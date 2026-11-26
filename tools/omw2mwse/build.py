"""Core build used by `package` (fresh output folder) and `convert` (in place).

build() turns one OpenMW mod source tree into MWSE files under a Data Files root:
  MWSE/mods/<Mod>/main.lua              generated loader (omwcompat.register spec)
  MWSE/omw/<Mod>/...                    the OpenMW Lua (+ .omwscripts, l10n)
  MWSE/omw/<Mod>/_original/...          verbatim copies of any Lua rewritten for hard-codes
  MWSE/lib/omwcompat(.lua)              the runtime (unless with_runtime=False)
  meshes/omwc/<slug>/<hash>.nif         short aliases for long mesh paths (R4)
  <Mod>-metadata.toml
Writes are two-phase (plan, then commit) so a conflict aborts before any change.
MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from . import __version__
from . import constants as K
from . import sidecar as SC
from .scan import ModScan, find_lua_files, find_omwscripts, normalize_mesh, read_text, render_markdown, scan_mod

HERE = Path(__file__).resolve().parent
RUNTIME_LIB = HERE.parent.parent / "runtime" / "MWSE" / "lib"
MAX_MESH = 31
MANIFEST_NAME = "omw2mwse-manifest.json"


class BuildError(Exception):
    pass


def default_slug(name: str) -> str:
    caps = re.findall(r"[A-Z0-9]", name)
    slug = "".join(caps).lower() if len(caps) >= 2 else re.sub(r"[^a-z0-9]", "", name.lower())
    return (slug or "mod")[:8]


def mesh_alias(slug: str, normalized: str) -> str:
    h = hashlib.sha1(normalized.encode("utf-8")).hexdigest()[:8]
    alias = f"omwc/{slug}/{h}.nif"
    if len(alias) > MAX_MESH:
        raise BuildError(f"alias {alias} too long; use a shorter --slug")
    return alias


def lua_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def sha256b(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def text_bytes(s: str) -> bytes:
    return s.replace("\r\n", "\n").encode("utf-8")  # UTF-8, no BOM, LF


# ------------------------------------------------------------------ writer
class Writer:
    """Plans file writes under root, detects conflicts, then commits atomically per file.

    previous: {rel: sha256} from the last omw2mwse manifest (files we own).
    Existing files that are not ours and differ are conflicts unless adopt=True.
    """

    def __init__(self, root: Path, previous: dict | None = None, adopt: bool = False):
        self.root = Path(root)
        self.previous = previous or {}
        self.adopt = adopt
        self.plan: dict[str, bytes] = {}
        self.status: dict[str, str] = {}
        self.conflicts: list[dict] = []
        self.removed: list[str] = []

    def put(self, rel: str, data: bytes) -> None:
        rel = rel.replace("\\", "/")
        if rel in self.plan and self.plan[rel] != data:
            raise BuildError(f"two different outputs for {rel}")
        self.plan[rel] = data

    def check(self) -> None:
        for rel, data in self.plan.items():
            p = self.root / rel
            if not p.exists():
                self.status[rel] = "created"
                continue
            cur = p.read_bytes()
            if cur == data:
                self.status[rel] = "unchanged"
            elif rel in self.previous and sha256b(cur) == self.previous[rel]:
                self.status[rel] = "updated"
            elif rel in self.previous:
                self.conflicts.append({"path": rel, "reason": "edited by hand since the last omw2mwse run"})
            elif self.adopt:
                self.status[rel] = "updated"
            else:
                self.conflicts.append({"path": rel, "reason": "existing file not written by omw2mwse"})
        for rel, sha in self.previous.items():
            if rel in self.plan:
                continue
            p = self.root / rel
            if p.is_file() and sha256b(p.read_bytes()) == sha:
                self.status[rel] = "removed"

    def commit(self) -> None:
        for rel, data in sorted(self.plan.items()):
            if self.status.get(rel) == "unchanged":
                continue
            p = self.root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            # write a temp file then rename over: an existing hardlink (e.g. Vortex deployment)
            # keeps pointing at the old content instead of being modified in place
            fd, tmp = tempfile.mkstemp(dir=p.parent, prefix=".omw2mwse-", suffix=".tmp")
            try:
                with os.fdopen(fd, "wb") as f:
                    f.write(data)
                os.replace(tmp, p)
            except BaseException:
                if os.path.exists(tmp):
                    os.remove(tmp)
                raise
            if p.read_bytes() != data:
                raise BuildError(f"write verification failed for {rel}")
        for rel, st in list(self.status.items()):
            if st == "removed":
                os.remove(self.root / rel)
                self.removed.append(rel)

    def changed(self) -> bool:
        return any(s != "unchanged" for s in self.status.values())


# ------------------------------------------------------------------ hard-code planning
def _humanize(name: str) -> str:
    s = re.sub(r"[_\s]+", " ", name).strip()
    s = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", s)
    return s[:1].upper() + s[1:].lower() if s.isupper() else s[:1].upper() + s[1:]


def _excerpt(src: str, start: int, end: int, replacement: str | None = None) -> str:
    ls = src.rfind("\n", 0, start) + 1
    le = src.find("\n", end)
    le = len(src) if le < 0 else le
    line = src[ls:le]
    if replacement is not None:
        line = src[ls:start] + replacement + src[end:le]
    return line.strip()


@dataclass
class HardcodePlan:
    conversions: list = field(default_factory=list)
    log: list = field(default_factory=list)         # one line per candidate decision
    alerts: list = field(default_factory=list)
    sidecar: str | None = None


def plan_hardcodes(sources: dict[str, str], mode: str, sidecar: dict | None) -> HardcodePlan:
    """sources: {target_rel: lua text}. mode: normal | hardcode."""
    plan = HardcodePlan(sidecar=sidecar.get("_path") if sidecar else None)
    detected = {}
    for rel, src in sources.items():
        try:
            detected[rel] = K.detect(src)
        except Exception as e:  # tokenizer error: scan already reports it
            plan.alerts.append({"level": "warning", "code": "hardcode-scan-failed", "file": rel, "message": str(e)})
            detected[rel] = ([], [])
    if mode == "normal":
        for rel, (consts, inline) in detected.items():
            for c in consts:
                if c.eligible:
                    plan.alerts.append({"level": "info", "code": "hardcode-candidate", "file": rel, "line": c.line,
                                        "kind": "constant", "name": c.name, "type": c.type, "value": c.literal,
                                        "autoPick": c.upper and c.type != "string",
                                        "risks": c.risks,
                                        "message": f"top-level constant {c.name} = {c.literal} could be exposed as a setting "
                                                   "(--convert-omwscripts=hardcode)"})
            for x in inline:
                plan.alerts.append({"level": "info", "code": "hardcode-candidate", "file": rel, "line": x.line,
                                    "kind": "literal", "context": x.context, "type": x.type, "value": x.literal,
                                    "function": x.function, "autoPick": False,
                                    "message": f"literal {x.literal} in '{x.context}' ({x.function}) could be exposed via a sidecar [[literal]]"})
        if sidecar:
            plan.alerts.append({"level": "info", "code": "sidecar-ignored", "file": sidecar["_path"],
                                "message": "sidecar present but mode is normal: no hard-coded values were converted"})
        return plan

    def resolve_file(f: str | None, pred) -> str:
        if f:
            f = f.replace("\\", "/")
            hits = [r for r in sources if r == f or r.lower() == f.lower()]
            if not hits:
                raise SC.SidecarError(f"file {f} is not one of the mod's Lua files")
            return hits[0]
        hits = [r for r in sources if pred(r)]
        if len(hits) != 1:
            raise SC.SidecarError(f"cannot pick a file ({len(hits)} candidates); add file = ...")
        return hits[0]

    if sidecar:
        for e in sidecar.get("constant", []):
            name = e["name"]
            rel = resolve_file(e.get("file"), lambda r: any(c.name == name for c in detected[r][0]))
            c = next((c for c in detected[rel][0] if c.name == name), None)
            if c is None:
                raise SC.SidecarError(f"constant {name}: no top-level `local {name} = <literal>` in {rel}")
            if not c.eligible:
                raise SC.SidecarError(f"constant {name} in {rel} cannot be converted: {c.reason}")
            plan.conversions.append(_conv_const(rel, sources[rel], c, e, "sidecar"))
            plan.log.append(f"{rel}:{c.line} {name}: converted (sidecar)")
        for e in sidecar.get("literal", []):
            rel = resolve_file(e["file"], lambda r: True)
            try:
                s, en, raw, kind, val, in_fn, in_tbl = K.find_literal(sources[rel], int(e["line"]), e["context"], e.get("literal"))
            except ValueError as err:
                raise SC.SidecarError(f"literal {e['key']}: {err}") from err
            conv = _conv_lit(rel, sources[rel], e, s, en, raw, kind, val, in_fn, in_tbl)
            plan.conversions.append(conv)
            plan.log.append(f"{rel}:{conv.line} {conv.key}: converted (sidecar literal '{e['context']}')")
    else:
        for rel, (consts, inline) in detected.items():
            for c, why in K.auto_pick(consts):
                if why.startswith("picked"):
                    plan.conversions.append(_conv_const(rel, sources[rel], c, {}, "auto: " + why[8:]))
                plan.log.append(f"{rel}:{c.line} {c.name}: {why}")
            for x in inline:
                plan.log.append(f"{rel}:{x.line} '{x.context}': skipped: inline literals are only converted from a sidecar")
    for c in plan.conversions:
        if c.default is not None and isinstance(c.default, float) and c.default != c.default:
            raise SC.SidecarError(f"{c.key}: NaN default")
    return plan


def _check_default(e: dict, value, key: str):
    if "default" in e and e["default"] != value:
        raise SC.SidecarError(f"{key}: sidecar default {e['default']!r} differs from the original value {value!r} "
                              "(the default is always the author's value)")


def _conv_const(rel, src, c: K.Constant, e: dict, origin: str) -> K.Conversion:
    key = e.get("key", c.name)
    if not K.KEY_RE.match(key):
        raise SC.SidecarError(f"bad key {key!r}")
    _check_default(e, c.value, key)
    conv = K.Conversion(key=key, kind="constant", file=rel, line=c.line, name=c.name, type=c.type, literal=c.literal,
                        default=c.value, start=c.start, end=c.end, apply="reload",
                        label=e.get("label", _humanize(c.name)), description=e.get("description", ""),
                        min=e.get("min"), max=e.get("max"), integer=bool(e.get("integer", False)),
                        risks=list(c.risks), origin=origin)
    conv.before = _excerpt(src, c.start, c.end)
    conv.after = _excerpt(src, c.start, c.end, conv.replacement())
    fns = ", ".join(sorted(c.functions)) or "top-level code"
    conv.apply_note = f"on script reload (value is captured when the chunk runs; read by {fns})"
    return conv


def _conv_lit(rel, src, e, s, en, raw, kind, val, in_fn, in_tbl) -> K.Conversion:
    key = e["key"]
    if not K.KEY_RE.match(key):
        raise SC.SidecarError(f"bad key {key!r}")
    _check_default(e, val, key)
    toks_line = src.count("\n", 0, s) + 1
    risks = []
    if kind == "string":
        risks.append("string literal: often a record id, path or event name")
    if not in_fn:
        risks.append("evaluated at load time (outside any function)" + (" inside a table constructor" if in_tbl else ""))
    conv = K.Conversion(key=key, kind="literal", file=rel, line=toks_line, name=e["context"], type=kind, literal=raw,
                        default=val, start=s, end=en, apply="live" if in_fn else "reload",
                        label=e.get("label", _humanize(key)), description=e.get("description", ""),
                        min=e.get("min"), max=e.get("max"), integer=bool(e.get("integer", False)),
                        risks=risks, origin="sidecar")
    conv.before = _excerpt(src, s, en)
    conv.after = _excerpt(src, s, en, conv.replacement())
    if in_fn:
        fn = _enclosing_function(src, s)
        conv.function = fn
        conv.apply_note = f"live (read every time {fn} runs)"
    else:
        conv.apply_note = "on script reload (evaluated once when the chunk runs)"
    return conv


def _enclosing_function(src: str, pos: int) -> str:
    toks = K.tokenize(src)
    ann = K.annotate(toks)
    for t, a in zip(toks, ann):
        if t.start >= pos:
            return a[3] or "<top level>"
    return "<top level>"


# ------------------------------------------------------------------ loader / metadata
def render_main(name: str, scripts, meshmap: dict[str, str], probe: bool = False, cfg: dict | None = None,
                title: str | None = None) -> str:
    lines = [
        f"-- {name}: MWSE loader generated by omw2mwse {__version__}.",
        "-- The OpenMW Lua lives in Data Files/MWSE/omw/" + name + "/ and is hosted by the",
        "-- omwcompat runtime (Data Files/MWSE/lib/omwcompat).",
        "-- Generated file: re-run omw2mwse instead of editing.",
        "local ok, omwcompat = pcall(require, \"omwcompat\")",
        "if not ok then",
        f"    mwse.log(\"[{name}] omwcompat runtime is missing or failed to load: %s\", tostring(omwcompat))",
        "    return",
        "end",
        "",
        "omwcompat.register({",
        f"    mod = {lua_str(name)},",
    ]
    if title:
        lines.append(f"    title = {lua_str(title)},")
    lines += [f"    root = {lua_str('Data Files/MWSE/omw/' + name + '/')},", "    scripts = {"]
    for s in scripts:
        flags = ", ".join(lua_str(f) for f in s.flags)
        lines.append(f"        {{ flags = {{ {flags} }}, path = {lua_str(s.path)} }},")
    lines.append("    },")
    lines.append("    meshmap = {")
    for src, dst in sorted(meshmap.items()):
        lines.append(f"        [{lua_str(src)}] = {lua_str(dst)},")
    lines.append("    },")
    if probe:
        lines.append("    probeSettings = true, -- collect I.Settings declarations for the MCM")
    if cfg:
        lines.append("    settings = { -- hard-coded values exposed by omw2mwse (developer-approved)")
        lines.append(f"        group = {lua_str(cfg['group'])},")
        lines.append(f"        groupName = {lua_str(cfg['groupName'])},")
        lines.append(f"        page = {{ key = {lua_str(cfg['group'])}, name = {lua_str(cfg['page'])}, "
                     f"description = {lua_str(cfg['description'])} }},")
        lines.append("        settings = {")
        for c in cfg["conversions"]:
            renderer = {"boolean": "checkbox", "number": "number"}.get(c.type, "textLine")
            parts = [f"key = {lua_str(c.key)}", f"name = {lua_str(c.label)}"]
            desc = c.description
            src_note = f"Hard-coded in {c.file}:{c.line} as {c.literal}."
            desc = (desc + "\n\n" if desc else "") + src_note
            parts.append(f"description = {lua_str(desc)}")
            parts.append(f"renderer = {lua_str(renderer)}")
            parts.append(f"default = {c.literal}")
            for k in ("min", "max"):
                v = getattr(c, k)
                if v is not None:
                    parts.append(f"{k} = {v!r}")
            if c.integer:
                parts.append("integer = true")
            parts.append(f"apply = {lua_str(c.apply)}")
            lines.append("            { " + ", ".join(parts) + " },")
        lines.append("        },")
        lines.append("    },")
    lines.append("})")
    return "\n".join(lines) + "\n"


def render_metadata(name: str, src_name: str) -> str:
    return (
        "[package]\n"
        f"name = \"{name}\"\n"
        f"description = \"{src_name} (OpenMW Lua) hosted on MWSE via omwcompat; built by omw2mwse {__version__}\"\n"
        "\n"
        "[tools.mwse]\n"
        f"lua-mod = \"{name}\"\n"
    )


# ------------------------------------------------------------------ build
@dataclass
class BuildResult:
    name: str
    slug: str
    source: str
    scan: ModScan
    writer: Writer
    omw_rel: str
    copied: list = field(default_factory=list)       # (source rel, target rel, rewritten?)
    aliases: list = field(default_factory=list)      # (source, alias, status)
    notes: list = field(default_factory=list)
    hard: HardcodePlan | None = None
    accepted: list = field(default_factory=list)
    report_md: str = ""
    alerts: list = field(default_factory=list)


def build(src: Path, writer: Writer, name: str, *, data_prefix: str = "", slug: str | None = None,
          with_runtime: bool = True, meshes_from: list[Path] | None = None, mode: str = "normal",
          sidecar: dict | None = None, confirm=None, manifest: dict | None = None,
          title: str | None = None) -> BuildResult:
    """Plan all outputs for one mod into writer (paths relative to writer.root, under data_prefix).

    confirm(plan) -> accepted conversions (raises warn.Refused); required when mode == 'hardcode'.
    """
    src = Path(src)
    if not re.fullmatch(r"[A-Za-z0-9_\-]+", name):
        raise BuildError(f"mod name {name!r} must be [A-Za-z0-9_-]")
    scan = scan_mod(src, manifest, name=name)
    if not scan.scripts:
        raise BuildError(f"{src}: no .omwscripts declarations found; nothing to host")
    slug = slug or default_slug(name)
    D = (data_prefix.rstrip("/") + "/") if data_prefix else ""
    omw = f"{D}MWSE/omw/{name}/"
    res = BuildResult(name=name, slug=slug, source=str(src), scan=scan, writer=writer, omw_rel=omw)

    # 1. Lua placement
    declared = {s.path.lower(): s.path for s in scan.scripts}
    by_base: dict[str, list[str]] = {}
    for d in declared.values():
        by_base.setdefault(Path(d).name.lower(), []).append(d)
    # directory case as declared (OpenMW's VFS and Windows ignore case; require() paths
    # follow the .omwscripts spelling, so align e.g. Scripts/X/ to scripts/X/)
    dir_case: dict[str, str] = {}
    for d in declared.values():
        parts = d.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dir_case.setdefault("/".join(parts[:i]).lower(), "/".join(parts[:i]))

    def case_fix(rel: str) -> str:
        parts = rel.split("/")
        for i in range(len(parts) - 1, 0, -1):
            pre = "/".join(parts[:i])
            if pre.lower() in dir_case and dir_case[pre.lower()] != pre:
                fixed = dir_case[pre.lower()] + "/" + "/".join(parts[i:])
                res.notes.append(f"{rel} placed at {fixed} (directory case as declared in .omwscripts)")
                return fixed
            if pre.lower() in dir_case:
                break
        return rel

    lua: dict[str, tuple[str, str]] = {}   # target rel (in omw root) -> (source rel, text)
    files = [(p, p.relative_to(src).as_posix()) for p in find_lua_files(src)]
    fixed = {rel: case_fix(rel) for _, rel in files}
    provided = {t.lower() for t in fixed.values()}
    for p, rel in files:
        target_rel = fixed[rel]
        if target_rel.lower() not in declared:
            cands = by_base.get(p.name.lower(), [])
            if len(cands) == 1 and cands[0].lower() not in provided:
                target_rel = cands[0]
                provided.add(target_rel.lower())
                res.notes.append(f"source has {rel} but .omwscripts declares {cands[0]}; placed at the declared path")
        if target_rel in lua:
            raise BuildError(f"two source files map to {target_rel} ({lua[target_rel][0]}, {rel})")
        lua[target_rel] = (rel, p.read_bytes())

    # 2. hard-coded values
    texts = {t: read_text(src / r) for t, (r, _) in lua.items()}
    hard = plan_hardcodes(texts, mode, sidecar)
    res.hard = hard
    res.alerts.extend(hard.alerts)
    accepted = []
    if mode == "hardcode":
        if hard.conversions:
            if confirm is None:
                raise BuildError("hardcode mode needs a confirmation callback")
            accepted = confirm(hard)
        else:
            res.alerts.append({"level": "info", "code": "hardcode-none", "message": "no hard-coded values selected for conversion"})
    res.accepted = accepted
    by_file: dict[str, list] = {}
    for c in accepted:
        by_file.setdefault(c.file, []).append(c)
    for target_rel, (rel, data) in sorted(lua.items()):
        if target_rel in by_file:
            new = K.rewrite(texts[target_rel], by_file[target_rel])
            writer.put(omw + target_rel, text_bytes(new))
            writer.put(omw + "_original/" + target_rel, data)
            res.copied.append((rel, target_rel, True))
        else:
            writer.put(omw + target_rel, data)
            res.copied.append((rel, target_rel, False))
    for om in find_omwscripts(src):
        r = om.relative_to(src).as_posix()
        writer.put(omw + r, om.read_bytes())
        res.copied.append((r, r, False))
    for p in sorted(src.rglob("*")):
        if p.is_file() and "l10n" in [x.lower() for x in p.relative_to(src).parts]:
            r = p.relative_to(src).as_posix()
            writer.put(omw + r, p.read_bytes())
            res.copied.append((r, r, False))

    # 3. mesh aliases (R4)
    meshmap: dict[str, str] = {}
    for m in scan.meshes:
        n = normalize_mesh(m)
        if len(n) > MAX_MESH and n not in meshmap:
            meshmap[n] = mesh_alias(slug, n)
    for n, a in sorted(meshmap.items()):
        status = "not copied (copy on install)"
        for mf in meshes_from or []:
            srcmesh = Path(mf) / n
            if srcmesh.is_file():
                writer.put(f"{D}meshes/{a}", srcmesh.read_bytes())
                status = "copied"
                break
        else:
            if meshes_from:
                status = "source mesh missing"
                res.alerts.append({"level": "warning", "code": "mesh-missing", "message": f"meshes/{n} not found; alias {a} not written"})
        res.aliases.append((n, a, status))

    # 4. loader, metadata, runtime
    probe = bool(scan.settings.get("groups"))
    cfg = None
    if accepted:
        mcm = (sidecar or {}).get("mcm", {})
        cfg = {"group": f"omw2mwse_{name}", "groupName": mcm.get("group", "Tunables"),
               "page": mcm.get("page", title or name),
               "description": mcm.get("description", "Values the mod author hard-coded, exposed by omw2mwse. "
                                      "Defaults are the author's values."),
               "conversions": accepted}
    writer.put(f"{D}MWSE/mods/{name}/main.lua", text_bytes(render_main(name, scan.scripts, meshmap, probe, cfg, title)))
    writer.put(f"{D}{name}-metadata.toml", text_bytes(render_metadata(name, src.name)))
    if with_runtime:
        writer.put(f"{D}MWSE/lib/omwcompat.lua", (RUNTIME_LIB / "omwcompat.lua").read_bytes())
        for f in sorted((RUNTIME_LIB / "omwcompat").iterdir()):
            if f.is_file():
                writer.put(f"{D}MWSE/lib/omwcompat/{f.name}", f.read_bytes())

    # alerts from the scan
    for b in scan.blockers:
        res.alerts.append({"level": "error", "code": "blocker", "message": b})
    for w in scan.warnings:
        res.alerts.append({"level": "warning", "code": "scan-warning", "message": w})
    for r, e in sorted(scan.settings.get("renderers", {}).items()):
        if e["status"] not in ("full", "partial"):
            res.alerts.append({"level": "warning", "code": "settings-renderer-fallback", "renderer": r, "count": e["count"],
                               "message": f"settings renderer {r} ({e['status']}) is shown with a fallback MCM control"})
    res.report_md = render_report(res, mode)
    return res


def render_report(res: BuildResult, mode: str) -> str:
    rep = [f"# omw2mwse report: {res.name}", "",
           f"- Source: `{res.source}` (never modified)",
           f"- omw2mwse {__version__}, mode `{mode}`",
           f"- Scan verdict: **{res.scan.verdict}**",
           f"- Mesh aliases: {len(res.aliases)}", ""]
    so, st = res.scan.settings_coverage()
    if res.scan.settings:
        rep.append(f"- OpenMW settings: {len(res.scan.settings['groups'])} group(s), renderers OK {so}/{st}; "
                   "an MCM is generated from them at runtime")
    if res.accepted:
        rep += ["", "## Hard-coded values converted (developer-approved)", "",
                "| Key | File:line | Type | Default | Applies | Origin |", "|---|---|---|---|---|---|"]
        for c in res.accepted:
            rep.append(f"| `{c.key}` | `{c.file}:{c.line}` | {c.type} | `{c.literal}` | {c.apply_note} | {c.origin} |")
        rep.append("")
        for c in res.accepted:
            rep += [f"- `{c.key}`:", f"  - before: `{c.before}`", f"  - after: `{c.after}`"]
            rep += [f"  - risk: {r}" for r in c.risks]
    if res.hard and res.hard.log:
        rep += ["", "## Hard-code decisions", ""] + [f"- {x}" for x in res.hard.log]
    if res.notes:
        rep += ["", "## Notes", ""] + [f"- {n}" for n in res.notes]
    rep += ["", "## Files", ""]
    for r, t, rewritten in res.copied:
        if rewritten:
            rep.append(f"- `{res.omw_rel}{t}` <- `{r}`: **rewritten** for hard-coded values; verbatim original at "
                       f"`{res.omw_rel}_original/{t}`")
        else:
            rep.append(f"- `{res.omw_rel}{t}` <- `{r}` (byte-identical)")
    rep += ["", "## Mesh aliases", ""] + [f"- `{a}` -> `{b}` ({c})" for a, b, c in res.aliases]
    rep += ["", render_markdown([res.scan], title="Scan").replace("# Scan", "## Scan", 1)]
    return "\n".join(rep)
