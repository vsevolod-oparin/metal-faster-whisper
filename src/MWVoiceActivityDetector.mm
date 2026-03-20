#import "MWVoiceActivityDetector.h"
#import "MWHelpers.h"
#import "MWConstants.h"

#include <vector>
#include <cmath>
#include <algorithm>
#include <numeric>
#include <string>

#include <onnxruntime_cxx_api.h>

// ── Error codes ────────────────────────────────────────────────────────────

NSInteger const MWErrorCodeVADLoadFailed = 600;
NSInteger const MWErrorCodeVADInferenceFailed = 601;

// ── Constants ──────────────────────────────────────────────────────────────

static const NSUInteger kVADWindowSize = 512;
static const NSUInteger kVADContextSize = 64;
static const NSUInteger kVADInputSize = kVADWindowSize + kVADContextSize;  // 576
static const NSUInteger kVADHiddenSize = 128;
static const NSUInteger kVADEncoderBatchSize = 10000;

// ── MWVADOptions ──────────────────────────────────────────────────────────

@implementation MWVADOptions

+ (instancetype)defaults {
    MWVADOptions *opts = [[MWVADOptions alloc] init];
    opts.threshold = 0.5f;
    opts.negThreshold = -1.0f;
    opts.minSpeechDurationMs = 0;
    opts.maxSpeechDurationS = INFINITY;
    opts.minSilenceDurationMs = 2000;
    opts.speechPadMs = 400;
    opts.minSilenceAtMaxSpeech = 98;
    opts.useMaxPossSilAtMaxSpeech = YES;
    return [opts autorelease];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _threshold = 0.5f;
        _negThreshold = -1.0f;
        _minSpeechDurationMs = 0;
        _maxSpeechDurationS = INFINITY;
        _minSilenceDurationMs = 2000;
        _speechPadMs = 400;
        _minSilenceAtMaxSpeech = 98;
        _useMaxPossSilAtMaxSpeech = YES;
    }
    return self;
}

@end

// ── MWVoiceActivityDetector ───────────────────────────────────────────────

@implementation MWVoiceActivityDetector {
    Ort::Env _env;
    Ort::Session *_session;
    std::string _inputName;
    std::string _hName;
    std::string _cName;
    std::string _outputName;
    std::string _hnName;
    std::string _cnName;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                     error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    _session = nullptr;

    try {
        _env = Ort::Env(ORT_LOGGING_LEVEL_WARNING, "silero_vad");

        Ort::SessionOptions opts;
        opts.SetIntraOpNumThreads(1);
        opts.SetInterOpNumThreads(1);
        opts.DisableMemPattern();
        opts.SetLogSeverityLevel(4);

        const char *path = [modelPath UTF8String];
        _session = new Ort::Session(_env, path, opts);

        // Discover input/output names from the model.
        Ort::AllocatorWithDefaultOptions allocator;

        // Inputs: expect "input", "h", "c" (or similar).
        for (size_t i = 0; i < _session->GetInputCount(); i++) {
            auto name = _session->GetInputNameAllocated(i, allocator);
            std::string n(name.get());
            if (n == "input") _inputName = n;
            else if (n == "h") _hName = n;
            else if (n == "c") _cName = n;
        }

        // Outputs: expect "output" (or "speech_probs"), "hn", "cn".
        for (size_t i = 0; i < _session->GetOutputCount(); i++) {
            auto name = _session->GetOutputNameAllocated(i, allocator);
            std::string n(name.get());
            if (n == "output" || n == "speech_probs") _outputName = n;
            else if (n == "hn") _hnName = n;
            else if (n == "cn") _cnName = n;
        }

        if (_inputName.empty() || _hName.empty() || _cName.empty() ||
            _outputName.empty() || _hnName.empty() || _cnName.empty()) {
            MWSetError(error, MWErrorCodeVADLoadFailed,
                       @"VAD model has unexpected input/output names");
            [self release];
            return nil;
        }

        MWLog(@"[MetalWhisper] VAD model loaded: inputs=[%s,%s,%s] outputs=[%s,%s,%s]",
              _inputName.c_str(), _hName.c_str(), _cName.c_str(),
              _outputName.c_str(), _hnName.c_str(), _cnName.c_str());

    } catch (const std::exception& e) {
        MWSetError(error, MWErrorCodeVADLoadFailed,
                   [NSString stringWithFormat:@"Failed to load VAD model: %s", e.what()]);
        [self release];
        return nil;
    }

    return self;
}

