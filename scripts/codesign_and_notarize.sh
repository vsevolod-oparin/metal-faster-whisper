#!/bin/bash
# Code-sign and notarize a MetalWhisper release directory or tarball.
#
# Usage:
#   ./scripts/codesign_and_notarize.sh [--sign-only] [RELEASE_DIR]
#
# Arguments:
#   RELEASE_DIR   Path to the assembled release directory (default: build/metalwhisper-*-macos-arm64)
#   --sign-only   Sign without notarizing (useful for local testing)
#
# Required environment variables:
#   CODESIGN_IDENTITY    Developer ID signing identity, e.g.:
#                        "Developer ID Application: Your Name (TEAMID)"
#                        Find yours with: security find-identity -v -p codesigning
#
# For notarization (one of these auth methods):
#
#   Method 1 — App Store Connect API key (preferred for CI):
#     NOTARIZE_KEY_ID      API key ID (e.g., "XXXXXXXXXX")
#     NOTARIZE_ISSUER      Issuer UUID from App Store Connect
#     NOTARIZE_KEY_PATH    Path to the .p8 private key file
#
#   Method 2 — Apple ID (simpler for local use):
#     NOTARIZE_APPLE_ID    Apple ID email
#     NOTARIZE_PASSWORD    App-specific password (NOT your Apple ID password)
#                          Generate at: https://appleid.apple.com/account/manage
#     NOTARIZE_TEAM_ID     10-character team ID
#
# Setup checklist:
#   1. Create a "Developer ID Application" certificate at:
#      https://developer.apple.com/account/resources/certificates/list
#   2. Download and double-click the .cer to install in Keychain Access
#   3. Verify:  security find-identity -v -p codesigning
#   4. For notarization, create an app-specific password at:
#      https://appleid.apple.com/account/manage → Sign-In and Security → App-Specific Passwords
#      Or create an API key at App Store Connect → Users and Access → Integrations → Keys
#   5. Store credentials in the keychain (recommended):
#      xcrun notarytool store-credentials "metalwhisper-notary" \
#          --apple-id "you@example.com" \
#          --team-id "TEAMID" \
#          --password "app-specific-password"
#      Then set: NOTARIZE_KEYCHAIN_PROFILE="metalwhisper-notary"
#
# Example:
#   export CODESIGN_IDENTITY="Developer ID Application: Vsevolod Oparin (TEAMID)"
#   export NOTARIZE_KEYCHAIN_PROFILE="metalwhisper-notary"
#   ./scripts/build_release.sh
#   ./scripts/codesign_and_notarize.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ENTITLEMENTS="$SCRIPT_DIR/entitlements.plist"

# ── Parse arguments ──────────────────────────────────────────────────────────

SIGN_ONLY=0
RELEASE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign-only) SIGN_ONLY=1; shift ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
        *)  RELEASE_DIR="$1"; shift ;;
    esac
done

# Auto-detect release directory if not specified
if [ -z "$RELEASE_DIR" ]; then
    RELEASE_DIR=$(find "$BUILD_DIR" -maxdepth 1 -type d -name "metalwhisper-*-macos-arm64" | sort -r | head -1)
    if [ -z "$RELEASE_DIR" ]; then
        echo "ERROR: No release directory found. Run build_release.sh first."
        exit 1
    fi
fi

if [ ! -d "$RELEASE_DIR" ]; then
    echo "ERROR: Release directory not found: $RELEASE_DIR"
    exit 1
fi

# ── Validate signing identity ────────────────────────────────────────────────

if [ -z "$CODESIGN_IDENTITY" ]; then
    echo "ERROR: CODESIGN_IDENTITY not set."
    echo ""
    echo "Available identities:"
    security find-identity -v -p codesigning
    echo ""
    echo "Set with: export CODESIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\""
    exit 1
fi

# Verify the identity exists in the keychain
if ! security find-identity -v -p codesigning | grep -q "$CODESIGN_IDENTITY"; then
    echo "ERROR: Identity not found in keychain: $CODESIGN_IDENTITY"
    echo ""
    echo "Available identities:"
    security find-identity -v -p codesigning
    exit 1
fi

echo "=== Code Signing & Notarization ==="
echo "Release dir: $RELEASE_DIR"
echo "Identity:    $CODESIGN_IDENTITY"
echo "Entitlements: $ENTITLEMENTS"
echo ""

# ── Helper: sign a single binary ─────────────────────────────────────────────

