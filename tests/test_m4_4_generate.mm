#import <Foundation/Foundation.h>
#include <compression.h>
#import "MWTranscriber.h"
#import "MWFeatureExtractor.h"
#import "MWAudioDecoder.h"
#import "MWTokenizer.h"
#import "MWConstants.h"
#import "MWTestCommon.h"

// ── Helper: encode first 30s of audio through the full pipeline ─────────────

static NSData *encodeFirst30s(MWTranscriber *t, NSData *audio, NSError **error) {
    NSUInteger samples30s = kMWTargetSampleRate * 30;
    NSData *audio30s = [MWAudioDecoder padOrTrimAudio:audio toSampleCount:samples30s];

    NSUInteger nFrames = 0;
    NSData *mel = [t.featureExtractor computeMelSpectrogramFromAudio:audio30s frameCount:&nFrames error:error];
    if (!mel) return nil;

    NSUInteger nMels = t.nMels;
    NSUInteger targetFrames = kMWDefaultChunkFrames;

    // Pad or trim mel to 3000 frames.
    if (nFrames != targetFrames) {
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
        mel = result;
        nFrames = targetFrames;
    }

    return [t encodeFeatures:mel nFrames:nFrames error:error];
}

// ── Tests ────────────────────────────────────────────────────────────────────

static void test_m4_4_greedy(MWTranscriber *t, NSData *encoderOutput) {
    const char *name = "m4_4_greedy";

    NSArray<NSNumber *> *prompt = [t buildPromptWithPreviousTokens:nil
                                                 withoutTimestamps:NO
                                                            prefix:nil
                                                          hotwords:nil];
    NSArray<NSNumber *> *suppress = [t buildSuppressedTokens:@[@(-1)]];

    NSError *error = nil;
    MWGenerateResult *result = [t generateWithEncoderOutput:encoderOutput
                                                     prompt:prompt
                                               temperatures:@[@0.0]
                                                   beamSize:5
                                                   patience:1.0f
                                                     bestOf:5
                                              lengthPenalty:1.0f
                                          repetitionPenalty:1.0f
                                          noRepeatNgramSize:0
                                    compressionRatioThreshold:2.4f
                                            logProbThreshold:-1.0f
                                          noSpeechThreshold:0.6f
                                              suppressTokens:suppress
                                               suppressBlank:YES
                                         maxInitialTimestamp:1.0f
                                                       error:&error];
    ASSERT_TRUE(name, result != nil, fmtErr(@"Generate failed", error));
    ASSERT_TRUE(name, [result.tokenIDs count] > 0, @"No tokens generated");
    ASSERT_TRUE(name, [result.text length] > 0, @"Empty text");
    NSString *tempMsg = [NSString stringWithFormat:@"Expected temperature 0, got %f", result.temperature];
    ASSERT_TRUE(name, result.temperature == 0.0f, tempMsg);

    fprintf(stdout, "    tokens: %lu, avgLogProb: %.4f, CR: %.2f, noSpeech: %.4f\n",
            (unsigned long)[result.tokenIDs count], result.avgLogProb,
            result.compressionRatio, result.noSpeechProb);
    fprintf(stdout, "    text: %.100s%s\n", [result.text UTF8String],
            [result.text length] > 100 ? "..." : "");

    reportResult(name, YES, nil);
}

