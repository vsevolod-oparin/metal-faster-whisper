#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import "MWVoiceActivityDetector.h"
#import "MWAudioDecoder.h"
#import "MWTranscriber.h"
#import "MWConstants.h"
#import "MWTestCommon.h"

#include <vector>
#include <cmath>

// ── Helpers ─────────────────────────────────────────────────────────────────

static NSString *gProjectDir = nil;

static NSString *vadModelPath(void) {
    return [gProjectDir stringByAppendingPathComponent:@"models/silero_vad_v6.onnx"];
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

// ── Test 1: VAD Empty Audio ─────────────────────────────────────────────────

static void test_vad_empty_audio(void) {
    const char *name = "vad_empty_audio";

    NSError *error = nil;
    MWVoiceActivityDetector *vad = [[MWVoiceActivityDetector alloc] initWithModelPath:vadModelPath()
                                                                               error:&error];
    ASSERT_TRUE(name, vad != nil, fmtErr(@"VAD load failed", error));

    NSData *emptyAudio = [NSData data];
    NSArray<NSNumber *> *probs = [vad speechProbabilities:emptyAudio error:&error];

    // Should return empty array, not nil, no crash.
    ASSERT_TRUE(name, probs != nil, @"speechProbabilities returned nil for empty audio");
    ASSERT_EQ(name, [probs count], 0);

    [vad release];
    reportResult(name, YES, nil);
}

// ── Test 2: VAD Nil Audio ───────────────────────────────────────────────────

static void test_vad_nil_audio(void) {
    const char *name = "vad_nil_audio";

    NSError *error = nil;
    MWVoiceActivityDetector *vad = [[MWVoiceActivityDetector alloc] initWithModelPath:vadModelPath()
                                                                               error:&error];
    ASSERT_TRUE(name, vad != nil, fmtErr(@"VAD load failed", error));

    // Cast through id to suppress the nonnull warning -- we're deliberately testing nil handling.
    id nilData = nil;
    NSArray<NSNumber *> *probs = [vad speechProbabilities:(NSData *)nilData error:&error];

    // Should return empty array, not crash.
    ASSERT_TRUE(name, probs != nil, @"speechProbabilities returned nil for nil audio");
    ASSERT_EQ(name, [probs count], 0);

    [vad release];
    reportResult(name, YES, nil);
}

// ── Test 3: VAD Short Audio ─────────────────────────────────────────────────

static void test_vad_short_audio(void) {
    const char *name = "vad_short_audio";

    NSError *error = nil;
    MWVoiceActivityDetector *vad = [[MWVoiceActivityDetector alloc] initWithModelPath:vadModelPath()
                                                                               error:&error];
    ASSERT_TRUE(name, vad != nil, fmtErr(@"VAD load failed", error));

    // 100 samples (less than 512 window size) -- should be padded to 512 and return 1 probability.
    std::vector<float> shortSamples(100, 0.01f);
    NSData *shortAudio = [NSData dataWithBytes:shortSamples.data()
                                        length:shortSamples.size() * sizeof(float)];

    NSArray<NSNumber *> *probs = [vad speechProbabilities:shortAudio error:&error];
    ASSERT_TRUE(name, probs != nil, fmtErr(@"speechProbabilities failed", error));
    ASSERT_EQ(name, [probs count], 1);

    float prob = [probs[0] floatValue];
    fprintf(stdout, "    Short audio (100 samples) prob: %.6f\n", prob);
    ASSERT_TRUE(name, prob >= 0.0f && prob <= 1.0f, @"prob out of [0,1] range");

    [vad release];
    reportResult(name, YES, nil);
}

// ── Test 4: VAD Timestamps Empty ────────────────────────────────────────────

static void test_vad_timestamps_empty(void) {
    const char *name = "vad_timestamps_empty";

    NSError *error = nil;
    MWVoiceActivityDetector *vad = [[MWVoiceActivityDetector alloc] initWithModelPath:vadModelPath()
                                                                               error:&error];
    ASSERT_TRUE(name, vad != nil, fmtErr(@"VAD load failed", error));

    NSData *emptyAudio = [NSData data];
    NSArray<NSDictionary<NSString *, NSNumber *> *> *timestamps =
        [vad speechTimestamps:emptyAudio options:nil error:&error];

    ASSERT_TRUE(name, timestamps != nil, @"speechTimestamps returned nil for empty audio");
    ASSERT_EQ(name, [timestamps count], 0);

    [vad release];
    reportResult(name, YES, nil);
}

// ── Test 5: VAD Max Speech Splitting ────────────────────────────────────────

static void test_vad_max_speech_splitting(NSString *dataDir) {
    const char *name = "vad_max_speech_splitting";

    // Load physicsworks.wav and take first 60s.
    NSString *audioPath = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSURL *audioURL = [NSURL fileURLWithPath:audioPath];
    NSError *decodeError = nil;
    NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:audioURL error:&decodeError];
    ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"Audio decode failed", decodeError));

    NSUInteger maxSamples = 60 * kMWTargetSampleRate;  // 960000 samples
    NSUInteger totalSamples = [fullAudio length] / sizeof(float);
    NSData *audio = fullAudio;
    if (totalSamples > maxSamples) {
        audio = [NSData dataWithBytes:[fullAudio bytes] length:maxSamples * sizeof(float)];
    }
    NSUInteger usedSamples = [audio length] / sizeof(float);
    float durationS = (float)usedSamples / (float)kMWTargetSampleRate;
    fprintf(stdout, "    Audio: %lu samples (%.2fs)\n", (unsigned long)usedSamples, durationS);

    NSError *error = nil;
    MWVoiceActivityDetector *vad = [[MWVoiceActivityDetector alloc] initWithModelPath:vadModelPath()
                                                                               error:&error];
    ASSERT_TRUE(name, vad != nil, fmtErr(@"VAD load failed", error));

    // Set maxSpeechDurationS=10.0 to force splitting of long speech segments.
    MWVADOptions *opts = [MWVADOptions defaults];
    opts.maxSpeechDurationS = 10.0f;

    NSArray<NSDictionary<NSString *, NSNumber *> *> *timestamps =
        [vad speechTimestamps:audio options:opts error:&error];
    ASSERT_TRUE(name, timestamps != nil, fmtErr(@"speechTimestamps failed", error));

    fprintf(stdout, "    Segments with maxSpeechDurationS=10: %lu\n", (unsigned long)[timestamps count]);

    // Verify all segments are within bounds and no segment exceeds ~10s + pad.
    float maxAllowedDuration = 10.0f + 2.0f;  // 10s + padding tolerance
    BOOL allInBounds = YES;
    for (NSUInteger i = 0; i < [timestamps count]; i++) {
        NSDictionary *seg = timestamps[i];
        NSInteger start = [seg[@"start"] integerValue];
        NSInteger end = [seg[@"end"] integerValue];
        float segDurS = (float)(end - start) / (float)kMWTargetSampleRate;
        fprintf(stdout, "    Segment %lu: %.2fs - %.2fs (dur: %.2fs)\n",
                (unsigned long)i,
                (float)start / (float)kMWTargetSampleRate,
                (float)end / (float)kMWTargetSampleRate,
                segDurS);
        if (segDurS > maxAllowedDuration) {
            allInBounds = NO;
            fprintf(stdout, "    WARNING: segment %lu exceeds max duration: %.2fs > %.2fs\n",
                    (unsigned long)i, segDurS, maxAllowedDuration);
        }
    }
    ASSERT_TRUE(name, allInBounds,
                @"one or more segments exceed maxSpeechDurationS + padding tolerance");

    // Also run without max speech limit for comparison.
    NSArray<NSDictionary<NSString *, NSNumber *> *> *timestampsNoMax =
        [vad speechTimestamps:audio options:nil error:&error];
    ASSERT_TRUE(name, timestampsNoMax != nil, fmtErr(@"speechTimestamps (no max) failed", error));
    fprintf(stdout, "    Segments without maxSpeechDuration: %lu\n", (unsigned long)[timestampsNoMax count]);

    // With max speech splitting, should have at least as many segments.
    ASSERT_TRUE(name, [timestamps count] >= [timestampsNoMax count],
                @"max speech splitting should produce at least as many segments");

    [vad release];
    reportResult(name, YES, nil);
}

