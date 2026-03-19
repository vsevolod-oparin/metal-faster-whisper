#import "MWTranscriber.h"
#import "MWAudioDecoder.h"
#import "MWConstants.h"

#include <memory>
#include <string>
#include <vector>
#include <cmath>
#include <compression.h>

#include <ctranslate2/models/whisper.h>
#include <ctranslate2/storage_view.h>
#include <ctranslate2/devices.h>
#include <ctranslate2/types.h>

NSErrorDomain const MWErrorDomain = @"com.metalwhisper.error";

// ── MWSegmentInfo ───────────────────────────────────────────────────────────

@implementation MWSegmentInfo {
    NSUInteger _seek;
    float _startTime;
    float _endTime;
    NSArray<NSNumber *> *_tokens;
}

- (instancetype)initWithSeek:(NSUInteger)seek
                   startTime:(float)startTime
                     endTime:(float)endTime
                      tokens:(NSArray<NSNumber *> *)tokens {
    self = [super init];
    if (!self) return nil;
    _seek = seek;
    _startTime = startTime;
    _endTime = endTime;
    _tokens = [tokens retain];
    return self;
}

- (NSUInteger)seek { return _seek; }
- (float)startTime { return _startTime; }
- (float)endTime { return _endTime; }
- (NSArray<NSNumber *> *)tokens { return _tokens; }

- (void)dealloc {
    [_tokens release];
    [super dealloc];
}

@end

// ── MWGenerateResult ────────────────────────────────────────────────────────

@implementation MWGenerateResult {
    NSArray<NSNumber *> *_tokenIDs;
    float _avgLogProb;
    float _temperature;
    float _compressionRatio;
    float _noSpeechProb;
    NSString *_text;
}

- (instancetype)initWithTokenIDs:(NSArray<NSNumber *> *)tokenIDs
                      avgLogProb:(float)avgLogProb
                     temperature:(float)temperature
                compressionRatio:(float)compressionRatio
                   noSpeechProb:(float)noSpeechProb
                            text:(NSString *)text {
    self = [super init];
    if (!self) return nil;
    _tokenIDs = [tokenIDs retain];
    _avgLogProb = avgLogProb;
    _temperature = temperature;
    _compressionRatio = compressionRatio;
    _noSpeechProb = noSpeechProb;
    _text = [text retain];
    return self;
}

- (NSArray<NSNumber *> *)tokenIDs { return _tokenIDs; }
- (float)avgLogProb { return _avgLogProb; }
- (float)temperature { return _temperature; }
- (float)compressionRatio { return _compressionRatio; }
- (float)noSpeechProb { return _noSpeechProb; }
- (NSString *)text { return _text; }

- (void)dealloc {
    [_tokenIDs release];
    [_text release];
    [super dealloc];
}

@end

// ── MWTranscriptionSegment ────────────────────────────────────────────────────

@implementation MWTranscriptionSegment {
    NSUInteger _segmentId;
    NSUInteger _seek;
    float _start;
    float _end;
    NSString *_text;
    NSArray<NSNumber *> *_tokens;
    float _temperature;
    float _avgLogProb;
    float _compressionRatio;
    float _noSpeechProb;
}

- (instancetype)initWithSegmentId:(NSUInteger)segmentId
                             seek:(NSUInteger)seek
                            start:(float)start
                              end:(float)end
                             text:(NSString *)text
                           tokens:(NSArray<NSNumber *> *)tokens
                      temperature:(float)temperature
                       avgLogProb:(float)avgLogProb
                 compressionRatio:(float)compressionRatio
                    noSpeechProb:(float)noSpeechProb {
    self = [super init];
    if (!self) return nil;
    _segmentId = segmentId;
    _seek = seek;
    _start = start;
    _end = end;
    _text = [text retain];
    _tokens = [tokens retain];
    _temperature = temperature;
    _avgLogProb = avgLogProb;
    _compressionRatio = compressionRatio;
    _noSpeechProb = noSpeechProb;
    return self;
}

- (NSUInteger)segmentId { return _segmentId; }
- (NSUInteger)seek { return _seek; }
- (float)start { return _start; }
- (float)end { return _end; }
- (NSString *)text { return _text; }
- (NSArray<NSNumber *> *)tokens { return _tokens; }
- (float)temperature { return _temperature; }
- (float)avgLogProb { return _avgLogProb; }
- (float)compressionRatio { return _compressionRatio; }
- (float)noSpeechProb { return _noSpeechProb; }

- (void)dealloc {
    [_text release];
    [_tokens release];
    [super dealloc];
}

@end

// ── MWTranscriptionInfo ──────────────────────────────────────────────────────

@implementation MWTranscriptionInfo {
    NSString *_language;
    float _languageProbability;
    float _duration;
}

- (instancetype)initWithLanguage:(NSString *)language
             languageProbability:(float)languageProbability
                        duration:(float)duration {
    self = [super init];
    if (!self) return nil;
    _language = [language retain];
    _languageProbability = languageProbability;
    _duration = duration;
    return self;
}

- (NSString *)language { return _language; }
- (float)languageProbability { return _languageProbability; }
- (float)duration { return _duration; }

- (void)dealloc {
    [_language release];
    [super dealloc];
}

@end

// ── Error helper ────────────────────────────────────────────────────────────

static void MWSetError(NSError **error, NSInteger code, NSString *description) {
    if (error) {
        *error = [NSError errorWithDomain:MWErrorDomain
                                     code:code
                                 userInfo:@{
            NSLocalizedDescriptionKey: description
        }];
    }
}

// ── CT2 compute type mapping ────────────────────────────────────────────────

static ctranslate2::ComputeType mwComputeTypeToCT2(MWComputeType type) {
    switch (type) {
        case MWComputeTypeFloat32:     return ctranslate2::ComputeType::FLOAT32;
        case MWComputeTypeFloat16:     return ctranslate2::ComputeType::FLOAT16;
        case MWComputeTypeInt8:        return ctranslate2::ComputeType::INT8;
        case MWComputeTypeInt8Float16: return ctranslate2::ComputeType::INT8_FLOAT16;
        case MWComputeTypeInt8Float32: return ctranslate2::ComputeType::INT8_FLOAT32;
        case MWComputeTypeDefault:
        default:                       return ctranslate2::ComputeType::DEFAULT;
    }
}

// ── Standard Whisper language codes (100 languages for multilingual models) ─

static NSArray<NSString *> *whisperLanguageCodes() {
    static NSArray<NSString *> *codes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        codes = [@[
            @"en", @"zh", @"de", @"es", @"ru", @"ko", @"fr", @"ja", @"pt", @"tr",
            @"pl", @"ca", @"nl", @"ar", @"sv", @"it", @"id", @"hi", @"fi", @"vi",
            @"he", @"uk", @"el", @"ms", @"cs", @"ro", @"da", @"hu", @"ta", @"no",
            @"th", @"ur", @"hr", @"bg", @"lt", @"la", @"mi", @"ml", @"cy", @"sk",
            @"te", @"fa", @"lv", @"bn", @"sr", @"az", @"sl", @"kn", @"et", @"mk",
            @"br", @"eu", @"is", @"hy", @"ne", @"mn", @"bs", @"kk", @"sq", @"sw",
            @"gl", @"mr", @"pa", @"si", @"km", @"sn", @"yo", @"so", @"af", @"oc",
            @"ka", @"be", @"tg", @"sd", @"gu", @"am", @"yi", @"lo", @"uz", @"fo",
            @"ht", @"ps", @"tk", @"nn", @"mt", @"sa", @"lb", @"my", @"bo", @"tl",
            @"mg", @"as", @"tt", @"haw", @"ln", @"ha", @"ba", @"jw", @"su", @"yue"
        ] retain];
    });
    return codes;
}

// ── JSON loading helper ─────────────────────────────────────────────────────

static NSDictionary *loadJSONFromPath(NSString *path, NSError **error) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return nil;  // Caller handles missing file gracefully
    }

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;

    NSError *parseError = nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data
                                                        options:0
                                                          error:&parseError];
    if (!dict && error) {
        *error = parseError;
    }
    return dict;
}

