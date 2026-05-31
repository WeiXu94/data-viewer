#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/app/DataViewer.app"
APPEX="$APP/Contents/PlugIns/DtaQuickLookPreview.appex"

swift build -c release --product DataViewer
swift build -c release --product DtaQuickLookPreview

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"
cp "$ROOT/.build/release/DataViewer" "$APP/Contents/MacOS/DataViewer"
cp "$ROOT/resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/resources/DataViewerIcon.icns" "$APP/Contents/Resources/DataViewerIcon.icns"
cp "$ROOT/.build/release/DtaQuickLookPreview" "$APPEX/Contents/MacOS/DtaQuickLookPreview"
cp "$ROOT/resources/DtaQuickLookPreview.appex/Info.plist" "$APPEX/Contents/Info.plist"

codesign --force --sign - "$APPEX" >/dev/null
codesign --force --sign - "$APP" >/dev/null

echo "$APP"
