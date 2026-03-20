#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import "MWTranscriber.h"
#import "MWTranscriptionOptions.h"
#import "MWAudioDecoder.h"
#import "MWModelManager.h"
#import "MWConstants.h"
#import "MWTestCommon.h"

// ── Helpers ─────────────────────────────────────────────────────────────────

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

/// Concatenate all segment texts into one lowercase string.
static NSString *fullText(NSArray<MWTranscriptionSegment *> *segments) {
    NSMutableString *s = [[NSMutableString alloc] init];
    for (MWTranscriptionSegment *seg in segments) {
        [s appendString:seg.text];
    }
    NSString *result = [[s lowercaseString] copy];
    [s release];
    return [result autorelease];
}

/// Simple word overlap ratio: fraction of words in A that also appear in B.
static float wordOverlap(NSString *textA, NSString *textB) {
    NSCharacterSet *sep = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSArray *wordsA = [[textA lowercaseString] componentsSeparatedByCharactersInSet:sep];
    NSMutableSet *setB = [NSMutableSet setWithArray:
        [[textB lowercaseString] componentsSeparatedByCharactersInSet:sep]];

    NSUInteger total = 0;
    NSUInteger matched = 0;
    for (NSString *w in wordsA) {
        if ([w length] == 0) continue;
        total++;
        if ([setB containsObject:w]) matched++;
    }
    return total > 0 ? (float)matched / (float)total : 0.0f;
}

/// Character-level similarity using longest common subsequence ratio.
static float charSimilarity(NSString *a, NSString *b) {
    NSString *la = [a lowercaseString];
    NSString *lb = [b lowercaseString];
    NSUInteger lenA = [la length];
    NSUInteger lenB = [lb length];
    if (lenA == 0 || lenB == 0) return 0.0f;

    // Use two rows to save memory.
    NSUInteger *prev = (NSUInteger *)calloc(lenB + 1, sizeof(NSUInteger));
    NSUInteger *curr = (NSUInteger *)calloc(lenB + 1, sizeof(NSUInteger));

    for (NSUInteger i = 1; i <= lenA; i++) {
        unichar ca = [la characterAtIndex:i - 1];
        for (NSUInteger j = 1; j <= lenB; j++) {
            unichar cb = [lb characterAtIndex:j - 1];
            if (ca == cb) {
                curr[j] = prev[j - 1] + 1;
            } else {
                curr[j] = MAX(prev[j], curr[j - 1]);
            }
        }
        NSUInteger *tmp = prev;
        prev = curr;
        curr = tmp;
        memset(curr, 0, (lenB + 1) * sizeof(NSUInteger));
    }
    float ratio = (float)prev[lenB] / (float)MAX(lenA, lenB);
    free(prev);
    free(curr);
    return ratio;
}

// ============================================================================
// Section 1: Accuracy Tests
// ============================================================================

static void test_m11_jfk_tiny(MWTranscriber *tinyTranscriber, NSString *dataDir) {
    const char *name = "m11_jfk_tiny";

    NSString *path = [dataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSURL *url = [NSURL fileURLWithPath:path];
    ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                @"jfk.flac not found");

    NSError *error = nil;
    MWTranscriptionInfo *info = nil;
    NSArray *segments = [tinyTranscriber transcribeURL:url
                                             language:@"en"
                                                 task:@"transcribe"
                                              options:nil
                                       segmentHandler:nil
                                                 info:&info
                                                error:&error];
    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribe failed", error));
    ASSERT_TRUE(name, [segments count] > 0, @"expected non-empty segments");

    NSString *text = fullText(segments);
    fprintf(stdout, "    tiny text: %s\n", [text UTF8String]);

    BOOL hasFellowAmericans = [text containsString:@"my fellow americans"] ||
                              [text containsString:@"fellow americans"];
    BOOL hasAskNot = [text containsString:@"ask not what your country can do"] ||
                     [text containsString:@"ask not"];

    ASSERT_TRUE(name, hasFellowAmericans || hasAskNot,
                @"tiny model output does not contain expected JFK phrases");

    reportResult(name, YES, nil);
}

