# M8 Milestone Report — CLI Tool (`metalwhisper`)

**Date:** 2026-03-20
**Status:** PASSED (7/7 tests)

## Summary

Shipped the `metalwhisper` command-line tool — a native macOS binary that replaces the Python `faster-whisper` CLI workflow entirely. Supports text, SRT, VTT, and JSON output formats, word-level timestamps, VAD filtering, and all transcription options.

## Usage Examples

```bash
# Basic transcription
metalwhisper meeting.m4a --model /path/to/whisper-large-v3-turbo

# Subtitle generation
metalwhisper podcast.mp3 --model turbo --output-format srt > podcast.srt

# Word-level timestamps as JSON
metalwhisper lecture.mp3 --model turbo --word-timestamps --json | jq '.segments[].words'

# With VAD filtering
metalwhisper long_meeting.wav --model turbo --vad-filter --vad-model models/silero_vad_v6.onnx

# Pipe from ffmpeg
ffmpeg -i video.mkv -ar 16000 -ac 1 -f wav - | metalwhisper --model turbo -
```

## Output Formats

| Format | Flag | Description |
|--------|------|-------------|
| Text | `--output-format text` (default) | Plain text, one segment per line |
| SRT | `--output-format srt` | SubRip subtitle format (HH:MM:SS,mmm) |
| VTT | `--output-format vtt` | WebVTT subtitle format (HH:MM:SS.mmm) |
| JSON | `--json` or `--output-format json` | Structured JSON with segments, timing, metadata |

Word-level SRT/VTT: With `--word-timestamps`, each word becomes its own subtitle cue.

## CLI Options

| Option | Default | Description |
|--------|---------|-------------|
| `--model` | (required) | Model directory path |
| `--language` | auto-detect | Language code (en, fr, zh, etc.) |
| `--task` | transcribe | transcribe or translate |
| `--output-format` | text | text, srt, vtt, json |
| `--output-dir` | stdout | Write files to directory |
| `--compute-type` | auto | auto, float32, float16 |
| `--beam-size` | 5 | Beam search width |
| `--word-timestamps` | off | Enable word-level timing |
| `--vad-filter` | off | Voice activity detection |
| `--vad-model` | — | Path to Silero VAD ONNX model |
| `--initial-prompt` | — | Initial prompt text |
| `--hotwords` | — | Bias words |
| `--temperature` | 0.0,...,1.0 | Fallback temperatures |
| `--verbose` | off | Progress on stderr |
| `-` | — | Read stdin (WAV) |

## Test Results

| Test | Result | Verification |
|------|--------|-------------|
| test_m8_help | PASS | Usage text, exit 0 |
| test_m8_basic | PASS | JFK → "country" in output, exit 0 |
| test_m8_srt | PASS | Valid SRT with "1\n00:00:" and "-->" |
| test_m8_vtt | PASS | Starts with "WEBVTT" |
| test_m8_json | PASS | Parseable JSON with "segments" key |
| test_m8_exit_codes | PASS | Nonexistent file → exit 1 + stderr error |
| test_m8_word_srt | PASS | >10 SRT entries for word-level JFK |

## Implementation

- **`cli/metalwhisper.mm`** — single file, ~500 lines
- Argument parsing via argv loop (no external dependency)
- Subtitle formatting (SRT, VTT, JSON) inline
- Stdin pipe support via temp file
- CMake target `mw_cli` with `OUTPUT_NAME metalwhisper` (avoids APFS case collision with `MetalWhisper` library)

## The MVP is Complete

Per the ROADMAP:
> **Minimum viable product:** M0 + M1 + M2 + M3 + M4 + M8 (CLI) = a working `metalwhisper` command on macOS.

We have all of these plus M5 (word timestamps), M6 (VAD), and M7 (batched inference).

## Project Status: 105 tests across 18 test suites

| Milestone | Tests |
|-----------|-------|
| M0 — Project Setup | 5 |
| M1 — Audio Decoding | 7 |
| M2 — Mel Spectrogram | 7 |
| M3 — BPE Tokenizer | 9 |
| M4 — Core Transcription | 35 |
| M5 — Word Timestamps | 4 |
| M6 — Voice Activity Detection | 6 |
| M7 — Batched Inference | 5 |
| M8 — CLI Tool | 7 |
| Edge Cases | 7 + 12 |
| Benchmark | 1 |
| **Total** | **105** |
