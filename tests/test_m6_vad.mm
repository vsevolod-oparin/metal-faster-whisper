#import <Foundation/Foundation.h>
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

static NSDictionary *loadReference(NSString *dataDir) {
    NSString *path = [dataDir stringByAppendingPathComponent:@"reference/vad_reference.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

// ── Test 1: Load Model ──────────────────────────────────────────────────────

static void test_m6_load_model(void) {
    const char *name = "m6_load_model";

    NSError *error = nil;
    MWVoiceActivityDetector *vad = [[MWVoiceActivityDetector alloc] initWithModelPath:vadModelPath()
                                                                               error:&error];
    ASSERT_TRUE(name, vad != nil, fmtErr(@"VAD model load failed", error));

    [vad release];
    reportResult(name, YES, nil);
}

// ── Test 2: Speech Probabilities ────────────────────────────────────────────

static void test_m6_speech_probs(NSString *dataDir) {
    const char *name = "m6_speech_probs";

    NSDictionary *ref = loadReference(dataDir);
    ASSERT_TRUE(name, ref != nil, @"Failed to load reference data");

    NSDictionary *refProbs = ref[@"speech_probs_30s"];
    NSArray<NSNumber *> *refProbValues = refProbs[@"probs"];
    NSInteger expectedChunks = [refProbs[@"num_chunks"] integerValue];

    // Load audio.
    NSString *audioPath = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSURL *audioURL = [NSURL fileURLWithPath:audioPath];
    NSError *decodeError = nil;
    NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:audioURL error:&decodeError];
    ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"Audio decode failed", decodeError));

    // Truncate to 30s.
    NSUInteger maxSamples = 30 * kMWTargetSampleRate;
    NSUInteger totalSamples = [fullAudio length] / sizeof(float);
    NSData *audio = fullAudio;
    if (totalSamples > maxSamples) {
        audio = [NSData dataWithBytes:[fullAudio bytes] length:maxSamples * sizeof(float)];
    }

    // Run VAD.
    NSError *error = nil;
    MWVoiceActivityDetector *vad = [[MWVoiceActivityDetector alloc] initWithModelPath:vadModelPath()
                                                                               error:&error];
    ASSERT_TRUE(name, vad != nil, fmtErr(@"VAD load failed", error));

    NSArray<NSNumber *> *probs = [vad speechProbabilities:audio error:&error];
    ASSERT_TRUE(name, probs != nil, fmtErr(@"speechProbabilities failed", error));

    fprintf(stdout, "    Chunks: %lu (expected %ld)\n", (unsigned long)[probs count], (long)expectedChunks);
    NSString *chunkMsg = [NSString stringWithFormat:@"expected %ld chunks, got %lu",
                          (long)expectedChunks, (unsigned long)[probs count]];
    ASSERT_TRUE(name, (NSInteger)[probs count] == expectedChunks, chunkMsg);

    // Compare first 10 probabilities.
    NSUInteger compareCount = MIN((NSUInteger)10, MIN([probs count], [refProbValues count]));
    float maxDiff = 0.0f;
    for (NSUInteger i = 0; i < compareCount; i++) {
        float actual = [probs[i] floatValue];
        float expected = [refProbValues[i] floatValue];
        float diff = fabsf(actual - expected);
        if (diff > maxDiff) maxDiff = diff;
        fprintf(stdout, "    prob[%lu]: %.6f (ref: %.6f, diff: %.6f)\n",
                (unsigned long)i, actual, expected, diff);
    }
    NSString *diffMsg = [NSString stringWithFormat:@"max diff %.6f exceeds 0.01", maxDiff];
    ASSERT_TRUE(name, maxDiff < 0.01f, diffMsg);

    [vad release];
    reportResult(name, YES, nil);
}

// ── Test 3: Speech Timestamps ───────────────────────────────────────────────

