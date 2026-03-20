#!/bin/bash
# tests/test_spm.sh — Verify SPM Package.swift integration
#
# Creates a temporary Swift package that depends on MetalWhisper,
# builds it with `swift build`, runs it, and verifies output.
#
# Prerequisites:
#   - xcframeworks built: ./scripts/build_xcframeworks.sh
#   - turbo model cached (or pass model path as $1)
#
# Usage: ./tests/test_spm.sh [model_path] [data_dir]

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_PATH="${1:-/Users/smileijp/Library/Caches/MetalWhisper/models/mobiuslabsgmbh--faster-whisper-large-v3-turbo}"
DATA_DIR="${2:-$PROJECT_DIR/tests/data}"
TMPDIR=$(mktemp -d /tmp/test-spm-XXXXXX)

PASS=0
FAIL=0

report() {
    local name="$1" passed="$2" detail="$3"
    if [ "$passed" = "1" ]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name -- $detail"
        FAIL=$((FAIL + 1))
    fi
}

cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

echo "=== SPM Integration Tests ==="
echo "Project: $PROJECT_DIR"
echo "Model:   $MODEL_PATH"
echo "Data:    $DATA_DIR"
echo "Temp:    $TMPDIR"
echo ""

# ── Check prerequisites ──────────────────────────────────────────────────────

if [ ! -d "$PROJECT_DIR/build/xcframeworks/MetalWhisper.xcframework" ]; then
    echo "FATAL: xcframeworks not found. Run: ./scripts/build_xcframeworks.sh"
    exit 1
fi

# ── Test 1: swift package describe ────────────────────────────────────────────

echo "--- Test 1: Package resolution ---"
DESCRIBE_OUT=$(cd "$PROJECT_DIR" && swift package describe 2>&1)
if echo "$DESCRIBE_OUT" | grep -q "Name: MetalWhisper" && \
   echo "$DESCRIBE_OUT" | grep -q "BinaryTarget"; then
    report "spm_package_describe" 1
else
    report "spm_package_describe" 0 "swift package describe failed or missing targets"
fi

# ── Test 2: Consumer package builds ───────────────────────────────────────────

echo "--- Test 2: Consumer build ---"

mkdir -p "$TMPDIR/Sources/TestSPM"

cat > "$TMPDIR/Package.swift" << 'SWIFTEOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "TestSPM",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "PLACEHOLDER_PROJECT_DIR"),
    ],
    targets: [
        .executableTarget(
            name: "TestSPM",
            dependencies: [
                .product(name: "MetalWhisper", package: "metal-faster-whisper"),
            ]
        ),
    ]
)
SWIFTEOF

# Replace placeholder with actual path
sed -i '' "s|PLACEHOLDER_PROJECT_DIR|$PROJECT_DIR|g" "$TMPDIR/Package.swift"

cat > "$TMPDIR/Sources/TestSPM/main.swift" << 'SWIFTEOF'
import Foundation
import MetalWhisper

// Test 1: API access
let manager = MWModelManager.shared()
let aliases = MWModelManager.availableModels()
print("ALIASES:\(aliases.count)")

// Test 2: Options creation
let opts = MWTranscriptionOptions.defaults()
opts.wordTimestamps = true
opts.beamSize = 6
print("BEAM:\(opts.beamSize)")

// Test 3: Model loading and transcription (if model path provided)
let args = CommandLine.arguments
if args.count >= 3 {
    let modelPath = args[1]
    let audioPath = args[2]

    do {
        let transcriber = try MWTranscriber(modelPath: modelPath)
        print("LOADED:YES")
        print("NMELS:\(transcriber.nMels)")

        var info: MWTranscriptionInfo?
        let segments = try transcriber.transcribeURL(
            URL(fileURLWithPath: audioPath),
            language: nil,
            task: "transcribe",
            typedOptions: opts,
            segmentHandler: nil,
            info: &info
        )

        let text = segments.map { $0.text }.joined().lowercased()
        print("SEGMENTS:\(segments.count)")
        print("HAS_COUNTRY:\(text.contains("country"))")
        if let info = info {
            print("LANG:\(info.language)")
        }
    } catch {
        print("ERROR:\(error.localizedDescription)")
    }
} else {
    print("LOADED:SKIP")
}

print("DONE")
SWIFTEOF

BUILD_OUT=$(cd "$TMPDIR" && swift build 2>&1)
if [ $? -eq 0 ]; then
    report "spm_consumer_build" 1
else
    report "spm_consumer_build" 0 "swift build failed: $(echo "$BUILD_OUT" | tail -5)"
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

# ── Test 3: Consumer runs (API access only) ──────────────────────────────────

echo "--- Test 3: Consumer run (API) ---"

RUN_OUT=$(cd "$TMPDIR" && .build/arm64-apple-macosx/debug/TestSPM 2>&1)
if echo "$RUN_OUT" | grep -q "ALIASES:18" && \
   echo "$RUN_OUT" | grep -q "BEAM:6" && \
   echo "$RUN_OUT" | grep -q "DONE"; then
    report "spm_api_access" 1
else
    report "spm_api_access" 0 "Unexpected output: $RUN_OUT"
fi

# ── Test 4: Consumer runs (transcription) ─────────────────────────────────────

echo "--- Test 4: Consumer run (transcription) ---"

AUDIO="$DATA_DIR/jfk.flac"
if [ -f "$MODEL_PATH/model.bin" ] && [ -f "$AUDIO" ]; then
    TX_OUT=$(cd "$TMPDIR" && .build/arm64-apple-macosx/debug/TestSPM "$MODEL_PATH" "$AUDIO" 2>&1) || true
    if echo "$TX_OUT" | grep -q "LOADED:YES" && \
       echo "$TX_OUT" | grep -q "HAS_COUNTRY:true" && \
       echo "$TX_OUT" | grep -q "LANG:en"; then
        report "spm_transcription" 1
    else
        report "spm_transcription" 0 "Output: $(echo "$TX_OUT" | tr '\n' ' ' | head -c 200)"
    fi
else
    echo "  SKIP: spm_transcription (model or audio not found)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=== SPM Results: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0 ? 1 : 0))
