#!/bin/sh
# Wrap the SwiftPM debug binary into build/Silkweb.app so it launches like a normal Mac app.
set -e
BIN=".build/debug/Silkweb"
APP="build/Silkweb.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Silkweb"
cp scripts/Info.plist "$APP/Contents/Info.plist"
codesign --force -s - -i com.silkweb.app "$APP"
echo "bundled $APP"