static void test_m6_timestamps_speech(NSString *dataDir) {
    const char *name = "m6_timestamps_speech";

    // Load jfk.flac.
    NSString *audioPath = [dataDir stringByAppendingPathComponent:@"jfk.flac"];
    NSURL *audioURL = [NSURL fileURLWithPath:audioPath];
    NSError *decodeError = nil;
    NSData *audio = [MWAudioDecoder decodeAudioAtURL:audioURL error:&decodeError];
    ASSERT_TRUE(name, audio != nil, fmtErr(@"Audio decode failed", decodeError));

    NSUInteger totalSamples = [audio length] / sizeof(float);
    float durationS = (float)totalSamples / (float)kMWTargetSampleRate;
    fprintf(stdout, "    JFK audio: %lu samples (%.2fs)\n", (unsigned long)totalSamples, durationS);

    NSError *error = nil;
    MWVoiceActivityDetector *vad = [[MWVoiceActivityDetector alloc] initWithModelPath:vadModelPath()
                                                                               error:&error];
    ASSERT_TRUE(name, vad != nil, fmtErr(@"VAD load failed", error));

    NSArray<NSDictionary<NSString *, NSNumber *> *> *timestamps =
        [vad speechTimestamps:audio options:nil error:&error];
    ASSERT_TRUE(name, timestamps != nil, fmtErr(@"speechTimestamps failed", error));

    NSString *segMsg = [NSString stringWithFormat:@"expected at least 1 segment, got %lu",
                        (unsigned long)[timestamps count]];
    ASSERT_TRUE(name, [timestamps count] >= 1, segMsg);

    // Print segments.
    for (NSUInteger i = 0; i < [timestamps count]; i++) {
        NSDictionary *seg = timestamps[i];
        float startS = [seg[@"start"] floatValue] / (float)kMWTargetSampleRate;
        float endS = [seg[@"end"] floatValue] / (float)kMWTargetSampleRate;
        fprintf(stdout, "    Segment %lu: %.2fs - %.2fs\n", (unsigned long)i, startS, endS);
    }

    // Verify speech covers most of the audio.
    NSInteger totalSpeech = 0;
    for (NSDictionary *seg in timestamps) {
        totalSpeech += [seg[@"end"] integerValue] - [seg[@"start"] integerValue];
    }
    float speechRatio = (float)totalSpeech / (float)totalSamples;
    fprintf(stdout, "    Speech ratio: %.2f\n", speechRatio);
    NSString *ratioMsg = [NSString stringWithFormat:@"speech ratio %.2f too low", speechRatio];
    ASSERT_TRUE(name, speechRatio > 0.5f, ratioMsg);

    [vad release];
    reportResult(name, YES, nil);
}

// ── Test 4: Collect Chunks ──────────────────────────────────────────────────

static void test_m6_collect_chunks(void) {
    const char *name = "m6_collect_chunks";

    // Create mock audio: 3 seconds of data.
    NSUInteger totalSamples = 3 * kMWTargetSampleRate;  // 48000
    std::vector<float> audioVec(totalSamples, 0.1f);
    NSData *audio = [NSData dataWithBytes:audioVec.data() length:totalSamples * sizeof(float)];

    // Two speech segments.
    NSArray *chunks = @[
        @{@"start": @0, @"end": @16000},       // 0-1s
        @{@"start": @32000, @"end": @48000},    // 2-3s
    ];

    // Unlimited duration: should produce one merged chunk.
    NSArray<NSData *> *result = [MWVoiceActivityDetector collectChunks:audio
                                                               chunks:chunks
                                                          maxDuration:INFINITY];
    NSString *msg1 = [NSString stringWithFormat:@"expected 1 chunk, got %lu",
                      (unsigned long)[result count]];
    ASSERT_TRUE(name, [result count] == 1, msg1);

    NSUInteger expectedSamples = 16000 + 16000;  // both segments
    NSUInteger actualSamples = [result[0] length] / sizeof(float);
    NSString *msg2 = [NSString stringWithFormat:@"expected %lu samples, got %lu",
                      (unsigned long)expectedSamples, (unsigned long)actualSamples];
    ASSERT_TRUE(name, actualSamples == expectedSamples, msg2);

    // Limited duration: should split into two chunks.
    result = [MWVoiceActivityDetector collectChunks:audio
                                             chunks:chunks
                                        maxDuration:1.5f];
    NSString *msg3 = [NSString stringWithFormat:@"expected 2 chunks, got %lu",
                      (unsigned long)[result count]];
    ASSERT_TRUE(name, [result count] == 2, msg3);

    reportResult(name, YES, nil);
}

