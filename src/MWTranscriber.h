#pragma once

#import <Foundation/Foundation.h>
#import "MWFeatureExtractor.h"
#import "MWTokenizer.h"
#import "MWTranscriptionOptions.h"

NS_ASSUME_NONNULL_BEGIN

/// A single word with timing and probability from word-level timestamps.
@interface MWWord : NSObject
@property (nonatomic, readonly) NSString *word;
@property (nonatomic, readonly) float start;
@property (nonatomic, readonly) float end;
@property (nonatomic, readonly) float probability;

- (instancetype)initWithWord:(NSString *)word
                       start:(float)start
                         end:(float)end
                 probability:(float)probability;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A transcription segment with timing, text, and decode metadata.
@interface MWTranscriptionSegment : NSObject
@property (nonatomic, readonly) NSUInteger segmentId;
@property (nonatomic, readonly) NSUInteger seek;
@property (nonatomic, readonly) float start;
@property (nonatomic, readonly) float end;
@property (nonatomic, readonly) NSString *text;
@property (nonatomic, readonly) NSArray<NSNumber *> *tokens;
@property (nonatomic, readonly) float temperature;
@property (nonatomic, readonly) float avgLogProb;
@property (nonatomic, readonly) float compressionRatio;
@property (nonatomic, readonly) float noSpeechProb;
@property (nonatomic, readonly, nullable) NSArray<MWWord *> *words;

- (instancetype)initWithSegmentId:(NSUInteger)segmentId
                             seek:(NSUInteger)seek
                            start:(float)start
                              end:(float)end
                             text:(NSString *)text
                           tokens:(NSArray<NSNumber *> *)tokens
                      temperature:(float)temperature
                       avgLogProb:(float)avgLogProb
                 compressionRatio:(float)compressionRatio
                    noSpeechProb:(float)noSpeechProb
                            words:(nullable NSArray<MWWord *> *)words;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Info about the transcription run.
@interface MWTranscriptionInfo : NSObject
@property (nonatomic, readonly) NSString *language;
@property (nonatomic, readonly) float languageProbability;
@property (nonatomic, readonly) float duration;

- (instancetype)initWithLanguage:(NSString *)language
             languageProbability:(float)languageProbability
                        duration:(float)duration;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A single timed segment from the decode output.
@interface MWSegmentInfo : NSObject
@property (nonatomic, readonly) NSUInteger seek;
@property (nonatomic, readonly) float startTime;
@property (nonatomic, readonly) float endTime;
@property (nonatomic, readonly) NSArray<NSNumber *> *tokens;

- (instancetype)initWithSeek:(NSUInteger)seek
                   startTime:(float)startTime
                     endTime:(float)endTime
                      tokens:(NSArray<NSNumber *> *)tokens;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Result of a single generate-with-fallback call.
@interface MWGenerateResult : NSObject
@property (nonatomic, readonly) NSArray<NSNumber *> *tokenIDs;
@property (nonatomic, readonly) float avgLogProb;
@property (nonatomic, readonly) float temperature;
@property (nonatomic, readonly) float compressionRatio;
@property (nonatomic, readonly) float noSpeechProb;
@property (nonatomic, readonly) NSString *text;
- (instancetype)initWithTokenIDs:(NSArray<NSNumber *> *)tokenIDs
                      avgLogProb:(float)avgLogProb
                     temperature:(float)temperature
                compressionRatio:(float)compressionRatio
                   noSpeechProb:(float)noSpeechProb
                            text:(NSString *)text;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Error domain for MetalWhisper errors.
extern NSErrorDomain const MWErrorDomain;

/// Error codes for MetalWhisper operations.
typedef NS_ENUM(NSInteger, MWErrorCode) {
    MWErrorCodeModelLoadFailed = 1,
    MWErrorCodeEncodeFailed    = 2,
    MWErrorCodeLanguageDetectionFailed = 3,
    MWErrorCodeAudioDecodeFailed = 100,
    MWErrorCodeAudioFileNotFound = 101,
    MWErrorCodeAudioTempFileFailed = 102,
    MWErrorCodeTokenizerLoadFailed = 200,
    MWErrorCodeConfigLoadFailed = 300,
    MWErrorCodeGenerateFailed = 400,
    MWErrorCodeTranscribeFailed = 500,
};

