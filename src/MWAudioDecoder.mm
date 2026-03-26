#import "MWAudioDecoder.h"
#import "MWConstants.h"
#import "MWHelpers.h"
#import "MWTranscriber.h"  // For MWErrorDomain and MWErrorCode

#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>

#include <stdexcept>
#include <climits>

// ── ffmpeg path discovery ─────────────────────────────────────────────────────
static NSString *MWFindFFmpeg(void) {
    // Common install locations (Homebrew arm64, Homebrew x86, MacPorts, system PATH)
    NSArray<NSString *> *candidates = @[
        @"/opt/homebrew/bin/ffmpeg",
        @"/usr/local/bin/ffmpeg",
        @"/opt/local/bin/ffmpeg",
        @"/usr/bin/ffmpeg",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

// ── Helper: decode from an AVAudioFile ───────────────────────────────────────
static NSData *MWDecodeAudioFile(AVAudioFile *audioFile, NSError **error) {
    AVAudioFormat *sourceFormat = [audioFile processingFormat];
    AVAudioChannelCount sourceChannels = sourceFormat.channelCount;

    // Create target format: 16 kHz, mono, float32 (non-interleaved).
    AVAudioFormat *outputFormat = [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatFloat32
                  sampleRate:(double)kMWTargetSampleRate
                    channels:(AVAudioChannelCount)kMWTargetChannels
                 interleaved:NO];
    if (!outputFormat) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   @"Failed to create output audio format");
        return nil;
    }

    AVAudioConverter *converter = [[AVAudioConverter alloc]
        initFromFormat:sourceFormat
              toFormat:outputFormat];
    if (!converter) {
        [outputFormat release];
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   @"Failed to create audio converter");
        return nil;
    }

    // Estimate total output frames for pre-allocation.
    double durationSeconds = (double)audioFile.length / sourceFormat.sampleRate;
    NSUInteger estimatedFrames = (NSUInteger)(durationSeconds * kMWTargetSampleRate) + kMWDecodeBufferFrames;
    NSMutableData *accumulated = [[NSMutableData alloc] initWithCapacity:estimatedFrames * sizeof(float)];

    // Allocate a reusable output buffer for the converter.
    AVAudioPCMBuffer *outputBuffer = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:outputFormat
            frameCapacity:(AVAudioFrameCount)kMWDecodeBufferFrames];
    if (!outputBuffer) {
        [accumulated release];
        [converter release];
        [outputFormat release];
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   @"Failed to allocate output PCM buffer");
        return nil;
    }

    // Allocate an input buffer for reading from the file.
    // Size it relative to source sample rate to feed the converter proportionally.
    double sampleRateRatio = sourceFormat.sampleRate / (double)kMWTargetSampleRate;
    AVAudioFrameCount inputFrameCapacity = (AVAudioFrameCount)(kMWDecodeBufferFrames * sampleRateRatio) + 1;
    AVAudioPCMBuffer *inputBuffer = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:sourceFormat
            frameCapacity:inputFrameCapacity];
    if (!inputBuffer) {
        [outputBuffer release];
        [accumulated release];
        [converter release];
        [outputFormat release];
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   @"Failed to allocate input PCM buffer");
        return nil;
    }

    __block BOOL readError = NO;
    __block NSError *fileReadError = nil;

    // Convert in chunks until the input is exhausted.
    while (YES) {
        @autoreleasepool {
            // Reset output buffer frame length for each conversion call.
            outputBuffer.frameLength = 0;

            AVAudioConverterOutputStatus status = [converter
                convertToBuffer:outputBuffer
                          error:&fileReadError
                 withInputFromBlock:^AVAudioBuffer *(AVAudioFrameCount inNumberOfPackets,
                                                     AVAudioConverterInputStatus *outStatus) {
                    // Read from the source file.
                    inputBuffer.frameLength = 0;
                    NSError *readErr = nil;
                    BOOL ok = [audioFile readIntoBuffer:inputBuffer
                                            frameCount:inNumberOfPackets
                                                 error:&readErr];
                    if (!ok || inputBuffer.frameLength == 0) {
                        if (readErr) {
                            readError = YES;
                            // Release-then-retain is safe: [nil release] is a no-op on
                            // first call, and subsequent calls correctly release the
                            // previous error.  An exception between release and retain
                            // is theoretically possible but extremely unlikely in this
                            // context (no ObjC exceptions, no C++ throws).  (H1: WONTFIX)
                            [fileReadError release];
                            fileReadError = [readErr retain];
                        }
                        *outStatus = AVAudioConverterInputStatus_EndOfStream;
                        return nil;
                    }
                    *outStatus = AVAudioConverterInputStatus_HaveData;
                    return inputBuffer;
                }];

            if (readError) {
                break;
            }

            if (status == AVAudioConverterOutputStatus_Error) {
                readError = YES;
                break;
            }

            // Append converted float32 samples to accumulator.
            if (outputBuffer.frameLength > 0) {
                const float *samples = outputBuffer.floatChannelData[0];
                [accumulated appendBytes:samples
                                  length:outputBuffer.frameLength * sizeof(float)];
            }

            if (status == AVAudioConverterOutputStatus_EndOfStream) {
                break;
            }
        } // @autoreleasepool
    }

    [inputBuffer release];
    [outputBuffer release];
    [converter release];
    [outputFormat release];

    if (readError) {
        [accumulated release];
        NSString *desc = fileReadError
            ? [NSString stringWithFormat:@"Audio read/conversion error: %@",
               [fileReadError localizedDescription]]
            : @"Audio read/conversion error";
        [fileReadError release];
        fileReadError = nil;
        MWSetError(error, MWErrorCodeAudioDecodeFailed, desc);
        return nil;
    }
    [fileReadError release];
    fileReadError = nil;

    // AVAudioConverter sums channels when downmixing (e.g., stereo→mono).
    // Normalize by dividing by the number of source channels to produce an
    // average, matching the behavior of ffmpeg's default downmix (used by
    // the Python faster-whisper reference).
    if (sourceChannels > kMWTargetChannels) {
        float scale = 1.0f / (float)sourceChannels;
        NSUInteger sampleCount = [accumulated length] / sizeof(float);
        float *samples = (float *)[accumulated mutableBytes];
        vDSP_vsmul(samples, 1, &scale, samples, 1, (vDSP_Length)sampleCount);
    }

    NSData *result = [accumulated autorelease];
    return result;
}

