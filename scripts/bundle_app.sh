#!/bin/sh
# Wrap the SwiftPM debug binary into build/Silkweb.app so it launches like a normal Mac app.
set -e
BIN=".build/debug/Silkweb"
APP="build/Silkweb.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Silkweb"
cp -R .build/debug/Silkweb_Silkweb.bundle "$APP/Contents/Resources/"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/Silkweb.icns "$APP/Contents/Resources/Silkweb.icns"
codesign --force -s - -i com.silkweb.app "$APP"
echo "bundled $APP"
# The agent-memory helper lives outside the app bundle so app updates can't break agent configs.
# Ad-hoc signed here; releases sign with Developer ID and notarize (docs/agent-memory.md).
HELPER="build/helper/silkweb"
rm -rf build/helper
mkdir -p build/helper
cp .build/debug/SilkwebHelper "$HELPER"
codesign --force -s - -i com.silkweb.helper "$HELPER"
echo "bundled $HELPER"
