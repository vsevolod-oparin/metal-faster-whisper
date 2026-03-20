# Final Code Analysis Report -- MetalWhisper

**Date:** 2026-03-20
**Scope:** All source files in src/, cli/, tests/
**Files analyzed:** MWTranscriber.mm/.h, MWTranscriptionOptions.mm/.h, MWAudioDecoder.mm/.h, MWFeatureExtractor.mm/.h, MWTokenizer.mm/.h, MWVoiceActivityDetector.mm/.h, MWModelManager.mm/.h, MWHelpers.mm/.h, MWConstants.h, MetalWhisper.h, cli/metalwhisper.mm

---

## CRITICAL (must fix)

### C1. `_whisperCPU` lazy init race condition (MWTranscriber.mm:1098-1109)

The `_whisperCPU` lazy initialization is protected by `@synchronized(self)`, but subsequent use of `_whisperCPU->align()` at line 1111 occurs **outside** the lock. If `transcribeAudio:` is called concurrently (e.g., via the async API `transcribeURL:...completionHandler:`), two threads could both pass the init check, then one thread could call `_whisperCPU.reset()` (line 2125) while the other is still inside `align()`.

**Impact:** Use-after-free crash in concurrent usage.
**Fix:** Either hold the lock for the duration of `align()`, or remove the `_whisperCPU.reset()` call at line 2125 (which is an optimization, not a correctness requirement), or document that concurrent transcription on the same `MWTranscriber` instance is unsupported.

### C2. `BluesteinDFT` work buffers are not thread-safe (MWFeatureExtractor.mm:217-223)

The `BluesteinDFT` struct reuses `workAR`/`workAI`/`workCR`/`workCI` buffers across calls. The code comments note this, but `MWFeatureExtractor` is a property of `MWTranscriber` and could be called from multiple threads via the async API. If two threads call `computeMelSpectrogramFromAudio:` simultaneously on the same `MWFeatureExtractor` instance, the shared work buffers will be corrupted.

**Impact:** Silent data corruption in mel spectrogram computation under concurrent use.
**Fix:** Either create per-call work buffers (allocate in `executeBluesteinDFT`), use thread-local `BluesteinDFT` contexts, or document single-threaded constraint.

---

## HIGH (should fix)

### H1. `fileReadError` double-release risk in MWAudioDecoder.mm:107-108

Inside the `readIntoBuffer:` callback block:
```objc
[fileReadError release];
fileReadError = [readErr retain];
```
`fileReadError` is a `__block NSError *` initialized to `nil`. This pattern is correct on first error, but if the block is called multiple times with errors, the previous `fileReadError` is released and the new one retained. However, after the loop exits, `fileReadError` is released at line 155 regardless of whether `readError` is true. If `readError` is NO and the callback was never called with an error, `fileReadError` is still `nil` and `[nil release]` is safe. **However**, there is a subtle issue: if the converter calls the block multiple times and each time there's a different error, the intermediate releases are fine. But if an exception is thrown between `[fileReadError release]` and `fileReadError = [readErr retain]`, the variable would be in an invalid state. Since this is inside a `@autoreleasepool` with no exception handlers, this is low-probability but worth noting.

**Recommendation:** Use a local variable pattern or `@try/@finally` around the error handling.

### H2. Async API thread safety for `_whisper` model (MWTranscriber.mm)

The `transcribeURL:...completionHandler:` method dispatches transcription to a background queue. The method comments state `segmentHandler` is called on a background queue. However, the underlying `_whisper->encode()` and `_whisper->generate()` calls are not synchronized. If a user calls the async API twice simultaneously, both threads will call into the same CT2 Whisper model instance. CT2's thread safety guarantees are not documented in this codebase.

**Impact:** Potential data races inside CT2 if concurrent calls are made.
**Fix:** Either serialize all CT2 calls via a dispatch queue, or document that only one transcription can run at a time per `MWTranscriber` instance.

### H3. Missing overflow check in `computeSTFTMagnitudesSquared` (MWFeatureExtractor.mm:462)

```objc
std::vector<float> magnitudes(nFreqs * nFrames, 0.0f);
```
If `nFreqs * nFrames` overflows `size_t`, this would allocate a tiny buffer. In practice, `nFreqs` is 201 and `nFrames` is bounded by the audio length, so overflow is unlikely for reasonable inputs. But there is no explicit guard.

**Recommendation:** Add a check: `if (nFreqs > SIZE_MAX / nFrames) return {};`

### H4. `strtol` without `errno` check for `--beam-size` (metalwhisper.mm:416-421)

```c
long val = strtol(argv[i], NULL, 10);
```
`strtol` with a NULL `endptr` cannot detect non-numeric input like "abc" -- it returns 0. The range check `val < 1` catches this case (returns error). However, mixed input like "5abc" would parse as 5 and succeed silently. Use `endptr` to verify the entire string was consumed.

### H5. `MWTranscriptionOptions` default `beamSize` is 6 but `transcribeAudio:` defaults to 5

In `MWTranscriptionOptions.mm:13`: `_beamSize = 6;`
In `MWTranscriber.mm:1600`: `NSUInteger beamSize = MWOptUInt(options, @"beamSize", 5);`

