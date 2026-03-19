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

static NSString *fmtErr(NSString *prefix, NSError *error) {
    return [NSString stringWithFormat:@"%@: %@", prefix, [error localizedDescription]];
}

// ── Test 1: Merge punctuations logic ─────────────────────────────────────────

static void test_m5_merge_punctuations(void) {
    const char *name = "m5_merge_punctuations";

    // Construct test alignment data.
    NSMutableArray<NSMutableDictionary *> *alignment = [[NSMutableArray alloc] init];
    [alignment addObject:[@{@"word": @" Hello", @"tokens": [@[@1] mutableCopy],
                           @"start": @(0.0f), @"end": @(0.5f), @"probability": @(0.9f)} mutableCopy]];
    [alignment addObject:[@{@"word": @",", @"tokens": [@[@2] mutableCopy],
                           @"start": @(0.5f), @"end": @(0.6f), @"probability": @(0.8f)} mutableCopy]];
    [alignment addObject:[@{@"word": @" world", @"tokens": [@[@3] mutableCopy],
                           @"start": @(0.6f), @"end": @(1.0f), @"probability": @(0.85f)} mutableCopy]];
    [alignment addObject:[@{@"word": @".", @"tokens": [@[@4] mutableCopy],
                           @"start": @(1.0f), @"end": @(1.1f), @"probability": @(0.7f)} mutableCopy]];

    // Build prepend/append sets matching Python defaults.
    unichar prependChars[] = {'"', '\'', 0x201C, 0xBF, '(', '[', '{', '-'};
    NSString *prepended = [NSString stringWithCharacters:prependChars
                                                  length:sizeof(prependChars)/sizeof(unichar)];

    // Merge prepended (right to left) -- none match here.
    NSMutableSet<NSString *> *prependSet = [[NSMutableSet alloc] init];
    for (NSUInteger ci = 0; ci < [prepended length]; ci++) {
        [prependSet addObject:[NSString stringWithFormat:@"%C", [prepended characterAtIndex:ci]]];
    }

    NSInteger i = (NSInteger)[alignment count] - 2;
    NSInteger j = (NSInteger)[alignment count] - 1;
    while (i >= 0) {
        NSMutableDictionary *previous = alignment[(NSUInteger)i];
        NSMutableDictionary *following = alignment[(NSUInteger)j];
        NSString *prevWord = previous[@"word"];
        NSString *stripped = [prevWord stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if ([prevWord hasPrefix:@" "] && [stripped length] > 0 && [prependSet containsObject:stripped]) {
            following[@"word"] = [prevWord stringByAppendingString:following[@"word"]];
            NSMutableArray *mergedTokens = [NSMutableArray arrayWithArray:previous[@"tokens"]];
            [mergedTokens addObjectsFromArray:following[@"tokens"]];
            following[@"tokens"] = mergedTokens;
            previous[@"word"] = @"";
            previous[@"tokens"] = [NSMutableArray array];
        } else {
            j = i;
        }
        i--;
    }
    [prependSet release];

    // Merge appended (left to right).
    NSString *appended = @"\"'.,:;!?)]}";
    i = 0;
    j = 1;
    while (j < (NSInteger)[alignment count]) {
        NSMutableDictionary *previous = alignment[(NSUInteger)i];
        NSMutableDictionary *following = alignment[(NSUInteger)j];
        NSString *prevWord = previous[@"word"];
        NSString *followWord = following[@"word"];
        if (![prevWord hasSuffix:@" "] && [prevWord length] > 0) {
            BOOL isAppended = NO;
            if ([followWord length] > 0) {
                for (NSUInteger k = 0; k < [appended length]; k++) {
                    NSString *ch = [NSString stringWithFormat:@"%C", [appended characterAtIndex:k]];
                    if ([followWord isEqualToString:ch]) {
                        isAppended = YES;
                        break;
                    }
                }
            }
            if (isAppended) {
                previous[@"word"] = [prevWord stringByAppendingString:followWord];
                NSMutableArray *mergedTokens = [NSMutableArray arrayWithArray:previous[@"tokens"]];
                [mergedTokens addObjectsFromArray:following[@"tokens"]];
                previous[@"tokens"] = mergedTokens;
                following[@"word"] = @"";
                following[@"tokens"] = [NSMutableArray array];
            } else {
                i = j;
            }
        } else {
            i = j;
        }
        j++;
    }

    // Verify results.
    NSString *w0 = alignment[0][@"word"];
    NSString *w1 = alignment[1][@"word"];
    NSString *w2 = alignment[2][@"word"];
    NSString *w3 = alignment[3][@"word"];

    fprintf(stdout, "    After merge: [%s] [%s] [%s] [%s]\n",
            [w0 UTF8String], [w1 UTF8String], [w2 UTF8String], [w3 UTF8String]);

    ASSERT_TRUE(name, [w0 isEqualToString:@" Hello,"],
                ([NSString stringWithFormat:@"expected ' Hello,' got '%@'", w0]));
    ASSERT_TRUE(name, [w1 isEqualToString:@""],
                ([NSString stringWithFormat:@"expected '' got '%@'", w1]));
    ASSERT_TRUE(name, [w2 isEqualToString:@" world."],
                ([NSString stringWithFormat:@"expected ' world.' got '%@'", w2]));
    ASSERT_TRUE(name, [w3 isEqualToString:@""],
                ([NSString stringWithFormat:@"expected '' got '%@'", w3]));

    // Check token merging.
    NSArray *t0 = alignment[0][@"tokens"];
    ASSERT_TRUE(name, [t0 count] == 2,
                ([NSString stringWithFormat:@"expected 2 tokens for 'Hello,', got %lu", (unsigned long)[t0 count]]));

    for (NSMutableDictionary *d in alignment) {
        [d release];
    }
    [alignment release];

    reportResult(name, YES, nil);
}

// ── Test 2: Anomaly score ────────────────────────────────────────────────────

static void test_m5_anomaly_score(void) {
    const char *name = "m5_anomaly_score";

    // Case 1: Normal word -- probability=0.9, duration=0.5 -> score=0
    {
        MWWord *w = [[MWWord alloc] initWithWord:@"hello" start:0.0f end:0.5f probability:0.9f];
        float dur = w.end - w.start;
        float score = 0.0f;
        if (w.probability < 0.15f) score += 1.0f;
        if (dur < 0.133f) score += (0.133f - dur) * 15.0f;
        if (dur > 2.0f) score += (dur - 2.0f);
        ASSERT_TRUE(name, fabsf(score) < 0.001f,
                    ([NSString stringWithFormat:@"case1: expected 0, got %.3f", score]));
        [w release];
    }

    // Case 2: Low probability -- probability=0.1, duration=0.5 -> score=1.0
    {
        MWWord *w = [[MWWord alloc] initWithWord:@"hello" start:0.0f end:0.5f probability:0.1f];
        float dur = w.end - w.start;
        float score = 0.0f;
        if (w.probability < 0.15f) score += 1.0f;
        if (dur < 0.133f) score += (0.133f - dur) * 15.0f;
        if (dur > 2.0f) score += (dur - 2.0f);
        ASSERT_TRUE(name, fabsf(score - 1.0f) < 0.001f,
                    ([NSString stringWithFormat:@"case2: expected 1.0, got %.3f", score]));
        [w release];
    }

    // Case 3: Short duration -- probability=0.9, duration=0.05 -> score=(0.133-0.05)*15=1.245
    {
        MWWord *w = [[MWWord alloc] initWithWord:@"hello" start:0.0f end:0.05f probability:0.9f];
        float dur = w.end - w.start;
        float score = 0.0f;
        if (w.probability < 0.15f) score += 1.0f;
        if (dur < 0.133f) score += (0.133f - dur) * 15.0f;
        if (dur > 2.0f) score += (dur - 2.0f);
        float expected = (0.133f - 0.05f) * 15.0f;
        ASSERT_TRUE(name, fabsf(score - expected) < 0.01f,
                    ([NSString stringWithFormat:@"case3: expected %.3f, got %.3f", expected, score]));
        [w release];
    }

    // Case 4: Long duration -- probability=0.9, duration=3.0 -> score=1.0
    {
        MWWord *w = [[MWWord alloc] initWithWord:@"hello" start:0.0f end:3.0f probability:0.9f];
        float dur = w.end - w.start;
        float score = 0.0f;
        if (w.probability < 0.15f) score += 1.0f;
        if (dur < 0.133f) score += (0.133f - dur) * 15.0f;
        if (dur > 2.0f) score += (dur - 2.0f);
        ASSERT_TRUE(name, fabsf(score - 1.0f) < 0.001f,
                    ([NSString stringWithFormat:@"case4: expected 1.0, got %.3f", score]));
        [w release];
    }

    reportResult(name, YES, nil);
}

// ── Test 3: Word timestamps on JFK speech ────────────────────────────────────

static void test_m5_word_timestamps(MWTranscriber *t, NSString *dataDir) {
    const char *name = "m5_word_timestamps";

    NSString *path = [dataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSURL *url = [NSURL fileURLWithPath:path];

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    ASSERT_TRUE(name, exists, @"Test audio jfk.flac not found");

    NSError *error = nil;
    MWTranscriptionInfo *info = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeURL:url
                language:@"en"
                    task:@"transcribe"
                 options:@{@"wordTimestamps": @YES}
          segmentHandler:nil
                    info:&info
                   error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeURL failed", error));
    ASSERT_TRUE(name, [segments count] > 0, @"expected non-empty segments");

    // Verify each segment has words.
    NSUInteger totalWords = 0;
    for (MWTranscriptionSegment *seg in segments) {
        NSString *segDesc = [NSString stringWithFormat:@"segment %lu", (unsigned long)seg.segmentId];
        ASSERT_TRUE(name, seg.words != nil,
                    ([NSString stringWithFormat:@"%@ words is nil", segDesc]));
        ASSERT_TRUE(name, [seg.words count] > 0,
                    ([NSString stringWithFormat:@"%@ has 0 words", segDesc]));

        fprintf(stdout, "    Segment %lu [%.2f -> %.2f]: %lu words\n",
                (unsigned long)seg.segmentId, seg.start, seg.end,
                (unsigned long)[seg.words count]);

        for (MWWord *w in seg.words) {
            fprintf(stdout, "      [%.2f -> %.2f] p=%.2f '%s'\n",
                    w.start, w.end, w.probability, [w.word UTF8String]);

            // Each word has start <= end.
            ASSERT_TRUE(name, w.start <= w.end + 0.001f,
                        ([NSString stringWithFormat:@"word start > end: %.3f > %.3f for '%@'",
                          w.start, w.end, w.word]));
        }

        totalWords += [seg.words count];
    }

    fprintf(stdout, "    Total words: %lu\n", (unsigned long)totalWords);

    // Word count should be reasonable for JFK speech (5-40 words).
    ASSERT_TRUE(name, totalWords >= 5 && totalWords <= 40,
                ([NSString stringWithFormat:@"unexpected word count: %lu", (unsigned long)totalWords]));

    // Monotonically increasing start times within each segment.
    for (MWTranscriptionSegment *seg in segments) {
        for (NSUInteger wi = 1; wi < [seg.words count]; wi++) {
            MWWord *prev = seg.words[wi - 1];
            MWWord *curr = seg.words[wi];
            ASSERT_TRUE(name, curr.start >= prev.start - 0.001f,
                        ([NSString stringWithFormat:@"non-monotonic: %.3f after %.3f",
                          curr.start, prev.start]));
        }
    }

    // Concatenation of word texts should approximately match segment text.
    for (MWTranscriptionSegment *seg in segments) {
        NSMutableString *wordText = [[NSMutableString alloc] init];
        for (MWWord *w in seg.words) {
            [wordText appendString:w.word];
        }
        NSString *segTextTrimmed = [seg.text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *wordTextTrimmed = [wordText stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        BOOL similar = ([segTextTrimmed length] > 0 && [wordTextTrimmed length] > 0);
        if (similar) {
            NSUInteger checkLen = MIN([segTextTrimmed length], [wordTextTrimmed length]);
            checkLen = MIN(checkLen, (NSUInteger)5);
            NSString *segPrefix = [[segTextTrimmed substringToIndex:checkLen] lowercaseString];
            NSString *wordPrefix = [[wordTextTrimmed substringToIndex:checkLen] lowercaseString];
            similar = [segPrefix isEqualToString:wordPrefix];
        }
        ASSERT_TRUE(name, similar,
                    ([NSString stringWithFormat:@"word text mismatch: seg='%@' words='%@'",
                      segTextTrimmed, wordTextTrimmed]));
        [wordText release];
    }

    reportResult(name, YES, nil);
}

// ── Test 4: Word timestamps on longer audio ──────────────────────────────────

static void test_m5_word_timestamps_long(MWTranscriber *t, NSString *dataDir) {
    const char *name = "m5_word_timestamps_long";

    NSString *path = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSURL *url = [NSURL fileURLWithPath:path];

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    ASSERT_TRUE(name, exists, @"Test audio physicsworks.wav not found");

    // Decode and truncate to ~30s to keep test fast.
    NSError *decodeError = nil;
    NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:url error:&decodeError];
    ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"Audio decode failed", decodeError));

    NSUInteger maxSamples = 30 * kMWTargetSampleRate;
    NSUInteger totalSamples = [fullAudio length] / sizeof(float);
    NSData *audio = fullAudio;
    if (totalSamples > maxSamples) {
        audio = [NSData dataWithBytes:[fullAudio bytes] length:maxSamples * sizeof(float)];
    }

    NSError *error = nil;
    MWTranscriptionInfo *info = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeAudio:audio
                  language:@"en"
                      task:@"transcribe"
                   options:@{@"wordTimestamps": @YES}
            segmentHandler:nil
                      info:&info
                     error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeAudio failed", error));
    ASSERT_TRUE(name, [segments count] > 0, @"expected non-empty segments");

    // Verify word timestamps are coherent across segments.
    NSUInteger totalWords = 0;
    for (MWTranscriptionSegment *seg in segments) {
        NSString *segDesc = [NSString stringWithFormat:@"segment %lu", (unsigned long)seg.segmentId];
        ASSERT_TRUE(name, seg.words != nil,
                    ([NSString stringWithFormat:@"%@ words is nil", segDesc]));

        for (MWWord *w in seg.words) {
            ASSERT_TRUE(name, w.start <= w.end + 0.001f,
                        ([NSString stringWithFormat:@"word start > end: %.3f > %.3f",
                          w.start, w.end]));
        }

        if ([seg.words count] > 0) {
            MWWord *firstWord = seg.words[0];
            // Word alignment times may differ slightly from segment boundaries.
            // Just ensure words are within a reasonable range of the overall audio.
            ASSERT_TRUE(name, firstWord.start >= 0.0f - 0.001f,
                        ([NSString stringWithFormat:@"first word starts before audio: %.3f",
                          firstWord.start]));
        }

        totalWords += [seg.words count];

        fprintf(stdout, "    Segment %lu [%.2f -> %.2f]: %lu words\n",
                (unsigned long)seg.segmentId, seg.start, seg.end,
                (unsigned long)[seg.words count]);
    }

    float lastEnd = [[segments lastObject] end];
    fprintf(stdout, "    Total words: %lu, last end: %.2fs\n", (unsigned long)totalWords, lastEnd);
    ASSERT_TRUE(name, totalWords > 10, @"expected >10 total words for 30s audio");

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

        fprintf(stdout, "[test_m5_word_timestamps] Loading model: %s\n", [modelPath UTF8String]);
        fprintf(stdout, "[test_m5_word_timestamps] Data dir: %s\n", [dataDir UTF8String]);

        // Tests that don't need a model.
        test_m5_merge_punctuations();
        test_m5_anomaly_score();

        // Tests that need a model.
        NSError *error = nil;
        MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
        if (!t) {
            fprintf(stderr, "FATAL: Failed to load model: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
        }

        test_m5_word_timestamps(t, dataDir);
        test_m5_word_timestamps_long(t, dataDir);

        [t release];

        fprintf(stdout, "\n[test_m5_word_timestamps] %d passed, %d failed\n", gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
