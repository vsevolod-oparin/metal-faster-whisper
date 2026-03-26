// tests/AdversarialTestAudioDecoder.mm
// Adversarial tests for MWAudioDecoder.
// Tier 1: no model, no GPU. Run on every build.
//
// Attack surface: stateless class methods — decodeAudioAtURL:, decodeAudioFromData:,
// decodeAudioFromBuffer:, padOrTrimAudio:toSampleCount:.
//
// ZOMBIES coverage:
//   Z: nil/empty inputs, zero sample counts
//   O: single-byte data, single-sample audio
//   M: large padding (1M samples)
//   B: partial floats, NaN samples, non-WAVE RIFF
//   I: directory URL, garbage trailer, inverted range, nil error ptr
//   E: error code verification, nil error ptr on failure
//   S: valid empty WAV, valid silence WAV (simple cases first)
//
// Usage: ./AdversarialTestAudioDecoder   (no arguments)

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "MWAudioDecoder.h"
#import "MWTranscriber.h"  // for MWErrorCodeAudioDecodeFailed etc.
#import "MWTestCommon.h"
#include <cmath>
#include <stdint.h>

// ── WAV builder ──────────────────────────────────────────────────────────────

/// Build a RIFF WAV file containing 16-bit PCM silence at the given sample rate.
static NSData *buildWAV16Silence(uint32_t sampleCount, uint32_t sampleRate) {
    uint32_t dataBytes  = sampleCount * sizeof(int16_t);
    uint32_t riffSize   = 36 + dataBytes;
    uint32_t byteRate   = sampleRate * 2;  // 1ch * 2 bytes/sample
    uint16_t blockAlign = 2;
    uint16_t bitsPerSample = 16;
    uint16_t audioFmt   = 1;   // PCM
    uint16_t channels   = 1;

    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataBytes];
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&riffSize length:4];
    [wav appendBytes:"WAVE" length:4];
    [wav appendBytes:"fmt " length:4];
    uint32_t fmtSize = 16;
    [wav appendBytes:&fmtSize length:4];
    [wav appendBytes:&audioFmt length:2];
    [wav appendBytes:&channels length:2];
    [wav appendBytes:&sampleRate length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&blockAlign length:2];
    [wav appendBytes:&bitsPerSample length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataBytes length:4];
    if (dataBytes > 0) {
        void *zeros = calloc(dataBytes, 1);
        [wav appendBytes:zeros length:dataBytes];
        free(zeros);
    }
    return wav;
}

// ── Tests: decodeAudioAtURL: ─────────────────────────────────────────────────

// Z1: Nonexistent path returns nil and sets error with non-zero code.
static void test_decodeURL_nonexistent_returnsNilError(void) {
    const char *name = "adv_audio_decodeURL_nonexistent_nil_error";
    NSError *error = nil;
    NSURL *url = [NSURL fileURLWithPath:@"/nonexistent/path/audio.wav"];
    NSData *result = [MWAudioDecoder decodeAudioAtURL:url error:&error];
    ASSERT_TRUE(name, result == nil, @"expected nil for nonexistent file");
    ASSERT_TRUE(name, error != nil, @"expected non-nil error for nonexistent file");
    ASSERT_TRUE(name, [error code] != 0, @"expected non-zero error code");
    reportResult(name, YES, nil);
}

// I1: Directory URL (not a file) returns nil and sets error.
static void test_decodeURL_directory_returnsNilError(void) {
    const char *name = "adv_audio_decodeURL_directory_nil_error";
    NSURL *url = [NSURL fileURLWithPath:@"/tmp" isDirectory:YES];
    NSError *error = nil;
    NSData *result = [MWAudioDecoder decodeAudioAtURL:url error:&error];
    ASSERT_TRUE(name, result == nil, @"expected nil for directory URL");
    ASSERT_TRUE(name, error != nil, @"expected error for directory URL");
    reportResult(name, YES, nil);
}

// E1: Nil error ptr on nonexistent URL does not crash.
static void test_decodeURL_nonexistent_nilErrorPtr_nocrash(void) {
    const char *name = "adv_audio_decodeURL_nonexistent_nilErrPtr_nocrash";
    NSURL *url = [NSURL fileURLWithPath:@"/nonexistent/path/audio.wav"];
    NSData *result = [MWAudioDecoder decodeAudioAtURL:url error:nil];
    ASSERT_TRUE(name, result == nil, @"expected nil for nonexistent (nil error ptr)");
    reportResult(name, YES, nil);
}