- (void)dealloc {
    delete _session;
    _session = nullptr;
    [super dealloc];
}

// ── Speech Probabilities ──────────────────────────────────────────────────

- (nullable NSArray<NSNumber *> *)speechProbabilities:(NSData *)audio
                                                error:(NSError **)error {
    if (!audio || [audio length] == 0) {
        return @[];
    }

    const float *samples = (const float *)[audio bytes];
    NSUInteger totalSamples = [audio length] / sizeof(float);

    // Pad to multiple of 512.
    NSUInteger paddedLen = totalSamples;
    NSUInteger remainder = totalSamples % kVADWindowSize;
    if (remainder != 0) {
        paddedLen = totalSamples + (kVADWindowSize - remainder);
    }

    std::vector<float> padded(paddedLen, 0.0f);
    std::memcpy(padded.data(), samples, totalSamples * sizeof(float));

    NSUInteger numChunks = paddedLen / kVADWindowSize;

    // Build batched_audio with context: (numChunks, 576)
    // context[i] = last 64 samples of chunk[i-1], context[0] = zeros
    std::vector<float> batchedAudio(numChunks * kVADInputSize, 0.0f);

    for (NSUInteger i = 0; i < numChunks; i++) {
        float *dst = batchedAudio.data() + i * kVADInputSize;

        // Context: last 64 samples of previous chunk (zero for first).
        if (i > 0) {
            const float *prevChunk = padded.data() + (i - 1) * kVADWindowSize;
            std::memcpy(dst, prevChunk + (kVADWindowSize - kVADContextSize),
                        kVADContextSize * sizeof(float));
        }
        // else: first 64 floats already zero from vector init.

        // Audio chunk.
        const float *chunk = padded.data() + i * kVADWindowSize;
        std::memcpy(dst + kVADContextSize, chunk, kVADWindowSize * sizeof(float));
    }

    // Initialize LSTM states.
    std::vector<float> h(1 * 1 * kVADHiddenSize, 0.0f);
    std::vector<float> c(1 * 1 * kVADHiddenSize, 0.0f);

    NSMutableArray<NSNumber *> *probs = [[NSMutableArray alloc] initWithCapacity:numChunks];

    try {
        Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

        const char *inputNames[] = {_inputName.c_str(), _hName.c_str(), _cName.c_str()};
        const char *outputNames[] = {_outputName.c_str(), _hnName.c_str(), _cnName.c_str()};

        std::array<int64_t, 3> hShape = {1, 1, (int64_t)kVADHiddenSize};

        for (NSUInteger batchStart = 0; batchStart < numChunks; batchStart += kVADEncoderBatchSize) {
            NSUInteger batchEnd = std::min(batchStart + kVADEncoderBatchSize, numChunks);
            NSUInteger batchSize = batchEnd - batchStart;

            std::array<int64_t, 2> inputShape = {(int64_t)batchSize, (int64_t)kVADInputSize};

            float *batchData = batchedAudio.data() + batchStart * kVADInputSize;

            Ort::Value inputTensors[] = {
                Ort::Value::CreateTensor<float>(memInfo, batchData,
                                                 batchSize * kVADInputSize,
                                                 inputShape.data(), inputShape.size()),
                Ort::Value::CreateTensor<float>(memInfo, h.data(),
                                                 h.size(),
                                                 hShape.data(), hShape.size()),
                Ort::Value::CreateTensor<float>(memInfo, c.data(),
                                                 c.size(),
                                                 hShape.data(), hShape.size()),
            };

            auto outputs = _session->Run(Ort::RunOptions{},
                                          inputNames, inputTensors, 3,
                                          outputNames, 3);

            // Extract speech probabilities.
            const float *outData = outputs[0].GetTensorData<float>();
            for (NSUInteger j = 0; j < batchSize; j++) {
                [probs addObject:@(outData[j])];
            }

            // Update LSTM states from output.
            const float *hnData = outputs[1].GetTensorData<float>();
            const float *cnData = outputs[2].GetTensorData<float>();
            std::memcpy(h.data(), hnData, h.size() * sizeof(float));
            std::memcpy(c.data(), cnData, c.size() * sizeof(float));
        }
    } catch (const std::exception& e) {
        [probs release];
        MWSetError(error, MWErrorCodeVADInferenceFailed,
                   [NSString stringWithFormat:@"VAD inference failed: %s", e.what()]);
        return nil;
    }

    return [probs autorelease];
}

