#!/bin/bash
# Build a release tarball for MetalWhisper
# Run from project root: ./scripts/build_release.sh
#
# Output: build/metalwhisper-{VERSION}-macos-arm64.tar.gz

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
VERSION="0.1.0"
RELEASE_NAME="metalwhisper-${VERSION}-macos-arm64"
STAGING="$BUILD_DIR/$RELEASE_NAME"

echo "=== Building MetalWhisper Release $VERSION ==="

# ── Step 1: Ensure dependencies are set up ──────────────────────────────────

if [ ! -f "$PROJECT_DIR/third_party/ctranslate2-mps/lib/libctranslate2.dylib" ]; then
    echo "Running dependency setup..."
    "$PROJECT_DIR/scripts/setup_dependencies.sh"
fi

# ── Step 2: Build the library and CLI ────────────────────────────────────────

echo "Building..."
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake "$PROJECT_DIR" -DCMAKE_BUILD_TYPE=Release
make -j$(sysctl -n hw.logicalcpu)

# ── Step 3: Build the framework ─────────────────────────────────────────────

echo "Building framework..."
"$PROJECT_DIR/scripts/build_framework.sh"

# ── Step 4: Assemble release directory ───────────────────────────────────────

echo "Assembling release..."
rm -rf "$STAGING"
mkdir -p "$STAGING/bin"
mkdir -p "$STAGING/lib"
mkdir -p "$STAGING/include/MetalWhisper"
mkdir -p "$STAGING/models"

# CLI binary
cp "$BUILD_DIR/metalwhisper" "$STAGING/bin/"

# MetalWhisper dylib (with versioned symlinks)
cp "$BUILD_DIR/libMetalWhisper.0.1.0.dylib" "$STAGING/lib/"
cd "$STAGING/lib"
ln -sf "libMetalWhisper.0.1.0.dylib" "libMetalWhisper.0.dylib"
ln -sf "libMetalWhisper.0.1.0.dylib" "libMetalWhisper.dylib"
cd "$BUILD_DIR"

# CTranslate2 dylib
CT2_LIB="$PROJECT_DIR/third_party/ctranslate2-mps/lib"
cp "$CT2_LIB/libctranslate2.mps.4.7.1.dylib" "$STAGING/lib/"
cd "$STAGING/lib"
ln -sf "libctranslate2.mps.4.7.1.dylib" "libctranslate2.mps.4.dylib"
ln -sf "libctranslate2.mps.4.7.1.dylib" "libctranslate2.dylib"
cd "$BUILD_DIR"

# ONNX Runtime dylib
ORT_LIB="$PROJECT_DIR/third_party/onnxruntime-osx-arm64-1.21.0/lib"
cp "$ORT_LIB/libonnxruntime.1.21.0.dylib" "$STAGING/lib/"
cd "$STAGING/lib"
ln -sf "libonnxruntime.1.21.0.dylib" "libonnxruntime.dylib"
cd "$BUILD_DIR"

# VAD model
if [ -f "$PROJECT_DIR/models/silero_vad_v6.onnx" ]; then
    cp "$PROJECT_DIR/models/silero_vad_v6.onnx" "$STAGING/models/"
fi

# Public headers
for header in MWTranscriber.h MWTranscriptionOptions.h MWAudioDecoder.h \
              MWFeatureExtractor.h MWTokenizer.h MWVoiceActivityDetector.h \
              MWModelManager.h MWConstants.h MetalWhisper.h; do
    if [ -f "$PROJECT_DIR/src/$header" ]; then
        cp "$PROJECT_DIR/src/$header" "$STAGING/include/MetalWhisper/"
    fi
done

# Framework bundle
if [ -d "$BUILD_DIR/MetalWhisper.framework" ]; then
    cp -R "$BUILD_DIR/MetalWhisper.framework" "$STAGING/"
fi

# ── Step 5: Fix rpaths for standalone use ────────────────────────────────────

echo "Fixing rpaths..."

# CLI binary: look for dylibs in ../lib relative to binary
install_name_tool -add_rpath "@executable_path/../lib" "$STAGING/bin/metalwhisper" 2>/dev/null || true

# MetalWhisper dylib: look for CT2 and ORT in same directory
install_name_tool -add_rpath "@loader_path" "$STAGING/lib/libMetalWhisper.0.1.0.dylib" 2>/dev/null || true

# ── Step 6: Create README ────────────────────────────────────────────────────

cat > "$STAGING/README.md" << 'EOF'
# MetalWhisper — Pre-built Release

Native macOS Whisper transcription powered by Metal GPU acceleration.

## Quick Start

```bash
# Transcribe (auto-downloads model on first use)
./bin/metalwhisper audio.mp3 --model turbo

# Subtitles
./bin/metalwhisper lecture.mp3 --model turbo --output-format srt > lecture.srt

# Word-level timestamps as JSON
./bin/metalwhisper audio.wav --model turbo --word-timestamps --json

# With voice activity detection
./bin/metalwhisper long_meeting.wav --model turbo --vad-filter --vad-model models/silero_vad_v6.onnx

# List available models
./bin/metalwhisper --list-models
```

## Contents

- `bin/metalwhisper` — CLI tool
- `lib/` — Dynamic libraries (MetalWhisper + CTranslate2 + ONNX Runtime)
- `include/MetalWhisper/` — C/Obj-C headers for framework use
- `MetalWhisper.framework/` — macOS framework for Swift apps
- `models/silero_vad_v6.onnx` — Voice activity detection model

## Using from Swift

```swift
import MetalWhisper

let transcriber = try MWTranscriber(modelPath: modelPath)
let segments = try transcriber.transcribeURL(url, language: nil, task: "transcribe",
                                              typedOptions: nil, segmentHandler: nil, info: &info)
```

Compile with:
```bash
swiftc -F /path/to/this/directory -framework MetalWhisper my_app.swift
```

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1/M2/M3/M4)
EOF

# ── Step 7: Create tarball ───────────────────────────────────────────────────

echo "Creating tarball..."
cd "$BUILD_DIR"
tar czf "${RELEASE_NAME}.tar.gz" "$RELEASE_NAME"

# Show result
SIZE=$(du -h "${RELEASE_NAME}.tar.gz" | awk '{print $1}')
echo ""
echo "=== Release built: $BUILD_DIR/${RELEASE_NAME}.tar.gz ($SIZE) ==="
echo ""
echo "Contents:"
find "$STAGING" -type f | sed "s|$STAGING/||" | sort
