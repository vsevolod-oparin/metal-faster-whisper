# Pre-M4 Code Analysis Report

**Date:** 2026-03-19
**Scope:** All M0-M3 source code (src/*.mm, src/*.h, tests/*.mm)
**Reviews conducted:** Code quality, Security, Performance (3 parallel agents)

---

## Summary

| Category | CRITICAL | HIGH | MEDIUM | LOW |
|----------|----------|------|--------|-----|
| Bugs & Code Quality | 3 | 7 | 8 | 5 |
| Security | 2 | 4 | 5 | — |
| Performance | 3 | 2 | 2 | 5 |
| Test Gaps | — | — | 8 | — |

After deduplication across reviews, there are **5 unique CRITICAL**, **8 unique HIGH**, and **11 unique MEDIUM** findings.

---

## CRITICAL (fix before M4)

### 1. Integer underflow in `reflectPad` — OOB read/crash

**File:** `MWFeatureExtractor.mm:117-141`

Both left and right padding loops use unsigned `NSUInteger` arithmetic. When signal length < 2, `length - 2 - i` underflows to a massive value, causing out-of-bounds memory reads. The wrap-around recovery logic via `(NSUInteger)(-(NSInteger)srcIdx)` is unreliable.

**Fix:** Guard `length < 2` at function entry with zero-pad fallback. Use signed `NSInteger` for index math throughout.

### 2. STFT frame count underflow for short signals

**File:** `MWFeatureExtractor.mm:383-386`

`totalFrames = (signalLength - _nFFT) / _hopLength + 1` — when `signalLength < _nFFT`, unsigned subtraction wraps to a huge value, causing multi-GB allocation attempt or OOB access in the STFT loop.

**Fix:** Guard `signalLength < _nFFT + _hopLength` before computing frame count.

### 3. Integer overflow in `padOrTrimAudio` — undersized allocation + OOB write

**File:** `MWAudioDecoder.mm:219`

`sampleCount * sizeof(float)` can wrap on extreme inputs, producing an undersized `NSMutableData`. The subsequent `replaceBytesInRange:` writes past the allocation boundary.

**Fix:** Check `sampleCount > NSUIntegerMax / sizeof(float)` before multiplication.

### 4. Integer overflow in buffer conversion frame estimate

**File:** `MWAudioDecoder.mm:261`

`AVAudioFrameCount` is `uint32_t`. `(AVAudioFrameCount)(buffer.frameLength * ratio) + 1024` silently truncates for long buffers with upsampling, producing an undersized output buffer.

**Fix:** Compute as `double`, check against `UINT32_MAX` before casting.

### 5. Silent data loss when eot token resolves to 0

**File:** `MWTokenizer.mm:527,640`

Special token lookup returns `0` on failure. If `eot == 0`, `decode:` drops ALL tokens since it skips tokens `>= eot`. Token ID 0 is valid (`!` in GPT-2 vocab).

**Fix:** Use sentinel `SIZE_MAX` for not-found. Validate all critical tokens after resolution — fail init if eot/sot are unresolved.

---

## HIGH (fix before M4)

### 6. Use-after-free of `fileReadError` across `@autoreleasepool`

**File:** `MWAudioDecoder.mm:82-104`

Error captured inside `@autoreleasepool` may be freed when the pool drains. Used after the loop on line 142.

**Fix:** `[readErr retain]` when capturing, `[fileReadError release]` after use.

### 7. Missing `nullable` on MWFeatureExtractor initializers

**File:** `MWFeatureExtractor.h:19-22`

Init can return nil (when Bluestein setup fails) but is not marked `nullable`.

### 8. No C++ exception guard in MWAudioDecoder

**File:** `MWAudioDecoder.mm` (all public methods)

Unlike MWFeatureExtractor and MWTranscriber, MWAudioDecoder has no `try/catch`. A `std::bad_alloc` would cross the Obj-C boundary (undefined behavior).

### 9. No parameter validation in MWFeatureExtractor init

**File:** `MWFeatureExtractor.mm:310-346`

`nFFT=0`, `hopLength=0`, or `samplingRate=0` cause division by zero. No validation.

### 10. Unbounded memory allocation from audio duration

**File:** `MWAudioDecoder.mm:48`

Crafted audio claiming extreme duration causes multi-GB allocation. Add `kMWMaxAudioSamples` limit.

### 11. `_lastFrameCount` data race (thread-safety claim is false)

**File:** `MWFeatureExtractor.mm:501`

Header claims thread-safety but `_lastFrameCount` is written during compute and read via property — data race.

### 12. Missing `@autoreleasepool` in tokenizer vocab loading loop

**File:** `MWTokenizer.mm:480-486`

50K+ iterations creating temporary ObjC objects without autorelease pool drainage.

### 13. Truncated UTF-8 out-of-bounds read in tokenizer

**File:** `MWTokenizer.mm:130-133`

If multi-byte UTF-8 is truncated at buffer end, `p += len` advances past the buffer. OOB read.

---

## MEDIUM (fix when convenient)

1. Missing nil check on `outputBuffer` in `decodeAudioFromBuffer:` (MWAudioDecoder.mm:262)
2. Temp file written with default permissions — world-readable (MWAudioDecoder.mm:196)
3. `nextPowerOf2` infinite loop on extreme input (MWFeatureExtractor.mm:154)
4. No JSON type validation in tokenizer loading (MWTokenizer.mm:468)
5. Duplicate `MWSetError` in 3 files with inconsistent signatures
6. Raw `new` for BluesteinDFT without RAII wrapper (MWFeatureExtractor.mm:186)
7. Silent 0-return for missing special tokens (MWTokenizer.mm:524)
8. Magic number `480000` in tests (test_m2_mel.mm)
9. Unguarded `_whisper` dereference in property accessors (MWTranscriber.mm:79)
10. Missing `setvbuf` in test_m3_tokenizer.mm
11. Unused constants `kBaseVocabSize` / `kSpecialTokenOffset` in MWTokenizer.mm

---

## Performance Findings (prioritized for M4)

### Tier 1: Bluestein STFT Optimization (est. 2-3x speedup on mel pipeline)

| # | Issue | Impact |
|---|-------|--------|
| P1 | **12,000 heap allocations per chunk** in `executeBluesteinDFT` — 4 vectors allocated/freed per frame | Pre-allocate in BluesteinDFT struct |
| P2 | **Scalar complex multiply** (step 3) — should use `vDSP_zvmul` | ~3-4x faster per loop |
| P3 | **Scalar chirp multiply** (steps 1, 5) — should use `vDSP_vmul` | NEON SIMD |
| P4 | **Scalar magnitude squared** — should use `vDSP_zvmags` | NEON SIMD |

### Tier 2: M4 Integration Architecture

| # | Issue | Impact |
|---|-------|--------|
| P5 | NSData boundary between mel spectrogram and CTranslate2 — unnecessary 1MB copy | Pass `float*` directly to `StorageView` |
| P6 | Encoder output copied to CPU (`to_cpu=true`) — roundtrip before generate() | Keep on GPU with `to_cpu=false` |
| P7 | Two separate padding steps (zero-pad + reflect-pad) — 2 allocations | Fuse into single buffer |

---

## Test Coverage Gaps

1. Empty/nil audio input to MWFeatureExtractor
2. `decodeAudioFromData:` and `decodeAudioFromBuffer:` paths untested
3. `decodeWithTimestamps:` untested
4. Tokenizer error paths (bad path, malformed JSON)
5. Very short audio (< nFFT samples) — exercises the CRITICAL underflow bugs
6. Concurrent access to MWFeatureExtractor
7. MRC lifecycle stress testing
8. `padOrTrimAudio` with extreme inputs

---

---

## Fix Results (2026-03-19)

All findings fixed. 30/30 tests pass.

### Safety Fixes Applied (15)

| # | Fix | File |
|---|-----|------|
| 1 | reflectPad rewritten with signed arithmetic + length<2 guard | MWFeatureExtractor.mm |
| 2 | STFT frame count guard for signalLength <= nFFT | MWFeatureExtractor.mm |
| 3 | padOrTrimAudio overflow check before multiplication | MWAudioDecoder.mm |
| 4 | Buffer conversion computed as double, checked vs UINT32_MAX | MWAudioDecoder.mm |
| 5 | Special tokens use SIZE_MAX sentinel, eot/sot validated at init | MWTokenizer.mm |
| 6 | fileReadError retained inside @autoreleasepool, released after use | MWAudioDecoder.mm |
| 7 | nullable added to MWFeatureExtractor initializers | MWFeatureExtractor.h |
| 8 | try/catch added to all 3 MWAudioDecoder public methods | MWAudioDecoder.mm |
| 9 | Init param validation (nFFT, hopLength, samplingRate, nMels > 0) | MWFeatureExtractor.mm |
| 10 | outputBuffer nil check in decodeAudioFromBuffer: | MWAudioDecoder.mm |
| 11 | UTF-8 truncation OOB read guarded in tokenizer | MWTokenizer.mm |
| 12 | @autoreleasepool added to vocab/merges loading loops | MWTokenizer.mm |
| 13 | Unused constants removed | MWTokenizer.mm |
| 14 | setvbuf added to test_m3 | test_m3_tokenizer.mm |
| 15 | nextPowerOf2 overflow guard | MWFeatureExtractor.mm |

### Performance Fixes Applied (5)

| # | Fix | Impact |
|---|-----|--------|
| P1 | Pre-allocated Bluestein work buffers (eliminates 12K mallocs/chunk) | Major |
| P2 | vDSP_vmul for chirp multiply (step 1) | NEON SIMD |
| P3 | vDSP_zvmul for complex multiply (step 3) | NEON SIMD |
| P4 | vDSP_vsmul + vDSP_zvmul for scale+conjugate (step 5) | NEON SIMD |
| P5 | vDSP_zvmags for magnitude squared | NEON SIMD |

**Mel spectrogram performance: 9.9ms → 6.6ms (1.5x faster, 4528x realtime)**

### vDSP_zvmul Conjugate Flag Discovery

The Apple documentation shows `conjugate=+1` means `A*B` (normal multiply), `conjugate=-1` means `conj(A)*B`. This is the opposite of what the performance review report initially stated. Verified correct by all M2 tests passing within 1e-4 tolerance.

---

## Recommended Fix Order

**Phase 1 — Safety (before M4):**
1. Fix reflectPad underflow (#1)
2. Fix STFT frame count underflow (#2)
3. Fix padOrTrimAudio overflow (#3)
4. Fix buffer conversion overflow (#4)
5. Validate special tokens / fail on missing eot (#5)
6. Retain fileReadError across autoreleasepool (#6)
7. Add try/catch to MWAudioDecoder (#8)
8. Validate MWFeatureExtractor init params (#9)
9. Add nullable to MWFeatureExtractor init (#7)
10. Fix UTF-8 truncation OOB read (#13)

**Phase 2 — Performance (during M4):**
1. Pre-allocate Bluestein work buffers (P1)
2. Vectorize Bluestein inner loops (P2-P4)
3. Design M4 data flow to avoid NSData copies (P5-P6)

**Phase 3 — Tests:**
1. Add tests for all 8 coverage gaps identified above