/// Compute type for model inference.
typedef NS_ENUM(NSInteger, MWComputeType) {
    MWComputeTypeDefault = 0,
    MWComputeTypeFloat32,
    MWComputeTypeFloat16,
    MWComputeTypeInt8,
    MWComputeTypeInt8Float16,
    MWComputeTypeInt8Float32,
};

/// Whisper transcriber: loads a CTranslate2 Whisper model on Metal (MPS),
/// owns the tokenizer and feature extractor, and exposes model configuration.
@interface MWTranscriber : NSObject

// --- Initializers ---

/// Initialize with a CTranslate2 model directory path and default compute type.
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                     error:(NSError **)error;

/// Initialize with a CTranslate2 model directory path and explicit compute type.
/// This is the designated initializer.
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                               computeType:(MWComputeType)computeType
                                     error:(NSError **)error NS_DESIGNATED_INITIALIZER;

/// Unavailable — use initWithModelPath:error: or initWithModelPath:computeType:error:.
- (instancetype)init NS_UNAVAILABLE;

// --- Model Properties ---

/// Whether the loaded model is multilingual (supports language detection).
@property (nonatomic, readonly) BOOL isMultilingual;

/// Number of mel frequency bins expected by the model (80 or 128).
@property (nonatomic, readonly) NSUInteger nMels;

/// Number of supported languages (0 if not multilingual).
@property (nonatomic, readonly) NSUInteger numLanguages;

/// The feature extractor configured for this model.
@property (nonatomic, readonly) MWFeatureExtractor *featureExtractor;

/// The tokenizer configured for this model.
@property (nonatomic, readonly) MWTokenizer *tokenizer;

// --- Derived Constants ---

/// Encoder downsampling factor (always 2 for Whisper).
@property (nonatomic, readonly) NSUInteger inputStride;

/// Samples per output token = hop_length * input_stride.
@property (nonatomic, readonly) NSUInteger numSamplesPerToken;

/// Frames per second = sampling_rate / hop_length.
@property (nonatomic, readonly) NSUInteger framesPerSecond;

/// Tokens per second = sampling_rate / num_samples_per_token.
@property (nonatomic, readonly) NSUInteger tokensPerSecond;

/// Time precision for timestamps = 0.02 seconds.
@property (nonatomic, readonly) float timePrecision;

/// Maximum generation length = 448.
@property (nonatomic, readonly) NSUInteger maxLength;

/// List of supported language codes.
@property (nonatomic, readonly) NSArray<NSString *> *supportedLanguages;

/// Suppress token IDs from config.json (suppress_ids field).
@property (nonatomic, readonly) NSArray<NSNumber *> *suppressTokens;

/// Suppress token IDs at beginning (suppress_ids_begin field).
@property (nonatomic, readonly) NSArray<NSNumber *> *suppressTokensAtBegin;

// --- Encoding ---

/// Encode mel spectrogram features through the Whisper encoder.
/// @param melSpectrogram float32 data in row-major order (nMels x nFrames)
/// @param nFrames Number of time frames in the mel spectrogram
/// @param error Error output on failure
/// @return Encoded features as NSData (float32), or nil on failure.
///         The shape is [1, 1500, d_model] where d_model depends on the model.
- (nullable NSData *)encodeFeatures:(NSData *)melSpectrogram
                            nFrames:(NSUInteger)nFrames
                              error:(NSError **)error;

// --- Language Detection ---

/// Detect language from audio samples (float32 at 16kHz).
/// @param audio Raw audio samples as float32 NSData
/// @param segments Number of 30s segments to analyze (default 1)
/// @param threshold Confidence threshold for early stop (default 0.5)
/// @param detectedLanguage Output: detected language code (e.g., "en")
/// @param probability Output: probability of the detected language
/// @param allLanguageProbs Output: array of dictionaries [{language: prob}, ...], sorted by probability
/// @param error Error output on failure
/// @return YES if detection succeeded, NO on failure.
- (BOOL)detectLanguageFromAudio:(NSData *)audio
                       segments:(NSUInteger)segments
                      threshold:(float)threshold
               detectedLanguage:(NSString * _Nullable * _Nonnull)detectedLanguage
                    probability:(float *)probability
               allLanguageProbs:(NSArray<NSDictionary<NSString *, NSNumber *> *> * _Nullable * _Nullable)allLanguageProbs
                          error:(NSError **)error;

