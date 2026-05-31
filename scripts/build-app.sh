#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/app/DataViewer.app"

swift build -c release --product DataViewer

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/DataViewer" "$APP/Contents/MacOS/DataViewer"
cp "$ROOT/resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/resources/DataViewerIcon.icns" "$APP/Contents/Resources/DataViewerIcon.icns"

echo "$APP"