// ── Test 5: Timestamp Map ───────────────────────────────────────────────────

static void test_m6_timestamp_map(void) {
    const char *name = "m6_timestamp_map";

    // Speech from 1s-3s and 5s-8s (gap from 0-1s and 3s-5s is silence).
    NSArray *chunks = @[
        @{@"start": @16000, @"end": @48000},    // 1s-3s
        @{@"start": @80000, @"end": @128000},    // 5s-8s
    ];

    MWSpeechTimestampsMap *map = [[MWSpeechTimestampsMap alloc] initWithChunks:chunks
                                                                 samplingRate:kMWTargetSampleRate];

    // chunk_end_sample = [32000, 80000]
    // total_silence_before = [1.0, 3.0]
    //
    // Time 0.0 in filtered audio -> sample=0, upper_bound idx=0, silence=1.0 -> 1.0
    float t0 = [map originalTimeForTime:0.0f];
    fprintf(stdout, "    t=0.0 -> %.2f (expected 1.0)\n", t0);
    NSString *msg0 = [NSString stringWithFormat:@"t=0.0 mapped to %.2f, expected 1.0", t0];
    ASSERT_TRUE(name, fabsf(t0 - 1.0f) < 0.01f, msg0);

    // Time 1.0 in filtered -> sample=16000, upper_bound idx=0, silence=1.0 -> 2.0
    float t1 = [map originalTimeForTime:1.0f];
    fprintf(stdout, "    t=1.0 -> %.2f (expected 2.0)\n", t1);
    NSString *msg1 = [NSString stringWithFormat:@"t=1.0 mapped to %.2f, expected 2.0", t1];
    ASSERT_TRUE(name, fabsf(t1 - 2.0f) < 0.01f, msg1);

    // Time 2.0 in filtered -> sample=32000 == chunk_end[0], upper_bound idx=1, silence=3.0 -> 5.0
    float t2 = [map originalTimeForTime:2.0f];
    fprintf(stdout, "    t=2.0 -> %.2f (expected 5.0)\n", t2);
    NSString *msg2 = [NSString stringWithFormat:@"t=2.0 mapped to %.2f, expected 5.0", t2];
    ASSERT_TRUE(name, fabsf(t2 - 5.0f) < 0.01f, msg2);

    // Time 3.0 in filtered -> sample=48000, upper_bound idx=1, silence=3.0 -> 6.0
    float t3 = [map originalTimeForTime:3.0f];
    fprintf(stdout, "    t=3.0 -> %.2f (expected 6.0)\n", t3);
    NSString *msg3 = [NSString stringWithFormat:@"t=3.0 mapped to %.2f, expected 6.0", t3];
    ASSERT_TRUE(name, fabsf(t3 - 6.0f) < 0.01f, msg3);

    [map release];
    reportResult(name, YES, nil);
}

// ── Test 6: End-to-End VAD + Transcribe ─────────────────────────────────────

