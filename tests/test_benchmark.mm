#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import "MWTranscriber.h"
#import "MWAudioDecoder.h"
#import "MWFeatureExtractor.h"
#import "MWConstants.h"

// ── Timing & memory helpers ──────────────────────────────────────────────────

static double now_ms(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1e6;
}

static size_t getCurrentRSS(void) {
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) == KERN_SUCCESS) {
        return info.resident_size;
    }
    return 0;
}

static double median3(double a, double b, double c) {
    if (a > b) { double t = a; a = b; b = t; }
    if (b > c) { double t = b; b = c; c = t; }
    if (a > b) { double t = a; a = b; b = t; }
    return b;
}

// ── Benchmark runner ─────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);

        if (argc < 3) {
            fprintf(stderr, "Usage: %s <model_path> <data_dir>\n", argv[0]);
            return 1;
        }

        NSString *modelPath = [NSString stringWithUTF8String:argv[1]];
        NSString *dataDir = [NSString stringWithUTF8String:argv[2]];

        fprintf(stdout, "=== MetalWhisper Benchmark ===\n");
        fprintf(stdout, "Model: %s\n", [modelPath UTF8String]);
        fprintf(stdout, "Data:  %s\n\n", [dataDir UTF8String]);

        // ── Load model ───────────────────────────────────────────────────
        NSError *error = nil;
        double t0 = now_ms();
        MWTranscriber *transcriber = [[MWTranscriber alloc] initWithModelPath:modelPath
                                                                        error:&error];
        double modelLoadMs = now_ms() - t0;
        if (!transcriber) {
            fprintf(stderr, "ERROR: Failed to load model: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
        }
        fprintf(stdout, "Model load: %.0f ms\n\n", modelLoadMs);

        // ── Audio Decode Benchmarks ──────────────────────────────────────
        fprintf(stdout, "--- Audio Decode ---\n");

        struct { const char *name; NSString *file; } audioFiles[] = {
            { "jfk.flac (11s)", @"jfk.flac" },
            { "physicsworks.wav (203s)", @"physicsworks.wav" },
        };

        for (int i = 0; i < 2; i++) {
            NSString *path = [dataDir stringByAppendingPathComponent:audioFiles[i].file];
            NSURL *url = [NSURL fileURLWithPath:path];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                fprintf(stdout, "  SKIP: %s — not found\n", audioFiles[i].name);
                continue;
            }

            double times[3];
            NSUInteger lastSamples = 0;
            for (int r = 0; r < 3; r++) {
                @autoreleasepool {
                    double t = now_ms();
                    NSData *audio = [MWAudioDecoder decodeAudioAtURL:url error:&error];
                    times[r] = now_ms() - t;
                    if (audio) lastSamples = [audio length] / sizeof(float);
                }
            }
            double med = median3(times[0], times[1], times[2]);
            double dur = (double)lastSamples / kMWTargetSampleRate;
            fprintf(stdout, "  %s: %.1f ms (%.1fs audio, %lu samples)\n",
                    audioFiles[i].name, med, dur, (unsigned long)lastSamples);
        }

        // ── Mel Spectrogram Benchmark ────────────────────────────────────
        fprintf(stdout, "\n--- Mel Spectrogram ---\n");

        // Decode physicsworks first 30s
        {
            NSString *wavPath = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
            NSURL *wavURL = [NSURL fileURLWithPath:wavPath];
            NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:wavURL error:&error];
            if (fullAudio) {
                NSUInteger samples30s = 30 * kMWTargetSampleRate;
                NSUInteger availBytes = [fullAudio length];
                NSUInteger useBytes = MIN(samples30s * sizeof(float), availBytes);
                NSData *audio30s = [fullAudio subdataWithRange:NSMakeRange(0, useBytes)];

                MWFeatureExtractor *fe = transcriber.featureExtractor;
                double times[5];
                for (int r = 0; r < 5; r++) {
                    @autoreleasepool {
                        double t = now_ms();
                        NSData *mel = [fe computeMelSpectrogramFromAudio:audio30s frameCount:NULL error:&error];
                        times[r] = now_ms() - t;
                        (void)mel;
                    }
                }
                // Sort and take median
                for (int i = 0; i < 4; i++)
                    for (int j = i+1; j < 5; j++)
                        if (times[i] > times[j]) { double t = times[i]; times[i] = times[j]; times[j] = t; }
                double med = times[2];
                fprintf(stdout, "  mel 30s (%lu mels): %.1f ms (%.0fx realtime)\n",
                        (unsigned long)fe.nMels, med, 30000.0 / med);
            }
        }

        // ── Encode Benchmark ─────────────────────────────────────────────
        fprintf(stdout, "\n--- Encode (30s silence) ---\n");
        {
            NSUInteger nMels = transcriber.nMels;
            NSUInteger nFrames = kMWDefaultChunkFrames; // 3000
            NSMutableData *silenceMel = [NSMutableData dataWithLength:nMels * nFrames * sizeof(float)];

            double times[3];
            for (int r = 0; r < 3; r++) {
                @autoreleasepool {
                    double t = now_ms();
                    NSData *enc = [transcriber encodeFeatures:silenceMel nFrames:nFrames error:&error];
                    times[r] = now_ms() - t;
                    (void)enc;
                }
            }
            double med = median3(times[0], times[1], times[2]);
            fprintf(stdout, "  encode 30s: %.0f ms\n", med);
        }

        // ── Full Transcription Benchmarks ────────────────────────────────
        fprintf(stdout, "\n--- Full Transcription (no word timestamps) ---\n");

        struct { const char *name; NSString *file; double durS; } transcribeFiles[] = {
            { "jfk.flac (11s)", @"jfk.flac", 11.0 },
            { "physicsworks.wav (203s)", @"physicsworks.wav", 203.0 },
        };

        for (int i = 0; i < 2; i++) {
            NSString *path = [dataDir stringByAppendingPathComponent:transcribeFiles[i].file];
            NSURL *url = [NSURL fileURLWithPath:path];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                fprintf(stdout, "  SKIP: %s\n", transcribeFiles[i].name);
                continue;
            }

            // Warm-up run
            @autoreleasepool {
                NSArray *segs = [transcriber transcribeURL:url
                                                 language:@"en"
                                                     task:@"transcribe"
                                                  options:@{@"temperatures": @[@0.0]}
                                           segmentHandler:nil
                                                     info:nil
                                                    error:&error];
                (void)segs;
            }

            double times[3];
            size_t peakRSS = 0;
            NSString *textPreview = nil;
            NSUInteger segCount = 0;

            for (int r = 0; r < 3; r++) {
                double t = now_ms();
                NSArray *segs = [transcriber transcribeURL:url
                                                 language:@"en"
                                                     task:@"transcribe"
                                                  options:@{@"temperatures": @[@0.0]}
                                             segmentHandler:nil
                                                     info:nil
                                                    error:&error];
                times[r] = now_ms() - t;

                if (r == 0 && segs) {
                    segCount = [segs count];
                    NSMutableString *full = [[NSMutableString alloc] init];
                    for (MWTranscriptionSegment *s in segs) {
                        [full appendString:s.text];
                    }
                    textPreview = [[full substringToIndex:MIN([full length], 80)] copy];
                    [full release];
                }
            }
            double med = median3(times[0], times[1], times[2]);
            double rtf = med / (transcribeFiles[i].durS * 1000.0);
            fprintf(stdout, "  %s: %.0f ms (RTF=%.3f, %lu segments)\n",
                    transcribeFiles[i].name, med, rtf, (unsigned long)segCount);
            if (textPreview) {
                fprintf(stdout, "    text: %s...\n", [textPreview UTF8String]);
                [textPreview release];
            }
        }

        // ── Word Timestamps Benchmark ────────────────────────────────────
        fprintf(stdout, "\n--- Transcription with Word Timestamps ---\n");
        {
            NSString *jfkPath = [dataDir stringByAppendingPathComponent:@"jfk.flac"];
            NSURL *jfkURL = [NSURL fileURLWithPath:jfkPath];
            if ([[NSFileManager defaultManager] fileExistsAtPath:jfkPath]) {
                double times[3];
                for (int r = 0; r < 3; r++) {
                    @autoreleasepool {
                        double t = now_ms();
                        NSArray *segs = [transcriber transcribeURL:jfkURL
                                                         language:@"en"
                                                             task:@"transcribe"
                                                          options:@{
                                                              @"temperatures": @[@0.0],
                                                              @"wordTimestamps": @YES
                                                          }
                                                     segmentHandler:nil
                                                             info:nil
                                                            error:&error];
                        times[r] = now_ms() - t;
                        (void)segs;
                    }
                }
                double med = median3(times[0], times[1], times[2]);
                fprintf(stdout, "  jfk.flac + word_timestamps: %.0f ms (RTF=%.3f)\n",
                        med, med / 11000.0);
            }
        }

        // ── Peak RSS ─────────────────────────────────────────────────────
        fprintf(stdout, "\n--- Memory ---\n");
        fprintf(stdout, "  Peak RSS: %.1f MB\n", (double)getCurrentRSS() / (1024.0 * 1024.0));

        fprintf(stdout, "\n=== Benchmark Complete ===\n");

        [transcriber release];
        return 0;
    }
}