// ── Private ivar block ──────────────────────────────────────────────────────

@implementation MWTranscriber {
    std::unique_ptr<ctranslate2::models::Whisper> _whisper;

    NSString *_modelPath;
    MWFeatureExtractor *_featureExtractor;
    MWTokenizer *_tokenizer;

    NSUInteger _numLanguages;
    NSUInteger _inputStride;
    NSUInteger _numSamplesPerToken;
    NSUInteger _framesPerSecond;
    NSUInteger _tokensPerSecond;
    float _timePrecision;
    NSUInteger _maxLength;

    NSArray<NSString *> *_supportedLanguages;
    NSArray<NSNumber *> *_suppressTokens;
    NSArray<NSNumber *> *_suppressTokensAtBegin;
}

// ── Initializers ────────────────────────────────────────────────────────────

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                     error:(NSError **)error {
    return [self initWithModelPath:modelPath
                       computeType:MWComputeTypeDefault
                             error:error];
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                               computeType:(MWComputeType)computeType
                                     error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    // Save model path for creating tokenizers later.
    _modelPath = [modelPath retain];

    // Step 1: Load CTranslate2 model
    try {
        const std::string path = [modelPath UTF8String];
        const auto ct2Type = mwComputeTypeToCT2(computeType);

        _whisper = std::make_unique<ctranslate2::models::Whisper>(
            path,
            ctranslate2::Device::MPS,
            ct2Type,
            std::vector<int>{0},
            false
        );

        NSLog(@"[MetalWhisper] Model loaded: multilingual=%d  n_mels=%zu  compute_type=%s",
              self.isMultilingual, (size_t)self.nMels,
              ctranslate2::compute_type_to_str(ct2Type).c_str());

    } catch (const std::exception& e) {
        MWSetError(error, MWErrorCodeModelLoadFailed,
                   [NSString stringWithFormat:@"Failed to load model: %s", e.what()]);
        [self release];
        return nil;
    }

    // Step 2: Load preprocessor_config.json
    NSUInteger featureSize = 80;  // Default for older models
    NSUInteger nFFT = kMWDefaultNFFT;
    NSUInteger hopLength = kMWDefaultHopLength;
    NSUInteger samplingRate = kMWTargetSampleRate;

    NSString *preprocessorPath = [modelPath stringByAppendingPathComponent:@"preprocessor_config.json"];
    NSDictionary *preprocessorConfig = loadJSONFromPath(preprocessorPath, nil);
    if (preprocessorConfig) {
        NSNumber *fs = preprocessorConfig[@"feature_size"];
        if (fs) featureSize = [fs unsignedIntegerValue];

        NSNumber *nf = preprocessorConfig[@"n_fft"];
        if (nf) nFFT = [nf unsignedIntegerValue];

        NSNumber *hl = preprocessorConfig[@"hop_length"];
        if (hl) hopLength = [hl unsignedIntegerValue];

        NSNumber *sr = preprocessorConfig[@"sampling_rate"];
        if (sr) samplingRate = [sr unsignedIntegerValue];
    }

    // Step 3: Create feature extractor
    _featureExtractor = [[MWFeatureExtractor alloc] initWithNMels:featureSize
                                                             nFFT:nFFT
                                                        hopLength:hopLength
                                                     samplingRate:samplingRate];
    if (!_featureExtractor) {
        MWSetError(error, MWErrorCodeModelLoadFailed,
                   @"Failed to create feature extractor");
        [self release];
        return nil;
    }

    // Step 4: Create tokenizer
    BOOL multilingual = self.isMultilingual;
    NSError *tokenizerError = nil;
    _tokenizer = [[MWTokenizer alloc] initWithModelPath:modelPath
                                           multilingual:multilingual
                                                   task:@"transcribe"
                                               language:(multilingual ? @"en" : nil)
                                                  error:&tokenizerError];
    if (!_tokenizer) {
        MWSetError(error, MWErrorCodeTokenizerLoadFailed,
                   [NSString stringWithFormat:@"Failed to load tokenizer: %@",
                    [tokenizerError localizedDescription]]);
        [self release];
        return nil;
    }

    // Step 5: Load config.json (suppress_ids, suppress_ids_begin, lang_ids)
    NSString *configPath = [modelPath stringByAppendingPathComponent:@"config.json"];
    NSDictionary *config = loadJSONFromPath(configPath, nil);

    NSMutableArray<NSNumber *> *suppressIds = [[NSMutableArray alloc] init];
    NSMutableArray<NSNumber *> *suppressIdsBegin = [[NSMutableArray alloc] init];

    if (config) {
        NSArray *sids = config[@"suppress_ids"];
        if ([sids isKindOfClass:[NSArray class]]) {
            for (NSNumber *n in sids) {
                [suppressIds addObject:n];
            }
        }

        NSArray *sidsBegin = config[@"suppress_ids_begin"];
        if ([sidsBegin isKindOfClass:[NSArray class]]) {
            for (NSNumber *n in sidsBegin) {
                [suppressIdsBegin addObject:n];
            }
        }

        // Count languages from lang_ids
        NSArray *langIds = config[@"lang_ids"];
        if ([langIds isKindOfClass:[NSArray class]]) {
            _numLanguages = [langIds count];
        } else {
            _numLanguages = multilingual ? 100 : 0;
        }
    } else {
        _numLanguages = multilingual ? 100 : 0;
    }

    _suppressTokens = suppressIds;        // Already +1 from alloc
    _suppressTokensAtBegin = suppressIdsBegin;  // Already +1 from alloc

    // Step 6: Compute derived constants
    _inputStride = kMWInputStride;
    _numSamplesPerToken = hopLength * _inputStride;
    _framesPerSecond = samplingRate / hopLength;
    _tokensPerSecond = samplingRate / _numSamplesPerToken;
    _timePrecision = kMWTimePrecision;
    _maxLength = kMWMaxGenerationLength;

    // Step 7: Build supported languages list
    if (multilingual) {
        NSArray<NSString *> *allLangs = whisperLanguageCodes();
        // Use lang_ids count to determine how many languages are supported.
        // For turbo/large-v3: 100 languages. Trim list to numLanguages.
        NSUInteger count = _numLanguages;
        if (count > [allLangs count]) count = [allLangs count];
        _supportedLanguages = [[allLangs subarrayWithRange:NSMakeRange(0, count)] retain];
    } else {
        _supportedLanguages = [@[@"en"] retain];
    }

    return self;
}

// ── Properties ──────────────────────────────────────────────────────────────

- (BOOL)isMultilingual {
    return _whisper->is_multilingual() ? YES : NO;
}

- (NSUInteger)nMels {
    return static_cast<NSUInteger>(_whisper->n_mels());
}

- (NSUInteger)numLanguages {
    return _numLanguages;
}

- (MWFeatureExtractor *)featureExtractor {
    return _featureExtractor;
}

- (MWTokenizer *)tokenizer {
    return _tokenizer;
}

- (NSUInteger)inputStride {
    return _inputStride;
}

- (NSUInteger)numSamplesPerToken {
    return _numSamplesPerToken;
}

- (NSUInteger)framesPerSecond {
    return _framesPerSecond;
}

- (NSUInteger)tokensPerSecond {
    return _tokensPerSecond;
}

- (float)timePrecision {
    return _timePrecision;
}

- (NSUInteger)maxLength {
    return _maxLength;
}

- (NSArray<NSString *> *)supportedLanguages {
    return _supportedLanguages;
}

- (NSArray<NSNumber *> *)suppressTokens {
    return _suppressTokens;
}

- (NSArray<NSNumber *> *)suppressTokensAtBegin {
    return _suppressTokensAtBegin;
}

// ── Mel pad/trim helper ─────────────────────────────────────────────────────