// --- Prompt Construction ---

/// Build the prompt token sequence for a decode step.
/// @param previousTokens Tokens from previous segment (nil for first segment)
/// @param withoutTimestamps Whether to suppress timestamp tokens
/// @param prefix Optional text prefix to guide decoding
/// @param hotwords Optional hotwords to bias toward
/// @return Array of token IDs for the prompt
- (NSArray<NSNumber *> *)buildPromptWithPreviousTokens:(nullable NSArray<NSNumber *> *)previousTokens
                                     withoutTimestamps:(BOOL)withoutTimestamps
                                                prefix:(nullable NSString *)prefix
                                              hotwords:(nullable NSString *)hotwords;

/// Build the full suppressed tokens list for a decode step.
/// If suppressTokens contains -1, it is expanded to the model's default suppress_ids
/// plus the tokenizer's non_speech_tokens.
/// Always adds transcribe, translate, sot, sot_prev, sot_lm, no_speech tokens.
/// @param suppressTokens Base suppress token list (use @[@(-1)] for default)
/// @return Sorted, deduplicated array of token IDs to suppress
- (NSArray<NSNumber *> *)buildSuppressedTokens:(NSArray<NSNumber *> *)suppressTokens;

// --- Generation ---

/// Generate tokens from encoder output with temperature fallback.
/// @param encoderOutput Pre-encoded features (from encodeFeatures:)
/// @param prompt Token IDs for the prompt (from buildPromptWithPreviousTokens:)
/// @param temperatures Array of temperatures to try (e.g., @[@0.0, @0.2, @0.4, @0.6, @0.8, @1.0])
/// @param beamSize Beam size for beam search at temperature 0 (default 5)
/// @param patience Beam search patience (default 1.0)
/// @param bestOf Number of hypotheses for sampling at temperature > 0 (default 5)
/// @param lengthPenalty Length penalty for beam search (default 1.0)
/// @param repetitionPenalty Repetition penalty (default 1.0)
/// @param noRepeatNgramSize Prevent repetitions of this ngram size (default 0)
/// @param compressionRatioThreshold Max compression ratio before fallback (default 2.4, -1 to disable)
/// @param logProbThreshold Min average log probability before fallback (default -1.0, NaN to disable)
/// @param noSpeechThreshold No-speech probability threshold (default 0.6, -1 to disable)
/// @param suppressTokens Tokens to suppress (default @[@(-1)] for model default)
/// @param suppressBlank Suppress blank tokens at start (default YES)
/// @param maxInitialTimestamp Maximum initial timestamp in seconds (default 1.0)
/// @param error Error output
/// @return MWGenerateResult or nil on failure
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
                                                    error:(NSError **)error;

// --- Segment Splitting ---

/// Split generated tokens into timed segments based on timestamp tokens.
/// @param tokens Token IDs from generate()
/// @param timeOffset Base time offset for this chunk (seconds)
/// @param segmentSize Number of mel frames in the segment (typically 3000)
/// @param segmentDuration Duration of the segment in seconds (typically 30.0)
/// @param seek Current seek position in mel frames
/// @param outSeek Updated seek position after processing
/// @param outSingleTimestampEnding Whether the sequence ends with a single timestamp
/// @return Array of MWSegmentInfo objects
- (NSArray<MWSegmentInfo *> *)splitSegmentsByTimestamps:(NSArray<NSNumber *> *)tokens
                                            timeOffset:(float)timeOffset
                                           segmentSize:(NSUInteger)segmentSize
                                       segmentDuration:(float)segmentDuration
                                                  seek:(NSUInteger)seek
                                               outSeek:(NSUInteger *)outSeek
                                outSingleTimestampEnding:(BOOL *)outSingleTimestampEnding;

// --- Transcription ---

/// Transcribe audio from a file URL.
/// Returns segments and transcription info.
/// @param url Audio file URL
/// @param language Language code (nil for auto-detect)
/// @param task "transcribe" or "translate"
/// @param options Transcription options (nil for defaults)
/// @param segmentHandler Called for each segment as it's produced (nil to collect all)
/// @param outInfo Output: transcription info (language, probability, duration)
/// @param error Error output
/// @return Array of all segments, or nil on failure
- (nullable NSArray<MWTranscriptionSegment *> *)transcribeURL:(NSURL *)url
                                                     language:(nullable NSString *)language
                                                         task:(NSString *)task
                                                      options:(nullable NSDictionary *)options
                                               segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *segment, BOOL *stop))segmentHandler
                                                         info:(MWTranscriptionInfo * _Nullable * _Nullable)outInfo
                                                        error:(NSError **)error;