// ── Tests: decodeAudioFromData: ──────────────────────────────────────────────

// Z2: Empty data (0 bytes) returns nil and sets error.
static void test_decodeFromData_empty_returnsNilError(void) {
    const char *name = "adv_audio_decodeData_empty_nil_error";
    NSError *error = nil;
    NSData *result = [MWAudioDecoder decodeAudioFromData:[NSData data] error:&error];
    ASSERT_TRUE(name, result == nil, @"expected nil for 0-byte data");
    ASSERT_TRUE(name, error != nil, @"expected error for 0-byte data");
    reportResult(name, YES, nil);
}

// E2: Nil error ptr on empty data does not crash, returns nil.
static void test_decodeFromData_empty_nilErrorPtr_nocrash(void) {
    const char *name = "adv_audio_decodeData_empty_nilErrPtr_nocrash";
    NSData *result = [MWAudioDecoder decodeAudioFromData:[NSData data] error:nil];
    ASSERT_TRUE(name, result == nil, @"expected nil for empty data (nil error ptr)");
    reportResult(name, YES, nil);
}

// O1: Single byte of garbage returns nil and sets error.
static void test_decodeFromData_oneByte_returnsNilError(void) {
    const char *name = "adv_audio_decodeData_1byte_nil_error";
    uint8_t byte = 0xFF;
    NSData *data = [NSData dataWithBytes:&byte length:1];
    NSError *error = nil;
    NSData *result = [MWAudioDecoder decodeAudioFromData:data error:&error];
    ASSERT_TRUE(name, result == nil, @"expected nil for 1-byte garbage");
    ASSERT_TRUE(name, error != nil, @"expected error for 1-byte garbage");
    reportResult(name, YES, nil);
}

// O2: Four bytes (one float, not a valid audio header) returns nil and sets error.
static void test_decodeFromData_fourBytes_returnsNilError(void) {
    const char *name = "adv_audio_decodeData_4bytes_nil_error";
    float val = 1.0f;
    NSData *data = [NSData dataWithBytes:&val length:sizeof(float)];
    NSError *error = nil;
    NSData *result = [MWAudioDecoder decodeAudioFromData:data error:&error];
    ASSERT_TRUE(name, result == nil, @"expected nil for 4-byte float");
    ASSERT_TRUE(name, error != nil, @"expected error for 4-byte float");
    reportResult(name, YES, nil);
}

// B1: Truncated RIFF header (10 bytes: "RIFF" + partial) returns nil and sets error.
static void test_decodeFromData_truncatedRIFF_returnsNilError(void) {
    const char *name = "adv_audio_decodeData_truncatedRIFF_nil_error";
    uint8_t partial[] = {'R','I','F','F', 100,0,0,0, 'W','A'};
    NSData *data = [NSData dataWithBytes:partial length:sizeof(partial)];
    NSError *error = nil;
    NSData *result = [MWAudioDecoder decodeAudioFromData:data error:&error];
    ASSERT_TRUE(name, result == nil, @"expected nil for truncated RIFF");
    ASSERT_TRUE(name, error != nil, @"expected error for truncated RIFF");
    reportResult(name, YES, nil);
}

// B2: RIFF header with type "AVI " instead of "WAVE" returns nil and sets error.
static void test_decodeFromData_riffNotWave_returnsNilError(void) {
    const char *name = "adv_audio_decodeData_riffNotWave_nil_error";
    uint8_t riffAVI[] = {
        'R','I','F','F', 100,0,0,0,
        'A','V','I',' ',
        'L','I','S','T', 80,0,0,0,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    };
    NSData *data = [NSData dataWithBytes:riffAVI length:sizeof(riffAVI)];
    NSError *error = nil;
    NSData *result = [MWAudioDecoder decodeAudioFromData:data error:&error];
    ASSERT_TRUE(name, result == nil, @"expected nil for non-WAVE RIFF");
    ASSERT_TRUE(name, error != nil, @"expected error for non-WAVE RIFF");
    reportResult(name, YES, nil);
}

