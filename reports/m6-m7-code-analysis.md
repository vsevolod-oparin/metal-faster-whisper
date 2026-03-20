# M6/M7 Code Analysis Report

**Date:** 2026-03-20
**Scope:** MWVoiceActivityDetector.mm, MWTranscriber.mm (batched methods), M6/M7 tests
**Reviews conducted:** Code quality + Security (2 parallel agents)

---

## Summary

| Category | CRITICAL | HIGH | MEDIUM | LOW |
|----------|----------|------|--------|-----|
| Code Quality | 1 | 4 | 5 | 4 |
| Security | — | 3 | 4 | 3 |

After deduplication: **1 CRITICAL, 5 unique HIGH, 6 unique MEDIUM** findings.

---

## CRITICAL

### 1. `tokenIDsArr` leak on exception paths in batched transcription

**File:** MWTranscriber.mm:2191-2356

`tokenIDsArr` is allocated inside the per-chunk loop. If an ObjC exception occurs between allocation and the release at line 2356, it leaks. The `@try/@finally` only covers outer resources.

**Fix:** Wrap inner per-chunk processing in its own `@try/@finally`, or autorelease `tokenIDsArr` at creation.

---

## HIGH (fix before M8)

### 2. Incorrect state machine condition in `speechTimestamps:`

**File:** MWVoiceActivityDetector.mm:328

```objc
if (nextStart < prevEnd + curSample) {  // WRONG
```

Python reference: `if next_start < prev_end`. Adding `curSample` makes the condition always true, so the max-speech-duration splitting always creates a new segment instead of sometimes disabling the trigger.

**Fix:** Change to `if (nextStart < prevEnd)`.

### 3. `collectChunks:` increments duration for skipped chunks

**File:** MWVoiceActivityDetector.mm:466

`currentDuration += chunkSamples` runs even when the chunk's audio is not appended (bounds check failure). This desyncs duration tracking.

**Fix:** Move the increment inside the `if` block.

### 4. `chunkIndexForTime:` unsigned underflow on empty chunks

**File:** MWVoiceActivityDetector.mm:545

`_chunkEndSample.size() - 1` wraps to SIZE_MAX when empty. Works by accident via downstream guard but is fragile.

**Fix:** Add `if (_chunkEndSample.empty()) return 0;` at top.

### 5. Mel chunk `memcpy` without length validation in batch stacking

**File:** MWTranscriber.mm:2098-2099

`memcpy` trusts `chunkElements` without checking `[melData length]`. Undersized mel chunk → heap buffer over-read.

**Fix:** Validate `[melData length] >= expectedBytes` before copying.

### 6. Silent batch failure — all batches fail returns empty with no error

**File:** MWTranscriber.mm:2121-2156

When encode/generate throws, the code `continue`s. If ALL batches fail, returns empty array indistinguishable from "no speech."

**Fix:** Track success count. If zero successes on non-empty input, set error.

---

## MEDIUM

1. **`MWSpeechTimestampsMap` negative silence** — overlapping VAD segments (after padding) make `start - previousEnd` negative, breaking monotonicity. Fix: `MAX(0, start - previousEnd)` (MWVoiceActivityDetector.mm:504)

2. **`collectChunks:` returns `@[[NSData data]]` for empty input** — empty NSData masquerades as valid chunk, confuses downstream. Fix: return `@[]` (MWVoiceActivityDetector.mm:441)

3. **`maxSpeechSamples` can go negative** — small `maxSpeechDurationS` values. Fix: `fmaxf(0.0f, ...)` (MWVoiceActivityDetector.mm:265)

4. **LSTM batch state may read wrong offset** — if Silero model returns h/c with batch dimension, `memcpy` copies first element not last. Fix: verify output shape at runtime (MWVoiceActivityDetector.mm:229-232)

5. **O(N^2) filtered time offset** — recomputed from start for each chunk. Fix: precompute cumulative array (MWTranscriber.mm:2205-2209)

6. **`samplingRate=0` division by zero** in `MWSpeechTimestampsMap`. Fix: validate at init (MWVoiceActivityDetector.mm:508)

---

## LOW

1. Redundant property assignments in `MWVADOptions +defaults`
2. Missing `@autoreleasepool` in batched inner loop
3. Test resource leaks on early ASSERT_TRUE returns
4. Static globals in MWTestCommon.h fragile if multi-TU

---

## Test Coverage Gaps

1. Empty/nil audio to VAD speechProbabilities/speechTimestamps
2. `maxSpeechDurationS` splitting behavior (most complex VAD logic, untested)
3. Error propagation when VAD model path is invalid
4. `MWSpeechTimestampsMap` with overlapping segments
5. `collectChunks:` with out-of-bounds segments

---

---

## Fix Results (2026-03-20)

All findings fixed. 86/86 tests pass.

### Fixes Applied (10 of 11)

| # | Fix | Severity |
|---|-----|----------|
| 1 | `tokenIDsArr` uses autorelease — leak-proof on all paths | CRITICAL |
| 2 | **Skipped** — `nextStart < prevEnd + curSample` matches Python exactly (line 137). Code review was wrong. | HIGH (false positive) |
| 3 | `collectChunks:` duration increment moved inside bounds-check `if` | HIGH |
| 4 | `chunkIndexForTime:` empty vector guard added | HIGH |
| 5 | Mel chunk `memcpy` validates `[melData length]` before copying | HIGH |
| 6 | `anyBatchSucceeded` tracking — sets error if all batches fail | HIGH |
| 7 | Negative silence clamped to 0 in `MWSpeechTimestampsMap` | MEDIUM |
| 8 | `collectChunks:` returns `@[]` for empty input (not `@[[NSData data]]`) | MEDIUM |
| 9 | `maxSpeechSamples` clamped to ≥ 0 | MEDIUM |
| 10 | O(N^2) offset → precomputed cumulative array | MEDIUM |
| 11 | `samplingRate=0` guarded in `MWSpeechTimestampsMap` | MEDIUM |

### Important: Fix 2 was a false positive

The code review flagged `nextStart < prevEnd + curSample` as incorrect, claiming Python uses `nextStart < prevEnd`. Checking the actual Python source (vad.py line 137): `if next_start < prev_end + cur_sample` — the original code was correct. The reviewer misread the Python reference.

---

## Recommended Fix Order

**Phase 1 — Safety:**
1. Fix state machine condition `nextStart < prevEnd` (#2)
2. Fix `collectChunks:` duration tracking (#3)
3. Guard `chunkIndexForTime:` empty vector (#4)
4. Validate mel chunk length before memcpy (#5)
5. Track batch success, set error if all fail (#6)
6. Fix `tokenIDsArr` leak (#1)
7. Clamp negative silence in timestamp map (#MEDIUM-1)
8. Fix empty chunks return (#MEDIUM-2)
9. Clamp `maxSpeechSamples` (#MEDIUM-3)

**Phase 2 — Quality:**
10. Precompute cumulative time offsets (#MEDIUM-5)
11. Validate `samplingRate` in timestamp map init (#MEDIUM-6)
