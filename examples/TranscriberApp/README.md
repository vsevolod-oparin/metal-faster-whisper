# TranscriberApp

A SwiftUI macOS demo application for MetalWhisper — native Whisper transcription on Apple Silicon via Metal.

## Quick Setup (xcodegen)

```bash
cd examples/TranscriberApp
xcodegen generate
xcodebuild -scheme TranscriberApp -configuration Debug build
```

The `project.yml` is pre-configured with all header/library search paths.

## Manual Xcode Setup

### Prerequisites

- macOS 14.0+ (Sonoma or later)
- Xcode 15.0+
- MetalWhisper built (`./scripts/setup_dependencies.sh && cd build && cmake .. && make`)

### Steps

1. Open Xcode → File → New → Project → macOS → App (SwiftUI)
2. Add the `.swift` files and `MetalWhisper-Bridging-Header.h` to the project
3. Build Settings:
   - **Objective-C Bridging Header**: `MetalWhisper-Bridging-Header.h`
   - **Header Search Paths**: `$(SRCROOT)/../../src`
   - **Library Search Paths**: `$(SRCROOT)/../../build`, `$(SRCROOT)/../../third_party/ctranslate2-mps/lib`, `$(SRCROOT)/../../third_party/onnxruntime-osx-arm64-1.21.0/lib`
   - **Other Linker Flags**: `-lMetalWhisper -lctranslate2 -lonnxruntime`
   - **Runpath Search Paths**: `@executable_path/../Frameworks` plus the library paths above
4. Build and run

## Using MetalWhisper from Pure Swift (no Xcode project)

You don't need Xcode or a bridging header. Just `swiftc`:

```swift
// my_transcriber.swift
import Foundation

let transcriber = try MWTranscriber(modelPath: "/path/to/model")
let opts = MWTranscriptionOptions.defaults()
opts.wordTimestamps = true

let url = URL(fileURLWithPath: "audio.mp3")
var info: MWTranscriptionInfo?
let segments = try transcriber.transcribeURL(
    url, language: nil, task: "transcribe",
    typedOptions: opts, segmentHandler: nil, info: &info)

for seg in segments {
    print("[\(String(format: "%.2f", seg.start))-\(String(format: "%.2f", seg.end))] \(seg.text)")
}
```

Compile:
```bash
swiftc -import-objc-header path/to/src/MetalWhisper.h \
  -I path/to/src -L path/to/build -lMetalWhisper \
  my_transcriber.swift -o my_transcriber
```

## Features

- **Model selection** — dropdown with all Whisper model sizes (auto-downloaded)
- **Language picker** — 30 languages + auto-detect
- **Task selection** — Transcribe (keep original language) or Translate to English
- **Drag & drop** — drop audio files onto the window
- **Streaming output** — segments appear as they're transcribed
- **Word timestamps** — colored badges show per-word timing and confidence
- **VAD filter** — skip non-speech regions
- **Export** — save as TXT, SRT, or VTT via native save dialog

## Supported Audio Formats

WAV, MP3, M4A, FLAC, AAC, AIFF, CAF — any format supported by AVFoundation.
