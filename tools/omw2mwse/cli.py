"""Command line entry point: `python -m omw2mwse scan|package|convert ...`.

Tidy-style invocation is also accepted:
    omw2mwse --convert-omwscripts[=normal|hardcode] <staged-mod-dir> [convert options]
which is the same as `omw2mwse convert <staged-mod-dir> --mode MODE`.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import REQUIRES_PYTHON, __version__
from . import sidecar as SC
from . import warn
from .build import BuildError
from .convert import EXIT_ERROR, EXIT_REFUSED, MODES, convert
from .package import PackageError, package
from .scan import load_manifest, render_markdown, scan_mod


def _mods_in(path: Path, corpus: bool) -> list[Path]:
    if not corpus:
        return [path]
    return sorted(p for p in path.iterdir() if p.is_dir() and not p.name.startswith("."))


def _credits(a) -> dict:
    return {"author": a.author, "license": a.license, "url": a.source_url}


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
    mode = a.mode or ("hardcode" if a.sidecar else "normal")
    try:
        sc = SC.load(Path(a.sidecar)) if a.sidecar else None

        def confirm(plan):
            text = warn.render(a.name or Path(a.src).name, plan.conversions, mode, plan.sidecar)
            return warn.confirm(text, plan.conversions, a.accept_hardcode_conversions)

        r = package(Path(a.src), Path(a.out), name=a.name, slug=a.slug, with_runtime=not a.no_runtime,
                    meshes_from=Path(a.meshes_from) if a.meshes_from else None, force=a.force,
                    mode=mode, sidecar=sc, confirm=confirm, title=a.title, credits=_credits(a))
    except warn.Refused as e:
        print(f"omw2mwse: refused: {e}", file=sys.stderr)
        return EXIT_REFUSED
    except (PackageError, SC.SidecarError) as e:
        print(f"omw2mwse: error: {e}", file=sys.stderr)
        return EXIT_ERROR
    print(f"packaged {r['name']} -> {r['out']} (verdict: {r['verdict']}, mesh aliases: {len(r['aliases'])}, "
          f"hard-coded values converted: {len(r['rewrites'])})")
    for n in r["notes"]:
        print(f"note: {n}")
    for b in r["blockers"]:
        print(f"blocker: {b}")
    for al in r["alerts"]:
        if al.get("code") == "hardcode-candidate":
            print(f"candidate: {al['file']}:{al['line']} {al.get('name') or al.get('context')} = {al['value']}")
    return 0


def cmd_convert(a) -> int:
    try:
        r = convert(Path(a.dir), a.mode, name=a.name, source=Path(a.source) if a.source else None,
                    sidecar_path=Path(a.sidecar) if a.sidecar else None, accept=a.accept_hardcode_conversions,
                    dry_run=a.dry_run, adopt=a.adopt_existing, with_runtime=not a.no_runtime,
                    meshes_from=[Path(a.meshes_from)] if a.meshes_from else None, title=a.title, credits=_credits(a))
    except (BuildError, SC.SidecarError) as e:
        r = {"tool": "omw2mwse", "version": __version__, "requiresPython": REQUIRES_PYTHON, "command": "convert", "mode": a.mode, "dir": str(a.dir),
             "mods": [], "alerts": [{"level": "error", "code": "error", "message": str(e)}], "changed": False,
             "exitCode": EXIT_ERROR}
    if a.json:
        print(json.dumps(r, indent=1, default=str))
    else:
        for al in r["alerts"]:
            print(f"{al['level']}: {al['message']}")
        for m in r["mods"]:
            if m["status"] in ("refused",):
                print(f"{m['name']}: refused: {m['message']}")
                continue
            counts = {}
            for st in m["files"].values():
                counts[st] = counts.get(st, 0) + 1
            print(f"{m['name']} ({m['source']}): {m['status']}, verdict {m['verdict']}, files "
                  + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) + (" (dry run)" if r["dryRun"] else ""))
            for c in m["conflicts"]:
                print(f"  conflict: {c['path']}: {c['reason']}")
            for c in m["rewrites"]:
                print(f"  converted: {c['key']} {c['file']}:{c['line']} ({c['apply']})")
            for line in m["hardcodeLog"]:
                print(f"  hardcode: {line}")
            for al in m["alerts"]:
                if al["code"] == "hardcode-candidate":
                    print(f"  candidate: {al['file']}:{al['line']} {al.get('name') or al.get('context')} = {al['value']}")
                elif al["level"] != "info":
                    print(f"  {al['level']}: {al['message']}")
    return r["exitCode"]


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="omw2mwse", description="Scan, package and convert OpenMW Lua mods for MWSE (omwcompat).")
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

    def hard_opts(p):
        p.add_argument("--author", help="original author (credited; default from the sidecar [mod] table)")
        p.add_argument("--license", help="original license / permissions (credited)")
        p.add_argument("--source-url", help="original mod page (credited)")
        p.add_argument("--sidecar", help="<Mod>.omw2mwse.toml listing hard-coded values to expose")
        p.add_argument("--accept-hardcode-conversions", action="store_true",
                       help="accept the developer warning without a prompt (required when not interactive)")

    p = sub.add_parser("package", help="build a fresh MWSE mod folder (OUT/Data Files) from an OpenMW mod")
    p.add_argument("src")
    p.add_argument("--out", required=True)
    p.add_argument("--name")
    p.add_argument("--title", help="display name for the MCM page")
    p.add_argument("--slug", help="short folder for mesh aliases (default: initials of the name)")
    p.add_argument("--meshes-from", help="a Data Files/meshes folder to copy long-path meshes from")
    p.add_argument("--no-runtime", action="store_true", help="do not bundle MWSE/lib/omwcompat")
    p.add_argument("--force", action="store_true", help="replace a previous omw2mwse output folder")
    p.add_argument("--mode", choices=MODES, help="normal (default) or hardcode (default when --sidecar is given)")
    hard_opts(p)
    p.set_defaults(func=cmd_package)

    c = sub.add_parser("convert", help="convert a staged mod folder in place (idempotent; entry point for tidy)")
    c.add_argument("dir", help="staged mod folder (a Data Files root, e.g. a Vortex staging mod folder)")
    c.add_argument("--mode", choices=MODES, default="normal",
                   help="normal: scripts only, hard-code candidates reported as alerts; hardcode: also convert them")
    c.add_argument("--json", action="store_true", help="machine-readable result on stdout")
    c.add_argument("--dry-run", action="store_true", help="plan only; nothing is written (no prompt in hardcode mode)")
    c.add_argument("--name", help="mod name (default: the .omwscripts file name)")
    c.add_argument("--title", help="display name (MCM entry, notices)")
    c.add_argument("--source", help="the OpenMW mod folder to use when the staged folder holds several")
    c.add_argument("--adopt-existing", action="store_true",
                   help="treat existing output files without an omw2mwse manifest as ours (first run on a hand-installed folder)")
    c.add_argument("--no-runtime", action="store_true", help="do not write MWSE/lib/omwcompat")
    c.add_argument("--meshes-from", help="extra Data Files/meshes folder to copy long-path meshes from")
    hard_opts(c)
    c.set_defaults(func=cmd_convert)
    return ap


def translate_tidy_flag(argv: list[str]) -> list[str]:
    """--convert-omwscripts[=MODE] DIR ... -> convert DIR --mode MODE ..."""
    out, mode, found = [], None, False
    for x in argv:
        if x == "--convert-omwscripts":
            found, mode = True, "normal"
        elif x.startswith("--convert-omwscripts="):
            found, mode = True, x.split("=", 1)[1] or "normal"
        else:
            out.append(x)
    if not found:
        return argv
    if mode not in MODES:
        raise SystemExit(f"omw2mwse: --convert-omwscripts must be one of {', '.join(MODES)} (got {mode!r})")
    return ["convert"] + out + ["--mode", mode]


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    a = build_parser().parse_args(translate_tidy_flag(argv))
    return a.func(a)
