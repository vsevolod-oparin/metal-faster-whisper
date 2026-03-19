#import <Foundation/Foundation.h>
#import "MWTranscriber.h"
#import "MWTokenizer.h"
#import "MWConstants.h"

// -- Test infrastructure --

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

#define ASSERT_EQ(name, actual, expected) do { \
    long _a = (long)(actual); long _e = (long)(expected); \
    if (_a != _e) { \
        reportResult(name, NO, [NSString stringWithFormat:@"expected %ld, got %ld", _e, _a]); \
        return; \
    } \
} while (0)

#define ASSERT_TRUE(name, cond, msg) do { \
    if (!(cond)) { \
        reportResult((name), NO, (msg)); \
        return; \
    } \
} while (0)

static NSString *loadFailMsg(NSError *error) {
    return [NSString stringWithFormat:@"Load failed: %@", [error localizedDescription]];
}

// -- Helper: check if array contains a value --

static BOOL arrayContains(NSArray<NSNumber *> *arr, NSUInteger value) {
    for (NSNumber *n in arr) {
        if ([n unsignedIntegerValue] == value) return YES;
    }
    return NO;
}

// -- Helper: check array is sorted and deduplicated --

static BOOL isSortedAndUnique(NSArray<NSNumber *> *arr) {
    for (NSUInteger i = 1; i < [arr count]; i++) {
        if ([arr[i] integerValue] <= [arr[i - 1] integerValue]) return NO;
    }
    return YES;
}

// -- Helper: print array of token IDs --

static void printTokenArray(const char *label, NSArray<NSNumber *> *arr) {
    fprintf(stdout, "    %s [%lu]: ", label, (unsigned long)[arr count]);
    NSUInteger printCount = MIN([arr count], (NSUInteger)20);
    for (NSUInteger i = 0; i < printCount; i++) {
        fprintf(stdout, "%ld", (long)[arr[i] integerValue]);
        if (i + 1 < printCount) fprintf(stdout, ", ");
    }
    if ([arr count] > 20) fprintf(stdout, " ...");
    fprintf(stdout, "\n");
}

// -- Tests --

static void test_m4_3_basic_prompt(MWTranscriber *t) {
    const char *name = "m4_3_basic_prompt";

    NSArray<NSNumber *> *prompt = [t buildPromptWithPreviousTokens:nil
                                                 withoutTimestamps:NO
                                                            prefix:nil
                                                          hotwords:nil];
    printTokenArray("basic prompt", prompt);

    // Should be just sotSequence: [sot, lang, task]
    NSArray<NSNumber *> *sotSeq = t.tokenizer.sotSequence;
    ASSERT_EQ(name, [prompt count], [sotSeq count]);

    for (NSUInteger i = 0; i < [sotSeq count]; i++) {
        ASSERT_EQ(name, [prompt[i] unsignedIntegerValue], [sotSeq[i] unsignedIntegerValue]);
    }

    reportResult(name, YES, nil);
}

static void test_m4_3_with_previous(MWTranscriber *t) {
    const char *name = "m4_3_with_previous";

    NSArray<NSNumber *> *prev = @[@100, @200, @300, @400, @500];
    NSArray<NSNumber *> *prompt = [t buildPromptWithPreviousTokens:prev
                                                 withoutTimestamps:NO
                                                            prefix:nil
                                                          hotwords:nil];
    printTokenArray("with_previous", prompt);

    // Should start with sot_prev
    ASSERT_EQ(name, [prompt[0] unsignedIntegerValue], t.tokenizer.sotPrev);

    // Then the 5 previous tokens
    for (NSUInteger i = 0; i < 5; i++) {
        ASSERT_EQ(name, [prompt[i + 1] unsignedIntegerValue], [prev[i] unsignedIntegerValue]);
    }

    // Then sotSequence
    NSArray<NSNumber *> *sotSeq = t.tokenizer.sotSequence;
    NSUInteger sotStart = 1 + 5;
    for (NSUInteger i = 0; i < [sotSeq count]; i++) {
        ASSERT_EQ(name, [prompt[sotStart + i] unsignedIntegerValue], [sotSeq[i] unsignedIntegerValue]);
    }

    // Total length: 1 (sot_prev) + 5 (prev) + sotSeq.count
    ASSERT_EQ(name, [prompt count], 1 + 5 + [sotSeq count]);

    reportResult(name, YES, nil);
}

