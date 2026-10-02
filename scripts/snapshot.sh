#!/bin/sh
# XCTest hosts production views offscreen; no app launch or GUI automation.
set -eu
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <out-dir> [scenario ...]" >&2
  exit 2
fi
case "$1" in
  /*) SILKWEB_SNAPSHOT_OUTPUT="$1" ;;
  *) SILKWEB_SNAPSHOT_OUTPUT="$PWD/$1" ;;
esac
shift
export SILKWEB_SNAPSHOT_OUTPUT
export SILKWEB_SNAPSHOT_SCENARIOS="$*"
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift test --disable-sandbox --cache-path "$PWD/.build/swiftpm-cache" --config-path "$PWD/.build/swiftpm-config" --security-path "$PWD/.build/swiftpm-security" --filter SnapshotHarnessTests/testRequestedScenarios
