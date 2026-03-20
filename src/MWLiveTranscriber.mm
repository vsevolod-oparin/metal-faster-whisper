// MWLiveTranscriber.mm — Live audio capture + chunked transcription
// Manual retain/release (-fno-objc-arc)

#import "MWLiveTranscriber.h"
#import "MWTranscriber.h"
#import "MWAudioDecoder.h"
#import "MWHelpers.h"

#include <vector>

static const NSTimeInterval kDefaultChunkDuration = 5.0;
static const double kTargetSampleRate = 16000.0;

@implementation MWLiveTranscriber {
    MWTranscriber *_transcriber;
    AVAudioEngine *_engine;
    BOOL _isCapturing;
    NSTimeInterval _chunkDuration;
    NSString *_language;
}

- (instancetype)initWithTranscriber:(MWTranscriber *)transcriber {
    self = [super init];
    if (!self) return nil;

    _transcriber = [transcriber retain];
    _chunkDuration = kDefaultChunkDuration;
    _isCapturing = NO;

    return self;
}

- (void)dealloc {
    [self stopCapturing];
    [_transcriber release];
    [_language release];
    [super dealloc];
}

// ── Properties ──────────────────────────────────────────────────────────────

- (BOOL)isCapturing {
    return _isCapturing;
}

- (NSTimeInterval)chunkDuration {
    return _chunkDuration;
}

- (void)setChunkDuration:(NSTimeInterval)chunkDuration {
    _chunkDuration = (chunkDuration > 0.5) ? chunkDuration : 0.5;
}

- (NSString *)language {
    return _language;
}

- (void)setLanguage:(NSString *)language {
    NSString *old = _language;
    _language = [language copy];
    [old release];
}

// ── Live capture ────────────────────────────────────────────────────────────

- (BOOL)startCapturing:(MWLiveTranscriptionHandler)handler
                 error:(NSError **)error {
    if (_isCapturing) {
        MWSetError(error, MWErrorCodeTranscribeFailed, @"Already capturing.");
        return NO;
    }

    _engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *inputNode = [_engine inputNode];

    // Use 16kHz mono float32 format for processing.
    AVAudioFormat *recordingFormat = [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatFloat32
                  sampleRate:kTargetSampleRate
                    channels:1
                 interleaved:NO];

    NSUInteger samplesPerChunk = (NSUInteger)(kTargetSampleRate * _chunkDuration);
    NSUInteger bufferSize = 4096; // frames per tap callback

    // Accumulator for audio samples.
    __block std::vector<float> accum;
    accum.reserve(samplesPerChunk);

    __block BOOL shouldStop = NO;

    // Capture handler and transcriber references for the block.
    MWLiveTranscriptionHandler capturedHandler = [handler copy];
    MWTranscriber *transcriber = [_transcriber retain];
    NSString *lang = [_language copy];

    [inputNode installTapOnBus:0
                    bufferSize:(AVAudioFrameCount)bufferSize
                        format:recordingFormat
                         block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        if (shouldStop) return;

        @autoreleasepool {
            const float *samples = [buffer floatChannelData][0];
            AVAudioFrameCount frameCount = [buffer frameLength];

            accum.insert(accum.end(), samples, samples + frameCount);

            if (accum.size() >= samplesPerChunk) {
                // Transcribe the accumulated chunk.
                NSData *audio = [NSData dataWithBytes:accum.data()
                                               length:accum.size() * sizeof(float)];
                accum.clear();

                NSError *txErr = nil;
                NSArray *segments = [transcriber transcribeAudio:audio
                                                       language:lang
                                                           task:@"transcribe"
                                                        options:nil
                                                 segmentHandler:nil
                                                           info:nil
                                                          error:&txErr];

                NSMutableString *text = [NSMutableString string];
                for (MWTranscriptionSegment *seg in segments) {
                    [text appendString:seg.text];
                }

                BOOL stop = NO;
                capturedHandler(text, YES, &stop);
                if (stop) {
                    shouldStop = YES;
                }
            }
        }
    }];

    NSError *startError = nil;
    [_engine prepare];
    BOOL started = [_engine startAndReturnError:&startError];
    if (!started) {
        MWSetError(error, MWErrorCodeAudioDecodeFailed,
                   [NSString stringWithFormat:@"AVAudioEngine failed to start: %@",
                    [startError localizedDescription]]);
        [inputNode removeTapOnBus:0];
        [_engine release];
        _engine = nil;
        [capturedHandler release];
        [transcriber release];
        [lang release];
        return NO;
    }

    _isCapturing = YES;
    MWLog(@"[MetalWhisper] Live capture started (chunk=%.1fs)", _chunkDuration);
    return YES;
}

- (void)stopCapturing {
    if (!_isCapturing || !_engine) return;

    [[_engine inputNode] removeTapOnBus:0];
    [_engine stop];
    [_engine release];
    _engine = nil;
    _isCapturing = NO;

    MWLog(@"[MetalWhisper] Live capture stopped");
}

// ── File-based testing ──────────────────────────────────────────────────────

- (BOOL)transcribeAudioFile:(NSURL *)url
                    handler:(MWLiveTranscriptionHandler)handler
                      error:(NSError **)error {
    // Decode the file to 16kHz mono float32 — same format as live capture.
    NSData *audio = [MWAudioDecoder decodeAudioAtURL:url error:error];
    if (!audio) return NO;

    const float *samples = (const float *)[audio bytes];
    NSUInteger totalSamples = [audio length] / sizeof(float);
    NSUInteger samplesPerChunk = (NSUInteger)(kTargetSampleRate * _chunkDuration);

    NSUInteger offset = 0;
    BOOL stopped = NO;

    while (offset < totalSamples && !stopped) {
        @autoreleasepool {
            NSUInteger remaining = totalSamples - offset;
            NSUInteger chunkSamples = (remaining < samplesPerChunk) ? remaining : samplesPerChunk;

            NSData *chunk = [NSData dataWithBytes:(samples + offset)
                                           length:chunkSamples * sizeof(float)];

            NSError *txErr = nil;
            NSArray *segments = [_transcriber transcribeAudio:chunk
                                                    language:_language
                                                        task:@"transcribe"
                                                     options:nil
                                              segmentHandler:nil
                                                        info:nil
                                                       error:&txErr];

            NSMutableString *text = [NSMutableString string];
            for (MWTranscriptionSegment *seg in segments) {
                [text appendString:seg.text];
            }

            BOOL isLast = (offset + chunkSamples >= totalSamples);
            BOOL stop = NO;
            handler(text, isLast, &stop);
            if (stop) stopped = YES;

            offset += chunkSamples;
        }
    }

    return YES;
}

@end