static void test_m6_end_to_end(MWTranscriber *t, NSString *dataDir) {
    const char *name = "m6_end_to_end";

    // Load audio.
    NSString *audioPath = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSURL *audioURL = [NSURL fileURLWithPath:audioPath];
    NSError *decodeError = nil;
    NSData *fullAudio = [MWAudioDecoder decodeAudioAtURL:audioURL error:&decodeError];
    ASSERT_TRUE(name, fullAudio != nil, fmtErr(@"Audio decode failed", decodeError));

    // Truncate to 30s.
    NSUInteger maxSamples = 30 * kMWTargetSampleRate;
    NSUInteger totalSamples = [fullAudio length] / sizeof(float);
    NSData *audio = fullAudio;
    if (totalSamples > maxSamples) {
        audio = [NSData dataWithBytes:[fullAudio bytes] length:maxSamples * sizeof(float)];
    }

    // Run VAD to get speech chunks.
    NSError *vadError = nil;
    MWVoiceActivityDetector *vad = [[MWVoiceActivityDetector alloc] initWithModelPath:vadModelPath()
                                                                               error:&vadError];
    ASSERT_TRUE(name, vad != nil, fmtErr(@"VAD load failed", vadError));

    NSArray<NSDictionary<NSString *, NSNumber *> *> *timestamps =
        [vad speechTimestamps:audio options:nil error:&vadError];
    ASSERT_TRUE(name, timestamps != nil, fmtErr(@"speechTimestamps failed", vadError));

    fprintf(stdout, "    VAD segments: %lu\n", (unsigned long)[timestamps count]);

    // Collect speech chunks.
    NSArray<NSData *> *speechChunks = [MWVoiceActivityDetector collectChunks:audio
                                                                     chunks:timestamps
                                                                maxDuration:INFINITY];
    ASSERT_TRUE(name, [speechChunks count] > 0, @"no speech chunks collected");

    // Concatenate speech audio.
    NSMutableData *speechAudio = [[NSMutableData alloc] init];
    for (NSData *chunk in speechChunks) {
        [speechAudio appendData:chunk];
    }
    fprintf(stdout, "    Speech audio: %lu samples (%.2fs)\n",
            (unsigned long)([speechAudio length] / sizeof(float)),
            (float)([speechAudio length] / sizeof(float)) / (float)kMWTargetSampleRate);

    ASSERT_TRUE(name, [speechAudio length] > 0, @"speech audio is empty");

    // Transcribe.
    MWTranscriptionInfo *info = nil;
    NSError *txError = nil;
    NSArray<MWTranscriptionSegment *> *segments =
        [t transcribeAudio:speechAudio
                  language:@"en"
                      task:@"transcribe"
                   options:nil
            segmentHandler:nil
                      info:&info
                     error:&txError];

    ASSERT_TRUE(name, segments != nil, fmtErr(@"transcribeAudio failed", txError));
    ASSERT_TRUE(name, [segments count] > 0, @"expected non-empty segments");

    NSMutableString *fullText = [[NSMutableString alloc] init];
    for (MWTranscriptionSegment *seg in segments) {
        [fullText appendString:seg.text];
    }
    fprintf(stdout, "    Text: %s\n", [fullText UTF8String]);

    NSString *lower = [fullText lowercaseString];
    BOOL hasContent = [lower length] > 10;
    ASSERT_TRUE(name, hasContent, @"transcription text too short");

    [fullText release];
    [speechAudio release];
    [vad release];
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

        fprintf(stdout, "=== M6 VAD Tests ===\n");
        fprintf(stdout, "  VAD model: %s\n", [vadModelPath() UTF8String]);
        fprintf(stdout, "  Data dir: %s\n", [dataDir UTF8String]);

        // Tests that don't need the whisper model.
        test_m6_load_model();
        test_m6_speech_probs(dataDir);
        test_m6_timestamps_speech(dataDir);
        test_m6_collect_chunks();
        test_m6_timestamp_map();

        // End-to-end test needs the whisper model.
        NSError *error = nil;
        MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
        if (!t) {
            fprintf(stderr, "Failed to load Whisper model: %s\n", [[error localizedDescription] UTF8String]);
            fprintf(stdout, "  SKIP: m6_end_to_end (model load failed)\n");
        } else {
            test_m6_end_to_end(t, dataDir);
            [t release];
        }

        fprintf(stdout, "\n=== Results: %d passed, %d failed ===\n", gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