// ── ffmpeg fallback for containers AVFoundation can't read (e.g. webm) ────────
// Two-step approach:
//   Step 1 — Quick extraction: ffmpeg demuxes and decodes the audio tracks to a
//             temp WAV at the source sample rate (no resampling). This is fast
//             because ffmpeg only decodes audio; resampling is deferred.
//   Step 2 — Decode: AVAudioFile reads the WAV and resamples to 16 kHz mono
//             float32 via AVAudioConverter, the same path used for all other formats.
//
// Separating extraction from resampling avoids timing drift that occurred when
// raw f32le output was used (no header → ambiguous length/offset for the decoder).

static NSData *MWRunFFmpegExtract(NSString *ffmpeg, NSURL *inputURL,
                                  NSString *outputPath, NSError **error) {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = ffmpeg;
    // -vn: drop all video streams
    // -c:a pcm_s16le: decode audio to signed 16-bit PCM (native sample rate, no resample)
    // WAV container: includes header so AVAudioFile knows sample rate / channel count
    task.arguments = @[
        @"-y", @"-i", [inputURL path],
        @"-vn",
        @"-c:a", @"pcm_s16le",
        outputPath
    ];

    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardError  = stderrPipe;
    task.standardOutput = [NSPipe pipe];

    NSError *launchError = nil;
    [task launchAndReturnError:&launchError];
    if (launchError) {
        [task release];
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   [NSString stringWithFormat:@"Failed to launch ffmpeg: %@",
                    [launchError localizedDescription]]);
        return nil;
    }
    [task waitUntilExit];

    int status = task.terminationStatus;
    [task release];

    if (status != 0) {
        NSData *stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
        NSString *stderrStr = [[NSString alloc] initWithData:stderrData
                                                    encoding:NSUTF8StringEncoding];
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   [NSString stringWithFormat:@"ffmpeg failed (exit %d): %@",
                    status, stderrStr ?: @"(no output)"]);
        [stderrStr release];
        return nil;
    }
    return (NSData *)1;  // sentinel: success, no data returned here
}

