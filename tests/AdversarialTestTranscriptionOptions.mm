// tests/AdversarialTestTranscriptionOptions.mm
// Adversarial tests for MWTranscriptionOptions, MWVADOptions, MWSpeechTimestampsMap,
// and MWVoiceActivityDetector.collectChunks (no model, no ONNX required).
//
// Tier 1: no model, no GPU. Run on every build.
//
// ZOMBIES coverage:
//   Z: zero-value numerics, nil/empty arrays, empty chunks
//   O: single-element arrays, one chunk
//   M: many temperatures, large time values
//   B: INT_MAX/INT_MIN for integer props, NaN/Inf/-0.0f for float props
//   I: toDictionary with NaN values, NSCopying independence
//   E: mutate-after-copy, use of defaults factory
//   S: defaults factory first
//
// Usage: ./AdversarialTestTranscriptionOptions   (no arguments)

#import <Foundation/Foundation.h>
#import "MWTranscriptionOptions.h"
#import "MWVoiceActivityDetector.h"
#import "MWTestCommon.h"
#include <cmath>
#include <climits>
#include <cfloat>

// ── MWTranscriptionOptions tests ─────────────────────────────────────────────

// S1: defaults factory creates an object with sensible non-zero values.
static void test_options_defaults_sane(void) {
    const char *name = "adv_opts_defaults_sane";
    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    ASSERT_TRUE(name, opts != nil, @"defaults must not return nil");
    ASSERT_TRUE(name, opts.temperatures != nil, @"temperatures must not be nil");
    ASSERT_TRUE(name, [opts.temperatures count] > 0, @"temperatures must be non-empty");
    ASSERT_TRUE(name, opts.beamSize > 0, @"default beamSize must be > 0");
    ASSERT_TRUE(name, isfinite(opts.patience), @"default patience must be finite");
    reportResult(name, YES, nil);
}

// Z1: beamSize=0 is accepted (disables beam search) and toDictionary does not crash.
static void test_options_beamSize_zero_nocrash(void) {
    const char *name = "adv_opts_beamSize_zero_nocrash";
    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    opts.beamSize = 0;
    NSDictionary *dict = [opts toDictionary];
    ASSERT_TRUE(name, dict != nil, @"toDictionary with beamSize=0 must not return nil");
    reportResult(name, YES, nil);
}

// B1: beamSize=NSUIntegerMax does not crash in toDictionary.
static void test_options_beamSize_max_nocrash(void) {
    const char *name = "adv_opts_beamSize_max_nocrash";
    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    opts.beamSize = NSUIntegerMax;
    NSDictionary *dict = [opts toDictionary];
    ASSERT_TRUE(name, dict != nil, @"toDictionary with NSUIntegerMax beamSize must not crash");
    reportResult(name, YES, nil);
}

// B2: patience=NAN does not crash in toDictionary.
static void test_options_patience_nan_nocrash(void) {
    const char *name = "adv_opts_patience_nan_nocrash";
    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    opts.patience = NAN;
    NSDictionary *dict = [opts toDictionary];
    ASSERT_TRUE(name, dict != nil, @"toDictionary with NaN patience must not crash");
    reportResult(name, YES, nil);
}

// B3: patience=+Inf does not crash in toDictionary.
static void test_options_patience_inf_nocrash(void) {
    const char *name = "adv_opts_patience_inf_nocrash";
    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    opts.patience = INFINITY;
    NSDictionary *dict = [opts toDictionary];
    ASSERT_TRUE(name, dict != nil, @"toDictionary with Inf patience must not crash");
    reportResult(name, YES, nil);
}

// B4: All float properties set to NaN — toDictionary must not crash.
static void test_options_allFloatNaN_toDictionary_nocrash(void) {
    const char *name = "adv_opts_all_float_nan_nocrash";
    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    opts.patience                    = NAN;
    opts.lengthPenalty               = NAN;
    opts.repetitionPenalty           = NAN;
    opts.compressionRatioThreshold   = NAN;
    opts.logProbThreshold            = NAN;
    opts.noSpeechThreshold           = NAN;
    opts.promptResetOnTemperature    = NAN;
    opts.maxInitialTimestamp         = NAN;
    opts.hallucinationSilenceThreshold = NAN;
    opts.languageDetectionThreshold  = NAN;
    NSDictionary *dict = [opts toDictionary];
    ASSERT_TRUE(name, dict != nil, @"toDictionary with all-NaN floats must not crash");
    reportResult(name, YES, nil);
}