static void test_m4_3_with_previous_truncation(MWTranscriber *t) {
    const char *name = "m4_3_with_previous_truncation";

    // Create 300 previous tokens
    NSMutableArray<NSNumber *> *prev = [[NSMutableArray alloc] initWithCapacity:300];
    for (NSUInteger i = 0; i < 300; i++) {
        [prev addObject:@(100 + i)];
    }

    NSArray<NSNumber *> *prompt = [t buildPromptWithPreviousTokens:prev
                                                 withoutTimestamps:NO
                                                            prefix:nil
                                                          hotwords:nil];
    fprintf(stdout, "    prompt length with 300 prev tokens: %lu\n", (unsigned long)[prompt count]);

    // maxLength//2 - 1 = 223 previous tokens max
    NSUInteger maxPrev = 223;
    NSUInteger expectedLength = 1 + maxPrev + [t.tokenizer.sotSequence count];
    ASSERT_EQ(name, [prompt count], expectedLength);

    // First token is sot_prev
    ASSERT_EQ(name, [prompt[0] unsignedIntegerValue], t.tokenizer.sotPrev);

    // Previous tokens should be the LAST 223 of the 300
    // prev[77] through prev[299] -> values 177 through 399
    ASSERT_EQ(name, [prompt[1] unsignedIntegerValue], 177UL);
    ASSERT_EQ(name, [prompt[maxPrev] unsignedIntegerValue], 399UL);

    [prev release];
    reportResult(name, YES, nil);
}

static void test_m4_3_with_prefix(MWTranscriber *t) {
    const char *name = "m4_3_with_prefix";

    NSArray<NSNumber *> *prompt = [t buildPromptWithPreviousTokens:nil
                                                 withoutTimestamps:NO
                                                            prefix:@"Hello"
                                                          hotwords:nil];
    printTokenArray("with_prefix", prompt);

    // Should be: sotSequence + timestampBegin + encoded(" Hello")
    NSArray<NSNumber *> *sotSeq = t.tokenizer.sotSequence;

    // Verify sotSequence at start
    for (NSUInteger i = 0; i < [sotSeq count]; i++) {
        ASSERT_EQ(name, [prompt[i] unsignedIntegerValue], [sotSeq[i] unsignedIntegerValue]);
    }

    // Next should be timestampBegin (since withoutTimestamps=NO)
    NSUInteger tsIdx = [sotSeq count];
    ASSERT_EQ(name, [prompt[tsIdx] unsignedIntegerValue], t.tokenizer.timestampBegin);

    // After that should be the encoded prefix tokens
    ASSERT_TRUE(name, [prompt count] > tsIdx + 1, @"No prefix tokens found");

    // Verify the prefix tokens decode to something containing "Hello"
    NSArray<NSNumber *> *prefixTokens = [prompt subarrayWithRange:
        NSMakeRange(tsIdx + 1, [prompt count] - tsIdx - 1)];
    NSString *decoded = [t.tokenizer decode:prefixTokens];
    fprintf(stdout, "    decoded prefix: '%s'\n", [decoded UTF8String]);
    NSString *prefixMsg = [NSString stringWithFormat:@"Prefix decode doesn't contain 'Hello': '%@'", decoded];
    ASSERT_TRUE(name, [decoded containsString:@"Hello"], prefixMsg);

    reportResult(name, YES, nil);
}

static void test_m4_3_with_hotwords(MWTranscriber *t) {
    const char *name = "m4_3_with_hotwords";

    NSArray<NSNumber *> *prompt = [t buildPromptWithPreviousTokens:nil
                                                 withoutTimestamps:NO
                                                            prefix:nil
                                                          hotwords:@"meeting notes"];
    printTokenArray("with_hotwords", prompt);

    // Should start with sot_prev (because hotwords && !prefix)
    ASSERT_EQ(name, [prompt[0] unsignedIntegerValue], t.tokenizer.sotPrev);

    // Then encoded hotwords, then sotSequence
    NSArray<NSNumber *> *sotSeq = t.tokenizer.sotSequence;

    // Find where sotSequence starts
    NSUInteger sotStart = [prompt count] - [sotSeq count];
    for (NSUInteger i = 0; i < [sotSeq count]; i++) {
        ASSERT_EQ(name, [prompt[sotStart + i] unsignedIntegerValue], [sotSeq[i] unsignedIntegerValue]);
    }

    // Tokens between sot_prev and sotSequence are the hotwords
    NSArray<NSNumber *> *hotwordTokens = [prompt subarrayWithRange:
        NSMakeRange(1, sotStart - 1)];
    ASSERT_TRUE(name, [hotwordTokens count] > 0, @"No hotword tokens found");

    NSString *decoded = [t.tokenizer decode:hotwordTokens];
    fprintf(stdout, "    decoded hotwords: '%s'\n", [decoded UTF8String]);
    NSString *hotwordsMsg = [NSString stringWithFormat:@"Hotwords decode doesn't contain 'meeting': '%@'", decoded];
    ASSERT_TRUE(name, [decoded containsString:@"meeting"], hotwordsMsg);

    reportResult(name, YES, nil);
}

