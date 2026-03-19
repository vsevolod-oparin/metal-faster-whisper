#import <Foundation/Foundation.h>
#import "MWTranscriber.h"
#import "MWFeatureExtractor.h"
#import "MWTokenizer.h"

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

// ── Tests ────────────────────────────────────────────────────────────────────

static void test_m4_1_load_turbo(NSString *modelPath) {
    const char *name = "m4_1_load_turbo";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    ASSERT_TRUE(name, t.isMultilingual, @"Expected multilingual=YES");
    ASSERT_EQ(name, t.nMels, 128);
    ASSERT_EQ(name, t.numLanguages, 100);
    ASSERT_TRUE(name, t.featureExtractor != nil, @"featureExtractor is nil");
    ASSERT_EQ(name, t.featureExtractor.nMels, 128);
    ASSERT_TRUE(name, t.tokenizer != nil, @"tokenizer is nil");
    ASSERT_EQ(name, t.tokenizer.vocabSize, 51866);

    [t release];
    reportResult(name, YES, nil);
}

static void test_m4_1_properties(NSString *modelPath) {
    const char *name = "m4_1_properties";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    ASSERT_EQ(name, t.inputStride, 2);
    ASSERT_EQ(name, t.numSamplesPerToken, 320);
    ASSERT_EQ(name, t.framesPerSecond, 100);
    ASSERT_EQ(name, t.tokensPerSecond, 50);

    // Float comparison with tolerance
    float tp = t.timePrecision;
    NSString *tpMsg = [NSString stringWithFormat:@"timePrecision expected ~0.02, got %f", tp];
    ASSERT_TRUE(name, (tp > 0.019f && tp < 0.021f), tpMsg);

    ASSERT_EQ(name, t.maxLength, 448);

    [t release];
    reportResult(name, YES, nil);
}

static void test_m4_1_compute_type(NSString *modelPath) {
    const char *name = "m4_1_compute_type";

    // Load with float32
    NSError *error = nil;
    MWTranscriber *t32 = [[MWTranscriber alloc] initWithModelPath:modelPath
                                                       computeType:MWComputeTypeFloat32
                                                             error:&error];
    ASSERT_TRUE(name, t32 != nil, loadFailMsg(error));

    // Load with float16
    error = nil;
    MWTranscriber *t16 = [[MWTranscriber alloc] initWithModelPath:modelPath
                                                       computeType:MWComputeTypeFloat16
                                                             error:&error];
    ASSERT_TRUE(name, t16 != nil, loadFailMsg(error));

    // Both should have the same properties
    ASSERT_TRUE(name, t32.isMultilingual == t16.isMultilingual, @"multilingual mismatch");
    ASSERT_EQ(name, t32.nMels, t16.nMels);
    ASSERT_EQ(name, t32.numLanguages, t16.numLanguages);
    ASSERT_EQ(name, t32.inputStride, t16.inputStride);

    [t32 release];
    [t16 release];
    reportResult(name, YES, nil);
}

static void test_m4_1_suppress_tokens(NSString *modelPath) {
    const char *name = "m4_1_suppress_tokens";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    NSArray<NSNumber *> *suppress = t.suppressTokens;
    ASSERT_TRUE(name, suppress != nil, @"suppressTokens is nil");
    ASSERT_TRUE(name, [suppress count] > 0, @"suppressTokens is empty");

    NSArray<NSNumber *> *suppressBegin = t.suppressTokensAtBegin;
    ASSERT_TRUE(name, suppressBegin != nil, @"suppressTokensAtBegin is nil");
    ASSERT_TRUE(name, [suppressBegin count] > 0, @"suppressTokensAtBegin is empty");

    fprintf(stdout, "    suppressTokens count: %lu\n", (unsigned long)[suppress count]);
    fprintf(stdout, "    suppressTokensAtBegin count: %lu\n", (unsigned long)[suppressBegin count]);

    [t release];
    reportResult(name, YES, nil);
}

static void test_m4_1_supported_languages(NSString *modelPath) {
    const char *name = "m4_1_supported_languages";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    NSArray<NSString *> *langs = t.supportedLanguages;
    ASSERT_TRUE(name, langs != nil, @"supportedLanguages is nil");
    ASSERT_EQ(name, [langs count], 100);

    // Check specific languages are present
    NSSet<NSString *> *langSet = [NSSet setWithArray:langs];
    ASSERT_TRUE(name, [langSet containsObject:@"en"], @"Missing 'en'");
    ASSERT_TRUE(name, [langSet containsObject:@"zh"], @"Missing 'zh'");
    ASSERT_TRUE(name, [langSet containsObject:@"ja"], @"Missing 'ja'");
    ASSERT_TRUE(name, [langSet containsObject:@"fr"], @"Missing 'fr'");

    [t release];
    reportResult(name, YES, nil);
}

static void test_m4_1_feature_extractor_works(NSString *modelPath) {
    const char *name = "m4_1_feature_extractor_works";

    NSError *error = nil;
    MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
    ASSERT_TRUE(name, t != nil, loadFailMsg(error));

    // Create 1 second of silence (16000 float32 samples = 0.0)
    NSUInteger numSamples = 16000;
    NSMutableData *silence = [NSMutableData dataWithLength:numSamples * sizeof(float)];
    memset([silence mutableBytes], 0, numSamples * sizeof(float));

    error = nil;
    NSData *mel = [t.featureExtractor computeMelSpectrogramFromAudio:silence error:&error];
    NSString *melMsg = [NSString stringWithFormat:@"Mel computation failed: %@",
                        [error localizedDescription]];
    ASSERT_TRUE(name, mel != nil, melMsg);
    ASSERT_TRUE(name, [mel length] > 0, @"Mel output is empty");

    fprintf(stdout, "    mel output bytes: %lu\n", (unsigned long)[mel length]);
    fprintf(stdout, "    mel frames: %lu\n", (unsigned long)t.featureExtractor.lastFrameCount);

    [t release];
    reportResult(name, YES, nil);
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);

        NSString *modelPath = nil;
        if (argc > 1) {
            modelPath = [NSString stringWithUTF8String:argv[1]];
        } else {
            const char *envPath = getenv("MW_MODEL_PATH");
            if (envPath) {
                modelPath = [NSString stringWithUTF8String:envPath];
            }
        }

        if (!modelPath || [modelPath length] == 0) {
            fprintf(stderr,
                    "Usage: %s <model_path>\n"
                    "   or: MW_MODEL_PATH=/path/to/model %s\n",
                    argv[0], argv[0]);
            return 1;
        }

        fprintf(stdout, "=== MetalWhisper M4.1 Model Loading Tests ===\n");
        fprintf(stdout, "Model path: %s\n\n", [modelPath UTF8String]);

        test_m4_1_load_turbo(modelPath);
        test_m4_1_properties(modelPath);
        test_m4_1_compute_type(modelPath);
        test_m4_1_suppress_tokens(modelPath);
        test_m4_1_supported_languages(modelPath);
        test_m4_1_feature_extractor_works(modelPath);

        fprintf(stdout, "\n=== M4.1 Results: %d passed, %d failed ===\n",
                gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
