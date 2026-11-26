#!/usr/bin/env bash
# Rebuilds staging/ for the LTLO install: the packaged mod with the hard-coded tunables
# from sidecars/LeaveTheLightsOff.omw2mwse.toml exposed in an MCM.
# Running this script is the developer's confirmation of the hard-code warning it prints.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/reference/openmw_original_exact"
rm -rf "$ROOT/staging/LTLOHandportMigration"   # no save migration, ever (Dej)
"$ROOT/bin/omw2mwse" package "$SRC" --name LeaveTheLightsOff --title "Leave The Lights Off" \
  --out "$ROOT/staging/LeaveTheLightsOff" --force \
  --sidecar "$ROOT/sidecars/LeaveTheLightsOff.omw2mwse.toml" --accept-hardcode-conversions
(cd "$ROOT/staging" && find . -type f ! -name '.omw2mwse-output' ! -name SHA256SUMS.txt -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.txt)
echo "staging ready: $ROOT/staging"
