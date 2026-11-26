"""Static scan of an OpenMW Lua mod against the omwcompat manifest."""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path

from .luatok import LuaSyntaxError, Token, tokenize

HERE = Path(__file__).resolve().parent
DEFAULT_MANIFEST = HERE.parent.parent / "runtime" / "MWSE" / "lib" / "omwcompat" / "manifest.json"

OK_STATUSES = ("full", "partial", "stub", "interface", "local")
MESH_RE = re.compile(r"^meshes[/\\].+\.nif$", re.IGNORECASE)


def load_manifest(path: Path | None = None) -> dict:
    with open(path or DEFAULT_MANIFEST, encoding="utf-8") as f:
        return json.load(f)


def normalize_mesh(p: str) -> str:
    p = p.replace("\\", "/").lower().lstrip("/")
    if p.startswith("meshes/"):
        p = p[len("meshes/"):]
    return p


# ------------------------------------------------------------------ omwscripts
@dataclass
class ScriptEntry:
    flags: list[str]
    path: str
    source: str  # .omwscripts file that declared it


def parse_omwscripts(text: str, source: str = "") -> list[ScriptEntry]:
    out = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        flags, path = line.split(":", 1)
        out.append(ScriptEntry([f.strip().upper() for f in flags.split(",") if f.strip()], path.strip().replace("\\", "/"), source))
    return out


# ------------------------------------------------------------------ analysis
@dataclass
class FileScan:
    path: str
    requires: dict[str, str] = field(default_factory=dict)       # alias -> module path
    uses: dict[str, int] = field(default_factory=dict)           # full symbol -> count
    methods: dict[str, int] = field(default_factory=dict)        # GameObject method -> count
    engine_handlers: list[str] = field(default_factory=list)
    event_handlers: list[str] = field(default_factory=list)
    meshes: list[str] = field(default_factory=list)
    local_requires: list[str] = field(default_factory=list)
    settings: list[dict] = field(default_factory=list)          # registerGroup declarations
    custom_renderers: list[str] = field(default_factory=list)   # registerRenderer names
    error: str | None = None


def _chain(toks: list[Token], i: int) -> tuple[list[str], int, str | None]:
    """Collect `.a.b:c` after index i (exclusive). Returns (parts, next index, separator of last)."""
    parts, j, last = [], i + 1, None
    while j + 1 < len(toks) and toks[j].kind == "symbol" and toks[j].value in (".", ":") and toks[j + 1].kind == "name":
        parts.append(toks[j + 1].value)
        last = toks[j].value
        j += 2
        if last == ":":
            break
    return parts, j, last


def _require_at(toks: list[Token], i: int) -> tuple[str | None, int]:
    """If toks[i] is `require` with a literal argument return (module, index after call)."""
    if toks[i].kind != "name" or toks[i].value != "require":
        return None, i
    if i + 1 < len(toks) and toks[i + 1].kind == "string":
        return toks[i + 1].value, i + 2
    if i + 3 < len(toks) and toks[i + 1].value == "(" and toks[i + 2].kind == "string" and toks[i + 3].value == ")":
        return toks[i + 2].value, i + 4
    return None, i


def _table_keys(toks: list[Token], start: int) -> list[str]:
    """Keys at depth 1 of a table constructor beginning at toks[start] == '{'.

    Tracks both bracket depth and block depth (function/if/do/repeat ... end/until)
    so assignments inside function bodies are not mistaken for table keys."""
    keys, depth, block, j = [], 0, 0, start
    while j < len(toks):
        t = toks[j]
        if t.kind == "symbol" and t.value in ("{", "(", "["):
            depth += 1
        elif t.kind == "symbol" and t.value in ("}", ")", "]"):
            depth -= 1
            if depth == 0:
                break
        elif t.kind == "keyword" and t.value in ("function", "if", "do", "repeat"):
            block += 1
        elif t.kind == "keyword" and t.value in ("end", "until"):
            block -= 1
        elif depth == 1 and block == 0 and t.kind == "name" and j + 1 < len(toks) and toks[j + 1].value == "=" \
                and toks[j - 1].value in ("{", ",", ";"):
            keys.append(t.value)
        j += 1
    return keys


