// tests/test_m10_api.mm -- M10 Public API & MWTranscriptionOptions tests.
// Usage: test_m10_api <model_path> <data_dir>
// Manual retain/release (-fno-objc-arc).
//
// Deferred (requires Xcode/SPM):
//   M10.6  Swift async/await wrapper
//   M10.7  AsyncSequence for streaming segments
//   M10.8  Structured cancellation
//   M10.9  Microphone capture

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "MWTranscriber.h"
#import "MWTranscriptionOptions.h"
#import "MWAudioDecoder.h"
#import "MWTestCommon.h"

// ── Globals ─────────────────────────────────────────────────────────────────

static NSString *gModelPath = nil;
static NSString *gDataDir   = nil;

// ── Float comparison helper ─────────────────────────────────────────────────

#define ASSERT_FLOAT_EQ(name, actual, expected, eps) do { \
    float _a = (float)(actual); float _e = (float)(expected); \
    if (fabs(_a - _e) > (eps)) { \
        reportResult(name, NO, [NSString stringWithFormat:@"expected %.6f, got %.6f", _e, _a]); \
        return; \
    } \
} while (0)

// ── Test 1: MWTranscriptionOptions defaults ─────────────────────────────────

static void test_m10_options_defaults(void) {
    const char *name = "m10_options_defaults";

    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    ASSERT_TRUE(name, opts != nil, @"defaults returned nil");

    ASSERT_EQ(name, opts.beamSize, 5);
    ASSERT_EQ(name, opts.bestOf, 5);
    ASSERT_FLOAT_EQ(name, opts.patience, 1.0f, 1e-6f);
    ASSERT_FLOAT_EQ(name, opts.lengthPenalty, 1.0f, 1e-6f);
    ASSERT_FLOAT_EQ(name, opts.repetitionPenalty, 1.0f, 1e-6f);
    ASSERT_EQ(name, opts.noRepeatNgramSize, 0);

    // Temperature array.
    ASSERT_TRUE(name, opts.temperatures != nil, @"temperatures nil");
    ASSERT_EQ(name, [opts.temperatures count], 6);
    ASSERT_FLOAT_EQ(name, [opts.temperatures[0] floatValue], 0.0f, 1e-6f);
    ASSERT_FLOAT_EQ(name, [opts.temperatures[5] floatValue], 1.0f, 1e-6f);

    // Thresholds.
    ASSERT_FLOAT_EQ(name, opts.compressionRatioThreshold, 2.4f, 1e-6f);
    ASSERT_FLOAT_EQ(name, opts.logProbThreshold, -1.0f, 1e-6f);
    ASSERT_FLOAT_EQ(name, opts.noSpeechThreshold, 0.6f, 1e-6f);

    // Behavior.
    ASSERT_TRUE(name, opts.conditionOnPreviousText == YES, @"conditionOnPreviousText default");
    ASSERT_FLOAT_EQ(name, opts.promptResetOnTemperature, 0.5f, 1e-6f);
    ASSERT_TRUE(name, opts.withoutTimestamps == NO, @"withoutTimestamps default");
    ASSERT_FLOAT_EQ(name, opts.maxInitialTimestamp, 1.0f, 1e-6f);
    ASSERT_TRUE(name, opts.suppressBlank == YES, @"suppressBlank default");
    ASSERT_TRUE(name, opts.suppressTokens != nil, @"suppressTokens nil");
    ASSERT_EQ(name, [opts.suppressTokens count], 1);
    ASSERT_EQ(name, [opts.suppressTokens[0] integerValue], -1);

    // Word timestamps.
    ASSERT_TRUE(name, opts.wordTimestamps == NO, @"wordTimestamps default");
    ASSERT_TRUE(name, opts.prependPunctuations == nil, @"prependPunctuations default");
    ASSERT_TRUE(name, opts.appendPunctuations == nil, @"appendPunctuations default");
    ASSERT_FLOAT_EQ(name, opts.hallucinationSilenceThreshold, 0.0f, 1e-6f);

    // Prompting.
    ASSERT_TRUE(name, opts.initialPrompt == nil, @"initialPrompt default");
    ASSERT_TRUE(name, opts.hotwords == nil, @"hotwords default");
    ASSERT_TRUE(name, opts.prefix == nil, @"prefix default");

    // VAD.
    ASSERT_TRUE(name, opts.vadFilter == NO, @"vadFilter default");
    ASSERT_TRUE(name, opts.vadModelPath == nil, @"vadModelPath default");

    reportResult(name, YES, nil);
}

// ── Test 2: NSCopying — copy is independent ─────────────────────────────────

