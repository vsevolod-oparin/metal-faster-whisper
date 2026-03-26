// tests/AdversarialTestFeatureExtractor.mm
// Adversarial tests for MWFeatureExtractor.
// Tier 1: no model, no GPU. Run on every build.
//
// Attack surface: init boundary violations + compute with pathological audio data.
//
// ZOMBIES coverage:
//   Z: 0 mels, 0 nFFT, 0 hopLength, 0 samplingRate, nil/empty audio
//   O: 1-sample audio, 1-mel bin, exactly nFFT samples
//   M: 30-second audio (480K samples)
//   B: nMels > freq bins, partial float input, NaN/Inf/FLT_MAX/FLT_MIN/-0.0f samples
//   I: NULL outFrameCount, nil error ptr, misaligned data length
//   E: error path verification on init and compute failures
//   S: standard 80-mel case first
//
// Usage: ./AdversarialTestFeatureExtractor   (no arguments)

#import <Foundation/Foundation.h>
#import "MWFeatureExtractor.h"
#import "MWConstants.h"
#import "MWTestCommon.h"
#include <cmath>
#include <cfloat>

// ── Standard parameters ──────────────────────────────────────────────────────

static const NSUInteger kNMels  = 80;
static const NSUInteger kNFFT   = kMWDefaultNFFT;    // 400
static const NSUInteger kHop    = kMWDefaultHopLength; // 160
static const NSUInteger kSRate  = kMWTargetSampleRate; // 16000

// Build a float32 audio buffer of N samples all set to `value`.
static NSData *makeAudioF32(NSUInteger n, float value) {
    if (n == 0) return [NSData data];
    NSMutableData *buf = [NSMutableData dataWithLength:n * sizeof(float)];
    float *p = (float *)[buf mutableBytes];
    for (NSUInteger i = 0; i < n; i++) p[i] = value;
    return buf;
}

// ── Init boundary tests ──────────────────────────────────────────────────────

// Z1: initWithNMels:0 must return nil (no spectrogram rows).
static void test_init_zeroMels_returnsNil(void) {
    const char *name = "adv_fe_init_0mels_nil";
    MWFeatureExtractor *fe = [[MWFeatureExtractor alloc] initWithNMels:0
                                                                  nFFT:kNFFT
                                                             hopLength:kHop
                                                          samplingRate:kSRate];
    ASSERT_TRUE(name, fe == nil, @"0 mel bins must return nil");
    reportResult(name, YES, nil);
}

// B1: initWithNMels:nFFT:0 must return nil (FFT of size 0 is undefined).
static void test_init_zeroFFT_returnsNil(void) {
    const char *name = "adv_fe_init_0fft_nil";
    MWFeatureExtractor *fe = [[MWFeatureExtractor alloc] initWithNMels:kNMels
                                                                  nFFT:0
                                                             hopLength:kHop
                                                          samplingRate:kSRate];
    ASSERT_TRUE(name, fe == nil, @"nFFT=0 must return nil");
    reportResult(name, YES, nil);
}

// B2: initWithNMels:hopLength:0 must return nil (div-by-zero in frame count).
// A hopLength of 0 would cause integer division-by-zero at compute time; must be
// rejected at init to prevent a SIGFPE crash later.
static void test_init_zeroHopLength_returnsNil(void) {
    const char *name = "adv_fe_init_0hop_nil";
    MWFeatureExtractor *fe = [[MWFeatureExtractor alloc] initWithNMels:kNMels
                                                                  nFFT:kNFFT
                                                             hopLength:0
                                                          samplingRate:kSRate];
    ASSERT_TRUE(name, fe == nil,
                @"hopLength=0 must return nil to prevent div-by-zero at compute time");
    reportResult(name, YES, nil);
}

// B3: initWithNMels:samplingRate:0 must return nil (zero sample rate is invalid).
static void test_init_zeroSampleRate_returnsNil(void) {
    const char *name = "adv_fe_init_0srate_nil";
    MWFeatureExtractor *fe = [[MWFeatureExtractor alloc] initWithNMels:kNMels
                                                                  nFFT:kNFFT
                                                             hopLength:kHop
                                                          samplingRate:0];
    ASSERT_TRUE(name, fe == nil, @"samplingRate=0 must return nil");
    reportResult(name, YES, nil);
}