// Z2: temperatures=@[] (empty array) does not crash in toDictionary.
static void test_options_emptyTemperatures_nocrash(void) {
    const char *name = "adv_opts_empty_temperatures_nocrash";
    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    opts.temperatures = @[];
    NSDictionary *dict = [opts toDictionary];
    ASSERT_TRUE(name, dict != nil, @"toDictionary with empty temperatures must not crash");
    reportResult(name, YES, nil);
}

// Z3: temperatures=nil does not crash in toDictionary.
static void test_options_nilTemperatures_nocrash(void) {
    const char *name = "adv_opts_nil_temperatures_nocrash";
    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    opts.temperatures = nil;
    NSDictionary *dict = [opts toDictionary];
    // nil temperatures: toDictionary must not crash (may use defaults internally)
    ASSERT_TRUE(name, dict != nil, @"toDictionary with nil temperatures must not crash");
    reportResult(name, YES, nil);
}

// Z4: suppressTokens=nil does not crash in toDictionary.
static void test_options_nilSuppressTokens_nocrash(void) {
    const char *name = "adv_opts_nil_suppressTokens_nocrash";
    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    opts.suppressTokens = nil;
    NSDictionary *dict = [opts toDictionary];
    ASSERT_TRUE(name, dict != nil, @"toDictionary with nil suppressTokens must not crash");
    reportResult(name, YES, nil);
}

// Z5: suppressTokens=@[] (empty) does not crash in toDictionary.
static void test_options_emptySuppress_nocrash(void) {
    const char *name = "adv_opts_empty_suppressTokens_nocrash";
    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    opts.suppressTokens = @[];
    NSDictionary *dict = [opts toDictionary];
    ASSERT_TRUE(name, dict != nil, @"toDictionary with empty suppressTokens must not crash");
    reportResult(name, YES, nil);
}

// B5: maxNewTokens=NSUIntegerMax does not crash in toDictionary.
static void test_options_maxNewTokens_max_nocrash(void) {
    const char *name = "adv_opts_maxNewTokens_max_nocrash";
    MWTranscriptionOptions *opts = [MWTranscriptionOptions defaults];
    opts.maxNewTokens = NSUIntegerMax;
    NSDictionary *dict = [opts toDictionary];
    ASSERT_TRUE(name, dict != nil, @"toDictionary with NSUIntegerMax maxNewTokens must not crash");
    reportResult(name, YES, nil);
}

// I1: NSCopying — copy produces an independent object with identical values.
static void test_options_copy_independence(void) {
    const char *name = "adv_opts_copy_independence";
    MWTranscriptionOptions *orig = [MWTranscriptionOptions defaults];
    orig.beamSize = 7;
    orig.patience = 2.5f;
    orig.temperatures = @[@0.0, @0.4, @0.8];
    orig.initialPrompt = @"Hello";

    MWTranscriptionOptions *copy = [[orig copy] autorelease];
    ASSERT_TRUE(name, copy != nil, @"copy must not return nil");
    ASSERT_TRUE(name, copy != orig, @"copy must be a different object");
    ASSERT_EQ(name, copy.beamSize, (NSUInteger)7);
    ASSERT_TRUE(name, fabsf(copy.patience - 2.5f) < 1e-5f, @"copy patience mismatch");
    ASSERT_EQ(name, [copy.temperatures count], (NSUInteger)3);
    ASSERT_TRUE(name, [copy.initialPrompt isEqualToString:@"Hello"], @"copy prompt mismatch");

    // Mutating original does not affect copy.
    orig.beamSize = 99;
    ASSERT_EQ(name, copy.beamSize, (NSUInteger)7);
    reportResult(name, YES, nil);
}

