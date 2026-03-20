# MetalWhisper API Reference

Objective-C API for the MetalWhisper transcription framework. All public headers are exposed through the umbrella header `MetalWhisper.h`.

```objc
#import <MetalWhisper/MetalWhisper.h>
```

## MWTranscriber

Core transcription engine. Loads a CTranslate2 Whisper model on the Metal GPU, owns the tokenizer and feature extractor, and runs the full transcription pipeline.

### Initialization

```objc
// Default compute type (auto)
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                     error:(NSError **)error;

// Explicit compute type
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                               computeType:(MWComputeType)computeType
                                     error:(NSError **)error;
```

**MWComputeType values:**

| Value | Description |
|-------|-------------|
| `MWComputeTypeDefault` | Auto-detect (float16 on Apple Silicon) |
| `MWComputeTypeFloat32` | 32-bit floating point |
| `MWComputeTypeFloat16` | 16-bit floating point (recommended) |
| `MWComputeTypeInt8` | 8-bit integer |
| `MWComputeTypeInt8Float16` | Mixed int8/float16 |
| `MWComputeTypeInt8Float32` | Mixed int8/float32 |

### Model Properties

| Property | Type | Description |
|----------|------|-------------|
| `isMultilingual` | `BOOL` | Whether the model supports language detection |
| `nMels` | `NSUInteger` | Mel frequency bins (80 or 128) |
| `numLanguages` | `NSUInteger` | Number of supported languages (0 if not multilingual) |
| `featureExtractor` | `MWFeatureExtractor *` | Configured feature extractor |
| `tokenizer` | `MWTokenizer *` | Configured tokenizer |
| `supportedLanguages` | `NSArray<NSString *> *` | Language codes (e.g., "en", "ja", "fr") |

### Derived Constants

| Property | Type | Value | Description |
|----------|------|-------|-------------|
| `inputStride` | `NSUInteger` | 2 | Encoder downsampling factor |
| `numSamplesPerToken` | `NSUInteger` | 320 | hop_length * input_stride |
| `framesPerSecond` | `NSUInteger` | 100 | sampling_rate / hop_length |
| `tokensPerSecond` | `NSUInteger` | 50 | sampling_rate / numSamplesPerToken |
| `timePrecision` | `float` | 0.02 | Seconds per timestamp token |
| `maxLength` | `NSUInteger` | 448 | Maximum generation length |

### Transcription Methods

**Transcribe from file URL:**

```objc
- (nullable NSArray<MWTranscriptionSegment *> *)transcribeURL:(NSURL *)url
                                                     language:(nullable NSString *)language
                                                         task:(NSString *)task
                                                typedOptions:(nullable MWTranscriptionOptions *)options
                                               segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *, BOOL *))segmentHandler
                                                         info:(MWTranscriptionInfo * _Nullable * _Nullable)outInfo
                                                        error:(NSError **)error;
```

**Transcribe from float32 samples (16kHz mono):**

```objc
- (nullable NSArray<MWTranscriptionSegment *> *)transcribeAudio:(NSData *)audio
                                                       language:(nullable NSString *)language
                                                           task:(NSString *)task
                                                        options:(nullable NSDictionary *)options
                                                 segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *, BOOL *))segmentHandler
                                                           info:(MWTranscriptionInfo * _Nullable * _Nullable)outInfo
                                                          error:(NSError **)error;
```

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `url` / `audio` | Audio source (file URL or raw float32 at 16kHz) |
| `language` | ISO 639-1 code (e.g., "en"). `nil` for auto-detection |
| `task` | `@"transcribe"` or `@"translate"` (translate to English) |
| `options` | `MWTranscriptionOptions` or `NSDictionary`. `nil` for defaults |
| `segmentHandler` | Called per segment as produced. Set `*stop = YES` to abort |
| `outInfo` | Receives `MWTranscriptionInfo` with language and duration |
| `error` | Receives error on failure |

**Returns:** Array of `MWTranscriptionSegment`, or `nil` on failure.

### Batched Transcription

