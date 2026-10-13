#!/bin/sh
# Pack an app into a compressed, read-only disk image with an Applications shortcut (#249). hdiutil only: no
# artwork, no Finder scripting, so it runs the same on a headless CI runner. Finder shows its default layout.
# Usage: scripts/make_dmg.sh <Silkweb.app> <version> <out.dmg>
set -e
[ $# -eq 3 ] || { echo "usage: $0 <Silkweb.app> <version> <out.dmg>" >&2; exit 64; }
APP="$1"
VERSION="$2"
OUT="$3"
[ -d "$APP" ] || { echo "make_dmg: no app at $APP" >&2; exit 1; }
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/silkweb-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
# The image holds exactly these two items.
ditto "$APP" "$STAGE/Silkweb.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -quiet -volname "Silkweb $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
  -imagekey zlib-level=9 "$OUT"
hdiutil verify -quiet "$OUT"
echo "packed $OUT"
