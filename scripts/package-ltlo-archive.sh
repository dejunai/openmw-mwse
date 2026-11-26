#!/usr/bin/env bash
# Build a Vortex-installable .7z of the mwsuite conversion of Leave The Lights Off 3.1.
#
# The complete original OpenMW package is placed at
#   Off/LeaveTheLightsOff/OpenMW/<author relative paths>
# by omw2mwse package (this is the permanent tool layout, not an archive-only choice).
#
# Reconstruction sources (on the box):
#   reference/openmw_original_exact  -- byte-exact LTLO_g.lua and .omwscripts
#   reference/openmw_original/lantern_off99_compat.yaml
#   $MESH_SRC                        -- off99 meshes copied from the hand-port backup
#
# Usage:
#   MESH_SRC=/path/to/meshes scripts/package-ltlo-archive.sh
# Output:
#   dist-archives/mwsuite - OpenMW - Leave The Lights Off 0.2.1.7z
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MESH_SRC="${MESH_SRC:-$ROOT/../ltlo-off99-meshes}"
WORK="$ROOT/build-ltlo-archive"
OUT_NAME="mwsuite - OpenMW - Leave The Lights Off 0.2.1"
ARCHIVE_DIR="$ROOT/dist-archives"
ARCHIVE="$ARCHIVE_DIR/$OUT_NAME.7z"

EXACT="$ROOT/reference/openmw_original_exact"
YAML="$ROOT/reference/openmw_original/lantern_off99_compat.yaml"
SIDECAR="$ROOT/sidecars/LeaveTheLightsOff.omw2mwse.toml"

for p in "$EXACT/scripts/LeaveTheLightsOff/LTLO_g.lua" "$EXACT/LeaveTheLightsOff.omwscripts" "$YAML" "$SIDECAR"; do
  if [[ ! -f "$p" ]]; then
    echo "missing required file: $p" >&2
    exit 1
  fi
done
if [[ ! -d "$MESH_SRC" ]]; then
  echo "MESH_SRC is not a directory: $MESH_SRC" >&2
  echo "Copy the hand-port backup meshes there (vanilla, dlr, rr off99) and re-run." >&2
  exit 1
fi

rm -rf "$WORK"
SRC="$WORK/src"
PKG="$WORK/pkg"
STAGE="$WORK/stage"
mkdir -p "$SRC" "$ARCHIVE_DIR"

# exact tree already has the author's relative paths (scripts/..., .omwscripts)
cp -a "$EXACT/." "$SRC/"
rm -f "$SRC/_SOURCE.txt"
mkdir -p "$SRC/scripts/MaxYari/animated_lanterns/configs"
install -m 644 "$YAML" "$SRC/scripts/MaxYari/animated_lanterns/configs/lantern_off99_compat.yaml"

# Original-package meshes: backup files at the meshes root (and any non-dlr/non-rr
# subfolders). dlr/ and rr/ off99 meshes are used only as alias sources -- they
# likely come from Darknut / RR replacers, not OwnlyMe's 3.1 zip.
mkdir -p "$SRC/meshes"
if [[ -d "$MESH_SRC" ]]; then
  # copy everything except dlr/ and rr/ into the reconstructed original package
  find "$MESH_SRC" -type f \( -iname '*.nif' -o -iname '*.kf' -o -iname '*.dds' \) -print0 |
    while IFS= read -r -d '' f; do
      rel="${f#"$MESH_SRC"/}"
      case "$rel" in
        dlr/*|rr/*|dlr\\*|rr\\*) continue ;;
      esac
      mkdir -p "$SRC/meshes/$(dirname "$rel")"
      install -m 644 "$f" "$SRC/meshes/$rel"
    done
fi

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
if [[ -f "$ROOT/docs/LTLO-ORIGINAL-PACKAGE-GAPS.md" ]]; then
  cp -a "$ROOT/docs/LTLO-ORIGINAL-PACKAGE-GAPS.md" "$STAGE/ORIGINAL-PACKAGE-GAPS.md"
fi

rm -f "$ARCHIVE"
(cd "$STAGE" && 7z a -t7z -mx=9 "$ARCHIVE" .) >/dev/null
sha256sum "$ARCHIVE" | tee "$ARCHIVE.sha256"
echo "archive: $ARCHIVE"
echo "size:    $(wc -c < "$ARCHIVE") bytes"
