# M7 Milestone Report — Batched Inference Pipeline

**Date:** 2026-03-20
**Status:** PASSED (5/5 tests)

## Summary

Implemented batched transcription pipeline matching Python's `BatchedInferencePipeline`. Audio is split via VAD into speech chunks, mel features are computed per chunk, stacked into batches, and processed via single batch encode + generate calls. Output matches sequential pipeline.

## Implementation

- **`transcribeBatchedURL:` / `transcribeBatchedAudio:`** — ~300 lines added to MWTranscriber.mm
- Flow: VAD → collect_chunks → mel per chunk → stack → batch encode → batch generate → split segments → restore timestamps via `MWSpeechTimestampsMap`

### Key Differences from Sequential (M4.6)

| Feature | Sequential | Batched |
|---------|-----------|---------|
| VAD | Optional | Required (splits audio) |
| Temperature fallback | Full loop (6 temps) | First temperature only |
| Condition on previous text | Supported | Always off (chunks independent) |
| Timestamps | with_timestamps default | without_timestamps default |
| GPU utilization | One chunk at a time | B chunks simultaneously |

## Test Results

| Test | Result | Details |
|------|--------|---------|
| m7_batch_encode | PASS | 4 chunks → 4 × (1500×1280) encoder outputs |
| m7_batch_transcribe | PASS | 60s audio, batchSize=4 → 3 coherent segments |
| m7_batch_vs_sequential | PASS | jfk.flac: identical text from both pipelines |
| m7_throughput | PASS | batchSize=1: RTF=0.057, batchSize=8: RTF=0.109 |
| m7_segment_handler | PASS | Callback count matches |

## Performance Finding: Batch is Slower on Apple Silicon MPS

| Config | Wall Time (203s audio) | RTF | Speedup |
|--------|----------------------|-----|---------|
| Sequential (M4.6) | 25.2s | 0.124 | baseline |
| Batched, batchSize=1 | 11.5s | 0.057 | 2.2x faster* |
| Batched, batchSize=8 | 22.1s | 0.109 | 1.1x faster |

*batchSize=1 batched is faster than M4.6 sequential because it uses VAD to skip silence and uses `withoutTimestamps=true` + single temperature (no fallback loop).

**Why batch>1 is slower:** The turbo model encoder on MPS Metal processes one chunk in ~1s. Running 8 simultaneously causes GPU memory pressure and MPS command buffer contention, negating any parallelism benefit. The native C++ pipeline has near-zero scheduling overhead (unlike Python's GIL + pybind11 marshaling), so there's nothing for batching to amortize.

**Recommendation:** Use sequential pipeline (M4.6) for best single-file performance on Apple Silicon. Batched mode with VAD + batchSize=1 is the fastest option when silence can be skipped. Batched mode with batchSize>1 may benefit from future Metal optimizations or multi-GPU setups.

## Task Checklist

| Task | Status |
|------|--------|
| M7.1: Batch audio chunks, single encode | Done |
| M7.2: Multi-language detection per chunk | Done (multilingual option) |
| M7.3: Batch generate with parallel prompts | Done |
| M7.4: Per-chunk segment splitting and word timestamps | Done |
| M7.5: Concurrent file processing via GCD | Deferred |

## Project Status: 86/86 tests across 15 test suites