Uses VAD to split audio into speech chunks and processes them in parallel batches:

```objc
- (nullable NSArray<MWTranscriptionSegment *> *)transcribeBatchedURL:(NSURL *)url
                                                            language:(nullable NSString *)language
                                                                task:(NSString *)task
                                                           batchSize:(NSUInteger)batchSize
                                                             options:(nullable NSDictionary *)options
                                                      segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *, BOOL *))segmentHandler
                                                                info:(MWTranscriptionInfo * _Nullable * _Nullable)outInfo
                                                               error:(NSError **)error;
```

### Async Transcription

Runs on a background queue (QOS_CLASS_USER_INITIATED), calls completion on the main queue:

```objc
- (void)transcribeURL:(NSURL *)url
             language:(nullable NSString *)language
                 task:(NSString *)task
         typedOptions:(nullable MWTranscriptionOptions *)options
       segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *, BOOL *))segmentHandler
    completionHandler:(void (^)(NSArray<MWTranscriptionSegment *> * _Nullable,
                                MWTranscriptionInfo * _Nullable,
                                NSError * _Nullable))completionHandler;
```

Note: `segmentHandler` is called on the background queue. Dispatch to main queue for UI updates.

### Encoding and Language Detection

```objc
// Encode mel spectrogram features
- (nullable NSData *)encodeFeatures:(NSData *)melSpectrogram
                            nFrames:(NSUInteger)nFrames
                              error:(NSError **)error;

// Detect language from audio samples
- (BOOL)detectLanguageFromAudio:(NSData *)audio
                       segments:(NSUInteger)segments
                      threshold:(float)threshold
               detectedLanguage:(NSString **)detectedLanguage
                    probability:(float *)probability
               allLanguageProbs:(NSArray **)allLanguageProbs
                          error:(NSError **)error;
```

---

## MWTranscriptionOptions

Typed configuration for transcription. All properties have sensible defaults.

```objc
MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
```

### Decoding

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `beamSize` | `NSUInteger` | 5 | Beam size for beam search at temperature 0 |
| `bestOf` | `NSUInteger` | 5 | Hypotheses for sampling at temperature > 0 |
| `patience` | `float` | 1.0 | Beam search patience factor |
| `lengthPenalty` | `float` | 1.0 | Length penalty for beam search |
| `repetitionPenalty` | `float` | 1.0 | Repetition penalty |
| `noRepeatNgramSize` | `NSUInteger` | 0 | Prevent n-gram repetitions (0 = disabled) |
| `temperatures` | `NSArray<NSNumber *> *` | [0, 0.2, 0.4, 0.6, 0.8, 1.0] | Temperature fallback chain |

### Thresholds

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `compressionRatioThreshold` | `float` | 2.4 | Max compression ratio before fallback |
| `logProbThreshold` | `float` | -1.0 | Min avg log probability before fallback |
| `noSpeechThreshold` | `float` | 0.6 | No-speech probability threshold |

### Behavior

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `conditionOnPreviousText` | `BOOL` | YES | Condition on previous segment text |
| `promptResetOnTemperature` | `float` | 0.5 | Reset prompt when temperature exceeds this |
| `withoutTimestamps` | `BOOL` | NO | Suppress timestamp tokens |
| `maxInitialTimestamp` | `float` | 1.0 | Maximum initial timestamp (seconds) |
| `suppressBlank` | `BOOL` | YES | Suppress blank tokens at start |
| `suppressTokens` | `NSArray<NSNumber *> *` | @[@(-1)] | Token IDs to suppress (-1 = model defaults) |

### Word Timestamps

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `wordTimestamps` | `BOOL` | NO | Extract word-level timestamps |
| `prependPunctuations` | `NSString *` | (standard set) | Punctuation merged left |
| `appendPunctuations` | `NSString *` | (standard set) | Punctuation merged right |
| `hallucinationSilenceThreshold` | `float` | 0 | Silence threshold for hallucination filtering |