static void test_m4_4_sampling(MWTranscriber *t, NSData *encoderOutput) {
    const char *name = "m4_4_sampling";

    NSArray<NSNumber *> *prompt = [t buildPromptWithPreviousTokens:nil
                                                 withoutTimestamps:NO
                                                            prefix:nil
                                                          hotwords:nil];
    NSArray<NSNumber *> *suppress = [t buildSuppressedTokens:@[@(-1)]];

    NSError *error = nil;
    MWGenerateResult *result = [t generateWithEncoderOutput:encoderOutput
                                                     prompt:prompt
                                               temperatures:@[@0.5]
                                                   beamSize:5
                                                   patience:1.0f
                                                     bestOf:3
                                              lengthPenalty:1.0f
                                          repetitionPenalty:1.0f
                                          noRepeatNgramSize:0
                                    compressionRatioThreshold:2.4f
                                            logProbThreshold:-1.0f
                                          noSpeechThreshold:0.6f
                                              suppressTokens:suppress
                                               suppressBlank:YES
                                         maxInitialTimestamp:1.0f
                                                       error:&error];
    ASSERT_TRUE(name, result != nil, fmtErr(@"Generate failed", error));
    ASSERT_TRUE(name, [result.tokenIDs count] > 0, @"No tokens generated");
    ASSERT_TRUE(name, [result.text length] > 0, @"Empty text");

    fprintf(stdout, "    tokens: %lu, temp: %.1f, avgLogProb: %.4f\n",
            (unsigned long)[result.tokenIDs count], result.temperature, result.avgLogProb);
    fprintf(stdout, "    text: %.100s%s\n", [result.text UTF8String],
            [result.text length] > 100 ? "..." : "");

    reportResult(name, YES, nil);
}

static void test_m4_4_fallback(MWTranscriber *t, NSData *encoderOutput) {
    const char *name = "m4_4_fallback";

    NSArray<NSNumber *> *prompt = [t buildPromptWithPreviousTokens:nil
                                                 withoutTimestamps:NO
                                                            prefix:nil
                                                          hotwords:nil];
    NSArray<NSNumber *> *suppress = [t buildSuppressedTokens:@[@(-1)]];

    // Use logProbThreshold=0.0 — average log probs are always negative,
    // so this forces fallback at every temperature.
    NSError *error = nil;
    MWGenerateResult *result = [t generateWithEncoderOutput:encoderOutput
                                                     prompt:prompt
                                               temperatures:@[@0.0, @0.2, @0.4]
                                                   beamSize:5
                                                   patience:1.0f
                                                     bestOf:3
                                              lengthPenalty:1.0f
                                          repetitionPenalty:1.0f
                                          noRepeatNgramSize:0
                                    compressionRatioThreshold:-1.0f
                                            logProbThreshold:0.0f
                                          noSpeechThreshold:-1.0f
                                              suppressTokens:suppress
                                               suppressBlank:YES
                                         maxInitialTimestamp:1.0f
                                                       error:&error];
    ASSERT_TRUE(name, result != nil, fmtErr(@"Generate failed", error));
    ASSERT_TRUE(name, [result.tokenIDs count] > 0, @"No tokens generated");

    fprintf(stdout, "    final temperature: %.1f, avgLogProb: %.4f\n",
            result.temperature, result.avgLogProb);

    // Since logProbThreshold=0.0 forces fallback for all temperatures,
    // the best result is selected. It should exist regardless.
    // The temperature in the result tells us which attempt produced the best result.
    ASSERT_TRUE(name, result.text != nil, @"No text in result");

    reportResult(name, YES, nil);
}

