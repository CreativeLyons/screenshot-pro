#!/bin/bash
# Build "Screenshot Pro.app" (arm64) from the Swift package and sign it.
#
#   scripts/build-app.sh              release build into build/
#   CONFIG=debug scripts/build-app.sh
#   SIGN_IDENTITY="Apple Development: ..." scripts/build-app.sh
#
# Signing: a stable identity keeps the Screen Recording permission across rebuilds
# (macOS ties the grant to the code signature). The first "Apple Development" identity
# in the keychain is used when SIGN_IDENTITY is unset; ad hoc ("-") is the fallback,
# which means re-granting Screen Recording after every rebuild.
#
# The bundle is updated in place (no deletes), so files removed from Resources/ linger
# in build/ until you clear that folder yourself.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="Screenshot Pro"
EXEC="ScreenshotPro"
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c "$CONFIG" --arch arm64 --product "$EXEC"
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

APP="build/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC" "$APP/Contents/MacOS/$EXEC"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUM/" Resources/Info.plist > "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    --identifier com.creativelyons.ScreenshotPro "$APP"
codesign --verify --strict "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/$EXEC"), signed with: $SIGN_IDENTITY)"
