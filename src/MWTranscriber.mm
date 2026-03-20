#import "MWTranscriber.h"
#import "MWAudioDecoder.h"
#import "MWConstants.h"
#import "MWHelpers.h"
#import "MWVoiceActivityDetector.h"

#include <memory>
#include <string>
#include <vector>
#include <cmath>

#include <ctranslate2/models/whisper.h>
#include <ctranslate2/storage_view.h>
#include <ctranslate2/devices.h>
#include <ctranslate2/types.h>

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

// ── Private ivar block ──────────────────────────────────────────────────────

@implementation MWTranscriber {
    std::unique_ptr<ctranslate2::models::Whisper> _whisper;
    std::unique_ptr<ctranslate2::models::Whisper> _whisperCPU;  // CPU pool for align()

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

        MWLog(@"[MetalWhisper] Model loaded: multilingual=%d  n_mels=%zu  compute_type=%s",
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
    NSDictionary *preprocessorConfig = MWLoadJSONFromPath(preprocessorPath, nil);
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
    NSDictionary *config = MWLoadJSONFromPath(configPath, nil);

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
        NSArray<NSString *> *allLangs = MWWhisperLanguageCodes();
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

// ── Encoding ────────────────────────────────────────────────────────────────

- (nullable NSData *)encodeFeatures:(NSData *)melSpectrogram
                            nFrames:(NSUInteger)nFrames
                              error:(NSError **)error {
    try {
        if (nFrames == 0) {
            MWSetError(error, MWErrorCodeEncodeFailed, @"nFrames must be > 0");
            return nil;
        }
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

        // Copy mel data into a vector to avoid const_cast on NSData's immutable bytes.
        const float *srcPtr = (const float *)[melSpectrogram bytes];
        NSUInteger totalElements = nMels * nFrames;
        std::vector<float> melCopy(srcPtr, srcPtr + totalElements);
        ctranslate2::StorageView features(
            {1, (ctranslate2::dim_t)nMels, (ctranslate2::dim_t)nFrames},
            melCopy.data(),
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
        size_t outElements = 1;
        for (auto dim : shape) outElements *= dim;

        return [NSData dataWithBytes:output.data<float>()
                              length:outElements * sizeof(float)];

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
    NSMutableDictionary<NSString *, NSNumber *> *langVotes = nil;
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
        NSUInteger fullFrames = 0;
        NSData *fullMel = [_featureExtractor computeMelSpectrogramFromAudio:limitedAudio
                                                                frameCount:&fullFrames
                                                                     error:&melError];
        if (!fullMel) {
            MWSetError(error, MWErrorCodeLanguageDetectionFailed,
                       [NSString stringWithFormat:@"Mel computation failed: %@",
                        [melError localizedDescription]]);
            return NO;
        }

        // Track per-segment top language for majority vote.
        langVotes = [[NSMutableDictionary alloc] init];
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
                segmentMel = MWPadOrTrimMel(subMel, nMels, availableFrames, targetFrames);
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
            // The encoded output shape is [1, kMWEncoderOutputFrames, d_model].
            NSUInteger encodedElements = [encoded length] / sizeof(float);
            NSUInteger dModel = encodedElements / kMWEncoderOutputFrames;
            if (dModel == 0) {
                MWSetError(error, MWErrorCodeLanguageDetectionFailed,
                           [NSString stringWithFormat:@"Invalid encoder output: dModel=0 (elements=%lu)",
                            (unsigned long)encodedElements]);
                [langVotes release];
                return NO;
            }

            // Copy encoded data to avoid const_cast on NSData's immutable bytes.
            const float *encSrcPtr = (const float *)[encoded bytes];
            std::vector<float> encCopy(encSrcPtr, encSrcPtr + encodedElements);
            ctranslate2::StorageView encView(
                {1, (ctranslate2::dim_t)kMWEncoderOutputFrames, (ctranslate2::dim_t)dModel},
                encCopy.data(),
                ctranslate2::Device::CPU
            );

            auto futures = _whisper->detect_language(encView);
            auto results = futures[0].get();

            // Parse results: vector of (token_string, probability).
            // Token strings look like "<|en|>", "<|zh|>", etc.
            NSMutableArray<NSDictionary<NSString *, NSNumber *> *> *probs =
                [NSMutableArray arrayWithCapacity:results.size()];

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
        [langVotes release];
        MWSetError(error, MWErrorCodeLanguageDetectionFailed,
                   [NSString stringWithFormat:@"Language detection failed: %s", e.what()]);
        return NO;
    } catch (...) {
        [langVotes release];
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
        // Also merge model's suppress_ids from config.json
        for (NSNumber *t in _suppressTokens) {
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
    MWGenerateResult *bestResult = nil;
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
        NSUInteger dModel = encodedElements / kMWEncoderOutputFrames;  // shape [1, kMWEncoderOutputFrames, d_model]
        if (dModel == 0) {
            MWSetError(error, MWErrorCodeGenerateFailed,
                       [NSString stringWithFormat:@"Invalid encoder output: dModel=0 (elements=%lu)",
                        (unsigned long)encodedElements]);
            return nil;
        }

        // Copy encoder output to avoid const_cast on NSData's immutable bytes.
        const float *encSrcPtr = (const float *)[encoderOutput bytes];
        std::vector<float> encCopy(encSrcPtr, encSrcPtr + encodedElements);
        ctranslate2::StorageView encView(
            {1, (ctranslate2::dim_t)kMWEncoderOutputFrames, (ctranslate2::dim_t)dModel},
            encCopy.data(),
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
            float compressionRatio = MWGetCompressionRatio(text);

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
        [bestResult release];
        MWSetError(error, MWErrorCodeGenerateFailed,
                   [NSString stringWithFormat:@"Generate failed: %s", e.what()]);
        return nil;
    } catch (...) {
        [bestResult release];
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

            NSUInteger startVal = [[slicedTokens firstObject] unsignedIntegerValue];
            NSUInteger startPos = (startVal >= tsBegin) ? (startVal - tsBegin) : 0;
            NSUInteger endVal = [[slicedTokens lastObject] unsignedIntegerValue];
            NSUInteger endPos = (endVal >= tsBegin) ? (endVal - tsBegin) : 0;
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
            NSUInteger lastTsVal = [[tokens objectAtIndex:lastSlice - 1] unsignedIntegerValue];
            NSUInteger lastTimestampPos = (lastTsVal >= tsBegin) ? (lastTsVal - tsBegin) : 0;
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
            NSUInteger lastTsTokenVal = [[timestamps lastObject] unsignedIntegerValue];
            NSUInteger lastTimestampPos = (lastTsTokenVal >= tsBegin) ? (lastTsTokenVal - tsBegin) : 0;
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

// ── Word-Level Timestamp: findAlignment ──────────────────────────────────────

/// Find word-level alignment for text tokens using cross-attention DTW.
/// Returns an array of alignment dictionaries per batch element.
/// Each alignment dict has keys: word (NSString*), tokens (NSArray<NSNumber*>*),
/// start (float), end (float), probability (float).
- (NSArray<NSArray<NSDictionary *> *> *)findAlignmentWithTokenizer:(MWTokenizer *)tokenizer
                                                        textTokens:(NSArray<NSArray<NSNumber *> *> *)textTokensBatch
                                                     encoderOutput:(NSData *)encoderOutput
                                                         numFrames:(NSUInteger)numFrames
                                                medianFilterWidth:(NSUInteger)medianFilterWidth {
    NSMutableArray<NSArray<NSDictionary *> *> *returnList = nil;
    try {
        // Build CT2 StorageView for encoder output.
        NSUInteger encodedElements = [encoderOutput length] / sizeof(float);
        NSUInteger dModel = encodedElements / kMWEncoderOutputFrames;
        if (dModel == 0) {
            MWLog(@"[MetalWhisper] findAlignment: invalid encoder output, dModel=0 (elements=%lu)",
                  (unsigned long)encodedElements);
            return @[];
        }

        // Copy encoder output to avoid const_cast on NSData's immutable bytes.
        const float *encSrcPtr = (const float *)[encoderOutput bytes];
        std::vector<float> encCopy(encSrcPtr, encSrcPtr + encodedElements);
        ctranslate2::StorageView encView(
            {1, (ctranslate2::dim_t)kMWEncoderOutputFrames, (ctranslate2::dim_t)dModel},
            encCopy.data(),
            ctranslate2::Device::CPU
        );

        // Build start_sequence from tokenizer's sotSequence.
        std::vector<size_t> startSeq;
        for (NSNumber *tok in tokenizer.sotSequence) {
            startSeq.push_back([tok unsignedLongValue]);
        }

        returnList = [[NSMutableArray alloc] init];

        // Call align one at a time since the pool derives batch_size from features.dim(0)=1.
        for (NSUInteger batchIdx = 0; batchIdx < [textTokensBatch count]; batchIdx++) {
            NSArray<NSNumber *> *textToks = textTokensBatch[batchIdx];

            // Skip empty token sequences.
            if ([textToks count] == 0) {
                [returnList addObject:@[]];
                continue;
            }

            // Build text_tokens for this single element.
            std::vector<size_t> toks;
            for (NSNumber *tok in textToks) {
                toks.push_back([tok unsignedLongValue]);
            }
            std::vector<std::vector<size_t>> textTokensVec = {toks};
            std::vector<size_t> numFramesVec = {numFrames};

            // Call CT2 align on CPU to avoid MPS LayerNorm limitations
            // with non-iterative decoder execution. Thread-safe lazy init.
            @synchronized (self) {
                if (!_whisperCPU) {
                    const std::string path = [_modelPath UTF8String];
                    _whisperCPU = std::make_unique<ctranslate2::models::Whisper>(
                        path,
                        ctranslate2::Device::CPU,
                        ctranslate2::ComputeType::FLOAT32,
                        std::vector<int>{0},
                        false
                    );
                }
            }

            auto futures = _whisperCPU->align(encView, startSeq, textTokensVec, numFramesVec,
                                              (ctranslate2::dim_t)medianFilterWidth);

            if (futures.empty()) {
                [returnList addObject:@[]];
                continue;
            }

            auto result = futures[0].get();

            const auto& alignments = result.alignments;
            const auto& textTokenProbs = result.text_token_probs;

            if (alignments.empty()) {
                [returnList addObject:@[]];
                continue;
            }

            // Extract text_indices and time_indices.
            std::vector<int64_t> textIndices(alignments.size());
            std::vector<int64_t> timeIndices(alignments.size());
            for (size_t ai = 0; ai < alignments.size(); ai++) {
                textIndices[ai] = alignments[ai].first;
                timeIndices[ai] = alignments[ai].second;
            }

            // Split to word tokens: text_tokens + [eot].
            NSMutableArray<NSNumber *> *tokensWithEOT = [NSMutableArray arrayWithArray:textToks];
            [tokensWithEOT addObject:@(tokenizer.eot)];

            NSArray<NSString *> *words = nil;
            NSArray<NSArray<NSNumber *> *> *wordTokens = nil;
            [tokenizer splitToWordTokens:tokensWithEOT words:&words wordTokens:&wordTokens];

            if (!words || [words count] <= 1) {
                [returnList addObject:@[]];
                continue;
            }

            // Compute word boundaries from cumulative token lengths.
            // word_boundaries = np.pad(np.cumsum([len(t) for t in word_tokens[:-1]]), (1, 0))
            NSUInteger numWords = [wordTokens count];
            std::vector<NSUInteger> wordBoundaries(numWords, 0);
            // wordBoundaries[0] = 0 (from np.pad (1,0))
            NSUInteger cumLen = 0;
            for (NSUInteger wi = 0; wi + 1 < numWords; wi++) {
                cumLen += [wordTokens[wi] count];
                wordBoundaries[wi + 1] = cumLen;
            }

            if (wordBoundaries.size() <= 1) {
                [returnList addObject:@[]];
                continue;
            }

            // Compute jumps: where text_index changes.
            // jumps = np.pad(np.diff(text_indices), (1, 0), constant_values=1).astype(bool)
            std::vector<bool> jumps(textIndices.size(), false);
            jumps[0] = true;  // constant_values=1 -> true
            for (size_t ji = 1; ji < textIndices.size(); ji++) {
                jumps[ji] = (textIndices[ji] != textIndices[ji - 1]);
            }

            // jump_times = time_indices[jumps] / tokens_per_second
            std::vector<float> jumpTimes;
            for (size_t ji = 0; ji < jumps.size(); ji++) {
                if (jumps[ji]) {
                    jumpTimes.push_back((float)timeIndices[ji] / (float)_tokensPerSecond);
                }
            }

            // Extract start/end times and probabilities per word.
            NSMutableArray<NSDictionary *> *wordList = [[NSMutableArray alloc] init];

            for (NSUInteger wi = 0; wi + 1 < numWords; wi++) {
                NSUInteger startBound = wordBoundaries[wi];
                NSUInteger endBound = wordBoundaries[wi + 1];

                float startTime = 0.0f;
                float endTime = 0.0f;
                if (startBound < jumpTimes.size()) {
                    startTime = jumpTimes[startBound];
                } else if (!jumpTimes.empty()) {
                    // Fallback: use end of previous word or last known jump
                    startTime = jumpTimes.back();
                }
                if (endBound < jumpTimes.size()) {
                    endTime = jumpTimes[endBound];
                } else if (!jumpTimes.empty()) {
                    endTime = jumpTimes.back();
                }
                // Ensure start <= end
                if (startTime > endTime) {
                    startTime = endTime;
                }

                // word probability = mean(text_token_probs[startBound:endBound])
                float probSum = 0.0f;
                NSUInteger probCount = 0;
                for (NSUInteger pi = startBound; pi < endBound && pi < textTokenProbs.size(); pi++) {
                    probSum += textTokenProbs[pi];
                    probCount++;
                }
                float wordProb = (probCount > 0) ? (probSum / (float)probCount) : 0.0f;

                NSDictionary *wordDict = @{
                    @"word": words[wi],
                    @"tokens": wordTokens[wi],
                    @"start": @(startTime),
                    @"end": @(endTime),
                    @"probability": @(wordProb)
                };
                [wordList addObject:wordDict];
            }

            [returnList addObject:[[wordList copy] autorelease]];
            [wordList release];
        }

        NSArray<NSArray<NSDictionary *> *> *result = [[returnList copy] autorelease];
        [returnList release];
        return result;

    } catch (const std::exception& e) {
        [returnList release];
        MWLog(@"[MetalWhisper] findAlignment failed: %s", e.what());
        return @[];
    } catch (...) {
        [returnList release];
        MWLog(@"[MetalWhisper] findAlignment failed: unknown exception");
        return @[];
    }
}

/// Add word-level timestamps to segments.
/// segmentGroups: array of segment groups, each group is an array of segment dicts.
/// Each segment dict has keys: start, end, tokens (including timestamps).
/// Returns the last speech timestamp for seek update.
- (float)addWordTimestampsToSegments:(NSMutableArray<MWTranscriptionSegment *> *)segments
                         fromIndex:(NSUInteger)fromIndex
                     encoderOutput:(NSData *)encoderOutput
                         numFrames:(NSUInteger)numFrames
                         tokenizer:(MWTokenizer *)tokenizer
               prependPunctuations:(NSString *)prepend
                appendPunctuations:(NSString *)append
                        timeOffset:(float)timeOffset
                      segmentDuration:(float)segDuration {
    if (!segments || [segments count] <= fromIndex) return 0.0f;

    // Collect text tokens from each segment (filter out timestamp tokens).
    NSUInteger tsBegin = tokenizer.timestampBegin;
    NSUInteger eot = tokenizer.eot;
    NSMutableArray<NSArray<NSNumber *> *> *textTokensBatch = [[NSMutableArray alloc] init];

    for (NSUInteger si = fromIndex; si < [segments count]; si++) {
        MWTranscriptionSegment *seg = segments[si];
        NSMutableArray<NSNumber *> *textToks = [[NSMutableArray alloc] init];
        for (NSNumber *tok in seg.tokens) {
            NSUInteger t = [tok unsignedIntegerValue];
            if (t < tsBegin && t != eot) {
                [textToks addObject:tok];
            }
        }
        [textTokensBatch addObject:textToks];
        [textToks release];
    }

    // Call findAlignment.
    NSArray<NSArray<NSDictionary *> *> *alignments =
        [self findAlignmentWithTokenizer:tokenizer
                              textTokens:textTokensBatch
                           encoderOutput:encoderOutput
                               numFrames:numFrames
                        medianFilterWidth:7];
    [textTokensBatch release];

    if (!alignments || [alignments count] == 0) return 0.0f;

    float lastSpeechTimestamp = 0.0f;

    // Process each segment's alignment.
    for (NSUInteger ai = 0; ai < [alignments count]; ai++) {
        NSUInteger segIdx = fromIndex + ai;
        if (segIdx >= [segments count]) break;

        NSArray<NSDictionary *> *alignment = alignments[ai];
        if ([alignment count] == 0) continue;

        MWTranscriptionSegment *seg = segments[segIdx];

        // Convert to mutable dicts for punctuation merging.
        NSMutableArray<NSMutableDictionary *> *mutableAlignment = [[NSMutableArray alloc] init];
        for (NSDictionary *d in alignment) {
            [mutableAlignment addObject:[d mutableCopy]];
        }

        // Merge punctuations.
        MWMergePunctuations(mutableAlignment, prepend, append);

        // Build MWWord array, offsetting times by segment start.
        NSMutableArray<MWWord *> *words = [[NSMutableArray alloc] init];
        for (NSMutableDictionary *wd in mutableAlignment) {
            NSString *wordStr = wd[@"word"];
            if ([wordStr length] == 0) continue;  // Skip merged-away entries.

            float wStart = [wd[@"start"] floatValue] + timeOffset;
            float wEnd = [wd[@"end"] floatValue] + timeOffset;
            float wProb = [wd[@"probability"] floatValue];

            // Clamp word times to segment boundaries.
            if (wStart < seg.start) wStart = seg.start;
            if (wEnd > seg.end) wEnd = seg.end;
            if (wStart > wEnd) wStart = wEnd;

            MWWord *word = [[MWWord alloc] initWithWord:wordStr
                                                  start:wStart
                                                    end:wEnd
                                            probability:wProb];
            [words addObject:word];
            [word release];

            if (wEnd > lastSpeechTimestamp) {
                lastSpeechTimestamp = wEnd;
            }
        }

        // Replace the segment with a new one that includes words.
        MWTranscriptionSegment *newSeg = [[MWTranscriptionSegment alloc]
            initWithSegmentId:seg.segmentId
                         seek:seg.seek
                        start:seg.start
                          end:seg.end
                         text:seg.text
                       tokens:seg.tokens
                  temperature:seg.temperature
                   avgLogProb:seg.avgLogProb
             compressionRatio:seg.compressionRatio
                noSpeechProb:seg.noSpeechProb
                        words:words];
        [segments replaceObjectAtIndex:segIdx withObject:newSeg];
        [newSeg release];

        [words release];
        for (NSMutableDictionary *d in mutableAlignment) {
            [d release];
        }
        [mutableAlignment release];
    }

    return lastSpeechTimestamp;
}

// ── Transcription ────────────────────────────────────────────────────────────

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

    // Declare resources that need cleanup in @finally.
    NSMutableArray<NSNumber *> *allTokens = nil;
    NSMutableArray<NSNumber *> *seekClips = nil;
    MWTokenizer *loopTokenizer = nil;
    BOOL createdNewTokenizer = NO;
    NSMutableArray<MWTranscriptionSegment *> *segments = nil;

    @try {

    NSUInteger totalSamples = [audio length] / sizeof(float);
    float audioDuration = (float)totalSamples / (float)kMWTargetSampleRate;

    // ── Parse options ────────────────────────────────────────────────────────
    NSUInteger beamSize = MWOptUInt(options, @"beamSize", 5);
    NSUInteger bestOf = MWOptUInt(options, @"bestOf", 5);
    float patience = MWOptFloat(options, @"patience", 1.0f);
    float lengthPenalty = MWOptFloat(options, @"lengthPenalty", 1.0f);
    float repetitionPenalty = MWOptFloat(options, @"repetitionPenalty", 1.0f);
    NSUInteger noRepeatNgramSize = MWOptUInt(options, @"noRepeatNgramSize", 0);
    float compressionRatioThreshold = MWOptFloat(options, @"compressionRatioThreshold", 2.4f);
    float logProbThreshold = MWOptFloat(options, @"logProbThreshold", -1.0f);
    float noSpeechThreshold = MWOptFloat(options, @"noSpeechThreshold", 0.6f);
    BOOL conditionOnPreviousText = MWOptBool(options, @"conditionOnPreviousText", YES);
    float promptResetOnTemperature = MWOptFloat(options, @"promptResetOnTemperature", 0.5f);
    BOOL withoutTimestamps = MWOptBool(options, @"withoutTimestamps", NO);
    BOOL suppressBlank = MWOptBool(options, @"suppressBlank", YES);
    float maxInitialTimestamp = MWOptFloat(options, @"maxInitialTimestamp", 1.0f);
    NSString *initialPrompt = MWOptString(options, @"initialPrompt");
    NSString *prefix = MWOptString(options, @"prefix");
    NSString *hotwords = MWOptString(options, @"hotwords");
    BOOL wordTimestamps = MWOptBool(options, @"wordTimestamps", NO);
    float hallucinationSilenceThreshold = MWOptFloat(options, @"hallucinationSilenceThreshold", 0.0f);
    NSString *prependPunctuations = MWOptString(options, @"prependPunctuations");
    if (!prependPunctuations) {
        // "'"¿([{-
        unichar prependChars[] = {'"', '\'', 0x201C, 0xBF, '(', '[', '{', '-'};
        prependPunctuations = [NSString stringWithCharacters:prependChars
                                                      length:sizeof(prependChars)/sizeof(unichar)];
    }
    NSString *appendPunctuations = MWOptString(options, @"appendPunctuations");
    if (!appendPunctuations) {
        // "'.。,，!！?？:：")]}、
        unichar appendChars[] = {'"', '\'', '.', 0x3002, ',', 0xFF0C, '!', 0xFF01,
                                 '?', 0xFF1F, ':', 0xFF1A, 0x201D, ')', ']', '}', 0x3001};
        appendPunctuations = [NSString stringWithCharacters:appendChars
                                                     length:sizeof(appendChars)/sizeof(unichar)];
    }

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
    NSUInteger totalFrames = 0;
    NSData *fullMel = [_featureExtractor computeMelSpectrogramFromAudio:audio
                                                            frameCount:&totalFrames
                                                                 error:&melError];
    if (!fullMel) {
        MWSetError(error, MWErrorCodeTranscribeFailed,
                   [NSString stringWithFormat:@"Mel computation failed: %@",
                    [melError localizedDescription]]);
        return nil;
    }
    NSUInteger nMels = self.nMels;
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

    MWLog(@"[MetalWhisper] Detected language: %@ (%.2f)", detectedLanguage, languageProb);

    // ── Step 3: Create tokenizer for the detected language/task ──────────────
    // Check if the existing tokenizer matches; if not, create a new one.
    loopTokenizer = _tokenizer;

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

    // ── Step 5: Handle initial_prompt -> prepend tokens ───────────────────────
    allTokens = [[NSMutableArray alloc] init];
    if (initialPrompt && [initialPrompt length] > 0) {
        NSString *prefixed = [@" " stringByAppendingString:initialPrompt];
        NSArray<NSNumber *> *promptTokens = [loopTokenizer encode:prefixed];
        [allTokens addObjectsFromArray:promptTokens];
    }
    NSInteger promptResetSince = 0;

    // ── Step 6: Parse clip_timestamps -> seek_clips ───────────────────────────
    // Each pair of timestamps defines a clip to transcribe.
    // Default: single clip [0, totalFrames].
    seekClips = [[NSMutableArray alloc] init];

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
    segments = [[NSMutableArray alloc] init];
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
                // Beyond audio -- produce silence.
                segmentMel = [NSMutableData dataWithLength:nMels * segmentSize * sizeof(float)];
            } else {
                segmentMel = MWSliceMel(fullMel, nMels, totalFrames, seek, framesToExtract);
            }

            // b) Pad/trim to 3000 frames.
            segmentMel = MWPadOrTrimMel(segmentMel, nMels, framesToExtract, segmentSize);

            // c) Encode mel.
            NSError *encError = nil;
            NSData *encoderOutput = [self encodeFeatures:segmentMel nFrames:segmentSize error:&encError];
            if (!encoderOutput) {
                MWLog(@"[MetalWhisper] Encode failed at seek=%lu: %@",
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
                MWLog(@"[MetalWhisper] Generate failed at seek=%lu: %@",
                      (unsigned long)seek, [genError localizedDescription]);
                seek += segmentSize;
                continue;
            }

            // f) Check no-speech -> skip if silent.
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
                        noSpeechProb:result.noSpeechProb
                                words:nil];

                [segments addObject:transSeg];
                [transSeg release];
                segmentIndex++;
            }

            // ── Word timestamps ──────────────────────────────────────────
            if (wordTimestamps && [splitSegs count] > 0) {
                NSUInteger wordSegStart = segmentIndex - [splitSegs count];
                [self addWordTimestampsToSegments:segments
                                        fromIndex:wordSegStart
                                    encoderOutput:encoderOutput
                                        numFrames:MIN(framesAvailable, segmentSize)
                                        tokenizer:loopTokenizer
                              prependPunctuations:prependPunctuations
                               appendPunctuations:appendPunctuations
                                       timeOffset:timeOffset
                                  segmentDuration:segmentDuration];

                // Hallucination silence threshold handling.
                // Port of Python's generate_segments() hallucination filtering.
                if (hallucinationSilenceThreshold > 0.0f) {
                    float threshold = hallucinationSilenceThreshold;

                    // Helper: find next segment with words starting from a given index.
                    NSUInteger (^nextWordsSegmentIdx)(NSUInteger) = ^NSUInteger(NSUInteger fromIdx) {
                        for (NSUInteger ni = fromIdx; ni < [segments count]; ni++) {
                            MWTranscriptionSegment *ns = segments[ni];
                            if (ns.words && [ns.words count] > 0) return ni;
                        }
                        return NSNotFound;
                    };

                    // Skip leading silence before hallucination.
                    NSUInteger firstIdx = nextWordsSegmentIdx(wordSegStart);
                    if (firstIdx != NSNotFound) {
                        MWTranscriptionSegment *firstSeg = segments[firstIdx];
                        if (MWIsSegmentAnomaly(firstSeg.words)) {
                            float gap = firstSeg.start - timeOffset;
                            if (gap > threshold) {
                                seek = previousSeek + (NSUInteger)(gap * (float)_framesPerSecond);
                                // Remove all segments from wordSegStart onward.
                                while ([segments count] > wordSegStart) {
                                    [segments removeLastObject];
                                }
                                segmentIndex = wordSegStart;
                                MWLog(@"[MetalWhisper] Hallucination: skipping leading silence gap=%.2f", gap);
                                continue;
                            }
                        }
                    }

                    // Skip silence between hallucinations.
                    float halLastEnd = 0.0f; // lastSpeechTimestamp from prior context
                    BOOL halDidBreak = NO;
                    float contentDuration = segmentDuration;
                    float windowEndTime = timeOffset + segmentDuration;

                    for (NSUInteger si = wordSegStart; si < [segments count]; si++) {
                        MWTranscriptionSegment *s = segments[si];
                        if (!s.words || [s.words count] == 0) continue;

                        if (MWIsSegmentAnomaly(s.words)) {
                            // Find next segment with words after this one.
                            NSUInteger nextIdx = nextWordsSegmentIdx(si + 1);
                            float halNextStart = 0.0f;
                            BOOL nextIsAnomaly = NO;
                            if (nextIdx != NSNotFound) {
                                MWTranscriptionSegment *nextSeg = segments[nextIdx];
                                if (nextSeg.words && [nextSeg.words count] > 0) {
                                    halNextStart = [[nextSeg.words firstObject] start];
                                }
                                nextIsAnomaly = MWIsSegmentAnomaly(nextSeg.words);
                            } else {
                                halNextStart = timeOffset + segmentDuration;
                            }

                            BOOL silenceBefore = (s.start - halLastEnd > threshold
                                                  || s.start < threshold
                                                  || s.start - timeOffset < 2.0f);
                            BOOL silenceAfter = (halNextStart - s.end > threshold
                                                 || nextIsAnomaly
                                                 || windowEndTime - s.end < 2.0f);

                            if (silenceBefore && silenceAfter) {
                                seek = (NSUInteger)(fmaxf(timeOffset + 1.0f, s.start) * (float)_framesPerSecond);
                                if (contentDuration - s.end < threshold) {
                                    seek = previousSeek + segmentSize;
                                }
                                // Remove this and all following segments.
                                while ([segments count] > si) {
                                    [segments removeLastObject];
                                }
                                segmentIndex = si;
                                halDidBreak = YES;
                                MWLog(@"[MetalWhisper] Hallucination: removed anomalous segment at %.2f", s.start);
                                break;
                            }
                        }
                        halLastEnd = s.end;
                    }
                    if (halDidBreak) continue;
                }
            }

            // Call segment handler for newly added segments.
            for (NSUInteger si = segmentIndex - [splitSegs count]; si < segmentIndex && !stopped; si++) {
                if (segmentHandler) {
                    BOOL stop = NO;
                    segmentHandler(segments[si], &stop);
                    if (stop) stopped = YES;
                }
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

    // Release CPU model to free ~3GB after word timestamps are done (Fix P1).
    _whisperCPU.reset();

    NSArray<MWTranscriptionSegment *> *result = [[segments copy] autorelease];
    return result;

    } @finally {
        [segments release];
        [allTokens release];
        [seekClips release];
        if (createdNewTokenizer) {
            [loopTokenizer release];
        }
    }
}

// ── Batched Inference ─────────────────────────────────────────────────────────

- (nullable NSArray<MWTranscriptionSegment *> *)transcribeBatchedURL:(NSURL *)url
                                                            language:(nullable NSString *)language
                                                                task:(NSString *)task
                                                           batchSize:(NSUInteger)batchSize
                                                             options:(nullable NSDictionary *)options
                                                      segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *, BOOL *))segmentHandler
                                                                info:(MWTranscriptionInfo * _Nullable * _Nullable)outInfo
                                                               error:(NSError **)error {
    NSError *decodeError = nil;
    NSData *audio = [MWAudioDecoder decodeAudioAtURL:url error:&decodeError];
    if (!audio) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   [NSString stringWithFormat:@"Audio decode failed: %@",
                    [decodeError localizedDescription]]);
        return nil;
    }

    return [self transcribeBatchedAudio:audio
                               language:language
                                   task:task
                              batchSize:batchSize
                                options:options
                         segmentHandler:segmentHandler
                                   info:outInfo
                                  error:error];
}

- (nullable NSArray<MWTranscriptionSegment *> *)transcribeBatchedAudio:(NSData *)audio
                                                              language:(nullable NSString *)language
                                                                  task:(NSString *)task
                                                             batchSize:(NSUInteger)batchSize
                                                               options:(nullable NSDictionary *)options
                                                        segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *, BOOL *))segmentHandler
                                                                  info:(MWTranscriptionInfo * _Nullable * _Nullable)outInfo
                                                                 error:(NSError **)error {
    if (!options) options = @{};
    if (batchSize == 0) batchSize = 8;

    // Handle empty/nil audio gracefully.
    if (!audio || [audio length] == 0) {
        if (outInfo) {
            *outInfo = [[[MWTranscriptionInfo alloc] initWithLanguage:(language ?: @"en")
                                                 languageProbability:0.0f
                                                            duration:0.0f] autorelease];
        }
        return @[];
    }

    // Declare resources that need cleanup in @finally.
    MWTokenizer *loopTokenizer = nil;
    BOOL createdNewTokenizer = NO;
    MWVoiceActivityDetector *vad = nil;
    NSMutableArray<MWTranscriptionSegment *> *allSegments = nil;
    MWSpeechTimestampsMap *timestampMap = nil;
    NSMutableArray<NSData *> *melChunks = nil;

    @try {

    NSUInteger totalSamples = [audio length] / sizeof(float);
    float audioDuration = (float)totalSamples / (float)kMWTargetSampleRate;

    // ── Parse options ────────────────────────────────────────────────────────
    NSUInteger beamSize = MWOptUInt(options, @"beamSize", 5);
    NSUInteger bestOf = MWOptUInt(options, @"bestOf", 5);
    float patience = MWOptFloat(options, @"patience", 1.0f);
    float lengthPenalty = MWOptFloat(options, @"lengthPenalty", 1.0f);
    float repetitionPenalty = MWOptFloat(options, @"repetitionPenalty", 1.0f);
    NSUInteger noRepeatNgramSize = MWOptUInt(options, @"noRepeatNgramSize", 0);
    float noSpeechThreshold = MWOptFloat(options, @"noSpeechThreshold", 0.6f);
    BOOL withoutTimestamps = MWOptBool(options, @"withoutTimestamps", YES);  // defaults to YES for batched
    BOOL suppressBlank = MWOptBool(options, @"suppressBlank", YES);
    float maxInitialTimestamp = MWOptFloat(options, @"maxInitialTimestamp", 1.0f);
    NSString *hotwords = MWOptString(options, @"hotwords");
    BOOL wordTimestamps = MWOptBool(options, @"wordTimestamps", NO);
    NSString *prependPunctuations = MWOptString(options, @"prependPunctuations");
    if (!prependPunctuations) {
        unichar prependChars[] = {'"', '\'', 0x201C, 0xBF, '(', '[', '{', '-'};
        prependPunctuations = [NSString stringWithCharacters:prependChars
                                                      length:sizeof(prependChars)/sizeof(unichar)];
    }
    NSString *appendPunctuations = MWOptString(options, @"appendPunctuations");
    if (!appendPunctuations) {
        unichar appendChars[] = {'"', '\'', '.', 0x3002, ',', 0xFF0C, '!', 0xFF01,
                                 '?', 0xFF1F, ':', 0xFF1A, 0x201D, ')', ']', '}', 0x3001};
        appendPunctuations = [NSString stringWithCharacters:appendChars
                                                     length:sizeof(appendChars)/sizeof(unichar)];
    }

    NSArray<NSNumber *> *temperatures = options[@"temperatures"];
    if (!temperatures || ![temperatures isKindOfClass:[NSArray class]] || [temperatures count] == 0) {
        temperatures = @[@0.0, @0.2, @0.4, @0.6, @0.8, @1.0];
    }
    float temperature = [[temperatures firstObject] floatValue];  // batched uses only first temperature

    NSArray<NSNumber *> *userSuppressTokens = options[@"suppressTokens"];
    if (!userSuppressTokens || ![userSuppressTokens isKindOfClass:[NSArray class]]) {
        userSuppressTokens = @[@(-1)];
    }

    // VAD options.
    NSString *vadModelPathStr = MWOptString(options, @"vadModelPath");
    float vadThreshold = MWOptFloat(options, @"vadThreshold", 0.5f);
    NSInteger minSilenceDurationMs = (NSInteger)MWOptUInt(options, @"minSilenceDurationMs", 2000);
    float maxSpeechDurationS = MWOptFloat(options, @"maxSpeechDurationS", INFINITY);

    // ── Step 1: Run VAD ─────────────────────────────────────────────────────
    if (!vadModelPathStr) {
        // Default: look for silero_vad_v6.onnx in models/ relative to model path
        vadModelPathStr = [_modelPath stringByDeletingLastPathComponent];
        vadModelPathStr = [vadModelPathStr stringByAppendingPathComponent:@"silero_vad_v6.onnx"];
        // If not there, try project-level models/ dir
        if (![[NSFileManager defaultManager] fileExistsAtPath:vadModelPathStr]) {
            vadModelPathStr = [[_modelPath stringByDeletingLastPathComponent]
                               stringByDeletingLastPathComponent];
            vadModelPathStr = [vadModelPathStr stringByAppendingPathComponent:@"models/silero_vad_v6.onnx"];
        }
    }

    NSError *vadError = nil;
    vad = [[MWVoiceActivityDetector alloc] initWithModelPath:vadModelPathStr error:&vadError];
    if (!vad) {
        MWSetError(error, MWErrorCodeTranscribeFailed,
                   [NSString stringWithFormat:@"VAD load failed: %@",
                    [vadError localizedDescription]]);
        return nil;
    }

    MWVADOptions *vadOpts = [MWVADOptions defaults];
    vadOpts.threshold = vadThreshold;
    vadOpts.minSilenceDurationMs = minSilenceDurationMs;
    vadOpts.maxSpeechDurationS = maxSpeechDurationS;

    NSArray<NSDictionary<NSString *, NSNumber *> *> *speechTimestamps =
        [vad speechTimestamps:audio options:vadOpts error:&vadError];
    if (!speechTimestamps) {
        MWSetError(error, MWErrorCodeTranscribeFailed,
                   [NSString stringWithFormat:@"VAD speech timestamps failed: %@",
                    [vadError localizedDescription]]);
        return nil;
    }

    MWLog(@"[MetalWhisper] Batched: VAD found %lu speech segments", (unsigned long)[speechTimestamps count]);

    if ([speechTimestamps count] == 0) {
        // No speech detected
        if (outInfo) {
            *outInfo = [[[MWTranscriptionInfo alloc] initWithLanguage:(language ?: @"en")
                                                 languageProbability:0.0f
                                                            duration:audioDuration] autorelease];
        }
        return @[];
    }

    // ── Step 2: Collect chunks (max 30s each) ───────────────────────────────
    NSArray<NSData *> *speechChunks = [MWVoiceActivityDetector collectChunks:audio
                                                                     chunks:speechTimestamps
                                                                maxDuration:30.0f];

    MWLog(@"[MetalWhisper] Batched: %lu speech chunks to process", (unsigned long)[speechChunks count]);

    // Build timestamp map for restoring original times.
    timestampMap = [[MWSpeechTimestampsMap alloc] initWithChunks:speechTimestamps
                                                   samplingRate:kMWTargetSampleRate];

    // ── Step 3: Compute mel features per chunk ──────────────────────────────
    NSUInteger nMels = self.nMels;
    NSUInteger segmentSize = kMWDefaultChunkFrames;  // 3000
    melChunks = [[NSMutableArray alloc] initWithCapacity:[speechChunks count]];

    for (NSData *chunkAudio in speechChunks) {
        NSError *melError = nil;
        NSUInteger frameCount = 0;
        NSData *mel = [_featureExtractor computeMelSpectrogramFromAudio:chunkAudio
                                                            frameCount:&frameCount
                                                                 error:&melError];
        if (!mel) {
            MWLog(@"[MetalWhisper] Batched: mel computation failed for chunk, skipping");
            // Create silence mel
            mel = [NSMutableData dataWithLength:nMels * segmentSize * sizeof(float)];
            frameCount = segmentSize;
        }

        // Pad or trim to 3000 frames.
        mel = MWPadOrTrimMel(mel, nMels, frameCount, segmentSize);
        [melChunks addObject:mel];
    }

    // ── Step 4: Language detection ──────────────────────────────────────────
    NSString *detectedLanguage = language;
    float languageProb = 1.0f;

    if (!detectedLanguage && self.isMultilingual) {
        // Detect from first chunk's audio.
        NSData *firstChunkAudio = speechChunks[0];
        NSString *detected = nil;
        float prob = 0.0f;
        NSError *langError = nil;
        BOOL ok = [self detectLanguageFromAudio:firstChunkAudio
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

    MWLog(@"[MetalWhisper] Batched: language=%@ (%.2f)", detectedLanguage, languageProb);

    // ── Step 5: Create tokenizer for detected language/task ──────────────────
    loopTokenizer = _tokenizer;

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
    }

    // Build suppressed tokens.
    NSArray<NSNumber *> *builtSuppressTokens = [self buildSuppressedTokens:userSuppressTokens];

    // Build base prompt (no previous tokens for batched).
    NSArray<NSNumber *> *basePrompt = [self buildPromptWithPreviousTokens:nil
                                                        withoutTimestamps:withoutTimestamps
                                                                   prefix:nil
                                                                 hotwords:hotwords];

    // Build suppress tokens vector for CT2.
    std::vector<int> suppressVec;
    for (NSNumber *tok in builtSuppressTokens) {
        suppressVec.push_back([tok intValue]);
    }

    // Build base prompt vector.
    std::vector<size_t> basePromptVec;
    for (NSNumber *tok in basePrompt) {
        basePromptVec.push_back([tok unsignedLongValue]);
    }

    // Compute max_initial_timestamp_index.
    size_t maxInitTimestampIdx = (size_t)roundf(maxInitialTimestamp / _timePrecision);

    // ── Step 6: Process chunks in batches ───────────────────────────────────
    allSegments = [[NSMutableArray alloc] init];
    NSUInteger segmentIndex = 0;
    BOOL stopped = NO;
    NSUInteger totalChunks = [melChunks count];

    for (NSUInteger batchStart = 0; batchStart < totalChunks && !stopped; batchStart += batchSize) {
        NSUInteger batchEnd = batchStart + batchSize;
        if (batchEnd > totalChunks) batchEnd = totalChunks;
        NSUInteger B = batchEnd - batchStart;

        // a) Stack mel features into contiguous buffer [B, nMels, 3000].
        size_t chunkElements = nMels * segmentSize;
        std::vector<float> stacked(B * chunkElements, 0.0f);
        for (NSUInteger b = 0; b < B; b++) {
            NSData *melData = melChunks[batchStart + b];
            const float *src = (const float *)[melData bytes];
            memcpy(stacked.data() + b * chunkElements, src, chunkElements * sizeof(float));
        }

        // b) Encode the batch.
        ctranslate2::StorageView features(
            {(ctranslate2::dim_t)B, (ctranslate2::dim_t)nMels, (ctranslate2::dim_t)segmentSize},
            stacked.data(),
            ctranslate2::Device::CPU
        );

        ctranslate2::StorageView encoderOutput;
        try {
            auto future = _whisper->encode(features, /*to_cpu=*/true);
            encoderOutput = future.get();

            if (encoderOutput.device() != ctranslate2::Device::CPU) {
                encoderOutput = encoderOutput.to(ctranslate2::Device::CPU);
            }
            if (encoderOutput.dtype() != ctranslate2::DataType::FLOAT32) {
                encoderOutput = encoderOutput.to(ctranslate2::DataType::FLOAT32);
            }
        } catch (const std::exception& e) {
            MWLog(@"[MetalWhisper] Batched: encode failed: %s", e.what());
            continue;
        }

        // c) Build prompts (one per chunk in batch).
        std::vector<std::vector<size_t>> prompts(B, basePromptVec);

        // d) Build generate options.
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

        // e) Generate for the batch.
        std::vector<std::future<ctranslate2::models::WhisperGenerationResult>> futures;
        try {
            futures = _whisper->generate(encoderOutput, prompts, opts);
        } catch (const std::exception& e) {
            MWLog(@"[MetalWhisper] Batched: generate failed: %s", e.what());
            continue;
        }

        // Encoder output shape for extracting per-chunk slices.
        const auto& encShape = encoderOutput.shape();
        NSUInteger dModel = encShape[2];
        NSUInteger encChunkElements = kMWEncoderOutputFrames * dModel;

        // f) Process each result.
        for (NSUInteger b = 0; b < B && !stopped; b++) {
            NSUInteger chunkIdx = batchStart + b;
            NSUInteger chunkSegStart = segmentIndex;  // Track where this chunk's segments begin.

            ctranslate2::models::WhisperGenerationResult genResult;
            try {
                genResult = futures[b].get();
            } catch (const std::exception& e) {
                MWLog(@"[MetalWhisper] Batched: result[%lu] failed: %s", (unsigned long)b, e.what());
                continue;
            }

            if (genResult.sequences_ids.empty() || genResult.sequences_ids[0].empty()) {
                continue;
            }

            const auto& tokenIds = genResult.sequences_ids[0];
            NSUInteger seqLen = tokenIds.size();

            // Compute avg log prob.
            float score = genResult.has_scores() ? genResult.scores[0] : 0.0f;
            float cumLogProb = score * powf((float)seqLen, lengthPenalty);
            float avgLogProb = cumLogProb / ((float)seqLen + 1.0f);
            float noSpeechProb = genResult.no_speech_prob;

            // Build token IDs array.
            NSMutableArray<NSNumber *> *tokenIDsArr = [[NSMutableArray alloc] initWithCapacity:seqLen];
            for (size_t i = 0; i < seqLen; i++) {
                [tokenIDsArr addObject:@((NSUInteger)tokenIds[i])];
            }

            // Decode text and compression ratio.
            NSString *text = [loopTokenizer decode:tokenIDsArr];
            float compressionRatio = MWGetCompressionRatio(text);

            // Chunk timing info.
            NSUInteger chunkSamples = [speechChunks[chunkIdx] length] / sizeof(float);
            float chunkDuration = (float)chunkSamples / (float)kMWTargetSampleRate;

            // Time offset in the concatenated (filtered) audio.
            float filteredTimeOffset = 0.0f;
            for (NSUInteger ci = 0; ci < chunkIdx; ci++) {
                filteredTimeOffset += (float)([speechChunks[ci] length] / sizeof(float))
                                     / (float)kMWTargetSampleRate;
            }

            // Skip no-speech chunks.
            if (noSpeechThreshold >= 0.0f && noSpeechProb > noSpeechThreshold) {
                [tokenIDsArr release];
                continue;
            }

            if (withoutTimestamps) {
                // Single segment per chunk.
                float origStart = [timestampMap originalTimeForTime:filteredTimeOffset];
                float origEnd = [timestampMap originalTimeForTime:filteredTimeOffset + chunkDuration];
                if (origEnd > audioDuration) origEnd = audioDuration;
                if (origStart > origEnd) origStart = origEnd;

                MWTranscriptionSegment *seg = [[MWTranscriptionSegment alloc]
                    initWithSegmentId:segmentIndex
                                 seek:0
                                start:origStart
                                  end:origEnd
                                 text:text
                               tokens:tokenIDsArr
                          temperature:temperature
                           avgLogProb:avgLogProb
                     compressionRatio:compressionRatio
                        noSpeechProb:noSpeechProb
                                words:nil];
                [allSegments addObject:seg];
                [seg release];
                segmentIndex++;
            } else {
                // Split by timestamps within the chunk.
                NSUInteger outSeek = 0;
                BOOL singleTimestampEnding = NO;
                float segDur = (float)segmentSize / (float)_framesPerSecond;

                NSArray<MWSegmentInfo *> *splitSegs =
                    [self splitSegmentsByTimestamps:tokenIDsArr
                                        timeOffset:0.0f
                                       segmentSize:segmentSize
                                   segmentDuration:segDur
                                              seek:0
                                           outSeek:&outSeek
                            outSingleTimestampEnding:&singleTimestampEnding];

                for (MWSegmentInfo *seg in splitSegs) {
                    float segStart = filteredTimeOffset + seg.startTime;
                    float segEnd = filteredTimeOffset + seg.endTime;
                    if (segEnd > filteredTimeOffset + chunkDuration) {
                        segEnd = filteredTimeOffset + chunkDuration;
                    }

                    float origStart = [timestampMap originalTimeForTime:segStart];
                    float origEnd = [timestampMap originalTimeForTime:segEnd];
                    if (origEnd > audioDuration) origEnd = audioDuration;
                    if (origStart > origEnd) origStart = origEnd;

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

                    MWTranscriptionSegment *transSeg = [[MWTranscriptionSegment alloc]
                        initWithSegmentId:segmentIndex
                                     seek:0
                                    start:origStart
                                      end:origEnd
                                     text:segText
                                   tokens:seg.tokens
                              temperature:temperature
                               avgLogProb:avgLogProb
                         compressionRatio:compressionRatio
                            noSpeechProb:noSpeechProb
                                    words:nil];
                    [allSegments addObject:transSeg];
                    [transSeg release];
                    segmentIndex++;
                }
            }

            // Word timestamps for this chunk's segments.
            if (wordTimestamps && segmentIndex > chunkSegStart) {
                const float *encData = encoderOutput.data<float>();
                const float *chunkEncPtr = encData + b * encChunkElements;
                NSData *chunkEnc = [NSData dataWithBytes:chunkEncPtr
                                                  length:encChunkElements * sizeof(float)];

                NSUInteger numFrames = MIN((NSUInteger)((chunkSamples + kMWDefaultHopLength - 1) / kMWDefaultHopLength),
                                          (NSUInteger)segmentSize);

                float segDur = (float)segmentSize / (float)_framesPerSecond;
                [self addWordTimestampsToSegments:allSegments
                                        fromIndex:chunkSegStart
                                    encoderOutput:chunkEnc
                                        numFrames:numFrames
                                        tokenizer:loopTokenizer
                              prependPunctuations:prependPunctuations
                               appendPunctuations:appendPunctuations
                                       timeOffset:0.0f
                                  segmentDuration:segDur];

                // Map word timestamps from chunk-relative to original audio time.
                for (NSUInteger si = chunkSegStart; si < segmentIndex; si++) {
                    MWTranscriptionSegment *seg = allSegments[si];
                    if (!seg.words || [seg.words count] == 0) continue;

                    NSMutableArray<MWWord *> *mappedWords = [[NSMutableArray alloc] init];
                    for (MWWord *w in seg.words) {
                        float wOrigStart = [timestampMap originalTimeForTime:filteredTimeOffset + w.start];
                        float wOrigEnd = [timestampMap originalTimeForTime:filteredTimeOffset + w.end];
                        if (wOrigStart < seg.start) wOrigStart = seg.start;
                        if (wOrigEnd > seg.end) wOrigEnd = seg.end;
                        if (wOrigStart > wOrigEnd) wOrigStart = wOrigEnd;

                        MWWord *mapped = [[MWWord alloc] initWithWord:w.word
                                                                start:wOrigStart
                                                                  end:wOrigEnd
                                                          probability:w.probability];
                        [mappedWords addObject:mapped];
                        [mapped release];
                    }

                    MWTranscriptionSegment *newSeg = [[MWTranscriptionSegment alloc]
                        initWithSegmentId:seg.segmentId
                                     seek:seg.seek
                                    start:seg.start
                                      end:seg.end
                                     text:seg.text
                                   tokens:seg.tokens
                              temperature:seg.temperature
                               avgLogProb:seg.avgLogProb
                         compressionRatio:seg.compressionRatio
                            noSpeechProb:seg.noSpeechProb
                                    words:mappedWords];
                    [allSegments replaceObjectAtIndex:si withObject:newSeg];
                    [newSeg release];
                    [mappedWords release];
                }
            }

            [tokenIDsArr release];

            // Call segment handler for this chunk's segments.
            if (segmentHandler) {
                for (NSUInteger si = chunkSegStart; si < segmentIndex && !stopped; si++) {
                    BOOL stop = NO;
                    segmentHandler(allSegments[si], &stop);
                    if (stop) stopped = YES;
                }
            }
        }
    }

    // ── Build output ────────────────────────────────────────────────────────
    if (outInfo) {
        *outInfo = [[[MWTranscriptionInfo alloc] initWithLanguage:detectedLanguage
                                             languageProbability:languageProb
                                                        duration:audioDuration] autorelease];
    }

    _whisperCPU.reset();

    NSArray<MWTranscriptionSegment *> *result = [[allSegments copy] autorelease];
    return result;

    } @finally {
        [allSegments release];
        [melChunks release];
        [timestampMap release];
        [vad release];
        if (createdNewTokenizer) {
            [loopTokenizer release];
        }
    }
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
    } catch (...) {
        MWSetError(error, MWErrorCodeEncodeFailed,
                   @"Encode failed: unknown exception");
        return nil;
    }
}

// ── Manual memory management (no ARC) ───────────────────────────────────────

- (void)dealloc {
    _whisperCPU.reset();
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
