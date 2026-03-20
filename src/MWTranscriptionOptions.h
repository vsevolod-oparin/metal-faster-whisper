#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Typed transcription options — replaces NSDictionary for MWTranscriber's
/// transcribeURL:/transcribeAudio:/transcribeBatchedURL:/transcribeBatchedAudio:.
@interface MWTranscriptionOptions : NSObject <NSCopying>

// ── Decoding ────────────────────────────────────────────────────────────────

/// Beam size for beam search at temperature 0.  Default: 5.
@property (nonatomic) NSUInteger beamSize;

/// Number of hypotheses for sampling at temperature > 0.  Default: 5.
@property (nonatomic) NSUInteger bestOf;

/// Beam search patience factor.  Default: 1.0.
@property (nonatomic) float patience;

/// Length penalty for beam search.  Default: 1.0.
@property (nonatomic) float lengthPenalty;

/// Repetition penalty.  Default: 1.0.
@property (nonatomic) float repetitionPenalty;

/// Prevent repetitions of this n-gram size (0 = disabled).  Default: 0.
@property (nonatomic) NSUInteger noRepeatNgramSize;

/// Temperatures to try in order (fallback chain).  Default: [0.0, 0.2, 0.4, 0.6, 0.8, 1.0].
@property (nonatomic, copy) NSArray<NSNumber *> *temperatures;

// ── Thresholds ──────────────────────────────────────────────────────────────

/// Maximum compression ratio before temperature fallback.  Default: 2.4.
@property (nonatomic) float compressionRatioThreshold;

/// Minimum average log probability before temperature fallback.  Default: -1.0.
@property (nonatomic) float logProbThreshold;

/// No-speech probability threshold.  Default: 0.6.
@property (nonatomic) float noSpeechThreshold;

// ── Behavior ────────────────────────────────────────────────────────────────

/// Whether to condition on previous segment text.  Default: YES.
@property (nonatomic) BOOL conditionOnPreviousText;

/// Reset prompt when temperature exceeds this value.  Default: 0.5.
@property (nonatomic) float promptResetOnTemperature;

/// Whether to suppress timestamp tokens.  Default: NO.
@property (nonatomic) BOOL withoutTimestamps;

/// Maximum initial timestamp in seconds.  Default: 1.0.
@property (nonatomic) float maxInitialTimestamp;

/// Whether to suppress blank tokens at start.  Default: YES.
@property (nonatomic) BOOL suppressBlank;

/// Token IDs to suppress.  @[@(-1)] expands to the model's default list.  Default: @[@(-1)].
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *suppressTokens;

// ── Word Timestamps ─────────────────────────────────────────────────────────

/// Whether to extract word-level timestamps.  Default: NO.
@property (nonatomic) BOOL wordTimestamps;

/// Punctuation characters that are prepended (merged left).  Default: standard set.
@property (nonatomic, copy, nullable) NSString *prependPunctuations;

/// Punctuation characters that are appended (merged right).  Default: standard set.
@property (nonatomic, copy, nullable) NSString *appendPunctuations;

/// Silence threshold for hallucination filtering (0 = disabled).  Default: 0.
@property (nonatomic) float hallucinationSilenceThreshold;

// ── Prompting ───────────────────────────────────────────────────────────────

/// Initial text prompt to guide the decoder.
@property (nonatomic, copy, nullable) NSString *initialPrompt;

/// Hotwords to bias the decoder toward.
@property (nonatomic, copy, nullable) NSString *hotwords;

/// Text prefix for the first segment.
@property (nonatomic, copy, nullable) NSString *prefix;

// ── VAD ─────────────────────────────────────────────────────────────────────

/// Whether to apply voice activity detection before transcription.  Default: NO.
@property (nonatomic) BOOL vadFilter;

/// Path to a Silero VAD ONNX model (nil = use model-relative default).
@property (nonatomic, copy, nullable) NSString *vadModelPath;

// ── Factory & Conversion ────────────────────────────────────────────────────

/// Create an instance with all default values.
+ (instancetype)defaults;

/// Convert to the NSDictionary format expected by MWTranscriber's transcribeURL:/transcribeAudio:.
- (NSDictionary *)toDictionary;

@end

NS_ASSUME_NONNULL_END
