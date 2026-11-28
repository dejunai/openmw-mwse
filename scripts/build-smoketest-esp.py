#!/usr/bin/env python3
"""Build the DEV-ONLY fixture plugin for omwcompat_smoketest from its JSON source.

  smoketest/esp/omwc_smoketest.esp.json  --tes3conv-->  OMWC_SmokeTest_DEV.esp

The JSON is the source of truth (tes3conv JSON, UTF-8, LF). tes3conv is found, in order, from
--tes3conv, $TES3CONV, a conflict-tools checkout (--conflict-tools DIR, $CONFLICT_TOOLS, or any
parent folder holding tools/tes3conv/tes3conv.exe), then PATH. The build is reproducible: the same
JSON and tes3conv give a byte-identical .esp (the SHA-256 is printed). --check also converts the
plugin back and compares it with the JSON (record order and flag order are normalised).

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
        if norm(rt) != norm(data):
            raise SystemExit("round trip differs from the JSON")
        print("check ok: reproducible, round trip equals the JSON")
    return 0


if __name__ == "__main__":
    sys.exit(main())
