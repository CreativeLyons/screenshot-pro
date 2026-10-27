#!/bin/bash
# Package "build/Screenshot Pro.app" into a drag-to-install disk image for a release.
#
#   scripts/make-dmg.sh               builds the app (ad hoc signed), then the DMG
#   SKIP_BUILD=1 scripts/make-dmg.sh  packages the app already in build/
#
# Writes build/ScreenshotPro-<version>-arm64.dmg with the app and an Applications link.
# Release builds are signed ad hoc: without a Developer ID the app is not notarized, so
# users approve it once in System Settings > Privacy & Security (see the README).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
APP="build/Screenshot Pro.app"
DMG="build/ScreenshotPro-$VERSION-arm64.dmg"

if [ -z "${SKIP_BUILD:-}" ]; then
    SIGN_IDENTITY="${SIGN_IDENTITY:--}" scripts/build-app.sh
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Screenshot Pro.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Screenshot Pro" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
echo "Wrote $DMG ($(du -h "$DMG" | cut -f1))"