static NSData *MWDecodeAudioFFmpeg(NSURL *url, NSError **error) {
    NSString *ffmpeg = MWFindFFmpeg();
    if (!ffmpeg) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   @"Audio format not supported by AVFoundation and ffmpeg was not found. "
                   @"Install ffmpeg (e.g. 'brew install ffmpeg') to decode this file.");
        return nil;
    }

    // Step 1: extract audio tracks to a temp WAV (native sample rate, no resample).
    NSString *tempWAV = [NSTemporaryDirectory()
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"mw_extract_%@.wav", [[NSUUID UUID] UUIDString]]];

    NSError *extractError = nil;
    if (!MWRunFFmpegExtract(ffmpeg, url, tempWAV, &extractError)) {
        [[NSFileManager defaultManager] removeItemAtPath:tempWAV error:nil];
        if (error) *error = extractError;
        return nil;
    }

    // Step 2: decode the WAV via AVAudioFile + AVAudioConverter (resamples to 16 kHz mono float32).
    NSURL *wavURL = [NSURL fileURLWithPath:tempWAV];
    NSError *decodeError = nil;
    AVAudioFile *audioFile = [[AVAudioFile alloc] initForReading:wavURL error:&decodeError];
    if (!audioFile) {
        [[NSFileManager defaultManager] removeItemAtPath:tempWAV error:nil];
        if (error) *error = decodeError;
        return nil;
    }

    NSData *result = MWDecodeAudioFile(audioFile, error);
    [audioFile release];
    [[NSFileManager defaultManager] removeItemAtPath:tempWAV error:nil];
    return result;
}

// ── AVAssetReader fallback for video containers ───────────────────────────────
// Used when AVAudioFile rejects the file type (e.g. mp4, mov, mkv).
// Extracts the first audio track, resamples to 16 kHz mono float32.
static NSData *MWDecodeAudioAsset(NSURL *url, NSError **error) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    if (!asset) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   @"Failed to open asset");
        return nil;
    }

    NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        // AVFoundation can't parse this container (e.g. webm, mkv with vp9/av1).
        // Fall back to ffmpeg if available.
        return MWDecodeAudioFFmpeg(url, error);
    }
    AVAssetTrack *audioTrack = audioTracks[0];

    // Ask AVAssetReaderTrackOutput to deliver linear PCM float32 at 16 kHz mono.
    NSDictionary *outputSettings = @{
        AVFormatIDKey:             @(kAudioFormatLinearPCM),
        AVSampleRateKey:           @((double)kMWTargetSampleRate),
        AVNumberOfChannelsKey:     @((int)kMWTargetChannels),
        AVLinearPCMBitDepthKey:    @(32),
        AVLinearPCMIsFloatKey:     @YES,
        AVLinearPCMIsNonInterleaved: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
    };

    NSError *readerError = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&readerError];
    if (!reader) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   [NSString stringWithFormat:@"Failed to create asset reader: %@",
                    [readerError localizedDescription]]);
        return nil;
    }

    AVAssetReaderTrackOutput *trackOutput =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack
                                                   outputSettings:outputSettings];
    trackOutput.alwaysCopiesSampleData = NO;
    [reader addOutput:trackOutput];

    if (![reader startReading]) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   [NSString stringWithFormat:@"Asset reader failed to start: %@",
                    [[reader error] localizedDescription]]);
        return nil;
    }

    NSMutableData *accumulated = [[NSMutableData alloc] init];

    while (reader.status == AVAssetReaderStatusReading) {
        @autoreleasepool {
            CMSampleBufferRef sampleBuffer = [trackOutput copyNextSampleBuffer];
            if (!sampleBuffer) break;

            CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
            if (blockBuffer) {
                size_t totalLength = 0;
                char *dataPointer = NULL;
                OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL,
                                                              &totalLength, &dataPointer);
                if (status == noErr && dataPointer && totalLength > 0) {
                    [accumulated appendBytes:dataPointer length:totalLength];
                }
            }
            CFRelease(sampleBuffer);
        }
    }

    if (reader.status == AVAssetReaderStatusFailed) {
        [accumulated release];
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   [NSString stringWithFormat:@"Asset reader error: %@",
                    [[reader error] localizedDescription]]);
        return nil;
    }

    NSData *result = [accumulated autorelease];
    return result;
}

