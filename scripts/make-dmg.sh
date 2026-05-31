#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/resources/Info.plist")}"
BUILD_ARCHS="${BUILD_ARCHS:-arm64}"
ARCH_LABEL="${ARCH_LABEL:-${BUILD_ARCHS// /-}}"
APP="$ROOT/.build/app/DataViewer.app"
STAGING="$ROOT/.build/dmg/DataViewer"
DIST="$ROOT/.build/dist"
DMG="$DIST/DataViewer-v$VERSION-$ARCH_LABEL.dmg"

"$ROOT/scripts/build-app.sh" >/dev/null

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING" "$DIST"
cp -R "$APP" "$STAGING/DataViewer.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "DataViewer" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

echo "$DMG"
