#pragma once

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@class MWTranscriber;

NS_ASSUME_NONNULL_BEGIN

/// Callback invoked when a chunk of audio has been transcribed.
/// @param text The transcribed text for this chunk.
/// @param isFinal YES if this is the final result for the chunk (not a partial).
/// @param stop Set to YES to stop capturing and transcribing.
typedef void (^MWLiveTranscriptionHandler)(NSString *text, BOOL isFinal, BOOL *stop);

/// Live audio transcription using AVAudioEngine.
///
/// Captures audio from the system's default input device (microphone),
/// accumulates it in chunks, and transcribes each chunk using the provided
/// MWTranscriber. Results are delivered via the handler callback.
///
/// For automated testing, use `transcribeAudioFile:` instead of `startCapturing:`
/// to process a file through the same chunked pipeline without requiring a microphone.
@interface MWLiveTranscriber : NSObject

/// Initialize with an existing transcriber instance.
/// The transcriber must already be loaded (isModelLoaded == YES).
- (instancetype)initWithTranscriber:(MWTranscriber *)transcriber;

- (instancetype)init NS_UNAVAILABLE;

/// Whether the live transcriber is currently capturing audio.
@property (nonatomic, readonly) BOOL isCapturing;

/// Duration of each audio chunk in seconds. Default: 5.0.
/// Shorter chunks give lower latency but may produce less coherent text.
@property (nonatomic) NSTimeInterval chunkDuration;

/// Language code for transcription (e.g., @"en"). Nil for auto-detection.
@property (nonatomic, copy, nullable) NSString *language;

/// Start capturing audio from the default input device.
/// The handler is called on a background queue for each transcribed chunk.
/// Returns NO and sets *error if the audio engine fails to start.
- (BOOL)startCapturing:(MWLiveTranscriptionHandler)handler
                 error:(NSError **)error;

/// Stop capturing and transcribing. Safe to call multiple times.
- (void)stopCapturing;

/// Process an audio file through the same chunked transcription pipeline.
/// This is the testable entry point — no microphone required.
/// The handler is called for each chunk, same as live capture.
- (BOOL)transcribeAudioFile:(NSURL *)url
                    handler:(MWLiveTranscriptionHandler)handler
                      error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
