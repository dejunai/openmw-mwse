#!/usr/bin/env bash
# Build a Vortex-installable .7z of the mwsuite conversion of Leave The Lights Off 3.2.
#
# Source is the official Nexus zip, extracted at
#   corpus/leave-the-lights-off/_archive/full/LeaveTheLightsOff
# (untracked; see corpus/leave-the-lights-off/_SOURCE.txt).
#
# The complete original OpenMW package is placed at
#   Off/LeaveTheLightsOff/OpenMW/<author relative paths>
# by omw2mwse package (this is the permanent tool layout, not an archive-only choice).
# The 3.2 zip is a loose folder, not a FOMOD; there are no installer options, so the
# whole package is converted (scripts, meshes including official dlr/ and rr/ off99,
# textures, ui_debugWidget.lua).
#
# Usage:
#   scripts/package-ltlo-archive.sh
#   SRC=/path/to/LeaveTheLightsOff scripts/package-ltlo-archive.sh
# Output:
#   dist-archives/mwsuite - OpenMW - Leave The Lights Off <omwcompat version>.7z
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SRC:-$ROOT/corpus/leave-the-lights-off/_archive/full/LeaveTheLightsOff}"
MESH_SRC="${MESH_SRC:-$SRC/meshes}"
WORK="$ROOT/build-ltlo-archive"
# the archive is named for the omwcompat runtime it is built for (BUILT_FOR in main.lua)
RT_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/runtime/MWSE/lib/omwcompat/manifest.json")"
OUT_NAME="mwsuite - OpenMW - Leave The Lights Off $RT_VERSION"
ARCHIVE_DIR="$ROOT/dist-archives"
ARCHIVE="$ARCHIVE_DIR/$OUT_NAME.7z"
SIDECAR="$ROOT/sidecars/LeaveTheLightsOff.omw2mwse.toml"

for p in "$SRC/scripts/LeaveTheLightsOff/LTLO_g.lua" "$SRC/LeaveTheLightsOff.omwscripts" "$SIDECAR"; do
  if [[ ! -f "$p" ]]; then
    echo "missing required file: $p" >&2
    exit 1
  fi
done
if [[ ! -d "$MESH_SRC" ]]; then
  echo "MESH_SRC is not a directory: $MESH_SRC" >&2
  exit 1
fi

rm -rf "$WORK"
PKG="$WORK/pkg"
STAGE="$WORK/stage"
mkdir -p "$ARCHIVE_DIR"

"$ROOT/bin/omw2mwse" package "$SRC" --name LeaveTheLightsOff --title "Leave The Lights Off" \
  --out "$PKG" --force \
  --sidecar "$SIDECAR" --accept-hardcode-conversions \
  --meshes-from "$MESH_SRC"

# Vortex-installable layout: Data Files contents at the archive root
mkdir -p "$STAGE"
cp -a "$PKG/Data Files/." "$STAGE/"
# helpful sidecar docs at the archive root (not under Off/)
if [[ -f "$PKG/OMW2MWSE-REPORT.md" ]]; then
  cp -a "$PKG/OMW2MWSE-REPORT.md" "$STAGE/"
fi
if [[ -f "$PKG/MESH-ALIASES.txt" ]]; then
  cp -a "$PKG/MESH-ALIASES.txt" "$STAGE/"
fi

rm -f "$ARCHIVE"
(cd "$STAGE" && 7z a -t7z -mx=9 "$ARCHIVE" .) >/dev/null
sha256sum "$ARCHIVE" | tee "$ARCHIVE.sha256"
echo "archive: $ARCHIVE"
echo "size:    $(wc -c < "$ARCHIVE") bytes"