/// Pad or trim a mel spectrogram (nMels x nFrames, row-major) to targetFrames columns.
/// If nFrames < targetFrames, zero-pads each row at the end.
/// If nFrames > targetFrames, truncates each row.
/// If nFrames == targetFrames, returns the original data.
static NSData *padOrTrimMel(NSData *mel, NSUInteger nMels, NSUInteger nFrames, NSUInteger targetFrames) {
    if (nFrames == targetFrames) return mel;

    NSUInteger targetBytes = nMels * targetFrames * sizeof(float);
    NSMutableData *result = [NSMutableData dataWithLength:targetBytes]; // zero-filled
    const float *src = (const float *)[mel bytes];
    float *dst = (float *)[result mutableBytes];

    NSUInteger copyFrames = MIN(nFrames, targetFrames);
    for (NSUInteger row = 0; row < nMels; row++) {
        memcpy(dst + row * targetFrames,
               src + row * nFrames,
               copyFrames * sizeof(float));
    }
    return result;
}

// ── Encoding ────────────────────────────────────────────────────────────────

- (nullable NSData *)encodeFeatures:(NSData *)melSpectrogram
                            nFrames:(NSUInteger)nFrames
                              error:(NSError **)error {
    try {
        NSUInteger nMels = self.nMels;
        NSUInteger expectedBytes = nMels * nFrames * sizeof(float);
        if ([melSpectrogram length] != expectedBytes) {
            MWSetError(error, MWErrorCodeEncodeFailed,
                       [NSString stringWithFormat:
                        @"Mel spectrogram size mismatch: expected %lu bytes (nMels=%lu, nFrames=%lu), got %lu",
                        (unsigned long)expectedBytes,
                        (unsigned long)nMels,
                        (unsigned long)nFrames,
                        (unsigned long)[melSpectrogram length]]);
            return nil;
        }

        // Zero-copy: create StorageView pointing to NSData's bytes.
        // NSData is retained on the stack, so the pointer remains valid through encode().
        float *melPtr = const_cast<float *>((const float *)[melSpectrogram bytes]);
        ctranslate2::StorageView features(
            {1, (ctranslate2::dim_t)nMels, (ctranslate2::dim_t)nFrames},
            melPtr,
            ctranslate2::Device::CPU
        );

        auto future = _whisper->encode(features, /*to_cpu=*/true);
        ctranslate2::StorageView output = future.get();

        // Move output to CPU if needed.
        if (output.device() != ctranslate2::Device::CPU) {
            output = output.to(ctranslate2::Device::CPU);
        }

        // Convert to float32 if the encoder returned a different type (e.g. float16).
        if (output.dtype() != ctranslate2::DataType::FLOAT32) {
            output = output.to(ctranslate2::DataType::FLOAT32);
        }

        // Compute total element count from shape.
        const auto& shape = output.shape();
        size_t totalElements = 1;
        for (auto dim : shape) totalElements *= dim;

        return [NSData dataWithBytes:output.data<float>()
                              length:totalElements * sizeof(float)];

    } catch (const std::exception& e) {
        MWSetError(error, MWErrorCodeEncodeFailed,
                   [NSString stringWithFormat:@"Encode failed: %s", e.what()]);
        return nil;
    } catch (...) {
        MWSetError(error, MWErrorCodeEncodeFailed,
                   @"Encode failed: unknown exception");
        return nil;
    }
}

// ── Language Detection ──────────────────────────────────────────────────────

- (BOOL)detectLanguageFromAudio:(NSData *)audio
                       segments:(NSUInteger)segments
                      threshold:(float)threshold
               detectedLanguage:(NSString * _Nullable * _Nonnull)detectedLanguage
                    probability:(float *)probability
               allLanguageProbs:(NSArray<NSDictionary<NSString *, NSNumber *> *> * _Nullable * _Nullable)allLanguageProbs
                          error:(NSError **)error {
    try {
        if (!audio || [audio length] == 0) {
            MWSetError(error, MWErrorCodeLanguageDetectionFailed,
                       @"Audio data is nil or empty");
            return NO;
        }

        if (segments == 0) segments = 1;

        NSUInteger nMels = self.nMels;
        NSUInteger targetFrames = kMWDefaultChunkFrames; // 3000 frames = 30s

        // Limit audio to segments * 30s worth of samples (each segment = 480000 samples at 16kHz).
        NSUInteger samplesPerSegment = kMWTargetSampleRate * 30; // 480000
        NSUInteger maxSamples = segments * samplesPerSegment;
        NSUInteger totalSamples = [audio length] / sizeof(float);

        NSData *limitedAudio = audio;
        if (totalSamples > maxSamples) {
            limitedAudio = [NSData dataWithBytes:[audio bytes]
                                          length:maxSamples * sizeof(float)];
            totalSamples = maxSamples;
        }

        // Compute mel spectrogram for entire limited audio.
        NSError *melError = nil;
        NSData *fullMel = [_featureExtractor computeMelSpectrogramFromAudio:limitedAudio
                                                                      error:&melError];
        if (!fullMel) {
            MWSetError(error, MWErrorCodeLanguageDetectionFailed,
                       [NSString stringWithFormat:@"Mel computation failed: %@",
                        [melError localizedDescription]]);
            return NO;
        }

        NSUInteger fullFrames = _featureExtractor.lastFrameCount;

        // Track per-segment top language for majority vote.
        NSMutableDictionary<NSString *, NSNumber *> *langVotes = [[NSMutableDictionary alloc] init];
        NSArray<NSDictionary<NSString *, NSNumber *> *> *lastProbs = nil;

        // Process each 30s segment.
        NSUInteger numSegments = (fullFrames + targetFrames - 1) / targetFrames;
        if (numSegments > segments) numSegments = segments;
        if (numSegments == 0) numSegments = 1;

        for (NSUInteger seg = 0; seg < numSegments; seg++) {
            // Extract this segment's mel frames.
            NSUInteger startFrame = seg * targetFrames;
            NSUInteger availableFrames = (startFrame < fullFrames) ? (fullFrames - startFrame) : 0;

            NSData *segmentMel = nil;
            if (availableFrames == 0) {
                // All zeros segment.
                NSMutableData *zeros = [NSMutableData dataWithLength:nMels * targetFrames * sizeof(float)];
                segmentMel = zeros;
            } else {
                // Extract sub-matrix: for each mel row, copy frames [startFrame, startFrame+availableFrames).
                NSMutableData *subMel = [NSMutableData dataWithLength:nMels * availableFrames * sizeof(float)];
                const float *srcMel = (const float *)[fullMel bytes];
                float *dstMel = (float *)[subMel mutableBytes];
                for (NSUInteger row = 0; row < nMels; row++) {
                    memcpy(dstMel + row * availableFrames,
                           srcMel + row * fullFrames + startFrame,
                           availableFrames * sizeof(float));
                }
                // Pad or trim to targetFrames.
                segmentMel = padOrTrimMel(subMel, nMels, availableFrames, targetFrames);
            }

            // Encode the segment.
            NSError *encError = nil;
            NSData *encoded = [self encodeFeatures:segmentMel nFrames:targetFrames error:&encError];
            if (!encoded) {
                MWSetError(error, MWErrorCodeLanguageDetectionFailed,
                           [NSString stringWithFormat:@"Encode failed for segment %lu: %@",
                            (unsigned long)seg, [encError localizedDescription]]);
                [langVotes release];
                return NO;
            }

            // Detect language from encoder output.
            // The encoded output shape is [1, 1500, d_model].
            // detect_language expects the encoder output as StorageView.
            NSUInteger encodedElements = [encoded length] / sizeof(float);
            NSUInteger dModel = encodedElements / 1500; // 1 * 1500 * d_model
            float *encPtr = const_cast<float *>((const float *)[encoded bytes]);
            ctranslate2::StorageView encView(
                {1, 1500, (ctranslate2::dim_t)dModel},
                encPtr,
                ctranslate2::Device::CPU
            );

            auto futures = _whisper->detect_language(encView);
            auto results = futures[0].get();

            // Parse results: vector of (token_string, probability).
            // Token strings look like "<|en|>", "<|zh|>", etc.
            NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *probs =
                [[NSMutableArray alloc] initWithCapacity:results.size()];

            NSString *topLang = nil;
            float topProb = -1.0f;

            for (const auto& pair : results) {
                // Strip "<|" prefix and "|>" suffix.
                std::string langCode = pair.first;
                if (langCode.size() >= 4 &&
                    langCode.substr(0, 2) == "<|" &&
                    langCode.substr(langCode.size() - 2) == "|>") {
                    langCode = langCode.substr(2, langCode.size() - 4);
                }

                NSString *lang = [NSString stringWithUTF8String:langCode.c_str()];
                float prob = pair.second;

                [probs addObject:@{lang: @(prob)}];

                if (prob > topProb) {
                    topProb = prob;
                    topLang = lang;
                }
            }

            // Sort by probability descending.
            [probs sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                float pa = [[[a allValues] firstObject] floatValue];
                float pb = [[[b allValues] firstObject] floatValue];
                if (pb > pa) return NSOrderedDescending;
                if (pb < pa) return NSOrderedAscending;
                return NSOrderedSame;
            }];

            lastProbs = [[probs copy] autorelease];
            [probs release];

            // Early stop if top language exceeds threshold.
            if (topProb > threshold) {
                *detectedLanguage = topLang;
                if (probability) *probability = topProb;
                if (allLanguageProbs) *allLanguageProbs = lastProbs;
                [langVotes release];
                return YES;
            }

            // Accumulate vote.
            if (topLang) {
                NSNumber *cur = langVotes[topLang];
                langVotes[topLang] = @([cur integerValue] + 1);
            }
        }

        // Majority vote: pick the language with the most top-1 appearances.
        NSString *bestLang = nil;
        NSInteger bestVotes = 0;
        for (NSString *lang in langVotes) {
            NSInteger v = [langVotes[lang] integerValue];
            if (v > bestVotes) {
                bestVotes = v;
                bestLang = lang;
            }
        }
        [langVotes release];

        // Find the probability for the majority language from the last segment's probs.
        float bestProb = 0.0f;
        if (bestLang && lastProbs) {
            for (NSDictionary<NSString *, NSNumber *> *entry in lastProbs) {
                NSNumber *p = entry[bestLang];
                if (p) {
                    bestProb = [p floatValue];
                    break;
                }
            }
        }

        *detectedLanguage = bestLang;
        if (probability) *probability = bestProb;
        if (allLanguageProbs) *allLanguageProbs = lastProbs;
        return YES;

    } catch (const std::exception& e) {
        MWSetError(error, MWErrorCodeLanguageDetectionFailed,
                   [NSString stringWithFormat:@"Language detection failed: %s", e.what()]);
        return NO;
    } catch (...) {
        MWSetError(error, MWErrorCodeLanguageDetectionFailed,
                   @"Language detection failed: unknown exception");
        return NO;
    }
}