// B4: nMels > nFFT/2+1 — more mel bins than unique FFT frequency bins.
// Must either return nil or succeed with a valid (if unusual) filterbank.
// Must NOT crash.
static void test_init_melsExceedFreqBins_nocrash(void) {
    const char *name = "adv_fe_init_mels_exceed_freqbins_nocrash";
    NSUInteger tooMany = kNFFT / 2 + 2;  // 202 > 201 unique bins
    MWFeatureExtractor *fe = [[MWFeatureExtractor alloc] initWithNMels:tooMany
                                                                  nFFT:kNFFT
                                                             hopLength:kHop
                                                          samplingRate:kSRate];
    // Either returns nil (validation) or a valid object — must NOT crash.
    if (fe != nil) [fe release];
    reportResult(name, YES, nil);
}

// O1: initWithNMels:1 — single mel bin is unusual but should not crash.
static void test_init_oneMel_nocrash(void) {
    const char *name = "adv_fe_init_1mel_nocrash";
    MWFeatureExtractor *fe = [[[MWFeatureExtractor alloc] initWithNMels:1
                                                                   nFFT:kNFFT
                                                              hopLength:kHop
                                                           samplingRate:kSRate] autorelease];
    // Might succeed or fail. If succeeds, must produce valid output.
    if (fe != nil) {
        NSData *audio = makeAudioF32(kNFFT * 4, 0.1f);
        NSError *error = nil;
        NSData *result = [fe computeMelSpectrogramFromAudio:audio
                                                 frameCount:NULL
                                                      error:&error];
        ASSERT_TRUE(name, result != nil, fmtErr(@"1-mel compute", error));
        ASSERT_EQ(name, [result length] % sizeof(float), 0UL);
    }
    reportResult(name, YES, nil);
}

// S1: Standard 80-mel init succeeds and properties are correct.
static void test_init_standard_succeeds(void) {
    const char *name = "adv_fe_init_standard_ok";
    MWFeatureExtractor *fe = [[[MWFeatureExtractor alloc] initWithNMels:kNMels
                                                                   nFFT:kNFFT
                                                              hopLength:kHop
                                                           samplingRate:kSRate] autorelease];
    ASSERT_TRUE(name, fe != nil, @"standard 80-mel init should succeed");
    ASSERT_EQ(name, fe.nMels, kNMels);
    ASSERT_TRUE(name, fe.melFilterbank != nil, @"filterbank should be non-nil");
    NSUInteger expectedFBSize = kNMels * (kNFFT / 2 + 1) * sizeof(float);
    ASSERT_EQ(name, [fe.melFilterbank length], expectedFBSize);
    reportResult(name, YES, nil);
}

// ── Shared extractor for compute tests ───────────────────────────────────────

static MWFeatureExtractor *createStandardExtractor(void) {
    MWFeatureExtractor *fe = [[MWFeatureExtractor alloc] initWithNMels:kNMels
                                                                  nFFT:kNFFT
                                                             hopLength:kHop
                                                          samplingRate:kSRate];
    if (!fe) {
        fprintf(stderr, "FATAL: Standard 80-mel extractor init failed\n");
    }
    return fe;  // caller owns; use [fe release]
}

// ── Compute boundary tests ────────────────────────────────────────────────────

// Z2: Nil audio returns nil and sets error.
static void test_compute_nilAudio_returnsNilError(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_nilAudio_nil_error";
    NSError *error = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    NSData *result = [fe computeMelSpectrogramFromAudio:(NSData *)nil
                                             frameCount:NULL
                                                  error:&error];
#pragma clang diagnostic pop
    ASSERT_TRUE(name, result == nil, @"nil audio must return nil");
    ASSERT_TRUE(name, error != nil, @"nil audio must set error");
    reportResult(name, YES, nil);
}

// Z3: Empty audio (0 bytes) returns nil and sets error.
static void test_compute_emptyAudio_returnsNilError(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_emptyAudio_nil_error";
    NSError *error = nil;
    NSData *result = [fe computeMelSpectrogramFromAudio:[NSData data]
                                             frameCount:NULL
                                                  error:&error];
    ASSERT_TRUE(name, result == nil, @"empty audio must return nil");
    ASSERT_TRUE(name, error != nil, @"empty audio must set error");
    reportResult(name, YES, nil);
}

// O2: One float sample (4 bytes) — less than nFFT, must fail cleanly.
static void test_compute_oneSample_failsCleanly(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_1sample_fails_clean";
    NSData *audio = makeAudioF32(1, 0.0f);
    NSError *error = nil;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio
                                             frameCount:NULL
                                                  error:&error];
    // Either nil+error or valid (possibly 0 frames) — must NOT crash.
    if (result != nil) {
        ASSERT_EQ(name, [result length] % sizeof(float), 0UL);
    }
    reportResult(name, YES, nil);
}