### Prompting

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `initialPrompt` | `NSString *` | nil | Initial text prompt |
| `hotwords` | `NSString *` | nil | Hotwords to bias toward |
| `prefix` | `NSString *` | nil | Text prefix for first segment |

### VAD

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `vadFilter` | `BOOL` | NO | Enable voice activity detection |
| `vadModelPath` | `NSString *` | nil | Path to Silero VAD ONNX model |

### Methods

```objc
+ (instancetype)defaults;          // Create with all defaults
- (NSDictionary *)toDictionary;    // Convert to NSDictionary form
```

`MWTranscriptionOptions` conforms to `NSCopying`.

---

## MWTranscriptionSegment

A transcription segment with timing, text, and decode metadata.

| Property | Type | Description |
|----------|------|-------------|
| `segmentId` | `NSUInteger` | Sequential segment index |
| `seek` | `NSUInteger` | Seek position in mel frames |
| `start` | `float` | Start time in seconds |
| `end` | `float` | End time in seconds |
| `text` | `NSString *` | Transcribed text |
| `tokens` | `NSArray<NSNumber *> *` | Token IDs |
| `temperature` | `float` | Temperature used for this segment |
| `avgLogProb` | `float` | Average log probability |
| `compressionRatio` | `float` | Text compression ratio |
| `noSpeechProb` | `float` | No-speech probability |
| `words` | `NSArray<MWWord *> *` | Word-level timestamps (nil if disabled) |

---

## MWWord

A single word with timing and probability.

| Property | Type | Description |
|----------|------|-------------|
| `word` | `NSString *` | The word text |
| `start` | `float` | Start time in seconds |
| `end` | `float` | End time in seconds |
| `probability` | `float` | Word probability (0.0-1.0) |

---

## MWTranscriptionInfo

Metadata about a transcription run.

| Property | Type | Description |
|----------|------|-------------|
| `language` | `NSString *` | Detected language code |
| `languageProbability` | `float` | Detection confidence (0.0-1.0) |
| `duration` | `float` | Audio duration in seconds |

---

## MWModelManager

Manages model downloading, caching, and resolution. Models are cached in `~/Library/Caches/MetalWhisper/models/`.

```objc
MWModelManager *mgr = [MWModelManager shared];
```

### Methods

```objc
// Resolve alias/path to local directory (downloads if needed)
- (nullable NSString *)resolveModel:(NSString *)sizeOrPath
                           progress:(nullable MWDownloadProgressBlock)progress
                              error:(NSError **)error;

// Check if model is cached
- (BOOL)isModelCached:(NSString *)sizeOrPath;

// List cached models (returns dicts with "name", "path", "sizeBytes")
- (NSArray<NSDictionary *> *)listCachedModels;

// Delete a cached model
- (BOOL)deleteCachedModel:(NSString *)sizeOrPath error:(NSError **)error;

// List all known aliases
+ (NSArray<NSString *> *)availableModels;

// Get HuggingFace repo ID for an alias
+ (nullable NSString *)repoIDForAlias:(NSString *)alias;
```

### Progress Callback

```objc
typedef void (^MWDownloadProgressBlock)(int64_t bytesDownloaded, int64_t totalBytes, NSString *fileName);
```

`totalBytes` is -1 if the server does not provide Content-Length.

---

## MWAudioDecoder

Stateless audio decoder. Converts audio files to 16 kHz mono float32 samples using AVFoundation.

Supported formats: WAV, MP3, M4A, FLAC, CAF, AIFF (all formats handled by AVAudioFile).

```objc
// Decode from file URL
+ (nullable NSData *)decodeAudioAtURL:(NSURL *)url error:(NSError **)error;

// Decode from in-memory data (writes to temp file internally)
+ (nullable NSData *)decodeAudioFromData:(NSData *)data error:(NSError **)error;

// Decode from AVAudioPCMBuffer (resamples and channel-mixes as needed)
+ (nullable NSData *)decodeAudioFromBuffer:(AVAudioPCMBuffer *)buffer error:(NSError **)error;

// Pad or trim to exact sample count
+ (NSData *)padOrTrimAudio:(NSData *)audio toSampleCount:(NSUInteger)sampleCount;
```