static void test_m11_jfk_turbo(MWTranscriber *turbo, NSString *dataDir) {
    const char *name = "m11_jfk_turbo";

    NSString *path = [dataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSURL *url = [NSURL fileURLWithPath:path];
    ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                @"jfk.flac not found");

    NSError *error = nil;
    NSArray *segments = [turbo transcribeURL:url
                                   language:@"en"
                                       task:@"transcribe"
                                    options:@{@"temperatures": @[@0.0]}
                             segmentHandler:nil
                                       info:nil
                                      error:&error];
    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribe failed", error));

    NSString *text = fullText(segments);
    fprintf(stdout, "    turbo text: %s\n", [text UTF8String]);

    // Known JFK speech reference (approximate).
    NSString *ref = @"And so my fellow Americans ask not what your country can do for you "
                    @"ask what you can do for your country";

    float sim = charSimilarity(text, ref);
    fprintf(stdout, "    char similarity to reference: %.1f%%\n", sim * 100.0f);
    NSString *simMsg = [NSString stringWithFormat:@"char similarity %.1f%% < 80%%", sim * 100.0f];
    ASSERT_TRUE(name, sim > 0.80f, simMsg);

    reportResult(name, YES, nil);
}

static void test_m11_multi_format(MWTranscriber *turbo, NSString *dataDir) {
    const char *name = "m11_multi_format";

    NSString *flacPath = [dataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSString *m4aPath  = [dataDir stringByAppendingPathComponent:@"jfk.m4a"];
    ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:flacPath],
                @"jfk.flac not found");
    ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:m4aPath],
                @"jfk.m4a not found");

    NSError *error = nil;
    NSDictionary *opts = @{@"temperatures": @[@0.0]};

    NSArray *flacSegs = [turbo transcribeURL:[NSURL fileURLWithPath:flacPath]
                                    language:@"en" task:@"transcribe" options:opts
                              segmentHandler:nil info:nil error:&error];
    ASSERT_TRUE(name, flacSegs != nil, fmtErr(@"FLAC transcribe failed", error));

    NSArray *m4aSegs = [turbo transcribeURL:[NSURL fileURLWithPath:m4aPath]
                                   language:@"en" task:@"transcribe" options:opts
                             segmentHandler:nil info:nil error:&error];
    ASSERT_TRUE(name, m4aSegs != nil, fmtErr(@"M4A transcribe failed", error));

    NSString *flacText = fullText(flacSegs);
    NSString *m4aText  = fullText(m4aSegs);

    float overlap = wordOverlap(flacText, m4aText);
    fprintf(stdout, "    FLAC: %s\n", [flacText UTF8String]);
    fprintf(stdout, "    M4A:  %s\n", [m4aText UTF8String]);
    fprintf(stdout, "    word overlap: %.1f%%\n", overlap * 100.0f);

    NSString *overlapMsg = [NSString stringWithFormat:@"word overlap %.1f%% < 60%%", overlap * 100.0f];
    ASSERT_TRUE(name, overlap > 0.60f, overlapMsg);

    reportResult(name, YES, nil);
}

static void test_m11_word_timestamps_monotonic(MWTranscriber *turbo, NSString *dataDir) {
    const char *name = "m11_word_timestamps_monotonic";

    NSString *path = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                @"physicsworks.wav not found");

    // Decode and trim to ~30s.
    NSError *error = nil;
    NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:[NSURL fileURLWithPath:path] error:&error];
    ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"decode failed", error));

    NSUInteger samples30s = 30 * (NSUInteger)kMWTargetSampleRate;
    NSUInteger useBytes = MIN(samples30s * sizeof(float), [fullAudio length]);
    NSData *audio30s = [fullAudio subdataWithRange:NSMakeRange(0, useBytes)];

    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    opts.wordTimestamps = YES;
    opts.temperatures = @[@0.0];

    MWTranscriptionInfo *info = nil;
    NSArray *segments = [turbo transcribeAudio:audio30s
                                     language:@"en"
                                         task:@"transcribe"
                                      options:[opts toDictionary]
                               segmentHandler:nil
                                         info:&info
                                        error:&error];
    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribe failed", error));
    ASSERT_TRUE(name, [segments count] > 0, @"expected segments");

    NSUInteger totalWords = 0;
    BOOL valid = YES;
    NSString *failDetail = nil;

    for (MWTranscriptionSegment *seg in segments) {
        if (!seg.words) continue;
        float prevWordStart = -1.0f;
        for (MWWord *w in seg.words) {
            totalWords++;
            if (w.start > w.end) {
                valid = NO;
                failDetail = [NSString stringWithFormat:
                    @"word '%@' has start %.3f > end %.3f", w.word, w.start, w.end];
                break;
            }
            if (w.start < prevWordStart - 0.001f) {
                valid = NO;
                failDetail = [NSString stringWithFormat:
                    @"word '%@' start %.3f < prev start %.3f (not monotonic within segment)",
                    w.word, w.start, prevWordStart];
                break;
            }
            prevWordStart = w.start;
        }
        if (!valid) break;
    }

    fprintf(stdout, "    total words: %lu\n", (unsigned long)totalWords);
    ASSERT_TRUE(name, totalWords > 0, @"expected word timestamps");
    ASSERT_TRUE(name, valid, failDetail);

    reportResult(name, YES, nil);
}

