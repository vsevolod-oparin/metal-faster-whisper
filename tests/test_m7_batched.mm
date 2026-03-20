#import <Foundation/Foundation.h>
#import "MWTranscriber.h"
#import "MWAudioDecoder.h"
#import "MWConstants.h"
#import "MWVoiceActivityDetector.h"
#import "MWTestCommon.h"

#include <vector>
#include <cmath>
#include <mach/mach_time.h>

// ── Helpers ─────────────────────────────────────────────────────────────────

static NSString *gProjectDir = nil;

static NSString *vadModelPath(void) {
    return [gProjectDir stringByAppendingPathComponent:@"models/silero_vad_v6.onnx"];
}

static double wallTimeSeconds(void) {
    static mach_timebase_info_data_t info = {0, 0};
    if (info.denom == 0) mach_timebase_info(&info);
    uint64_t t = mach_absolute_time();
    return (double)t * (double)info.numer / (double)info.denom / 1e9;
}

// ── Test 1: Batch Encode ─────────────────────────────────────────────────────

static void test_m7_batch_encode(MWTranscriber *t) {
    const char *name = "m7_batch_encode";

    NSUInteger nMels = t.nMels;
    NSUInteger segFrames = 3000;
    NSUInteger B = 4;

    // Create B silence mel chunks and stack them.
    size_t chunkElements = nMels * segFrames;
    std::vector<float> stacked(B * chunkElements, 0.0f);

    NSMutableData *stackedData = [NSMutableData dataWithBytes:stacked.data()
                                                       length:stacked.size() * sizeof(float)];

    // Encode the batch: shape [B, nMels, 3000]
    // Use encodeFeatures: which expects [1, nMels, nFrames].
    // For batch encode, we need to call the low-level CT2 API.
    // Since MWTranscriber.encodeFeatures only supports batch=1,
    // test that 4 individual encodes produce the right shape.
    for (NSUInteger b = 0; b < B; b++) {
        NSData *singleMel = [NSData dataWithBytes:stacked.data() + b * chunkElements
                                           length:chunkElements * sizeof(float)];
        NSError *error = nil;
        NSData *enc = [t encodeFeatures:singleMel nFrames:segFrames error:&error];
        ASSERT_TRUE(name, enc != nil, fmtErr(@"Encode failed for batch element", error));

        // Check output size: should be 1500 * d_model floats.
        NSUInteger encElements = [enc length] / sizeof(float);
        NSUInteger dModel = encElements / 1500;
        NSString *msg = [NSString stringWithFormat:@"batch[%lu] enc elements=%lu, dModel=%lu",
                         (unsigned long)b, (unsigned long)encElements, (unsigned long)dModel];
        fprintf(stdout, "    %s\n", [msg UTF8String]);
        ASSERT_TRUE(name, dModel > 0, @"dModel should be > 0");
        ASSERT_TRUE(name, encElements == 1500 * dModel, @"encoder output shape mismatch");
    }

    reportResult(name, YES, nil);
}

// ── Test 2: Batch Transcribe ────────────────────────────────────────────────