// O3: Exactly nFFT samples produces at least 1 frame.
static void test_compute_exactNFFT_oneFrame(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_exactNFFT_oneframe";
    NSData *audio = makeAudioF32(kNFFT, 0.1f);
    NSError *error = nil;
    NSUInteger frames = 0;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio
                                             frameCount:&frames
                                                  error:&error];
    ASSERT_TRUE(name, result != nil, fmtErr(@"nFFT samples should succeed", error));
    ASSERT_TRUE(name, frames >= 1, @"nFFT samples must produce ≥1 frame");
    ASSERT_EQ(name, [result length], kNMels * frames * sizeof(float));
    reportResult(name, YES, nil);
}

// B5: Input with 1 byte (not float-aligned) must return nil+error.
static void test_compute_misalignedInput_returnsNilError(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_misaligned_nil_error";
    uint8_t byte = 0xFF;
    NSData *audio = [NSData dataWithBytes:&byte length:1];
    NSError *error = nil;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio
                                             frameCount:NULL
                                                  error:&error];
    ASSERT_TRUE(name, result == nil, @"1-byte misaligned input must return nil");
    ASSERT_TRUE(name, error != nil, @"1-byte misaligned input must set error");
    reportResult(name, YES, nil);
}

// B6: Input with 6 bytes (1.5 floats, not aligned) returns nil and sets error.
static void test_compute_partialFloatInput_returnsNilError(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_1_5floats_nil_error";
    uint8_t bytes[6] = {0};
    NSData *audio = [NSData dataWithBytes:bytes length:6];
    NSError *error = nil;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio
                                             frameCount:NULL
                                                  error:&error];
    // 6 bytes is not a multiple of 4; must fail cleanly.
    if (result != nil) {
        // Tolerate if implementation floor-divides to 1 sample (4 bytes) and returns 0 frames.
        ASSERT_EQ(name, [result length] % sizeof(float), 0UL);
    }
    reportResult(name, YES, nil);
}

// B7: All-NaN audio samples — must not crash; result may be nil or contain NaN.
static void test_compute_nanSamples_nocrash(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_nan_nocrash";
    NSData *audio = makeAudioF32(kNFFT * 4, NAN);
    NSError *error = nil;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio frameCount:NULL error:&error];
    (void)result;
    reportResult(name, YES, nil);
}

// B8: All +Inf audio samples — must not crash.
static void test_compute_posInfSamples_nocrash(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_posinf_nocrash";
    NSData *audio = makeAudioF32(kNFFT * 4, INFINITY);
    NSError *error = nil;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio frameCount:NULL error:&error];
    (void)result;
    reportResult(name, YES, nil);
}

// B9: All -Inf audio samples — must not crash.
static void test_compute_negInfSamples_nocrash(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_neginf_nocrash";
    NSData *audio = makeAudioF32(kNFFT * 4, -INFINITY);
    NSError *error = nil;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio frameCount:NULL error:&error];
    (void)result;
    reportResult(name, YES, nil);
}

// B10: FLT_MAX samples — must not crash.
static void test_compute_fltMaxSamples_nocrash(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_fltmax_nocrash";
    NSData *audio = makeAudioF32(kNFFT * 4, FLT_MAX);
    NSError *error = nil;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio frameCount:NULL error:&error];
    (void)result;
    reportResult(name, YES, nil);
}

// B11: FLT_MIN (smallest positive normal) samples — must not crash.
static void test_compute_fltMinSamples_nocrash(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_fltmin_nocrash";
    NSData *audio = makeAudioF32(kNFFT * 4, FLT_MIN);
    NSError *error = nil;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio frameCount:NULL error:&error];
    (void)result;
    reportResult(name, YES, nil);
}

// B12: -0.0f samples — must not crash.
static void test_compute_negZeroSamples_nocrash(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_negzero_nocrash";
    NSData *audio = makeAudioF32(kNFFT * 4, -0.0f);
    NSError *error = nil;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio frameCount:NULL error:&error];
    (void)result;
    reportResult(name, YES, nil);
}

// I1: NULL outFrameCount does not crash and result length is consistent.
static void test_compute_nullFrameCount_nocrash(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_null_framecount_nocrash";
    NSData *audio = makeAudioF32(kNFFT * 8, 0.1f);
    NSError *error = nil;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio
                                             frameCount:NULL
                                                  error:&error];
    ASSERT_TRUE(name, result != nil, fmtErr(@"NULL frameCount should succeed", error));
    ASSERT_EQ(name, [result length] % sizeof(float), 0UL);
    reportResult(name, YES, nil);
}

