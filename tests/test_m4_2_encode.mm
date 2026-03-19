#import <Foundation/Foundation.h>
#import "MWTranscriber.h"
#import "MWFeatureExtractor.h"
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

/// Helper to format load-failure messages without comma issues in macros.
static NSString *loadFailMsg(NSError *error) {
    return [NSString stringWithFormat:@"Load failed: %@", [error localizedDescription]];
}

static NSString *fmtErr(NSString *prefix, NSError *error) {
    return [NSString stringWithFormat:@"%@: %@", prefix, [error localizedDescription]];
}

static NSString *fmtStr(NSString *prefix, NSString *value) {
    return [NSString stringWithFormat:@"%@: %@", prefix, value];
}

static NSString *fmtFloat(NSString *prefix, float value) {
    return [NSString stringWithFormat:@"%@: %f", prefix, value];
}

// ── Helper: pad or trim mel to targetFrames ─────────────────────────────────

static NSData *padOrTrimMelTest(NSData *mel, NSUInteger nMels, NSUInteger nFrames, NSUInteger targetFrames) {
    if (nFrames == targetFrames) return mel;
    NSUInteger targetBytes = nMels * targetFrames * sizeof(float);
    NSMutableData *result = [NSMutableData dataWithLength:targetBytes];
    const float *src = (const float *)[mel bytes];
    float *dst = (float *)[result mutableBytes];
    NSUInteger copyFrames = MIN(nFrames, targetFrames);
    for (NSUInteger row = 0; row < nMels; row++) {
        memcpy(dst + row * targetFrames,
               src + row * nFrames,
               copyFrames * sizeof(float));
    }
    return result;
}

// ── Tests ────────────────────────────────────────────────────────────────────

static void test_m4_2_encode_shape(NSString *modelPath) {
    const char *name = "m4_2_encode_shape";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    // Create 30s of silence (480000 samples at 16kHz).
    NSUInteger numSamples = kMWTargetSampleRate * 30;
    NSMutableData *silence = [NSMutableData dataWithLength:numSamples * sizeof(float)];

    // Compute mel spectrogram.
    error = nil;
    NSData *mel = [t.featureExtractor computeMelSpectrogramFromAudio:silence error:&error];
    NSString *melMsg = fmtErr(@"Mel computation failed", error);
    ASSERT_TRUE(name, mel != nil, melMsg);

    NSUInteger nFrames = t.featureExtractor.lastFrameCount;
    NSUInteger nMels = t.nMels;
    fprintf(stdout, "    mel: nMels=%lu, nFrames=%lu\n", (unsigned long)nMels, (unsigned long)nFrames);

    // Pad or trim to 3000 frames.
    NSUInteger targetFrames = kMWDefaultChunkFrames;
    NSData *trimmedMel = padOrTrimMelTest(mel, nMels, nFrames, targetFrames);
    nFrames = targetFrames;

    // Encode.
    error = nil;
    NSData *encoded = [t encodeFeatures:trimmedMel nFrames:nFrames error:&error];
    NSString *encMsg = fmtErr(@"Encode failed", error);
    ASSERT_TRUE(name, encoded != nil, encMsg);
    ASSERT_TRUE(name, [encoded length] > 0, @"Encoded output is empty");

    // For turbo model (d_model=1280): expected 1 * 1500 * 1280 * 4 = 7,680,000 bytes.
    NSUInteger expectedBytes = 1 * 1500 * 1280 * sizeof(float);
    fprintf(stdout, "    encoded bytes: %lu (expected %lu for d_model=1280)\n",
            (unsigned long)[encoded length], (unsigned long)expectedBytes);
    ASSERT_EQ(name, [encoded length], expectedBytes);

    [t release];
    reportResult(name, YES, nil);
}

