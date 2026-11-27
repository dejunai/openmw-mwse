"""Command line entry point: `python -m omw2mwse scan|package|convert|recover|api-audit ...`.

The tidy handoff (docs/TIDY_INTERFACE.md):
    omw2mwse --staged-root <staged-mod-dir> --result-json <file> [--dry-run] [convert options]
which is `omw2mwse convert --staged-root ...`: everything is written inside the staged folder,
nothing else but the result file, and a Data Files folder or game install is refused (exit 3).
The older form is also accepted:
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
from . import apicatalog as AC
from . import recovery as RC
from .package import PackageError, package
from . import tidy as TD
from .targets import TargetRefused, refuse_protected
from .scan import load_manifest, render_markdown, scan_mod


def _mods_in(path: Path, corpus: bool) -> list[Path]:
    if not corpus:
        return [path]
    return sorted(p for p in path.iterdir() if p.is_dir() and not p.name.startswith("."))


def _credits(a) -> dict:
    return {"author": a.author, "license": a.license, "url": a.source_url}


def _catalog(a):
    """The OpenMW API catalog for scan/api-audit: --openmw/--openmw-src, else $OMW2MWSE_OPENMW, the newest
    cached download, then common install paths. (None, searched) when there is none."""
    explicit = getattr(a, "openmw", None) or getattr(a, "openmw_src", None)
    if getattr(a, "no_openmw", False):
        return None, []
    return AC.locate(explicit, cache_root=getattr(a, "api_cache", None),
                     use_installs=not getattr(a, "no_installs", False))


def cmd_scan(a) -> int:
    manifest = load_manifest(Path(a.manifest) if a.manifest else None)
    catalog, _searched = _catalog(a)
    if (a.openmw or a.openmw_src) and catalog is None and not a.no_openmw:
        print(f"omw2mwse: no OpenMW API files under {a.openmw or a.openmw_src}; scanning without them", file=sys.stderr)
    scans = []
    for p in a.paths:
        for m in _mods_in(Path(p), a.corpus):
            scans.append(scan_mod(m, manifest, catalog=catalog))
    if a.json:
        print(json.dumps([s.to_dict() for s in scans], indent=1))
    else:
        md = render_markdown(scans, title=a.title)
        if a.output:
            refuse_protected(Path(a.output).parent, "report folder")
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

        r = package(Path(a.src), Path(a.out), name=a.name, slug=a.slug,
                    meshes_from=Path(a.meshes_from) if a.meshes_from else None, force=a.force,
                    mode=mode, sidecar=sc, confirm=confirm, title=a.title, credits=_credits(a))
    except TargetRefused as e:
        print(f"omw2mwse: refused: {e}", file=sys.stderr)
        return EXIT_REFUSED
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
    if a.no_runtime:
        print("omw2mwse: note: --no-runtime is ignored; the omwcompat runtime is always written into the staged folder",
              file=sys.stderr)
    if a.staged_root and a.dir and Path(a.staged_root) != Path(a.dir):
        print("omw2mwse: error: the staged folder is given twice and differs (use --staged-root only)", file=sys.stderr)
        return TD.EXIT_USAGE
    root = a.staged_root or a.dir
    if not root:
        print("omw2mwse: error: a staged mod folder is required (--staged-root DIR)", file=sys.stderr)
        return TD.EXIT_USAGE
    if a.result_json or a.staged_root:
        if not a.result_json:
            print("omw2mwse: error: --staged-root needs --result-json FILE (the tidy handoff)", file=sys.stderr)
            return TD.EXIT_USAGE
        code = TD.run(root, a.result_json, dry_run=a.dry_run, mode=a.mode, name=a.name, source=a.source, sidecar=a.sidecar,
                      accept=a.accept_hardcode_conversions, adopt=a.adopt_existing, meshes_from=a.meshes_from,
                      title=a.title, credits=_credits(a))
        print(f"omw2mwse: {'dry run: ' if a.dry_run else ''}exit {code}; result in {a.result_json}")
        return code
    try:
        r = convert(Path(root), a.mode, name=a.name, source=Path(a.source) if a.source else None,
                    sidecar_path=Path(a.sidecar) if a.sidecar else None, accept=a.accept_hardcode_conversions,
                    dry_run=a.dry_run, adopt=a.adopt_existing,
                    meshes_from=[Path(a.meshes_from)] if a.meshes_from else None, title=a.title, credits=_credits(a))
    except TargetRefused as e:
        print(f"omw2mwse: refused: {e}", file=sys.stderr)
        return EXIT_REFUSED
    except (BuildError, SC.SidecarError) as e:
        r = {"tool": "omw2mwse", "version": __version__, "requiresPython": REQUIRES_PYTHON, "command": "convert", "mode": a.mode, "dir": str(root),
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


def cmd_recover(a) -> int:
    """Report (default) or roll back convert runs that did not finish (recovery journals)."""
    try:
        refuse_protected(a.dir, "staged folder")
    except TargetRefused as e:
        print(f"omw2mwse: refused: {e}", file=sys.stderr)
        return EXIT_REFUSED
    staged = Path(a.dir).resolve()
    r = {"tool": "omw2mwse", "version": __version__, "requiresPython": REQUIRES_PYTHON, "command": "recover",
         "dir": str(staged), "rollback": bool(a.rollback), "rolledBack": [], "pendingRecovery": [], "alerts": [],
         "exitCode": 0}
    if not staged.is_dir():
        r["alerts"].append({"level": "error", "code": "error", "message": f"{staged} is not a directory"})
        r["exitCode"] = EXIT_ERROR
    else:
        for j in RC.pending(staged):
            if a.name and j.get("mod") != a.name:
                continue
            if a.rollback:
                if j.get("stage") == "unreadable":
                    r["alerts"].append({"level": "error", "code": "journal-unreadable",
                                        "path": RC.describe(j, staged)["journal"],
                                        "message": "the recovery journal cannot be read; nothing was rolled back"})
                    r["exitCode"] = EXIT_ERROR
                    continue
                r["rolledBack"].append(RC.rollback(staged, j))
        r["pendingRecovery"] = [RC.describe(j, staged) for j in RC.pending(staged)]
    if a.json:
        print(json.dumps(r, indent=1))
    else:
        for al in r["alerts"]:
            print(f"{al['level']}: {al['message']}")
        for rb in r["rolledBack"]:
            print(f"{rb['mod']}: rolled back (was at stage {rb['stage']}): restored {len(rb['restored'])}, "
                  f"removed {len(rb['removed'])}, left alone {len(rb['kept'])}")
            for k in rb["kept"]:
                print(f"  left alone: {k['path']}: {k['reason']}")
        for p in r["pendingRecovery"]:
            print(f"{p['mod']}: unfinished convert run (stage {p['stage']}); run convert again to finish it, "
                  "or recover --rollback to undo it")
        if not r["rolledBack"] and not r["pendingRecovery"] and not r["alerts"]:
            print("nothing to recover")
    return r["exitCode"]


def cmd_api_audit(a) -> int:
    """Compare manifest.json with OpenMW's own Lua API files (read only; a no-op without a copy)."""
    if a.fetch:
        try:
            dest = AC.fetch(a.fetch, cache_root=a.api_cache, refresh=a.refresh)
        except AC.FetchError as e:
            print(f"omw2mwse: {e}", file=sys.stderr)
            return EXIT_ERROR
        a.openmw = str(dest)
    catalog, searched = _catalog(a)
    if catalog is None:
        r = AC.not_found(searched)
    else:
        r = AC.audit(catalog, load_manifest(Path(a.manifest) if a.manifest else None), limit=a.limit)
    if a.json:
        print(json.dumps(r, indent=1))
    else:
        sys.stdout.write(AC.render(r))
    return 0