// ── Test 6: VAD Model Invalid Path ──────────────────────────────────────────

static void test_vad_model_invalid_path(void) {
    const char *name = "vad_model_invalid_path";

    NSError *error = nil;
    MWVoiceActivityDetector *vad = [[MWVoiceActivityDetector alloc]
        initWithModelPath:@"/nonexistent/path/to/model.onnx"
                    error:&error];

    ASSERT_TRUE(name, vad == nil, @"expected nil for invalid model path");
    ASSERT_TRUE(name, error != nil, @"expected error for invalid model path");

    fprintf(stdout, "    Error: %s\n", [[error localizedDescription] UTF8String]);

    reportResult(name, YES, nil);
}

// ── Test 7: Timestamp Map Overlapping ───────────────────────────────────────

static void test_timestamp_map_overlapping(void) {
    const char *name = "timestamp_map_overlapping";

    // Overlapping segments: [0, 2000] and [1500, 4000].
    NSArray *chunks = @[
        @{@"start": @0, @"end": @(2000)},
        @{@"start": @(1500), @"end": @(4000)},
    ];

    MWSpeechTimestampsMap *map = [[MWSpeechTimestampsMap alloc] initWithChunks:chunks
                                                                 samplingRate:kMWTargetSampleRate];

    // Should not crash. Verify it returns reasonable times.
    float t0 = [map originalTimeForTime:0.0f];
    float t1 = [map originalTimeForTime:0.1f];

    fprintf(stdout, "    Overlapping chunks: t=0.0 -> %.4f, t=0.1 -> %.4f\n", t0, t1);

    // With overlapping chunks, the silence calculation uses MAX(0, start - previousEnd).
    // First chunk: start=0, end=2000, silentSamples += max(0, 0-0)=0, previousEnd=2000
    // Second chunk: start=1500, end=4000, silentSamples += max(0, 1500-2000)=0, previousEnd=4000
    // So totalSilenceBefore = [0.0, 0.0].
    // t=0.0 should map to ~0.0 (first chunk, silence=0).
    ASSERT_TRUE(name, t0 >= 0.0f, @"mapped time should be >= 0");
    ASSERT_TRUE(name, t1 > t0, @"mapped times should be monotonically increasing");

    [map release];
    reportResult(name, YES, nil);
}

