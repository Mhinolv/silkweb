#!/bin/sh
# Stress audit (#63): runs the full test suite repeatedly while `yes` processes keep most cores busy, then lists
# every failing assertion per run, so timing-sensitive tests surface in one pass instead of one CI run at a time.
# Usage: sh scripts/stress_test.sh [runs (default 5)] [load processes (default: cores - 1)] [log dir (default .build/stress)]
set -u
cd "$(dirname "$0")/.."
RUNS=${1:-5}
LOAD=${2:-$(($(sysctl -n hw.ncpu) - 1))}
LOGS=${3:-.build/stress}
mkdir -p "$LOGS"
PIDS=""
trap 'kill $PIDS 2>/dev/null' EXIT INT TERM
i=0
while [ "$i" -lt "$LOAD" ]; do
  yes > /dev/null &
  PIDS="$PIDS $!"
  i=$((i + 1))
done
echo "$LOAD load processes on $(sysctl -n hw.ncpu) cores, $RUNS full-suite runs, logs in $LOGS"
TOTAL=0
run=1
while [ "$run" -le "$RUNS" ]; do
  LOG="$LOGS/run-$run.log"
  ./scripts/build.sh test > "$LOG" 2>&1
  STATUS=$?
  FAILS=$(grep -c ': error: ' "$LOG")
  TOTAL=$((TOTAL + FAILS))
  echo "run $run: exit $STATUS, $FAILS failing assertions, $(grep -E '^[[:space:]]*Executed [0-9]+ tests' "$LOG" | tail -1 | sed 's/^[[:space:]]*//')"
  grep ': error: ' "$LOG" | sed 's|^.*/Tests/|  Tests/|'
  run=$((run + 1))
done
echo "total failing assertions: $TOTAL"
[ "$TOTAL" -eq 0 ]