def _openmw_opts(p, fetch: bool = False) -> None:
    p.add_argument("--openmw", metavar="DIR", help="an OpenMW install, source tree or api-audit cache folder")
    p.add_argument("--openmw-src", metavar="DIR", help="an OpenMW source tree (files/lua_api/openmw); same as --openmw")
    p.add_argument("--api-cache", metavar="DIR", help=f"cache root for downloaded API files (default ${AC.ENV_CACHE}, "
                   "else the user cache folder)")
    p.add_argument("--no-installs", action="store_true", help="do not look for an OpenMW install")
    if fetch:
        p.add_argument("--fetch", metavar="TAG", help="download the API files of this release tag (e.g. openmw-0.51.0) "
                       "into the cache first (only those files)")
        p.add_argument("--refresh", action="store_true", help="download again even when the cache has the tag")
    else:
        p.add_argument("--no-openmw", action="store_true", help="do not use OpenMW's API files even if found")


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
    _openmw_opts(s)
    s.set_defaults(func=cmd_scan)

    au = sub.add_parser("api-audit", help="compare the omwcompat manifest with OpenMW's own Lua API files")
    au.add_argument("--json", action="store_true")
    au.add_argument("--manifest")
    au.add_argument("--limit", type=int, default=0, help="at most N entries in the long lists (default: all)")
    _openmw_opts(au, fetch=True)
    au.set_defaults(func=cmd_api_audit)

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
    p.add_argument("--meshes-from", help="a meshes folder to copy long-path meshes from (not a Data Files or game folder)")
    p.add_argument("--no-runtime", action="store_true", help="ignored (since 0.3.1 the runtime is always bundled)")
    p.add_argument("--force", action="store_true", help="replace a previous omw2mwse output folder")
    p.add_argument("--mode", choices=MODES, help="normal (default) or hardcode (default when --sidecar is given)")
    hard_opts(p)
    p.set_defaults(func=cmd_package)

    c = sub.add_parser("convert", help="convert a staged mod folder in place (idempotent; entry point for tidy)")
    c.add_argument("dir", nargs="?", help="staged mod folder (a Vortex staging mod folder; never Data Files or a game install); "
                   "same as --staged-root but without the tidy result file and exit codes")
    c.add_argument("--staged-root", metavar="DIR", help="the staged mod folder: tidy handoff mode (needs --result-json; "
                   "see docs/TIDY_INTERFACE.md)")
    c.add_argument("--result-json", metavar="FILE", help="write the tidy result here (outside the staged folder)")
    c.add_argument("--mode", choices=MODES, default="normal",
                   help="normal: scripts only, hard-code candidates reported as alerts; hardcode: also convert them")
    c.add_argument("--json", action="store_true", help="machine-readable result on stdout")
    c.add_argument("--dry-run", action="store_true", help="plan only; nothing is written (no prompt in hardcode mode)")
    c.add_argument("--name", help="mod name (default: the .omwscripts file name)")
    c.add_argument("--title", help="display name (MCM entry, notices)")
    c.add_argument("--source", help="the OpenMW mod folder to use when the staged folder holds several")
    c.add_argument("--adopt-existing", action="store_true",
                   help="treat existing output files without an omw2mwse manifest as ours (first run on a hand-installed folder)")
    c.add_argument("--no-runtime", action="store_true", help="ignored (since 0.3.1 the runtime is always written into the staged folder)")
    c.add_argument("--meshes-from", help="extra meshes folder to copy long-path meshes from (not a Data Files or game folder)")
    hard_opts(c)
    c.set_defaults(func=cmd_convert)

    rv = sub.add_parser("recover", help="report or roll back convert runs that were interrupted")
    rv.add_argument("dir", help="staged mod folder given to convert")
    rv.add_argument("--rollback", action="store_true",
                    help="undo unfinished runs (default: only report them; re-running convert finishes them)")
    rv.add_argument("--name", help="only this mod (the MWSE/mods/mwsuite/openmw/<Mod> name)")
    rv.add_argument("--json", action="store_true")
    rv.set_defaults(func=cmd_recover)
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


SUBCOMMANDS = ("scan", "api-audit", "package", "convert", "recover")


def translate_staged_root(argv: list[str]) -> list[str]:
    """`omw2mwse --staged-root DIR --result-json F ...` (no subcommand) -> `convert --staged-root DIR ...`."""
    if any(x == "--staged-root" or x.startswith("--staged-root=") for x in argv) and not any(x in SUBCOMMANDS for x in argv[:1]):
        return ["convert"] + argv
    return argv


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    argv = translate_staged_root(translate_tidy_flag(argv))
    contract = "--staged-root" in " ".join(argv) or any(x.startswith("--result-json") for x in argv)
    try:
        a = build_parser().parse_args(argv)
    except SystemExit as e:
        # tidy form: a usage error is 64, so that 2 only ever means "failed" (docs/TIDY_INTERFACE.md)
        if contract and e.code == 2:
            raise SystemExit(TD.EXIT_USAGE)
        raise
    try:
        return a.func(a)
    except TargetRefused as e:
        print(f"omw2mwse: refused: {e}", file=sys.stderr)
        return EXIT_REFUSED