// ── Test 8: Timestamp Map Empty ─────────────────────────────────────────────

static void test_timestamp_map_empty(void) {
    const char *name = "timestamp_map_empty";

    NSArray *emptyChunks = @[];
    MWSpeechTimestampsMap *map = [[MWSpeechTimestampsMap alloc] initWithChunks:emptyChunks
                                                                 samplingRate:kMWTargetSampleRate];

    // With no chunks, originalTimeForTime: should return the input time (no offset).
    float t0 = [map originalTimeForTime:0.0f];
    float t5 = [map originalTimeForTime:5.0f];

    fprintf(stdout, "    Empty map: t=0.0 -> %.4f, t=5.0 -> %.4f\n", t0, t5);

    NSString *msg0 = [NSString stringWithFormat:@"expected 0.0, got %.4f", t0];
    ASSERT_TRUE(name, fabsf(t0 - 0.0f) < 0.01f, msg0);
    NSString *msg5 = [NSString stringWithFormat:@"expected 5.0, got %.4f", t5];
    ASSERT_TRUE(name, fabsf(t5 - 5.0f) < 0.01f, msg5);

    [map release];
    reportResult(name, YES, nil);
}

// ── Test 9: Collect Chunks Out of Bounds ────────────────────────────────────

static void test_collect_chunks_oob(void) {
    const char *name = "collect_chunks_oob";

    // Create small audio: 1 second.
    NSUInteger totalSamples = kMWTargetSampleRate;  // 16000 samples
    std::vector<float> audioVec(totalSamples, 0.1f);
    NSData *audio = [NSData dataWithBytes:audioVec.data() length:totalSamples * sizeof(float)];

    // Chunks that extend beyond audio length.
    NSArray *chunks = @[
        @{@"start": @(14000), @"end": @(20000)},    // end > 16000
        @{@"start": @(50000), @"end": @(60000)},     // entirely beyond audio
    ];

    NSArray<NSData *> *result = [MWVoiceActivityDetector collectChunks:audio
                                                               chunks:chunks
                                                          maxDuration:INFINITY];

    // Should not crash. The OOB chunks are skipped by the bounds check.
    fprintf(stdout, "    OOB chunks result: %lu chunk(s)\n", (unsigned long)[result count]);

    // The implementation flushes currentAudio at the end regardless, so we get 1 chunk (possibly empty).
    // Verify no crash is the main goal.
    reportResult(name, YES, nil);
}

