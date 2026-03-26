#!/bin/bash
# Build xcframeworks, zip them for SPM binary distribution, compute checksums,
# and generate the Package.swift for a GitHub release.
#
# Usage:
#   ./scripts/build_spm_release.sh [--repo OWNER/REPO] [--version VERSION]
#
# Examples:
#   ./scripts/build_spm_release.sh --repo vsevolod-oparin/metal-faster-whisper --version 0.1.0
#   ./scripts/build_spm_release.sh   # prints Package.swift with placeholder URLs
#
# Output:
#   build/spm-release/MetalWhisper.xcframework.zip
#   build/spm-release/CTranslate2.xcframework.zip
#   build/spm-release/OnnxRuntime.xcframework.zip
#   build/spm-release/Package.swift      (ready to commit before tagging)
#   build/spm-release/checksums.txt      (for reference)

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
XCF_DIR="$BUILD_DIR/xcframeworks"
RELEASE_DIR="$BUILD_DIR/spm-release"

# ── Parse arguments ────────────────────────────────────────────────────────

REPO=""
VERSION="0.1.0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# ── Step 1: Ensure xcframeworks exist ─────────────────────────────────────

if [ ! -d "$XCF_DIR/MetalWhisper.xcframework" ] || \
   [ ! -d "$XCF_DIR/CTranslate2.xcframework" ] || \
   [ ! -d "$XCF_DIR/OnnxRuntime.xcframework" ]; then
    echo "xcframeworks not found — building..."
    "$PROJECT_DIR/scripts/build_xcframeworks.sh"
fi

echo "=== Building SPM release v$VERSION ==="

# ── Step 2: Zip each xcframework ─────────────────────────────────────────

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

cd "$XCF_DIR"
for name in MetalWhisper CTranslate2 OnnxRuntime; do
    echo "Zipping $name.xcframework..."
    zip -r --symlinks "$RELEASE_DIR/$name.xcframework.zip" "$name.xcframework"
    echo "  ✓ $name.xcframework.zip ($(du -sh "$RELEASE_DIR/$name.xcframework.zip" | awk '{print $1}'))"
done
cd "$PROJECT_DIR"

# ── Step 3: Compute checksums ─────────────────────────────────────────────

echo ""
echo "Computing checksums..."

MW_CHECKSUM=$(swift package compute-checksum "$RELEASE_DIR/MetalWhisper.xcframework.zip")
CT2_CHECKSUM=$(swift package compute-checksum "$RELEASE_DIR/CTranslate2.xcframework.zip")
ORT_CHECKSUM=$(swift package compute-checksum "$RELEASE_DIR/OnnxRuntime.xcframework.zip")

cat > "$RELEASE_DIR/checksums.txt" << EOF
MetalWhisper.xcframework.zip  $MW_CHECKSUM
CTranslate2.xcframework.zip   $CT2_CHECKSUM
OnnxRuntime.xcframework.zip   $ORT_CHECKSUM
EOF

echo "  MetalWhisper:  $MW_CHECKSUM"
echo "  CTranslate2:   $CT2_CHECKSUM"
echo "  OnnxRuntime:   $ORT_CHECKSUM"

# ── Step 4: Generate Package.swift ───────────────────────────────────────

if [ -n "$REPO" ]; then
    BASE_URL="https://github.com/$REPO/releases/download/$VERSION"
else
    BASE_URL="https://github.com/OWNER/REPO/releases/download/$VERSION"
fi

cat > "$RELEASE_DIR/Package.swift" << EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetalWhisper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MetalWhisper",
            targets: ["MetalWhisper", "CTranslate2", "OnnxRuntime"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "MetalWhisper",
            url: "$BASE_URL/MetalWhisper.xcframework.zip",
            checksum: "$MW_CHECKSUM"
        ),
        .binaryTarget(
            name: "CTranslate2",
            url: "$BASE_URL/CTranslate2.xcframework.zip",
            checksum: "$CT2_CHECKSUM"
        ),
        .binaryTarget(
            name: "OnnxRuntime",
            url: "$BASE_URL/OnnxRuntime.xcframework.zip",
            checksum: "$ORT_CHECKSUM"
        ),
    ]
)
EOF

# ── Step 5: Summary and instructions ────────────────────────────────────

echo ""
echo "=== SPM release ready ==="
echo ""
echo "Release assets (upload these to GitHub release $VERSION):"
for name in MetalWhisper CTranslate2 OnnxRuntime; do
    echo "  $RELEASE_DIR/$name.xcframework.zip"
done
echo ""
echo "Next steps:"
echo "  1. Copy Package.swift to project root:"
echo "       cp $RELEASE_DIR/Package.swift $PROJECT_DIR/Package.swift"
if [ -z "$REPO" ]; then
    echo "     (replace OWNER/REPO in the generated Package.swift with your actual repo)"
fi
echo "  2. Commit: git add Package.swift && git commit -m 'release: v$VERSION'"
echo "  3. Tag:    git tag $VERSION && git push && git push --tags"
echo "  4. Create GitHub release $VERSION and upload the 3 zip files from:"
echo "     $RELEASE_DIR/"
echo ""
echo "Consumers add the dependency with:"
if [ -n "$REPO" ]; then
    echo "  .package(url: \"https://github.com/$REPO\", from: \"$VERSION\")"
else
    echo "  .package(url: \"https://github.com/OWNER/REPO\", from: \"$VERSION\")"
fi