static void test_m4_2_encode_real_audio(NSString *modelPath, NSString *dataDir) {
    const char *name = "m4_2_encode_real_audio";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    // Load physicsworks.wav.
    NSString *wavPath = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSURL *wavURL = [NSURL fileURLWithPath:wavPath];
    error = nil;
    NSData *audio = [MWAudioDecoder decodeAudioAtURL:wavURL error:&error];
    NSString *audioMsg = fmtErr(@"Audio decode failed", error);
    ASSERT_TRUE(name, audio != nil, audioMsg);

    // Take first 30s of audio.
    NSUInteger samples30s = kMWTargetSampleRate * 30;
    NSData *audio30s = [MWAudioDecoder padOrTrimAudio:audio toSampleCount:samples30s];

    // Compute mel.
    error = nil;
    NSData *mel = [t.featureExtractor computeMelSpectrogramFromAudio:audio30s error:&error];
    NSString *melMsg = fmtErr(@"Mel failed", error);
    ASSERT_TRUE(name, mel != nil, melMsg);

    NSUInteger nFrames = t.featureExtractor.lastFrameCount;
    NSUInteger nMels = t.nMels;
    NSUInteger targetFrames = kMWDefaultChunkFrames;

    // Pad/trim mel to 3000 frames.
    NSData *trimmedMel = padOrTrimMelTest(mel, nMels, nFrames, targetFrames);
    nFrames = targetFrames;

    // Encode.
    error = nil;
    NSData *encoded = [t encodeFeatures:trimmedMel nFrames:nFrames error:&error];
    NSString *encMsg = fmtErr(@"Encode failed", error);
    ASSERT_TRUE(name, encoded != nil, encMsg);

    NSUInteger expectedBytes = 1 * 1500 * 1280 * sizeof(float);
    fprintf(stdout, "    encoded bytes: %lu (expected %lu)\n",
            (unsigned long)[encoded length], (unsigned long)expectedBytes);
    ASSERT_EQ(name, [encoded length], expectedBytes);

    // Verify encoded values are not all zero (real audio should produce non-trivial output).
    const float *encData = (const float *)[encoded bytes];
    NSUInteger numElements = [encoded length] / sizeof(float);
    float maxVal = 0.0f;
    for (NSUInteger i = 0; i < numElements; i++) {
        float v = fabsf(encData[i]);
        if (v > maxVal) maxVal = v;
    }
    fprintf(stdout, "    max abs encoded value: %f\n", maxVal);
    ASSERT_TRUE(name, maxVal > 0.001f, @"Encoded output is all near-zero for real audio");

    [t release];
    reportResult(name, YES, nil);
}

static void test_m4_2_detect_english(NSString *modelPath, NSString *dataDir) {
    const char *name = "m4_2_detect_english";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    // Load physicsworks.wav (English).
    NSString *wavPath = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSURL *wavURL = [NSURL fileURLWithPath:wavPath];
    error = nil;
    NSData *audio = [MWAudioDecoder decodeAudioAtURL:wavURL error:&error];
    NSString *audioMsg = fmtErr(@"Audio decode failed", error);
    ASSERT_TRUE(name, audio != nil, audioMsg);

    NSString *detectedLang = nil;
    float prob = 0.0f;
    NSArray<NSDictionary<NSString *, NSNumber *> *> *langProbs = nil;
    error = nil;

    BOOL ok = [t detectLanguageFromAudio:audio
                                segments:1
                               threshold:0.5f
                        detectedLanguage:&detectedLang
                             probability:&prob
                        allLanguageProbs:&langProbs
                                   error:&error];

    NSString *detMsg = fmtErr(@"Detection failed", error);
    ASSERT_TRUE(name, ok, detMsg);
    ASSERT_TRUE(name, detectedLang != nil, @"detectedLanguage is nil");

    fprintf(stdout, "    detected: %s (prob=%.4f)\n", [detectedLang UTF8String], prob);

    NSString *langMsg = fmtStr(@"Expected 'en' got", detectedLang);
    ASSERT_TRUE(name, [detectedLang isEqualToString:@"en"], langMsg);
    NSString *probMsg = fmtFloat(@"Expected prob > 0.5 got", prob);
    ASSERT_TRUE(name, prob > 0.5f, probMsg);

    // Check allLanguageProbs is populated.
    ASSERT_TRUE(name, langProbs != nil, @"allLanguageProbs is nil");
    ASSERT_TRUE(name, [langProbs count] > 0, @"allLanguageProbs is empty");

    // Print top 5 languages.
    fprintf(stdout, "    top languages:\n");
    NSUInteger printCount = MIN([langProbs count], (NSUInteger)5);
    for (NSUInteger i = 0; i < printCount; i++) {
        NSDictionary<NSString *, NSNumber *> *entry = langProbs[i];
        NSString *lang = [[entry allKeys] firstObject];
        float p = [entry[lang] floatValue];
        fprintf(stdout, "      %s: %.4f\n", [lang UTF8String], p);
    }

    [t release];
    reportResult(name, YES, nil);
}

