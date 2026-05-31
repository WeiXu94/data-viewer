#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/app/DataViewer.app"

# Build main app with SwiftPM
swift build -c release --product DataViewer

# Build Quick Look extension with Xcode (SwiftPM can't produce a pluginkit-compatible appex)
SIGNING_IDENTITY="Apple Development: weixu1026@gmail.com (UDW746L7RQ)"
xcodebuild -project "$ROOT/quicklook/DataViewerQuickLookExtension.xcodeproj" \
           -scheme DataViewerQuickLookExtension \
           -configuration Release \
           -derivedDataPath "$ROOT/.build/xcode" \
           ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
           CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
           CODE_SIGN_STYLE=Manual \
           build >/dev/null

# Assemble app bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"

cp "$ROOT/.build/release/DataViewer" "$APP/Contents/MacOS/DataViewer"
cp "$ROOT/resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/resources/DataViewerIcon.icns" "$APP/Contents/Resources/DataViewerIcon.icns"

# Copy Xcode-built appex
cp -R "$ROOT/.build/xcode/Build/Products/Release/DataViewerQuickLookExtension.appex" \
      "$APP/Contents/PlugIns/"

# Sign the outer app with the Apple Development identity (ad-hoc won't register
# with pluginkit). Do NOT re-sign the appex: xcodebuild already signed it WITH
# its App Sandbox entitlement, and signing the app without --deep only records
# the appex's existing code identity, leaving its signature/entitlements intact.
# Re-signing the appex here (or adding --deep) would strip the sandbox
# entitlement and pkd would silently refuse to register the Quick Look extension.
codesign --force --sign "$SIGNING_IDENTITY" "$APP" >/dev/null

echo "$APP"