When using the `NSDictionary` API with `nil` options, beamSize defaults to 5. When using `MWTranscriptionOptions`, beamSize defaults to 6. This inconsistency means the two API paths produce different results for the same audio with "default" settings. The Python reference uses beam_size=5 by default.

**Fix:** Align the defaults. Either change `MWTranscriptionOptions` to default to 5, or change the NSDictionary fallback to 6. The Python `faster-whisper` default is 5.

Similarly, `lengthPenalty` defaults to 0.6 in `MWTranscriptionOptions` but 1.0 in the NSDictionary path. Python default is 1.0.

---

## MEDIUM (nice to fix)

### M1. `MWSetError` function defined in multiple translation units

`MWSetError` is defined as a `static` function in `MWAudioDecoder.mm`, `MWFeatureExtractor.mm`, and `MWTokenizer.mm`, plus as a non-static function in `MWHelpers.mm`. The static versions shadow the shared one. This works but is redundant -- the static copies in each .mm file are unnecessary since `MWHelpers.h` declares the shared version.

**Fix:** Remove the static `MWSetError` definitions from `MWAudioDecoder.mm`, `MWFeatureExtractor.mm`, and `MWTokenizer.mm`, and use the shared one from `MWHelpers.h`.

### M2. `kMWErrorCodeTokenizerLoadFailed` redefined as local constant (MWTokenizer.mm:29)

```cpp
static const NSInteger kMWErrorCodeTokenizerLoadFailed = 200;
```
This duplicates the value from `MWErrorCode` enum (`MWErrorCodeTokenizerLoadFailed = 200`). Using the enum directly would be clearer.

### M3. `MWVADOptions` uses `NSInteger` for millisecond fields but `float` for seconds

`minSpeechDurationMs`, `minSilenceDurationMs`, `speechPadMs` are `NSInteger` (milliseconds), while `maxSpeechDurationS` is `float` (seconds). This mixed convention is error-prone. Consider using a consistent unit.

### M4. Memory: `mutableCopy` results not released in word timestamp code (MWTranscriber.mm:1313-1314)

```objc
NSMutableArray<NSMutableDictionary *> *mutableAlignment = [[NSMutableArray alloc] init];
for (NSDictionary *d in alignment) {
    [mutableAlignment addObject:[d mutableCopy]];
}
```
Each `[d mutableCopy]` returns a +1 object that is added to the array (retained again). The release happens at lines 1525-1527:
```objc
for (NSMutableDictionary *d in mutableAlignment) {
    [d release];
}
```
This is correct but fragile -- if an exception occurs between the `mutableCopy` and the release loop, the copies leak. The `@try` block around `findAlignment` catches C++ exceptions but the release loop for mutable dictionaries is outside it.

### M5. `tokenizerCache` ownership in multilingual mode (MWTranscriber.mm:1821-1839)

When `tokenizerCache` is created, the current `loopTokenizer` is added to it. If `createdNewTokenizer` is YES, the initial `loopTokenizer` was alloc'd at line 1704 and has a +1 refcount. Adding it to the cache retains it again (+2). In the `@finally` block (line 2134), the cache is released, dropping all values. But the initial +1 from `alloc` is never released because the `@finally` either releases the cache OR releases `loopTokenizer` (via `createdNewTokenizer`), not both.

When `tokenizerCache` is non-nil, the `createdNewTokenizer` path is skipped (line 2137), so the initial alloc's +1 is released when the cache releases its objects. This appears correct **only if** the initially-created tokenizer was added to the cache. If `multilingualPerSegment` is NO but `createdNewTokenizer` is YES and `tokenizerCache` is somehow non-nil, there could be a leak. In practice the code flow prevents this, but the logic is hard to follow.

### M6. Signal handler in CLI uses `unlink` which is not async-signal-safe on all platforms

`metalwhisper.mm:28`: `unlink(gStdinTempPathBuf)` in a signal handler. While `unlink` is listed as async-signal-safe by POSIX, `_exit` is also called immediately after. The pattern is acceptable but minimal -- no logging or error handling.

### M7. `collectChunks` appends empty NSData if last chunk has 0 samples

In `MWVoiceActivityDetector.mm:483`:
```objc
[audioChunks addObject:[NSData dataWithData:currentAudio]];
```
If `currentAudio` has length 0 (e.g., all chunks were flushed in the loop), an empty NSData is appended. Downstream code should handle this, but the empty chunk creates a zero-length mel which gets zero-padded to 3000 frames of silence.

### M8. Magic number 7 for `medianFilterWidth` (MWTranscriber.mm:1289)

```objc
medianFilterWidth:7];
```
This matches the Python default but should be a named constant.

### M9. `_timePrecision` stored in `MWSpeechTimestampsMap` as `NSUInteger` (MWVoiceActivityDetector.mm:497)

```objc
NSUInteger _timePrecision;
```
Set to `2` at line 509. This represents decimal places for rounding, not the 0.02s time precision constant. The name is confusing given `kMWTimePrecision = 0.02f` exists elsewhere. Rename to `_decimalPlaces` or similar.