static void test_m11_segment_timestamps_valid(MWTranscriber *turbo, NSString *dataDir) {
    const char *name = "m11_segment_timestamps_valid";

    NSString *path = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                @"physicsworks.wav not found");

    // Decode and trim to ~60s.
    NSError *error = nil;
    NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:[NSURL fileURLWithPath:path] error:&error];
    ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"decode failed", error));

    NSUInteger samples60s = 60 * (NSUInteger)kMWTargetSampleRate;
    NSUInteger useBytes = MIN(samples60s * sizeof(float), [fullAudio length]);
    NSData *audio60s = [fullAudio subdataWithRange:NSMakeRange(0, useBytes)];
    float audioDuration = (float)(useBytes / sizeof(float)) / (float)kMWTargetSampleRate;

    MWTranscriptionInfo *info = nil;
    NSArray *segments = [turbo transcribeAudio:audio60s
                                     language:@"en"
                                         task:@"transcribe"
                                      options:@{@"temperatures": @[@0.0]}
                               segmentHandler:nil
                                         info:&info
                                        error:&error];
    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribe failed", error));
    ASSERT_TRUE(name, [segments count] > 0, @"expected segments");

    BOOL valid = YES;
    NSString *failDetail = nil;

    for (MWTranscriptionSegment *seg in segments) {
        if (seg.start < 0.0f) {
            valid = NO;
            failDetail = [NSString stringWithFormat:@"negative start: %.3f", seg.start];
            break;
        }
        if (seg.start >= seg.end) {
            valid = NO;
            failDetail = [NSString stringWithFormat:
                @"segment %lu: start %.3f >= end %.3f",
                (unsigned long)seg.segmentId, seg.start, seg.end];
            break;
        }
    }

    if (valid) {
        MWTranscriptionSegment *last = [segments lastObject];
        if (last.end > audioDuration + 1.0f) {
            valid = NO;
            failDetail = [NSString stringWithFormat:
                @"last segment end %.3f > audio duration %.3f + 1s", last.end, audioDuration];
        }
    }

    fprintf(stdout, "    segments: %lu, audio duration: %.1fs\n",
            (unsigned long)[segments count], audioDuration);
    if ([segments count] > 0) {
        MWTranscriptionSegment *last = [segments lastObject];
        fprintf(stdout, "    last segment end: %.3fs\n", last.end);
    }
    ASSERT_TRUE(name, valid, failDetail);

    reportResult(name, YES, nil);
}

// ============================================================================
// Section 2: Performance Benchmarks
// ============================================================================

static void test_m11_rtf_turbo(MWTranscriber *turbo, NSString *dataDir) {
    const char *name = "m11_rtf_turbo";

    NSString *path = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                @"physicsworks.wav not found");

    NSURL *url = [NSURL fileURLWithPath:path];
    NSError *error = nil;
    MWTranscriptionInfo *info = nil;

    double t0 = now_ms();
    NSArray *segments = [turbo transcribeURL:url
                                   language:@"en"
                                       task:@"transcribe"
                                    options:@{@"temperatures": @[@0.0]}
                             segmentHandler:nil
                                       info:&info
                                      error:&error];
    double elapsed = now_ms() - t0;

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribe failed", error));

    float audioDur = info ? info.duration : 203.0f;
    double rtf = elapsed / (audioDur * 1000.0);
    fprintf(stdout, "    turbo RTF: %.4f (%.0f ms for %.1fs audio)\n",
            rtf, elapsed, audioDur);
    NSString *rtfMsg = [NSString stringWithFormat:@"RTF %.4f >= 0.20", rtf];
    ASSERT_TRUE(name, rtf < 0.20, rtfMsg);

    reportResult(name, YES, nil);
}

