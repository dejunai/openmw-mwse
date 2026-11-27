"""The tidy handoff: `omw2mwse --staged-root DIR --result-json FILE [--dry-run]` (docs/TIDY_INTERFACE.md).

One call converts the OpenMW mod(s) inside one staged mod folder, entirely inside that folder
(the omwcompat runtime included), and reports in a small JSON file. Exit codes:
0 converted (or nothing to convert), 1 blocked, 2 failed, 3 refused target, 64 usage error,
70 internal error. A blocked, failed or refused call writes nothing but the result JSON, and
so does --dry-run: the whole staged folder is planned first and only written when every mod in
it can be converted.
MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

import json
import os
import sys
import traceback
from pathlib import Path

from . import REQUIRES_PYTHON, __version__
from . import sidecar as SC
from .build import BuildError, atomic_write_bytes, runtime_version
from .convert import convert
from .optout import REASON_CODE as OPT_OUT_CODE
from .targets import TargetRefused, protected_reason

INTERFACE_VERSION = 1
EXIT_CONVERTED, EXIT_BLOCKED, EXIT_FAILED, EXIT_REFUSED_TARGET, EXIT_USAGE, EXIT_INTERNAL = 0, 1, 2, 3, 64, 70


def _inside(child: Path, parent: Path) -> bool:
    try:
        c, p = os.path.normcase(str(child.resolve())), os.path.normcase(str(parent.resolve()))
    except OSError:
        return False
    return c == p or c.startswith(p.rstrip("\\/") + os.sep)


def _base(staged, dry_run: bool) -> dict:
    return {"tool": "omw2mwse", "version": __version__, "interface": INTERFACE_VERSION, "requiresPython": REQUIRES_PYTHON,
            "staged_root": str(staged), "dry_run": bool(dry_run), "exit_code": EXIT_CONVERTED, "verdict": "none",
            "blockers": [], "guards": [], "runtime_version": runtime_version(), "written_files": [],
            "planned_files": [], "removed_files": [], "moved_files": [], "excluded_by_author": False,
            "errors": [], "mods": []}


def _fail(res: dict, code: int, verdict: str, err_code: str, message: str) -> dict:
    res["exit_code"], res["verdict"] = code, verdict
    res["errors"].append({"code": err_code, "message": message})
    return res


def write_result(path: Path, res: dict) -> None:
    atomic_write_bytes(Path(path), (json.dumps(res, indent=1, sort_keys=True) + "\n").encode("utf-8"))


def _summarise(res: dict, r: dict) -> None:
    """Fold convert()'s result r into the tidy result res (no exit code decisions here)."""
    guards = set()
    for m in r["mods"]:
        g = m.get("guards") or {}
        for names in g.values():
            guards.update(names)
        res["mods"].append({
            "name": m["name"], "source": m["source"], "status": m.get("status"), "verdict": m.get("verdict"),
            "blockers": m.get("blockers", []), "guards": g, "written_files": m.get("written", []),
            "planned_files": m.get("planned", []), "off": m.get("off"),
            "excluded_by_author": (m.get("reason") or {}).get("code") == OPT_OUT_CODE})
        res["written_files"] += m.get("written", [])
        res["planned_files"] += m.get("planned", [])
        res["removed_files"] += m.get("removedFiles", [])
        res["moved_files"] += m.get("relocated", [])
        res["blockers"] += m.get("blockers", [])
        rmsg = (m.get("reason") or {}).get("message")
        if m.get("verdict") == "blocked" and rmsg and rmsg not in m.get("blockers", []):
            res["blockers"].append(rmsg)
        if (m.get("reason") or {}).get("code") == OPT_OUT_CODE:
            res["excluded_by_author"] = True
        if m.get("status") == "refused":
            res["errors"].append({"code": "hardcode-not-accepted", "mod": m["name"], "message": m.get("message", "")})
        for c in m.get("conflicts", []):
            res["errors"].append({"code": "conflict", "mod": m["name"], "path": c["path"], "message": c["reason"]})
    res["guards"] = sorted(guards)
    for k in ("written_files", "planned_files", "removed_files", "moved_files"):
        res[k] = sorted(set(res[k]))
    for al in r["alerts"]:
        if al.get("level") == "error":
            res["errors"].append({"code": al.get("code", "error"), "message": al["message"]})


def _classify(r: dict) -> tuple:
    """(exit_code, verdict) of a convert() result, applying the all-or-nothing rule."""
    mods = r["mods"]
    if any(m.get("status") == "refused" for m in mods):
        return EXIT_FAILED, "failed"
    if any(m.get("status") == "conflict" for m in mods) or r.get("exitCode") in (2, 3, 4):
        return EXIT_FAILED, "failed"
    if any(m.get("verdict") == "blocked" for m in mods):
        return EXIT_BLOCKED, "blocked"
    if not mods:
        return EXIT_CONVERTED, "none"
    return EXIT_CONVERTED, "ready"


def run(staged_root, result_json, *, dry_run: bool = False, mode: str = "normal", name=None, source=None, sidecar=None,
        accept: bool = False, adopt: bool = False, meshes_from=None, title=None, credits=None) -> int:
    """Run the tidy handoff; writes result_json (always, when its location is allowed) and returns the exit code."""
    staged = Path(staged_root)
    res = _base(staged.absolute(), dry_run)
    out = Path(result_json)
    # where the result goes: outside the staged folder, never in Data Files or a game install
    if protected_reason(out.parent):
        print(f"omw2mwse: refused: --result-json {out} is in a Data Files folder or game install", file=sys.stderr)
        return EXIT_REFUSED_TARGET
    if _inside(out, staged):
        print(f"omw2mwse: error: --result-json {out} must be outside the staged folder", file=sys.stderr)
        return EXIT_USAGE
    try:
        try:
            res["staged_root"] = str(staged.resolve())
            if not staged.is_dir():
                _fail(res, EXIT_FAILED, "failed", "not-a-directory", f"{staged} is not a directory")
            else:
                kw = dict(name=name, source=Path(source) if source else None, sidecar_path=Path(sidecar) if sidecar else None,
                          accept=accept, adopt=adopt, meshes_from=[Path(meshes_from)] if meshes_from else None,
                          interactive=False, title=title, credits=credits)
                plan = convert(staged, mode, dry_run=True, strict_accept=True, **kw)
                code, verdict = _classify(plan)
                if code != EXIT_CONVERTED or dry_run:
                    _summarise(res, plan)
                    res["exit_code"], res["verdict"] = code, verdict
                else:
                    done = convert(staged, mode, dry_run=False, **kw)
                    code, verdict = _classify(done)
                    _summarise(res, done)
                    res["exit_code"], res["verdict"] = code, verdict
                if res["exit_code"] == EXIT_FAILED and not res["errors"]:
                    res["errors"].append({"code": "failed", "message": "the conversion could not be completed; see mods[]"})
        except TargetRefused as e:
            _fail(res, EXIT_REFUSED_TARGET, "refused", "target-refused", str(e))
        except (BuildError, SC.SidecarError) as e:
            _fail(res, EXIT_FAILED, "failed", "error", str(e))
    except Exception as e:                                           # a bug: report, do not guess
        _fail(res, EXIT_INTERNAL, "error", "internal-error", f"{type(e).__name__}: {e}")
        res["errors"][-1]["trace"] = traceback.format_exc().splitlines()[-6:]
    write_result(out, res)
    return res["exit_code"]