// ── Speech Timestamps ─────────────────────────────────────────────────────

- (nullable NSArray<NSDictionary<NSString *, NSNumber *> *> *)speechTimestamps:(NSData *)audio
                                                                       options:(nullable MWVADOptions *)options
                                                                         error:(NSError **)error {
    if (!options) {
        options = [MWVADOptions defaults];
    }

    NSArray<NSNumber *> *speechProbs = [self speechProbabilities:audio error:error];
    if (!speechProbs) return nil;

    const NSUInteger samplingRate = kMWTargetSampleRate;
    const float threshold = options.threshold;
    float negThreshold = options.negThreshold;
    if (negThreshold < 0) {
        negThreshold = fmaxf(threshold - 0.15f, 0.01f);
    }

    const float minSpeechSamples = (float)samplingRate * (float)options.minSpeechDurationMs / 1000.0f;
    const float speechPadSamples = (float)samplingRate * (float)options.speechPadMs / 1000.0f;
    const float maxSpeechSamples = (float)samplingRate * options.maxSpeechDurationS
                                    - (float)kVADWindowSize
                                    - 2.0f * speechPadSamples;
    const float minSilenceSamples = (float)samplingRate * (float)options.minSilenceDurationMs / 1000.0f;
    const float minSilenceSamplesAtMaxSpeech = (float)samplingRate * (float)options.minSilenceAtMaxSpeech / 1000.0f;
    const BOOL useMaxPossSil = options.useMaxPossSilAtMaxSpeech;

    const NSUInteger audioLengthSamples = [audio length] / sizeof(float);

    BOOL triggered = NO;
    NSMutableArray<NSMutableDictionary *> *speeches = [[NSMutableArray alloc] init];
    NSMutableDictionary *currentSpeech = nil;

    // Track possible ends for max speech splitting.
    // Each entry: (end_sample, silence_duration)
    NSMutableArray<NSArray<NSNumber *> *> *possibleEnds = [[NSMutableArray alloc] init];

    NSInteger tempEnd = 0;
    NSInteger prevEnd = 0;
    NSInteger nextStart = 0;

    for (NSUInteger i = 0; i < [speechProbs count]; i++) {
        float speechProb = [speechProbs[i] floatValue];
        NSInteger curSample = (NSInteger)(kVADWindowSize * i);

        // If speech above threshold and we had a temp_end, record possible end.
        if (speechProb >= threshold && tempEnd != 0) {
            NSInteger silDur = curSample - tempEnd;
            if ((float)silDur > minSilenceSamplesAtMaxSpeech) {
                [possibleEnds addObject:@[@(tempEnd), @(silDur)]];
            }
            tempEnd = 0;
            if (nextStart < prevEnd) {
                nextStart = curSample;
            }
        }

        // Speech start detection.
        if (speechProb >= threshold && !triggered) {
            triggered = YES;
            currentSpeech = [NSMutableDictionary dictionaryWithDictionary:@{@"start": @(curSample)}];
            continue;
        }

        // Max speech duration check.
        if (triggered && currentSpeech &&
            ((float)(curSample - [currentSpeech[@"start"] integerValue]) > maxSpeechSamples)) {

            if (useMaxPossSil && [possibleEnds count] > 0) {
                // Find possible end with maximum silence duration.
                NSArray<NSNumber *> *best = possibleEnds[0];
                for (NSArray<NSNumber *> *pe in possibleEnds) {
                    if ([pe[1] integerValue] > [best[1] integerValue]) {
                        best = pe;
                    }
                }
                prevEnd = [best[0] integerValue];
                NSInteger dur = [best[1] integerValue];
                currentSpeech[@"end"] = @(prevEnd);
                [speeches addObject:currentSpeech];
                currentSpeech = nil;
                nextStart = prevEnd + dur;

                if (nextStart < prevEnd + curSample) {
                    currentSpeech = [NSMutableDictionary dictionaryWithDictionary:@{@"start": @(nextStart)}];
                } else {
                    triggered = NO;
                }
                prevEnd = 0;
                nextStart = 0;
                tempEnd = 0;
                [possibleEnds removeAllObjects];
            } else {
                if (prevEnd != 0) {
                    currentSpeech[@"end"] = @(prevEnd);
                    [speeches addObject:currentSpeech];
                    currentSpeech = nil;
                    if (nextStart < prevEnd) {
                        triggered = NO;
                    } else {
                        currentSpeech = [NSMutableDictionary dictionaryWithDictionary:@{@"start": @(nextStart)}];
                    }
                    prevEnd = 0;
                    nextStart = 0;
                    tempEnd = 0;
                    [possibleEnds removeAllObjects];
                } else {
                    currentSpeech[@"end"] = @(curSample);
                    [speeches addObject:currentSpeech];
                    currentSpeech = nil;
                    prevEnd = 0;
                    nextStart = 0;
                    tempEnd = 0;
                    triggered = NO;
                    [possibleEnds removeAllObjects];
                    continue;
                }
            }
        }

        // Speech end detection.
        if (speechProb < negThreshold && triggered) {
            if (tempEnd == 0) {
                tempEnd = curSample;
            }
            NSInteger silDurNow = curSample - tempEnd;

            if (!useMaxPossSil && (float)silDurNow > minSilenceSamplesAtMaxSpeech) {
                prevEnd = tempEnd;
            }

            if ((float)silDurNow < minSilenceSamples) {
                continue;
            } else {
                currentSpeech[@"end"] = @(tempEnd);
                if (currentSpeech &&
                    ([currentSpeech[@"end"] integerValue] - [currentSpeech[@"start"] integerValue]) > (NSInteger)minSpeechSamples) {
                    [speeches addObject:currentSpeech];
                }
                currentSpeech = nil;
                prevEnd = 0;
                nextStart = 0;
                tempEnd = 0;
                triggered = NO;
                [possibleEnds removeAllObjects];
                continue;
            }
        }
    }

    // Handle trailing speech.
    if (currentSpeech &&
        ((NSInteger)audioLengthSamples - [currentSpeech[@"start"] integerValue]) > (NSInteger)minSpeechSamples) {
        currentSpeech[@"end"] = @(audioLengthSamples);
        [speeches addObject:currentSpeech];
    }

    // Apply padding and merge close segments.
    for (NSUInteger i = 0; i < [speeches count]; i++) {
        NSMutableDictionary *speech = speeches[i];
        if (i == 0) {
            speech[@"start"] = @((NSInteger)fmax(0, [speech[@"start"] integerValue] - speechPadSamples));
        }
        if (i != [speeches count] - 1) {
            NSInteger silenceDuration = [speeches[i + 1][@"start"] integerValue] - [speech[@"end"] integerValue];
            if (silenceDuration < (NSInteger)(2 * speechPadSamples)) {
                speech[@"end"] = @([speech[@"end"] integerValue] + (NSInteger)(silenceDuration / 2));
                speeches[i + 1][@"start"] = @((NSInteger)fmax(0, [speeches[i + 1][@"start"] integerValue] - silenceDuration / 2));
            } else {
                speech[@"end"] = @((NSInteger)fmin((NSInteger)audioLengthSamples, [speech[@"end"] integerValue] + (NSInteger)speechPadSamples));
                speeches[i + 1][@"start"] = @((NSInteger)fmax(0, [speeches[i + 1][@"start"] integerValue] - (NSInteger)speechPadSamples));
            }
        } else {
            speech[@"end"] = @((NSInteger)fmin((NSInteger)audioLengthSamples, [speech[@"end"] integerValue] + (NSInteger)speechPadSamples));
        }
    }

    // Convert to immutable result.
    NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *result =
        [[NSMutableArray alloc] initWithCapacity:[speeches count]];
    for (NSDictionary *s in speeches) {
        [result addObject:[NSDictionary dictionaryWithDictionary:s]];
    }

    [speeches release];
    [possibleEnds release];

    return [result autorelease];
}