static void test_m11_rtf_tiny(MWTranscriber *tinyTranscriber, NSString *dataDir) {
    const char *name = "m11_rtf_tiny";

    NSString *path = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                @"physicsworks.wav not found");

    // Decode and trim to ~30s.
    NSError *error = nil;
    NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:[NSURL fileURLWithPath:path] error:&error];
    ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"decode failed", error));

    NSUInteger samples30s = 30 * (NSUInteger)kMWTargetSampleRate;
    NSUInteger useBytes = MIN(samples30s * sizeof(float), [fullAudio length]);
    NSData *audio30s = [fullAudio subdataWithRange:NSMakeRange(0, useBytes)];
    float audioDur = (float)(useBytes / sizeof(float)) / (float)kMWTargetSampleRate;

    double t0 = now_ms();
    NSArray *segments = [tinyTranscriber transcribeAudio:audio30s
                                               language:@"en"
                                                   task:@"transcribe"
                                                options:@{@"temperatures": @[@0.0]}
                                         segmentHandler:nil
                                                   info:nil
                                                  error:&error];
    double elapsed = now_ms() - t0;

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribe failed", error));

    double rtf = elapsed / (audioDur * 1000.0);
    fprintf(stdout, "    tiny RTF (30s): %.4f (%.0f ms for %.1fs audio)\n",
            rtf, elapsed, audioDur);
    NSString *rtfMsg = [NSString stringWithFormat:@"RTF %.4f >= 0.15", rtf];
    ASSERT_TRUE(name, rtf < 0.15, rtfMsg);

    reportResult(name, YES, nil);
}

// ============================================================================
// Section 3: Edge Cases
// ============================================================================

static void test_m11_empty_audio(MWTranscriber *turbo) {
    const char *name = "m11_empty_audio";

    NSData *emptyAudio = [NSData data];
    NSError *error = nil;
    MWTranscriptionInfo *info = nil;
    NSArray *segments = [turbo transcribeAudio:emptyAudio
                                     language:@"en"
                                         task:@"transcribe"
                                      options:nil
                               segmentHandler:nil
                                         info:&info
                                        error:&error];

    ASSERT_TRUE(name, segments != nil, @"should not return nil for empty audio");
    ASSERT_EQ(name, [segments count], 0);
    fprintf(stdout, "    empty audio: %lu segments (OK)\n", (unsigned long)[segments count]);

    reportResult(name, YES, nil);
}

static void test_m11_very_short_audio(MWTranscriber *turbo) {
    const char *name = "m11_very_short_audio";

    // 0.05s = 800 samples at 16kHz, all zeros.
    NSUInteger numSamples = 800;
    NSMutableData *audio = [NSMutableData dataWithLength:numSamples * sizeof(float)];
    memset([audio mutableBytes], 0, numSamples * sizeof(float));

    NSError *error = nil;
    MWTranscriptionInfo *info = nil;
    NSArray *segments = [turbo transcribeAudio:audio
                                     language:@"en"
                                         task:@"transcribe"
                                      options:nil
                               segmentHandler:nil
                                         info:&info
                                        error:&error];

    // Should not crash. May produce empty or short output.
    ASSERT_TRUE(name, segments != nil, @"should not return nil for very short audio");
    fprintf(stdout, "    very short audio (0.05s): %lu segments\n",
            (unsigned long)[segments count]);

    reportResult(name, YES, nil);
}

static void test_m11_stereo_input(MWTranscriber *turbo, NSString *dataDir) {
    const char *name = "m11_stereo_input";

    NSString *path = [dataDir stringByAppendingPathComponent:@"stereo_diarization.wav"];
    ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                @"stereo_diarization.wav not found");

    NSError *error = nil;
    NSArray *segments = [turbo transcribeURL:[NSURL fileURLWithPath:path]
                                   language:@"en"
                                       task:@"transcribe"
                                    options:nil
                             segmentHandler:nil
                                       info:nil
                                      error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribe failed", error));
    // Stereo file should produce at least some output.
    NSString *text = fullText(segments);
    fprintf(stdout, "    stereo text: %s\n", [text UTF8String]);
    ASSERT_TRUE(name, [text length] > 0, @"expected non-empty text from stereo input");

    reportResult(name, YES, nil);
}

static void test_m11_mp3_input(MWTranscriber *turbo, NSString *dataDir) {
    const char *name = "m11_mp3_input";

    NSString *path = [dataDir stringByAppendingPathComponent:@"hotwords.mp3"];
    ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                @"hotwords.mp3 not found");

    NSError *error = nil;
    NSArray *segments = [turbo transcribeURL:[NSURL fileURLWithPath:path]
                                   language:@"en"
                                       task:@"transcribe"
                                    options:nil
                             segmentHandler:nil
                                       info:nil
                                      error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribe failed", error));
    NSString *text = fullText(segments);
    fprintf(stdout, "    mp3 text: %s\n", [text UTF8String]);
    ASSERT_TRUE(name, [text length] > 0, @"expected non-empty text from MP3 input");

    reportResult(name, YES, nil);
}

