#!/usr/bin/env bash
# Runs the LuaJIT mock tests against the packaged output in staging/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TESTS_DIR="$ROOT/tests/lua"
STAGE="$ROOT/staging/LeaveTheLightsOff"
# (re)build the local test staging when it is missing or its runtime differs from runtime/
if [ ! -d "$STAGE" ] || ! diff -rq "$ROOT/runtime/MWSE/lib" "$STAGE/Data Files/MWSE/lib" >/dev/null 2>&1; then
  "$ROOT/scripts/build-staging.sh" >/dev/null 2>&1
fi
status=0
for t in "$ROOT"/tests/lua/test_*.lua; do
  echo "### $(basename "$t")"
  (cd "$STAGE" && luajit "$t") || status=1
done
echo "### corpus settings probe"
python3 "$ROOT/tests/corpus_settings.py" || status=1
exit $status
