#!/bin/sh
# Wrap the SwiftPM binary into build/Silkweb.app so it launches like a normal Mac app.
# Usage: scripts/bundle_app.sh [debug|release] [out-dir]   (default debug; release is what scripts/release.sh ships)
#   out-dir defaults to build. #276: tests pass a private folder, so a build or suite at the same time never deletes
#   the bundle that they read.
set -e
CONFIG="${1:-debug}"
OUT="${2:-build}"
BIN=".build/$CONFIG/Silkweb"
APP="$OUT/Silkweb.app"
# Bundle identifiers (#249); SilkwebCore's BundleIdentity and scripts/Info.plist say the same.
APP_ID="io.github.mhinolv.silkweb"
HELPER_ID="io.github.mhinolv.silkweb.helper"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Silkweb"
cp -R ".build/$CONFIG/Silkweb_Silkweb.bundle" "$APP/Contents/Resources/"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/Silkweb.icns "$APP/Contents/Resources/Silkweb.icns"
codesign --force -s - -i "$APP_ID" "$APP"
echo "bundled $APP ($CONFIG)"
# The agent-memory helper lives outside the app bundle so app updates can't break agent configs.
# Ad-hoc signed here; releases sign with Developer ID and notarize (docs/agent-memory.md).
HELPER="$OUT/helper/silkweb"
rm -rf "$OUT/helper"
mkdir -p "$OUT/helper"
cp ".build/$CONFIG/SilkwebHelper" "$HELPER"
codesign --force -s - -i "$HELPER_ID" "$HELPER"
echo "bundled $HELPER"
