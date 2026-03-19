#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Computes log-mel spectrograms from raw audio, matching the faster-whisper
/// Python FeatureExtractor output exactly.
///
/// Uses Accelerate (vDSP, vForce, BLAS) for all heavy computation.
/// Thread-safe after initialization.
@interface MWFeatureExtractor : NSObject

/// Initialize with feature extraction parameters.
/// @param nMels Number of mel frequency bins (80 for standard whisper, 128 for large-v3/turbo)
/// @param nFFT FFT size (default 400)
/// @param hopLength Hop length in samples (default 160)
/// @param samplingRate Sample rate (default 16000)
- (nullable instancetype)initWithNMels:(NSUInteger)nMels
                                  nFFT:(NSUInteger)nFFT
                             hopLength:(NSUInteger)hopLength
                          samplingRate:(NSUInteger)samplingRate NS_DESIGNATED_INITIALIZER;

/// Convenience initializer with default parameters for standard whisper.
- (nullable instancetype)initWithNMels:(NSUInteger)nMels;

/// Unavailable — use initWithNMels: or the full designated initializer.
- (instancetype)init NS_UNAVAILABLE;

/// Compute log-mel spectrogram from float32 audio samples.
/// @param audio NSData containing float32 audio samples at the configured sample rate
/// @param error Error output on failure
/// @return NSData containing float32 mel spectrogram in row-major order (nMels x nFrames).
///         Returns nil on failure.
- (nullable NSData *)computeMelSpectrogramFromAudio:(NSData *)audio
                                              error:(NSError **)error;

/// Number of mel bins.
@property (nonatomic, readonly) NSUInteger nMels;

/// Number of output frames for the last computed spectrogram.
@property (nonatomic, readonly) NSUInteger lastFrameCount;

/// Test helper: returns the mel filterbank matrix as float32 data (nMels x (nFFT/2+1), row-major).
@property (nonatomic, readonly) NSData *melFilterbank;

@end

NS_ASSUME_NONNULL_END