static void test_m10_options_copy(void) {
    const char *name = "m10_options_copy";

    MWTranscriptionOptions *original = [MWTranscriptionOptions defaults];
    original.beamSize = 3;
    original.patience = 2.0f;
    original.initialPrompt = @"Hello world";
    original.temperatures = @[@0.0, @0.5];

    MWTranscriptionOptions *copy = [[original copy] autorelease];

    // Copy should match.
    ASSERT_EQ(name, copy.beamSize, 3);
    ASSERT_FLOAT_EQ(name, copy.patience, 2.0f, 1e-6f);
    ASSERT_TRUE(name, [copy.initialPrompt isEqualToString:@"Hello world"], @"copy prompt mismatch");
    ASSERT_EQ(name, [copy.temperatures count], 2);

    // Modify copy, original should be unaffected.
    copy.beamSize = 10;
    copy.patience = 99.0f;
    copy.initialPrompt = @"Changed";
    copy.temperatures = @[@1.0];

    ASSERT_EQ(name, original.beamSize, 3);
    ASSERT_FLOAT_EQ(name, original.patience, 2.0f, 1e-6f);
    ASSERT_TRUE(name, [original.initialPrompt isEqualToString:@"Hello world"], @"original prompt changed");
    ASSERT_EQ(name, [original.temperatures count], 2);

    reportResult(name, YES, nil);
}

// ── Test 3: toDictionary produces expected keys ─────────────────────────────

static void test_m10_options_to_dict(void) {
    const char *name = "m10_options_to_dict";

    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    opts.initialPrompt = @"test prompt";
    opts.wordTimestamps = YES;

    NSDictionary *dict = [opts toDictionary];
    ASSERT_TRUE(name, dict != nil, @"toDictionary returned nil");

    // Check required keys.
    ASSERT_TRUE(name, dict[@"beamSize"] != nil, @"missing beamSize");
    ASSERT_EQ(name, [dict[@"beamSize"] unsignedIntegerValue], 5);

    ASSERT_TRUE(name, dict[@"bestOf"] != nil, @"missing bestOf");
    ASSERT_TRUE(name, dict[@"patience"] != nil, @"missing patience");
    ASSERT_TRUE(name, dict[@"temperatures"] != nil, @"missing temperatures");
    ASSERT_TRUE(name, dict[@"compressionRatioThreshold"] != nil, @"missing compressionRatioThreshold");
    ASSERT_TRUE(name, dict[@"suppressBlank"] != nil, @"missing suppressBlank");
    ASSERT_TRUE(name, dict[@"suppressTokens"] != nil, @"missing suppressTokens");
    ASSERT_TRUE(name, dict[@"wordTimestamps"] != nil, @"missing wordTimestamps");
    ASSERT_TRUE(name, [dict[@"wordTimestamps"] boolValue] == YES, @"wordTimestamps not YES");

    // Optional string key present.
    ASSERT_TRUE(name, dict[@"initialPrompt"] != nil, @"missing initialPrompt");
    ASSERT_TRUE(name, [dict[@"initialPrompt"] isEqualToString:@"test prompt"], @"initialPrompt mismatch");

    // Nil optional keys should be absent.
    MWTranscriptionOptions *plain = [MWTranscriptionOptions defaults];
    NSDictionary *plainDict = [plain toDictionary];
    ASSERT_TRUE(name, plainDict[@"initialPrompt"] == nil, @"initialPrompt should be absent");
    ASSERT_TRUE(name, plainDict[@"hotwords"] == nil, @"hotwords should be absent");
    ASSERT_TRUE(name, plainDict[@"vadModelPath"] == nil, @"vadModelPath should be absent");

    reportResult(name, YES, nil);
}

// ── Test 4: Transcribe with typed options ───────────────────────────────────