// ── MWAudioDecoder implementation ────────────────────────────────────────────

// OSStatus for kAudioFileUnsupportedFileTypeError ('typ?')
static const NSInteger kMWAudioFileUnsupportedTypeCode = 1954115647;

@implementation MWAudioDecoder

+ (nullable NSData *)decodeAudioAtURL:(NSURL *)url
                                error:(NSError **)error {
    try {
        if (![[NSFileManager defaultManager] fileExistsAtPath:[url path]]) {
            MWSetError(error, MWErrorCodeAudioFileNotFound,
                       [NSString stringWithFormat:@"Audio file not found: %@", [url path]]);
            return nil;
        }

        NSError *audioFileError = nil;
        AVAudioFile *audioFile = [[AVAudioFile alloc] initForReading:url error:&audioFileError];
        if (!audioFile) {
            // For unsupported audio file types (e.g. video containers like mp4/mov),
            // fall back to AVAssetReader which can extract audio from video tracks.
            if (audioFileError.code == kMWAudioFileUnsupportedTypeCode) {
                return MWDecodeAudioAsset(url, error);
            }
            if (error) *error = audioFileError;
            return nil;
        }

        NSData *result = MWDecodeAudioFile(audioFile, error);
        [audioFile release];
        return result;
    } catch (const std::exception &e) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   [NSString stringWithFormat:@"Audio decode failed: %s", e.what()]);
        return nil;
    } catch (...) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   @"Audio decode failed with unknown error");
        return nil;
    }
}

+ (nullable NSData *)decodeAudioFromData:(NSData *)data
                                   error:(NSError **)error {
    try {
        // Write data to a temporary file, decode, then clean up.
        NSString *tempDir = NSTemporaryDirectory();
        NSString *tempFileName = [NSString stringWithFormat:@"mw_audio_%@.tmp",
                                  [[NSUUID UUID] UUIDString]];
        NSString *tempPath = [tempDir stringByAppendingPathComponent:tempFileName];

        BOOL written = [data writeToFile:tempPath atomically:YES];
        if (!written) {
            MWSetError(error, MWErrorCodeAudioTempFileFailed,
                       [NSString stringWithFormat:@"Failed to write temp file: %@", tempPath]);
            return nil;
        }

        NSURL *tempURL = [NSURL fileURLWithPath:tempPath];
        AVAudioFile *audioFile = [[AVAudioFile alloc] initForReading:tempURL error:error];
        if (!audioFile) {
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
            return nil;
        }

        NSData *result = MWDecodeAudioFile(audioFile, error);
        [audioFile release];

        // Clean up temp file regardless of success or failure.
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

        return result;
    } catch (const std::exception &e) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   [NSString stringWithFormat:@"Audio decode from data failed: %s", e.what()]);
        return nil;
    } catch (...) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   @"Audio decode from data failed with unknown error");
        return nil;
    }
}

