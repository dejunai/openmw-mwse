#!/usr/bin/env bash
# Runs the LuaJIT mock tests against the packaged output in staging/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TESTS_DIR="$ROOT/tests/lua"
STAGE="$ROOT/staging/LeaveTheLightsOff"
if [ ! -d "$STAGE" ]; then
  "$ROOT/scripts/build-staging.sh" 2>/dev/null
fi
status=0
for t in "$ROOT"/tests/lua/test_*.lua; do
  echo "### $(basename "$t")"
  (cd "$STAGE" && luajit "$t") || status=1
done
echo "### corpus settings probe"
python3 "$ROOT/tests/corpus_settings.py" || status=1
exit $status
