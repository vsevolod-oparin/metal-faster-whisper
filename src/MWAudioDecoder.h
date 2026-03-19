#pragma once

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Stateless audio decoder that converts audio files to 16 kHz mono float32 samples
/// suitable for Whisper model input.
///
/// Supports all formats handled by AVAudioFile: WAV, MP3, M4A, FLAC, CAF, AIFF.
@interface MWAudioDecoder : NSObject

/// Decode audio file at URL to 16 kHz mono float32 samples.
/// Returns nil and sets *error on failure.
+ (nullable NSData *)decodeAudioAtURL:(NSURL *)url
                                error:(NSError **)error;

/// Decode audio from in-memory data to 16 kHz mono float32 samples.
/// The data must contain a complete audio file (WAV, MP3, M4A, FLAC, etc.).
/// Internally writes to a temporary file, decodes, then deletes the temp file.
+ (nullable NSData *)decodeAudioFromData:(NSData *)data
                                   error:(NSError **)error;

/// Decode audio from an AVAudioPCMBuffer to 16 kHz mono float32 samples.
/// The buffer can be in any format — resampling and channel mixing is handled.
+ (nullable NSData *)decodeAudioFromBuffer:(AVAudioPCMBuffer *)buffer
                                     error:(NSError **)error;

/// Pad or trim float32 audio samples to the specified number of samples.
/// If shorter, zero-pads at the end. If longer, truncates.
+ (NSData *)padOrTrimAudio:(NSData *)audio toSampleCount:(NSUInteger)sampleCount;

@end

NS_ASSUME_NONNULL_END