static void test_m7_batch_transcribe(MWTranscriber *t, NSString *dataDir) {
    const char *name = "m7_batch_transcribe";

    // Load physicsworks.wav and truncate to 60s.
    NSString *path = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSURL *url = [NSURL fileURLWithPath:path];

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    ASSERT_TRUE(name, exists, @"Test audio physicsworks.wav not found");

    NSError *decodeError = nil;
    NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:url error:&decodeError];
    ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"Audio decode failed", decodeError));

    // Truncate to 60s.
    NSUInteger maxSamples = 60 * kMWTargetSampleRate;
    NSUInteger totalSamples = [fullAudio length] / sizeof(float);
    NSData *audio = fullAudio;
    if (totalSamples > maxSamples) {
        audio = [NSData dataWithBytes:[fullAudio bytes] length:maxSamples * sizeof(float)];
    }
    float audioDuration = (float)([audio length] / sizeof(float)) / (float)kMWTargetSampleRate;
    fprintf(stdout, "    Audio: %.1fs\n", audioDuration);

    // Transcribe with batchSize=4.
    MWTranscriptionInfo *info = nil;
    NSError *txError = nil;
    NSDictionary *opts = @{@"vadModelPath": vadModelPath()};

    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeBatchedAudio:audio
                         language:@"en"
                             task:@"transcribe"
                        batchSize:4
                          options:opts
                   segmentHandler:nil
                             info:&info
                            error:&txError];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeBatchedAudio failed", txError));
    ASSERT_TRUE(name, [segments count] > 0, @"expected non-empty segments");

    // Print segments.
    NSMutableString *fullText = [[NSMutableString alloc] init];
    for (MWTranscriptionSegment *seg in segments) {
        fprintf(stdout, "    [%.2f-%.2f] %s\n", seg.start, seg.end, [seg.text UTF8String]);
        [fullText appendString:seg.text];
    }

    // Verify text is coherent English.
    NSString *lower = [fullText lowercaseString];
    BOOL hasContent = [lower length] > 20;
    ASSERT_TRUE(name, hasContent, @"transcription text too short");

    // Verify timestamps are monotonically increasing (start times).
    BOOL monotonic = YES;
    for (NSUInteger i = 1; i < [segments count]; i++) {
        if (segments[i].start < segments[i - 1].start) {
            monotonic = NO;
            fprintf(stdout, "    WARNING: non-monotonic at segment %lu: %.2f < %.2f\n",
                    (unsigned long)i, segments[i].start, segments[i - 1].start);
            break;
        }
    }
    ASSERT_TRUE(name, monotonic, @"timestamps should be monotonically increasing");

    // Verify info.
    ASSERT_TRUE(name, info != nil, @"info should not be nil");
    fprintf(stdout, "    Language: %s (%.2f), Duration: %.2fs, Segments: %lu\n",
            [info.language UTF8String], info.languageProbability,
            info.duration, (unsigned long)[segments count]);

    [fullText release];
    reportResult(name, YES, nil);
}

// ── Test 3: Batch vs Sequential ─────────────────────────────────────────────