// I2: NSCopying with nil string properties does not crash.
static void test_options_copy_nilStrings_nocrash(void) {
    const char *name = "adv_opts_copy_nilStrings_nocrash";
    MWTranscriptionOptions *orig = [MWTranscriptionOptions defaults];
    orig.initialPrompt = nil;
    orig.hotwords = nil;
    orig.prefix = nil;
    orig.prependPunctuations = nil;
    orig.appendPunctuations = nil;
    MWTranscriptionOptions *copy = [[orig copy] autorelease];
    ASSERT_TRUE(name, copy != nil, @"copy with nil strings must not return nil");
    reportResult(name, YES, nil);
}

// I3: Mutating temperatures array in copy does not affect original.
static void test_options_copy_temperaturesDeepCopy(void) {
    const char *name = "adv_opts_copy_temperatures_deepcopy";
    MWTranscriptionOptions *orig = [MWTranscriptionOptions defaults];
    orig.temperatures = @[@0.0, @0.5, @1.0];
    MWTranscriptionOptions *copy = [[orig copy] autorelease];
    // Reassign temperatures on copy
    copy.temperatures = @[@0.0];
    // Original must still have 3 entries
    ASSERT_EQ(name, [orig.temperatures count], (NSUInteger)3);
    reportResult(name, YES, nil);
}

// ── MWVADOptions tests ────────────────────────────────────────────────────────

// S2: VADOptions defaults returns non-nil with valid threshold range.
static void test_vadopts_defaults_sane(void) {
    const char *name = "adv_vadopts_defaults_sane";
    MWVADOptions *opts = [MWVADOptions defaults];
    ASSERT_TRUE(name, opts != nil, @"VADOptions defaults must not return nil");
    ASSERT_TRUE(name, opts.threshold >= 0.0f && opts.threshold <= 1.0f,
                @"default threshold must be in [0,1]");
    reportResult(name, YES, nil);
}

// Z6: threshold=0 (silence detector) — property stores correctly.
static void test_vadopts_threshold_zero(void) {
    const char *name = "adv_vadopts_threshold_zero";
    MWVADOptions *opts = [MWVADOptions defaults];
    opts.threshold = 0.0f;
    ASSERT_TRUE(name, opts.threshold == 0.0f, @"threshold=0 must store correctly");
    reportResult(name, YES, nil);
}

// B6: threshold=NaN — stored value is NaN (implementation decides how to use it).
static void test_vadopts_threshold_nan_stored(void) {
    const char *name = "adv_vadopts_threshold_nan_stored";
    MWVADOptions *opts = [MWVADOptions defaults];
    opts.threshold = NAN;
    // Just verify it doesn't crash setting and reading back.
    float v = opts.threshold;
    (void)v;
    reportResult(name, YES, nil);
}

// B7: threshold=+Inf — stored without crash.
static void test_vadopts_threshold_inf(void) {
    const char *name = "adv_vadopts_threshold_inf";
    MWVADOptions *opts = [MWVADOptions defaults];
    opts.threshold = INFINITY;
    float v = opts.threshold;
    (void)v;
    reportResult(name, YES, nil);
}

// B8: negThreshold=NaN — stored without crash.
static void test_vadopts_negThreshold_nan(void) {
    const char *name = "adv_vadopts_negThreshold_nan";
    MWVADOptions *opts = [MWVADOptions defaults];
    opts.negThreshold = NAN;
    float v = opts.negThreshold;
    (void)v;
    reportResult(name, YES, nil);
}

// B9: maxSpeechDurationS=0 — stored correctly.
static void test_vadopts_maxSpeech_zero(void) {
    const char *name = "adv_vadopts_maxSpeech_zero";
    MWVADOptions *opts = [MWVADOptions defaults];
    opts.maxSpeechDurationS = 0.0f;
    ASSERT_TRUE(name, opts.maxSpeechDurationS == 0.0f, @"maxSpeechDurationS=0 stored correctly");
    reportResult(name, YES, nil);
}

// B10: maxSpeechDurationS=NaN — stored without crash.
static void test_vadopts_maxSpeech_nan(void) {
    const char *name = "adv_vadopts_maxSpeech_nan";
    MWVADOptions *opts = [MWVADOptions defaults];
    opts.maxSpeechDurationS = NAN;
    float v = opts.maxSpeechDurationS;
    (void)v;
    reportResult(name, YES, nil);
}

