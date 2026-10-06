#!/bin/sh
# Verify the selected Xcode, Swift compiler and swift-format match .toolchain-versions.
# Usage: scripts/check_toolchain.sh [--format-only]
#   exit 0 = match, 1 = mismatch (message says what to select), 2 = tool missing
# Select a different Xcode without changing the machine-wide default:
#   DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer ./scripts/format.sh
cd "$(dirname "$0")/.."
want() { sed -n "s/^$1=//p" .toolchain-versions; }
fail=0
report() { echo "Toolchain mismatch: expected $1 $2; found ${3:-nothing}." >&2; fail=1; }

found_fmt=$(xcrun swift-format --version 2>/dev/null)
[ -n "$found_fmt" ] || { echo "swift-format not found in the selected Xcode ($(xcode-select -p 2>/dev/null))." >&2; exit 2; }
[ "$found_fmt" = "$(want swift_format)" ] || report swift-format "$(want swift_format)" "$found_fmt"

if [ "$1" != "--format-only" ]; then
  found_build=$(xcodebuild -version 2>/dev/null | sed -n 's/^Build version //p')
  [ "$found_build" = "$(want xcode_build)" ] || report "Xcode build" "$(want xcode_build) (Xcode $(want xcode))" "$found_build"
  found_swift=$(xcrun swift --version 2>/dev/null | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p' | head -1)
  [ "$found_swift" = "$(want swift)" ] || report Swift "$(want swift)" "$found_swift"
fi

if [ $fail -ne 0 ]; then
  echo "Selected developer directory: ${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)}" >&2
  echo "Select Xcode $(want xcode) (e.g. DEVELOPER_DIR=/Applications/Xcode_$(want xcode).app/Contents/Developer) or update .toolchain-versions deliberately." >&2
  exit 1
fi
echo "Toolchain OK: Xcode $(want xcode) ($(want xcode_build)), Swift $(want swift), swift-format $(want swift_format)."
