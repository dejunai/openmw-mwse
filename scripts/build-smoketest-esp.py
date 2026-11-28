#!/usr/bin/env python3
"""Build the DEV-ONLY fixture plugin for omwcompat_smoketest from its JSON source.

  smoketest/esp/omwc_smoketest.esp.json  --tes3conv-->  OMWC_SmokeTest_DEV.esp

The JSON is the source of truth (tes3conv JSON, UTF-8, LF). tes3conv is found, in order, from
--tes3conv, $TES3CONV, a conflict-tools checkout (--conflict-tools DIR, $CONFLICT_TOOLS, or any
parent folder holding tools/tes3conv/tes3conv.exe), then PATH. The build is reproducible: the same
JSON and tes3conv give a byte-identical .esp (the SHA-256 is printed). --check also converts the
plugin back and compares it with the JSON (record order and flag order are normalised).

Before tes3conv runs, every fixed-size TES3 field is checked against the Construction Set buffer
(FNAM and record ids are 32 bytes including the NUL, so 31 characters; cell names are 64 including
NUL). An overflow fails the build: the CS would otherwise truncate and warn "Chunk size N too big".

Written for omwcompat by dej (dejunai). MIT. Python 3.9+.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "smoketest", "esp", "omwc_smoketest.esp.json")
ESP_NAME = "OMWC_SmokeTest_DEV.esp"

# Construction Set fixed-size buffers, in bytes including the trailing NUL.
# A string may be at most (limit - 1) bytes. The file format itself is a zstring
# of any length; the CS truncates (and warns) when a plugin exceeds these.
ID_LIMIT = 32            # record id (NAME) for every object we emit
FNAM_LIMIT = 32          # display name (FNAM) for ACTI, LIGH, CLOT, ARMO, NPC, STAT, ...
CELL_NAME_LIMIT = 64     # interior cell name (CELL NAME subrecord)
REGION_LIMIT = 32        # region id (RGNN) in a cell
HEADER_AUTHOR_LIMIT = 32
HEADER_DESC_LIMIT = 256

# Cell rules learned in game (omwcompat smoke test, 0.1.1 run):
#  - every cell needs a fog density of at least MIN_FOG_DENSITY (zero fog breaks some mods and shaders);
#  - a cell that behaves like an exterior needs a region: weather, sounds and many mods read the region
#    without a nil guard, and with no region the weather has nothing to follow;
#  - such a cell is drawn with water at WHGT even without the "has water" flag, so with no water wanted
#    the height must sit far below the floor (MAX_DRY_WATER_HEIGHT or lower) instead of at 0.
MIN_FOG_DENSITY = 0.01
MAX_DRY_WATER_HEIGHT = -1024.0

# Record types we emit (or may add later) that carry a FNAM display name.
FNAM_TYPES = frozenset({
    "Activator", "Light", "Clothing", "Armor", "Npc", "Static",
})


def find_tes3conv(explicit, conflict_tools):
    cands = [explicit, os.environ.get("TES3CONV")]
    for ct in (conflict_tools, os.environ.get("CONFLICT_TOOLS")):
        if ct:
            cands.append(os.path.join(ct, "tools", "tes3conv", "tes3conv.exe"))
            cands.append(os.path.join(ct, "tools", "tes3conv", "tes3conv"))
    here = ROOT
    for _ in range(4):
        cands.append(os.path.join(here, "tools", "tes3conv", "tes3conv.exe"))
        here = os.path.dirname(here)
    cands.append(shutil.which("tes3conv"))
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return None


def run(exe, src, dst):
    p = subprocess.run([exe, src, dst], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if p.returncode != 0:
        raise SystemExit("tes3conv failed (%d): %s" % (p.returncode, p.stderr.strip()))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def norm(records):
    def fix(v):
        if isinstance(v, dict):
            return {k: (" | ".join(sorted(x.strip() for x in x2.split("|"))) if k == "flags" and isinstance(x2, str) and x2 else fix(x2))
                    for k, x2 in v.items()}
        if isinstance(v, list):
            return [fix(x) for x in v]
        return v
    out = [fix(r) for r in records]
    out.sort(key=lambda r: (r["type"], str(r.get("id", r.get("name", "")))))
    return out


def zlen(s):
    """Bytes a TES3 zstring occupies (UTF-8 content plus the trailing NUL)."""
    if s is None:
        return 1
    if not isinstance(s, str):
        s = str(s)
    return len(s.encode("utf-8")) + 1


def _overflow(errors, rec, field, value, limit):
    typ = rec.get("type", "?")
    ident = rec.get("id") or rec.get("name") or typ
    n = zlen(value)
    if n > limit:
        errors.append(
            "%s %s %s: %d bytes including NUL, limit is %d (%r)"
            % (typ, ident, field, n, limit, value)
        )


def validate(records):
    """Return overflow messages (empty if every fixed-size field fits)."""
    errors = []
    if not isinstance(records, list):
        return ["plugin JSON must be a list of records"]
    for rec in records:
        if not isinstance(rec, dict):
            errors.append("record is not an object: %r" % (rec,))
            continue
        typ = rec.get("type")
        if typ == "Header":
            if "author" in rec:
                _overflow(errors, rec, "author", rec["author"], HEADER_AUTHOR_LIMIT)
            if "description" in rec:
                _overflow(errors, rec, "description", rec["description"], HEADER_DESC_LIMIT)
            continue
        if typ == "Cell":
            if "name" in rec:
                _overflow(errors, rec, "name", rec["name"], CELL_NAME_LIMIT)
            for ref in rec.get("references") or []:
                if isinstance(ref, dict) and "id" in ref:
                    _overflow(errors, rec, "reference id", ref["id"], ID_LIMIT)
            errors.extend(validate_cell(rec))
            continue
        if "id" in rec:
            _overflow(errors, rec, "id", rec["id"], ID_LIMIT)
        # STAT (and similar) may omit FNAM; only check a name that is actually present.
        if typ in FNAM_TYPES or "name" in rec:
            if "name" in rec:
                _overflow(errors, rec, "name (FNAM)", rec["name"], FNAM_LIMIT)
    return errors


def _cell_flags(rec):
    flags = (rec.get("data") or {}).get("flags") or ""
    return {f.strip() for f in str(flags).split("|") if f.strip()}


def validate_cell(rec):
    """Return messages for cell rules (fog, region, water); see MIN_FOG_DENSITY above."""
    errors = []
    name = rec.get("name") or "(exterior cell)"
    flags = _cell_flags(rec)
    atmo = rec.get("atmosphere_data")
    if atmo is not None or "IS_INTERIOR" in flags:
        fog = atmo.get("fog_density") if isinstance(atmo, dict) else None
        if not isinstance(fog, (int, float)) or isinstance(fog, bool) or fog < MIN_FOG_DENSITY:
            errors.append("Cell %s: fog density %r is below the minimum %s (every cell needs fog)" % (name, fog, MIN_FOG_DENSITY))
    if "BEHAVES_LIKE_EXTERIOR" in flags:
        region = rec.get("region")
        if not isinstance(region, str) or not region.strip():
            errors.append("Cell %s: behaves like an exterior but has no region (mods read it without a nil guard)" % name)
        else:
            _overflow(errors, rec, "region", region, REGION_LIMIT)
        wh = rec.get("water_height")
        if "HAS_WATER" not in flags and (not isinstance(wh, (int, float)) or wh > MAX_DRY_WATER_HEIGHT):
            errors.append("Cell %s: no water wanted, but water_height %r is above %s (it is still drawn in a cell that behaves like an exterior)"
                          % (name, wh, MAX_DRY_WATER_HEIGHT))
    return errors


def require_fits(records):
    errors = validate(records)
    if errors:
        raise SystemExit(
            "TES3 field overflow (the Construction Set will truncate):\n  " + "\n  ".join(errors)
        )


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(ROOT, "build-smoketest"), help="output folder (default build-smoketest/)")
    ap.add_argument("--tes3conv")
    ap.add_argument("--conflict-tools")
    ap.add_argument("--check", action="store_true", help="also convert back and compare with the JSON")
    a = ap.parse_args(argv)
    exe = find_tes3conv(a.tes3conv, a.conflict_tools)
    if not exe:
        raise SystemExit("tes3conv not found: pass --tes3conv, set TES3CONV, or use --conflict-tools DIR (tools/tes3conv/tes3conv.exe)")
    with open(SRC, "r", encoding="utf-8") as f:
        data = json.load(f)
    require_fits(data)
    os.makedirs(a.out, exist_ok=True)
    esp = os.path.join(a.out, ESP_NAME)
    run(exe, SRC, esp)
    digest = sha256(esp)
    print("tes3conv: %s" % exe)
    print("built %s (%d bytes) sha256 %s" % (esp, os.path.getsize(esp), digest))
    if a.check:
        with tempfile.TemporaryDirectory() as td:
            esp2 = os.path.join(td, "again.esp")
            run(exe, SRC, esp2)
            if sha256(esp2) != digest:
                raise SystemExit("NOT reproducible: a second build differs")
            back = os.path.join(td, "back.json")
            run(exe, esp, back)
            with open(back, "r", encoding="utf-8") as f:
                rt = json.load(f)
        require_fits(rt)
        if norm(rt) != norm(data):
            raise SystemExit("round trip differs from the JSON")
        print("check ok: reproducible, round trip equals the JSON")
    return 0


if __name__ == "__main__":
    sys.exit(main())