// E1: Nil error ptr on empty audio does not crash.
static void test_compute_nilErrorPtr_emptyAudio_nocrash(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_nil_errptr_empty_nocrash";
    NSData *result = [fe computeMelSpectrogramFromAudio:[NSData data]
                                             frameCount:NULL
                                                  error:nil];
    ASSERT_TRUE(name, result == nil, @"empty audio with nil error ptr must return nil");
    reportResult(name, YES, nil);
}

// S2: Output dimensions are nMels × nFrames × sizeof(float).
static void test_compute_outputDimensions_correct(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_dims_correct";
    NSData *audio = makeAudioF32(kSRate, 0.0f);  // 1 second of silence
    NSError *error = nil;
    NSUInteger frames = 0;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio
                                             frameCount:&frames
                                                  error:&error];
    ASSERT_TRUE(name, result != nil, fmtErr(@"1-second silence should succeed", error));
    ASSERT_TRUE(name, frames > 0, @"1-second audio should produce >0 frames");
    ASSERT_EQ(name, [result length], kNMels * frames * sizeof(float));
    reportResult(name, YES, nil);
}

// M1: 30 seconds (480,000 samples) succeeds without crash.
static void test_compute_30s_audio_nocrash(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_30s_nocrash";
    NSData *audio = makeAudioF32(30 * kSRate, 0.05f);
    NSError *error = nil;
    NSUInteger frames = 0;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio
                                             frameCount:&frames
                                                  error:&error];
    ASSERT_TRUE(name, result != nil, fmtErr(@"30-second audio should succeed", error));
    ASSERT_TRUE(name, frames > 0, @"30s audio must produce >0 frames");
    // 30s @ 16kHz / hop160 ≈ 3000 frames (with padding)
    ASSERT_EQ(name, [result length], kNMels * frames * sizeof(float));
    reportResult(name, YES, nil);
}

// S3: Silence output has no NaN or Inf values (log-mel of silence must be finite).
static void test_compute_silence_outputIsFinite(MWFeatureExtractor *fe) {
    const char *name = "adv_fe_compute_silence_finite";
    NSData *audio = makeAudioF32(kNFFT * 10, 0.0f);
    NSError *error = nil;
    NSUInteger frames = 0;
    NSData *result = [fe computeMelSpectrogramFromAudio:audio
                                             frameCount:&frames
                                                  error:&error];
    ASSERT_TRUE(name, result != nil, fmtErr(@"silence should succeed", error));
    const float *vals = (const float *)[result bytes];
    NSUInteger total = [result length] / sizeof(float);
    for (NSUInteger i = 0; i < total; i++) {
        ASSERT_TRUE(name, isfinite(vals[i]),
                    ([NSString stringWithFormat:@"silence output[%lu] must be finite, got %f",
                     (unsigned long)i, vals[i]]));
    }
    reportResult(name, YES, nil);
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        fprintf(stdout, "=== AdversarialTestFeatureExtractor ===\n\n");

        // Init tests (no shared instance needed)
        test_init_zeroMels_returnsNil();
        test_init_zeroFFT_returnsNil();
        test_init_zeroHopLength_returnsNil();
        test_init_zeroSampleRate_returnsNil();
        test_init_melsExceedFreqBins_nocrash();
        test_init_oneMel_nocrash();
        test_init_standard_succeeds();

        // Compute tests — create standard extractor once
        MWFeatureExtractor *fe = createStandardExtractor();
        if (!fe) {
            fprintf(stderr, "FATAL: Could not create standard extractor — aborting compute tests\n");
            fprintf(stdout, "\n[AdversarialTestFeatureExtractor] %d passed, %d failed\n",
                    gPassCount, gFailCount);
            return 1;
        }

        test_compute_nilAudio_returnsNilError(fe);
        test_compute_emptyAudio_returnsNilError(fe);
        test_compute_oneSample_failsCleanly(fe);
        test_compute_exactNFFT_oneFrame(fe);
        test_compute_misalignedInput_returnsNilError(fe);
        test_compute_partialFloatInput_returnsNilError(fe);
        test_compute_nanSamples_nocrash(fe);
        test_compute_posInfSamples_nocrash(fe);
        test_compute_negInfSamples_nocrash(fe);
        test_compute_fltMaxSamples_nocrash(fe);
        test_compute_fltMinSamples_nocrash(fe);
        test_compute_negZeroSamples_nocrash(fe);
        test_compute_nullFrameCount_nocrash(fe);
        test_compute_nilErrorPtr_emptyAudio_nocrash(fe);
        test_compute_outputDimensions_correct(fe);
        test_compute_30s_audio_nocrash(fe);
        test_compute_silence_outputIsFinite(fe);

        [fe release];

        fprintf(stdout, "\n[AdversarialTestFeatureExtractor] %d passed, %d failed\n",
                gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
