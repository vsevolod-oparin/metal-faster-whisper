#import <Foundation/Foundation.h>
#import "MWTranscriber.h"
#import "MWAudioDecoder.h"
#import "MWConstants.h"
#import "MWTestCommon.h"

// ── Tests ────────────────────────────────────────────────────────────────────

/// Test 1: initWithModelPath with nonexistent path returns nil + proper error.
static void test_invalid_model_path(void) {
    const char *name = "edge_invalid_model_path";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:@"/nonexistent/path/to/model"
                                                          error:&error];
    ASSERT_TRUE(name, t == nil, @"expected nil for invalid model path");
    ASSERT_TRUE(name, error != nil, @"expected non-nil error");
    ASSERT_EQ(name, [error code], MWErrorCodeModelLoadFailed);

    reportResult(name, YES, nil);
}

/// Test 2: encodeFeatures with nFrames=0 returns nil + error.
static void test_encode_zero_frames(MWTranscriber *t) {
    const char *name = "edge_encode_zero_frames";

    NSData *mel = [NSData data];
    NSError *error = nil;
    NSData *result = [t encodeFeatures:mel nFrames:0 error:&error];

    ASSERT_TRUE(name, result == nil, @"expected nil for zero frames");
    ASSERT_TRUE(name, error != nil, @"expected non-nil error");
    ASSERT_EQ(name, [error code], MWErrorCodeEncodeFailed);

    reportResult(name, YES, nil);
}

/// Test 3: encodeFeatures with mismatched size returns nil + error.
static void test_encode_wrong_size(MWTranscriber *t) {
    const char *name = "edge_encode_wrong_size";

    // Create mel data with wrong size (just 4 bytes instead of nMels * nFrames * 4).
    float dummy = 1.0f;
    NSData *mel = [NSData dataWithBytes:&dummy length:sizeof(float)];
    NSError *error = nil;
    NSData *result = [t encodeFeatures:mel nFrames:100 error:&error];

    ASSERT_TRUE(name, result == nil, @"expected nil for wrong size");
    ASSERT_TRUE(name, error != nil, @"expected non-nil error");
    ASSERT_EQ(name, [error code], MWErrorCodeEncodeFailed);

    reportResult(name, YES, nil);
}

/// Test 4: Transcribe jfk.flac with segmentHandler that sets stop=YES on first segment.
static void test_callback_stop(MWTranscriber *t, NSString *dataDir) {
    const char *name = "edge_callback_stop";

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
              *stop = YES;
          }
                    info:nil
                   error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeURL failed", error));
    // The callback was called once and set stop=YES.
    ASSERT_EQ(name, callbackCount, 1);
    // Only 1 segment should be in the returned array (first chunk's segments before stop).
    ASSERT_TRUE(name, [segments count] >= 1, @"expected >= 1 segment");

    fprintf(stdout, "    Callback count: %lu, Segments: %lu\n",
            (unsigned long)callbackCount, (unsigned long)[segments count]);

    reportResult(name, YES, nil);
}

/// Test 5: buildSuppressedTokens with @[@(-1)] includes config.json suppress tokens.
static void test_suppress_tokens_includes_config(MWTranscriber *t) {
    const char *name = "edge_suppress_tokens_config";

    NSArray<NSNumber *> *result = [t buildSuppressedTokens:@[@(-1)]];
    ASSERT_TRUE(name, result != nil, @"expected non-nil result");

    // Config.json has ~90 suppress_ids + non_speech_tokens + 6 special tokens.
    // Should be well above 82.
    ASSERT_TRUE(name, [result count] > 82, @"expected > 82 suppressed tokens");

    // Verify sorted.
    BOOL sorted = YES;
    for (NSUInteger i = 1; i < [result count]; i++) {
        if ([result[i] integerValue] < [result[i-1] integerValue]) {
            sorted = NO;
            break;
        }
    }
    ASSERT_TRUE(name, sorted, @"suppressed tokens not sorted");

    fprintf(stdout, "    Suppressed token count: %lu\n", (unsigned long)[result count]);
    reportResult(name, YES, nil);
}

/// Test 6: transcribeAudio with empty NSData returns empty array, no crash.
static void test_empty_transcribe(MWTranscriber *t) {
    const char *name = "edge_empty_transcribe";

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
    MWTranscriptionInfo *info2 = nil;
    segments = [t transcribeAudio:nil
                         language:@"en"
                             task:@"transcribe"
                          options:nil
                   segmentHandler:nil
                             info:&info2
                            error:&error];

    ASSERT_TRUE(name, segments != nil, @"nil audio should return empty array");
    ASSERT_EQ(name, [segments count], 0);

    reportResult(name, YES, nil);
}

/// Test 7: transcribeURL with nonexistent file returns nil + proper error.
static void test_transcribe_url_not_found(MWTranscriber *t) {
    const char *name = "edge_transcribe_url_not_found";

    NSURL *url = [NSURL fileURLWithPath:@"/nonexistent/audio/file.flac"];
    NSError *error = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeURL:url
                language:@"en"
                    task:@"transcribe"
                 options:nil
          segmentHandler:nil
                    info:nil
                   error:&error];

    ASSERT_TRUE(name, segments == nil, @"expected nil for nonexistent file");
    ASSERT_TRUE(name, error != nil, @"expected non-nil error");

    fprintf(stdout, "    Error: %s\n", [[error localizedDescription] UTF8String]);
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

        fprintf(stdout, "[test_edge_cases] Model: %s\n", [modelPath UTF8String]);
        fprintf(stdout, "[test_edge_cases] Data:  %s\n", [dataDir UTF8String]);

        // Test 1: Does not need a loaded model.
        test_invalid_model_path();

        // Load model for remaining tests.
        NSError *error = nil;
        MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
        if (!t) {
            fprintf(stderr, "FATAL: Failed to load model: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
        }

        test_encode_zero_frames(t);
        test_encode_wrong_size(t);
        test_callback_stop(t, dataDir);
        test_suppress_tokens_includes_config(t);
        test_empty_transcribe(t);
        test_transcribe_url_not_found(t);

        [t release];

        fprintf(stdout, "\n[test_edge_cases] %d passed, %d failed\n", gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