def _find_table_for_name(toks: list[Token], name: str) -> int | None:
    for j in range(len(toks) - 2):
        if toks[j].kind == "name" and toks[j].value == name and toks[j + 1].value == "=" and toks[j + 2].value == "{":
            return j + 2
    return None


def _settings_list(toks: list[Token], start: int) -> tuple[list[dict], bool]:
    """Entries { key=, renderer= } of a settings list constructor at toks[start] == '{'."""
    out, depth, k, cur, n = [], 0, start, None, len(toks)
    dynamic = False
    while k < n:
        x = toks[k]
        if x.kind == "symbol" and x.value in ("{", "(", "["):
            depth += 1
            if depth == 2 and x.value == "{":
                cur = {"key": None, "renderer": "textLine"}
        elif x.kind == "symbol" and x.value in ("}", ")", "]"):
            if depth == 2 and x.value == "}" and cur is not None:
                out.append(cur)
                cur = None
            depth -= 1
            if depth == 0:
                break
        elif depth == 2 and cur is not None and x.kind == "name" and k + 2 < n and toks[k + 1].value == "=":
            v = toks[k + 2]
            if x.value == "key":
                cur["key"] = v.value if v.kind == "string" else "<dynamic>"
            elif x.value == "renderer":
                cur["renderer"] = v.value if v.kind == "string" and toks[k + 3].value in (",", "}", ";") else "<dynamic>"
        elif depth == 1 and x.kind == "keyword" and x.value in ("for", "function"):
            dynamic = True
        k += 1
    if not out:
        dynamic = True
    return out, dynamic


def _settings_groups(toks: list[Token]) -> tuple[list[dict], list[str]]:
    """registerGroup({ key = ..., settings = { { key, renderer, default }, ... } }) declarations."""
    groups, renderers = [], []
    n = len(toks)
    for i, t in enumerate(toks):
        if t.kind != "name" or i + 1 >= n:
            continue
        if t.value == "registerRenderer":
            j = i + 1
            if toks[j].value == "(":
                j += 1
            if j < n and toks[j].kind == "string":
                renderers.append(toks[j].value)
            continue
        if t.value != "registerGroup":
            continue
        j = i + 1
        if toks[j].value == "(":
            j += 1
        if j >= n or toks[j].value != "{":
            continue
        g = {"key": None, "settings": [], "dynamic": False}
        depth, k = 0, j
        while k < n:
            x = toks[k]
            if x.kind == "symbol" and x.value in ("{", "(", "["):
                depth += 1
            elif x.kind == "symbol" and x.value in ("}", ")", "]"):
                depth -= 1
                if depth == 0:
                    break
            elif depth == 1 and x.kind == "name" and k + 2 < n and toks[k + 1].value == "=":
                v = toks[k + 2]
                if x.value == "key" and v.kind == "string":
                    g["key"] = v.value
                elif x.value == "key":
                    g["key"] = "<dynamic>"
                elif x.value == "settings":
                    start = k + 2 if v.value == "{" else (_find_table_for_name(toks, v.value) if v.kind == "name" else None)
                    if start is None:
                        g["dynamic"] = True
                    else:
                        g["settings"], dyn = _settings_list(toks, start)
                        g["dynamic"] = g["dynamic"] or dyn
            k += 1
        groups.append(g)
    return groups, renderers


