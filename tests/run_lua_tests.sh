#!/usr/bin/env bash
# Runs the LuaJIT mock tests against the packaged output in staging/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TESTS_DIR="$ROOT/tests/lua"
STAGE="$ROOT/staging/LeaveTheLightsOff"
if [ ! -d "$STAGE" ]; then
  "$ROOT/bin/omw2mwse" package "$ROOT/reference/openmw_original_exact" --name LeaveTheLightsOff --out "$STAGE"
fi
status=0
for t in "$ROOT"/tests/lua/test_*.lua; do
  echo "### $(basename "$t")"
  (cd "$STAGE" && luajit "$t") || status=1
done
exit $status