// ── Test 10: Collect Chunks Empty ───────────────────────────────────────────

static void test_collect_chunks_empty(void) {
    const char *name = "collect_chunks_empty";

    NSUInteger totalSamples = kMWTargetSampleRate;
    std::vector<float> audioVec(totalSamples, 0.1f);
    NSData *audio = [NSData dataWithBytes:audioVec.data() length:totalSamples * sizeof(float)];

    // Empty chunks array.
    NSArray *chunks = @[];
    NSArray<NSData *> *result = [MWVoiceActivityDetector collectChunks:audio
                                                               chunks:chunks
                                                          maxDuration:INFINITY];

    ASSERT_TRUE(name, result != nil, @"result should not be nil");
    ASSERT_EQ(name, [result count], 0);

    reportResult(name, YES, nil);
}

// ── Test 11: Memory VAD Repeated ────────────────────────────────────────────

static void test_memory_vad_repeated(NSString *dataDir) {
    const char *name = "memory_vad_repeated";

    // Load physicsworks.wav, truncate to 30s.
    NSString *audioPath = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSURL *audioURL = [NSURL fileURLWithPath:audioPath];
    NSError *decodeError = nil;
    NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:audioURL error:&decodeError];
    ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"Audio decode failed", decodeError));

    NSUInteger maxSamples = 30 * kMWTargetSampleRate;
    NSUInteger totalSamples = [fullAudio length] / sizeof(float);
    NSData *audio = fullAudio;
    if (totalSamples > maxSamples) {
        audio = [NSData dataWithBytes:[fullAudio bytes] length:maxSamples * sizeof(float)];
    }

    NSError *error = nil;
    MWVoiceActivityDetector *vad = [[MWVoiceActivityDetector alloc] initWithModelPath:vadModelPath()
                                                                               error:&error];
    ASSERT_TRUE(name, vad != nil, fmtErr(@"VAD load failed", error));

    // Warm-up run.
    @autoreleasepool {
        NSArray *warmup = [vad speechTimestamps:audio options:nil error:&error];
        (void)warmup;
    }

    size_t rssBefore = getCurrentRSS();
    fprintf(stdout, "    RSS before: %.1f MB\n", (double)rssBefore / (1024.0 * 1024.0));

    for (int i = 0; i < 10; i++) {
        @autoreleasepool {
            NSArray *timestamps = [vad speechTimestamps:audio options:nil error:&error];
            if (!timestamps) {
                NSString *msg = [NSString stringWithFormat:@"speechTimestamps failed on iteration %d", i];
                ASSERT_TRUE(name, NO, msg);
            }
        }
    }

    size_t rssAfter = getCurrentRSS();
    fprintf(stdout, "    RSS after 10 runs: %.1f MB\n", (double)rssAfter / (1024.0 * 1024.0));

    double growthMB = (double)(rssAfter > rssBefore ? rssAfter - rssBefore : 0) / (1024.0 * 1024.0);
    fprintf(stdout, "    RSS growth: %.1f MB\n", growthMB);

    NSString *growthMsg = [NSString stringWithFormat:@"RSS grew %.1f MB (> 5MB threshold)", growthMB];
    ASSERT_TRUE(name, growthMB < 5.0, growthMsg);

    [vad release];
    reportResult(name, YES, nil);
}

