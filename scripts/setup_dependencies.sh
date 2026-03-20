#!/bin/bash
# Download pre-built dependencies for MetalWhisper
# Run from the project root: ./scripts/setup_dependencies.sh

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
THIRD_PARTY="$PROJECT_DIR/third_party"

echo "=== MetalWhisper Dependency Setup ==="
echo "Project: $PROJECT_DIR"
echo ""

# ── CTranslate2 (Metal/MPS build) ──────────────────────────────────────────

CT2_DIR="$THIRD_PARTY/ctranslate2-mps"
CT2_VERSION="4.7.1"
CT2_DYLIB_URL="https://github.com/vsevolod-oparin/CTranslate2/releases/download/metal-dev-0.2/libctranslate2.mps.4.7.1.dylib"
CT2_STATIC_URL="https://github.com/vsevolod-oparin/CTranslate2/releases/download/metal-dev-0.2/libctranslate2.mps.a"
CT2_HEADERS_URL="https://github.com/vsevolod-oparin/CTranslate2/archive/refs/heads/metal-dev.tar.gz"

if [ -f "$CT2_DIR/lib/libctranslate2.dylib" ]; then
    echo "[CT2] Already installed at $CT2_DIR"
else
    echo "[CT2] Downloading CTranslate2 $CT2_VERSION (Metal/MPS)..."
    mkdir -p "$CT2_DIR/lib" "$CT2_DIR/include"

    # Download dylib
    echo "  Downloading libctranslate2.dylib..."
    curl -L -o "$CT2_DIR/lib/libctranslate2.mps.$CT2_VERSION.dylib" "$CT2_DYLIB_URL"
    cd "$CT2_DIR/lib"
    # The dylib's install name is @rpath/libctranslate2.mps.4.dylib
    ln -sf "libctranslate2.mps.$CT2_VERSION.dylib" "libctranslate2.mps.4.dylib"
    ln -sf "libctranslate2.mps.$CT2_VERSION.dylib" "libctranslate2.mps.dylib"
    # Also create standard names for cmake find_package compatibility
    ln -sf "libctranslate2.mps.$CT2_VERSION.dylib" "libctranslate2.$CT2_VERSION.dylib"
    ln -sf "libctranslate2.mps.$CT2_VERSION.dylib" "libctranslate2.4.dylib"
    ln -sf "libctranslate2.mps.$CT2_VERSION.dylib" "libctranslate2.dylib"

    # Download static lib
    echo "  Downloading libctranslate2.a..."
    curl -L -o "$CT2_DIR/lib/libctranslate2.a" "$CT2_STATIC_URL"

    # Get headers — prefer local CTranslate2 repo, fall back to GitHub API
    echo "  Setting up headers..."
    LOCAL_CT2="$(dirname "$PROJECT_DIR")/CTranslate2/include/ctranslate2"
    if [ -d "$LOCAL_CT2" ]; then
        cp -R "$LOCAL_CT2" "$CT2_DIR/include/"
        echo "  Copied headers from local CTranslate2 repo"
    else
        echo "  Downloading headers from GitHub..."
        TEMP_TAR=$(mktemp)
        curl -L -o "$TEMP_TAR" "https://api.github.com/repos/vsevolod-oparin/CTranslate2/tarball/metal-dev"
        tar xzf "$TEMP_TAR" -C /tmp
        EXTRACTED=$(ls -d /tmp/vsevolod-oparin-CTranslate2-* 2>/dev/null | head -1)
        if [ -d "$EXTRACTED/include/ctranslate2" ]; then
            cp -R "$EXTRACTED/include/ctranslate2" "$CT2_DIR/include/"
        else
            echo "  ERROR: Could not find headers in downloaded archive"
            exit 1
        fi
        rm -rf "$EXTRACTED" "$TEMP_TAR"
    fi

    # Copy cmake config if available, otherwise create a minimal one
    mkdir -p "$CT2_DIR/lib/cmake/ctranslate2"
    cat > "$CT2_DIR/lib/cmake/ctranslate2/ctranslate2-config.cmake" << 'CMAKE_EOF'
# Minimal CTranslate2 CMake config for MetalWhisper
if(NOT TARGET CTranslate2::ctranslate2)
    add_library(CTranslate2::ctranslate2 SHARED IMPORTED)
    get_filename_component(_CT2_PREFIX "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
    set_target_properties(CTranslate2::ctranslate2 PROPERTIES
        IMPORTED_LOCATION "${_CT2_PREFIX}/lib/libctranslate2.dylib"
        INTERFACE_INCLUDE_DIRECTORIES "${_CT2_PREFIX}/include"
    )
endif()
CMAKE_EOF

    echo "[CT2] Installed to $CT2_DIR"
fi

# ── ONNX Runtime (for VAD) ─────────────────────────────────────────────────

ORT_DIR="$THIRD_PARTY/onnxruntime-osx-arm64-1.21.0"
ORT_URL="https://github.com/microsoft/onnxruntime/releases/download/v1.21.0/onnxruntime-osx-arm64-1.21.0.tgz"

if [ -f "$ORT_DIR/lib/libonnxruntime.dylib" ]; then
    echo "[ORT] Already installed at $ORT_DIR"
else
    echo "[ORT] Downloading ONNX Runtime 1.21.0 (arm64)..."
    mkdir -p "$THIRD_PARTY"
    curl -L -o "$THIRD_PARTY/onnxruntime.tgz" "$ORT_URL"
    tar xzf "$THIRD_PARTY/onnxruntime.tgz" -C "$THIRD_PARTY"
    rm "$THIRD_PARTY/onnxruntime.tgz"
    echo "[ORT] Installed to $ORT_DIR"
fi

# ── Silero VAD model ───────────────────────────────────────────────────────

VAD_MODEL="$PROJECT_DIR/models/silero_vad_v6.onnx"
VAD_URL="https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx"

if [ -f "$VAD_MODEL" ]; then
    echo "[VAD] Already installed at $VAD_MODEL"
else
    echo "[VAD] Downloading Silero VAD v6..."
    mkdir -p "$PROJECT_DIR/models"
    # Try to copy from faster-whisper first (faster, no network)
    FW_VAD="$(dirname "$PROJECT_DIR")/faster-whisper/faster_whisper/assets/silero_vad_v6.onnx"
    if [ -f "$FW_VAD" ]; then
        cp "$FW_VAD" "$VAD_MODEL"
        echo "[VAD] Copied from faster-whisper"
    else
        curl -L -o "$VAD_MODEL" "$VAD_URL"
        echo "[VAD] Downloaded"
    fi
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "To build MetalWhisper:"
echo "  mkdir -p build && cd build"
echo "  cmake .. -DCMAKE_BUILD_TYPE=Release -DCT2_INSTALL_PREFIX=$CT2_DIR"
echo "  make -j\$(sysctl -n hw.logicalcpu)"
echo ""
echo "To test:"
echo "  ./test_e2e <whisper_model_path> ../tests/data"
