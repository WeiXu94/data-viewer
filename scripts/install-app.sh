#!/usr/bin/env bash
set -euo pipefail

# Build DataViewer.app, install it to a LaunchServices-visible location, and
# register + enable the Quick Look preview extension. Run this whenever you
# change the app or the extension and want the new build active in Finder
# Quick Look (Space-bar preview).
#
# Install location defaults to /Applications (you're an admin, so no sudo
# needed). Override with INSTALL_DIR, e.g.
#   INSTALL_DIR="$HOME/Applications" ./scripts/install-app.sh
# Keep ONLY ONE copy installed: two bundles sharing the same id collide in
# LaunchServices and only one (the higher-ranked domain) registers its Quick
# Look extension. Do NOT install into .build/ — it is a hidden dir pkd skips.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="DataViewer.app"
BUILT="$ROOT/.build/app/$APP_NAME"        # where build-app.sh writes the bundle
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
DEST="$INSTALL_DIR/$APP_NAME"
PLUGIN_ID="com.weixu.DataViewer.QuickLookExtension"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# 1. Build the .app bundle (streams build output to the terminal).
echo "==> Building..."
"$ROOT/scripts/build-app.sh" >/dev/null
echo "    built: $BUILT"

# 2. Quit any running instance so the bundle can be replaced cleanly.
osascript -e 'tell application "DataViewer" to quit' >/dev/null 2>&1 || true

# 3. Install into a LaunchServices-visible location.
echo "==> Installing to $DEST"
mkdir -p "$INSTALL_DIR"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"

# Drop the intermediate build artifact so exactly one bundle exists on disk:
# a leftover .build/ copy shares the same bundle id and clutters LaunchServices.
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true
rm -rf "$BUILT"

# 4. Register with LaunchServices, launch once (hidden) so pkd scans the
#    embedded appex, then enable the extension and quit the app again.
echo "==> Registering + enabling Quick Look extension..."
"$LSREGISTER" -f "$DEST"
open -g -j "$DEST"
sleep 2
pluginkit -e use -i "$PLUGIN_ID" >/dev/null 2>&1 || true
osascript -e 'tell application "DataViewer" to quit' >/dev/null 2>&1 || true

# 5. Verify the extension is registered (leading '+' = enabled).
echo "==> Status:"
if pluginkit -m -A -v -i "$PLUGIN_ID" 2>/dev/null | grep -q "$PLUGIN_ID"; then
    pluginkit -m -A -v -i "$PLUGIN_ID"
    echo
    echo "Done. In Finder, select a .dta/.rds/.mat file and press Space."
else
    echo "ERROR: extension not registered. Check codesign entitlements:" >&2
    echo "  codesign -d --entitlements - \"$DEST/Contents/PlugIns/DataViewerQuickLookExtension.appex\"" >&2
    exit 1
fi