// B11: minSpeechDurationMs=INT_MAX — stored without crash.
static void test_vadopts_minSpeech_intMax(void) {
    const char *name = "adv_vadopts_minSpeech_intmax";
    MWVADOptions *opts = [MWVADOptions defaults];
    opts.minSpeechDurationMs = INT_MAX;
    ASSERT_EQ(name, opts.minSpeechDurationMs, (NSInteger)INT_MAX);
    reportResult(name, YES, nil);
}

// B12: minSpeechDurationMs=INT_MIN — stored without crash.
static void test_vadopts_minSpeech_intMin(void) {
    const char *name = "adv_vadopts_minSpeech_intmin";
    MWVADOptions *opts = [MWVADOptions defaults];
    opts.minSpeechDurationMs = INT_MIN;
    ASSERT_EQ(name, opts.minSpeechDurationMs, (NSInteger)INT_MIN);
    reportResult(name, YES, nil);
}

// B13: speechPadMs=INT_MAX — stored without crash.
static void test_vadopts_speechPad_intMax(void) {
    const char *name = "adv_vadopts_speechPad_intmax";
    MWVADOptions *opts = [MWVADOptions defaults];
    opts.speechPadMs = INT_MAX;
    ASSERT_EQ(name, opts.speechPadMs, (NSInteger)INT_MAX);
    reportResult(name, YES, nil);
}

// ── MWSpeechTimestampsMap tests ───────────────────────────────────────────────

// Z7: Empty chunks with valid samplingRate — all methods return reasonable values.
static void test_tsmap_emptyChunks_nocrash(void) {
    const char *name = "adv_tsmap_empty_chunks_nocrash";
    MWSpeechTimestampsMap *map = [[[MWSpeechTimestampsMap alloc]
                                   initWithChunks:@[]
                                     samplingRate:16000] autorelease];
    ASSERT_TRUE(name, map != nil, @"empty chunks map must not return nil");
    float t = [map originalTimeForTime:0.0f];
    (void)t;
    NSUInteger idx = [map chunkIndexForTime:0.0f isEnd:NO];
    (void)idx;
    reportResult(name, YES, nil);
}

// B14: samplingRate=0 with empty chunks — must not crash (no div-by-zero on ARM).
// This is a critical boundary: integer div-by-zero in originalTimeForTime: would SIGFPE.
static void test_tsmap_zeroSamplingRate_nocrash(void) {
    const char *name = "adv_tsmap_zero_samplingrate_nocrash";
    MWSpeechTimestampsMap *map = [[[MWSpeechTimestampsMap alloc]
                                   initWithChunks:@[]
                                     samplingRate:0] autorelease];
    ASSERT_TRUE(name, map != nil, @"zero-samplingRate map must not return nil on init");
    // originalTimeForTime: must NOT perform integer division by zero.
    // If samplingRate=0 is used in `sample / samplingRate`, that is SIGFPE on ARM.
    float t = [map originalTimeForTime:0.0f];
    (void)t;
    reportResult(name, YES, nil);
}

// B15: originalTimeForTime:NAN — must not crash.
static void test_tsmap_nanTime_nocrash(void) {
    const char *name = "adv_tsmap_nan_time_nocrash";
    MWSpeechTimestampsMap *map = [[[MWSpeechTimestampsMap alloc]
                                   initWithChunks:@[]
                                     samplingRate:16000] autorelease];
    ASSERT_TRUE(name, map != nil, @"init must succeed");
    float t = [map originalTimeForTime:NAN];
    (void)t;
    reportResult(name, YES, nil);
}

// B16: originalTimeForTime:+Inf — must not crash.
static void test_tsmap_infTime_nocrash(void) {
    const char *name = "adv_tsmap_inf_time_nocrash";
    MWSpeechTimestampsMap *map = [[[MWSpeechTimestampsMap alloc]
                                   initWithChunks:@[]
                                     samplingRate:16000] autorelease];
    ASSERT_TRUE(name, map != nil, @"init must succeed");
    float t = [map originalTimeForTime:INFINITY];
    (void)t;
    reportResult(name, YES, nil);
}