static void test_m11_corrupt_file(MWTranscriber *turbo) {
    const char *name = "m11_corrupt_file";

    // Write 1000 random bytes to a temp file.
    NSString *tmpPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"m11_corrupt_test.wav"];
    NSMutableData *garbage = [NSMutableData dataWithLength:1000];
    arc4random_buf([garbage mutableBytes], 1000);
    [garbage writeToFile:tmpPath atomically:YES];

    NSError *error = nil;
    NSArray *segments = [turbo transcribeURL:[NSURL fileURLWithPath:tmpPath]
                                   language:@"en"
                                       task:@"transcribe"
                                    options:nil
                             segmentHandler:nil
                                       info:nil
                                      error:&error];

    // Should fail gracefully with error, not crash.
    ASSERT_TRUE(name, segments == nil || [segments count] == 0,
                @"expected nil or empty for corrupt file");
    if (segments == nil) {
        ASSERT_TRUE(name, error != nil, @"expected error for corrupt file");
        fprintf(stdout, "    corrupt file error: %s\n",
                [[error localizedDescription] UTF8String]);
    } else {
        fprintf(stdout, "    corrupt file: returned empty segments (OK)\n");
    }

    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
    reportResult(name, YES, nil);
}

// ============================================================================
// Section 4: Memory
// ============================================================================

static void test_m11_memory_sequential(MWTranscriber *turbo, NSString *dataDir) {
    const char *name = "m11_memory_sequential";

    NSString *path = [dataDir stringByAppendingPathComponent:@"jfk.flac"];
    ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                @"jfk.flac not found");

    NSURL *url = [NSURL fileURLWithPath:path];
    NSError *error = nil;

    // Warm-up run.
    @autoreleasepool {
        NSArray *segs = [turbo transcribeURL:url language:@"en" task:@"transcribe"
                                    options:@{@"temperatures": @[@0.0]}
                             segmentHandler:nil info:nil error:&error];
        (void)segs;
    }

    size_t rssBefore = getCurrentRSS();

    for (int i = 0; i < 5; i++) {
        @autoreleasepool {
            NSArray *segs = [turbo transcribeURL:url language:@"en" task:@"transcribe"
                                        options:@{@"temperatures": @[@0.0]}
                                 segmentHandler:nil info:nil error:&error];
            ASSERT_TRUE(name, segs != nil, fmtErr(@"transcribe failed on iteration", error));
        }
    }

    size_t rssAfter = getCurrentRSS();
    double growthMB = ((double)rssAfter - (double)rssBefore) / (1024.0 * 1024.0);
    fprintf(stdout, "    RSS before: %.1f MB, after: %.1f MB, growth: %.1f MB\n",
            (double)rssBefore / (1024.0 * 1024.0),
            (double)rssAfter / (1024.0 * 1024.0),
            growthMB);

    // Allow negative growth (memory freed). Threshold 100MB allows for OS-level
    // memory fluctuations while still catching real accumulating leaks.
    BOOL ok = growthMB < 100.0;
    NSString *rssMsg = [NSString stringWithFormat:@"RSS growth %.1f MB >= 100 MB", growthMB];
    ASSERT_TRUE(name, ok, rssMsg);

    reportResult(name, YES, nil);
}

static void test_m11_memory_peak(MWTranscriber *turbo, NSString *dataDir) {
    const char *name = "m11_memory_peak";

    NSString *path = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    ASSERT_TRUE(name, [[NSFileManager defaultManager] fileExistsAtPath:path],
                @"physicsworks.wav not found");

    NSURL *url = [NSURL fileURLWithPath:path];
    NSError *error = nil;

    // Track peak RSS during transcription.
    __block size_t peakRSS = getCurrentRSS();
    NSArray *segments = [turbo transcribeURL:url
                                   language:@"en"
                                       task:@"transcribe"
                                    options:@{@"temperatures": @[@0.0]}
                             segmentHandler:^(MWTranscriptionSegment *seg, BOOL *stop) {
                                 size_t rss = getCurrentRSS();
                                 if (rss > peakRSS) peakRSS = rss;
                             }
                                       info:nil
                                      error:&error];

    // Also check after completion.
    size_t rssNow = getCurrentRSS();
    if (rssNow > peakRSS) peakRSS = rssNow;

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribe failed", error));

    double peakMB = (double)peakRSS / (1024.0 * 1024.0);
    fprintf(stdout, "    peak RSS during 203s transcription: %.1f MB\n", peakMB);
    NSString *peakMsg = [NSString stringWithFormat:@"peak RSS %.1f MB >= 3000 MB", peakMB];
    ASSERT_TRUE(name, peakMB < 3000.0, peakMsg);

    reportResult(name, YES, nil);
}

