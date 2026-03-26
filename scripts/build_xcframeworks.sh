#!/bin/bash
# Build .xcframework bundles for SPM distribution.
# Run from project root: ./scripts/build_xcframeworks.sh
#
# Produces:
#   build/xcframeworks/MetalWhisper.xcframework
#   build/xcframeworks/CTranslate2.xcframework
#   build/xcframeworks/OnnxRuntime.xcframework

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
XCF_DIR="$BUILD_DIR/xcframeworks"

echo "=== Building xcframeworks for SPM ==="

# ── Step 1: Ensure the library and framework are built ─────────────────────

if [ ! -f "$BUILD_DIR/libMetalWhisper.0.1.0.dylib" ]; then
    echo "Building MetalWhisper..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    cmake "$PROJECT_DIR" -DCMAKE_BUILD_TYPE=Release
    make -j$(sysctl -n hw.logicalcpu)
fi

# ── Step 2: Create xcframeworks ────────────────────────────────────────────

rm -rf "$XCF_DIR"
mkdir -p "$XCF_DIR"

# Helper: create an xcframework from a dylib
# Usage: make_xcframework <name> <dylib_path> <headers_dir> <install_name>
make_xcframework() {
    local name="$1"
    local dylib="$2"
    local headers="$3"
    local staging="$XCF_DIR/staging-$name"

    echo "Creating $name.xcframework..."
    rm -rf "$staging"

    # Create a proper framework bundle from the dylib
    local fw_dir="$staging/$name.framework"
    mkdir -p "$fw_dir/Headers"

    # Copy and rename dylib to framework binary
    cp "$dylib" "$fw_dir/$name"

    # Fix install name to be framework-relative
    install_name_tool -id "@rpath/$name.framework/$name" "$fw_dir/$name" 2>/dev/null || true

    # Copy public headers
    if [ -d "$headers" ]; then
        cp -R "$headers"/*.h "$fw_dir/Headers/" 2>/dev/null || true
        # Also copy subdirectories (e.g., ctranslate2/)
        for subdir in "$headers"/*/; do
            if [ -d "$subdir" ]; then
                cp -R "$subdir" "$fw_dir/Headers/"
            fi
        done
    fi

    # Create Info.plist
    cat > "$fw_dir/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$name</string>
    <key>CFBundleIdentifier</key>
    <string>com.metalwhisper.$name</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>MinimumOSVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

    # Build xcframework
    xcodebuild -create-xcframework \
        -framework "$fw_dir" \
        -output "$XCF_DIR/$name.xcframework"

    rm -rf "$staging"
    echo "  ✓ $name.xcframework"
}

# ── MetalWhisper xcframework ──

MW_STAGING="$XCF_DIR/staging-mw"
MW_FW="$MW_STAGING/MetalWhisper.framework"
mkdir -p "$MW_FW/Headers" "$MW_FW/Modules"

# Copy dylib as framework binary
cp "$BUILD_DIR/libMetalWhisper.0.1.0.dylib" "$MW_FW/MetalWhisper"
install_name_tool -id "@rpath/MetalWhisper.framework/MetalWhisper" "$MW_FW/MetalWhisper" 2>/dev/null || true

# Rewrite dependency references to match xcframework names.
# MetalWhisper references @rpath/libctranslate2.mps.4.dylib → @rpath/CTranslate2.framework/CTranslate2
# MetalWhisper references @rpath/libonnxruntime.1.21.0.dylib → @rpath/OnnxRuntime.framework/OnnxRuntime
CT2_OLD=$(otool -L "$MW_FW/MetalWhisper" | grep -o '@rpath/libctranslate2[^ ]*' | head -1)
ORT_OLD=$(otool -L "$MW_FW/MetalWhisper" | grep -o '@rpath/libonnxruntime[^ ]*' | head -1)
if [ -n "$CT2_OLD" ]; then
    install_name_tool -change "$CT2_OLD" "@rpath/CTranslate2.framework/CTranslate2" "$MW_FW/MetalWhisper"
fi
if [ -n "$ORT_OLD" ]; then
    install_name_tool -change "$ORT_OLD" "@rpath/OnnxRuntime.framework/OnnxRuntime" "$MW_FW/MetalWhisper"
fi

# Copy public headers
for h in MetalWhisper.h MWTranscriber.h MWTranscriptionOptions.h MWAudioDecoder.h \
         MWFeatureExtractor.h MWTokenizer.h MWVoiceActivityDetector.h \
         MWModelManager.h MWConstants.h MWLiveTranscriber.h MWHelpers.h; do
    cp "$PROJECT_DIR/src/$h" "$MW_FW/Headers/"
done

# Copy module map
cp "$PROJECT_DIR/src/module.modulemap" "$MW_FW/Modules/"