// ── Collect Chunks ────────────────────────────────────────────────────────

+ (NSArray<NSData *> *)collectChunks:(NSData *)audio
                              chunks:(NSArray<NSDictionary<NSString *, NSNumber *> *> *)chunks
                         maxDuration:(float)maxDuration {
    if (!chunks || [chunks count] == 0) {
        return @[[NSData data]];
    }

    const float *samples = (const float *)[audio bytes];
    const NSUInteger samplingRate = kMWTargetSampleRate;

    NSMutableArray<NSData *> *audioChunks = [[NSMutableArray alloc] init];
    NSMutableData *currentAudio = [[NSMutableData alloc] init];
    float currentDuration = 0;

    for (NSDictionary *chunk in chunks) {
        NSInteger start = [chunk[@"start"] integerValue];
        NSInteger end = [chunk[@"end"] integerValue];
        NSInteger chunkSamples = end - start;

        if (currentDuration + (float)chunkSamples > maxDuration * (float)samplingRate) {
            // Flush current audio.
            [audioChunks addObject:[NSData dataWithData:currentAudio]];
            [currentAudio setLength:0];
            currentDuration = 0;
        }

        if (start >= 0 && end <= (NSInteger)([audio length] / sizeof(float)) && chunkSamples > 0) {
            [currentAudio appendBytes:(samples + start) length:chunkSamples * sizeof(float)];
        }
        currentDuration += (float)chunkSamples;
    }

    // Flush remaining.
    [audioChunks addObject:[NSData dataWithData:currentAudio]];
    [currentAudio release];

    NSArray<NSData *> *result = [NSArray arrayWithArray:audioChunks];
    [audioChunks release];
    return result;
}

