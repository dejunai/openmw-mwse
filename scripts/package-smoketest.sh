#!/usr/bin/env bash
# Package the smoke test as two Vortex-installable .7z archives (Data Files contents at the archive root):
#   dist-archives/mwsuite - OpenMW - Smoke Test <version>.7z           the MWSE mod (no plugin)
#   dist-archives/mwsuite - OpenMW - Smoke Test DEV cell <version>.7z  OMWC_SmokeTest_DEV.esp only (dev-only)
# plus SHA256SUMS-smoketest.txt. Needs tes3conv for the plugin (see scripts/build-smoketest-esp.py).
# Files come from the git tree (LF), so a Windows checkout with autocrlf does not matter if run from git blobs.
# Usage: scripts/package-smoketest.sh [--tes3conv EXE | --conflict-tools DIR]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/^local C = { VERSION = "\([^"]*\)" }.*/\1/p' "$ROOT/smoketest/MWSE/mods/mwsuite/openmw/omwcompat_smoketest/checks.lua")"
OUT="$ROOT/dist-archives"
WORK="$ROOT/build-smoketest"
rm -rf "$WORK/mod" "$WORK/dev"
mkdir -p "$OUT" "$WORK/mod" "$WORK/dev"
# the mod: every file from the git tree
(cd "$ROOT" && git archive HEAD smoketest/MWSE | tar -x -C "$WORK/mod" --strip-components=1)
python3 "$ROOT/scripts/build-smoketest-esp.py" --out "$WORK/esp" --check "$@"
cp "$WORK/esp/OMWC_SmokeTest_DEV.esp" "$WORK/dev/"
MOD="$OUT/mwsuite - OpenMW - Smoke Test $VERSION.7z"
DEV="$OUT/mwsuite - OpenMW - Smoke Test DEV cell $VERSION.7z"
rm -f "$MOD" "$DEV"
find "$WORK/mod" "$WORK/dev" -exec touch -d "2026-01-01 00:00:00" {} +
(cd "$WORK/mod" && 7z a -t7z -mx=9 -mtm=off -mtc=off -mta=off "$MOD" . >/dev/null)
(cd "$WORK/dev" && 7z a -t7z -mx=9 -mtm=off -mtc=off -mta=off "$DEV" . >/dev/null)
(cd "$OUT" && sha256sum "$(basename "$MOD")" "$(basename "$DEV")" > SHA256SUMS-smoketest.txt)
(cd "$WORK" && find mod dev -type f -print0 | sort -z | xargs -0 sha256sum > "$OUT/SHA256SUMS-smoketest-files.txt")
echo "built:"; cat "$OUT/SHA256SUMS-smoketest.txt"