sign_binary() {
    local path="$1"
    local label="$2"
    local use_entitlements="${3:-yes}"

    if [ ! -f "$path" ]; then
        echo "  SKIP (not found): $label"
        return
    fi

    local ent_args=()
    if [ "$use_entitlements" = "yes" ] && [ -f "$ENTITLEMENTS" ]; then
        ent_args=(--entitlements "$ENTITLEMENTS")
    fi

    codesign --force --options runtime --timestamp \
        --sign "$CODESIGN_IDENTITY" \
        "${ent_args[@]}" \
        "$path"
    echo "  SIGNED: $label"
}

# ── Helper: sign a framework bundle ──────────────────────────────────────────

sign_framework() {
    local fw_path="$1"
    local label="$2"

    if [ ! -d "$fw_path" ]; then
        echo "  SKIP (not found): $label"
        return
    fi

    codesign --force --options runtime --timestamp \
        --sign "$CODESIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$fw_path"
    echo "  SIGNED: $label"
}

# ── Step 1: Sign dylibs (sign dependencies before dependents) ────────────────

echo "Signing dylibs..."

# Third-party dylibs first (no entitlements — they don't need JIT/library-validation)
sign_binary "$RELEASE_DIR/lib/libonnxruntime.1.21.0.dylib" "libonnxruntime.1.21.0.dylib" no
sign_binary "$RELEASE_DIR/lib/libctranslate2.mps.4.7.1.dylib" "libctranslate2.mps.4.7.1.dylib" no

# MetalWhisper dylib (needs entitlements for Metal JIT + loading third-party libs)
sign_binary "$RELEASE_DIR/lib/libMetalWhisper.0.2.0.dylib" "libMetalWhisper.0.2.0.dylib" yes

# ── Step 2: Sign CLI binary ─────────────────────────────────────────────────

echo "Signing CLI binary..."
sign_binary "$RELEASE_DIR/bin/metalwhisper" "metalwhisper" yes

# ── Step 3: Sign framework bundle ────────────────────────────────────────────

echo "Signing framework..."
if [ -d "$RELEASE_DIR/MetalWhisper.framework" ]; then
    # Sign the framework binary inside the versioned layout
    local_fw="$RELEASE_DIR/MetalWhisper.framework"

    # Sign the inner binary first (Versions/A/MetalWhisper)
    if [ -f "$local_fw/Versions/A/MetalWhisper" ]; then
        sign_binary "$local_fw/Versions/A/MetalWhisper" "MetalWhisper.framework/Versions/A/MetalWhisper" yes
    fi

    # Then sign the framework bundle as a whole
    sign_framework "$local_fw" "MetalWhisper.framework"
fi

# ── Step 4: Verify signatures ────────────────────────────────────────────────

echo ""
echo "Verifying signatures..."

VERIFY_FAILED=0

verify_binary() {
    local path="$1"
    local label="$2"

    if [ ! -e "$path" ]; then
        return
    fi

    if codesign --verify --deep --strict "$path" 2>/dev/null; then
        echo "  OK: $label"
    else
        echo "  FAIL: $label"
        codesign --verify --deep --strict --verbose=4 "$path" 2>&1 | head -5
        VERIFY_FAILED=1
    fi
}

verify_binary "$RELEASE_DIR/lib/libonnxruntime.1.21.0.dylib" "libonnxruntime"
verify_binary "$RELEASE_DIR/lib/libctranslate2.mps.4.7.1.dylib" "libctranslate2"
verify_binary "$RELEASE_DIR/lib/libMetalWhisper.0.2.0.dylib" "libMetalWhisper"
verify_binary "$RELEASE_DIR/bin/metalwhisper" "metalwhisper"
verify_binary "$RELEASE_DIR/MetalWhisper.framework" "MetalWhisper.framework"

if [ "$VERIFY_FAILED" -eq 1 ]; then
    echo ""
    echo "ERROR: One or more signatures failed verification."
    exit 1
fi

echo ""
echo "All signatures verified."

# ── Step 5: Notarize ────────────────────────────────────────────────────────

if [ "$SIGN_ONLY" -eq 1 ]; then
    echo ""
    echo "=== Signing complete (--sign-only, skipping notarization) ==="
    exit 0
fi

echo ""
echo "Preparing for notarization..."

# Create a zip for notarization submission
NOTARIZE_ZIP="$BUILD_DIR/metalwhisper-notarize.zip"
rm -f "$NOTARIZE_ZIP"
cd "$(dirname "$RELEASE_DIR")"
zip -r --symlinks "$NOTARIZE_ZIP" "$(basename "$RELEASE_DIR")"
cd "$PROJECT_DIR"

echo "  Created: $NOTARIZE_ZIP ($(du -h "$NOTARIZE_ZIP" | awk '{print $1}'))"

# Build notarytool arguments
NOTARY_ARGS=()

