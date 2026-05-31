#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/app/DtaViewer.app"

swift build -c release --product DtaViewer

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/DtaViewer" "$APP/Contents/MacOS/DtaViewer"
cp "$ROOT/resources/Info.plist" "$APP/Contents/Info.plist"

echo "$APP"
