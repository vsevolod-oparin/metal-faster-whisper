#import <Foundation/Foundation.h>
#import "MWTranscriber.h"
#import "MWAudioDecoder.h"
#import "MWConstants.h"

// ── Test infrastructure ──────────────────────────────────────────────────────

static int gPassCount = 0;
static int gFailCount = 0;

static void reportResult(const char *testName, BOOL passed, NSString *detail) {
    if (passed) {
        fprintf(stdout, "  PASS: %s\n", testName);
        gPassCount++;
    } else {
        fprintf(stdout, "  FAIL: %s -- %s\n", testName, detail ? [detail UTF8String] : "(no detail)");
        gFailCount++;
    }
}

#define ASSERT_TRUE(name, cond, msg) do { \
    if (!(cond)) { \
        reportResult((name), NO, (msg)); \
        return; \
    } \
} while (0)

#define ASSERT_EQ(name, actual, expected) do { \
    long _a = (long)(actual); long _e = (long)(expected); \
    if (_a != _e) { \
        reportResult(name, NO, [NSString stringWithFormat:@"expected %ld, got %ld", _e, _a]); \
        return; \
    } \
} while (0)

static NSString *fmtErr(NSString *prefix, NSError *error) {
    return [NSString stringWithFormat:@"%@: %@", prefix, [error localizedDescription]];
}

// ── Tests ────────────────────────────────────────────────────────────────────

/// Test 1: Transcribe jfk.flac (11s short audio).
static void test_m4_6_short_audio(MWTranscriber *t, NSString *dataDir) {
    const char *name = "m4_6_short_audio";

    NSString *path = [dataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSURL *url = [NSURL fileURLWithPath:path];

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    ASSERT_TRUE(name, exists, @"Test audio jfk.flac not found");

    MWTranscriptionInfo *info = nil;
    NSError *error = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeURL:url
                language:nil
                    task:@"transcribe"
                 options:nil
          segmentHandler:nil
                    info:&info
                   error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeURL failed", error));
    ASSERT_TRUE(name, [segments count] > 0, @"expected non-empty segments");

    // All segment start < end.
    for (MWTranscriptionSegment *seg in segments) {
        BOOL valid = (seg.start < seg.end);
        ASSERT_TRUE(name, valid, @"segment start >= end");
    }

    // All timestamps within [0, 12] seconds (audio is ~11s).
    for (MWTranscriptionSegment *seg in segments) {
        BOOL inRange = (seg.start >= 0.0f && seg.end <= 12.0f);
        ASSERT_TRUE(name, inRange, @"segment timestamps out of range");
    }

    // Concatenated text should contain recognizable English.
    NSMutableString *fullText = [[NSMutableString alloc] init];
    for (MWTranscriptionSegment *seg in segments) {
        [fullText appendString:seg.text];
    }
    fprintf(stdout, "    Text: %s\n", [fullText UTF8String]);

    // JFK speech: expect some recognizable words.
    NSString *lower = [fullText lowercaseString];
    BOOL hasEnglish = ([lower rangeOfString:@"country"].location != NSNotFound ||
                       [lower rangeOfString:@"ask"].location != NSNotFound ||
                       [lower rangeOfString:@"what"].location != NSNotFound ||
                       [lower rangeOfString:@"your"].location != NSNotFound ||
                       [lower rangeOfString:@"fellow"].location != NSNotFound ||
                       [lower rangeOfString:@"do"].location != NSNotFound);
    ASSERT_TRUE(name, hasEnglish, @"text does not contain recognizable English words");

    // Info check.
    ASSERT_TRUE(name, info != nil, @"info should not be nil");
    BOOL isEnglish = [info.language isEqualToString:@"en"];
    ASSERT_TRUE(name, isEnglish, @"expected language 'en'");

    fprintf(stdout, "    Language: %s (%.2f), Duration: %.2fs, Segments: %lu\n",
            [info.language UTF8String], info.languageProbability,
            info.duration, (unsigned long)[segments count]);

    [fullText release];
    reportResult(name, YES, nil);
}

/// Test 2: Transcribe first ~60s of physicsworks.wav.
static void test_m4_6_long_audio(MWTranscriber *t, NSString *dataDir) {
    const char *name = "m4_6_long_audio";

    NSString *path = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSURL *url = [NSURL fileURLWithPath:path];

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    ASSERT_TRUE(name, exists, @"Test audio physicsworks.wav not found");

    // Decode and truncate to ~60s to keep test fast.
    NSError *decodeError = nil;
    NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:url error:&decodeError];
    ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"Audio decode failed", decodeError));

    NSUInteger maxSamples = 60 * kMWTargetSampleRate;  // 60s
    NSUInteger totalSamples = [fullAudio length] / sizeof(float);
    NSData *audio = fullAudio;
    if (totalSamples > maxSamples) {
        audio = [NSData dataWithBytes:[fullAudio bytes] length:maxSamples * sizeof(float)];
    }

    MWTranscriptionInfo *info = nil;
    NSError *error = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeAudio:audio
                  language:@"en"
                      task:@"transcribe"
                   options:nil
            segmentHandler:nil
                      info:&info
                     error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeAudio failed", error));
    ASSERT_TRUE(name, [segments count] > 1, @"expected multiple segments");

    // Timestamps should be monotonically non-decreasing.
    for (NSUInteger i = 1; i < [segments count]; i++) {
        BOOL mono = (segments[i].start >= segments[i-1].start);
        ASSERT_TRUE(name, mono, @"timestamps not monotonically increasing");
    }

    // Last segment end should be close to 60s (within tolerance).
    float lastEnd = [[segments lastObject] end];
    BOOL nearEnd = (lastEnd > 50.0f && lastEnd <= 65.0f);
    ASSERT_TRUE(name, nearEnd, @"last segment end not near 60s");

    // Print summary.
    fprintf(stdout, "    Segments: %lu, Last end: %.2fs\n",
            (unsigned long)[segments count], lastEnd);
    for (MWTranscriptionSegment *seg in segments) {
        fprintf(stdout, "    [%.2f -> %.2f] %s\n", seg.start, seg.end, [seg.text UTF8String]);
    }

    reportResult(name, YES, nil);
}

