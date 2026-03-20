# Swift CLI Example

Minimal Whisper transcription in pure Swift — no Xcode project needed.

## Build the framework first

```bash
cd /path/to/metal-faster-whisper
./scripts/build_framework.sh
```

## Build this example

```bash
cd examples/swift-cli
swiftc -F ../../build -framework MetalWhisper \
  -Xlinker -rpath -Xlinker ../../build \
  -Xlinker -rpath -Xlinker ../../third_party/ctranslate2-mps/lib \
  -Xlinker -rpath -Xlinker ../../third_party/onnxruntime-osx-arm64-1.21.0/lib \
  transcribe.swift -o transcribe
```

## Usage

```bash
# Basic transcription (auto-downloads model on first use)
./transcribe --model turbo recording.wav

# Word-level timestamps
./transcribe --model turbo lecture.mp3 --words

# Specific language
./transcribe --model turbo interview.wav --language ru

# Translate to English
./transcribe --model turbo foreign_speech.mp3 --task translate

# Multiple files
./transcribe --model turbo file1.wav file2.mp3 file3.flac
```

## Output

```
[en 95%] jfk.flac (11.0s)
[00:00.00 → 00:10.34]  And so, my fellow Americans, ask not what your country can do for you...
```

With `--words`:
```
[00:00.00 → 00:10.34]  And so, my fellow Americans, ask not...
  00:00.00  79%  And
  00:00.52 100%  so,
  00:01.10 100%  my
  00:01.20 100%  fellow
  00:01.54  98%  Americans,
```

## How it works

The key line is:

```swift
import MetalWhisper
```

This works because `build_framework.sh` creates a proper `MetalWhisper.framework` with headers, module map, and dylib — the standard macOS framework format that Swift understands natively.
