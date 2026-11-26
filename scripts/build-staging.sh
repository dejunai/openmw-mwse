#!/usr/bin/env bash
# Rebuilds staging/ for the LTLO install: the packaged mod + the hand-port migration helper.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/reference/openmw_original_exact"
"$ROOT/bin/omw2mwse" package "$SRC" --name LeaveTheLightsOff --out "$ROOT/staging/LeaveTheLightsOff" --force
MIG="$ROOT/staging/LTLOHandportMigration"
rm -rf "$MIG"
mkdir -p "$MIG/Data Files/MWSE/mods/LTLOHandportMigration"
cp "$ROOT/migrations/ltlo-handport/MWSE/mods/LTLOHandportMigration/main.lua" "$MIG/Data Files/MWSE/mods/LTLOHandportMigration/main.lua"
cp "$ROOT/migrations/ltlo-handport/README.md" "$MIG/README.md"
(cd "$ROOT/staging" && find . -type f ! -name '.omw2mwse-output' ! -name SHA256SUMS.txt -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.txt)
echo "staging ready: $ROOT/staging"