// ── Test 12: Memory Batched Repeated ────────────────────────────────────────

static void test_memory_batched_repeated(MWTranscriber *t, NSString *dataDir) {
    const char *name = "memory_batched_repeated";

    NSString *path = [dataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSURL *url = [NSURL fileURLWithPath:path];
    NSError *decodeError = nil;
    NSData *audio = [MWAudioDecoder decodeAudioAtURL:url error:&decodeError];
    ASSERT_TRUE(name, audio != nil, fmtErr(@"Audio decode failed", decodeError));

    NSDictionary *opts = @{@"vadModelPath": vadModelPath()};

    // Warm-up runs (GPU/MPS buffer caches grow during the first few invocations).
    for (int w = 0; w < 3; w++) {
        @autoreleasepool {
            NSError *err = nil;
            NSArray *warmup = [t transcribeBatchedAudio:audio
                                               language:@"en"
                                                   task:@"transcribe"
                                              batchSize:4
                                                options:opts
                                         segmentHandler:nil
                                                   info:nil
                                                  error:&err];
            (void)warmup;
        }
    }

    size_t rssBefore = getCurrentRSS();
    fprintf(stdout, "    RSS before: %.1f MB\n", (double)rssBefore / (1024.0 * 1024.0));

    for (int i = 0; i < 3; i++) {
        @autoreleasepool {
            NSError *err = nil;
            NSArray *segments = [t transcribeBatchedAudio:audio
                                                language:@"en"
                                                    task:@"transcribe"
                                               batchSize:4
                                                 options:opts
                                          segmentHandler:nil
                                                    info:nil
                                                   error:&err];
            if (!segments) {
                NSString *msg = [NSString stringWithFormat:@"transcribeBatchedAudio failed on iteration %d", i];
                ASSERT_TRUE(name, NO, msg);
            }
            fprintf(stdout, "    Iteration %d: %lu segments\n", i, (unsigned long)[segments count]);
        }
    }

    size_t rssAfter = getCurrentRSS();
    fprintf(stdout, "    RSS after 3 runs: %.1f MB\n", (double)rssAfter / (1024.0 * 1024.0));

    double growthMB = (double)(rssAfter > rssBefore ? rssAfter - rssBefore : 0) / (1024.0 * 1024.0);
    fprintf(stdout, "    RSS growth: %.1f MB\n", growthMB);

    // Threshold is generous because MPS/GPU buffer pools and CTranslate2 internal caches
    // cause RSS growth that is not a leak (pooled memory is reused on subsequent runs).
    // On Apple Silicon, MPS allocations show up in RSS and can grow 50-100MB as the GPU
    // runtime optimizes buffer allocations across repeated invocations.
    NSString *growthMsg = [NSString stringWithFormat:@"RSS grew %.1f MB (> 100MB threshold)", growthMB];
    ASSERT_TRUE(name, growthMB < 100.0, growthMsg);

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

        fprintf(stdout, "=== M6/M7 Edge Case Tests ===\n");
        fprintf(stdout, "  VAD model: %s\n", [vadModelPath() UTF8String]);
        fprintf(stdout, "  Data dir: %s\n", [dataDir UTF8String]);

        // Tests that don't need the whisper model.
        test_vad_empty_audio();
        test_vad_nil_audio();
        test_vad_short_audio();
        test_vad_timestamps_empty();
        test_vad_max_speech_splitting(dataDir);
        test_vad_model_invalid_path();
        test_timestamp_map_overlapping();
        test_timestamp_map_empty();
        test_collect_chunks_oob();
        test_collect_chunks_empty();
        test_memory_vad_repeated(dataDir);

        // Tests that need the whisper model.
        NSError *error = nil;
        MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
        if (!t) {
            fprintf(stderr, "Failed to load Whisper model: %s\n",
                    [[error localizedDescription] UTF8String]);
            fprintf(stdout, "  SKIP: memory_batched_repeated (model load failed)\n");
        } else {
            test_memory_batched_repeated(t, dataDir);
            [t release];
        }

        fprintf(stdout, "\n=== Results: %d passed, %d failed ===\n", gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
