#!/bin/bash
# Macoestro build + sign + (optionally) notarize + install pipeline.
# Usage:
#   ./build.sh                 full release: Developer ID sign + notarize + staple + install
#   ./build.sh --skip-notarize Developer ID sign, skip notarization (first-launch may Gatekeeper-prompt)
#   ./build.sh --dev           ad-hoc sign only (fastest; TCC grants won't persist rebuilds)

set -euo pipefail

MODE="${1:-release}"
SIGN_ID="Developer ID Application: Izotz Cristobal Mota (U4VYZ8CUN9)"
ENTITLEMENTS="Resources/Macoestro.entitlements"
BUILD_DIR="build/Macoestro.app"
NOTARY_PROFILE="macoestro-notary"

cd "$(dirname "$0")"

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

say "Killing any running Macoestro"
pkill -x Macoestro 2>/dev/null || true

say "Swift build (release, arm64)"
swift build -c release --arch arm64

say "Assembling .app bundle"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/Contents/MacOS"
cp .build/arm64-apple-macosx/release/Macoestro "$BUILD_DIR/Contents/MacOS/"
cp Resources/Info.plist "$BUILD_DIR/Contents/"

case "$MODE" in
    --dev)
        say "Signing ad-hoc (dev mode — TCC will NOT persist across rebuilds)"
        codesign --force --deep --sign - "$BUILD_DIR"
        ;;
    --skip-notarize|release)
        say "Signing with Developer ID + hardened runtime"
        codesign --force --deep --options runtime \
            --entitlements "$ENTITLEMENTS" \
            --sign "$SIGN_ID" \
            --timestamp \
            "$BUILD_DIR"
        ;;
    *)
        echo "Unknown mode: $MODE (use --dev, --skip-notarize, or no arg for full release)" >&2
        exit 1
        ;;
esac

if [ "$MODE" = "release" ]; then
    say "Notarizing (this takes 1-3 min)"
    ZIP="build/Macoestro.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$BUILD_DIR" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$ZIP"

    say "Stapling notarization ticket"
    xcrun stapler staple "$BUILD_DIR"
fi

say "Installing to /Applications"
rm -rf /Applications/Macoestro.app
cp -R "$BUILD_DIR" /Applications/
xattr -cr /Applications/Macoestro.app

say "Deploying resilient MCP bridge to ~/.macoestro/"
mkdir -p ~/.macoestro
cp Scripts/macoestro-mcp-bridge.sh ~/.macoestro/macoestro-mcp-bridge.sh
chmod +x ~/.macoestro/macoestro-mcp-bridge.sh

say "Launching"
open -a Macoestro

sleep 1
say "Verification"
codesign -dvv /Applications/Macoestro.app 2>&1 | grep -E "Identifier|TeamIdentifier|Authority|flags" || true
if [ "$MODE" = "release" ]; then
    spctl -a -vvv /Applications/Macoestro.app 2>&1 | head -5 || true
fi
pgrep -fl Macoestro || echo "(not running — check Console for crash)"

printf '\n\033[1;32mDone.\033[0m First launch: grant Accessibility + Screen Recording once; they persist forever with Team ID U4VYZ8CUN9.\n'