static void test_m4_3_without_timestamps(MWTranscriber *t) {
    const char *name = "m4_3_without_timestamps";

    NSArray<NSNumber *> *prompt = [t buildPromptWithPreviousTokens:nil
                                                 withoutTimestamps:YES
                                                            prefix:nil
                                                          hotwords:nil];
    printTokenArray("without_timestamps", prompt);

    // Should be: sotSequence + noTimestamps
    NSArray<NSNumber *> *sotSeq = t.tokenizer.sotSequence;
    ASSERT_EQ(name, [prompt count], [sotSeq count] + 1);

    for (NSUInteger i = 0; i < [sotSeq count]; i++) {
        ASSERT_EQ(name, [prompt[i] unsignedIntegerValue], [sotSeq[i] unsignedIntegerValue]);
    }
    ASSERT_EQ(name, [prompt[[sotSeq count]] unsignedIntegerValue], t.tokenizer.noTimestamps);

    reportResult(name, YES, nil);
}

static void test_m4_3_suppressed_tokens(MWTranscriber *t) {
    const char *name = "m4_3_suppressed_tokens";

    NSArray<NSNumber *> *suppressed = [t buildSuppressedTokens:@[@(-1)]];
    fprintf(stdout, "    suppressed token count: %lu\n", (unsigned long)[suppressed count]);

    // Must contain the 6 always-added special tokens
    ASSERT_TRUE(name, arrayContains(suppressed, t.tokenizer.transcribeToken),
                @"Missing transcribeToken");
    ASSERT_TRUE(name, arrayContains(suppressed, t.tokenizer.translateToken),
                @"Missing translateToken");
    ASSERT_TRUE(name, arrayContains(suppressed, t.tokenizer.sot),
                @"Missing sot");
    ASSERT_TRUE(name, arrayContains(suppressed, t.tokenizer.sotPrev),
                @"Missing sotPrev");
    ASSERT_TRUE(name, arrayContains(suppressed, t.tokenizer.sotLM),
                @"Missing sotLM");
    ASSERT_TRUE(name, arrayContains(suppressed, t.tokenizer.noSpeech),
                @"Missing noSpeech");

    // Must contain non-speech tokens (since -1 was in input)
    NSArray<NSNumber *> *nonSpeech = t.tokenizer.nonSpeechTokens;
    fprintf(stdout, "    nonSpeechTokens count: %lu\n", (unsigned long)[nonSpeech count]);
    ASSERT_TRUE(name, [nonSpeech count] > 0, @"nonSpeechTokens is empty");

    for (NSNumber *tok in nonSpeech) {
        NSString *nstMsg = [NSString stringWithFormat:@"Missing nonSpeech token %@", tok];
        ASSERT_TRUE(name, arrayContains(suppressed, [tok unsignedIntegerValue]), nstMsg);
    }

    // Must be sorted and unique
    ASSERT_TRUE(name, isSortedAndUnique(suppressed), @"Suppressed tokens not sorted/unique");

    // Must NOT contain -1
    ASSERT_TRUE(name, !arrayContains(suppressed, (NSUInteger)-1), @"Contains -1");

    reportResult(name, YES, nil);
}

