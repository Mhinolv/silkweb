#!/bin/sh
# Swift formatting with the toolchain's swift-format and the repo's .swift-format config.
# CI runs the --check form. Usage: scripts/format.sh [--check]
#   (no args)  format Sources/ and Tests/ in place
#   --check    strict lint; exit 0 clean, 1 violations, 2 swift-format missing or bad argument
cd "$(dirname "$0")/.."
case "$1" in
  "" | --check) ;;
  *) echo "usage: scripts/format.sh [--check]" >&2; exit 2 ;;
esac
if [ $# -gt 1 ]; then echo "usage: scripts/format.sh [--check]" >&2; exit 2; fi

SWIFT_FORMAT=$(xcrun --find swift-format 2>/dev/null) || SWIFT_FORMAT=$(command -v swift-format)
if [ -z "$SWIFT_FORMAT" ] || [ ! -x "$SWIFT_FORMAT" ]; then
  echo "swift-format not found — install Xcode 16+ or the Swift 6 toolchain." >&2
  exit 2
fi

if [ "$1" = "--check" ]; then
  if "$SWIFT_FORMAT" lint --strict --recursive --parallel --configuration .swift-format Sources Tests; then
    echo "Format check passed."
  else
    echo "Format check failed — run ./scripts/format.sh and commit the result." >&2
    exit 1
  fi
else
  "$SWIFT_FORMAT" format --in-place --recursive --parallel --configuration .swift-format Sources Tests || exit 1
  echo "Formatted Sources/ and Tests/."
fi
