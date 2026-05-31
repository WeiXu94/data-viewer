#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/app/DataViewer.app"
BUILD_ARCHS="${BUILD_ARCHS:-arm64}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

read -r -a ARCH_FLAGS <<< "$BUILD_ARCHS"
SWIFT_ARCH_ARGS=()
for arch in "${ARCH_FLAGS[@]}"; do
    SWIFT_ARCH_ARGS+=(--arch "$arch")
done

# Build main app with SwiftPM
swift build -c release --product DataViewer "${SWIFT_ARCH_ARGS[@]}"
SWIFTPM_BINARY="$(swift build -c release --show-bin-path "${SWIFT_ARCH_ARGS[@]}")/DataViewer"

# Build Quick Look extension with Xcode (SwiftPM can't produce a pluginkit-compatible appex)
xcodebuild -project "$ROOT/quicklook/DataViewerQuickLookExtension.xcodeproj" \
           -scheme DataViewerQuickLookExtension \
           -configuration Release \
           -derivedDataPath "$ROOT/.build/xcode" \
           ARCHS="$BUILD_ARCHS" ONLY_ACTIVE_ARCH=NO \
           CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
           CODE_SIGN_STYLE=Manual \
           CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
           build >/dev/null

# Assemble app bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"

cp "$SWIFTPM_BINARY" "$APP/Contents/MacOS/DataViewer"
cp "$ROOT/resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/resources/DataViewerIcon.icns" "$APP/Contents/Resources/DataViewerIcon.icns"

# Copy Xcode-built appex
cp -R "$ROOT/.build/xcode/Build/Products/Release/DataViewerQuickLookExtension.appex" \
      "$APP/Contents/PlugIns/"

# Sign the outer app without --deep. The appex is already signed by xcodebuild
# with its sandbox entitlement; re-signing it here can strip that entitlement
# and make pkd silently refuse to register the Quick Look extension.
codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP" >/dev/null

echo "$APP"
