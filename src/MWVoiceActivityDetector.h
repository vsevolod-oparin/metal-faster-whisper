#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ── Error code for VAD operations ──────────────────────────────────────────

extern NSInteger const MWErrorCodeVADLoadFailed;
extern NSInteger const MWErrorCodeVADInferenceFailed;

// ── VAD Options ────────────────────────────────────────────────────────────

@interface MWVADOptions : NSObject
@property (nonatomic) float threshold;              // default 0.5
@property (nonatomic) float negThreshold;           // default -1 (auto: max(threshold-0.15, 0.01))
@property (nonatomic) NSInteger minSpeechDurationMs;     // default 0
@property (nonatomic) float maxSpeechDurationS;     // default INFINITY
@property (nonatomic) NSInteger minSilenceDurationMs;    // default 2000
@property (nonatomic) NSInteger speechPadMs;             // default 400
@property (nonatomic) NSInteger minSilenceAtMaxSpeech;   // default 98
@property (nonatomic) BOOL useMaxPossSilAtMaxSpeech;     // default YES
+ (instancetype)defaults;
@end

// ── Voice Activity Detector ────────────────────────────────────────────────

@interface MWVoiceActivityDetector : NSObject

/// Initialize with path to Silero VAD ONNX model.
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                     error:(NSError **)error;

- (instancetype)init NS_UNAVAILABLE;

/// Compute speech probabilities for each 512-sample chunk.
/// @param audio Float32 audio samples at 16kHz
/// @return Array of speech probabilities (one per 512-sample chunk)
- (nullable NSArray<NSNumber *> *)speechProbabilities:(NSData *)audio
                                                error:(NSError **)error;

/// Get speech timestamps from audio.
/// @param audio Float32 audio samples at 16kHz
/// @param options VAD options (nil for defaults)
/// @return Array of dictionaries with "start" and "end" keys (sample indices)
- (nullable NSArray<NSDictionary<NSString *, NSNumber *> *> *)speechTimestamps:(NSData *)audio
                                                                       options:(nullable MWVADOptions *)options
                                                                         error:(NSError **)error;

/// Collect speech chunks from audio, merging into segments up to maxDuration.
/// @param audio Full audio samples
/// @param chunks Speech timestamps from speechTimestamps:
/// @param maxDuration Maximum duration per collected chunk in seconds (INFINITY for unlimited)
/// @return Array of NSData chunks (float32 audio)
+ (NSArray<NSData *> *)collectChunks:(NSData *)audio
                              chunks:(NSArray<NSDictionary<NSString *, NSNumber *> *> *)chunks
                         maxDuration:(float)maxDuration;

@end

// ── Speech Timestamps Map ──────────────────────────────────────────────────

/// Helper to restore original timestamps after VAD filtering.
@interface MWSpeechTimestampsMap : NSObject

- (instancetype)initWithChunks:(NSArray<NSDictionary<NSString *, NSNumber *> *> *)chunks
                  samplingRate:(NSUInteger)samplingRate;
- (instancetype)init NS_UNAVAILABLE;

- (float)originalTimeForTime:(float)time;
- (float)originalTimeForTime:(float)time chunkIndex:(NSUInteger)chunkIndex;
- (NSUInteger)chunkIndexForTime:(float)time isEnd:(BOOL)isEnd;

@end

NS_ASSUME_NONNULL_END
