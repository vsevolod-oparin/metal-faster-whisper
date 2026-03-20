# MetalWhisper vs faster-whisper: Implementation Comparison

**Date:** 2026-03-20
**Method:** Line-by-line comparison of all 8 subsystems

## Summary: 5 CRITICAL, 13 HIGH, 4 LOW divergences

---

## CRITICAL Divergences (will produce different outputs)

### C1. No-speech detection logic is inverted

**Python (correct):**
```python
should_skip = no_speech_prob > no_speech_threshold  # default: skip silent
if log_prob_threshold is not None and avg_logprob > log_prob_threshold:
    should_skip = False  # un-skip if logprob is high
```

**Native (wrong):**
```objc
if (noSpeechProb > noSpeechThreshold) {
    if (!isnan(logProbThreshold) && avgLogProb < logProbThreshold) {
        shouldSkip = YES;  // only skip if BOTH conditions
    }
}
```

**Impact:** With `logProbThreshold=NaN` (disabled), Python skips all high-no-speech segments. Native never skips. Silent chunks produce garbage text.

### C2. Batched VAD defaults are wrong

| Parameter | Python (batched) | Native (batched) |
|-----------|-----------------|-----------------|
| minSilenceDurationMs | 160 | 2000 |
| maxSpeechDurationS | chunk_length (30) | INFINITY |

**Impact:** Native produces arbitrarily long segments instead of 30s chunks. Short silences don't trigger splits. Radically different segmentation.

### C3. Missing per-segment multilingual language re-detection

Python re-detects language for EACH 30s chunk when `multilingual=True`, updating the tokenizer. Native detects once and never updates.

**Impact:** For multilingual audio, language switches aren't tracked. Already caused the Russian→English bug.

### C4. Missing batched per-chunk language detection

Python's batched pipeline detects language per chunk and substitutes the language token in each batch prompt. Native uses a single fixed prompt for all chunks.

### C5. Missing word timestamp duration clamping heuristics

Python has ~100 lines of word duration capping: median/max duration, sentence boundary truncation, first-word-after-pause adjustment, segment start/end preference. Native has none of this — just basic clamp to segment bounds.

**Impact:** Word timestamps may have implausibly long words at sentence boundaries and pauses.

---

## HIGH Divergences (13)

| # | Subsystem | Issue |
|---|-----------|-------|
| 1 | Fallback | When all temps fail, Python uses last temperature (forces prompt reset); native uses best result's actual temperature |
| 2 | Main loop | Encoder output not reused from language detection on first segment (wastes one encode pass) |
| 3 | Main loop | Prefix passed to ALL segments instead of only first (seek==0) |
| 4 | Main loop | Empty/zero-duration segments not filtered out |
| 5 | Main loop | Seek not adjusted based on word timestamp end position |
| 6 | Main loop | Language detection ignores user-provided segments/threshold params (hardcodes 1/0.5) |
| 7 | Generate | `max_new_tokens` option not implemented |
| 8 | Batched | `max_initial_timestamp` defaults to 1.0 instead of Python's 0.0 |
| 9 | Batched | Feature last-frame not dropped (`[..., :-1]` missing) |
| 10 | Batched | Timestamp restoration doesn't use middle-point chunk index |
| 11 | Batched | `initial_prompt` not supported in batched path |
| 12 | Word timestamps | `last_speech_timestamp` not carried across loop iterations |
| 13 | Main loop | allTokens includes ALL generate tokens (including unfinished segments), Python only adds yielded sub-segment tokens |

---

## MATCH (correctly ported)

- Prompt construction (get_prompt)
- Segment splitting (_split_segments_by_timestamps)
- Temperature fallback loop structure
- avg_logprob computation
- VAD state machine (get_speech_timestamps)
- VAD padding/merging
- Punctuation merging
- DTW alignment core
- Suppressed tokens (with minor superset divergence)

---

## E2E Testing Plan

### Test Audio Dataset

To properly compare, we need audio covering:

| # | Audio | Duration | Language | Purpose |
|---|-------|----------|----------|---------|
| 1 | jfk.flac | 11s | English | Short, clean speech — baseline |
| 2 | physicsworks.wav | 203s | English | Multi-segment, long-form |
| 3 | hotwords.mp3 | 4s | English | Short, lossy format |
| 4 | stereo_diarization.wav | 5s | English | Stereo → mono |
| 5 | Russian audio | 30-60s | Russian | Multilingual detection |
| 6 | Silence + speech | 30s | English | No-speech detection |
| 7 | Music-only | 15s | None | no_speech_prob behavior |

Items 5-7 need to be sourced or generated.

### Test Protocol

For each audio file, run:

1. **Python faster-whisper** (CPU mode, same model) with explicit parameters
2. **MetalWhisper** (MPS mode, same model) with matching parameters

Compare:
- **Token-level**: Are the decoded token IDs identical for greedy (temp=0, beam=5)?
- **Text-level**: Is the text identical after decoding?
- **Timestamp-level**: Are segment start/end within tolerance (±20ms)?
- **Word timestamp-level**: Are word boundaries within tolerance (±50ms)?

### Priority Fix Order Before E2E Testing

1. **C1: Fix no-speech detection logic** — match Python's default-skip behavior
2. **C2: Fix batched VAD defaults** — 160ms silence, 30s max duration
3. **C3: Add per-segment multilingual re-detection** — `multilingual` option
4. **H3: Prefix only for first segment** — `seek == 0` check
5. **H4: Filter empty/zero-duration segments** — skip empty text
6. **H5: Seek adjustment from word timestamps** — match Python
7. **H1: Temperature selection when all fail** — use last temperature

These 7 fixes address the most impactful divergences and should bring the output significantly closer to Python's behavior.