// ============================================================================
// Main
// ============================================================================

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);

        if (argc < 3) {
            fprintf(stderr, "Usage: %s <turbo_model_path> <data_dir>\n", argv[0]);
            return 1;
        }

        NSString *turboModelPath = [NSString stringWithUTF8String:argv[1]];
        NSString *dataDir = [NSString stringWithUTF8String:argv[2]];

        fprintf(stdout, "=== M11 Validation Suite ===\n");
        fprintf(stdout, "Turbo model: %s\n", [turboModelPath UTF8String]);
        fprintf(stdout, "Data dir:    %s\n\n", [dataDir UTF8String]);

        // ── Load turbo model ────────────────────────────────────────────
        fprintf(stdout, "Loading turbo model...\n");
        NSError *error = nil;
        double t0 = now_ms();
        MWTranscriber *turbo = [[MWTranscriber alloc] initWithModelPath:turboModelPath
                                                                  error:&error];
        double loadMs = now_ms() - t0;
        if (!turbo) {
            fprintf(stderr, "FATAL: Failed to load turbo model: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
        }
        fprintf(stdout, "Turbo model loaded in %.0f ms\n\n", loadMs);

        // ── Resolve tiny model ──────────────────────────────────────────
        MWTranscriber *tiny = nil;
        MWModelManager *mm = [MWModelManager shared];
        BOOL tinyAvailable = [mm isModelCached:@"tiny"];
        if (tinyAvailable) {
            NSString *tinyPath = [mm resolveModel:@"tiny" progress:nil error:&error];
            if (tinyPath) {
                fprintf(stdout, "Loading tiny model from %s...\n", [tinyPath UTF8String]);
                double t1 = now_ms();
                tiny = [[MWTranscriber alloc] initWithModelPath:tinyPath error:&error];
                if (tiny) {
                    fprintf(stdout, "Tiny model loaded in %.0f ms\n\n", now_ms() - t1);
                } else {
                    fprintf(stdout, "WARNING: Failed to load tiny model: %s\n\n",
                            [[error localizedDescription] UTF8String]);
                }
            }
        } else {
            fprintf(stdout, "SKIP: tiny model not cached, tiny-specific tests will be skipped\n\n");
        }

        // ── Section 1: Accuracy ─────────────────────────────────────────
        fprintf(stdout, "--- Section 1: Accuracy ---\n");

        if (tiny) {
            test_m11_jfk_tiny(tiny, dataDir);
        } else {
            fprintf(stdout, "  SKIP: m11_jfk_tiny (tiny model not available)\n");
        }

        test_m11_jfk_turbo(turbo, dataDir);
        test_m11_multi_format(turbo, dataDir);
        test_m11_word_timestamps_monotonic(turbo, dataDir);
        test_m11_segment_timestamps_valid(turbo, dataDir);

        // ── Section 2: Performance ──────────────────────────────────────
        fprintf(stdout, "\n--- Section 2: Performance ---\n");

        test_m11_rtf_turbo(turbo, dataDir);

        if (tiny) {
            test_m11_rtf_tiny(tiny, dataDir);
        } else {
            fprintf(stdout, "  SKIP: m11_rtf_tiny (tiny model not available)\n");
        }

        // ── Section 3: Edge Cases ───────────────────────────────────────
        fprintf(stdout, "\n--- Section 3: Edge Cases ---\n");

        test_m11_empty_audio(turbo);
        test_m11_very_short_audio(turbo);
        test_m11_stereo_input(turbo, dataDir);
        test_m11_mp3_input(turbo, dataDir);
        test_m11_corrupt_file(turbo);

        // ── Section 4: Memory ───────────────────────────────────────────
        fprintf(stdout, "\n--- Section 4: Memory ---\n");

        test_m11_memory_sequential(turbo, dataDir);
        test_m11_memory_peak(turbo, dataDir);

        // ── Summary ─────────────────────────────────────────────────────
        fprintf(stdout, "\n=== M11 Validation Complete: %d passed, %d failed ===\n",
                gPassCount, gFailCount);

        [tiny release];
        [turbo release];

        return gFailCount > 0 ? 1 : 0;
    }
}