// I2: Deterministic random garbage (1024 bytes) returns nil and sets error.
static void test_decodeFromData_randomGarbage_returnsNilError(void) {
    const char *name = "adv_audio_decodeData_garbage_nil_error";
    uint8_t noise[1024];
    for (int i = 0; i < 1024; i++) noise[i] = (uint8_t)(i * 31 + 7);
    NSData *data = [NSData dataWithBytes:noise length:sizeof(noise)];
    NSError *error = nil;
    NSData *result = [MWAudioDecoder decodeAudioFromData:data error:&error];
    ASSERT_TRUE(name, result == nil, @"expected nil for random garbage");
    ASSERT_TRUE(name, error != nil, @"expected error for random garbage");
    reportResult(name, YES, nil);
}

// S1: Valid WAV with 0 samples handles gracefully (no crash, empty or nil result).
static void test_decodeFromData_emptyWAV_nocrash(void) {
    const char *name = "adv_audio_decodeData_emptyWAV_nocrash";
    NSData *wav = buildWAV16Silence(0, 16000);
    NSError *error = nil;
    NSData *result = [MWAudioDecoder decodeAudioFromData:wav error:&error];
    // Must not crash; may return empty data or nil depending on implementation.
    BOOL ok = (result == nil || [result length] == 0);
    ASSERT_TRUE(name, ok, @"0-sample WAV must produce empty or nil result");
    reportResult(name, YES, nil);
}

// S2: Valid WAV with 100 silence samples succeeds and output is float32 aligned.
static void test_decodeFromData_silenceWAV_succeeds(void) {
    const char *name = "adv_audio_decodeData_silence100_succeeds";
    NSData *wav = buildWAV16Silence(100, 16000);
    NSError *error = nil;
    NSData *result = [MWAudioDecoder decodeAudioFromData:wav error:&error];
    ASSERT_TRUE(name, result != nil, fmtErr(@"silence WAV should decode", error));
    ASSERT_EQ(name, [result length] % sizeof(float), 0UL);
    // All silence samples should be near zero.
    const float *samples = (const float *)[result bytes];
    NSUInteger count = [result length] / sizeof(float);
    float maxAbs = 0.0f;
    for (NSUInteger i = 0; i < count; i++) {
        if (fabsf(samples[i]) > maxAbs) maxAbs = fabsf(samples[i]);
    }
    ASSERT_TRUE(name, maxAbs < 0.01f,
                ([NSString stringWithFormat:@"silence should be near zero, got max=%f", maxAbs]));
    reportResult(name, YES, nil);
}

// I3: Valid WAV followed by garbage trailer — must not crash.
static void test_decodeFromData_wavPlusGarbageTrailer_nocrash(void) {
    const char *name = "adv_audio_decodeData_wavGarbageTrailer_nocrash";
    NSMutableData *wav = [NSMutableData dataWithData:buildWAV16Silence(100, 16000)];
    uint8_t garbage[100];
    for (int i = 0; i < 100; i++) garbage[i] = (uint8_t)i;
    [wav appendBytes:garbage length:sizeof(garbage)];
    NSError *error = nil;
    NSData *result = [MWAudioDecoder decodeAudioFromData:wav error:&error];
    // Should succeed (ignoring trailer) or fail cleanly — must NOT crash.
    (void)result;
    (void)error;
    reportResult(name, YES, nil);
}

// ── Tests: decodeAudioFromBuffer: ────────────────────────────────────────────

