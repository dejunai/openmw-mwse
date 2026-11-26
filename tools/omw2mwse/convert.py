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
Before the first change to a mod folder a recovery journal is written (recovery.py), so an
interrupted run is finished by running convert again or undone by `recover --rollback`; the
manifest is written atomically. Paths in the JSON result and the manifest are relative to the
staged folder with forward slashes (build.portable_path; docs/TIDY-INTEGRATION.md).
Converted mods live at MWSE/mods/mwsuite/openmw/<Mod>/ (loader main.lua, hosted Lua in omw/);
a 0.2.0 layout (MWSE/mods/<Mod>/, MWSE/omw/<Mod>/) is migrated on the first run.
MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

import json
import os
from pathlib import Path

from . import REQUIRES_PYTHON, __version__
from . import sidecar as SC
from . import warn
from . import recovery as RC
from .build import (MANIFEST_NAME, MAX_PATH_CHARS, MAX_PATH_LIST, BuildError, Writer, abs_path_len, atomic_write_bytes,
                    max_path_list_text, build, is_game_asset, iter_original_files, mod_dir, mod_name_for, portable_path,
                    renamed_plugin, notice_text, original_off_prefix, sha256b, text_bytes)
from .optout import find_opt_out
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


def owned_by_others(staged: Path, src: Path, mod_dir_name: str) -> set:
    """Lower-case posix paths, relative to src, of files other converted mods in this staged
    folder placed (keys of their manifests' files and plugin paths). Those are never part of
    this mod's original package, e.g. a nested add-on's <Name>-metadata.toml at the root."""
    try:
        src_rel = src.resolve().relative_to(staged.resolve()).as_posix()
    except ValueError:
        return set()
    pre = "" if src_rel in ("", ".") else src_rel.lower() + "/"
    out = set()
    for pattern in ("MWSE/mods/mwsuite/openmw/*/" + MANIFEST_NAME, "MWSE/omw/*/" + MANIFEST_NAME):
        for mp in sorted(staged.glob(pattern)):
            if mp.parent.name == mod_dir_name:
                continue
            try:
                data = json.loads(mp.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            rels = list(data.get("files", {})) + [p.get("path") for p in data.get("plugins", []) if p.get("path")]
            for r in rels:
                r = r.replace("\\", "/").lower()
                if r.startswith(pre):
                    out.add(r[len(pre):])
    return out


def _relocation_candidates(src: Path, staged: Path, name: str, keep_root=None, exclude=None, dest_sha=None):
    """Yield (path, rel, sha) for each original relocate_original would remove from its old place:
    its Off/<name>/OpenMW/ copy has the same SHA-256 (dest_sha(rel, newp) gives the copy's hash;
    default: the file on disk). See relocate_original for the rules."""
    dest = canonical_source(staged, name)
    try:
        src_r, staged_r, dest_r = src.resolve(), staged.resolve(), dest.resolve()
    except OSError:
        return
    if src_r == dest_r:
        return
    if staged_r not in src_r.parents and src_r != staged_r:
        return
    if dest_sha is None:
        def dest_sha(_rel, newp):
            return sha256b(newp.read_bytes()) if newp.is_file() else None
    src_is_root = src_r == staged_r
    keep = {k.replace("\\", "/").lower() for k in (keep_root or [])}
    for p, rel in iter_original_files(src, exclude):
        posix = rel.replace("\\", "/")
        newp = dest / rel
        if not p.is_file():
            continue
        try:
            if p.resolve() == newp.resolve():
                continue
        except OSError:
            continue
        if src_is_root and is_game_asset(posix):
            suf = Path(posix).suffix.lower()
            if "/" not in posix and suf in {".esp", ".esm", ".omwaddon", ".omwgame"}:
                # Leave a required/undetermined installed plugin at the root.
                # Always remove the original .omwaddon/.omwgame (the renamed
                # .esp/.esm is a different path, written by build()).
                inst = renamed_plugin(posix)
                if inst is None and posix.lower() in keep:
                    continue
            else:
                # meshes, Sound, .bsa, ...
                continue
        target = dest_sha(rel, newp)
        if target is None:
            continue
        sha = sha256b(p.read_bytes())
        if sha != target:
            continue
        yield p, rel, sha


def _rels_under(staged: Path, src: Path, rels) -> set:
    """Lower-case posix paths relative to src for the staged-relative rels below src."""
    try:
        src_rel = src.resolve().relative_to(staged.resolve()).as_posix()
    except ValueError:
        return set()
    pre = "" if src_rel in ("", ".") else src_rel.lower() + "/"
    out = set()
    for r in rels:
        r = r.replace("\\", "/").lower()
        if r.startswith(pre):
            out.add(r[len(pre):])
    return out


def relocate_original(src: Path, staged: Path, name: str, keep_root=None, exclude=None) -> list[str]:
    """After Off/<name>/OpenMW/ has been written, remove the previous package location.

    Game assets already at the staged Data Files root (meshes/, textures/, ...) stay
    there so Morrowind can load them. A root plugin stays only when its installed
    name is in keep_root (required or undetermined). Obsolete plugins and the
    pre-rename .omwaddon/.omwgame are removed from the root once Off/ holds a
    matching copy. An external --source is never deleted.
    """
    removed: list[str] = []
    for p, rel, _sha in list(_relocation_candidates(src, staged, name, keep_root, exclude)):
        p.unlink()
        removed.append(rel)
    _prune_empty_dirs(src, staged)
    return removed


def plan_relocation(src: Path, staged: Path, name: str, planned: dict, keep_root=None, exclude=None) -> dict | None:
    """The relocation relocate_original will do once the planned outputs are written, for the
    recovery journal: {"from", "to", "files": {rel: sha}} (staged-relative, forward slashes)."""
    off = original_off_prefix(name)

    def dest_sha(rel, newp):
        data = planned.get(off + rel)
        if data is not None:
            return sha256b(data)
        return sha256b(newp.read_bytes()) if newp.is_file() else None

    files = {rel: sha for _p, rel, sha in _relocation_candidates(src, staged, name, keep_root, exclude, dest_sha)}
    if not files:
        return None
    return {"from": portable_path(src, staged), "to": portable_path(canonical_source(staged, name), staged), "files": files}


# mod_name_for lives in build.py (one helper for Off/<plugin>/ and the mod folder)


def max_path_offenders(w: Writer, staged: Path, src: Path, off_prefix: str) -> list[str]:
    """Staged-relative paths for Off/<plugin>/max_path_too_long.txt from the files w did not write.

    As in conflict-tools' tidy, a file that stays where it is is listed by its own path: an
    original whose Off/<plugin>/OpenMW/ copy would be too long stays in the source folder
    (relocate_original only removes what Off/ holds). A generated or installed file that
    could not be written is listed by the path it would have had.
    """
    out = []
    try:
        src_rel = src.resolve().relative_to(staged.resolve()).as_posix()
    except ValueError:
        src_rel = None                      # external --source: its files are not ours to list
    for rel in w.too_long:
        if rel.lower().startswith(off_prefix.lower()):
            if src_rel is None:
                continue
            orig = rel[len(off_prefix):]
            out.append(f"{src_rel}/{orig}" if src_rel not in ("", ".") else orig)
        else:
            out.append(rel)
    return out


def write_max_path_list(staged: Path, off_rel: str, offenders: list[str], off_prefix: str) -> bool:
    """Refresh Off/<plugin>/max_path_too_long.txt with tidy's rule: this run's offenders plus
    earlier lines whose file is still there and still too long (its own path, or its copy
    under off_prefix, the move it was left out of); removed when empty; written only when
    the text changes. Returns True if the file was written or removed."""
    path = staged / off_rel / MAX_PATH_LIST
    root = os.path.abspath(str(staged))
    old = []
    if path.is_file():
        old = [ln.strip() for ln in path.read_text(encoding="utf-8", errors="replace").splitlines() if ln.strip()]
    keep = [r for r in old if (staged / r.replace("\\", "/")).is_file()
            and max(abs_path_len(root, r), abs_path_len(root, off_prefix + r)) > MAX_PATH_CHARS]
    text = max_path_list_text(list(offenders) + keep)
    if not text:
        if path.is_file():
            path.unlink()
            return True
        return False
    if path.is_file() and path.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n") == text:
        return False
    atomic_write_bytes(path, text.encode("utf-8"))
    return True


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
    result = {"tool": "omw2mwse", "version": __version__, "requiresPython": REQUIRES_PYTHON, "command": "convert", "mode": mode, "dir": str(staged),
              "dryRun": dry_run, "mods": [], "alerts": [], "changed": False, "exitCode": EXIT_OK}
    if not staged.is_dir():
        raise BuildError(f"{staged} is not a directory")
    # Recovery (#1): finish what an interrupted run started before looking for sources, so a
    # half-relocated package is not seen as a second, different copy of the mod.
    resumed: dict[str, dict] = {}
    for jd in RC.pending(staged):
        if dry_run:
            result["alerts"].append({"level": "warning", "code": "interrupted-run-pending",
                                     "path": RC.describe(jd, staged)["journal"], "mod": jd.get("mod"),
                                     "message": f"{jd.get('mod')}: an earlier convert run did not finish "
                                                f"(stage {jd.get('stage')}); run convert again to finish it, "
                                                "or `omw2mwse recover --rollback` to undo it"})
            continue
        if jd.get("stage") == "unreadable":
            continue
        RC.complete_relocations(staged, jd)
        resumed[jd.get("mod")] = jd
    result["pendingRecovery"] = []
    manifest = manifest or load_manifest()
    sources = [Path(source).resolve()] if source else find_sources(staged)
    if not sources:
        result["alerts"].append({"level": "info", "code": "no-openmw-scripts", "message": "no .omwscripts found; nothing to convert"})
        result["pendingRecovery"] = [RC.describe(j, staged) for j in RC.pending(staged)]
        return result
    # identical copies of one mod (e.g. Off/OpenMW/X and Off/X/OpenMW) collapse;
    # the canonical Off/<name>/OpenMW copy is preferred when it is one of them
    groups: dict[str, list[Path]] = {}
    for s in sources:
        groups.setdefault(name or mod_name_for(s), []).append(s)
    for modname, srcs in groups.items():
        offname = mod_name_for(srcs[0])  # Off/<plugin>/ always follows the tidy rule, even with --name
        src = prefer_source(srcs, staged, offname)
        offname = mod_name_for(src)
        sigs = {_tree_sig(s) for s in srcs}
        if len(sigs) > 1:
            raise BuildError(f"{modname}: {len(srcs)} different source folders ({', '.join(portable_path(s, staged) for s in srcs)}); "
                             "pick one with --source")
        for dup in srcs:
            if dup.resolve() == src.resolve():
                continue
            result["alerts"].append({"level": "info", "code": "duplicate-source",
                                     "message": f"{portable_path(dup, staged)} is identical to {portable_path(src, staged)}; used the latter"})
        opt = find_opt_out(src)
        if opt:
            # author opt-out: write nothing, move nothing; tidy treats it like any blocked mod
            entry = {"name": modname, "source": portable_path(src, staged),
                     "status": "ok", "verdict": "blocked", "reason": opt,
                     "alerts": [dict(opt, level="error")], "files": {}, "plugins": [], "conflicts": [], "rewrites": [],
                     "hardcodeLog": [], "partialApis": [], "guards": {}, "changed": False}
            if (staged / mod_dir(modname) / MANIFEST_NAME).is_file():
                entry["alerts"].append({"level": "warning", "code": "previous-output-present",
                                        "message": f"{mod_dir(modname)} holds output from an earlier conversion; "
                                                   "it was left as is"})
            if modname in resumed:
                entry["alerts"].append(_pending_alert(modname))
            result["mods"].append(entry)
            continue
        old_journal = resumed.get(modname)
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
        if old_journal:
            # files the interrupted run already wrote are ours (not "existing file not written by omw2mwse")
            prev.update(RC.owned_from(old_journal, staged))
        w = Writer(staged, previous=prev, adopt=adopt, max_path=MAX_PATH_CHARS)
        others = owned_by_others(staged, src, Path(mod_dir(modname)).name)
        if old_journal:
            # what the interrupted run wrote (e.g. <Mod>-metadata.toml next to a root package) is
            # output, not part of the original package
            off_pre = original_off_prefix(offname).lower()
            others |= _rels_under(staged, src, [rel for rel, rec in old_journal.get("writes", {}).items()
                                               if rec.get("old") is None and not rel.lower().startswith(off_pre)])
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
        entry = {"name": modname, "source": portable_path(src, staged)}
        if old_journal:
            entry["resumed"] = {"stage": old_journal.get("stage"), "journal": RC.journal_rel(modname)}
        try:
            res = build(src, w, modname, off_name=offname, exclude=others, slug=None, with_runtime=with_runtime, meshes_from=mesh_dirs, mode=mode,
                        sidecar=sc, confirm=confirm, manifest=manifest, title=title, credits=credits,
                        meta_dirs=[staged])
        except warn.Refused as e:
            entry.update({"status": "refused", "message": str(e), "warning": warning_box.get("text")})
            if old_journal:
                entry["alerts"] = [_pending_alert(modname)]
            result["mods"].append(entry)
            result["exitCode"] = EXIT_REFUSED
            continue
        w.put(f"{mod_dir(modname)}OMW2MWSE-REPORT.md", text_bytes(res.report_md))
        w.check()
        ok, total = res.scan.coverage()
        so, st = res.scan.settings_coverage()
        entry["off"] = original_off_prefix(offname).rstrip("/")
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
            "plugins": res.plugins,
            "partialApis": res.scan.partial_apis,
            "guards": res.scan.guards,
        })
        owner_rel = f"Off/{offname}"
        too_long = max_path_offenders(w, staged, src, original_off_prefix(offname))
        if too_long:
            entry["maxPathTooLong"] = too_long
            for rel in w.too_long:
                entry["alerts"].append({"level": "error", "code": "max-path-too-long", "path": rel,
                                        "message": f"{rel} not written: its full path would be over {MAX_PATH_CHARS} "
                                                   f"characters (Windows MAX_PATH); listed in {owner_rel}/{MAX_PATH_LIST}"})
            hosted = [r for r in w.too_long if r.lower().startswith("mwse/")]
            if hosted:
                entry["verdict"] = "blocked"
                entry["reason"] = {"code": "max-path-too-long", "file": hosted[0],
                                   "message": f"{len(hosted)} MWSE file(s) could not be written because their full path "
                                              f"is over {MAX_PATH_CHARS} characters; move the staging folder to a shorter path"}
        if "text" in warning_box:
            entry["warning"] = warning_box["text"]
        if res.accepted:
            entry["sidecar"] = portable_path(res.hard.sidecar, staged) if res.hard.sidecar else res.hard.sidecar
        for al in entry["alerts"]:
            if al.get("code") == "sidecar-ignored" and al.get("file"):
                al["file"] = portable_path(al["file"], staged)
        if w.conflicts:
            entry["status"] = "conflict"
            result["exitCode"] = max(result["exitCode"], EXIT_CONFLICT)
            if old_journal:
                entry["alerts"].append(_pending_alert(modname))
            result["mods"].append(entry)
            continue
        keep_root = [pl["name"] for pl in res.plugins if pl.get("placement") == "root"]
        journal = None
        if not dry_run:
            # Recovery intent first (#1): what will be written, removed and relocated, with hashes,
            # and backups of everything replaced. Nothing in the mod folder changes before this.
            writes = {rel: sha256b(w.plan[rel]) for rel, st in w.status.items() if st in ("created", "updated")}
            removes = {rel: w.previous[rel] for rel, st in w.status.items() if st == "removed"}
            reloc = plan_relocation(src, staged, offname, w.plan, keep_root=keep_root, exclude=others)
            if writes or removes or reloc or old_journal:
                # (a run with nothing to write stays a true no-op: no journal; a lone manifest
                # rewrite is a single atomic replace)
                journal = RC.begin(staged, modname, mode=mode, source=entry["source"], writes=writes, removes=removes,
                                   relocation=reloc, aux=[man_rel, f"Off/{offname}/{MAX_PATH_LIST}"],
                                   previous=old_journal)
            w.commit()
            if journal:
                journal.stage("outputs-written")
            for legacy in (staged / "MWSE" / "omw" / modname, staged / "MWSE" / "mods" / modname):
                if legacy.is_dir():
                    _prune_empty_dirs(legacy, staged)
            old_loader = staged / "MWSE" / "mods" / modname / "main.lua"
            if old_loader.is_file():
                entry["alerts"].append({"level": "warning", "code": "legacy-loader-present",
                                        "message": f"MWSE/mods/{modname}/main.lua is not an omw2mwse file and would load "
                                                   "alongside the converted mod; remove it if it is an older build or hand port"})
            moved = relocate_original(src, staged, offname, keep_root=keep_root, exclude=others)
            if moved:
                previous_src = entry["source"]
                entry["source"] = portable_path(canonical_source(staged, offname), staged)
                entry["relocatedFrom"] = previous_src
                entry["relocated"] = moved
            if journal:
                journal.stage("relocated")
        else:
            dest = canonical_source(staged, offname)
            try:
                if src.resolve() != dest.resolve() and (staged.resolve() in src.resolve().parents or src.resolve() == staged.resolve()):
                    entry["willRelocateTo"] = portable_path(dest, staged)
            except OSError:
                pass
        files = {rel: sha256b(data) for rel, data in w.plan.items()}
        man = {"tool": "omw2mwse", "version": __version__, "mod": modname, "source": entry["source"], "mode": mode,
               "files": files, "plugins": res.plugins}
        man_bytes = text_bytes(json.dumps(man, indent=1, sort_keys=True) + "\n")
        man_changed = not (mp.is_file() and mp.read_bytes() == man_bytes)
        if not dry_run and man_changed:
            atomic_write_bytes(mp, man_bytes)       # temp file + os.replace: old or new, never partial
        if journal:
            journal.stage("manifest-written")
        list_changed = False if dry_run else write_max_path_list(staged, f"Off/{offname}", too_long, original_off_prefix(offname))
        if journal:
            journal.finish()
        entry["changed"] = w.changed() or man_changed or bool(entry.get("relocated")) or list_changed
        result["changed"] = result["changed"] or entry["changed"]
        result["mods"].append(entry)
    result["pendingRecovery"] = [RC.describe(j, staged) for j in RC.pending(staged)]
    return result


def _pending_alert(modname: str) -> dict:
    return {"level": "warning", "code": "interrupted-run-pending", "path": RC.journal_rel(modname), "mod": modname,
            "message": f"{modname}: an earlier convert run did not finish and this run made no changes; "
                       "resolve the conflict and run convert again, or `omw2mwse recover --rollback` to undo it"}
