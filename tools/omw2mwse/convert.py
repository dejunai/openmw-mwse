"""`convert`: in-place conversion of a staged mod folder (the entry point for tidy).

The staged folder is a Data Files root (e.g. a Vortex staging mod folder). Every
OpenMW mod inside it (a folder holding a .omwscripts file, outside MWSE/) is built
into MWSE files in the same folder. The OpenMW source files are never modified.
Running it again with the same inputs changes nothing (idempotent): ownership is
tracked in MWSE/omw/<Mod>/omw2mwse-manifest.json.
MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

import json
import re
from pathlib import Path

from . import __version__
from . import sidecar as SC
from . import warn
from .build import MANIFEST_NAME, BuildError, Writer, build, sha256b, text_bytes
from .scan import load_manifest

MODES = ("normal", "hardcode")
EXIT_OK, EXIT_ERROR, EXIT_REFUSED, EXIT_CONFLICT = 0, 2, 3, 4


def find_sources(root: Path) -> list[Path]:
    """Folders under root holding a .omwscripts file, excluding omw2mwse output (MWSE/)."""
    found = []
    for om in sorted(root.rglob("*.omwscripts")):
        rel = om.relative_to(root).parts
        if rel and rel[0].lower() == "mwse":
            continue
        if om.parent not in found:
            found.append(om.parent)
    return found


def mod_name_for(src: Path) -> str:
    oms = sorted(src.glob("*.omwscripts"))
    base = oms[0].stem if oms else src.name
    return re.sub(r"[^A-Za-z0-9_\-]", "", base) or "OpenMWMod"


def _tree_sig(p: Path) -> str:
    h = []
    for f in sorted(p.rglob("*")):
        if f.is_file():
            h.append(f.relative_to(p).as_posix() + ":" + sha256b(f.read_bytes()))
    return sha256b("\n".join(h).encode())


def convert(staged: Path, mode: str = "normal", *, name: str | None = None, source: Path | None = None,
            sidecar_path: Path | None = None, accept: bool = False, dry_run: bool = False, adopt: bool = False,
            with_runtime: bool = True, meshes_from: list[Path] | None = None, interactive: bool | None = None,
            inp=None, err=None, manifest: dict | None = None) -> dict:
    """Returns the machine-readable result (also printed by `--json`)."""
    if mode not in MODES:
        raise BuildError(f"mode must be one of {MODES}")
    staged = Path(staged).resolve()
    result = {"tool": "omw2mwse", "version": __version__, "command": "convert", "mode": mode, "dir": str(staged),
              "dryRun": dry_run, "mods": [], "alerts": [], "changed": False, "exitCode": EXIT_OK}
    if not staged.is_dir():
        raise BuildError(f"{staged} is not a directory")
    manifest = manifest or load_manifest()
    sources = [Path(source).resolve()] if source else find_sources(staged)
    if not sources:
        result["alerts"].append({"level": "info", "code": "no-openmw-scripts", "message": "no .omwscripts found; nothing to convert"})
        return result
    # identical copies of one mod (e.g. OpenMW/X and Off/OpenMW/X) collapse to the first
    groups: dict[str, list[Path]] = {}
    for s in sources:
        groups.setdefault(name or mod_name_for(s), []).append(s)
    for modname, srcs in groups.items():
        src = srcs[0]
        sigs = {_tree_sig(s) for s in srcs}
        if len(sigs) > 1:
            raise BuildError(f"{modname}: {len(srcs)} different source folders ({', '.join(str(s.relative_to(staged)) for s in srcs)}); "
                             "pick one with --source")
        for dup in srcs[1:]:
            result["alerts"].append({"level": "info", "code": "duplicate-source",
                                     "message": f"{dup.relative_to(staged)} is identical to {src.relative_to(staged)}; used the latter"})
        man_rel = f"MWSE/omw/{modname}/{MANIFEST_NAME}"
        prev = {}
        mp = staged / man_rel
        if mp.is_file():
            try:
                prev = json.loads(mp.read_text(encoding="utf-8")).get("files", {})
            except (OSError, ValueError):
                result["alerts"].append({"level": "warning", "code": "manifest-unreadable", "message": man_rel})
        w = Writer(staged, previous=prev, adopt=adopt)
        sc = None
        if mode == "hardcode":
            sp = Path(sidecar_path) if sidecar_path else SC.find(modname, staged, src)
            if sp:
                sc = SC.load(sp)
        elif sidecar_path or SC.find(modname, staged, src):
            sc = SC.load(Path(sidecar_path) if sidecar_path else SC.find(modname, staged, src))

        warning_box = {}

        def confirm(plan, _mod=modname, _box=warning_box):
            text = warn.render(_mod, plan.conversions, mode, plan.sidecar)
            _box["text"] = text
            if dry_run:
                return list(plan.conversions)  # plan only: tidy shows the warning, then re-runs with the accept flag
            return warn.confirm(text, plan.conversions, accept, interactive=interactive, inp=inp, err=err)

        mesh_dirs = list(meshes_from or []) + [staged / "meshes", src / "meshes"]
        entry = {"name": modname, "source": str(src.relative_to(staged)) if staged in src.parents else str(src)}
        try:
            res = build(src, w, modname, slug=None, with_runtime=with_runtime, meshes_from=mesh_dirs, mode=mode,
                        sidecar=sc, confirm=confirm, manifest=manifest)
        except warn.Refused as e:
            entry.update({"status": "refused", "message": str(e), "warning": warning_box.get("text")})
            result["mods"].append(entry)
            result["exitCode"] = EXIT_REFUSED
            continue
        w.put(f"MWSE/omw/{modname}/OMW2MWSE-REPORT.md", text_bytes(res.report_md))
        w.check()
        ok, total = res.scan.coverage()
        so, st = res.scan.settings_coverage()
        entry.update({
            "status": "ok", "verdict": res.scan.verdict, "coverage": [ok, total],
            "settings": {"groups": [g["key"] for g in res.scan.settings.get("groups", [])], "coverage": [so, st],
                         "mcm": bool(res.scan.settings.get("groups")) or bool(res.accepted)},
            "rewrites": [c.to_json() for c in res.accepted],
            "hardcodeLog": res.hard.log if res.hard else [],
            "alerts": res.alerts,
            "conflicts": w.conflicts,
            "files": {rel: w.status.get(rel, "?") for rel in sorted(set(w.plan) | {r for r, s in w.status.items() if s == "removed"})},
            "newGameRequired": False,
        })
        if "text" in warning_box:
            entry["warning"] = warning_box["text"]
        if res.accepted:
            entry["sidecar"] = res.hard.sidecar
        if w.conflicts:
            entry["status"] = "conflict"
            result["exitCode"] = max(result["exitCode"], EXIT_CONFLICT)
            result["mods"].append(entry)
            continue
        files = {rel: sha256b(data) for rel, data in w.plan.items()}
        man = {"tool": "omw2mwse", "version": __version__, "mod": modname, "source": entry["source"], "mode": mode,
               "files": files}
        man_bytes = text_bytes(json.dumps(man, indent=1, sort_keys=True) + "\n")
        man_changed = not (mp.is_file() and mp.read_bytes() == man_bytes)
        if not dry_run:
            w.commit()
            if man_changed:
                mp.parent.mkdir(parents=True, exist_ok=True)
                mp.write_bytes(man_bytes)
        entry["changed"] = w.changed() or man_changed
        result["changed"] = result["changed"] or entry["changed"]
        result["mods"].append(entry)
    return result