// B17: originalTimeForTime:-Inf — must not crash.
static void test_tsmap_negInfTime_nocrash(void) {
    const char *name = "adv_tsmap_neginf_time_nocrash";
    MWSpeechTimestampsMap *map = [[[MWSpeechTimestampsMap alloc]
                                   initWithChunks:@[]
                                     samplingRate:16000] autorelease];
    ASSERT_TRUE(name, map != nil, @"init must succeed");
    float t = [map originalTimeForTime:-INFINITY];
    (void)t;
    reportResult(name, YES, nil);
}

// B18: chunkIndexForTime:NAN — must not crash.
static void test_tsmap_nanTime_chunkIndex_nocrash(void) {
    const char *name = "adv_tsmap_nan_chunkindex_nocrash";
    MWSpeechTimestampsMap *map = [[[MWSpeechTimestampsMap alloc]
                                   initWithChunks:@[]
                                     samplingRate:16000] autorelease];
    ASSERT_TRUE(name, map != nil, @"init must succeed");
    NSUInteger idx = [map chunkIndexForTime:NAN isEnd:NO];
    (void)idx;
    reportResult(name, YES, nil);
}

// B19: chunkIndexForTime:+Inf — must not crash.
static void test_tsmap_infTime_chunkIndex_nocrash(void) {
    const char *name = "adv_tsmap_inf_chunkindex_nocrash";
    MWSpeechTimestampsMap *map = [[[MWSpeechTimestampsMap alloc]
                                   initWithChunks:@[]
                                     samplingRate:16000] autorelease];
    ASSERT_TRUE(name, map != nil, @"init must succeed");
    NSUInteger idx = [map chunkIndexForTime:INFINITY isEnd:YES];
    (void)idx;
    reportResult(name, YES, nil);
}

// I4: originalTimeForTime:time:chunkIndex: with large chunkIndex — must not crash.
static void test_tsmap_largeChunkIndex_nocrash(void) {
    const char *name = "adv_tsmap_large_chunkindex_nocrash";
    NSArray *chunks = @[@{@"start": @(0), @"end": @(16000)}];
    MWSpeechTimestampsMap *map = [[[MWSpeechTimestampsMap alloc]
                                   initWithChunks:chunks
                                     samplingRate:16000] autorelease];
    ASSERT_TRUE(name, map != nil, @"init with 1 chunk must succeed");
    // chunkIndex=NSUIntegerMax far exceeds array bounds.
    float t = [map originalTimeForTime:1.0f chunkIndex:NSUIntegerMax];
    (void)t;
    reportResult(name, YES, nil);
}

// S3: One chunk — originalTimeForTime: for a known time returns a reasonable value.
static void test_tsmap_oneChunk_basicMapping(void) {
    const char *name = "adv_tsmap_onechunk_mapping";
    // Chunk: samples 0..16000 (1 second) from the full audio
    NSArray *chunks = @[@{@"start": @(0), @"end": @(16000)}];
    MWSpeechTimestampsMap *map = [[[MWSpeechTimestampsMap alloc]
                                   initWithChunks:chunks
                                     samplingRate:16000] autorelease];
    ASSERT_TRUE(name, map != nil, @"1-chunk map must succeed");
    // Time 0.5s within the single chunk should map to ≥0.
    float t = [map originalTimeForTime:0.5f];
    ASSERT_TRUE(name, isfinite(t), ([NSString stringWithFormat:@"mapped time must be finite, got %f", t]));
    ASSERT_TRUE(name, t >= 0.0f, ([NSString stringWithFormat:@"mapped time must be ≥0, got %f", t]));
    reportResult(name, YES, nil);
}

// ── MWVoiceActivityDetector.collectChunks tests ──────────────────────────────

// Z8: collectChunks with empty audio and empty chunks returns empty array.
static void test_collectChunks_emptyAudio_emptyChunks(void) {
    const char *name = "adv_vad_collectChunks_empty_empty";
    NSArray *result = [MWVoiceActivityDetector collectChunks:[NSData data]
                                                      chunks:@[]
                                                 maxDuration:INFINITY];
    ASSERT_TRUE(name, result != nil, @"collectChunks must not return nil");
    ASSERT_EQ(name, [result count], 0UL);
    reportResult(name, YES, nil);
}

