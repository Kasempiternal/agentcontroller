#!/bin/bash
# AgentController build + sign + (optionally) notarize + install pipeline.
# Usage:
#   ./build.sh                 full release: Developer ID sign + notarize + staple + install
#   ./build.sh --skip-notarize Developer ID sign, skip notarization (first-launch may Gatekeeper-prompt)
#   ./build.sh --dev           ad-hoc sign only (fastest; TCC grants won't persist rebuilds)

set -euo pipefail

MODE="${1:-release}"
SIGN_ID="${SIGN_ID:-Developer ID Application: Izotz Cristobal Mota (U4VYZ8CUN9)}"
ENTITLEMENTS="Resources/AgentController.entitlements"
BUILD_DIR="build/AgentController.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-agentcontroller-notary}"

cd "$(dirname "$0")"

# Marketing version straight from the bundle so the DMG name + volume match the app.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 0.0.0)"
DMG="build/AgentController-${VERSION}.dmg"

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m== ERROR: %s ==\033[0m\n' "$*" >&2; exit 1; }

# Fail fast if Developer ID signing is requested but the identity isn't in the keychain.
# Ad-hoc (--dev) signing uses the "-" pseudo-identity and needs no lookup.
if [ "$MODE" = "release" ] || [ "$MODE" = "--skip-notarize" ]; then
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
        die "Signing identity not found in keychain: '$SIGN_ID'
       Available codesigning identities:
$(security find-identity -v -p codesigning 2>/dev/null | sed 's/^/         /')
       Set a valid one with:  SIGN_ID='Developer ID Application: ...' ./build.sh $MODE"
    fi
fi

say "Killing any running AgentController"
pkill -x AgentController 2>/dev/null || true

say "Swift build (release, arm64)"
swift build -c release --arch arm64

say "Generating macOS app icon"
ICON_SOURCE="Resources/AgentControllerIcon.png"
ICONSET="build/AgentController.iconset"
ICON_FILE="build/AgentController.icns"
rm -rf "$ICONSET" "$ICON_FILE"
mkdir -p "$ICONSET"
sips -z 16 16     "$ICON_SOURCE" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     "$ICON_SOURCE" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "$ICON_SOURCE" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     "$ICON_SOURCE" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "$ICON_SOURCE" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   "$ICON_SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICON_SOURCE" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   "$ICON_SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICON_SOURCE" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$ICON_FILE"
rm -rf "$ICONSET"

say "Assembling .app bundle"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/Contents/MacOS"
cp .build/arm64-apple-macosx/release/AgentController "$BUILD_DIR/Contents/MacOS/"
cp Resources/Info.plist "$BUILD_DIR/Contents/"
# Bundle the canonical bridge script (sealed by the signature below) so the app
# itself can install/refresh ~/.agentcontroller/ — DMG installs never run this script.
mkdir -p "$BUILD_DIR/Contents/Resources"
cp Scripts/agentcontroller-mcp-bridge.sh "$BUILD_DIR/Contents/Resources/"
cp "$ICON_FILE" "$BUILD_DIR/Contents/Resources/AgentController.icns"

case "$MODE" in
    --dev)
        say "Signing ad-hoc (dev mode — TCC will NOT persist across rebuilds)"
        codesign --force --sign - "$BUILD_DIR"
        ;;
    --skip-notarize|release)
        say "Signing with Developer ID + hardened runtime"
        codesign --force --options runtime \
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
    ZIP="build/AgentController.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$BUILD_DIR" "$ZIP"

    # Capture notarytool output so we can confirm Apple actually Accepted the build
    # before stapling. --wait blocks until the submission reaches a terminal state.
    NOTARY_OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
    printf '%s\n' "$NOTARY_OUT"
    rm -f "$ZIP"

    if ! printf '%s\n' "$NOTARY_OUT" | grep -Eq 'status:[[:space:]]*Accepted'; then
        die "Notarization did not reach 'status: Accepted'. Aborting before staple.
       Inspect the submission with:
         xcrun notarytool log <submission-id> --keychain-profile '$NOTARY_PROFILE'"
    fi

    say "Stapling notarization ticket"
    xcrun stapler staple "$BUILD_DIR"
fi

# --- Distributable DMG -------------------------------------------------------
# Built for the distribution modes (release / --skip-notarize), skipped for the
# fast --dev iteration loop. In release the DMG is itself signed + notarized +
# stapled — that is what lets it open with NO Gatekeeper warning on any Mac.
if [ "$MODE" != "--dev" ]; then
    say "Building DMG ($DMG)"
    STAGING="build/dmg-staging"
    rm -rf "$STAGING" "$DMG"
    mkdir -p "$STAGING"
    cp -R "$BUILD_DIR" "$STAGING/AgentController.app"
    ln -s /Applications "$STAGING/Applications"     # drag-to-install target
    hdiutil create -volname "AgentController $VERSION" \
        -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGING"

    # Sign the DMG wrapper in both distribution modes (the final message says
    # "signed" — make that true for --skip-notarize too, not just release).
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
    if [ "$MODE" = "release" ]; then
        say "Notarizing DMG (1-3 min)"
        DMG_NOTARY_OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
        printf '%s\n' "$DMG_NOTARY_OUT"
        printf '%s\n' "$DMG_NOTARY_OUT" | grep -Eq 'status:[[:space:]]*Accepted' \
            || die "DMG notarization did not reach 'status: Accepted'. Aborting before staple."
        xcrun stapler staple "$DMG"
        say "Verifying stapled DMG (Gatekeeper)"
        spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | head -3 || true
    fi
fi

say "Installing to /Applications"
rm -rf /Applications/AgentController.app
cp -R "$BUILD_DIR" /Applications/
xattr -cr /Applications/AgentController.app

say "Deploying resilient MCP bridge to ~/.agentcontroller/"
mkdir -p ~/.agentcontroller
chmod 700 ~/.agentcontroller
cp Scripts/agentcontroller-mcp-bridge.sh ~/.agentcontroller/agentcontroller-mcp-bridge.sh
chmod 700 ~/.agentcontroller/agentcontroller-mcp-bridge.sh

say "Launching"
# Launch by path, not `open -a AgentController`: LaunchServices hasn't necessarily
# indexed the just-copied bundle by name yet, which makes `-a` fail on a fresh install.
open "/Applications/AgentController.app"

sleep 1
say "Verification"
codesign -dvv /Applications/AgentController.app 2>&1 | grep -E "Identifier|TeamIdentifier|Authority|flags" || true
if [ "$MODE" = "release" ]; then
    spctl -a -vvv /Applications/AgentController.app 2>&1 | head -5 || true
fi
pgrep -fl AgentController || echo "(not running — check Console for crash)"

printf '\n\033[1;32mDone.\033[0m First launch: grant Accessibility + Screen Recording once; they persist forever with Team ID U4VYZ8CUN9.\n'
if [ "$MODE" != "--dev" ] && [ -f "$DMG" ]; then
    if [ "$MODE" = "release" ]; then
        printf '\033[1;32mDistributable:\033[0m %s  (signed + notarized + stapled — ships anywhere)\n' "$DMG"
    else
        printf '\033[1;33mDistributable:\033[0m %s  (signed, NOT notarized — for local testing; use `./build.sh` for a notarized DMG)\n' "$DMG"
    fi
fi
