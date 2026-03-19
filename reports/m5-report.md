# M5 Milestone Report — Word-Level Timestamps

**Date:** 2026-03-19
**Status:** PASSED (4/4 tests)

## Summary

Added word-level timestamp extraction via CTranslate2's cross-attention alignment API. Each transcription segment can now include per-word timing and probability data, enabling word-level SRT/VTT subtitle export.

## Implementation

### Components added to MWTranscriber.mm:

1. **`MWWord`** — result class: word text, start time, end time, probability
2. **`findAlignmentWithTokenizer:`** — calls CT2 `align()`, parses DTW alignment results (text_indices, time_indices), splits tokens to words via tokenizer, computes word boundaries using cumulative token counts, derives start/end times from jump detection in the alignment path, computes per-word probability as mean of constituent token probabilities
3. **`addWordTimestampsToSegments:`** — orchestrates: collect text tokens per segment → find alignment → compute median/max word duration → truncate long words at sentence boundaries → merge punctuations → apply boundary heuristics (first word after pause, segment start/end preference) → clamp to segment bounds
4. **`mergePunctuations()`** — merges prepend punctuations right-to-left (e.g., opening quotes attach to next word) and append punctuations left-to-right (e.g., periods attach to previous word)
5. **`wordAnomalyScore()` / `isSegmentAnomaly()`** — hallucination detection scoring
6. **Decode loop integration** — `wordTimestamps`, `hallucinationSilenceThreshold`, `prependPunctuations`, `appendPunctuations` options parsed and applied

### Key Design Decision: CPU Pool for Alignment

The MPS Metal backend throws `"LayerNorm: only normalization over a memory-contiguous axis is supported"` when running the decoder in non-iterative mode (as `align()` requires). Solution: a lazily-initialized CPU-only `Whisper` pool (`_whisperCPU`) dedicated to alignment. The encoder output from MPS is passed directly — CT2's `maybe_encode()` detects pre-encoded features via `is_encoded()` and skips re-encoding.

This is transparent to the caller and adds negligible overhead since alignment is much faster than generation.

## Word Timing Algorithm

```
CT2 align() → DTW alignment path: [(text_idx, time_idx), ...]
  → Extract jumps: positions where text_idx advances
  → Map jump times to word boundaries via cumulative token counts
  → start_times = jump_times[word_boundaries[:-1]]
  → end_times = jump_times[word_boundaries[1:]]
  → probability = mean(text_token_probs[boundary_start:boundary_end])
```

## Test Results

| Test | Result | Details |
|------|--------|---------|
| m5_merge_punctuations | PASS | Prepend and append merge patterns correct |
| m5_anomaly_score | PASS | All 4 score cases match formula |
| m5_word_timestamps | PASS | jfk.flac → 22 words, prob 0.79-1.00, monotonic |
| m5_word_timestamps_long | PASS | 30s physics → 82 words across 9 segments |

### JFK Word Alignment Sample

```
[0.00 -> 0.52] p=0.79  And
[0.52 -> 0.86] p=1.00  so,
[1.10 -> 1.20] p=1.00  my
[1.20 -> 1.54] p=1.00  fellow
[1.54 -> 2.12] p=0.98  Americans,
[3.32 -> 3.78] p=0.99  ask
[3.78 -> 4.34] p=0.98  not
[4.34 -> 5.56] p=0.99  what
[5.56 -> 5.80] p=1.00  your
[5.80 -> 6.24] p=1.00  country
[6.24 -> 6.62] p=1.00  can
[6.62 -> 6.82] p=1.00  do
[6.82 -> 7.06] p=1.00  for
[7.06 -> 7.40] p=1.00  you,
[7.78 -> 8.52] p=1.00  ask
[8.52 -> 8.80] p=1.00  what
[8.80 -> 9.04] p=1.00  you
[9.04 -> 9.34] p=1.00  can
[9.34 -> 9.56] p=1.00  do
[9.56 -> 9.78] p=1.00  for
[9.78 -> 9.96] p=1.00  your
[9.96 -> 10.34] p=1.00  country
```

## Task Checklist

| Task | Status |
|------|--------|
| M5.1: findAlignment via CT2 align() + DTW | Done |
| M5.2: splitToWordTokens (reuses tokenizer) | Done |
| M5.3: addWordTimestamps with median/max duration | Done |
| M5.4: mergePunctuations prepend/append | Done |
| M5.5: Word anomaly scoring + hallucination threshold | Done |

## Project Status: 68/68 tests pass across M0-M5