/// Transcribe audio from float32 samples (16kHz mono).
- (nullable NSArray<MWTranscriptionSegment *> *)transcribeAudio:(NSData *)audio
                                                       language:(nullable NSString *)language
                                                           task:(NSString *)task
                                                        options:(nullable NSDictionary *)options
                                                 segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *segment, BOOL *stop))segmentHandler
                                                           info:(MWTranscriptionInfo * _Nullable * _Nullable)outInfo
                                                          error:(NSError **)error;

// --- Batched Inference ---

/// Transcribe audio using batched inference (faster for long audio).
/// Uses VAD to split audio into speech chunks, processes them in batches.
/// @param url Audio file URL
/// @param language Language code (nil for auto-detect)
/// @param task "transcribe" or "translate"
/// @param batchSize Number of chunks to process simultaneously (default 8)
/// @param options Transcription options (nil for defaults). Same keys as transcribeURL: plus "batchSize".
/// @param segmentHandler Called for each segment as produced
/// @param outInfo Transcription info output
/// @param error Error output
/// @return All segments, or nil on failure
- (nullable NSArray<MWTranscriptionSegment *> *)transcribeBatchedURL:(NSURL *)url
                                                            language:(nullable NSString *)language
                                                                task:(NSString *)task
                                                           batchSize:(NSUInteger)batchSize
                                                             options:(nullable NSDictionary *)options
                                                      segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *, BOOL *))segmentHandler
                                                                info:(MWTranscriptionInfo * _Nullable * _Nullable)outInfo
                                                               error:(NSError **)error;

/// Transcribe float32 audio using batched inference.
- (nullable NSArray<MWTranscriptionSegment *> *)transcribeBatchedAudio:(NSData *)audio
                                                              language:(nullable NSString *)language
                                                                  task:(NSString *)task
                                                             batchSize:(NSUInteger)batchSize
                                                               options:(nullable NSDictionary *)options
                                                        segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *, BOOL *))segmentHandler
                                                                  info:(MWTranscriptionInfo * _Nullable * _Nullable)outInfo
                                                                 error:(NSError **)error;

// --- Typed-options convenience ---

/// Transcribe audio file using typed MWTranscriptionOptions.
/// Equivalent to transcribeURL:language:task:options:segmentHandler:info:error:
/// with [options toDictionary].
- (nullable NSArray<MWTranscriptionSegment *> *)transcribeURL:(NSURL *)url
                                                     language:(nullable NSString *)language
                                                         task:(NSString *)task
                                            typedOptions:(nullable MWTranscriptionOptions *)options
                                               segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *segment, BOOL *stop))segmentHandler
                                                         info:(MWTranscriptionInfo * _Nullable * _Nullable)outInfo
                                                        error:(NSError **)error;

// --- Async Transcription (completion handler) ---

/// Transcribe audio file asynchronously.
/// Runs transcription on a background dispatch queue (QOS_CLASS_USER_INITIATED)
/// and calls completionHandler on the main queue.
/// @param url Audio file URL
/// @param language Language code (nil for auto-detect)
/// @param task "transcribe" or "translate"
/// @param options Typed transcription options (nil for defaults)
/// @param segmentHandler Called for each segment as it's produced (called on background queue)
/// @param completionHandler Called on main queue with results or error
- (void)transcribeURL:(NSURL *)url
             language:(nullable NSString *)language
                 task:(NSString *)task
         typedOptions:(nullable MWTranscriptionOptions *)options
       segmentHandler:(void (^ _Nullable)(MWTranscriptionSegment *segment, BOOL *stop))segmentHandler
    completionHandler:(void (^)(NSArray<MWTranscriptionSegment *> * _Nullable segments,
                                MWTranscriptionInfo * _Nullable info,
                                NSError * _Nullable error))completionHandler;

// --- M0 test method (backward compat) ---

/// Quick test: encode 30s of silence, return output shape as a string
/// (e.g. "[1, 1500, 512]"). Returns nil and sets *error on failure.
- (nullable NSString *)encodeSilenceTestWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
