#!/bin/bash
# Build MetalWhisper.framework — a proper macOS framework bundle
# that enables `import MetalWhisper` in Swift.
#
# Run from project root: ./scripts/build_framework.sh

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
FRAMEWORK_DIR="$BUILD_DIR/MetalWhisper.framework"

echo "=== Building MetalWhisper.framework ==="

# 1. Ensure the dylib is built
if [ ! -f "$BUILD_DIR/libMetalWhisper.dylib" ]; then
    echo "Building library first..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    cmake .. -DCMAKE_BUILD_TYPE=Release
    make -j$(sysctl -n hw.logicalcpu)
fi

# 2. Create framework structure
rm -rf "$FRAMEWORK_DIR"
mkdir -p "$FRAMEWORK_DIR/Versions/A/Headers"
mkdir -p "$FRAMEWORK_DIR/Versions/A/Modules"
mkdir -p "$FRAMEWORK_DIR/Versions/A/Resources"

# 3. Copy the dylib as the framework binary
cp "$BUILD_DIR/libMetalWhisper.dylib" "$FRAMEWORK_DIR/Versions/A/MetalWhisper"

# Fix the install name to framework convention
install_name_tool -id "@rpath/MetalWhisper.framework/Versions/A/MetalWhisper" \
    "$FRAMEWORK_DIR/Versions/A/MetalWhisper"

# 4. Copy public headers
for header in MWTranscriber.h MWTranscriptionOptions.h MWAudioDecoder.h \
              MWFeatureExtractor.h MWTokenizer.h MWVoiceActivityDetector.h \
              MWModelManager.h MWConstants.h MetalWhisper.h; do
    if [ -f "$PROJECT_DIR/src/$header" ]; then
        cp "$PROJECT_DIR/src/$header" "$FRAMEWORK_DIR/Versions/A/Headers/"
    fi
done

# 5. Create module map
cat > "$FRAMEWORK_DIR/Versions/A/Modules/module.modulemap" << 'EOF'
framework module MetalWhisper {
    umbrella header "MetalWhisper.h"
    export *
    module * { export * }
}
EOF

# 6. Create Info.plist
cat > "$FRAMEWORK_DIR/Versions/A/Resources/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.metalwhisper.framework</string>
    <key>CFBundleName</key>
    <string>MetalWhisper</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleExecutable</key>
    <string>MetalWhisper</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
EOF

# 7. Create version symlinks (standard framework structure)
cd "$FRAMEWORK_DIR/Versions"
ln -sf A Current
cd "$FRAMEWORK_DIR"
ln -sf Versions/Current/Headers Headers
ln -sf Versions/Current/Modules Modules
ln -sf Versions/Current/Resources Resources
ln -sf Versions/Current/MetalWhisper MetalWhisper

echo ""
echo "=== Framework built: $FRAMEWORK_DIR ==="
echo ""
echo "Use from Swift:"
echo "  swiftc -F $BUILD_DIR -framework MetalWhisper my_app.swift"
echo ""
echo "Or add to Xcode project: drag MetalWhisper.framework into your project."