def scan_lua(src: str, path: str, method_names: set[str]) -> FileScan:
    fs = FileScan(path)
    try:
        toks = tokenize(src)
    except LuaSyntaxError as e:
        fs.error = str(e)
        return fs
    aliases: dict[str, str] = {}
    n = len(toks)
    # pass 1: aliases from require(...) and `local X = alias.chain`
    for i in range(n):
        mod, after = _require_at(toks, i)
        if mod is None:
            continue
        parts, after2, _ = _chain(toks, after - 1)
        full = ".".join([mod] + parts)
        is_openmw = mod.startswith("openmw.") or mod.startswith("openmw_aux.")
        if not is_openmw:
            fs.local_requires.append(mod)
        # assignment target
        if i >= 2 and toks[i - 1].value == "=" and toks[i - 2].kind == "name":
            aliases[toks[i - 2].value] = full
            fs.requires[toks[i - 2].value] = full
        elif is_openmw:
            fs.requires.setdefault("<inline:" + full + ">", full)
            if parts:
                fs.uses[full] = fs.uses.get(full, 0) + 1
    changed = True
    while changed:
        changed = False
        for i in range(2, n):
            t = toks[i]
            if t.kind == "name" and t.value in aliases and toks[i - 1].value == "=" and toks[i - 2].kind == "name" \
                    and (i < 3 or toks[i - 3].value not in (".", ":")):
                parts, j, last = _chain(toks, i)
                if parts and last == "." and (j >= n or toks[j].value not in ("(", "[", "{")) and toks[i - 2].value not in aliases:
                    aliases[toks[i - 2].value] = aliases[t.value] + "." + ".".join(parts)
                    changed = True
    # pass 2: uses
    for i, t in enumerate(toks):
        if t.kind == "name" and t.value in aliases:
            if i > 0 and toks[i - 1].value in (".", ":"):
                continue
            if i > 0 and toks[i - 1].value == "local":
                continue
            if i + 1 < n and toks[i + 1].value == "=" and (i == 0 or toks[i - 1].value in ("local", ",", ";")):
                continue
            parts, _, _ = _chain(toks, i)
            full = ".".join([aliases[t.value]] + parts)
            if parts or aliases[t.value].count(".") >= 2:
                fs.uses[full] = fs.uses.get(full, 0) + 1
        elif t.kind == "symbol" and t.value == ":" and i + 2 < n and toks[i + 1].kind == "name" \
                and toks[i + 1].value in method_names and toks[i + 2].value in ("(", "{") or (
                t.kind == "symbol" and t.value == ":" and i + 2 < n and toks[i + 1].kind == "name"
                and toks[i + 1].value in method_names and toks[i + 2].kind == "string"):
            recv = toks[i - 1] if i > 0 else None
            if recv is not None and recv.kind == "name" and recv.value in aliases:
                continue
            fs.methods[toks[i + 1].value] = fs.methods.get(toks[i + 1].value, 0) + 1
        elif t.kind == "string" and MESH_RE.match(t.value):
            fs.meshes.append(t.value)
    # handlers
    for i in range(n - 2):
        t = toks[i]
        if t.kind == "name" and t.value in ("engineHandlers", "eventHandlers") and toks[i + 1].value == "=":
            nxt = toks[i + 2]
            start = i + 2 if nxt.value == "{" else (_find_table_for_name(toks, nxt.value) if nxt.kind == "name" else None)
            if start is not None:
                keys = _table_keys(toks, start)
                (fs.engine_handlers if t.value == "engineHandlers" else fs.event_handlers).extend(keys)
    fs.settings, fs.custom_renderers = _settings_groups(toks)
    return fs


def classify(symbol: str, manifest: dict) -> str:
    syms = manifest["symbols"]
    mods = manifest["modules"]
    unsup = set(manifest["unsupportedModules"])
    parts = symbol.split(".")
    # find module (longest prefix that is a known module or unsupported module)
    for k in range(len(parts), 0, -1):
        mod = ".".join(parts[:k])
        if mod in unsup:
            return "unsupported"
        if mod in mods:
            break
    else:
        if parts[0] in ("openmw", "openmw_aux"):
            return "unsupported"
        return "local"
    if symbol.startswith("openmw.interfaces.") and len(parts) >= 3 and parts[2] not in ("Activation", "Settings"):
        return "interface"
    for k in range(len(parts), 1, -1):
        pref = ".".join(parts[:k])
        if pref in syms:
            return syms[pref]
        if any(s.startswith(pref + ".") for s in syms) and k == len(parts):
            return "full"  # namespace value itself (e.g. types.Light passed as an argument)
    return "unsupported"


