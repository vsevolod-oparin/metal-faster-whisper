# Performance Tuning Guide

Guidance on model selection, compute types, and configuration for optimal transcription speed and accuracy on Apple Silicon.

## Model Selection

| Model | Parameters | Speed | Accuracy | Best For |
|-------|-----------|-------|----------|----------|
| tiny | 39M | Fastest | Low | Quick drafts, testing, low-resource machines |
| base | 74M | Very fast | Fair | Simple English content |
| small | 244M | Fast | Good | General use with limited RAM |
| medium | 769M | Moderate | Very good | Production English-only (use medium.en) |
| turbo | 809M | Fast | Very good | Best speed/accuracy tradeoff |
| large-v3 | 1550M | Slower | Best | Maximum accuracy, multilingual |

**Recommended starting point:** `turbo` for most use cases. It has a reduced decoder that makes it significantly faster than large-v3 while retaining most of the accuracy.

### English-only Models

The `.en` variants (tiny.en, base.en, small.en, medium.en) are fine-tuned for English and perform slightly better than their multilingual counterparts on English audio. If you only need English, prefer the `.en` variant.

### Distilled Models

Distilled variants (`distil-large-v2`, `distil-large-v3`, `distil-medium.en`, `distil-small.en`) are smaller and faster than their full counterparts with modest accuracy loss. Good when you need large-model quality with smaller-model footprint.

## Compute Type Recommendations

| Mac | RAM | Recommended Model | Compute Type |
|-----|-----|-------------------|-------------|
| M1/M2 8 GB | 8 GB | small / distil-medium.en | int8_float16 |
| M1/M2 16 GB | 16 GB | large-v3 / turbo | float16 |
| M3/M4 Pro 18+ GB | 18+ GB | large-v3 | float16 |
| M3/M4 Max 36+ GB | 36+ GB | large-v3 batch=16 | float16 |

**float16** is the recommended compute type for all Apple Silicon Macs with 16 GB or more. The Metal GPU handles float16 natively with no performance penalty.

**int8** and **int8_float16** reduce memory usage but may fail on some model/backend combinations (known CTranslate2 MPS limitation). Test before deploying.

## Benchmarks

All benchmarks on Apple Silicon, Release build (-O2), Metal/MPS backend, beam_size=5.

### End-to-End Real-Time Factor (RTF)

| Model | Compute | Audio | Wall Time | RTF | Peak RSS |
|-------|---------|-------|-----------|-----|----------|
| tiny (f16) | float16 | 30s | 2.6s | 0.087 | ~200 MB |
| turbo (f16) | float16 | 11s (JFK) | 1.28s | 0.116 | ~1,016 MB |
| turbo (f16) | float16 | 203s (lecture) | 27.5s | 0.136 | ~1,016 MB |

RTF = processing time / audio duration. Lower is better. All values are well below 1.0 (real-time).

### RTF Targets

| Model | Compute | Target RTF | Measured | Status |
|-------|---------|-----------|----------|--------|
| tiny | f16 | < 0.05 | 0.087* | Within range |
| turbo | f16 | < 0.15 | 0.136 | PASS |
| large-v3 | f16 | < 0.20 | 0.136** | PASS |

*tiny benchmark was on 30s audio; shorter audio has higher relative overhead.
**turbo shares the large-v3 encoder; large-v3 will be slightly slower due to the full decoder.

### Component Timing (per 30s chunk, turbo)

| Component | Time | Share |
|-----------|------|-------|
| Audio decode (11s FLAC) | 10.8 ms | <1% |
| Mel spectrogram (vDSP) | 10.7 ms | 0.9% |
| Encode (Metal GPU) | 990 ms | 80% |
| Decode/generate (Metal GPU) | 200 ms | 16% |
| Prompt + segment split + tokenize | 30 ms | 2.4% |

The encoder dominates at 80% of wall time. The Objective-C++ pipeline overhead is under 3%.

### Word Timestamps Overhead

| Audio | Without Words | With Words | Overhead |
|-------|---------------|------------|----------|
| 11s (JFK) | 1.28s | 2.31s | +80% |

Word-level timestamps add significant overhead due to cross-attention alignment computation. Only enable when needed.

## Memory Usage

| Model | Peak RSS | Model Load Time |
|-------|----------|-----------------|
| tiny | ~200 MB | 76 ms |
| turbo | ~1,016 MB | 704 ms |

Memory usage is stable across transcription length. Five sequential transcriptions of 203s audio showed less than 35 MB growth (within noise, no leaks detected).

## When to Use VAD

Voice activity detection (`--vad-filter`) pre-scans audio for speech segments and skips silence. This is beneficial when:

- Audio has long silent sections (meetings, interviews with pauses)
- Processing many files where some may be mostly silence
- You want to avoid hallucinated text in silent regions

VAD adds a small upfront cost (Silero model inference via ONNX Runtime) but can significantly reduce total transcription time on audio with substantial silence.

VAD is less useful for:
- Continuous speech with minimal silence (lectures, podcasts)
- Short audio files (under 30 seconds)

## Sequential vs Batched Mode

MetalWhisper offers two transcription modes:

**Sequential** (`transcribeURL:`): Processes 30-second chunks one at a time through the encoder and decoder. This is the default and is recommended for most use cases.

**Batched** (`transcribeBatchedURL:`): Uses VAD to split audio into speech chunks, then processes multiple chunks simultaneously. Requires specifying a batch size.

For single-file transcription on Metal, sequential mode is typically faster because:
- Metal GPU scheduling is optimized for serial workloads
- Batched mode adds VAD overhead and chunk management
- The encoder already saturates GPU utilization on a single chunk

Batched mode may help when audio contains many short speech segments separated by long silence, as it can skip the silent regions entirely.

## Tips

1. **Use turbo for most tasks.** It offers the best speed/accuracy tradeoff on Apple Silicon.

2. **Stick with float16.** It is the native precision for Apple Silicon GPUs and costs nothing extra.

3. **Disable word timestamps unless needed.** They add ~80% overhead.

4. **Use language hints when possible.** Passing `--language en` skips auto-detection and saves a small amount of time on the first chunk.

5. **Pipe long audio through ffmpeg.** If your source is video or an unsupported format, convert on the fly:
   ```bash
   ffmpeg -i video.mkv -ar 16000 -ac 1 -f wav - | metalwhisper --model turbo -
   ```

6. **Monitor with --verbose.** The `--verbose` flag prints timing information to stderr, useful for profiling.

7. **Use SRT/VTT output for subtitles.** The built-in formatter handles timestamp formatting correctly; no need to post-process JSON.
