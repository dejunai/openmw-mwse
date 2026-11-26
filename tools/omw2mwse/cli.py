"""Command line entry point: `python -m omw2mwse scan|package ...`."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import __version__
from .package import PackageError, package
from .scan import load_manifest, render_markdown, scan_mod


def _mods_in(path: Path, corpus: bool) -> list[Path]:
    if not corpus:
        return [path]
    return sorted(p for p in path.iterdir() if p.is_dir() and not p.name.startswith("."))


def cmd_scan(a) -> int:
    manifest = load_manifest(Path(a.manifest) if a.manifest else None)
    scans = []
    for p in a.paths:
        for m in _mods_in(Path(p), a.corpus):
            scans.append(scan_mod(m, manifest))
    if a.json:
        print(json.dumps([s.to_dict() for s in scans], indent=1))
    else:
        md = render_markdown(scans, title=a.title)
        if a.output:
            Path(a.output).parent.mkdir(parents=True, exist_ok=True)
            with open(a.output, "w", encoding="utf-8", newline="\n") as f:
                f.write(md)
            for s in scans:
                ok, total = s.coverage()
                print(f"{s.name}: {s.verdict} ({ok}/{total})")
        else:
            sys.stdout.write(md)
    return 1 if a.strict and any(s.verdict == "blocked" for s in scans) else 0


def cmd_package(a) -> int:
    try:
        r = package(Path(a.src), Path(a.out), name=a.name, slug=a.slug, with_runtime=not a.no_runtime,
                    meshes_from=Path(a.meshes_from) if a.meshes_from else None, force=a.force)
    except PackageError as e:
        print(f"omw2mwse: error: {e}", file=sys.stderr)
        return 2
    print(f"packaged {r['name']} -> {r['out']} (verdict: {r['verdict']}, mesh aliases: {len(r['aliases'])})")
    for n in r["notes"]:
        print(f"note: {n}")
    for b in r["blockers"]:
        print(f"blocker: {b}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="omw2mwse", description="Scan and package OpenMW Lua mods for MWSE (omwcompat).")
    ap.add_argument("--version", action="version", version=f"omw2mwse {__version__}")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan", help="report OpenMW API usage vs the omwcompat runtime")
    s.add_argument("paths", nargs="+")
    s.add_argument("--corpus", action="store_true", help="treat each subfolder of PATH as a separate mod")
    s.add_argument("--json", action="store_true")
    s.add_argument("-o", "--output", help="write markdown report to this file")
    s.add_argument("--title", default="omw2mwse scan")
    s.add_argument("--manifest")
    s.add_argument("--strict", action="store_true", help="exit 1 if any mod is blocked")
    s.set_defaults(func=cmd_scan)
    p = sub.add_parser("package", help="build an MWSE mod folder hosting the OpenMW Lua unmodified")
    p.add_argument("src")
    p.add_argument("--out", required=True)
    p.add_argument("--name")
    p.add_argument("--slug", help="short folder for mesh aliases (default: initials of the name)")
    p.add_argument("--meshes-from", help="a Data Files/meshes folder to copy long-path meshes from")
    p.add_argument("--no-runtime", action="store_true", help="do not bundle MWSE/lib/omwcompat")
    p.add_argument("--force", action="store_true", help="replace a previous omw2mwse output folder")
    p.set_defaults(func=cmd_package)
    return ap


def main(argv=None) -> int:
    a = build_parser().parse_args(argv)
    return a.func(a)