// ── Prompt Construction ──────────────────────────────────────────────────────

- (NSArray<NSNumber *> *)buildPromptWithPreviousTokens:(nullable NSArray<NSNumber *> *)previousTokens
                                     withoutTimestamps:(BOOL)withoutTimestamps
                                                prefix:(nullable NSString *)prefix
                                              hotwords:(nullable NSString *)hotwords {
    NSMutableArray<NSNumber *> *prompt = [[NSMutableArray alloc] init];
    NSUInteger halfMax = _maxLength / 2;  // 224

    BOOL hasPrevious = (previousTokens != nil && [previousTokens count] > 0);
    BOOL hasHotwords = (hotwords != nil && [[hotwords stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0);
    BOOL hasPrefix = (prefix != nil && [[prefix stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0);

    // Step 1: previous tokens / hotwords preamble
    if (hasPrevious || (hasHotwords && !hasPrefix)) {
        [prompt addObject:@(_tokenizer.sotPrev)];

        if (hasHotwords && !hasPrefix) {
            NSString *trimmedHotwords = [hotwords stringByTrimmingCharactersInSet:
                                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *hotwordsInput = [@" " stringByAppendingString:trimmedHotwords];
            NSArray<NSNumber *> *hotwordsTokens = [_tokenizer encode:hotwordsInput];
            if ([hotwordsTokens count] >= halfMax) {
                hotwordsTokens = [hotwordsTokens subarrayWithRange:NSMakeRange(0, halfMax - 1)];
            }
            [prompt addObjectsFromArray:hotwordsTokens];
        }

        if (hasPrevious) {
            NSUInteger maxPrevious = halfMax - 1;  // 223
            NSArray<NSNumber *> *prevSlice = previousTokens;
            if ([previousTokens count] > maxPrevious) {
                NSUInteger start = [previousTokens count] - maxPrevious;
                prevSlice = [previousTokens subarrayWithRange:NSMakeRange(start, maxPrevious)];
            }
            [prompt addObjectsFromArray:prevSlice];
        }
    }

    // Step 2: SOT sequence
    [prompt addObjectsFromArray:_tokenizer.sotSequence];

    // Step 3: no-timestamps flag
    if (withoutTimestamps) {
        [prompt addObject:@(_tokenizer.noTimestamps)];
    }

    // Step 4: prefix
    if (hasPrefix) {
        NSString *trimmedPrefix = [prefix stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *prefixInput = [@" " stringByAppendingString:trimmedPrefix];
        NSArray<NSNumber *> *prefixTokens = [_tokenizer encode:prefixInput];
        if ([prefixTokens count] >= halfMax) {
            prefixTokens = [prefixTokens subarrayWithRange:NSMakeRange(0, halfMax - 1)];
        }

        if (!withoutTimestamps) {
            [prompt addObject:@(_tokenizer.timestampBegin)];
        }
        [prompt addObjectsFromArray:prefixTokens];
    }

    NSArray<NSNumber *> *result = [[prompt copy] autorelease];
    [prompt release];
    return result;
}

- (NSArray<NSNumber *> *)buildSuppressedTokens:(NSArray<NSNumber *> *)suppressTokens {
    NSMutableSet<NSNumber *> *tokenSet = [[NSMutableSet alloc] init];

    // Check if -1 is in the input
    BOOL hasNegativeOne = NO;
    for (NSNumber *t in suppressTokens) {
        if ([t integerValue] == -1) {
            hasNegativeOne = YES;
        }
    }

    if (hasNegativeOne) {
        // Add all non-(-1) tokens from input
        for (NSNumber *t in suppressTokens) {
            if ([t integerValue] >= 0) {
                [tokenSet addObject:t];
            }
        }
        // Add tokenizer's non-speech tokens
        for (NSNumber *t in _tokenizer.nonSpeechTokens) {
            [tokenSet addObject:t];
        }
    } else {
        // Use input as-is
        for (NSNumber *t in suppressTokens) {
            [tokenSet addObject:t];
        }
    }

    // Always add these special tokens
    [tokenSet addObject:@(_tokenizer.transcribeToken)];
    [tokenSet addObject:@(_tokenizer.translateToken)];
    [tokenSet addObject:@(_tokenizer.sot)];
    [tokenSet addObject:@(_tokenizer.sotPrev)];
    [tokenSet addObject:@(_tokenizer.sotLM)];
    [tokenSet addObject:@(_tokenizer.noSpeech)];

    // Sort and deduplicate (set already deduplicates)
    NSArray<NSNumber *> *sorted = [[tokenSet allObjects]
        sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            return [a compare:b];
        }];

    [tokenSet release];
    return sorted;
}

// ── Compression ratio helper ─────────────────────────────────────────────────

static float getCompressionRatio(NSString *text) {
    NSData *textData = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!textData || [textData length] == 0) return 0.0f;

    NSUInteger srcLen = [textData length];
    size_t dstCapacity = srcLen + 1024;
    uint8_t *dstBuffer = (uint8_t *)malloc(dstCapacity);

    size_t compressedSize = compression_encode_buffer(
        dstBuffer, dstCapacity,
        (const uint8_t *)[textData bytes], srcLen,
        NULL,
        COMPRESSION_ZLIB);

    free(dstBuffer);

    if (compressedSize == 0) return 0.0f;
    return (float)srcLen / (float)compressedSize;
}

// ── Generate with temperature fallback ──────────────────────────────────────

- (nullable MWGenerateResult *)generateWithEncoderOutput:(NSData *)encoderOutput
                                                  prompt:(NSArray<NSNumber *> *)prompt
                                            temperatures:(NSArray<NSNumber *> *)temperatures
                                                beamSize:(NSUInteger)beamSize
                                                patience:(float)patience
                                                  bestOf:(NSUInteger)bestOf
                                           lengthPenalty:(float)lengthPenalty
                                       repetitionPenalty:(float)repetitionPenalty
                                       noRepeatNgramSize:(NSUInteger)noRepeatNgramSize
                                 compressionRatioThreshold:(float)compressionRatioThreshold
                                         logProbThreshold:(float)logProbThreshold
                                       noSpeechThreshold:(float)noSpeechThreshold
                                           suppressTokens:(nullable NSArray<NSNumber *> *)suppressTokens
                                            suppressBlank:(BOOL)suppressBlank
                                      maxInitialTimestamp:(float)maxInitialTimestamp
                                                    error:(NSError **)error {
    try {
        if (!encoderOutput || [encoderOutput length] == 0) {
            MWSetError(error, MWErrorCodeGenerateFailed, @"Encoder output is nil or empty");
            return nil;
        }
        if (!prompt || [prompt count] == 0) {
            MWSetError(error, MWErrorCodeGenerateFailed, @"Prompt is nil or empty");
            return nil;
        }
        if (!temperatures || [temperatures count] == 0) {
            MWSetError(error, MWErrorCodeGenerateFailed, @"Temperatures list is nil or empty");
            return nil;
        }

        // Build encoder output StorageView.
        NSUInteger encodedElements = [encoderOutput length] / sizeof(float);
        NSUInteger dModel = encodedElements / 1500;  // shape [1, 1500, d_model]
        float *encPtr = const_cast<float *>((const float *)[encoderOutput bytes]);
        ctranslate2::StorageView encView(
            {1, 1500, (ctranslate2::dim_t)dModel},
            encPtr,
            ctranslate2::Device::CPU
        );

        // Build prompt vector.
        std::vector<size_t> promptVec;
        promptVec.reserve([prompt count]);
        for (NSNumber *tok in prompt) {
            promptVec.push_back([tok unsignedLongValue]);
        }
        std::vector<std::vector<size_t>> prompts = {promptVec};

        // Build suppress tokens vector.
        std::vector<int> suppressVec;
        if (suppressTokens) {
            for (NSNumber *tok in suppressTokens) {
                suppressVec.push_back([tok intValue]);
            }
        } else {
            suppressVec.push_back(-1);
        }

        // Compute max_initial_timestamp_index from seconds.
        // max_initial_timestamp_index = round(maxInitialTimestamp / time_precision)
        size_t maxInitTimestampIdx = (size_t)roundf(maxInitialTimestamp / _timePrecision);

        // Track best result across all temperature attempts.
        MWGenerateResult *bestResult = nil;
        float bestAvgLogProb = -INFINITY;

        for (NSNumber *tempNum in temperatures) {
            float temperature = [tempNum floatValue];

            // Build WhisperOptions based on temperature.
            ctranslate2::models::WhisperOptions opts;
            if (temperature > 0.0f) {
                opts.beam_size = 1;
                opts.num_hypotheses = bestOf;
                opts.sampling_topk = 0;
                opts.sampling_temperature = temperature;
            } else {
                opts.beam_size = beamSize;
                opts.patience = patience;
                opts.num_hypotheses = 1;
            }

            opts.length_penalty = lengthPenalty;
            opts.repetition_penalty = repetitionPenalty;
            opts.no_repeat_ngram_size = noRepeatNgramSize;
            opts.max_length = _maxLength;
            opts.return_scores = true;
            opts.return_no_speech_prob = true;
            opts.suppress_blank = suppressBlank ? true : false;
            opts.suppress_tokens = suppressVec;
            opts.max_initial_timestamp_index = maxInitTimestampIdx;

            // Call generate.
            auto futures = _whisper->generate(encView, prompts, opts);
            auto result = futures[0].get();

            if (result.sequences_ids.empty() || result.sequences_ids[0].empty()) {
                continue;
            }

            // Extract tokens from the best hypothesis (index 0).
            const auto& tokenIds = result.sequences_ids[0];
            NSUInteger seqLen = tokenIds.size();

            // Compute average log probability.
            // CT2 returns score = cumulative_logprob / (seq_len ^ length_penalty)
            // We need avg_logprob = cumulative_logprob / (seq_len + 1)
            // So: cumulative_logprob = score * (seq_len ^ length_penalty)
            //     avg_logprob = cumulative_logprob / (seq_len + 1)
            float score = result.has_scores() ? result.scores[0] : 0.0f;
            float cumLogProb = score * powf((float)seqLen, lengthPenalty);
            float avgLogProb = cumLogProb / ((float)seqLen + 1.0f);

            float noSpeechProb = result.no_speech_prob;

            // Build token IDs array.
            NSMutableArray<NSNumber *> *tokenIDsArr = [[NSMutableArray alloc] initWithCapacity:seqLen];
            for (size_t i = 0; i < seqLen; i++) {
                [tokenIDsArr addObject:@((NSUInteger)tokenIds[i])];
            }

            // Decode text.
            NSString *text = [[_tokenizer decode:tokenIDsArr] stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];

            // Compute compression ratio.
            float compressionRatio = getCompressionRatio(text);

            // Build result.
            MWGenerateResult *genResult = [[MWGenerateResult alloc]
                initWithTokenIDs:tokenIDsArr
                      avgLogProb:avgLogProb
                     temperature:temperature
                compressionRatio:compressionRatio
                   noSpeechProb:noSpeechProb
                            text:text];
            [tokenIDsArr release];

            // Check fallback conditions.
            BOOL needsFallback = NO;

            // Compression ratio check.
            if (compressionRatioThreshold >= 0.0f && compressionRatio > compressionRatioThreshold) {
                needsFallback = YES;
            }

            // Log probability check.
            if (!isnan(logProbThreshold) && avgLogProb < logProbThreshold) {
                needsFallback = YES;
            }

            // No-speech override: if no_speech_prob is high AND avg_logprob is low,
            // this is likely silence — do NOT fall back.
            if (noSpeechThreshold >= 0.0f && noSpeechProb > noSpeechThreshold
                && !isnan(logProbThreshold) && avgLogProb < logProbThreshold) {
                needsFallback = NO;
            }

            // Track best result (prefer results below CR threshold).
            BOOL currentBelowCR = (compressionRatioThreshold < 0.0f ||
                                   compressionRatio <= compressionRatioThreshold);
            BOOL bestBelowCR = NO;
            if (bestResult) {
                bestBelowCR = (compressionRatioThreshold < 0.0f ||
                               bestResult.compressionRatio <= compressionRatioThreshold);
            }

            if (!bestResult ||
                (currentBelowCR && !bestBelowCR) ||
                (currentBelowCR == bestBelowCR && avgLogProb > bestAvgLogProb)) {
                [bestResult release];
                bestResult = genResult;
                bestAvgLogProb = avgLogProb;
            } else {
                [genResult release];
            }

            if (!needsFallback) {
                return [bestResult autorelease];
            }
        }

        // All temperatures tried; return the best result.
        if (bestResult) {
            return [bestResult autorelease];
        }

        MWSetError(error, MWErrorCodeGenerateFailed, @"Generate produced no results");
        return nil;

    } catch (const std::exception& e) {
        MWSetError(error, MWErrorCodeGenerateFailed,
                   [NSString stringWithFormat:@"Generate failed: %s", e.what()]);
        return nil;
    } catch (...) {
        MWSetError(error, MWErrorCodeGenerateFailed,
                   @"Generate failed: unknown exception");
        return nil;
    }
}

// ── Segment Splitting ────────────────────────────────────────────────────────

- (NSArray<MWSegmentInfo *> *)splitSegmentsByTimestamps:(NSArray<NSNumber *> *)tokens
                                            timeOffset:(float)timeOffset
                                           segmentSize:(NSUInteger)segmentSize
                                       segmentDuration:(float)segmentDuration
                                                  seek:(NSUInteger)seek
                                               outSeek:(NSUInteger *)outSeek
                                outSingleTimestampEnding:(BOOL *)outSingleTimestampEnding {
    NSUInteger tsBegin = _tokenizer.timestampBegin;
    NSUInteger count = [tokens count];

    // Detect single_timestamp_ending:
    // len(tokens) >= 2 and tokens[-2] < timestampBegin <= tokens[-1]
    BOOL singleTimestampEnding = NO;
    if (count >= 2) {
        NSUInteger lastToken = [[tokens objectAtIndex:count - 1] unsignedIntegerValue];
        NSUInteger secondLast = [[tokens objectAtIndex:count - 2] unsignedIntegerValue];
        if (secondLast < tsBegin && lastToken >= tsBegin) {
            singleTimestampEnding = YES;
        }
    }

    // Find consecutive_timestamps: indices where both token[i] and token[i-1] >= timestampBegin
    NSMutableArray<NSNumber *> *consecutiveTimestamps = [[NSMutableArray alloc] init];
    for (NSUInteger i = 1; i < count; i++) {
        NSUInteger cur = [[tokens objectAtIndex:i] unsignedIntegerValue];
        NSUInteger prev = [[tokens objectAtIndex:i - 1] unsignedIntegerValue];
        if (cur >= tsBegin && prev >= tsBegin) {
            [consecutiveTimestamps addObject:@(i)];
        }
    }

    NSMutableArray<MWSegmentInfo *> *currentSegments = [[NSMutableArray alloc] init];

    if ([consecutiveTimestamps count] > 0) {
        // Build slices array
        NSMutableArray<NSNumber *> *slices = [consecutiveTimestamps mutableCopy];
        if (singleTimestampEnding) {
            [slices addObject:@(count)];
        }

        NSUInteger lastSlice = 0;
        for (NSNumber *sliceNum in slices) {
            NSUInteger currentSlice = [sliceNum unsignedIntegerValue];

            // sliced_tokens = tokens[lastSlice:currentSlice]
            NSRange range = NSMakeRange(lastSlice, currentSlice - lastSlice);
            NSArray<NSNumber *> *slicedTokens = [tokens subarrayWithRange:range];

            if ([slicedTokens count] == 0) {
                lastSlice = currentSlice;
                continue;
            }

            NSUInteger startPos = [[slicedTokens firstObject] unsignedIntegerValue] - tsBegin;
            NSUInteger endPos = [[slicedTokens lastObject] unsignedIntegerValue] - tsBegin;
            float startTime = timeOffset + (float)startPos * _timePrecision;
            float endTime = timeOffset + (float)endPos * _timePrecision;

            MWSegmentInfo *seg = [[MWSegmentInfo alloc] initWithSeek:seek
                                                           startTime:startTime
                                                             endTime:endTime
                                                              tokens:slicedTokens];
            [currentSegments addObject:seg];
            [seg release];

            lastSlice = currentSlice;
        }

        if (singleTimestampEnding) {
            seek += segmentSize;
        } else {
            // last_timestamp_position = tokens[last_slice - 1] - timestampBegin
            NSUInteger lastTimestampPos = [[tokens objectAtIndex:lastSlice - 1] unsignedIntegerValue] - tsBegin;
            seek += lastTimestampPos * _inputStride;
        }

        [slices release];
    } else {
        // No consecutive timestamps
        float duration = segmentDuration;

        // Find all timestamp tokens
        NSMutableArray<NSNumber *> *timestamps = [[NSMutableArray alloc] init];
        for (NSNumber *tok in tokens) {
            if ([tok unsignedIntegerValue] >= tsBegin) {
                [timestamps addObject:tok];
            }
        }

        if ([timestamps count] > 0 &&
            [[timestamps lastObject] unsignedIntegerValue] != tsBegin) {
            NSUInteger lastTimestampPos = [[timestamps lastObject] unsignedIntegerValue] - tsBegin;
            duration = (float)lastTimestampPos * _timePrecision;
        }

        MWSegmentInfo *seg = [[MWSegmentInfo alloc] initWithSeek:seek
                                                       startTime:timeOffset
                                                         endTime:timeOffset + duration
                                                          tokens:tokens];
        [currentSegments addObject:seg];
        [seg release];

        [timestamps release];
        seek += segmentSize;
    }

    [consecutiveTimestamps release];

    if (outSeek) *outSeek = seek;
    if (outSingleTimestampEnding) *outSingleTimestampEnding = singleTimestampEnding;

    NSArray<MWSegmentInfo *> *result = [[currentSegments copy] autorelease];
    [currentSegments release];
    return result;
}

// ── Mel slicing helper ───────────────────────────────────────────────────────

/// Extract a sub-range of mel frames from a full mel spectrogram.
/// fullMel is nMels x totalFrames, row-major. Returns nMels x numFrames.
/// If startFrame + numFrames > totalFrames, copies what's available and zero-pads.
static NSData *sliceMel(NSData *fullMel, NSUInteger nMels, NSUInteger totalFrames,
                        NSUInteger startFrame, NSUInteger numFrames) {
    NSMutableData *slice = [NSMutableData dataWithLength:nMels * numFrames * sizeof(float)];
    const float *src = (const float *)[fullMel bytes];
    float *dst = (float *)[slice mutableBytes];
    NSUInteger copyFrames = (startFrame + numFrames <= totalFrames)
                            ? numFrames : (totalFrames > startFrame ? totalFrames - startFrame : 0);
    for (NSUInteger row = 0; row < nMels; row++) {
        if (copyFrames > 0) {
            memcpy(dst + row * numFrames,
                   src + row * totalFrames + startFrame,
                   copyFrames * sizeof(float));
        }
    }
    return slice;
}

// ── Transcription ────────────────────────────────────────────────────────────

/// Helper to read an option from the dictionary with a default value.
static NSUInteger optUInt(NSDictionary *opts, NSString *key, NSUInteger dflt) {
    NSNumber *val = opts[key];
    return val ? [val unsignedIntegerValue] : dflt;
}
static float optFloat(NSDictionary *opts, NSString *key, float dflt) {
    NSNumber *val = opts[key];
    return val ? [val floatValue] : dflt;
}
static BOOL optBool(NSDictionary *opts, NSString *key, BOOL dflt) {
    NSNumber *val = opts[key];
    return val ? [val boolValue] : dflt;
}
static NSString *optString(NSDictionary *opts, NSString *key) {
    NSString *val = opts[key];
    return ([val isKindOfClass:[NSString class]] && [val length] > 0) ? val : nil;
}

- (nullable NSArray<MWTranscriptionSegment *> *)transcribeURL:(NSURL *)url
                                                     language:(nullable NSString *)language
                                                         task:(NSString *)task
                                                      options:(nullable NSDictionary *)options
                                               segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *segment, BOOL *stop))segmentHandler
                                                         info:(MWTranscriptionInfo * _Nullable * _Nullable)outInfo
                                                        error:(NSError **)error {
    // Decode audio file to float32 16kHz mono.
    NSError *decodeError = nil;
    NSData *audio = [MWAudioDecoder decodeAudioAtURL:url error:&decodeError];
    if (!audio) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   [NSString stringWithFormat:@"Audio decode failed: %@",
                    [decodeError localizedDescription]]);
        return nil;
    }

    return [self transcribeAudio:audio
                        language:language
                            task:task
                         options:options
                  segmentHandler:segmentHandler
                            info:outInfo
                           error:error];
}