// Z3: Zero-frame buffer handles gracefully (empty or nil result, no crash).
static void test_decodeFromBuffer_zeroFrames_nocrash(void) {
    const char *name = "adv_audio_decodeBuffer_zeroFrames_nocrash";
    AVAudioFormat *fmt = [[[AVAudioFormat alloc]
                           initWithCommonFormat:AVAudioPCMFormatFloat32
                                    sampleRate:16000
                                      channels:1
                                   interleaved:NO] autorelease];
    ASSERT_TRUE(name, fmt != nil, @"failed to create AVAudioFormat");
    AVAudioPCMBuffer *buf = [[[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt
                                                            frameCapacity:0] autorelease];
    ASSERT_TRUE(name, buf != nil, @"failed to create zero-frame buffer");
    NSError *error = nil;
    NSData *result = [MWAudioDecoder decodeAudioFromBuffer:buf error:&error];
    // Zero frames should produce empty or nil, never crash.
    BOOL ok = (result == nil || [result length] == 0);
    ASSERT_TRUE(name, ok, @"zero-frame buffer should produce empty or nil result");
    reportResult(name, YES, nil);
}

// B3: Buffer with NaN float samples does not crash.
static void test_decodeFromBuffer_nanSamples_nocrash(void) {
    const char *name = "adv_audio_decodeBuffer_nanSamples_nocrash";
    AVAudioFormat *fmt = [[[AVAudioFormat alloc]
                           initWithCommonFormat:AVAudioPCMFormatFloat32
                                    sampleRate:16000
                                      channels:1
                                   interleaved:NO] autorelease];
    ASSERT_TRUE(name, fmt != nil, @"failed to create format");
    AVAudioPCMBuffer *buf = [[[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt
                                                            frameCapacity:1600] autorelease];
    ASSERT_TRUE(name, buf != nil, @"failed to create buffer");
    buf.frameLength = 1600;
    float *data = buf.floatChannelData[0];
    for (int i = 0; i < 1600; i++) data[i] = NAN;
    NSError *error = nil;
    NSData *result = [MWAudioDecoder decodeAudioFromBuffer:buf error:&error];
    // Must not crash; result may be nil or contain NaN-derived values.
    (void)result;
    reportResult(name, YES, nil);
}

// B4: Buffer with +Inf samples does not crash.
static void test_decodeFromBuffer_infSamples_nocrash(void) {
    const char *name = "adv_audio_decodeBuffer_infSamples_nocrash";
    AVAudioFormat *fmt = [[[AVAudioFormat alloc]
                           initWithCommonFormat:AVAudioPCMFormatFloat32
                                    sampleRate:16000
                                      channels:1
                                   interleaved:NO] autorelease];
    ASSERT_TRUE(name, fmt != nil, @"failed to create format");
    AVAudioPCMBuffer *buf = [[[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt
                                                            frameCapacity:1600] autorelease];
    ASSERT_TRUE(name, buf != nil, @"failed to create buffer");
    buf.frameLength = 1600;
    float *data = buf.floatChannelData[0];
    for (int i = 0; i < 1600; i++) data[i] = INFINITY;
    NSError *error = nil;
    NSData *result = [MWAudioDecoder decodeAudioFromBuffer:buf error:&error];
    (void)result;
    reportResult(name, YES, nil);
}

// E3: Nil error ptr with zero-frame buffer does not crash.
static void test_decodeFromBuffer_zeroFrames_nilErrorPtr_nocrash(void) {
    const char *name = "adv_audio_decodeBuffer_nilErrPtr_nocrash";
    AVAudioFormat *fmt = [[[AVAudioFormat alloc]
                           initWithCommonFormat:AVAudioPCMFormatFloat32
                                    sampleRate:16000
                                      channels:1
                                   interleaved:NO] autorelease];
    ASSERT_TRUE(name, fmt != nil, @"failed to create format");
    AVAudioPCMBuffer *buf = [[[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt
                                                            frameCapacity:0] autorelease];
    ASSERT_TRUE(name, buf != nil, @"failed to create buffer");
    NSData *result = [MWAudioDecoder decodeAudioFromBuffer:buf error:nil];
    BOOL ok = (result == nil || [result length] == 0);
    ASSERT_TRUE(name, ok, @"zero-frame buffer with nil error ptr: empty or nil");
    reportResult(name, YES, nil);
}

// ── Tests: padOrTrimAudio:toSampleCount: ─────────────────────────────────────

// Z4: Empty data to 0 samples returns empty NSData (never nil).
static void test_padOrTrim_empty_toZero_returnsEmpty(void) {
    const char *name = "adv_audio_padOrTrim_empty_toZero_empty";
    NSData *result = [MWAudioDecoder padOrTrimAudio:[NSData data] toSampleCount:0];
    ASSERT_TRUE(name, result != nil, @"padOrTrim must never return nil");
    ASSERT_EQ(name, [result length], 0UL);
    reportResult(name, YES, nil);
}

// Z5: Empty data padded to 100 samples returns 100*4 bytes of zeros.
static void test_padOrTrim_empty_pad100_returnsZeros(void) {
    const char *name = "adv_audio_padOrTrim_empty_pad100_zeros";
    NSData *result = [MWAudioDecoder padOrTrimAudio:[NSData data] toSampleCount:100];
    ASSERT_TRUE(name, result != nil, @"padOrTrim must never return nil");
    ASSERT_EQ(name, [result length], (NSUInteger)(100 * sizeof(float)));
    const float *samples = (const float *)[result bytes];
    for (int i = 0; i < 100; i++) {
        ASSERT_TRUE(name, samples[i] == 0.0f,
                    ([NSString stringWithFormat:@"pad sample[%d] must be 0, got %f", i, samples[i]]));
    }
    reportResult(name, YES, nil);
}

// O3: Single sample identity (1→1 is no-op).
static void test_padOrTrim_oneSample_identity(void) {
    const char *name = "adv_audio_padOrTrim_1sample_identity";
    float val = 0.5f;
    NSData *input = [NSData dataWithBytes:&val length:sizeof(float)];
    NSData *result = [MWAudioDecoder padOrTrimAudio:input toSampleCount:1];
    ASSERT_TRUE(name, result != nil, @"padOrTrim must never return nil");
    ASSERT_EQ(name, [result length], (NSUInteger)sizeof(float));
    float out = *(const float *)[result bytes];
    ASSERT_TRUE(name, fabsf(out - val) < 1e-6f,
                ([NSString stringWithFormat:@"1→1 identity: expected %f got %f", val, out]));
    reportResult(name, YES, nil);
}

// B5: Trim 100→50 preserves first 50 samples.
static void test_padOrTrim_trim_preservesFirstN(void) {
    const char *name = "adv_audio_padOrTrim_trim50_firstN";
    float vals[100];
    for (int i = 0; i < 100; i++) vals[i] = (float)i * 0.01f;
    NSData *input = [NSData dataWithBytes:vals length:100 * sizeof(float)];
    NSData *result = [MWAudioDecoder padOrTrimAudio:input toSampleCount:50];
    ASSERT_TRUE(name, result != nil, @"padOrTrim must never return nil");
    ASSERT_EQ(name, [result length], (NSUInteger)(50 * sizeof(float)));
    const float *out = (const float *)[result bytes];
    for (int i = 0; i < 50; i++) {
        ASSERT_TRUE(name, fabsf(out[i] - vals[i]) < 1e-6f,
                    ([NSString stringWithFormat:@"trim sample[%d]: expected %f got %f", i, vals[i], out[i]]));
    }
    reportResult(name, YES, nil);
}

// B6: Pad 50→100 appends zeros.
static void test_padOrTrim_pad_appendsZeros(void) {
    const char *name = "adv_audio_padOrTrim_pad100_appendsZeros";
    float vals[50];
    for (int i = 0; i < 50; i++) vals[i] = (float)i * 0.01f;
    NSData *input = [NSData dataWithBytes:vals length:50 * sizeof(float)];
    NSData *result = [MWAudioDecoder padOrTrimAudio:input toSampleCount:100];
    ASSERT_TRUE(name, result != nil, @"padOrTrim must never return nil");
    ASSERT_EQ(name, [result length], (NSUInteger)(100 * sizeof(float)));
    const float *out = (const float *)[result bytes];
    for (int i = 0; i < 50; i++) {
        ASSERT_TRUE(name, fabsf(out[i] - vals[i]) < 1e-6f,
                    ([NSString stringWithFormat:@"pad: original sample[%d] mismatch", i]));
    }
    for (int i = 50; i < 100; i++) {
        ASSERT_TRUE(name, out[i] == 0.0f,
                    ([NSString stringWithFormat:@"pad: zero sample[%d] = %f", i, out[i]]));
    }
    reportResult(name, YES, nil);
}

// B7: Input with 3 bytes (partial float) does not crash; output size is 5*4=20.
static void test_padOrTrim_partialFloat_nocrash(void) {
    const char *name = "adv_audio_padOrTrim_3bytes_nocrash";
    uint8_t bytes[3] = {0x00, 0x00, 0x80};
    NSData *input = [NSData dataWithBytes:bytes length:3];
    NSData *result = [MWAudioDecoder padOrTrimAudio:input toSampleCount:5];
    ASSERT_TRUE(name, result != nil, @"padOrTrim with partial float must not return nil");
    // 3 bytes < 1 float (4 bytes) = 0 complete samples; result should be 5 zero floats.
    ASSERT_EQ(name, [result length], (NSUInteger)(5 * sizeof(float)));
    reportResult(name, YES, nil);
}

// B8: Input with NaN samples preserves correct output length.
static void test_padOrTrim_nanSamples_correctLength(void) {
    const char *name = "adv_audio_padOrTrim_nanSamples_length";
    float vals[10];
    for (int i = 0; i < 10; i++) vals[i] = NAN;
    NSData *input = [NSData dataWithBytes:vals length:10 * sizeof(float)];
    NSData *result = [MWAudioDecoder padOrTrimAudio:input toSampleCount:5];
    ASSERT_TRUE(name, result != nil, @"padOrTrim with NaN must not return nil");
    ASSERT_EQ(name, [result length], (NSUInteger)(5 * sizeof(float)));
    reportResult(name, YES, nil);
}

// M1: Pad 1 sample to 1,000,000 samples — must not crash and output is correct size.
static void test_padOrTrim_largePad_correctSize(void) {
    const char *name = "adv_audio_padOrTrim_1Mpad_nocrash";
    float val = 0.0f;
    NSData *input = [NSData dataWithBytes:&val length:sizeof(float)];
    NSData *result = [MWAudioDecoder padOrTrimAudio:input toSampleCount:1000000];
    ASSERT_TRUE(name, result != nil, @"large pad must not return nil");
    ASSERT_EQ(name, [result length], (NSUInteger)(1000000 * sizeof(float)));
    reportResult(name, YES, nil);
}

// B9: Trim 100 samples to 0 returns empty data.
static void test_padOrTrim_trimToZero_returnsEmpty(void) {
    const char *name = "adv_audio_padOrTrim_trim_toZero_empty";
    float vals[100];
    for (int i = 0; i < 100; i++) vals[i] = 1.0f;
    NSData *input = [NSData dataWithBytes:vals length:100 * sizeof(float)];
    NSData *result = [MWAudioDecoder padOrTrimAudio:input toSampleCount:0];
    ASSERT_TRUE(name, result != nil, @"padOrTrim to 0 must not return nil");
    ASSERT_EQ(name, [result length], 0UL);
    reportResult(name, YES, nil);
}

// ── Main ─────────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        fprintf(stdout, "=== AdversarialTestAudioDecoder ===\n\n");

        // decodeAudioAtURL:
        test_decodeURL_nonexistent_returnsNilError();
        test_decodeURL_directory_returnsNilError();
        test_decodeURL_nonexistent_nilErrorPtr_nocrash();

        // decodeAudioFromData:
        test_decodeFromData_empty_returnsNilError();
        test_decodeFromData_empty_nilErrorPtr_nocrash();
        test_decodeFromData_oneByte_returnsNilError();
        test_decodeFromData_fourBytes_returnsNilError();
        test_decodeFromData_truncatedRIFF_returnsNilError();
        test_decodeFromData_riffNotWave_returnsNilError();
        test_decodeFromData_randomGarbage_returnsNilError();
        test_decodeFromData_emptyWAV_nocrash();
        test_decodeFromData_silenceWAV_succeeds();
        test_decodeFromData_wavPlusGarbageTrailer_nocrash();

        // decodeAudioFromBuffer:
        test_decodeFromBuffer_zeroFrames_nocrash();
        test_decodeFromBuffer_nanSamples_nocrash();
        test_decodeFromBuffer_infSamples_nocrash();
        test_decodeFromBuffer_zeroFrames_nilErrorPtr_nocrash();

        // padOrTrimAudio:toSampleCount:
        test_padOrTrim_empty_toZero_returnsEmpty();
        test_padOrTrim_empty_pad100_returnsZeros();
        test_padOrTrim_oneSample_identity();
        test_padOrTrim_trim_preservesFirstN();
        test_padOrTrim_pad_appendsZeros();
        test_padOrTrim_partialFloat_nocrash();
        test_padOrTrim_nanSamples_correctLength();
        test_padOrTrim_largePad_correctSize();
        test_padOrTrim_trimToZero_returnsEmpty();

        fprintf(stdout, "\n[AdversarialTestAudioDecoder] %d passed, %d failed\n",
                gPassCount, gFailCount);
        return gFailCount > 0 ? 1 : 0;
    }
}