static void test_m4_3_suppressed_tokens_empty(MWTranscriber *t) {
    const char *name = "m4_3_suppressed_tokens_empty";

    // Empty input -> only the 6 always-added tokens
    NSArray<NSNumber *> *suppressed = [t buildSuppressedTokens:@[]];
    fprintf(stdout, "    suppressed (empty input) count: %lu\n", (unsigned long)[suppressed count]);
    printTokenArray("suppressed_empty", suppressed);

    // Should contain exactly the 6 special tokens (deduplicated)
    NSMutableSet<NSNumber *> *expected = [[NSMutableSet alloc] initWithArray:@[
        @(t.tokenizer.transcribeToken),
        @(t.tokenizer.translateToken),
        @(t.tokenizer.sot),
        @(t.tokenizer.sotPrev),
        @(t.tokenizer.sotLM),
        @(t.tokenizer.noSpeech),
    ]];
    ASSERT_EQ(name, [suppressed count], [expected count]);
    ASSERT_TRUE(name, isSortedAndUnique(suppressed), @"Not sorted/unique");

    [expected release];
    reportResult(name, YES, nil);
}

static void test_m4_3_translate_task(NSString *modelPath) {
    const char *name = "m4_3_translate_task";

    NSError *error = nil;
    MWTokenizer *translateTok = [[MWTokenizer alloc] initWithModelPath:modelPath
                                                           multilingual:YES
                                                                   task:@"translate"
                                                               language:@"fr"
                                                                  error:&error];
    ASSERT_TRUE(name, translateTok != nil, loadFailMsg(error));

    NSArray<NSNumber *> *sotSeq = translateTok.sotSequence;
    printTokenArray("translate sotSequence", sotSeq);

    // sotSequence should contain the translate token (50359)
    NSString *transMsg = [NSString stringWithFormat:@"sotSequence missing translate token %lu",
                         (unsigned long)translateTok.translateToken];
    ASSERT_TRUE(name, arrayContains(sotSeq, translateTok.translateToken), transMsg);

    // Should NOT contain the transcribe token
    ASSERT_TRUE(name, !arrayContains(sotSeq, translateTok.transcribeToken),
                @"sotSequence should not contain transcribe token for translate task");

    // Should contain the French language token
    ASSERT_TRUE(name, arrayContains(sotSeq, translateTok.languageToken),
                @"sotSequence missing language token");

    fprintf(stdout, "    translate token: %lu, language token (fr): %lu\n",
            (unsigned long)translateTok.translateToken,
            (unsigned long)translateTok.languageToken);

    [translateTok release];
    reportResult(name, YES, nil);
}

// -- Main --

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);

        NSString *modelPath = nil;
        if (argc > 1) {
            modelPath = [NSString stringWithUTF8String:argv[1]];
        }
        if (!modelPath) {
            const char *envPath = getenv("MW_MODEL_PATH");
            if (envPath) modelPath = [NSString stringWithUTF8String:envPath];
        }
        if (!modelPath || [modelPath length] == 0) {
            fprintf(stderr, "Usage: %s <model_path>\n", argv[0]);
            return 1;
        }

        fprintf(stdout, "=== MetalWhisper M4.3 Prompt Construction & Task Selection Tests ===\n");
        fprintf(stdout, "Model path: %s\n", [modelPath UTF8String]);
        fprintf(stdout, "\n");

        // Load transcriber once for all prompt tests
        NSError *error = nil;
        MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
        if (!t) {
            fprintf(stderr, "FATAL: Failed to load model: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
        }

        fprintf(stdout, "  Tokenizer: sot=%lu sotPrev=%lu noTimestamps=%lu timestampBegin=%lu\n",
                (unsigned long)t.tokenizer.sot,
                (unsigned long)t.tokenizer.sotPrev,
                (unsigned long)t.tokenizer.noTimestamps,
                (unsigned long)t.tokenizer.timestampBegin);
        fprintf(stdout, "  sotSequence: ");
        for (NSNumber *n in t.tokenizer.sotSequence) {
            fprintf(stdout, "%ld ", (long)[n integerValue]);
        }
        fprintf(stdout, "\n\n");

        test_m4_3_basic_prompt(t);
        test_m4_3_with_previous(t);
        test_m4_3_with_previous_truncation(t);
        test_m4_3_with_prefix(t);
        test_m4_3_with_hotwords(t);
        test_m4_3_without_timestamps(t);
        test_m4_3_suppressed_tokens(t);
        test_m4_3_suppressed_tokens_empty(t);
        test_m4_3_translate_task(modelPath);

        [t release];

        fprintf(stdout, "\n=== M4.3 Results: %d passed, %d failed ===\n",
                gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
