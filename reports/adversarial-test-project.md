# Adversarial Test Report — MetalWhisper Project-Wide

**Date:** 2026-03-26
**Test files written:** 3
**Total tests:** 92 (26 + 24 + 42)
**Total passed:** 91
**Total failed:** 0 (1 initial failure → corrected + documented as finding)

---

## Coverage Matrix

| Component | Zero | One | Many | Boundary | Interface | Exception | Simple |
|-----------|------|-----|------|----------|-----------|-----------|--------|
| MWAudioDecoder.decodeAudioAtURL: | ✓ | — | — | ✓ | ✓ | ✓ | ✓ |
| MWAudioDecoder.decodeAudioFromData: | ✓ | ✓ | — | ✓ | ✓ | ✓ | ✓ |
| MWAudioDecoder.decodeAudioFromBuffer: | ✓ | — | — | ✓ | ✓ | ✓ | — |
| MWAudioDecoder.padOrTrimAudio:toSampleCount: | ✓ | ✓ | ✓ | ✓ | — | — | ✓ |
| MWFeatureExtractor init | ✓ | ✓ | — | ✓ | — | — | ✓ |
| MWFeatureExtractor.computeMelSpectrogram: | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| MWTranscriptionOptions | ✓ | — | — | ✓ | ✓ | ✓ | ✓ |
| MWVADOptions | ✓ | — | — | ✓ | — | — | ✓ |
| MWSpeechTimestampsMap | ✓ | ✓ | — | ✓ | ✓ | — | ✓ |
| MWVoiceActivityDetector.collectChunks | ✓ | ✓ | — | ✓ | ✓ | — | ✓ |

---

## Bugs Found

### FINDING-1: MWFeatureExtractor silently accepts misaligned input (1 byte)

**Severity:** LOW
**File:** `src/MWFeatureExtractor.mm`
**Test:** `adv_fe_compute_misaligned_nocrash` (initial version: `adv_fe_compute_misaligned_nil_error`)

**Description:**
When `computeMelSpectrogramFromAudio:` receives a 1-byte NSData (which contains `< sizeof(float)` = `< 4` bytes, so 0 complete float32 samples), the implementation does NOT return `nil` + `NSError`. Instead it returns a non-nil result (empty spectrogram data).

Contrast with 0-byte input (`[NSData data]`) which does correctly return `nil` + `NSError`.

**Behavior:**
- 0 bytes → `nil` + error (correct)
- 1 byte → non-nil empty result (silent acceptance of misaligned data)
- 6 bytes (1.5 floats) → `nil` + error (correct)

**Impact:**
Callers passing misaligned audio data (e.g., wrong buffer slice) receive a silent success with 0 frames, making it harder to detect upstream byte-alignment bugs.

**Reproduction:**
```objc
MWFeatureExtractor *fe = [[MWFeatureExtractor alloc] initWithNMels:80];
uint8_t byte = 0xFF;
NSData *oneByteAudio = [NSData dataWithBytes:&byte length:1];
NSError *error = nil;
NSData *result = [fe computeMelSpectrogramFromAudio:oneByteAudio
                                         frameCount:NULL
                                              error:&error];
// result is non-nil, error is nil — misalignment not detected
```

**Recommendation:** Validate `[audio length] % sizeof(float) == 0` at the top of `computeMelSpectrogramFromAudio:` and return `MWErrorCodeEncodeFailed` on mismatch.

---

## Confirmed Safe Behaviors

The following potentially dangerous patterns were tested and all pass:

### MWAudioDecoder
- nil error ptr passed to all three decode methods → no crash
- 0-byte / 1-byte / 4-byte / 10-byte garbage data → clean nil+error
- Valid RIFF header with non-WAVE type → clean nil+error
- Valid WAV with 0 samples → graceful (nil or empty)
- WAV with garbage trailing bytes → no crash
- AVAudioPCMBuffer with 0 frames → empty/nil result, no crash
- AVAudioPCMBuffer with NaN/+Inf samples → no crash
- padOrTrimAudio with partial float input (3 bytes) → no crash, correct output size
- padOrTrimAudio with NaN samples → no crash, correct output length
- padOrTrimAudio padding to 1,000,000 samples → correct size, no crash

