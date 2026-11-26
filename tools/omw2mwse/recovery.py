"""Recoverable commit for `convert`: a journal written before the first change to a mod folder.

`convert` changes a staged mod folder in three steps: it writes the planned outputs (each file
atomically), relocates the original package to Off/<plugin>/OpenMW/ (removes the old copies),
and writes the manifest (atomically). Before the first of those changes it records, in
MWSE/mods/mwsuite/openmw/<Mod>/.omw2mwse-recovery/journal.json:

- every file it will create, replace or remove, with the SHA-256 before and after,
- every original it will remove from its old place, with its SHA-256 (the Off/ copy holds the
  same bytes),
- the state reached so far (planned, outputs-written, relocated, manifest-written).

Every replaced or removed file, and the previous manifest, is first copied to backup/<sha256>
next to the journal (content addressed, never a runnable name). The journal is deleted once
the manifest is written, so a folder with a journal is a run that did not finish.

Recovery:
- Re-running `convert` finishes it: the relocation recorded in the journal is completed first
  (only files that still match their recorded hash, and only when the Off/ copy matches too),
  files the interrupted run already wrote are treated as owned (so they are not conflicts),
  and the normal run converges. The new journal keeps the oldest "before" state, so a later
  rollback still returns to the folder as it was before the first interrupted run.
- `omw2mwse recover DIR --rollback` undoes it: originals are copied back from Off/, created
  files are removed, replaced and removed files are restored from backup, the manifest is put
  back. A file that no longer matches what the journal expects (edited since) is left alone
  and reported.

Paths in the journal are relative to the staged folder with forward slashes.
MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

import json
import shutil
from pathlib import Path

from . import __version__
from .build import atomic_write_bytes, mod_dir, sha256b

RECOVERY_DIR = ".omw2mwse-recovery"
JOURNAL_NAME = "journal.json"
JOURNAL_FORMAT = 1
STAGES = ("planned", "outputs-written", "relocated", "manifest-written")


def recovery_dir(staged: Path, modname: str) -> Path:
    return Path(staged) / mod_dir(modname) / RECOVERY_DIR


def journal_rel(modname: str) -> str:
    return f"{mod_dir(modname)}{RECOVERY_DIR}/{JOURNAL_NAME}"


def _sha(p: Path):
    try:
        return sha256b(p.read_bytes()) if p.is_file() else None
    except OSError:
        return None


def pending(staged: Path) -> list[dict]:
    """Unfinished journals in the staged folder (each with "_path" set to the journal file)."""
    out = []
    for jp in sorted(Path(staged).glob(f"MWSE/mods/mwsuite/openmw/*/{RECOVERY_DIR}/{JOURNAL_NAME}")):
        try:
            data = json.loads(jp.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {"mod": jp.parent.parent.name, "stage": "unreadable", "writes": {}, "removes": {},
                    "relocations": [], "aux": {}}
        data["_path"] = jp
        out.append(data)
    return out


def load(staged: Path, modname: str):
    jp = recovery_dir(staged, modname) / JOURNAL_NAME
    if not jp.is_file():
        return None
    try:
        data = json.loads(jp.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    data["_path"] = jp
    return data


class Journal:
    """The recovery record of one convert run for one mod (see the module docstring)."""

    def __init__(self, staged: Path, modname: str, data: dict):
        self.staged = Path(staged)
        self.modname = modname
        self.dir = recovery_dir(staged, modname)
        self.path = self.dir / JOURNAL_NAME
        self.data = data

    def _save(self) -> None:
        data = {k: v for k, v in self.data.items() if not k.startswith("_")}
        atomic_write_bytes(self.path, (json.dumps(data, indent=1, sort_keys=True) + "\n").encode("utf-8"))

    def _backup(self, rel: str) -> str | None:
        """Copy the current staged/rel into backup/<sha> (once per content); returns the sha."""
        p = self.staged / rel
        if not p.is_file():
            return None
        data = p.read_bytes()
        sha = sha256b(data)
        b = self.dir / "backup" / sha
        if not (b.is_file() and sha256b(b.read_bytes()) == sha):
            atomic_write_bytes(b, data)
        return sha

    def stage(self, name: str) -> None:
        self.data["stage"] = name
        self._save()

    def finish(self) -> None:
        """The run completed (manifest written): drop the journal and its backups."""
        shutil.rmtree(self.dir, ignore_errors=True)


def begin(staged: Path, modname: str, *, mode: str, source: str, writes: dict, removes: dict,
          relocation: dict | None, aux: list[str], previous: dict | None = None) -> Journal:
    """Record the intent before the first change. writes: {rel: new sha} (files to create or
    replace); removes: {rel: sha} (owned files to delete); relocation: {"from", "to", "files":
    {rel: sha}} or None; aux: files rewritten whole at the end (manifest, MAX_PATH list).
    previous: an unfinished journal of the same mod; its "before" states are kept."""
    staged = Path(staged)
    prev = previous or {}
    j = Journal(staged, modname, {})
    pw = prev.get("writes", {})
    w_out = {}
    for rel, new in sorted(writes.items()):
        if rel in pw:
            old = pw[rel].get("old")
        else:
            old = j._backup(rel)
        w_out[rel] = {"old": old, "new": new}
    # files an earlier interrupted run wrote that this run no longer plans keep their record
    for rel, rec in pw.items():
        if rel not in w_out:
            w_out[rel] = dict(rec)
    r_out = dict(prev.get("removes", {}))
    for rel, sha in sorted(removes.items()):
        if rel in w_out:            # created by the interrupted run, removed now: back to "old"
            continue
        if rel not in r_out:
            j._backup(rel)
            r_out[rel] = sha
    a_out = dict(prev.get("aux", {}))
    for rel in aux:
        if rel not in a_out:
            a_out[rel] = {"old": j._backup(rel)}
    relocs = list(prev.get("relocations", []))
    if relocation and relocation.get("files"):
        relocs.append(relocation)
    j.data = {"tool": "omw2mwse", "format": JOURNAL_FORMAT, "version": __version__, "mod": modname,
              "mode": mode, "source": source, "stage": "planned",
              "resumedFrom": prev.get("stage") if prev else None,
              "writes": w_out, "removes": r_out, "relocations": relocs, "aux": a_out}
    j._save()
    return j


def _prune(start: Path, stop: Path) -> None:
    from .convert import _prune_empty_dirs   # local import: convert imports this module
    _prune_empty_dirs(start, stop)


def complete_relocations(staged: Path, data: dict) -> list[str]:
    """Roll forward the relocation an interrupted run started: remove an original from its old
    place only when it still has the recorded hash and its Off/ copy has it too."""
    staged = Path(staged)
    done = []
    for rl in data.get("relocations", []):
        frm = staged / rl["from"] if rl["from"] != "." else staged
        to = staged / rl["to"]
        for rel, sha in sorted(rl.get("files", {}).items()):
            p, newp = frm / rel, to / rel
            if _sha(p) == sha and _sha(newp) == sha:
                p.unlink()
                done.append(rel)
        _prune(frm, staged)
    return done


def owned_from(data: dict, staged: Path) -> dict:
    """{rel: sha} for files the interrupted run already wrote (current content == its "new")."""
    out = {}
    for rel, rec in data.get("writes", {}).items():
        if rec.get("new") and _sha(Path(staged) / rel) == rec["new"]:
            out[rel] = rec["new"]
    return out


def rollback(staged: Path, data: dict) -> dict:
    """Undo an unfinished run recorded in data (a journal from pending()/load())."""
    staged = Path(staged)
    jdir = Path(data["_path"]).parent
    rep = {"mod": data.get("mod"), "stage": data.get("stage"), "restored": [], "removed": [], "kept": []}

    def restore(rel: str, sha: str) -> bool:
        b = jdir / "backup" / sha
        if _sha(b) != sha:
            rep["kept"].append({"path": rel, "reason": "backup missing or damaged"})
            return False
        atomic_write_bytes(staged / rel, b.read_bytes())
        rep["restored"].append(rel)
        return True

    touched = []
    # 1. originals back to where they were (from the Off/ copy, which a later step may delete)
    for rl in data.get("relocations", []):
        frm = staged / rl["from"] if rl["from"] != "." else staged
        to = staged / rl["to"]
        frm_rel = "" if rl["from"] == "." else rl["from"].rstrip("/") + "/"
        for rel, sha in sorted(rl.get("files", {}).items()):
            p, newp = frm / rel, to / rel
            cur = _sha(p)
            if cur == sha:
                continue
            if cur is not None:
                rep["kept"].append({"path": frm_rel + rel, "reason": "changed since the interrupted run"})
                continue
            if _sha(newp) == sha:
                atomic_write_bytes(p, newp.read_bytes())
                rep["restored"].append(frm_rel + rel)
            else:
                rep["kept"].append({"path": frm_rel + rel, "reason": "its Off/ copy is missing or changed"})
    # 2. outputs
    for rel, rec in sorted(data.get("writes", {}).items()):
        p = staged / rel
        cur, old, new = _sha(p), rec.get("old"), rec.get("new")
        if cur == old:
            continue
        if cur is not None and cur != new:
            rep["kept"].append({"path": rel, "reason": "edited since the interrupted run"})
            continue
        if old is None:
            p.unlink()
            rep["removed"].append(rel)
            touched.append(p.parent)
        else:
            restore(rel, old)
    for rel, sha in sorted(data.get("removes", {}).items()):
        cur = _sha(staged / rel)
        if cur == sha:
            continue
        if cur is not None:
            rep["kept"].append({"path": rel, "reason": "edited since the interrupted run"})
            continue
        restore(rel, sha)
    # 3. manifest and MAX_PATH list: back to their earlier content (or gone)
    for rel, rec in sorted(data.get("aux", {}).items()):
        p, old = staged / rel, rec.get("old")
        cur = _sha(p)
        if cur == old:
            continue
        if old is None:
            p.unlink()
            rep["removed"].append(rel)
            touched.append(p.parent)
        else:
            restore(rel, old)
    shutil.rmtree(jdir, ignore_errors=True)
    touched.append(jdir.parent)
    for d in touched:
        _prune(d, staged)
    return rep


def describe(data: dict, staged: Path) -> dict:
    """The JSON form of an unfinished journal (`pendingRecovery` / `recover --json`)."""
    return {"mod": data.get("mod"), "stage": data.get("stage"), "mode": data.get("mode"),
            "journal": Path(data["_path"]).relative_to(Path(staged)).as_posix(),
            "writes": len(data.get("writes", {})), "removes": len(data.get("removes", {})),
            "relocations": sum(len(r.get("files", {})) for r in data.get("relocations", []))}


# Convenience for tests and tidy: is anything unfinished?
def has_pending(staged: Path) -> bool:
    return bool(pending(staged))


__all__ = ["RECOVERY_DIR", "JOURNAL_NAME", "STAGES", "Journal", "begin", "complete_relocations", "describe",
           "has_pending", "journal_rel", "load", "owned_from", "pending", "recovery_dir", "rollback"]
