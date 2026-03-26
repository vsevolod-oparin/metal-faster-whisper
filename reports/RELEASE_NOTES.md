# MetalWhisper v0.1.0 Release Notes

**2026-03-26** — Initial release.

MetalWhisper is a native macOS port of [faster-whisper](https://github.com/SYSTRAN/faster-whisper) built on CTranslate2's Metal/MPS backend. It replaces the Python runtime with a single compiled Objective-C++ framework and CLI tool. No Python, no Conda, no FFmpeg required.

---

## Highlights

- **2–2.6x faster** than mlx-whisper and whisper.cpp on Apple Silicon (RTF 0.087–0.136 with turbo)
- **Zero runtime dependencies** — one binary, ships with all required dylibs
- **Full API parity** with Python faster-whisper — 100% token match on reference audio, 0.3% WER on LibriSpeech test-clean
- **SPM binary distribution** — add as Swift Package dependency in one line

---

## Performance

Benchmarks on Apple Silicon, Release build, float16, Metal/MPS backend.

| Model | Audio | Wall Time | RTF | Peak RAM |
|-------|-------|-----------|-----|---------|
| turbo (f16) | 11 s (JFK) | 1.28 s | 0.116 | ~1.0 GB |
| turbo (f16) | 203 s (lecture) | 27.5 s | 0.136 | ~1.0 GB |
| tiny (f16) | 30 s | 2.6 s | 0.087 | ~200 MB |

### vs. Alternatives (whisper-large-v3-turbo, FLEURS)

| Implementation | RTF | vs MetalWhisper |
|----------------|-----|-----------------|
| **MetalWhisper** | **0.121** | baseline |
| mlx-whisper f16 | 0.217 | 1.8× slower |
| whisper.cpp F16 | 0.295 | 2.4× slower |
| OpenAI whisper f32 (CPU) | 0.309 | 2.6× slower |

---

## Features

### CLI Tool

```bash
# Transcribe (model auto-downloads on first use)
metalwhisper audio.mp3 --model turbo

# Subtitles with word-level timestamps
metalwhisper lecture.mp3 --model turbo --output-format srt --word-timestamps

# Pipe from ffmpeg
ffmpeg -i video.mkv -ar 16000 -ac 1 -f wav - | metalwhisper --model large-v3 -

# Batch a directory
metalwhisper *.mp3 --model turbo --output-dir ./subtitles

# JSON output
metalwhisper audio.wav --model turbo --word-timestamps --json | jq '.segments[].text'
```

### Framework API (Objective-C + Swift)

```swift
import MetalWhisper

let transcriber = try MWTranscriber(modelPath: modelPath)
let options = MWTranscriptionOptions()
options.language = nil          // auto-detect
options.vadFilter = true
options.wordTimestamps = true

let segments = try transcriber.transcribeURL(
    url, language: nil, task: "transcribe",
    typedOptions: options,
    segmentHandler: { segment, _ in
        print(segment.text)
    },
    info: &info
)
```

### What's included

- **18 model aliases** from tiny (74 MB) to large-v3 (3.1 GB), including turbo
- **Output formats:** plain text, SRT, VTT, JSON
- **Voice activity detection** — Silero VAD v6 via ONNX Runtime (bundled)
- **Word-level timestamps** via DTW alignment — 100% timing match vs Python reference
- **Language auto-detection** with per-segment multilingual re-detection
- **Translation** to English (transcribe or translate task)
- **Temperature fallback loop** — greedy first, sampling fallback on difficult audio
- **Streaming segment callback** — segments yielded as they complete, not buffered
- **Async API** with completion handler (fires on main queue)
- **Audio formats:** WAV, MP3, FLAC, M4A, CAF, stdin pipe
- **Model manager** — auto-download, cache, list, verify

---

## Accuracy

Validated against Python faster-whisper output:

| Test | Result |
|------|--------|
| JFK 11s — token match | 100% (27/27 tokens) |
| LibriSpeech test-clean WER | 0.3% (10 utterances) |
| Word timestamp accuracy | 0 ms max diff vs Python reference |
| VAD output | Bit-exact match (max diff 0.0) |
| 203s lecture text similarity | 97.4% |

---

## Supported Compute Types

| Type | MPS Support |
|------|-------------|
| float32 | ✅ |
| float16 | ✅ (default) |
| int8 | ❌ (loads, fails at encode — MPS limitation) |

---

## Installation

### Swift Package Manager

```swift
// Package.swift
.package(url: "https://github.com/vsevolod-oparin/metal-faster-whisper", from: "0.1.0")
```

Then add `"MetalWhisper"` to your target's dependencies. The package includes three binary targets: `MetalWhisper`, `CTranslate2`, `OnnxRuntime`. All three are required — the product dependency `"MetalWhisper"` pulls them all in.

The Silero VAD model (`silero_vad_v6.onnx`, 2.3 MB) is bundled inside `MetalWhisper.xcframework` and resolved automatically at runtime via `[NSBundle bundleForClass:[MWTranscriber class]]`. No separate setup step required.

### CLI (from release tarball)

Download `metalwhisper-0.1.0-macos-arm64.tar.gz`, extract, and run:

```bash
./bin/metalwhisper audio.mp3 --model turbo
```

### Build from source

```bash
./scripts/setup_dependencies.sh    # downloads CT2, ORT, VAD model
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(sysctl -n hw.logicalcpu)
```

---

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon (M1 / M2 / M3 / M4)

---

## Known Limitations

**No int8 inference on Metal.** CTranslate2's MPS backend doesn't support int8 Whisper inference. float16 is the recommended default and provides excellent speed with minimal accuracy loss.

**Turbo model doesn't translate.** The `turbo` / `large-v3-turbo` model appears to have translation weights removed. Use `large-v3` if you need English translation from another language.

**Batched inference is slower than sequential.** GPU memory contention on MPS makes batch mode ~1.9× slower than sequential for multi-file workloads. Sequential is the recommended and default mode.

**No real-time streaming yet.** Live microphone transcription (low-latency chunk processing) is planned for v0.2.

---

## Release Assets

| File | Size | Description |
|------|------|-------------|
| `MetalWhisper.xcframework.zip` | 1.3 MB | Framework + headers + VAD model |
| `CTranslate2.xcframework.zip` | 1.1 MB | CTranslate2 Metal/MPS dylib |
| `OnnxRuntime.xcframework.zip` | 8.7 MB | ONNX Runtime dylib |

---

## Roadmap

| Version | Focus |
|---------|-------|
| v0.2 | Real-time streaming transcription (live microphone input, M13) |
| v0.3 | Speaker diarization (M14) |
| v0.4 | OpenAI-compatible API server (M15) |

---

## Acknowledgements

Built on [CTranslate2](https://github.com/OpenNMT/CTranslate2) (OpenNMT) and [Silero VAD](https://github.com/snakers4/silero-vad). Validated against [faster-whisper](https://github.com/SYSTRAN/faster-whisper) for Python parity.