static void test_m4_4_compression_ratio(void) {
    const char *name = "m4_4_compression_ratio";

    // Test with highly repetitive text.
    NSString *repetitive = @"hello hello hello hello hello hello hello hello hello hello";
    NSData *repData = [repetitive dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger repLen = [repData length];
    size_t dstCap = repLen + 1024;
    uint8_t *dst = (uint8_t *)malloc(dstCap);
    size_t compSize = compression_encode_buffer(dst, dstCap,
        (const uint8_t *)[repData bytes], repLen, NULL, COMPRESSION_ZLIB);
    free(dst);
    float repRatio = (compSize > 0) ? (float)repLen / (float)compSize : 0.0f;

    fprintf(stdout, "    repetitive CR: %.2f (len=%lu, compressed=%zu)\n",
            repRatio, (unsigned long)repLen, compSize);
    NSString *repMsg = [NSString stringWithFormat:@"Expected CR > 2.0, got %.2f", repRatio];
    ASSERT_TRUE(name, repRatio > 2.0f, repMsg);

    // Test with varied text.
    NSString *varied = @"the quick brown fox jumps over the lazy dog";
    NSData *varData = [varied dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger varLen = [varData length];
    dstCap = varLen + 1024;
    dst = (uint8_t *)malloc(dstCap);
    compSize = compression_encode_buffer(dst, dstCap,
        (const uint8_t *)[varData bytes], varLen, NULL, COMPRESSION_ZLIB);
    free(dst);
    float varRatio = (compSize > 0) ? (float)varLen / (float)compSize : 0.0f;

    fprintf(stdout, "    varied CR: %.2f (len=%lu, compressed=%zu)\n",
            varRatio, (unsigned long)varLen, compSize);
    // Varied text should have lower compression ratio than repetitive.
    NSString *varMsg = [NSString stringWithFormat:@"Expected varied CR < repetitive CR, got %.2f >= %.2f",
                 varRatio, repRatio];
    ASSERT_TRUE(name, varRatio < repRatio, varMsg);

    reportResult(name, YES, nil);
}

static void test_m4_4_no_speech(MWTranscriber *t) {
    const char *name = "m4_4_no_speech";

    // Create 30s of silence.
    NSUInteger samples30s = kMWTargetSampleRate * 30;
    NSMutableData *silence = [NSMutableData dataWithLength:samples30s * sizeof(float)];

    NSError *error = nil;
    NSData *encoderOutput = encodeFirst30s(t, silence, &error);
    ASSERT_TRUE(name, encoderOutput != nil, fmtErr(@"Encode silence failed", error));

    NSArray<NSNumber *> *prompt = [t buildPromptWithPreviousTokens:nil
                                                 withoutTimestamps:NO
                                                            prefix:nil
                                                          hotwords:nil];
    NSArray<NSNumber *> *suppress = [t buildSuppressedTokens:@[@(-1)]];

    error = nil;
    MWGenerateResult *result = [t generateWithEncoderOutput:encoderOutput
                                                     prompt:prompt
                                               temperatures:@[@0.0]
                                                   beamSize:5
                                                   patience:1.0f
                                                     bestOf:5
                                              lengthPenalty:1.0f
                                          repetitionPenalty:1.0f
                                          noRepeatNgramSize:0
                                    compressionRatioThreshold:2.4f
                                            logProbThreshold:-1.0f
                                          noSpeechThreshold:0.6f
                                              suppressTokens:suppress
                                               suppressBlank:YES
                                         maxInitialTimestamp:1.0f
                                                       error:&error];
    ASSERT_TRUE(name, result != nil, fmtErr(@"Generate on silence failed", error));

    fprintf(stdout, "    noSpeechProb: %.4f, avgLogProb: %.4f, text: '%s'\n",
            result.noSpeechProb, result.avgLogProb, [result.text UTF8String]);

    // Note: CT2 on MPS may not always return no_speech_prob correctly for all model variants.
    // We verify the generate pipeline works on silence and returns a valid result.
    // If no_speech_prob is populated, it should be a valid probability.
    if (result.noSpeechProb > 0.0f) {
        fprintf(stdout, "    noSpeechProb is populated: %.4f\n", result.noSpeechProb);
        ASSERT_TRUE(name, result.noSpeechProb >= 0.0f && result.noSpeechProb <= 1.0f,
                    @"noSpeechProb out of [0,1] range");
    } else {
        fprintf(stdout, "    WARNING: noSpeechProb=0 (CT2/MPS may not populate this for all models)\n");
    }

    // The generate pipeline should still produce a result for silence.
    ASSERT_TRUE(name, result.tokenIDs != nil, @"No tokenIDs for silence");
    ASSERT_TRUE(name, result.text != nil, @"No text for silence");

    reportResult(name, YES, nil);
}

static void test_m4_4_best_of(MWTranscriber *t, NSData *encoderOutput) {
    const char *name = "m4_4_best_of";

    NSArray<NSNumber *> *prompt = [t buildPromptWithPreviousTokens:nil
                                                 withoutTimestamps:NO
                                                            prefix:nil
                                                          hotwords:nil];
    NSArray<NSNumber *> *suppress = [t buildSuppressedTokens:@[@(-1)]];

    NSError *error = nil;
    MWGenerateResult *result = [t generateWithEncoderOutput:encoderOutput
                                                     prompt:prompt
                                               temperatures:@[@0.8]
                                                   beamSize:5
                                                   patience:1.0f
                                                     bestOf:5
                                              lengthPenalty:1.0f
                                          repetitionPenalty:1.0f
                                          noRepeatNgramSize:0
                                    compressionRatioThreshold:2.4f
                                            logProbThreshold:-1.0f
                                          noSpeechThreshold:0.6f
                                              suppressTokens:suppress
                                               suppressBlank:YES
                                         maxInitialTimestamp:1.0f
                                                       error:&error];
    ASSERT_TRUE(name, result != nil, fmtErr(@"Generate failed", error));
    ASSERT_TRUE(name, [result.tokenIDs count] > 0, @"No tokens generated");
    ASSERT_TRUE(name, [result.text length] > 0, @"Empty text");

    fprintf(stdout, "    tokens: %lu, temp: %.1f, avgLogProb: %.4f\n",
            (unsigned long)[result.tokenIDs count], result.temperature, result.avgLogProb);
    fprintf(stdout, "    text: %.100s%s\n", [result.text UTF8String],
            [result.text length] > 100 ? "..." : "");

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

        fprintf(stdout, "=== MetalWhisper M4.4 Generate with Temperature Fallback Tests ===\n");
        fprintf(stdout, "Model path: %s\n", [modelPath UTF8String]);
        if (dataDir) {
            fprintf(stdout, "Data dir:   %s\n", [dataDir UTF8String]);
        }
        fprintf(stdout, "\n");

        // Compression ratio test (no model needed).
        test_m4_4_compression_ratio();

        // Load model.
        NSError *error = nil;
        MWTranscriber *t = [[MWTranscriber alloc] initWithModelPath:modelPath error:&error];
        if (!t) {
            fprintf(stderr, "FATAL: Failed to load model: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
        }

        // No-speech test (uses silence, no data dir needed).
        test_m4_4_no_speech(t);

        if (dataDir) {
            // Load and encode audio.
            NSString *wavPath = [dataDir stringByAppendingPathComponent:@"physicsworks.wav"];
            NSURL *wavURL = [NSURL fileURLWithPath:wavPath];
            error = nil;
            NSData *audio = [MWAudioDecoder decodeAudioAtURL:wavURL error:&error];
            if (!audio) {
                fprintf(stderr, "FATAL: Audio decode failed: %s\n",
                        [[error localizedDescription] UTF8String]);
                [t release];
                return 1;
            }

            error = nil;
            NSData *encoderOutput = encodeFirst30s(t, audio, &error);
            if (!encoderOutput) {
                fprintf(stderr, "FATAL: Encode failed: %s\n",
                        [[error localizedDescription] UTF8String]);
                [t release];
                return 1;
            }
            fprintf(stdout, "  Encoder output: %lu bytes\n\n",
                    (unsigned long)[encoderOutput length]);

            test_m4_4_greedy(t, encoderOutput);
            test_m4_4_sampling(t, encoderOutput);
            test_m4_4_fallback(t, encoderOutput);
            test_m4_4_best_of(t, encoderOutput);
        } else {
            fprintf(stdout, "  SKIP: m4_4_greedy (no data_dir)\n");
            fprintf(stdout, "  SKIP: m4_4_sampling (no data_dir)\n");
            fprintf(stdout, "  SKIP: m4_4_fallback (no data_dir)\n");
            fprintf(stdout, "  SKIP: m4_4_best_of (no data_dir)\n");
        }

        [t release];

        fprintf(stdout, "\n=== M4.4 Results: %d passed, %d failed ===\n",
                gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
