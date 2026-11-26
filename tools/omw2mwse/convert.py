"""`convert`: in-place conversion of a staged mod folder (the entry point for tidy).

The staged folder is a Data Files root (e.g. a Vortex staging mod folder). Every
OpenMW mod inside it (a folder holding a .omwscripts file, outside MWSE/) is built
into MWSE files in the same folder. The complete original OpenMW package is always
moved (or copied, when --source is outside the staged folder) to
Off/<plugin>/OpenMW/<the author's relative paths> — for example
Off/LeaveTheLightsOff/OpenMW/scripts/LeaveTheLightsOff/LTLO_g.lua. File contents
are never edited; only the location of the original tree changes (legacy layouts
such as Off/OpenMW/<plugin>/ are relocated on the first successful run). Game
assets (meshes, textures, ...) are also installed at the Data Files root so
Morrowind can load them. Running it again with the same inputs changes nothing
(idempotent): ownership is tracked in MWSE/mods/mwsuite/openmw/<Mod>/omw2mwse-manifest.json.
Converted mods live at MWSE/mods/mwsuite/openmw/<Mod>/ (loader main.lua, hosted Lua in omw/);
a 0.2.0 layout (MWSE/mods/<Mod>/, MWSE/omw/<Mod>/) is migrated on the first run.
MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

from . import __version__
from . import sidecar as SC
from . import warn
from .build import (MANIFEST_NAME, BuildError, Writer, build, is_game_asset, iter_original_files, mod_dir,
                    renamed_plugin,
                    notice_text, original_off_prefix, sha256b, text_bytes)
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


def canonical_source(staged: Path, name: str) -> Path:
    """Off/<plugin>/OpenMW — the permanent home of the original OpenMW package."""
    return Path(staged) / "Off" / name / "OpenMW"


def prefer_source(srcs: list[Path], staged: Path, name: str) -> Path:
    """Prefer a copy already at Off/<name>/OpenMW when several identical trees exist."""
    canon = canonical_source(staged, name).resolve()
    for s in srcs:
        if s.resolve() == canon:
            return s
    return srcs[0]


def _prune_empty_dirs(start: Path, stop: Path) -> None:
    """Remove empty directories under start, then start itself, up to (not including) stop."""
    try:
        stop = stop.resolve()
    except OSError:
        return
    if start.exists():
        for dirpath, dirnames, filenames in os.walk(start, topdown=False):
            p = Path(dirpath)
            try:
                if p.resolve() == stop:
                    continue
                next(p.iterdir())
            except StopIteration:
                try:
                    p.rmdir()
                except OSError:
                    pass
            except OSError:
                pass
    try:
        cur = start.resolve() if start.exists() else start.parent.resolve()
    except OSError:
        return
    while cur != stop and stop in cur.parents:
        try:
            next(cur.iterdir())
            break
        except StopIteration:
            parent = cur.parent
            try:
                cur.rmdir()
            except OSError:
                break
            cur = parent
        except OSError:
            break


def relocate_original(src: Path, staged: Path, name: str) -> list[str]:
    """After Off/<name>/OpenMW/ has been written, remove the previous package location.

    Game assets already at the staged Data Files root (meshes/, textures/, ...) stay
    there so Morrowind can load them. An external --source is never deleted.
    """
    dest = canonical_source(staged, name)
    try:
        src_r, staged_r, dest_r = src.resolve(), staged.resolve(), dest.resolve()
    except OSError:
        return []
    if src_r == dest_r:
        return []
    if staged_r not in src_r.parents and src_r != staged_r:
        return []
    removed: list[str] = []
    src_is_root = src_r == staged_r
    for p, rel in iter_original_files(src):
        new = dest / rel
        if not p.is_file() or not new.is_file():
            continue
        try:
            if p.resolve() == new.resolve():
                continue
        except OSError:
            continue
        if src_is_root and is_game_asset(rel) and not renamed_plugin(rel):
            continue
        if sha256b(p.read_bytes()) != sha256b(new.read_bytes()):
            continue
        p.unlink()
        removed.append(rel)
    _prune_empty_dirs(src, staged)
    return removed


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
            inp=None, err=None, manifest: dict | None = None, title: str | None = None,
            credits: dict | None = None) -> dict:
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
    # identical copies of one mod (e.g. Off/OpenMW/X and Off/X/OpenMW) collapse;
    # the canonical Off/<name>/OpenMW copy is preferred when it is one of them
    groups: dict[str, list[Path]] = {}
    for s in sources:
        groups.setdefault(name or mod_name_for(s), []).append(s)
    for modname, srcs in groups.items():
        src = prefer_source(srcs, staged, modname)
        sigs = {_tree_sig(s) for s in srcs}
        if len(sigs) > 1:
            raise BuildError(f"{modname}: {len(srcs)} different source folders ({', '.join(str(s.relative_to(staged)) for s in srcs)}); "
                             "pick one with --source")
        for dup in srcs:
            if dup.resolve() == src.resolve():
                continue
            result["alerts"].append({"level": "info", "code": "duplicate-source",
                                     "message": f"{dup.relative_to(staged)} is identical to {src.relative_to(staged)}; used the latter"})
        man_rel = f"{mod_dir(modname)}{MANIFEST_NAME}"
        legacy_rel = f"MWSE/omw/{modname}/{MANIFEST_NAME}"     # 0.2.0 layout
        prev = {}
        mp = staged / man_rel
        for rel_m in (legacy_rel, man_rel):
            if (staged / rel_m).is_file():
                try:
                    prev.update(json.loads((staged / rel_m).read_text(encoding="utf-8")).get("files", {}))
                except (OSError, ValueError):
                    result["alerts"].append({"level": "warning", "code": "manifest-unreadable", "message": rel_m})
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
                        sidecar=sc, confirm=confirm, manifest=manifest, title=title, credits=credits,
                        meta_dirs=[staged])
        except warn.Refused as e:
            entry.update({"status": "refused", "message": str(e), "warning": warning_box.get("text")})
            result["mods"].append(entry)
            result["exitCode"] = EXIT_REFUSED
            continue
        w.put(f"{mod_dir(modname)}OMW2MWSE-REPORT.md", text_bytes(res.report_md))
        w.check()
        ok, total = res.scan.coverage()
        so, st = res.scan.settings_coverage()
        entry["off"] = original_off_prefix(modname).rstrip("/")
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
            "notice": notice_text(res.credits),
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
        if not dry_run:
            w.commit()
            for legacy in (staged / "MWSE" / "omw" / modname, staged / "MWSE" / "mods" / modname):
                if legacy.is_dir():
                    _prune_empty_dirs(legacy, staged)
            old_loader = staged / "MWSE" / "mods" / modname / "main.lua"
            if old_loader.is_file():
                entry["alerts"].append({"level": "warning", "code": "legacy-loader-present",
                                        "message": f"MWSE/mods/{modname}/main.lua is not an omw2mwse file and would load "
                                                   "alongside the converted mod; remove it if it is an older build or hand port"})
            moved = relocate_original(src, staged, modname)
            if moved:
                previous_src = entry["source"]
                entry["source"] = str(canonical_source(staged, modname).relative_to(staged))
                entry["relocatedFrom"] = previous_src
                entry["relocated"] = moved
        else:
            dest = canonical_source(staged, modname)
            try:
                if src.resolve() != dest.resolve() and (staged.resolve() in src.resolve().parents or src.resolve() == staged.resolve()):
                    entry["willRelocateTo"] = str(dest.relative_to(staged))
            except OSError:
                pass
        files = {rel: sha256b(data) for rel, data in w.plan.items()}
        man = {"tool": "omw2mwse", "version": __version__, "mod": modname, "source": entry["source"], "mode": mode,
               "files": files}
        man_bytes = text_bytes(json.dumps(man, indent=1, sort_keys=True) + "\n")
        man_changed = not (mp.is_file() and mp.read_bytes() == man_bytes)
        if not dry_run and man_changed:
            mp.parent.mkdir(parents=True, exist_ok=True)
            mp.write_bytes(man_bytes)
        entry["changed"] = w.changed() or man_changed or bool(entry.get("relocated"))
        result["changed"] = result["changed"] or entry["changed"]
        result["mods"].append(entry)
    return result