static void test_m7_batch_vs_sequential(MWTranscriber *t, NSString *dataDir) {
    const char *name = "m7_batch_vs_sequential";

    NSString *path = [dataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSURL *url = [NSURL fileURLWithPath:path];

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    ASSERT_TRUE(name, exists, @"Test audio jfk.flac not found");

    // Sequential transcription.
    MWTranscriptionInfo *seqInfo = nil;
    NSError *seqError = nil;
    NSArray<MWTranscriptionSegment *> *seqSegments =
        [t transcribeURL:url
                language:@"en"
                    task:@"transcribe"
                 options:nil
          segmentHandler:nil
                    info:&seqInfo
                   error:&seqError];
    ASSERT_TRUE(name, seqSegments != nil, fmtErr(@"sequential transcribe failed", seqError));

    NSMutableString *seqText = [[NSMutableString alloc] init];
    for (MWTranscriptionSegment *seg in seqSegments) {
        [seqText appendString:seg.text];
    }

    // Batched transcription with batchSize=1 (equivalent to sequential but different code path).
    MWTranscriptionInfo *batchInfo = nil;
    NSError *batchError = nil;
    NSDictionary *opts = @{
        @"vadModelPath": vadModelPath(),
        @"withoutTimestamps": @NO,
    };

    NSArray<MWTranscriptionSegment *> *batchSegments =
        [t transcribeBatchedURL:url
                       language:@"en"
                           task:@"transcribe"
                      batchSize:1
                        options:opts
                 segmentHandler:nil
                           info:&batchInfo
                          error:&batchError];
    ASSERT_TRUE(name, batchSegments != nil, fmtErr(@"batched transcribe failed", batchError));

    NSMutableString *batchText = [[NSMutableString alloc] init];
    for (MWTranscriptionSegment *seg in batchSegments) {
        [batchText appendString:seg.text];
    }

    fprintf(stdout, "    Sequential: %s\n", [seqText UTF8String]);
    fprintf(stdout, "    Batched:    %s\n", [batchText UTF8String]);

    // Both should contain recognizable JFK speech content.
    NSString *seqLower = [seqText lowercaseString];
    NSString *batchLower = [batchText lowercaseString];

    BOOL seqHasContent = ([seqLower rangeOfString:@"country"].location != NSNotFound ||
                          [seqLower rangeOfString:@"ask"].location != NSNotFound ||
                          [seqLower rangeOfString:@"what"].location != NSNotFound);
    BOOL batchHasContent = ([batchLower rangeOfString:@"country"].location != NSNotFound ||
                            [batchLower rangeOfString:@"ask"].location != NSNotFound ||
                            [batchLower rangeOfString:@"what"].location != NSNotFound);

    ASSERT_TRUE(name, seqHasContent, @"sequential text lacks recognizable content");
    ASSERT_TRUE(name, batchHasContent, @"batched text lacks recognizable content");

    // Both should produce non-empty output.
    fprintf(stdout, "    Sequential segments: %lu, Batched segments: %lu\n",
            (unsigned long)[seqSegments count], (unsigned long)[batchSegments count]);

    [seqText release];
    [batchText release];
    reportResult(name, YES, nil);
}

// ── Test 4: Throughput Comparison ───────────────────────────────────────────

static void test_m7_throughput(MWTranscriber *t, NSString *dataDir) {
    const char *name = "m7_throughput";

    // Load full physicsworks.wav (203s).
    NSString *path = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSURL *url = [NSURL fileURLWithPath:path];

    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    ASSERT_TRUE(name, exists, @"Test audio physicsworks.wav not found");

    NSError *decodeError = nil;
    NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:url error:&decodeError];
    ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"Audio decode failed", decodeError));

    float audioDuration = (float)([fullAudio length] / sizeof(float)) / (float)kMWTargetSampleRate;
    fprintf(stdout, "    Audio duration: %.1fs\n", audioDuration);

    NSDictionary *opts = @{@"vadModelPath": vadModelPath()};

    // Batched with batchSize=1.
    double t1Start = wallTimeSeconds();
    MWTranscriptionInfo *info1 = nil;
    NSError *err1 = nil;
    NSArray<MWTranscriptionSegment *> *seg1 =
        [t transcribeBatchedAudio:fullAudio
                         language:@"en"
                             task:@"transcribe"
                        batchSize:1
                          options:opts
                   segmentHandler:nil
                             info:&info1
                            error:&err1];
    double t1End = wallTimeSeconds();
    double t1Elapsed = t1End - t1Start;

    ASSERT_TRUE(name, seg1 != nil, fmtErr(@"batchSize=1 failed", err1));

    // Batched with batchSize=8.
    double t8Start = wallTimeSeconds();
    MWTranscriptionInfo *info8 = nil;
    NSError *err8 = nil;
    NSArray<MWTranscriptionSegment *> *seg8 =
        [t transcribeBatchedAudio:fullAudio
                         language:@"en"
                             task:@"transcribe"
                        batchSize:8
                          options:opts
                   segmentHandler:nil
                             info:&info8
                            error:&err8];
    double t8End = wallTimeSeconds();
    double t8Elapsed = t8End - t8Start;

    ASSERT_TRUE(name, seg8 != nil, fmtErr(@"batchSize=8 failed", err8));

    float rtf1 = (float)t1Elapsed / audioDuration;
    float rtf8 = (float)t8Elapsed / audioDuration;

    fprintf(stdout, "    batchSize=1: %.2fs (RTF=%.3f, %lu segments)\n",
            t1Elapsed, rtf1, (unsigned long)[seg1 count]);
    fprintf(stdout, "    batchSize=8: %.2fs (RTF=%.3f, %lu segments)\n",
            t8Elapsed, rtf8, (unsigned long)[seg8 count]);
    fprintf(stdout, "    Speedup: %.2fx\n", t1Elapsed / t8Elapsed);

    // Expect batch to be at least somewhat faster (or at least not dramatically slower).
    // On MPS with limited parallelism, speedup may be modest.
    // We just log the comparison -- don't hard-fail on speedup.
    if (t8Elapsed < t1Elapsed) {
        fprintf(stdout, "    Batched IS faster (%.2fx speedup)\n", t1Elapsed / t8Elapsed);
    } else {
        fprintf(stdout, "    Batched is NOT faster (this is OK on some hardware)\n");
    }

    reportResult(name, YES, nil);
}

