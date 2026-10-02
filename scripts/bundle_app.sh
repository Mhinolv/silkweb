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