if [ -n "${NOTARIZE_KEYCHAIN_PROFILE:-}" ]; then
    # Preferred: stored keychain profile (most secure, no env vars with secrets)
    NOTARY_ARGS=(--keychain-profile "$NOTARIZE_KEYCHAIN_PROFILE")
    echo "  Auth: keychain profile '$NOTARIZE_KEYCHAIN_PROFILE'"

elif [ -n "${NOTARIZE_KEY_ID:-}" ] && [ -n "${NOTARIZE_ISSUER:-}" ] && [ -n "${NOTARIZE_KEY_PATH:-}" ]; then
    # App Store Connect API key (good for CI)
    NOTARY_ARGS=(--key "$NOTARIZE_KEY_PATH" --key-id "$NOTARIZE_KEY_ID" --issuer "$NOTARIZE_ISSUER")
    echo "  Auth: API key $NOTARIZE_KEY_ID"

elif [ -n "${NOTARIZE_APPLE_ID:-}" ] && [ -n "${NOTARIZE_PASSWORD:-}" ] && [ -n "${NOTARIZE_TEAM_ID:-}" ]; then
    # Apple ID + app-specific password
    NOTARY_ARGS=(--apple-id "$NOTARIZE_APPLE_ID" --password "$NOTARIZE_PASSWORD" --team-id "$NOTARIZE_TEAM_ID")
    echo "  Auth: Apple ID $NOTARIZE_APPLE_ID"

else
    echo "ERROR: No notarization credentials found."
    echo ""
    echo "Set one of:"
    echo "  1. NOTARIZE_KEYCHAIN_PROFILE (recommended — run 'xcrun notarytool store-credentials' first)"
    echo "  2. NOTARIZE_KEY_ID + NOTARIZE_ISSUER + NOTARIZE_KEY_PATH (API key)"
    echo "  3. NOTARIZE_APPLE_ID + NOTARIZE_PASSWORD + NOTARIZE_TEAM_ID (Apple ID)"
    exit 1
fi

# Submit for notarization
echo ""
echo "Submitting to Apple for notarization..."
echo "  (this typically takes 2-10 minutes)"

xcrun notarytool submit "$NOTARIZE_ZIP" \
    "${NOTARY_ARGS[@]}" \
    --wait \
    --timeout 30m \
    2>&1 | tee "$BUILD_DIR/notarize-log.txt"

# Check result
if grep -q "status: Accepted" "$BUILD_DIR/notarize-log.txt"; then
    echo ""
    echo "Notarization ACCEPTED."

    # Extract submission ID for log retrieval
    SUBMISSION_ID=$(grep -o 'id: [a-f0-9-]*' "$BUILD_DIR/notarize-log.txt" | head -1 | awk '{print $2}')
    if [ -n "$SUBMISSION_ID" ]; then
        echo "  Submission ID: $SUBMISSION_ID"
        echo "  Full log: xcrun notarytool log $SUBMISSION_ID ${NOTARY_ARGS[*]}"
    fi
else
    echo ""
    echo "ERROR: Notarization failed or timed out."
    echo "Check $BUILD_DIR/notarize-log.txt for details."

    # Try to get the log for diagnostics
    SUBMISSION_ID=$(grep -o 'id: [a-f0-9-]*' "$BUILD_DIR/notarize-log.txt" | head -1 | awk '{print $2}')
    if [ -n "$SUBMISSION_ID" ]; then
        echo ""
        echo "Fetching detailed log..."
        xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" \
            "$BUILD_DIR/notarize-details.json" 2>/dev/null || true
        if [ -f "$BUILD_DIR/notarize-details.json" ]; then
            echo "  Saved to: $BUILD_DIR/notarize-details.json"
            cat "$BUILD_DIR/notarize-details.json"
        fi
    fi
    exit 1
fi

# ── Step 6: Re-create the release tarball (now signed + notarized) ──────────

echo ""
echo "Re-creating release tarball with signed binaries..."
RELEASE_NAME="$(basename "$RELEASE_DIR")"
cd "$(dirname "$RELEASE_DIR")"
rm -f "${RELEASE_NAME}.tar.gz"
tar czf "${RELEASE_NAME}.tar.gz" "$RELEASE_NAME"
cd "$PROJECT_DIR"

TARBALL="$(dirname "$RELEASE_DIR")/${RELEASE_NAME}.tar.gz"
SIZE=$(du -h "$TARBALL" | awk '{print $1}')

# Clean up notarization zip
rm -f "$NOTARIZE_ZIP"

echo ""
echo "=== Code signing & notarization complete ==="
echo ""
echo "  Signed tarball: $TARBALL ($SIZE)"
echo ""
echo "  Users on macOS 14+ will see no Gatekeeper warnings."
echo "  The notarization ticket is stored in Apple's servers —"
echo "  Gatekeeper checks it online on first launch."