static void test_m10_transcribe_with_options(MWTranscriber *t) {
    const char *name = "m10_transcribe_with_options";

    NSString *path = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSURL *url = [NSURL fileURLWithPath:path];

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    ASSERT_TRUE(name, exists, @"jfk.flac not found");

    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    opts.beamSize = 3;
    opts.bestOf = 3;

    MWTranscriptionInfo *info = nil;
    NSError *error = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeURL:url
                language:nil
                    task:@"transcribe"
            typedOptions:opts
          segmentHandler:nil
                    info:&info
                   error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribe failed", error));
    ASSERT_TRUE(name, [segments count] > 0, @"expected non-empty segments");

    // Check we got recognizable JFK text.
    NSMutableString *fullText = [[NSMutableString alloc] init];
    for (MWTranscriptionSegment *seg in segments) {
        [fullText appendString:seg.text];
    }
    fprintf(stdout, "    Text: %s\n", [fullText UTF8String]);

    NSString *lower = [fullText lowercaseString];
    BOOL hasEnglish = ([lower rangeOfString:@"country"].location != NSNotFound ||
                       [lower rangeOfString:@"ask"].location != NSNotFound ||
                       [lower rangeOfString:@"what"].location != NSNotFound ||
                       [lower rangeOfString:@"fellow"].location != NSNotFound);
    ASSERT_TRUE(name, hasEnglish, @"text lacks recognizable English");

    ASSERT_TRUE(name, info != nil, @"info nil");
    ASSERT_TRUE(name, [info.language isEqualToString:@"en"], @"expected language 'en'");

    fprintf(stdout, "    Language: %s (%.2f), Duration: %.2fs, Segments: %lu\n",
            [info.language UTF8String], info.languageProbability,
            info.duration, (unsigned long)[segments count]);

    [fullText release];
    reportResult(name, YES, nil);
}

// ── Test 5: Async transcription ─────────────────────────────────────────────

static void test_m10_async_transcribe(MWTranscriber *t) {
    const char *name = "m10_async_transcribe";

    NSString *path = [gDataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSURL *url = [NSURL fileURLWithPath:path];

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    ASSERT_TRUE(name, exists, @"jfk.flac not found");

    __block NSArray<MWTranscriptionSegment *> *resultSegments = nil;
    __block MWTranscriptionInfo *resultInfo = nil;
    __block NSError *resultError = nil;
    __block BOOL completed = NO;

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    [t transcribeURL:url
            language:nil
                task:@"transcribe"
        typedOptions:nil
      segmentHandler:nil
   completionHandler:^(NSArray<MWTranscriptionSegment *> *segments,
                       MWTranscriptionInfo *info,
                       NSError *error) {
       resultSegments = [segments retain];
       resultInfo = [info retain];
       resultError = [error retain];
       completed = YES;
       dispatch_semaphore_signal(sema);
   }];

    // The completion handler fires on main queue, but we are on main thread.
    // Pump the main run loop while waiting.
    while (!completed) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    dispatch_release(sema);

    ASSERT_TRUE(name, resultError == nil, fmtErr(@"async transcribe failed", resultError));
    ASSERT_TRUE(name, resultSegments != nil, @"async segments nil");
    ASSERT_TRUE(name, [resultSegments count] > 0, @"async segments empty");
    ASSERT_TRUE(name, resultInfo != nil, @"async info nil");

    NSMutableString *fullText = [[NSMutableString alloc] init];
    for (MWTranscriptionSegment *seg in resultSegments) {
        [fullText appendString:seg.text];
    }
    fprintf(stdout, "    Async text: %s\n", [fullText UTF8String]);

    NSString *lower = [fullText lowercaseString];
    BOOL hasEnglish = ([lower rangeOfString:@"country"].location != NSNotFound ||
                       [lower rangeOfString:@"ask"].location != NSNotFound ||
                       [lower rangeOfString:@"what"].location != NSNotFound ||
                       [lower rangeOfString:@"fellow"].location != NSNotFound);
    ASSERT_TRUE(name, hasEnglish, @"async text lacks recognizable English");

    fprintf(stdout, "    Language: %s (%.2f), Duration: %.2fs\n",
            [resultInfo.language UTF8String], resultInfo.languageProbability,
            resultInfo.duration);

    [fullText release];
    [resultSegments release];
    [resultInfo release];
    [resultError release];
    reportResult(name, YES, nil);
}

// ── Main ────────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "Usage: test_m10_api <model_path> <data_dir>\n");
            return 1;
        }
        gModelPath = [NSString stringWithUTF8String:argv[1]];
        gDataDir   = [NSString stringWithUTF8String:argv[2]];

        fprintf(stdout, "=== M10 Public API Tests ===\n");

        // Tests 1-3: no model needed.
        test_m10_options_defaults();
        test_m10_options_copy();
        test_m10_options_to_dict();

        // Load model for tests 4-5.
        fprintf(stdout, "  Loading model from: %s\n", [gModelPath UTF8String]);
        NSError *loadError = nil;
        MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:gModelPath error:&loadError];
        if (!t) {
            fprintf(stderr, "FATAL: Model load failed: %s\n",
                    [[loadError localizedDescription] UTF8String]);
            return 1;
        }

        test_m10_transcribe_with_options(t);
        test_m10_async_transcribe(t);

        [t release];

        fprintf(stdout, "\n=== M10 Results: %d passed, %d failed ===\n", gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