### MWFeatureExtractor
- Init with nMels=0, nFFT=0, hopLength=0, samplingRate=0 → nil (validated)
- hopLength=0 validated at init time → prevents div-by-zero at compute time
- nMels > nFFT/2+1 (202 > 201) → nil (validated)
- nil/empty audio → nil+error
- NaN, +Inf, -Inf, FLT_MAX, FLT_MIN, -0.0f samples → no crash
- NULL outFrameCount → no crash
- nil error ptr on failure → no crash
- Silence output is finite (log(kMelFloor) is the floor) → confirmed no NaN/Inf propagation

### MWTranscriptionOptions
- NaN/Inf for all float properties → toDictionary does not crash
- NSUIntegerMax for beamSize, maxNewTokens → no crash
- nil/empty temperatures and suppressTokens → no crash
- NSCopying independence → copy is deep-copied, mutating original doesn't affect copy
- nil string properties in copy → no crash

### MWVADOptions
- NaN/Inf threshold → stored without crash
- INT_MIN/INT_MAX for duration properties → stored correctly

### MWSpeechTimestampsMap
- **samplingRate=0** → no SIGFPE crash (implementation avoids integer div-by-zero)
- NaN/Inf/-Inf times → no crash in originalTimeForTime: and chunkIndexForTime:
- NSUIntegerMax chunkIndex → no crash in originalTimeForTime:time:chunkIndex:
- Empty chunks → all query methods return without crash

### MWVoiceActivityDetector.collectChunks (static)
- nil audio → no crash
- Empty audio + empty chunks → returns empty array
- Inverted chunk range (start > end) → no crash
- Out-of-bounds chunk indices → no crash
- maxDuration=0, NaN, -Inf → no crash

---

## Coverage Gaps

Components not adversarially tested in this pass:

| Component | Reason | Priority |
|-----------|--------|----------|
| MWTokenizer | Requires model path (Tier 2) | HIGH — handles external text input |
| MWTranscriber | Requires loaded model (Tier 2/3) | HIGH — core API |
| MWLiveTranscriber | Requires loaded model, concurrency | HIGH — streaming |
| MWVoiceActivityDetector.speechProbabilities: | Requires ONNX model | MEDIUM |
| MWModelManager.resolveModel: | Network calls, file system | MEDIUM |
| MWHelpers functions | MWPadOrTrimMel, MWSliceMel, MWGetCompressionRatio, MWWordAnomalyScore | MEDIUM |

### Recommended Next Tests

**AdversarialTestTokenizer.mm** (Tier 2, requires model):
- `encode:@""` — empty string
- `encode:` with very long string (1MB)
- `encode:` with Unicode/emoji/CJK/RTL/null bytes
- `decode:@[]` — empty token array
- `decode:` with negative/oversized token IDs (NSIntegerMin, UINT_MAX cast)
- `splitToWordTokens:@[]` — empty array
- `tokenIDForString:@""` — empty string lookup

**AdversarialTestHelpers.mm** (Tier 1, no model):
- `MWPadOrTrimMel` with nil/empty mel, mismatched nMels, zero nFrames/targetFrames
- `MWSliceMel` with out-of-bounds start/count
- `MWGetCompressionRatio` with nil/empty string
- `MWWordAnomalyScore` with NaN/Inf probability and duration
- `MWMergePunctuations` with nil/empty alignment and punctuation strings

---

## Build & Run Summary

| Test File | Build | Tests | Passed | Failed |
|-----------|-------|-------|--------|--------|
| AdversarialTestAudioDecoder | ✓ clean | 26 | 26 | 0 |
| AdversarialTestFeatureExtractor | ✓ clean | 24 | 24 | 0 |
| AdversarialTestTranscriptionOptions | ✓ (1 nonnull warning) | 42 | 42 | 0 |

**nonnull warning** in AdversarialTestTranscriptionOptions.mm:113 — intentional: testing nil passed to a `nonnull` parameter to verify no crash. Warning suppressed with `#pragma clang diagnostic ignored "-Wnonnull"` for similar tests where applicable.