- (nullable NSArray<MWTranscriptionSegment *> *)transcribeAudio:(NSData *)audio
                                                       language:(nullable NSString *)language
                                                           task:(NSString *)task
                                                        options:(nullable NSDictionary *)options
                                                 segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *segment, BOOL *stop))segmentHandler
                                                           info:(MWTranscriptionInfo * _Nullable * _Nullable)outInfo
                                                          error:(NSError **)error {
    if (!options) options = @{};

    // Handle empty/nil audio gracefully.
    if (!audio || [audio length] == 0) {
        if (outInfo) {
            *outInfo = [[[MWTranscriptionInfo alloc] initWithLanguage:(language ?: @"en")
                                                 languageProbability:0.0f
                                                            duration:0.0f] autorelease];
        }
        return @[];
    }

    NSUInteger totalSamples = [audio length] / sizeof(float);
    float audioDuration = (float)totalSamples / (float)kMWTargetSampleRate;

    // ── Parse options ────────────────────────────────────────────────────────
    NSUInteger beamSize = optUInt(options, @"beamSize", 5);
    NSUInteger bestOf = optUInt(options, @"bestOf", 5);
    float patience = optFloat(options, @"patience", 1.0f);
    float lengthPenalty = optFloat(options, @"lengthPenalty", 1.0f);
    float repetitionPenalty = optFloat(options, @"repetitionPenalty", 1.0f);
    NSUInteger noRepeatNgramSize = optUInt(options, @"noRepeatNgramSize", 0);
    float compressionRatioThreshold = optFloat(options, @"compressionRatioThreshold", 2.4f);
    float logProbThreshold = optFloat(options, @"logProbThreshold", -1.0f);
    float noSpeechThreshold = optFloat(options, @"noSpeechThreshold", 0.6f);
    BOOL conditionOnPreviousText = optBool(options, @"conditionOnPreviousText", YES);
    float promptResetOnTemperature = optFloat(options, @"promptResetOnTemperature", 0.5f);
    BOOL withoutTimestamps = optBool(options, @"withoutTimestamps", NO);
    BOOL suppressBlank = optBool(options, @"suppressBlank", YES);
    float maxInitialTimestamp = optFloat(options, @"maxInitialTimestamp", 1.0f);
    NSString *initialPrompt = optString(options, @"initialPrompt");
    NSString *prefix = optString(options, @"prefix");
    NSString *hotwords = optString(options, @"hotwords");

    NSArray<NSNumber *> *temperatures = options[@"temperatures"];
    if (!temperatures || ![temperatures isKindOfClass:[NSArray class]] || [temperatures count] == 0) {
        temperatures = @[@0.0, @0.2, @0.4, @0.6, @0.8, @1.0];
    }

    NSArray<NSNumber *> *userSuppressTokens = options[@"suppressTokens"];
    if (!userSuppressTokens || ![userSuppressTokens isKindOfClass:[NSArray class]]) {
        userSuppressTokens = @[@(-1)];
    }

    // Parse clip_timestamps.
    NSArray<NSNumber *> *clipTimestamps = options[@"clipTimestamps"];

    // ── Step 1: Compute mel spectrogram for entire audio ─────────────────────
    NSError *melError = nil;
    NSData *fullMel = [_featureExtractor computeMelSpectrogramFromAudio:audio error:&melError];
    if (!fullMel) {
        MWSetError(error, MWErrorCodeTranscribeFailed,
                   [NSString stringWithFormat:@"Mel computation failed: %@",
                    [melError localizedDescription]]);
        return nil;
    }
    NSUInteger nMels = self.nMels;
    NSUInteger totalFrames = _featureExtractor.lastFrameCount;
    NSUInteger segmentSize = kMWDefaultChunkFrames;  // 3000 frames = 30s
    float segmentDuration = (float)segmentSize / (float)_framesPerSecond;

    // ── Step 2: Detect language ──────────────────────────────────────────────
    NSString *detectedLanguage = language;
    float languageProb = 1.0f;

    if (!detectedLanguage && self.isMultilingual) {
        NSString *detected = nil;
        float prob = 0.0f;
        NSError *langError = nil;
        BOOL ok = [self detectLanguageFromAudio:audio
                                       segments:1
                                      threshold:0.5f
                               detectedLanguage:&detected
                                    probability:&prob
                               allLanguageProbs:nil
                                          error:&langError];
        if (ok && detected) {
            detectedLanguage = detected;
            languageProb = prob;
        } else {
            detectedLanguage = @"en";
            languageProb = 0.0f;
        }
    } else if (!detectedLanguage) {
        detectedLanguage = @"en";
        languageProb = 1.0f;
    }

    NSLog(@"[MetalWhisper] Detected language: %@ (%.2f)", detectedLanguage, languageProb);

    // ── Step 3: Create tokenizer for the detected language/task ──────────────
    // Check if the existing tokenizer matches; if not, create a new one.
    MWTokenizer *loopTokenizer = _tokenizer;
    BOOL createdNewTokenizer = NO;

    if (![detectedLanguage isEqualToString:_tokenizer.languageCode] ||
        ![task isEqualToString:@"transcribe"]) {
        NSError *tokErr = nil;
        MWTokenizer *newTok = [[MWTokenizer alloc] initWithModelPath:_modelPath
                                                        multilingual:self.isMultilingual
                                                                task:task
                                                            language:detectedLanguage
                                                               error:&tokErr];
        if (newTok) {
            loopTokenizer = newTok;
            createdNewTokenizer = YES;
        }
        // If creation fails, fall back to existing tokenizer.
    }

    // ── Step 4: Build suppressed tokens ──────────────────────────────────────
    NSArray<NSNumber *> *builtSuppressTokens = [self buildSuppressedTokens:userSuppressTokens];

    // ── Step 5: Handle initial_prompt → prepend tokens ───────────────────────
    NSMutableArray<NSNumber *> *allTokens = [[NSMutableArray alloc] init];
    if (initialPrompt && [initialPrompt length] > 0) {
        NSString *prefixed = [@" " stringByAppendingString:initialPrompt];
        NSArray<NSNumber *> *promptTokens = [loopTokenizer encode:prefixed];
        [allTokens addObjectsFromArray:promptTokens];
    }
    NSInteger promptResetSince = 0;

    // ── Step 6: Parse clip_timestamps → seek_clips ───────────────────────────
    // Each pair of timestamps defines a clip to transcribe.
    // Default: single clip [0, totalFrames].
    NSMutableArray<NSNumber *> *seekClips = [[NSMutableArray alloc] init];

    if (clipTimestamps && [clipTimestamps count] > 0) {
        // Convert seconds to mel frames.
        for (NSNumber *ts in clipTimestamps) {
            float secs = [ts floatValue];
            NSUInteger frame = (NSUInteger)(secs * (float)_framesPerSecond);
            if (frame > totalFrames) frame = totalFrames;
            [seekClips addObject:@(frame)];
        }
        // Ensure even number (pairs). If odd, add totalFrames at end.
        if ([seekClips count] % 2 != 0) {
            [seekClips addObject:@(totalFrames)];
        }
    } else {
        [seekClips addObject:@(0)];
        [seekClips addObject:@(totalFrames)];
    }

    // ── Step 7: Main decode loop ─────────────────────────────────────────────
    NSMutableArray<MWTranscriptionSegment *> *segments = [[NSMutableArray alloc] init];
    NSUInteger segmentIndex = 0;
    BOOL stopped = NO;

    for (NSUInteger clipIdx = 0; clipIdx + 1 < [seekClips count]; clipIdx += 2) {
        NSUInteger seek = [[seekClips objectAtIndex:clipIdx] unsignedIntegerValue];
        NSUInteger clipEnd = [[seekClips objectAtIndex:clipIdx + 1] unsignedIntegerValue];

        while (seek < clipEnd && !stopped) {
            NSUInteger previousSeek = seek;
            float timeOffset = (float)seek / (float)_framesPerSecond;

            // a) Extract mel segment at seek position.
            NSUInteger framesAvailable = (seek < totalFrames) ? (totalFrames - seek) : 0;
            NSUInteger framesToExtract = (framesAvailable < segmentSize) ? framesAvailable : segmentSize;

            NSData *segmentMel = nil;
            if (framesToExtract == 0) {
                // Beyond audio — produce silence.
                segmentMel = [NSMutableData dataWithLength:nMels * segmentSize * sizeof(float)];
            } else {
                segmentMel = sliceMel(fullMel, nMels, totalFrames, seek, framesToExtract);
            }

            // b) Pad/trim to 3000 frames.
            segmentMel = padOrTrimMel(segmentMel, nMels, framesToExtract, segmentSize);

            // c) Encode mel.
            NSError *encError = nil;
            NSData *encoderOutput = [self encodeFeatures:segmentMel nFrames:segmentSize error:&encError];
            if (!encoderOutput) {
                NSLog(@"[MetalWhisper] Encode failed at seek=%lu: %@",
                      (unsigned long)seek, [encError localizedDescription]);
                seek += segmentSize;  // Skip this chunk.
                continue;
            }

            // d) Build prompt (with previous tokens if conditionOnPreviousText).
            NSArray<NSNumber *> *previousTokens = nil;
            if (conditionOnPreviousText && [allTokens count] > 0) {
                // Use tokens since last prompt reset.
                NSUInteger tokCount = [allTokens count];
                if (promptResetSince >= 0 && (NSUInteger)promptResetSince < tokCount) {
                    previousTokens = [allTokens subarrayWithRange:
                        NSMakeRange((NSUInteger)promptResetSince, tokCount - (NSUInteger)promptResetSince)];
                } else {
                    previousTokens = allTokens;
                }
            }

            NSArray<NSNumber *> *prompt = [self buildPromptWithPreviousTokens:previousTokens
                                                            withoutTimestamps:withoutTimestamps
                                                                       prefix:prefix
                                                                     hotwords:hotwords];

            // e) Generate with fallback.
            NSError *genError = nil;
            MWGenerateResult *result = [self generateWithEncoderOutput:encoderOutput
                                                                prompt:prompt
                                                          temperatures:temperatures
                                                              beamSize:beamSize
                                                              patience:patience
                                                                bestOf:bestOf
                                                         lengthPenalty:lengthPenalty
                                                     repetitionPenalty:repetitionPenalty
                                                     noRepeatNgramSize:noRepeatNgramSize
                                               compressionRatioThreshold:compressionRatioThreshold
                                                       logProbThreshold:logProbThreshold
                                                     noSpeechThreshold:noSpeechThreshold
                                                         suppressTokens:builtSuppressTokens
                                                          suppressBlank:suppressBlank
                                                    maxInitialTimestamp:maxInitialTimestamp
                                                                  error:&genError];
            if (!result) {
                NSLog(@"[MetalWhisper] Generate failed at seek=%lu: %@",
                      (unsigned long)seek, [genError localizedDescription]);
                seek += segmentSize;
                continue;
            }

            // f) Check no-speech → skip if silent.
            BOOL shouldSkip = NO;
            if (noSpeechThreshold >= 0.0f && result.noSpeechProb > noSpeechThreshold) {
                // If logProbThreshold is active and avgLogProb is below it, skip.
                if (!isnan(logProbThreshold) && result.avgLogProb < logProbThreshold) {
                    shouldSkip = YES;
                }
            }

            if (shouldSkip) {
                seek += segmentSize;
                continue;
            }

            // g) Split by timestamps.
            NSUInteger outSeek = seek;
            BOOL singleTimestampEnding = NO;
            NSArray<MWSegmentInfo *> *splitSegs = [self splitSegmentsByTimestamps:result.tokenIDs
                                                                      timeOffset:timeOffset
                                                                     segmentSize:segmentSize
                                                                 segmentDuration:segmentDuration
                                                                            seek:seek
                                                                         outSeek:&outSeek
                                                          outSingleTimestampEnding:&singleTimestampEnding];
            seek = outSeek;

            // h) For each segment: decode text, create MWTranscriptionSegment, call handler.
            for (MWSegmentInfo *seg in splitSegs) {
                if (stopped) break;

                // Filter out timestamp tokens for text decoding.
                NSUInteger tsBegin = loopTokenizer.timestampBegin;
                NSUInteger eot = loopTokenizer.eot;
                NSMutableArray<NSNumber *> *textTokens = [[NSMutableArray alloc] init];
                for (NSNumber *tok in seg.tokens) {
                    NSUInteger t = [tok unsignedIntegerValue];
                    if (t < tsBegin && t != eot) {
                        [textTokens addObject:tok];
                    }
                }

                NSString *segText = [loopTokenizer decode:textTokens];
                [textTokens release];

                // Clamp end time to audio duration.
                float endTime = seg.endTime;
                if (endTime > audioDuration) endTime = audioDuration;

                MWTranscriptionSegment *transSeg = [[MWTranscriptionSegment alloc]
                    initWithSegmentId:segmentIndex
                                 seek:seg.seek
                                start:seg.startTime
                                  end:endTime
                                 text:segText
                               tokens:seg.tokens
                          temperature:result.temperature
                           avgLogProb:result.avgLogProb
                     compressionRatio:result.compressionRatio
                        noSpeechProb:result.noSpeechProb];

                [segments addObject:transSeg];

                if (segmentHandler) {
                    BOOL stop = NO;
                    segmentHandler(transSeg, &stop);
                    if (stop) stopped = YES;
                }

                [transSeg release];
                segmentIndex++;
            }

            // i) Update allTokens and handle prompt reset.
            [allTokens addObjectsFromArray:result.tokenIDs];

            if (result.temperature >= promptResetOnTemperature) {
                promptResetSince = (NSInteger)[allTokens count];
            }

            // j) Infinite loop protection: if seek didn't advance, force-advance.
            if (seek <= previousSeek) {
                seek = previousSeek + segmentSize;
            }
        }

        if (stopped) break;
    }

    // ── Build output ─────────────────────────────────────────────────────────
    if (outInfo) {
        *outInfo = [[[MWTranscriptionInfo alloc] initWithLanguage:detectedLanguage
                                             languageProbability:languageProb
                                                        duration:audioDuration] autorelease];
    }

    NSArray<MWTranscriptionSegment *> *result = [[segments copy] autorelease];
    [segments release];
    [allTokens release];
    [seekClips release];
    if (createdNewTokenizer) {
        [loopTokenizer release];
    }

    return result;
}