---

## MWFeatureExtractor

Computes log-mel spectrograms from raw audio using Accelerate (vDSP, vForce, BLAS). Output matches Python faster-whisper exactly.

```objc
// Standard initialization
- (nullable instancetype)initWithNMels:(NSUInteger)nMels;

// Full initialization
- (nullable instancetype)initWithNMels:(NSUInteger)nMels
                                  nFFT:(NSUInteger)nFFT
                             hopLength:(NSUInteger)hopLength
                          samplingRate:(NSUInteger)samplingRate;

// Compute mel spectrogram
- (nullable NSData *)computeMelSpectrogramFromAudio:(NSData *)audio
                                         frameCount:(NSUInteger *)outFrameCount
                                              error:(NSError **)error;
```

**Parameters:** `nMels` is 80 for standard Whisper models, 128 for large-v3 and turbo. The returned NSData contains float32 values in row-major order (nMels x nFrames).

---

## MWVoiceActivityDetector

Silero VAD for speech/silence detection. Requires an ONNX model file and ONNX Runtime.

### Initialization

```objc
- (nullable instancetype)initWithModelPath:(NSString *)modelPath error:(NSError **)error;
```

### Methods

```objc
// Get speech probabilities per 512-sample chunk
- (nullable NSArray<NSNumber *> *)speechProbabilities:(NSData *)audio error:(NSError **)error;

// Get speech timestamps (array of {"start": N, "end": N} sample indices)
- (nullable NSArray<NSDictionary<NSString *, NSNumber *> *> *)speechTimestamps:(NSData *)audio
                                                                       options:(nullable MWVADOptions *)options
                                                                         error:(NSError **)error;

// Collect speech chunks from timestamps
+ (NSArray<NSData *> *)collectChunks:(NSData *)audio
                              chunks:(NSArray<NSDictionary<NSString *, NSNumber *> *> *)chunks
                         maxDuration:(float)maxDuration;
```

### MWVADOptions

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `threshold` | `float` | 0.5 | Speech detection threshold |
| `negThreshold` | `float` | -1 (auto) | Negative threshold (auto = threshold - 0.15) |
| `minSpeechDurationMs` | `NSInteger` | 0 | Minimum speech duration (ms) |
| `maxSpeechDurationS` | `float` | INFINITY | Maximum speech duration (seconds) |
| `minSilenceDurationMs` | `NSInteger` | 2000 | Minimum silence to split segments (ms) |
| `speechPadMs` | `NSInteger` | 400 | Padding around speech segments (ms) |

### MWSpeechTimestampsMap

Helper to restore original timestamps after VAD filtering:

```objc
- (instancetype)initWithChunks:(NSArray *)chunks samplingRate:(NSUInteger)samplingRate;
- (float)originalTimeForTime:(float)time;
- (float)originalTimeForTime:(float)time chunkIndex:(NSUInteger)chunkIndex;
```

---

## Error Handling

All errors use the `MWErrorDomain` domain.

| Code | Name | Description |
|------|------|-------------|
| 1 | `MWErrorCodeModelLoadFailed` | Failed to load CTranslate2 model |
| 2 | `MWErrorCodeEncodeFailed` | Encoder failed |
| 3 | `MWErrorCodeLanguageDetectionFailed` | Language detection failed |
| 100 | `MWErrorCodeAudioDecodeFailed` | Audio decoding failed |
| 101 | `MWErrorCodeAudioFileNotFound` | Audio file not found |
| 102 | `MWErrorCodeAudioTempFileFailed` | Temp file creation failed |
| 200 | `MWErrorCodeTokenizerLoadFailed` | Tokenizer load failed |
| 300 | `MWErrorCodeConfigLoadFailed` | Config load failed |
| 400 | `MWErrorCodeGenerateFailed` | Token generation failed |
| 500 | `MWErrorCodeTranscribeFailed` | Transcription failed |

For full method signatures and documentation comments, see the header files in `src/`.
