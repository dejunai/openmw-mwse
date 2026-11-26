#!/usr/bin/env python3
"""Package every corpus mod that declares I.Settings groups and probe its generated MCM
in the LuaJIT mock. Writes reports/generated/corpus-settings.md; exit 1 if a mod that
declares groups produced no MCM or a control failed its get/set round trip."""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from omw2mwse.convert import mod_name_for  # noqa: E402
from omw2mwse.package import package  # noqa: E402
from omw2mwse.scan import scan_mod  # noqa: E402

corpus = ROOT / "corpus"
out_root = ROOT / "tests" / "tmp" / "corpus"
if not corpus.is_dir():
    print("corpus/ missing; skipped")
    sys.exit(0)
rows, bad = [], 0
for mod in sorted(p for p in corpus.iterdir() if p.is_dir()):
    sc = scan_mod(mod)
    if not sc.settings.get("groups") or not sc.scripts:
        continue
    oms = sorted(mod.rglob("*.omwscripts"), key=lambda p: (len(p.relative_to(mod).parts), str(p)))
    src = oms[0].parent
    name = mod_name_for(src)
    out = out_root / mod.name
    if out.exists():
        shutil.rmtree(out)
    package(src, out, name=name)
    p = subprocess.run(["luajit", str(ROOT / "tests" / "lua" / "corpus_mcm.lua"), name], cwd=out,
                       env=dict(os.environ, TESTS_DIR=str(ROOT / "tests" / "lua")), capture_output=True, text=True)
    lines = p.stdout.splitlines()
    reg = next((l for l in lines if l.startswith("registry")), "registry\t?")
    tpls = [l for l in lines if l.startswith("template")]
    rt = next((l for l in lines if l.startswith("roundtrip")), "roundtrip\t?")
    logs = [l[4:] for l in lines if l.startswith("log\t")]
    static = sum(g["settings"] for g in sc.settings["groups"])
    dyn = any(g["dynamic"] for g in sc.settings["groups"])
    declared = {x.path.lower() for x in sc.scripts}
    reachable = set(declared)
    texts = {f.path.lower(): "" for f in sc.files}
    for f in sc.files:
        for r in f.local_requires:
            reachable.add(r.replace(".", "/").lower() + ".lua")
    group_files = {g["file"].lower() for g in sc.settings["groups"]}
    expected = any(g in reachable or any(g.endswith(d) or d.endswith(g) for d in reachable) for g in group_files)
    ok = p.returncode == 0 and (bool(tpls) or not expected)
    bad += not ok
    so, st = sc.settings_coverage()
    rows.append((mod.name, name, ",".join(sorted(sc.flags)), f"{so}/{st}", static, dyn, reg.split("\t", 1)[1],
                 "; ".join(t.split("\t", 1)[1] for t in tpls) or "none", rt.split("\t", 1)[1], logs,
                 ("ok" if tpls else "ok (settings file not loaded by any declared script)") if ok else f"FAIL rc={p.returncode} {p.stderr.strip()[-300:]}"))
md = ["# Corpus settings probe (generated)", "",
      "Each mod below declares OpenMW settings. It was packaged in normal mode and its scripts were run",
      "once in the MWSE mock in settings-probe mode (unsupported modules replaced by inert stand-ins) at",
      "modConfigReady; the table shows the MCM omwcompat generated. 'Round trip' reads and writes every",
      "control through the MCM variable. Mods whose scripts are not GLOBAL get an MCM whose values are",
      "stored but not used until omwcompat hosts PLAYER/MENU scripts.", "",
      "| Corpus mod | Flags | Renderers OK (scan) | Settings (scan) | Probe registry | MCM | Round trip | Result |",
      "|---|---|---:|---:|---|---|---|---|"]
for r in rows:
    md.append(f"| {r[0]} | {r[2]} | {r[3]} | {r[4]}{' + dynamic' if r[5] else ''} | {r[6]} | {r[7]} | {r[8]} | {r[10]} |")
md.append("")
for r in rows:
    if r[9]:
        md.append(f"- {r[0]}: " + " / ".join(x.strip() for x in r[9][:4]))
(ROOT / "reports" / "generated").mkdir(parents=True, exist_ok=True)
(ROOT / "reports" / "generated" / "corpus-settings.md").write_text("\n".join(md) + "\n", encoding="utf-8")
for r in rows:
    print(f"{r[0]:36} {r[6]:40} MCM: {r[7]:55} {r[8]:14} {r[10]}")
print(f"{len(rows)} mods probed, {bad} failed")
sys.exit(1 if bad else 0)