@dataclass
class ModScan:
    name: str
    root: str
    scripts: list[ScriptEntry]
    files: list[FileScan]
    symbols: dict[str, dict]
    handlers: dict[str, str]
    event_handlers: list[str]
    methods: dict[str, dict]
    flags: dict[str, str]
    unsupported_modules: list[str]
    meshes: list[str]
    blockers: list[str]
    warnings: list[str]
    settings: dict = field(default_factory=dict)
    hardcode: list[dict] = field(default_factory=list)

    def settings_coverage(self) -> tuple[int, int]:
        r = self.settings.get("renderers", {})
        total = sum(e["count"] for e in r.values())
        ok = sum(e["count"] for e in r.values() if e["status"] in ("full", "partial"))
        return ok, total

    @property
    def verdict(self) -> str:
        if not self.files:
            return "no-lua"
        return "ready" if not self.blockers else "blocked"

    def coverage(self) -> tuple[int, int]:
        total = ok = 0
        for s in self.symbols.values():
            total += s["count"]
            if s["status"] in OK_STATUSES:
                ok += s["count"]
        for h, st in self.handlers.items():
            total += 1
            ok += st in OK_STATUSES
        for m in self.methods.values():
            total += m["count"]
            if m["status"] in OK_STATUSES:
                ok += m["count"]
        return ok, total

    def to_dict(self) -> dict:
        ok, total = self.coverage()
        return {
            "name": self.name, "root": self.root, "verdict": self.verdict, "coverage": [ok, total],
            "scripts": [{"flags": s.flags, "path": s.path} for s in self.scripts],
            "flags": self.flags, "symbols": self.symbols, "engineHandlers": self.handlers,
            "eventHandlers": self.event_handlers, "methods": self.methods,
            "unsupportedModules": self.unsupported_modules, "meshes": self.meshes,
            "blockers": self.blockers, "warnings": self.warnings,
            "errors": {f.path: f.error for f in self.files if f.error},
            "settings": dict(self.settings, coverage=list(self.settings_coverage())) if self.settings else {},
            "hardcodeCandidates": self.hardcode,
        }


SKIP_DIRS = {".git", "__pycache__"}


def find_lua_files(root: Path) -> list[Path]:
    out = []
    for dp, dns, fns in os.walk(root):
        dns[:] = sorted(d for d in dns if d not in SKIP_DIRS)
        for fn in sorted(fns):
            if fn.lower().endswith(".lua"):
                out.append(Path(dp) / fn)
    return out


def find_omwscripts(root: Path) -> list[Path]:
    out = []
    for dp, dns, fns in os.walk(root):
        dns[:] = sorted(d for d in dns if d not in SKIP_DIRS)
        for fn in sorted(fns):
            if fn.lower().endswith(".omwscripts"):
                out.append(Path(dp) / fn)
    return out


def read_text(p: Path) -> str:
    data = p.read_bytes()
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    return data.decode("utf-8", errors="replace")


