#!/bin/sh
# Canonical build: works in a normal shell and inside the agents' workspace-write sandbox.
# Caches live under .build/ (the sandbox can't write ~/.cache), and SwiftPM's own sandbox is
# disabled because nested sandboxing isn't permitted. Usage: scripts/build.sh [test [--filter <pattern>]]
set -e
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
FLAGS="--disable-sandbox --cache-path $PWD/.build/swiftpm-cache --config-path $PWD/.build/swiftpm-config --security-path $PWD/.build/swiftpm-security"
if [ "$1" = "test" ]; then
  shift
  swift test $FLAGS "$@"
else
  swift build $FLAGS
  ./scripts/bundle_app.sh
fi