// ── Silence encode test ─────────────────────────────────────────────────────

- (nullable NSString *)encodeSilenceTestWithError:(NSError **)error {
    try {
        const auto n_mels = static_cast<ctranslate2::dim_t>(_whisper->n_mels());

        // Zero-filled mel spectrogram: [1, n_mels, chunk_frames] (30s of silence).
        ctranslate2::StorageView features(
            {1, n_mels, kMWDefaultChunkFrames},
            0.0f,
            ctranslate2::Device::CPU
        );

        auto future = _whisper->encode(features, /*to_cpu=*/true);
        ctranslate2::StorageView output = future.get();

        // Build shape string using std::string (RAII -- no leak on exception).
        const auto& shape = output.shape();
        std::string shapeStr = "[";
        for (size_t i = 0; i < shape.size(); ++i) {
            if (i > 0) shapeStr += ", ";
            shapeStr += std::to_string(shape[i]);
        }
        shapeStr += "]";

        return [NSString stringWithUTF8String:shapeStr.c_str()];

    } catch (const std::exception& e) {
        MWSetError(error, MWErrorCodeEncodeFailed,
                   [NSString stringWithFormat:@"Encode failed: %s", e.what()]);
        return nil;
    }
}

// ── Manual memory management (no ARC) ───────────────────────────────────────

- (void)dealloc {
    _whisper.reset();
    [_modelPath release];
    [_featureExtractor release];
    [_tokenizer release];
    [_supportedLanguages release];
    [_suppressTokens release];
    [_suppressTokensAtBegin release];
    [super dealloc];
}

@end