# Bundle VAD model as a framework resource so consumers don't need to provide it separately
if [ -f "$PROJECT_DIR/models/silero_vad_v6.onnx" ]; then
    mkdir -p "$MW_FW/Resources"
    cp "$PROJECT_DIR/models/silero_vad_v6.onnx" "$MW_FW/Resources/"
fi

# Info.plist
cat > "$MW_FW/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MetalWhisper</string>
    <key>CFBundleIdentifier</key>
    <string>com.metalwhisper.MetalWhisper</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>MinimumOSVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

xcodebuild -create-xcframework \
    -framework "$MW_FW" \
    -output "$XCF_DIR/MetalWhisper.xcframework"
rm -rf "$MW_STAGING"
echo "  ✓ MetalWhisper.xcframework"

# ── CTranslate2 xcframework ──

CT2_LIB="$PROJECT_DIR/third_party/ctranslate2-mps/lib"
CT2_INC="$PROJECT_DIR/third_party/ctranslate2-mps/include"

# Find the actual dylib (not symlink)
CT2_DYLIB=$(find "$CT2_LIB" -name "libctranslate2.mps.*.*.*.dylib" -not -type l 2>/dev/null | head -1)
if [ -z "$CT2_DYLIB" ]; then
    CT2_DYLIB=$(find "$CT2_LIB" -name "libctranslate2.*.*.*.dylib" -not -type l 2>/dev/null | head -1)
fi
if [ -z "$CT2_DYLIB" ]; then
    CT2_DYLIB="$CT2_LIB/libctranslate2.dylib"
fi

CT2_STAGING="$XCF_DIR/staging-ct2"
CT2_FW="$CT2_STAGING/CTranslate2.framework"
mkdir -p "$CT2_FW/Headers"
cp "$CT2_DYLIB" "$CT2_FW/CTranslate2"
install_name_tool -id "@rpath/CTranslate2.framework/CTranslate2" "$CT2_FW/CTranslate2" 2>/dev/null || true

# Copy CT2 headers (including subdirectories)
if [ -d "$CT2_INC/ctranslate2" ]; then
    cp -R "$CT2_INC/ctranslate2" "$CT2_FW/Headers/"
fi

cat > "$CT2_FW/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>CTranslate2</string>
    <key>CFBundleIdentifier</key>
    <string>com.metalwhisper.CTranslate2</string>
    <key>CFBundleVersion</key>
    <string>4.7.1</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>MinimumOSVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

xcodebuild -create-xcframework \
    -framework "$CT2_FW" \
    -output "$XCF_DIR/CTranslate2.xcframework"
rm -rf "$CT2_STAGING"
echo "  ✓ CTranslate2.xcframework"

# ── OnnxRuntime xcframework ──

ORT_DIR="$PROJECT_DIR/third_party/onnxruntime-osx-arm64-1.21.0"
ORT_DYLIB=$(find "$ORT_DIR/lib" -name "libonnxruntime.*.*.*.dylib" -not -type l 2>/dev/null | head -1)
if [ -z "$ORT_DYLIB" ]; then
    ORT_DYLIB="$ORT_DIR/lib/libonnxruntime.dylib"
fi

ORT_STAGING="$XCF_DIR/staging-ort"
ORT_FW="$ORT_STAGING/OnnxRuntime.framework"
mkdir -p "$ORT_FW/Headers"
cp "$ORT_DYLIB" "$ORT_FW/OnnxRuntime"
install_name_tool -id "@rpath/OnnxRuntime.framework/OnnxRuntime" "$ORT_FW/OnnxRuntime" 2>/dev/null || true

# Copy ORT headers
for h in "$ORT_DIR/include"/*.h; do
    cp "$h" "$ORT_FW/Headers/" 2>/dev/null || true
done
# Copy subdirectories (core/)
for subdir in "$ORT_DIR/include"/*/; do
    if [ -d "$subdir" ]; then
        cp -R "$subdir" "$ORT_FW/Headers/"
    fi
done

cat > "$ORT_FW/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>OnnxRuntime</string>
    <key>CFBundleIdentifier</key>
    <string>com.metalwhisper.OnnxRuntime</string>
    <key>CFBundleVersion</key>
    <string>1.21.0</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>MinimumOSVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

xcodebuild -create-xcframework \
    -framework "$ORT_FW" \
    -output "$XCF_DIR/OnnxRuntime.xcframework"
rm -rf "$ORT_STAGING"
echo "  ✓ OnnxRuntime.xcframework"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=== xcframeworks built ==="
ls -la "$XCF_DIR"/*.xcframework
echo ""
echo "These can be used with Package.swift binaryTarget or distributed as GitHub release artifacts."