@end

// ── MWSpeechTimestampsMap ─────────────────────────────────────────────────

@implementation MWSpeechTimestampsMap {
    NSUInteger _samplingRate;
    NSUInteger _timePrecision;
    std::vector<NSInteger> _chunkEndSample;
    std::vector<float> _totalSilenceBefore;
}

- (instancetype)initWithChunks:(NSArray<NSDictionary<NSString *, NSNumber *> *> *)chunks
                  samplingRate:(NSUInteger)samplingRate {
    self = [super init];
    if (!self) return nil;

    _samplingRate = samplingRate;
    _timePrecision = 2;

    NSInteger previousEnd = 0;
    NSInteger silentSamples = 0;

    for (NSDictionary *chunk in chunks) {
        NSInteger start = [chunk[@"start"] integerValue];
        NSInteger end = [chunk[@"end"] integerValue];

        silentSamples += start - previousEnd;
        previousEnd = end;

        _chunkEndSample.push_back(end - silentSamples);
        _totalSilenceBefore.push_back((float)silentSamples / (float)samplingRate);
    }

    return self;
}

- (float)originalTimeForTime:(float)time {
    NSUInteger idx = [self chunkIndexForTime:time isEnd:NO];
    return [self originalTimeForTime:time chunkIndex:idx];
}

- (float)originalTimeForTime:(float)time chunkIndex:(NSUInteger)chunkIndex {
    if (chunkIndex >= _totalSilenceBefore.size()) {
        return time;
    }
    float totalSilenceBefore = _totalSilenceBefore[chunkIndex];
    // Round to _timePrecision decimal places.
    float result = totalSilenceBefore + time;
    float factor = powf(10.0f, (float)_timePrecision);
    return roundf(result * factor) / factor;
}

- (NSUInteger)chunkIndexForTime:(float)time isEnd:(BOOL)isEnd {
    NSInteger sample = (NSInteger)(time * (float)_samplingRate);

    // Check if sample matches a chunk end exactly (for end timestamps).
    if (isEnd) {
        for (NSUInteger i = 0; i < _chunkEndSample.size(); i++) {
            if (_chunkEndSample[i] == sample) {
                return i;
            }
        }
    }

    // Binary search: find first chunk_end_sample > sample.
    auto it = std::upper_bound(_chunkEndSample.begin(), _chunkEndSample.end(), sample);
    NSUInteger idx = (NSUInteger)(it - _chunkEndSample.begin());
    return std::min(idx, (NSUInteger)(_chunkEndSample.size() - 1));
}

@end
