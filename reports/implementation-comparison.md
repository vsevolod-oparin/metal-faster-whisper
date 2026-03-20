# MetalWhisper vs faster-whisper: Implementation Comparison

**Date:** 2026-03-20
**Method:** Line-by-line comparison of all 8 subsystems
**Status:** 19 of 22 divergences fixed. 3 LOW remaining (intentional).

---

## Divergence Tracking

### CRITICAL — All Fixed

| # | Subsystem | Issue | Fix |
|---|-----------|-------|-----|
| C1 | No-speech | Logic inverted: native never skipped silent segments when logProbThreshold disabled | Fixed: default-skip, un-skip if logprob high |
| C2 | Batched VAD | Wrong defaults: minSilence=2000→160ms, maxSpeech=∞→30s | Fixed: batched overrides to Python defaults |
| C3 | Main loop | No per-segment multilingual re-detection | Fixed: added `multilingual` option, per-segment detect_language + tokenizer cache |
| C4 | Batched | No per-chunk language detection | Fixed: detect_language per batch, substitute language tokens in prompts |
| C5 | Word timestamps | Missing 100 lines of duration heuristics | Fixed: full port — median/max duration, sentence boundary truncation, post-pause adjustment, segment start/end preference |

### HIGH — All Fixed (1 deferred as performance-only)

| # | Subsystem | Issue | Fix |
|---|-----------|-------|-----|
| H1 | Fallback | Wrong temperature when all fail → bad prompt reset | Fixed: use last temperature tried |
| H2 | Main loop | Encoder output not reused on first segment | **Deferred** — performance only, no output impact |
| H3 | Main loop | Prefix passed to all segments | Fixed: only when seek==0 |
| H4 | Main loop | Empty/zero-duration segments not filtered | Fixed: skip if start==end or text empty |
| H5 | Main loop | Seek not adjusted from word timestamps | Fixed: adjust seek to last word end |
| H6 | Main loop | Language detection ignores user segments/threshold params | Fixed: reads from MWTranscriptionOptions |
| H7 | Generate | max_new_tokens not implemented | Fixed: added maxNewTokens parameter |
| H8 | Batched | max_initial_timestamp defaults to 1.0 instead of 0.0 | Fixed: forced to 0.0 in batched |
| H9 | Batched | Feature last-frame not dropped | Fixed: drop last frame before padding |
| H10 | Batched | Per-chunk language detection missing | Fixed: detect_language on encoder output, substitute in prompts |
| H11 | Batched | initial_prompt not supported | Fixed: encode and pass as previousTokens |
| H12 | Word timestamps | last_speech_timestamp not carried across iterations | Fixed: declared before loop, passed/returned |
| H13 | Main loop | allTokens includes all generate tokens | Fixed: only adds yielded sub-segment tokens |

### LOW — Remaining (intentional differences)

| # | Subsystem | Issue | Reason kept |
|---|-----------|-------|-------------|
| 19 | Clip timestamps | String format ("0,5.2") not supported — only NSArray | Native API uses typed arrays, not strings |
| 20 | Suppressed tokens | Config.json suppress_ids merged as superset | Extra safety — suppresses more, never less |
| 21 | Hallucination | Anomaly detection uses letterCharacterSet | Slightly broader filter than Python's punctuation set |

---

## Match Summary (correctly ported, no issues)

- Prompt construction (get_prompt) — exact match
- Segment splitting (_split_segments_by_timestamps) — exact match
- Temperature fallback loop structure — exact match
- avg_logprob computation — exact match
- VAD state machine (get_speech_timestamps) — exact match
- VAD padding/merging — exact match
- Punctuation merging (merge_punctuations) — exact match
- DTW alignment core (find_alignment) — exact match
- Suppressed tokens core logic — match (with minor superset)
- No-speech detection — now matches Python
- Per-segment multilingual — now matches Python
- Batched inference — now matches Python

---

## E2E Testing Plan

### Test Audio Dataset

| # | Audio | Duration | Language | Purpose |
|---|-------|----------|----------|---------|
| 1 | jfk.flac | 11s | English | Short, clean speech — baseline |
| 2 | physicsworks.wav | 203s | English | Multi-segment, long-form |
| 3 | hotwords.mp3 | 4s | English | Short, lossy format |
| 4 | stereo_diarization.wav | 5s | English | Stereo → mono |
| 5 | Russian audio (TBD) | 30-60s | Russian | Multilingual detection |
| 6 | Silence + speech (TBD) | 30s | English | No-speech detection |
| 7 | Music-only (TBD) | 15s | None | no_speech_prob behavior |

### Test Protocol

For each audio file, run both implementations with identical parameters and compare:
- **Token IDs**: identical for greedy (temp=0, beam=5)?
- **Text**: identical after decoding?
- **Segment timestamps**: within ±20ms?
- **Word timestamps**: within ±50ms?

### Known Expected Differences

Even with all divergences fixed, some differences are expected due to:
1. **GPU vs CPU execution**: MPS Metal vs CPU produces slightly different floating-point results
2. **Different CT2 builds**: Our custom Metal-enabled CT2 vs Python's standard CPU build
3. **Feature extraction precision**: Our Bluestein FFT vs Python's NumPy FFT — matched within 1.9e-5 but not bit-identical
