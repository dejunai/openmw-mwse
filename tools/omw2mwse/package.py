"""`package`: build a fresh MWSE mod folder (OUT/Data Files/...) from an OpenMW mod source."""
from __future__ import annotations

import json
import shutil
from pathlib import Path

from . import __version__
from .build import (BuildError, Writer, build, default_slug, lua_str, mesh_alias, render_main,  # noqa: F401 (re-exported)
                    render_metadata, sha256b, text_bytes)
from .scan import load_manifest

MARKER = ".omw2mwse-output"
PackageError = BuildError


def _tree_hashes(root: Path) -> dict:
    return {p: sha256b(p.read_bytes()) for p in sorted(root.rglob("*")) if p.is_file()}


def package(src: Path, out: Path, name: str | None = None, slug: str | None = None, with_runtime: bool = True,
            meshes_from: Path | None = None, force: bool = False, manifest: dict | None = None,
            mode: str = "normal", sidecar: dict | None = None, confirm=None, title: str | None = None,
            credits: dict | None = None) -> dict:
    src, out = Path(src).resolve(), Path(out).resolve()
    if not src.is_dir():
        raise PackageError(f"source {src} is not a directory")
    if out == src or src in out.parents or out in src.parents:
        raise PackageError("output must not be inside the source (or vice versa)")
    manifest = manifest or load_manifest()
    name = name or src.name
    if out.exists():
        if not force:
            raise PackageError(f"{out} exists (use --force to replace a previous omw2mwse output)")
        if not (out / MARKER).exists():
            raise PackageError(f"{out} exists and was not created by omw2mwse; refusing to replace it")
    before = _tree_hashes(src)
    w = Writer(out)
    res = build(src, w, name, data_prefix="Data Files", slug=slug, with_runtime=with_runtime,
                meshes_from=[Path(meshes_from)] if meshes_from else None, mode=mode, sidecar=sidecar,
                confirm=confirm, manifest=manifest, title=title, credits=credits)
    rows = ["# Mesh aliases (R4: Morrowind record mesh paths are limited to 31 chars)",
            "# source (relative to Data Files/meshes)\talias (relative to Data Files/meshes)\tstatus"]
    rows += [f"{a}\t{b}\t{c}" for a, b, c in res.aliases]
    w.put("MESH-ALIASES.txt", text_bytes("\n".join(rows) + "\n"))
    w.put("OMW2MWSE-REPORT.md", text_bytes(res.report_md))
    w.put(MARKER, text_bytes(json.dumps({"tool": "omw2mwse", "version": __version__, "source": str(src)}) + "\n"))
    if out.exists():
        shutil.rmtree(out)
    w.check()
    w.commit()
    if _tree_hashes(src) != before:
        raise PackageError("source tree changed during packaging (this is a bug)")
    return {"out": str(out), "name": res.name, "slug": res.slug, "verdict": res.scan.verdict, "aliases": res.aliases,
            "copied": [(str(src / a), str(out / "Data Files" / "MWSE" / "mods" / "mwsuite" / "openmw" / res.name / "omw" / b)) for a, b, _ in res.copied],
            "notes": res.notes, "blockers": res.scan.blockers, "rewrites": [c.to_json() for c in res.accepted],
            "alerts": res.alerts, "result": res}