/// Test 3: Streaming callback counts match.
static void test_m4_6_callback_streaming(MWTranscriber *t, NSString *dataDir) {
    const char *name = "m4_6_callback_streaming";

    NSString *path = [dataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSURL *url = [NSURL fileURLWithPath:path];

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    ASSERT_TRUE(name, exists, @"Test audio jfk.flac not found");

    __block NSUInteger callbackCount = 0;
    NSError *error = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeURL:url
                language:@"en"
                    task:@"transcribe"
                 options:nil
          segmentHandler:^(MWTranscriptionSegment *segment, BOOL *stop) {
              callbackCount++;
              fprintf(stdout, "    Callback %lu: [%.2f -> %.2f] %s\n",
                      (unsigned long)callbackCount, segment.start, segment.end,
                      [segment.text UTF8String]);
          }
                    info:nil
                   error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeURL failed", error));
    BOOL countMatch = (callbackCount == [segments count]);
    ASSERT_TRUE(name, countMatch, @"callback count != segment count");

    reportResult(name, YES, nil);
}

/// Test 4: Empty audio produces empty segments, no crash.
static void test_m4_6_empty_audio(MWTranscriber *t) {
    const char *name = "m4_6_empty_audio";

    NSData *emptyAudio = [NSData data];
    NSError *error = nil;
    MWTranscriptionInfo *info = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeAudio:emptyAudio
                  language:@"en"
                      task:@"transcribe"
                   options:nil
            segmentHandler:nil
                      info:&info
                     error:&error];

    ASSERT_TRUE(name, segments != nil, @"should not return nil for empty audio");
    ASSERT_EQ(name, [segments count], 0);
    ASSERT_TRUE(name, info != nil, @"info should not be nil");
    BOOL zeroDuration = (info.duration < 0.01f);
    ASSERT_TRUE(name, zeroDuration, @"expected duration ~0 for empty audio");

    // Also test nil audio.
    segments = [t transcribeAudio:nil
                         language:@"en"
                             task:@"transcribe"
                          options:nil
                   segmentHandler:nil
                             info:nil
                            error:&error];

    ASSERT_TRUE(name, segments != nil, @"nil audio should return empty array");
    ASSERT_EQ(name, [segments count], 0);

    reportResult(name, YES, nil);
}

/// Test 5: conditionOnPreviousText=YES vs NO both produce output.
static void test_m4_6_condition_previous(MWTranscriber *t, NSString *dataDir) {
    const char *name = "m4_6_condition_previous";

    NSString *path = [dataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSURL *url = [NSURL fileURLWithPath:path];

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    ASSERT_TRUE(name, exists, @"Test audio jfk.flac not found");

    // With conditionOnPreviousText=YES (default).
    NSError *error1 = nil;
    NSArray<MWTranscriptionSegment *> *segsYes =
        [t transcribeURL:url
                language:@"en"
                    task:@"transcribe"
                 options:@{@"conditionOnPreviousText": @YES}
          segmentHandler:nil
                    info:nil
                   error:&error1];

    ASSERT_TRUE(name, segsYes != nil, fmtErr(@"transcribe with condition=YES failed", error1));
    ASSERT_TRUE(name, [segsYes count] > 0, @"condition=YES produced no segments");

    // With conditionOnPreviousText=NO.
    NSError *error2 = nil;
    NSArray<MWTranscriptionSegment *> *segsNo =
        [t transcribeURL:url
                language:@"en"
                    task:@"transcribe"
                 options:@{@"conditionOnPreviousText": @NO}
          segmentHandler:nil
                    info:nil
                   error:&error2];

    ASSERT_TRUE(name, segsNo != nil, fmtErr(@"transcribe with condition=NO failed", error2));
    ASSERT_TRUE(name, [segsNo count] > 0, @"condition=NO produced no segments");

    fprintf(stdout, "    condition=YES: %lu segments, condition=NO: %lu segments\n",
            (unsigned long)[segsYes count], (unsigned long)[segsNo count]);

    reportResult(name, YES, nil);
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "Usage: %s <model_path> <data_dir>\n", argv[0]);
            return 1;
        }

        NSString *modelPath = [NSString stringWithUTF8String:argv[1]];
        NSString *dataDir = [NSString stringWithUTF8String:argv[2]];

        fprintf(stdout, "[test_m4_6_transcribe] Loading model: %s\n", [modelPath UTF8String]);
        fprintf(stdout, "[test_m4_6_transcribe] Data dir: %s\n", [dataDir UTF8String]);

        NSError *error = nil;
        MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
        if (!t) {
            fprintf(stderr, "FATAL: Failed to load model: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
        }

        test_m4_6_short_audio(t, dataDir);
        test_m4_6_long_audio(t, dataDir);
        test_m4_6_callback_streaming(t, dataDir);
        test_m4_6_empty_audio(t);
        test_m4_6_condition_previous(t, dataDir);

        [t release];

        fprintf(stdout, "\n[test_m4_6_transcribe] %d passed, %d failed\n", gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