static void test_m4_2_detect_threshold(NSString *modelPath, NSString *dataDir) {
    const char *name = "m4_2_detect_threshold";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    // Load physicsworks.wav.
    NSString *wavPath = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
    NSURL *wavURL = [NSURL fileURLWithPath:wavPath];
    error = nil;
    NSData *audio = [MWAudioDecoder decodeAudioAtURL:wavURL error:&error];
    NSString *audioMsg = fmtErr(@"Audio decode failed", error);
    ASSERT_TRUE(name, audio != nil, audioMsg);

    // Test with threshold=0.0 (should return on first segment via early stop).
    NSString *lang1 = nil;
    float prob1 = 0.0f;
    error = nil;
    BOOL ok1 = [t detectLanguageFromAudio:audio
                                 segments:3
                                threshold:0.0f
                         detectedLanguage:&lang1
                              probability:&prob1
                         allLanguageProbs:nil
                                    error:&error];
    NSString *ok1Msg = fmtErr(@"Low threshold detection failed", error);
    ASSERT_TRUE(name, ok1, ok1Msg);
    ASSERT_TRUE(name, lang1 != nil, @"Low threshold: detectedLanguage is nil");
    fprintf(stdout, "    threshold=0.0: %s (prob=%.4f)\n", [lang1 UTF8String], prob1);

    // Test with threshold=1.0 (nothing exceeds 1.0, falls through to majority vote).
    NSString *lang2 = nil;
    float prob2 = 0.0f;
    error = nil;
    BOOL ok2 = [t detectLanguageFromAudio:audio
                                 segments:2
                                threshold:1.0f
                         detectedLanguage:&lang2
                              probability:&prob2
                         allLanguageProbs:nil
                                    error:&error];
    NSString *ok2Msg = fmtErr(@"High threshold detection failed", error);
    ASSERT_TRUE(name, ok2, ok2Msg);
    ASSERT_TRUE(name, lang2 != nil, @"High threshold: detectedLanguage is nil");
    fprintf(stdout, "    threshold=1.0: %s (prob=%.4f) [majority vote]\n",
            [lang2 UTF8String], prob2);

    // Both should detect English regardless of threshold.
    NSString *lang1Msg = fmtStr(@"Low threshold: expected 'en' got", lang1);
    ASSERT_TRUE(name, [lang1 isEqualToString:@"en"], lang1Msg);
    NSString *lang2Msg = fmtStr(@"High threshold: expected 'en' got", lang2);
    ASSERT_TRUE(name, [lang2 isEqualToString:@"en"], lang2Msg);

    [t release];
    reportResult(name, YES, nil);
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);

        NSString *modelPath = nil;
        NSString *dataDir = nil;

        if (argc > 2) {
            modelPath = [NSString stringWithUTF8String:argv[1]];
            dataDir = [NSString stringWithUTF8String:argv[2]];
        } else if (argc > 1) {
            modelPath = [NSString stringWithUTF8String:argv[1]];
        }

        // Fallback to env vars.
        if (!modelPath) {
            const char *envPath = getenv("MW_MODEL_PATH");
            if (envPath) modelPath = [NSString stringWithUTF8String:envPath];
        }
        if (!dataDir) {
            const char *envData = getenv("MW_DATA_DIR");
            if (envData) dataDir = [NSString stringWithUTF8String:envData];
        }

        if (!modelPath || [modelPath length] == 0) {
            fprintf(stderr,
                    "Usage: %s <model_path> [data_dir]\n"
                    "   or: MW_MODEL_PATH=/path MW_DATA_DIR=/path %s\n",
                    argv[0], argv[0]);
            return 1;
        }

        fprintf(stdout, "=== MetalWhisper M4.2 Encoding & Language Detection Tests ===\n");
        fprintf(stdout, "Model path: %s\n", [modelPath UTF8String]);
        if (dataDir) {
            fprintf(stdout, "Data dir:   %s\n", [dataDir UTF8String]);
        }
        fprintf(stdout, "\n");

        // Encode tests.
        test_m4_2_encode_shape(modelPath);

        if (dataDir) {
            test_m4_2_encode_real_audio(modelPath, dataDir);
            test_m4_2_detect_english(modelPath, dataDir);
            test_m4_2_detect_threshold(modelPath, dataDir);
        } else {
            fprintf(stdout, "  SKIP: m4_2_encode_real_audio (no data_dir)\n");
            fprintf(stdout, "  SKIP: m4_2_detect_english (no data_dir)\n");
            fprintf(stdout, "  SKIP: m4_2_detect_threshold (no data_dir)\n");
        }

        fprintf(stdout, "\n=== M4.2 Results: %d passed, %d failed ===\n",
                gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