def scan_mod(root: Path, manifest: dict | None = None, name: str | None = None) -> ModScan:
    manifest = manifest or load_manifest()
    root = Path(root)
    method_names = set(manifest["gameObject"]["methods"])
    scripts: list[ScriptEntry] = []
    for om in find_omwscripts(root):
        scripts.extend(parse_omwscripts(read_text(om), str(om.relative_to(root))))
    files = [scan_lua(read_text(p), str(p.relative_to(root)).replace(os.sep, "/"), method_names) for p in find_lua_files(root)]
    symbols: dict[str, dict] = {}
    handlers: dict[str, str] = {}
    events: list[str] = []
    methods: dict[str, dict] = {}
    unsup_mods: list[str] = []
    meshes: list[str] = []
    blockers: list[str] = []
    warnings: list[str] = []
    unsup_set = set(manifest["unsupportedModules"])
    # interfaces provided by the mod itself
    provided = set()
    for p in find_lua_files(root):
        for m in re.finditer(r"interfaceName\s*=\s*['\"]([A-Za-z0-9_]+)['\"]", read_text(p)):
            provided.add(m.group(1))
    for f in files:
        if f.error:
            blockers.append(f"{f.path}: tokenizer error: {f.error}")
        for alias, mod in f.requires.items():
            base = mod
            for um in unsup_set:
                if mod == um or mod.startswith(um + "."):
                    if um not in unsup_mods:
                        unsup_mods.append(um)
        for sym, c in f.uses.items():
            st = classify(sym, manifest)
            if st == "interface":
                iname = sym.split(".")[2]
                st = "interface" if iname in provided else "interface"
            e = symbols.setdefault(sym, {"status": st, "count": 0, "files": []})
            e["count"] += c
            if f.path not in e["files"]:
                e["files"].append(f.path)
        for h in f.engine_handlers:
            handlers[h] = manifest["engineHandlers"].get(h, "unsupported")
        events.extend(e for e in f.event_handlers if e not in events)
        for m, c in f.methods.items():
            e = methods.setdefault(m, {"status": manifest["gameObject"]["methods"][m], "count": 0})
            e["count"] += c
        meshes.extend(x for x in f.meshes if x not in meshes)
    flags: dict[str, str] = {}
    for s in scripts:
        for fl in s.flags:
            flags[fl] = manifest["scriptFlags"].get(fl, "unsupported")
    for um in unsup_mods:
        blockers.append(f"requires unsupported module {um}")
    for sym, e in sorted(symbols.items()):
        if e["status"] == "unsupported":
            blockers.append(f"unsupported API {sym} ({e['count']}x)")
    for h, st in sorted(handlers.items()):
        if st == "unsupported":
            blockers.append(f"unsupported engine handler {h}")
    for m, e in sorted(methods.items()):
        if e["status"] == "unsupported":
            blockers.append(f"unsupported GameObject:{m} ({e['count']}x)")
    for fl, st in sorted(flags.items()):
        if st == "unsupported":
            blockers.append(f"script flag {fl} not hosted (only GLOBAL scripts run)")
    if files and not scripts:
        warnings.append("no .omwscripts file found (script declarations unknown)")
    for s in scripts:
        if not (root / s.path).exists() and not any(p.name == Path(s.path).name for p in find_lua_files(root)):
            warnings.append(f"declared script {s.path} not found")
    long_meshes = [m for m in meshes if len(normalize_mesh(m)) > 31]
    if long_meshes:
        warnings.append(f"{len(long_meshes)} mesh path(s) longer than 31 chars need aliases (R4)")
    for sym, e in symbols.items():
        if e["status"] == "interface":
            iname = sym.split(".")[2]
            if iname not in provided:
                w = f"optional interface I.{iname} (nil unless another hosted mod provides it)"
                if w not in warnings:
                    warnings.append(w)
    # settings (I.Settings) coverage
    known = manifest.get("settingsRenderers", {})
    renderers: dict[str, dict] = {}
    groups = []
    custom = sorted({r for f in files for r in f.custom_renderers})
    for f in files:
        for g in f.settings:
            groups.append({"key": g["key"], "file": f.path, "settings": len(g["settings"]), "dynamic": g["dynamic"]})
            for st in g["settings"]:
                r = st["renderer"]
                status = known.get(r, "dynamic" if r == "<dynamic>" else "custom")
                e = renderers.setdefault(r, {"status": status, "count": 0})
                e["count"] += 1
    for r, e in sorted(renderers.items()):
        if e["status"] not in ("full", "partial"):
            warnings.append(f"settings renderer {r} x{e['count']} ({e['status']}: MCM shows a fallback control)")
    settings_info = {"groups": groups, "renderers": renderers, "customRenderers": custom} if groups or custom else {}
    # hard-coded constant candidates (reported; converted only by `convert --mode hardcode` / sidecar)
    from .constants import detect  # local import: constants imports luatok only
    hard = []
    for p in find_lua_files(root):
        rel = str(p.relative_to(root)).replace(os.sep, "/")
        try:
            consts, inline = detect(read_text(p))
        except LuaSyntaxError:
            continue
        for c in consts:
            if c.eligible:
                hard.append(dict(c.to_json(), file=rel, kind="constant"))
        for x in inline:
            hard.append(dict(x.to_json(), file=rel, kind="literal"))
    return ModScan(name or root.name, str(root), scripts, files, symbols, handlers, events, methods, flags,
                   unsup_mods, meshes, blockers, warnings, settings_info, hard)