---

## LOW (cosmetic)

### L1. `MWTranscriptionOptions.defaults` temperature default differs from Python

`MWTranscriptionOptions.mm:19`: `_temperatures = [@[@0.0, @0.6] retain];`
Python faster-whisper default: `[0.0, 0.2, 0.4, 0.6, 0.8, 1.0]`

The two-temperature default `[0.0, 0.6]` is a deliberate choice for speed, but it differs from the Python reference. Worth documenting.

### L2. Unused `kByteRemapStart` constant (MWTokenizer.mm:36)

```cpp
static const int kByteRemapStart = 256;
```
Used only in `buildBytesToUnicode()` -- the constant is fine but the name could be more descriptive (e.g., `kGPT2RemapOffset`).

### L3. `formatText` adds trailing newline per segment (metalwhisper.mm:116)

This means text output has a trailing newline after the last segment. Minor formatting difference from some tools that omit the trailing newline.

### L4. CLI `--beam-size` validation uses `strtol` but should validate `endptr` for non-numeric trailing characters

As noted in H4 above.

### L5. `kVADEncoderBatchSize = 10000` is a large batch for VAD inference

This processes up to 10000 chunks at once through the ONNX session. For very long audio (hours), this could allocate significant memory for the batched input tensor. Consider a smaller default or making it configurable.

---

## Test Gaps Still Remaining

1. ~~**Async API**~~: Now tested — `test_m10_async_transcribe` in test_m10_api and `e2e_async_api` in test_e2e.

2. **Batched transcription with word timestamps**: The `transcribeBatchedAudio:` path with `wordTimestamps=YES` is tested indirectly via VAD tests but not with explicit token/word validation.

3. ~~**Multilingual per-segment re-detection**~~: Now tested — `test_multilingual_batch` in test_deferred.mm.

4. ~~**`clipTimestamps` option**~~: Now tested — `test_clip_timestamps` in test_deferred.mm.

5. ~~**`hallucinationSilenceThreshold`**~~: Now tested — `test_hallucination_skip` in test_deferred.mm.

6. **`MWModelManager` download path**: Tests only check cached models; no test exercises actual HTTP download, resume, or error paths (would require mocking or network access).

7. ~~**`decodeAudioFromData:` with corrupted/invalid data**~~: Now tested — `test_decode_from_data` and `test_decode_from_buffer` in test_coverage.mm.

8. ~~**Edge case: empty audio transcription**~~: Now tested — `e2e_empty_audio` in test_e2e.

9. ~~**`prefix` option**~~: Now tested — `test_prompt_with_prefix` in test_m4_3_prompt.

10. ~~**Error paths in generate**~~: Now tested — `test_m4_4_error_recovery` in test_deferred.mm.

**Remaining gaps:** #2 (batched + word timestamps explicit validation) and #6 (HTTP download mocking).

---

## Overall Assessment

**Code Quality: Good.** The codebase is well-structured with clear separation of concerns. Each component (audio decoding, feature extraction, tokenization, VAD, transcription) is in its own file with clean interfaces. The manual retain/release memory management is consistently applied with proper cleanup in error paths.

**Python Parity: Excellent.** The transcription output matches the Python faster-whisper reference with 100% text similarity on JFK and 100% text similarity on physicsworks (3+ minutes). Token-level output is identical for the JFK test case. This demonstrates that the CPU-based CTranslate2 backend on macOS produces results fully consistent with the GPU-based Python reference.

**Critical Issues: 2.** Both relate to thread safety -- the `_whisperCPU` lazy init race and the `BluesteinDFT` shared work buffers. These only manifest under concurrent use, which the current test suite and CLI do not exercise. The async API exposes both issues.

**High Issues: 5.** The most impactful is H5 (default parameter inconsistency between the two API surfaces), which could silently produce different transcription results depending on which API a user chooses.

**Architecture:** The project makes good use of RAII via `std::unique_ptr` for the CT2 model, `std::vector` for temporary buffers, and `@try/@finally` for Objective-C resource cleanup. The Bluestein DFT implementation is well-optimized with precomputed chirp sequences and Accelerate vectorization. The VAD integration follows the Python reference closely.

## Fixes Applied (2026-03-20)

| # | Fix | What changed |
|---|-----|-------------|
| C1 | `_whisperCPU` race | `align()` call moved inside `@synchronized(self)`; removed `_whisperCPU.reset()` (freed in dealloc only) |
| C2 | BluesteinDFT buffers | `@synchronized(self)` around `computeMelSpectrogramFromAudio:` |
| H1 | fileReadError | WONTFIX — pattern is correct, added explanatory comment |
| H2 | Async thread safety | Documentation added: one transcription per instance |
| H3 | STFT overflow | `SIZE_MAX` guard before magnitudes allocation |
| H4 | strtol endptr | Validates entire string consumed, rejects "5abc" |
| H5 | Default alignment | NsDictionary defaults now match MWTranscriptionOptions: beam=6, lengthPenalty=0.6, temps=[0.0, 0.6] |

All test suites pass after fixes.