// Z9: collectChunks with nil audio — must not crash.
static void test_collectChunks_nilAudio_nocrash(void) {
    const char *name = "adv_vad_collectChunks_nilAudio_nocrash";
    NSArray *chunks = @[@{@"start": @(0), @"end": @(16000)}];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    NSArray *result = [MWVoiceActivityDetector collectChunks:(NSData *)nil
                                                      chunks:chunks
                                                 maxDuration:INFINITY];
#pragma clang diagnostic pop
    // Must not crash; result may be nil or empty.
    (void)result;
    reportResult(name, YES, nil);
}

// Z10: collectChunks with empty chunks array returns empty array.
static void test_collectChunks_emptyChunks_returnsEmpty(void) {
    const char *name = "adv_vad_collectChunks_empty_chunks";
    // 1 second of silence audio
    NSMutableData *audio = [NSMutableData dataWithLength:16000 * sizeof(float)];
    NSArray *result = [MWVoiceActivityDetector collectChunks:audio
                                                      chunks:@[]
                                                 maxDuration:INFINITY];
    ASSERT_TRUE(name, result != nil, @"collectChunks with empty chunks must not return nil");
    ASSERT_EQ(name, [result count], 0UL);
    reportResult(name, YES, nil);
}

// I5: Chunk with start > end (inverted range) — must not crash.
static void test_collectChunks_invertedRange_nocrash(void) {
    const char *name = "adv_vad_collectChunks_inverted_nocrash";
    NSMutableData *audio = [NSMutableData dataWithLength:16000 * sizeof(float)];
    NSArray *chunks = @[@{@"start": @(16000), @"end": @(0)}];  // inverted
    NSArray *result = [MWVoiceActivityDetector collectChunks:audio
                                                      chunks:chunks
                                                 maxDuration:INFINITY];
    (void)result;
    reportResult(name, YES, nil);
}

// I6: Chunk with indices exceeding audio length — must not crash.
static void test_collectChunks_outOfBounds_nocrash(void) {
    const char *name = "adv_vad_collectChunks_oob_nocrash";
    NSMutableData *audio = [NSMutableData dataWithLength:16000 * sizeof(float)]; // 1s
    // Chunk claims samples 0..999999 but audio only has 16000 samples.
    NSArray *chunks = @[@{@"start": @(0), @"end": @(999999)}];
    NSArray *result = [MWVoiceActivityDetector collectChunks:audio
                                                      chunks:chunks
                                                 maxDuration:INFINITY];
    // Must not crash or overflow buffer; may return truncated or empty result.
    (void)result;
    reportResult(name, YES, nil);
}

// B20: maxDuration=0 — must not crash (may return many tiny or zero chunks).
static void test_collectChunks_maxDurationZero_nocrash(void) {
    const char *name = "adv_vad_collectChunks_maxDur0_nocrash";
    NSMutableData *audio = [NSMutableData dataWithLength:16000 * sizeof(float)];
    NSArray *chunks = @[@{@"start": @(0), @"end": @(16000)}];
    NSArray *result = [MWVoiceActivityDetector collectChunks:audio
                                                      chunks:chunks
                                                 maxDuration:0.0f];
    (void)result;
    reportResult(name, YES, nil);
}

// B21: maxDuration=NAN — must not crash.
static void test_collectChunks_maxDurationNaN_nocrash(void) {
    const char *name = "adv_vad_collectChunks_maxDurNaN_nocrash";
    NSMutableData *audio = [NSMutableData dataWithLength:16000 * sizeof(float)];
    NSArray *chunks = @[@{@"start": @(0), @"end": @(16000)}];
    NSArray *result = [MWVoiceActivityDetector collectChunks:audio
                                                      chunks:chunks
                                                 maxDuration:NAN];
    (void)result;
    reportResult(name, YES, nil);
}

