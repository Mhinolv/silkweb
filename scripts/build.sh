#!/bin/sh
# Canonical build: works in a normal shell and inside the agents' workspace-write sandbox.
# Caches live under .build/ (the sandbox can't write ~/.cache), and SwiftPM's own sandbox is
# disabled because nested sandboxing isn't permitted.
# Usage: scripts/build.sh [test [--serial | --filter <pattern> | <swift test options>] | release]
#   test with no options runs the full suite in two steps at the same time (#272): SilkwebCoreTests in
#   parallel, and SilkwebAppTests serially (they share real windows and settings, #213). --serial runs
#   everything in one serial process, as before #272. Any other option goes to `swift test` unchanged.
#   release builds the Release configuration into build/Silkweb.app (scripts/release.sh uses it, #249).
set -e
cd "$(dirname "$0")/.."
# Build and test only with the pinned toolchain (.toolchain-versions), the same one CI uses.
./scripts/check_toolchain.sh
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
FLAGS="--disable-sandbox --cache-path $PWD/.build/swiftpm-cache --config-path $PWD/.build/swiftpm-config --security-path $PWD/.build/swiftpm-security"
if [ "$1" = "test" ] && [ $# -eq 1 ]; then
  swift build --build-tests $FLAGS
  # Each run keeps its step files apart, so two suites in one checkout don't mix results.
  RUN_DIR=$(mktemp -d "$PWD/.build/test-run.XXXXXX")
  CORE_LOG=$RUN_DIR/core.log
  CORE_XML=$RUN_DIR/core.xml
  APP_LOG=$RUN_DIR/app.log
  start=$(date +%s)
  # Step 1, in the background: core tests in parallel. Both steps only read the built bundle, so they skip
  # SwiftPM's lock on .build. The per-test progress lines are dropped; failures print in full.
  (
    if swift test --skip-build --ignore-lock --parallel $FLAGS --filter '^SilkwebCoreTests\.' \
      --xunit-output "$CORE_XML" >"$CORE_LOG" 2>&1; then status=0; else status=$?; fi
    echo "$status $(($(date +%s) - start))" >"$CORE_LOG.status"
  ) &
  core_pid=$!
  trap 'kill $core_pid 2>/dev/null; rm -rf "$RUN_DIR"; exit 130' INT TERM
  # Step 2, at the same time: app tests serially, streamed as before.
  if swift test --skip-build --ignore-lock $FLAGS --filter '^SilkwebAppTests\.' 2>&1 | tee "$APP_LOG"; then :; fi
  app_seconds=$(($(date +%s) - start))
  wait $core_pid || true
  grep -v '^\[[0-9]*/[0-9]*\] Testing ' "$CORE_LOG" || true
  read -r core_status core_seconds <"$CORE_LOG.status" || core_status=1
  core_tests=$(sed -n 's/.*<testsuite name="TestResults".* tests="\([0-9]*\)".*/\1/p' "$CORE_XML" 2>/dev/null)
  core_failures=$(sed -n 's/.*<testsuite name="TestResults".* failures="\([0-9]*\)".*/\1/p' "$CORE_XML" 2>/dev/null)
  core_errors=$(sed -n 's/.*<testsuite name="TestResults".* errors="\([0-9]*\)".*/\1/p' "$CORE_XML" 2>/dev/null)
  [ -n "$core_failures" ] && core_failures=$((core_failures + ${core_errors:-0}))
  echo "core: ${core_tests:-0} tests, ${core_failures:-?} failures, ${core_seconds:-?} s (parallel)"
  # tee hides the exit status; XCTest's last summary line gives the result.
  summary=$(grep -E '^[[:space:]]*Executed [0-9]+ tests?, ' "$APP_LOG" | tail -1)
  app_tests=$(echo "$summary" | sed -n 's/.*Executed \([0-9]*\) test.*/\1/p')
  app_failures=$(echo "$summary" | sed -n 's/.* \([0-9]*\) failures\{0,1\} (.*/\1/p')
  echo "app: ${app_tests:-0} tests, ${app_failures:-?} failures, ${app_seconds} s (serial)"
  total=$((${core_tests:-0} + ${app_tests:-0}))
  failures=$((${core_failures:-0} + ${app_failures:-0}))
  echo "	 Executed $total tests, with $failures failures in $(($(date +%s) - start)) seconds (core parallel, app serial)"
  # A crash or a missing summary fails the run, as does any failing test.
  if [ "$core_status" -eq 0 ] && [ -n "$core_tests" ] && [ -n "$app_tests" ] && [ "$failures" -eq 0 ] \
    && grep -q "Test Suite 'Selected tests' passed" "$APP_LOG"; then result=0; else result=1; fi
  rm -rf "$RUN_DIR"
  exit $result
elif [ "$1" = "test" ]; then
  shift
  [ "$1" = "--serial" ] && shift
  swift test $FLAGS "$@"
elif [ "$1" = "release" ]; then
  swift build -c release $FLAGS
  ./scripts/bundle_app.sh release
else
  swift build $FLAGS
  ./scripts/bundle_app.sh
fi
