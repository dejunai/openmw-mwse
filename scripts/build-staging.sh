#!/usr/bin/env bash
# Rebuilds staging/ for the LTLO install: the packaged official 3.2 mod with the
# hard-coded tunables from sidecars/LeaveTheLightsOff.omw2mwse.toml exposed in an MCM.
# Running this script is the developer's confirmation of the hard-code warning it prints.
#
# Requires the official 3.2 extract at
#   corpus/leave-the-lights-off/_archive/full/LeaveTheLightsOff
# (untracked; see that folder's _SOURCE.txt). The 3.1 reference tree stays in
# reference/openmw_original_exact/ for comparison only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC:-$ROOT/corpus/leave-the-lights-off/_archive/full/LeaveTheLightsOff}"
rm -rf "$ROOT/staging/LTLOHandportMigration"   # no save migration, ever (Dej)
"$ROOT/bin/omw2mwse" package "$SRC" --name LeaveTheLightsOff --title "Leave The Lights Off" \
  --out "$ROOT/staging/LeaveTheLightsOff" --force \
  --sidecar "$ROOT/sidecars/LeaveTheLightsOff.omw2mwse.toml" --accept-hardcode-conversions \
  --meshes-from "$SRC/meshes"
(cd "$ROOT/staging" && find . -type f ! -name '.omw2mwse-output' ! -name SHA256SUMS.txt -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.txt)
echo "staging ready: $ROOT/staging"