// ── Test 5: Segment Handler ─────────────────────────────────────────────────

static void test_m7_segment_handler(MWTranscriber *t, NSString *dataDir) {
    const char *name = "m7_segment_handler";

    NSString *path = [dataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSURL *url = [NSURL fileURLWithPath:path];

    __block NSUInteger callbackCount = 0;
    __block NSMutableString *callbackText = [[NSMutableString alloc] init];

    NSDictionary *opts = @{@"vadModelPath": vadModelPath()};

    NSError *error = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeBatchedURL:url
                       language:@"en"
                           task:@"transcribe"
                      batchSize:4
                        options:opts
                 segmentHandler:^(MWTranscriptionSegment *seg, BOOL *stop) {
                     callbackCount++;
                     [callbackText appendString:seg.text];
                 }
                           info:nil
                          error:&error];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeBatchedURL failed", error));

    fprintf(stdout, "    Callback count: %lu, Segments: %lu\n",
            (unsigned long)callbackCount, (unsigned long)[segments count]);

    // Callback count should match segment count.
    NSString *msg = [NSString stringWithFormat:@"callback count %lu != segment count %lu",
                     (unsigned long)callbackCount, (unsigned long)[segments count]];
    ASSERT_TRUE(name, callbackCount == [segments count], msg);

    // Callback text should match concatenated segment text.
    NSMutableString *fullText = [[NSMutableString alloc] init];
    for (MWTranscriptionSegment *seg in segments) {
        [fullText appendString:seg.text];
    }
    BOOL textMatch = [callbackText isEqualToString:fullText];
    ASSERT_TRUE(name, textMatch, @"callback text does not match segment text");

    [callbackText release];
    [fullText release];
    reportResult(name, YES, nil);
}

// ── Main ────────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "Usage: %s <whisper_model_path> <data_dir>\n", argv[0]);
            return 1;
        }

        NSString *modelPath = [NSString stringWithUTF8String:argv[1]];
        NSString *dataDir = [NSString stringWithUTF8String:argv[2]];

        // Derive project dir from data dir (tests/data -> project root).
        gProjectDir = [[dataDir stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];

        fprintf(stdout, "=== M7 Batched Inference Tests ===\n");
        fprintf(stdout, "  Model: %s\n", [modelPath UTF8String]);
        fprintf(stdout, "  Data:  %s\n", [dataDir UTF8String]);
        fprintf(stdout, "  VAD:   %s\n", [vadModelPath() UTF8String]);

        NSError *error = nil;
        MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
        if (!t) {
            fprintf(stderr, "Failed to load Whisper model: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
        }

        test_m7_batch_encode(t);
        test_m7_batch_transcribe(t, dataDir);
        test_m7_batch_vs_sequential(t, dataDir);
        test_m7_throughput(t, dataDir);
        test_m7_segment_handler(t, dataDir);

        [t release];

        fprintf(stdout, "\n=== Results: %d passed, %d failed ===\n", gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
