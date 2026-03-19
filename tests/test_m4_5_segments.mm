#import <Foundation/Foundation.h>
#import "MWTranscriber.h"
#import "MWTokenizer.h"
#import "MWConstants.h"

// ── Test infrastructure ──────────────────────────────────────────────────────

static int gPassCount = 0;
static int gFailCount = 0;

static void reportResult(const char *testName, BOOL passed, NSString *detail) {
    if (passed) {
        fprintf(stdout, "  PASS: %s\n", testName);
        gPassCount++;
    } else {
        fprintf(stdout, "  FAIL: %s — %s\n", testName, detail ? [detail UTF8String] : "(no detail)");
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

#define ASSERT_FLOAT_EQ(name, actual, expected, eps) do { \
    float _a = (float)(actual); float _e = (float)(expected); \
    if (fabsf(_a - _e) > (eps)) { \
        reportResult(name, NO, [NSString stringWithFormat:@"expected %.4f, got %.4f", _e, _a]); \
        return; \
    } \
} while (0)

static NSString *fmtErr(NSString *prefix, NSError *error) {
    return [NSString stringWithFormat:@"%@: %@", prefix, [error localizedDescription]];
}

// ── Helper: make timestamp token ─────────────────────────────────────────────

static NSNumber *tsToken(NSUInteger tsBegin, float seconds) {
    return @(tsBegin + (NSUInteger)(seconds / kMWTimePrecision));
}

// ── Tests ────────────────────────────────────────────────────────────────────

/// Test basic split with 2 timestamp pairs producing 2 segments.
static void test_m4_5_basic_split(MWTranscriber *t) {
    const char *name = "m4_5_basic_split";
    NSUInteger tsBegin = t.tokenizer.timestampBegin;

    // [ts(0.00), text1, text2, ts(2.50), ts(2.50), text3, ts(5.00)]
    NSArray<NSNumber *> *tokens = @[
        tsToken(tsBegin, 0.00f),  // timestamp 0.00
        @(100),                   // text token
        @(200),                   // text token
        tsToken(tsBegin, 2.50f),  // timestamp 2.50
        tsToken(tsBegin, 2.50f),  // timestamp 2.50 (consecutive pair)
        @(300),                   // text token
        tsToken(tsBegin, 5.00f),  // timestamp 5.00
    ];

    NSUInteger outSeek = 0;
    BOOL outSingleEnding = NO;
    NSArray<MWSegmentInfo *> *segs = [t splitSegmentsByTimestamps:tokens
                                                      timeOffset:0.0f
                                                     segmentSize:3000
                                                 segmentDuration:30.0f
                                                            seek:0
                                                         outSeek:&outSeek
                                          outSingleTimestampEnding:&outSingleEnding];

    ASSERT_EQ(name, [segs count], 2);
    ASSERT_FLOAT_EQ(name, segs[0].startTime, 0.0f, 0.01f);
    ASSERT_FLOAT_EQ(name, segs[0].endTime, 2.5f, 0.01f);
    ASSERT_FLOAT_EQ(name, segs[1].startTime, 2.5f, 0.01f);
    ASSERT_FLOAT_EQ(name, segs[1].endTime, 5.0f, 0.01f);
    // tokens[-2] = 300 (text) < tsBegin, tokens[-1] = ts(5.00) >= tsBegin
    // => single_timestamp_ending = YES
    ASSERT_TRUE(name, outSingleEnding, @"should be single timestamp ending");

    // With singleTimestampEnding + consecutive timestamps, seek += segmentSize = 3000
    ASSERT_EQ(name, outSeek, 3000);

    reportResult(name, YES, nil);
}

/// Test single timestamp ending: tokens ending with a single timestamp.
static void test_m4_5_single_ending(MWTranscriber *t) {
    const char *name = "m4_5_single_ending";
    NSUInteger tsBegin = t.tokenizer.timestampBegin;

    // [ts(0.00), text1, text2, ts(3.00)]
    // second-to-last (text2) < tsBegin, last >= tsBegin => single_timestamp_ending
    NSArray<NSNumber *> *tokens = @[
        tsToken(tsBegin, 0.00f),
        @(100),
        @(200),
        tsToken(tsBegin, 3.00f),
    ];

    NSUInteger outSeek = 0;
    BOOL outSingleEnding = NO;
    NSArray<MWSegmentInfo *> *segs = [t splitSegmentsByTimestamps:tokens
                                                      timeOffset:0.0f
                                                     segmentSize:3000
                                                 segmentDuration:30.0f
                                                            seek:0
                                                         outSeek:&outSeek
                                          outSingleTimestampEnding:&outSingleEnding];

    ASSERT_TRUE(name, outSingleEnding, @"should be single timestamp ending");

    // No consecutive timestamps => single segment, duration from last timestamp
    // last_timestamp_position = 3.0/0.02 = 150, duration = 150 * 0.02 = 3.0
    ASSERT_EQ(name, [segs count], 1);
    ASSERT_FLOAT_EQ(name, segs[0].startTime, 0.0f, 0.01f);
    ASSERT_FLOAT_EQ(name, segs[0].endTime, 3.0f, 0.01f);

    // seek should advance by segmentSize (3000)
    ASSERT_EQ(name, outSeek, 3000);

    reportResult(name, YES, nil);
}

/// Test with no timestamp tokens at all.
static void test_m4_5_no_timestamps(MWTranscriber *t) {
    const char *name = "m4_5_no_timestamps";

    // All text tokens, no timestamps
    NSArray<NSNumber *> *tokens = @[@(100), @(200), @(300)];

    NSUInteger outSeek = 0;
    BOOL outSingleEnding = NO;
    NSArray<MWSegmentInfo *> *segs = [t splitSegmentsByTimestamps:tokens
                                                      timeOffset:0.0f
                                                     segmentSize:3000
                                                 segmentDuration:30.0f
                                                            seek:0
                                                         outSeek:&outSeek
                                          outSingleTimestampEnding:&outSingleEnding];

    ASSERT_EQ(name, [segs count], 1);
    ASSERT_FLOAT_EQ(name, segs[0].startTime, 0.0f, 0.01f);
    ASSERT_FLOAT_EQ(name, segs[0].endTime, 30.0f, 0.01f);
    ASSERT_TRUE(name, !outSingleEnding, @"should not be single timestamp ending");
    ASSERT_EQ(name, outSeek, 3000);

    reportResult(name, YES, nil);
}

/// Test 3 consecutive timestamp pairs producing 3 segments.
static void test_m4_5_consecutive(MWTranscriber *t) {
    const char *name = "m4_5_consecutive";
    NSUInteger tsBegin = t.tokenizer.timestampBegin;

    // [ts(0.00), text1, ts(1.00), ts(1.00), text2, ts(2.00), ts(2.00), text3, ts(3.00)]
    NSArray<NSNumber *> *tokens = @[
        tsToken(tsBegin, 0.00f),
        @(100),
        tsToken(tsBegin, 1.00f),
        tsToken(tsBegin, 1.00f),
        @(200),
        tsToken(tsBegin, 2.00f),
        tsToken(tsBegin, 2.00f),
        @(300),
        tsToken(tsBegin, 3.00f),
    ];

    NSUInteger outSeek = 0;
    BOOL outSingleEnding = NO;
    NSArray<MWSegmentInfo *> *segs = [t splitSegmentsByTimestamps:tokens
                                                      timeOffset:0.0f
                                                     segmentSize:3000
                                                 segmentDuration:30.0f
                                                            seek:0
                                                         outSeek:&outSeek
                                          outSingleTimestampEnding:&outSingleEnding];

    ASSERT_EQ(name, [segs count], 3);
    ASSERT_FLOAT_EQ(name, segs[0].startTime, 0.0f, 0.01f);
    ASSERT_FLOAT_EQ(name, segs[0].endTime, 1.0f, 0.01f);
    ASSERT_FLOAT_EQ(name, segs[1].startTime, 1.0f, 0.01f);
    ASSERT_FLOAT_EQ(name, segs[1].endTime, 2.0f, 0.01f);
    ASSERT_FLOAT_EQ(name, segs[2].startTime, 2.0f, 0.01f);
    ASSERT_FLOAT_EQ(name, segs[2].endTime, 3.0f, 0.01f);

    // No single timestamp ending (last two are: @(300), ts(3.00) => single ending?
    // Actually: tokens[-2] = @(300) < tsBegin, tokens[-1] = ts(3.00) >= tsBegin => YES
    ASSERT_TRUE(name, outSingleEnding, @"should be single timestamp ending");

    // With single_timestamp_ending, consecutive timestamps exist, and slices includes len(tokens).
    // So all tokens are consumed. seek += segmentSize = 3000
    ASSERT_EQ(name, outSeek, 3000);

    reportResult(name, YES, nil);
}

/// Test time offset is applied correctly.
static void test_m4_5_time_offset(MWTranscriber *t) {
    const char *name = "m4_5_time_offset";
    NSUInteger tsBegin = t.tokenizer.timestampBegin;

    // Same as basic_split but with timeOffset=30.0
    NSArray<NSNumber *> *tokens = @[
        tsToken(tsBegin, 0.00f),
        @(100),
        @(200),
        tsToken(tsBegin, 2.50f),
        tsToken(tsBegin, 2.50f),
        @(300),
        tsToken(tsBegin, 5.00f),
    ];

    NSUInteger outSeek = 0;
    BOOL outSingleEnding = NO;
    NSArray<MWSegmentInfo *> *segs = [t splitSegmentsByTimestamps:tokens
                                                      timeOffset:30.0f
                                                     segmentSize:3000
                                                 segmentDuration:30.0f
                                                            seek:3000
                                                         outSeek:&outSeek
                                          outSingleTimestampEnding:&outSingleEnding];

    ASSERT_EQ(name, [segs count], 2);
    ASSERT_FLOAT_EQ(name, segs[0].startTime, 30.0f, 0.01f);
    ASSERT_FLOAT_EQ(name, segs[0].endTime, 32.5f, 0.01f);
    ASSERT_FLOAT_EQ(name, segs[1].startTime, 32.5f, 0.01f);
    ASSERT_FLOAT_EQ(name, segs[1].endTime, 35.0f, 0.01f);

    // singleTimestampEnding=YES => seek = 3000 + segmentSize(3000) = 6000
    ASSERT_EQ(name, outSeek, 6000);

    reportResult(name, YES, nil);
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: %s <model_path>\n", argv[0]);
            return 1;
        }

        NSString *modelPath = [NSString stringWithUTF8String:argv[1]];
        fprintf(stdout, "[test_m4_5_segments] Loading model: %s\n", [modelPath UTF8String]);

        NSError *error = nil;
        MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
        if (!t) {
            fprintf(stderr, "FATAL: Failed to load model: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
        }

        fprintf(stdout, "[test_m4_5_segments] timestampBegin = %lu\n",
                (unsigned long)t.tokenizer.timestampBegin);
        fprintf(stdout, "[test_m4_5_segments] timePrecision = %.4f\n", t.timePrecision);
        fprintf(stdout, "[test_m4_5_segments] inputStride = %lu\n", (unsigned long)t.inputStride);

        test_m4_5_basic_split(t);
        test_m4_5_single_ending(t);
        test_m4_5_no_timestamps(t);
        test_m4_5_consecutive(t);
        test_m4_5_time_offset(t);

        [t release];

        fprintf(stdout, "\n[test_m4_5_segments] %d passed, %d failed\n", gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