// B22: maxDuration=-Inf — must not crash.
static void test_collectChunks_maxDurationNegInf_nocrash(void) {
    const char *name = "adv_vad_collectChunks_maxDurNegInf_nocrash";
    NSMutableData *audio = [NSMutableData dataWithLength:16000 * sizeof(float)];
    NSArray *chunks = @[@{@"start": @(0), @"end": @(16000)}];
    NSArray *result = [MWVoiceActivityDetector collectChunks:audio
                                                      chunks:chunks
                                                 maxDuration:-INFINITY];
    (void)result;
    reportResult(name, YES, nil);
}

// S4: Valid 1-second chunk with Inf maxDuration returns exactly one NSData chunk.
static void test_collectChunks_oneChunk_infDuration_returnsOne(void) {
    const char *name = "adv_vad_collectChunks_1chunk_inf_returnsOne";
    float sampleVal = 0.1f;
    NSMutableData *audio = [NSMutableData dataWithCapacity:16000 * sizeof(float)];
    for (int i = 0; i < 16000; i++) {
        [audio appendBytes:&sampleVal length:sizeof(float)];
    }
    NSArray *chunks = @[@{@"start": @(0), @"end": @(16000)}];
    NSArray *result = [MWVoiceActivityDetector collectChunks:audio
                                                      chunks:chunks
                                                 maxDuration:INFINITY];
    ASSERT_TRUE(name, result != nil, @"collectChunks must not return nil");
    ASSERT_EQ(name, [result count], 1UL);
    NSData *chunk = result[0];
    ASSERT_TRUE(name, [chunk isKindOfClass:[NSData class]], @"chunk must be NSData");
    ASSERT_EQ(name, [chunk length], (NSUInteger)(16000 * sizeof(float)));
    reportResult(name, YES, nil);
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        fprintf(stdout, "=== AdversarialTestTranscriptionOptions ===\n\n");

        // MWTranscriptionOptions
        test_options_defaults_sane();
        test_options_beamSize_zero_nocrash();
        test_options_beamSize_max_nocrash();
        test_options_patience_nan_nocrash();
        test_options_patience_inf_nocrash();
        test_options_allFloatNaN_toDictionary_nocrash();
        test_options_emptyTemperatures_nocrash();
        test_options_nilTemperatures_nocrash();
        test_options_nilSuppressTokens_nocrash();
        test_options_emptySuppress_nocrash();
        test_options_maxNewTokens_max_nocrash();
        test_options_copy_independence();
        test_options_copy_nilStrings_nocrash();
        test_options_copy_temperaturesDeepCopy();

        // MWVADOptions
        test_vadopts_defaults_sane();
        test_vadopts_threshold_zero();
        test_vadopts_threshold_nan_stored();
        test_vadopts_threshold_inf();
        test_vadopts_negThreshold_nan();
        test_vadopts_maxSpeech_zero();
        test_vadopts_maxSpeech_nan();
        test_vadopts_minSpeech_intMax();
        test_vadopts_minSpeech_intMin();
        test_vadopts_speechPad_intMax();

        // MWSpeechTimestampsMap
        test_tsmap_emptyChunks_nocrash();
        test_tsmap_zeroSamplingRate_nocrash();
        test_tsmap_nanTime_nocrash();
        test_tsmap_infTime_nocrash();
        test_tsmap_negInfTime_nocrash();
        test_tsmap_nanTime_chunkIndex_nocrash();
        test_tsmap_infTime_chunkIndex_nocrash();
        test_tsmap_largeChunkIndex_nocrash();
        test_tsmap_oneChunk_basicMapping();

        // MWVoiceActivityDetector.collectChunks
        test_collectChunks_emptyAudio_emptyChunks();
        test_collectChunks_nilAudio_nocrash();
        test_collectChunks_emptyChunks_returnsEmpty();
        test_collectChunks_invertedRange_nocrash();
        test_collectChunks_outOfBounds_nocrash();
        test_collectChunks_maxDurationZero_nocrash();
        test_collectChunks_maxDurationNaN_nocrash();
        test_collectChunks_maxDurationNegInf_nocrash();
        test_collectChunks_oneChunk_infDuration_returnsOne();

        fprintf(stdout, "\n[AdversarialTestTranscriptionOptions] %d passed, %d failed\n",
                gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