def render_markdown(scans: list[ModScan], title: str = "omw2mwse scan") -> str:
    out = [f"# {title}", ""]
    out.append("| Mod | Lua files | Script flags | API uses OK/total | Settings OK/total | Verdict | Blockers |")
    out.append("|---|---:|---|---:|---:|---|---|")
    for s in scans:
        ok, total = s.coverage()
        pct = f"{ok}/{total} ({(100 * ok // total) if total else 100}%)"
        fl = ", ".join(sorted(s.flags)) or "-"
        so, st = s.settings_coverage()
        spct = f"{so}/{st}" if st else "-"
        out.append(f"| {s.name} | {len(s.files)} | {fl} | {pct} | {spct} | {s.verdict} | {len(s.blockers)} |")
    out.append("")
    for s in scans:
        out.append(f"## {s.name}")
        out.append("")
        out.append(f"- Verdict: **{s.verdict}**")
        ok, total = s.coverage()
        out.append(f"- API uses supported: {ok}/{total}")
        if s.scripts:
            out.append("- Scripts: " + "; ".join(f"{','.join(x.flags)}: {x.path}" for x in s.scripts))
        if s.handlers:
            out.append("- Engine handlers: " + ", ".join(f"{h} ({st})" for h, st in sorted(s.handlers.items())))
        if s.event_handlers:
            out.append("- Event handlers: " + ", ".join(s.event_handlers))
        if s.settings:
            so, st = s.settings_coverage()
            out.append(f"- Settings: {len(s.settings['groups'])} group(s), renderers OK {so}/{st}: " + ", ".join(
                f"{r} x{e['count']} ({e['status']})" for r, e in sorted(s.settings["renderers"].items())))
        if s.hardcode:
            out.append(f"- Hard-coded candidates: {len(s.hardcode)} (" + ", ".join(
                (h["name"] if h["kind"] == "constant" else h["context"]) for h in s.hardcode[:8])
                + (", ..." if len(s.hardcode) > 8 else "") + ")")
        if s.methods:
            out.append("- GameObject methods: " + ", ".join(f"{m} x{e['count']} ({e['status']})" for m, e in sorted(s.methods.items())))
        if s.blockers:
            out.append("- Blockers:")
            out.extend(f"  - {b}" for b in s.blockers[:40])
            if len(s.blockers) > 40:
                out.append(f"  - ... and {len(s.blockers) - 40} more")
        if s.warnings:
            out.append("- Warnings:")
            out.extend(f"  - {w}" for w in s.warnings)
        if s.symbols:
            out.append("")
            out.append("| Symbol | Status | Uses |")
            out.append("|---|---|---:|")
            for sym, e in sorted(s.symbols.items()):
                out.append(f"| `{sym}` | {e['status']} | {e['count']} |")
        out.append("")
    return "\n".join(out) + "\n"