+ (nullable NSData *)decodeAudioFromBuffer:(AVAudioPCMBuffer *)buffer
                                     error:(NSError **)error {
    try {
    if (!buffer || buffer.frameLength == 0) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed, @"Input buffer is empty or nil");
        return nil;
    }

    AVAudioFormat *sourceFormat = [buffer format];

    // If already in target format, just copy the samples out.
    if (sourceFormat.sampleRate == (double)kMWTargetSampleRate &&
        sourceFormat.channelCount == (AVAudioChannelCount)kMWTargetChannels &&
        sourceFormat.commonFormat == AVAudioPCMFormatFloat32) {
        const float *samples = buffer.floatChannelData[0];
        return [NSData dataWithBytes:samples
                              length:buffer.frameLength * sizeof(float)];
    }

    // Create target format and converter.
    AVAudioFormat *outputFormat = [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatFloat32
                  sampleRate:(double)kMWTargetSampleRate
                    channels:(AVAudioChannelCount)kMWTargetChannels
                 interleaved:NO];
    if (!outputFormat) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   @"Failed to create output audio format");
        return nil;
    }

    AVAudioConverter *converter = [[AVAudioConverter alloc]
        initFromFormat:sourceFormat
              toFormat:outputFormat];
    if (!converter) {
        [outputFormat release];
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   @"Failed to create audio converter for buffer");
        return nil;
    }

    // Estimate output size, guarding against overflow of uint32_t (AVAudioFrameCount).
    double ratio = (double)kMWTargetSampleRate / sourceFormat.sampleRate;
    double estimatedFrames = (double)buffer.frameLength * ratio + 1024.0;
    if (estimatedFrames > (double)UINT32_MAX) {
        [converter release];
        [outputFormat release];
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   @"Input buffer too large for conversion");
        return nil;
    }
    AVAudioFrameCount outFrames = (AVAudioFrameCount)estimatedFrames;
    AVAudioPCMBuffer *outputBuffer = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:outputFormat
            frameCapacity:outFrames];
    if (!outputBuffer) {
        [converter release];
        [outputFormat release];
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   @"Failed to allocate output PCM buffer for conversion");
        return nil;
    }

    __block BOOL inputConsumed = NO;
    NSError *convError = nil;
    [converter convertToBuffer:outputBuffer
                         error:&convError
                withInputFromBlock:^AVAudioBuffer *(AVAudioFrameCount inNumberOfPackets,
                                                    AVAudioConverterInputStatus *outStatus) {
        if (inputConsumed) {
            *outStatus = AVAudioConverterInputStatus_EndOfStream;
            return nil;
        }
        inputConsumed = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return buffer;
    }];

    if (convError) {
        [outputBuffer release];
        [converter release];
        [outputFormat release];
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   [NSString stringWithFormat:@"Buffer conversion failed: %@",
                    [convError localizedDescription]]);
        return nil;
    }

    NSData *result = nil;
    if (outputBuffer.frameLength > 0) {
        const float *samples = outputBuffer.floatChannelData[0];
        NSMutableData *accum = [[NSMutableData alloc]
            initWithBytes:samples
                   length:outputBuffer.frameLength * sizeof(float)];

        // Normalize stereo→mono downmix (AVAudioConverter sums, we need average).
        AVAudioChannelCount sourceChannels = sourceFormat.channelCount;
        if (sourceChannels > kMWTargetChannels) {
            float scale = 1.0f / (float)sourceChannels;
            NSUInteger sampleCount = outputBuffer.frameLength;
            float *ptr = (float *)[accum mutableBytes];
            vDSP_vsmul(ptr, 1, &scale, ptr, 1, (vDSP_Length)sampleCount);
        }

        result = [accum autorelease];
    }

    [outputBuffer release];
    [converter release];
    [outputFormat release];
    return result;
    } catch (const std::exception &e) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   [NSString stringWithFormat:@"Audio decode from buffer failed: %s", e.what()]);
        return nil;
    } catch (...) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   @"Audio decode from buffer failed with unknown error");
        return nil;
    }
}

+ (NSData *)padOrTrimAudio:(NSData *)audio toSampleCount:(NSUInteger)sampleCount {
    // Guard against integer overflow in sampleCount * sizeof(float).
    if (sampleCount > NSUIntegerMax / sizeof(float)) {
        return audio;  // Return input unchanged on overflow
    }
    NSUInteger targetBytes = sampleCount * sizeof(float);
    NSUInteger sourceBytes = [audio length];

    if (sourceBytes >= targetBytes) {
        // Trim: return a sub-range of the input data.
        return [audio subdataWithRange:NSMakeRange(0, targetBytes)];
    }

    // Pad: copy existing samples and zero-fill the rest.
    NSMutableData *padded = [NSMutableData dataWithLength:targetBytes];
    [padded replaceBytesInRange:NSMakeRange(0, sourceBytes)
                      withBytes:[audio bytes]];
    return padded;
}

@end
