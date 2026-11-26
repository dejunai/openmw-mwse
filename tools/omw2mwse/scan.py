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
    use_lines: dict[str, list] = field(default_factory=dict)     # full symbol -> source lines (in order)
    method_lines: dict[str, list] = field(default_factory=dict)  # GameObject method -> source lines
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
                fs.use_lines.setdefault(full, []).append(toks[i].line)
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
                fs.use_lines.setdefault(full, []).append(t.line)
        elif t.kind == "symbol" and t.value == ":" and i + 2 < n and toks[i + 1].kind == "name" \
                and toks[i + 1].value in method_names and toks[i + 2].value in ("(", "{") or (
                t.kind == "symbol" and t.value == ":" and i + 2 < n and toks[i + 1].kind == "name"
                and toks[i + 1].value in method_names and toks[i + 2].kind == "string"):
            recv = toks[i - 1] if i > 0 else None
            if recv is not None and recv.kind == "name" and recv.value in aliases:
                continue
            fs.methods[toks[i + 1].value] = fs.methods.get(toks[i + 1].value, 0) + 1
            fs.method_lines.setdefault(toks[i + 1].value, []).append(toks[i + 1].line)
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
    builtin = manifest.get("builtinInterfaces", {"Activation": "global", "Settings": "any"})
    if symbol.startswith("openmw.interfaces.") and len(parts) >= 3 and parts[2] not in builtin:
        return "interface"  # provided by a mod (optional unless a hosted script provides it)
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
    opt_out: dict | None = None
    partial_apis: list[dict] = field(default_factory=list)
    patterns: list[dict] = field(default_factory=list)      # patterns.Finding.to_json(), file order
    guards: dict[str, list[str]] = field(default_factory=dict)  # declared script path -> runtime guards

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
            "optOut": self.opt_out,
            "partialApis": self.partial_apis,
            "guards": self.guards,
        }


SKIP_DIRS = {".git", "__pycache__"}
# Top-level folders of a package that hold converter/tidy output, never package content:
# MWSE/ (generated build), Off/ (set-aside originals of this or other packages), Extras/.
OUTPUT_TOP_DIRS = frozenset({"mwse", "off", "extras"})


def is_package_dir(d) -> bool:
    """True if folder d directly holds a *.omwscripts file (an OpenMW package root)."""
    try:
        return any(e.lower().endswith(".omwscripts") and os.path.isfile(os.path.join(d, e)) for e in os.listdir(d))
    except OSError:
        return False


def walk_package(root):
    """os.walk over one package: sorted, without SKIP_DIRS, without the package's top-level
    output folders (OUTPUT_TOP_DIRS, when root is itself a package), and without nested packages. Inside a package (a folder holding a
    .omwscripts, or below one), a subfolder that holds its own .omwscripts is a package
    boundary: it is converted on its own (convert.find_sources lists it), so neither its files
    nor anything below it belong to the parent. Above the first package (an archive's wrapper
    folder) nothing is pruned, so `scan mod-archive/` still finds the package inside."""
    root = os.fspath(root)
    inside: set = set()
    for dp, dns, fns in os.walk(root):
        top = os.path.normpath(dp) == os.path.normpath(root)
        in_pkg = dp in inside or is_package_dir(dp)
        keep = []
        for d in sorted(dns):
            if d in SKIP_DIRS or d.lower() == "__pycache__" or (top and in_pkg and d.lower() in OUTPUT_TOP_DIRS):
                continue
            sub = os.path.join(dp, d)
            if in_pkg:
                if is_package_dir(sub):
                    continue
                inside.add(sub)
            keep.append(d)
        dns[:] = keep
        yield dp, dns, sorted(fns)


def package_files(root) -> list[Path]:
    """Every file of the package rooted at root (see walk_package), sorted walk order."""
    return [Path(dp) / fn for dp, _dns, fns in walk_package(root) for fn in fns]


def find_lua_files(root: Path) -> list[Path]:
    return [p for p in package_files(root) if p.name.lower().endswith(".lua")]


def find_omwscripts(root: Path) -> list[Path]:
    return [p for p in package_files(root) if p.name.lower().endswith(".omwscripts")]


def read_text(p: Path) -> str:
    data = p.read_bytes()
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    return data.decode("utf-8", errors="replace")


def _norm_rel(rel: str) -> str:
    return rel.replace("\\", "/").lower()


def resolve_local_module(mod: str, by_rel: dict[str, str], from_rel: str | None = None) -> str | None:
    """Map a require() module name to a Lua path in this package, if one exists."""
    cand = mod.replace("\\", "/").replace(".", "/")
    cand = cand.lstrip("/")
    options = [cand + ".lua", cand + "/init.lua"]
    if from_rel:
        parts = Path(from_rel).as_posix().split("/")
        # require() is VFS-style from a data root; try every ancestor as that root
        # so mod/scripts/X/a.lua requiring scripts.X.b finds mod/scripts/X/b.lua.
        for i in range(len(parts)):
            prefix = "/".join(parts[:i])
            if prefix:
                options.extend((prefix + "/" + cand + ".lua", prefix + "/" + cand + "/init.lua"))
        parent = "/".join(parts[:-1])
        if parent:
            options.extend((parent + "/" + cand + ".lua", parent + "/" + cand + "/init.lua"))
    for suffix in options:
        hit = by_rel.get(_norm_rel(suffix))
        if hit:
            return hit
    return None


def _script_file(s: ScriptEntry, by_rel: dict, by_name: dict) -> str | None:
    """The Lua file a declared script entry loads (package-relative path), or None."""
    candidates = []
    if s.source:
        parent = str(Path(s.source).parent).replace("\\", "/")
        if parent not in (".", ""):
            candidates.append(parent + "/" + s.path)
    candidates.append(s.path)
    for c in candidates:
        hit = by_rel.get(_norm_rel(c))
        if hit:
            return hit
    cands = by_name.get(Path(s.path).name.lower(), [])
    return cands[0] if len(cands) == 1 else None


def _file_indexes(files: list[FileScan]):
    by_rel = {_norm_rel(f.path): f.path for f in files}
    by_name: dict[str, list[str]] = {}
    for f in files:
        by_name.setdefault(Path(f.path).name.lower(), []).append(f.path)
    return by_rel, by_name


def script_closures(scripts: list[ScriptEntry], files: list[FileScan]) -> dict[str, set[str]]:
    """Declared script path -> the Lua files it loads (itself plus local require()s, transitively)."""
    by_rel, by_name = _file_indexes(files)
    file_by = {f.path: f for f in files}
    out: dict[str, set[str]] = {}
    for s in scripts:
        hit = _script_file(s, by_rel, by_name)
        out[s.path] = _closure([hit] if hit else [], file_by, by_rel)
    return out


def _closure(queue: list[str], file_by: dict, by_rel: dict) -> set[str]:
    loaded: set[str] = set()
    while queue:
        rel = queue.pop()
        if rel in loaded:
            continue
        loaded.add(rel)
        fs = file_by.get(rel)
        if fs is None:
            continue
        mods: list[str] = []
        for mod in list(fs.local_requires) + list(fs.requires.values()):
            if mod.startswith("openmw.") or mod.startswith("openmw_aux."):
                continue
            if mod not in mods:
                mods.append(mod)
        for mod in mods:
            hit = resolve_local_module(mod, by_rel, rel)
            if hit is not None and hit not in loaded:
                queue.append(hit)
    return loaded


def loaded_lua_paths(scripts: list[ScriptEntry], files: list[FileScan]) -> set[str] | None:
    """Lua files .omwscripts will load: declared scripts plus local require()s.

    Returns None when there is no .omwscripts, so every Lua file is counted.
    """
    if not scripts:
        return None
    by_rel, by_name = _file_indexes(files)
    file_by = {f.path: f for f in files}
    queue: list[str] = []
    for s in scripts:
        hit = _script_file(s, by_rel, by_name)
        if hit is not None:
            queue.append(hit)
    return _closure(queue, file_by, by_rel)


# Which scripts a file runs in. OpenMW gives GLOBAL scripts openmw.world and local
# (object-attached) scripts openmw.self / openmw.nearby; built-in interfaces exist
# only in some script kinds (I.AI in actor scripts, I.Activation in global ones).
FLAG_SCOPE = {"GLOBAL": "global", "NPC": "actor", "CREATURE": "actor", "ACTOR": "actor", "PLAYER": "player",
              "CONTAINER": "object", "DOOR": "object", "LIGHT": "object", "ACTIVATOR": "object", "ITEM": "object",
              "MENU": "menu", "CUSTOM": "custom", "LOAD": "load"}
SCOPE_ALLOWS = {
    "any": {"global", "actor", "player", "object", "menu", "custom", "load"},
    "global": {"global"},
    "local": {"actor", "player", "object", "custom"},
    "actor": {"actor", "player"},
    "player": {"player"},
}


def file_scopes(scripts: list[ScriptEntry], files: list[FileScan]) -> dict[str, set[str]]:
    """file path -> script kinds (FLAG_SCOPE values) that load it."""
    out: dict[str, set[str]] = {}
    for s in scripts:
        kinds = {FLAG_SCOPE.get(f, "custom") for f in s.flags}
        loaded = loaded_lua_paths([s], files) or set()
        for p in loaded:
            out.setdefault(p, set()).update(kinds)
    return out


def scope_blockers(counted: list[FileScan], scopes: dict[str, set[str]], manifest: dict) -> list[str]:
    mod_scopes = manifest.get("moduleScopes", {})
    iface_scopes = manifest.get("builtinInterfaces", {})
    out: list[str] = []
    for f in counted:
        kinds = scopes.get(f.path)
        if not kinds:
            continue
        need: dict[str, str] = {}
        for mod in f.requires.values():
            for mname, sc in mod_scopes.items():
                if mod == mname or mod.startswith(mname + "."):
                    need[mname] = sc
        for sym in f.uses:
            parts = sym.split(".")
            if sym.startswith("openmw.interfaces.") and len(parts) >= 3 and parts[2] in iface_scopes:
                need["I." + parts[2]] = iface_scopes[parts[2]]
        for what, sc in sorted(need.items()):
            bad = sorted(k for k in kinds if k not in SCOPE_ALLOWS.get(sc, set()))
            if bad:
                out.append(f"{f.path}: {what} is only available to {sc} scripts, but this file runs as {', '.join(bad)}")
    return out


def scan_mod(root: Path, manifest: dict | None = None, name: str | None = None) -> ModScan:
    manifest = manifest or load_manifest()
    root = Path(root)
    method_names = set(manifest["gameObject"]["methods"])
    scripts: list[ScriptEntry] = []
    for om in find_omwscripts(root):
        scripts.extend(parse_omwscripts(read_text(om), om.relative_to(root).as_posix()))
    files = [scan_lua(read_text(p), str(p.relative_to(root)).replace(os.sep, "/"), method_names) for p in find_lua_files(root)]
    loaded = loaded_lua_paths(scripts, files)
    counted = files if loaded is None else [f for f in files if f.path in loaded]
    symbols: dict[str, dict] = {}
    handlers: dict[str, str] = {}
    events: list[str] = []
    methods: dict[str, dict] = {}
    unsup_mods: list[str] = []
    meshes: list[str] = []
    blockers: list[str] = []
    warnings: list[str] = []
    unsup_set = set(manifest["unsupportedModules"])
    # interfaces provided by the mod itself (only from scripts that will actually load)
    provided = set()
    for f in counted:
        srcp = root / f.path
        if srcp.is_file():
            for m in re.finditer(r"interfaceName\s*=\s*['\"]([A-Za-z0-9_]+)['\"]", read_text(srcp)):
                provided.add(m.group(1))
    if loaded is not None:
        for f in files:
            if f.path not in loaded:
                warnings.append(
                    f"{f.path} is not declared in .omwscripts and is not required "
                    "by a declared script; ignored for the verdict"
                )
    for f in counted:
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
            hosted = ", ".join(sorted(k for k, v in manifest["scriptFlags"].items() if v != "unsupported"))
            blockers.append(f"script flag {fl} not hosted (hosted: {hosted})")
    if scripts:
        blockers.extend(scope_blockers(counted, file_scopes(scripts, files), manifest))
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
    custom = sorted({r for f in counted for r in f.custom_renderers})
    for f in counted:
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
    hard_files = counted if loaded is not None else files
    for f in hard_files:
        try:
            consts, inline = detect(read_text(root / f.path))
        except LuaSyntaxError:
            continue
        for c in consts:
            if c.eligible:
                hard.append(dict(c.to_json(), file=f.path, kind="constant"))
        for x in inline:
            hard.append(dict(x.to_json(), file=f.path, kind="literal"))
    from .optout import find_opt_out  # local import: optout is standalone
    opt = find_opt_out(root)
    if opt:
        blockers.insert(0, f"{opt['code']}: {opt['message']}")
    # An author opt-out never reports where anything is in the mod's files (no file/line).
    partial = [] if opt else partial_api_uses(counted, symbols, handlers, methods, flags, renderers, manifest)
    found, guards = ([], {}) if opt else pattern_findings(root, scripts, files, counted)
    partial.extend(pattern_partials(found))
    return ModScan(name or root.name, str(root), scripts, files, symbols, handlers, events, methods, flags,
                   unsup_mods, meshes, blockers, warnings, settings_info, hard, opt, partial, found, guards)


def pattern_findings(root: Path, scripts: list, files: list, counted: list) -> tuple[list[dict], dict[str, list[str]]]:
    """Rule-based pattern findings (see patterns.py) in the Lua files the mod loads, and the
    runtime guards each declared script gets: every rule found in a file the script loads
    (itself or a module it requires). Guards are emitted into the generated main.lua."""
    from .patterns import GUARD_FOR_RULE, detect  # local import: patterns imports luatok only
    found: list[dict] = []
    by_file: dict[str, set[str]] = {}
    for f in counted:
        if f.error:
            continue
        for x in detect(read_text(root / f.path)):
            x.file = f.path
            found.append(x.to_json())
            by_file.setdefault(f.path, set()).add(GUARD_FOR_RULE[x.rule])
    guards: dict[str, list[str]] = {}
    if by_file:
        for path, loaded in script_closures(scripts, files).items():
            g = set()
            for rel in loaded:
                g |= by_file.get(rel, set())
            if g:
                guards[path] = sorted(g)
    return found, guards


# What each rule's runtime guard does and does not cover (partialApis `missing` for kind "pattern").
PATTERN_NOTES = {
    "active-collect-dedupe": "an object from onObjectActive/onActorActive/onItemActive is added to a list with no "
                             "duplicate check, so the list grows each time the cell is loaded again; omwcompat "
                             "(guard activeDedupe) skips a table.insert of an object already in the list while the "
                             "handler runs; list[#list + 1] = obj is not intercepted",
    "mutate-during-iteration": "a table is changed while it is traversed with next/pairs/ipairs; omwcompat (guard "
                               "safeIteration) visits the element that table.remove shifts into the freed slot and "
                               "restarts next() instead of raising 'invalid key to next'; t[k] = nil inside ipairs "
                               "and inserts inside a pairs loop are reported only",
}


def pattern_partials(found: list[dict]) -> list[dict]:
    """partialApis entries (kind "pattern") for rules that fired, one per rule."""
    out = []
    for rule in ("active-collect-dedupe", "mutate-during-iteration"):
        hits = [x for x in found if x["rule"] == rule]
        if not hits:
            continue
        uses, seen = [], set()
        for x in hits:
            if (x["file"], x["line"]) not in seen:
                seen.add((x["file"], x["line"]))
                uses.append({"file": x["file"], "line": x["line"]})
        out.append({"api": "pattern:" + rule, "kind": "pattern", "count": len(hits),
                    "uses": uses[:MAX_PARTIAL_USES], "missing": PATTERN_NOTES[rule]})
    return out


MAX_PARTIAL_USES = 20   # per API: the first uses (file order, then line order); `count` has the total
GENERIC_PARTIAL = "emulated with documented differences (see docs/GAPS.md)"


# What a `partial` API does differently in omwcompat (keys: dotted prefixes, `*` matches one
# segment; longest match wins). Kept next to the scanner, not in the runtime manifest, so the
# shipped runtime files do not change when a note is reworded. Source: the runtime code.
PARTIAL_NOTES = {
    "openmw.async.newRealTimer": "real-time timers are not saved with the game (dropped on save/load)",
    "openmw.async.newUnsavableRealTimer": "real time is measured with os.clock (process time), not wall-clock time",
    "openmw.core.getRealTime": "returns os.clock() (process time), not seconds since the epoch",
    "openmw.core.getGameTimeScale": "reads the vanilla timescale global (30 if it cannot be read)",
    "openmw.core.l10n": "only l10n/<context>/en.yaml is read; {name} substitution only, no ICU plural/select formats",
    "openmw.core.weather": "read from MWSE's weather controller; getTransition is 1 - transitionScalar "
                           "(direction not yet confirmed in game); nil in cells without sky",
    "openmw.interfaces.AI": "Combat via mobile:startCombat; Wander/Travel/Follow/Escort via tes3.setAI*; other "
                            "package types raise; removePackages only removes Combat; getActivePackage reads "
                            "inCombat, then the AI planner",
    "openmw.interfaces.Settings.registerRenderer": "custom renderers are accepted; the MCM shows a fallback control",
    "openmw.interfaces.Settings": "groups and pages registered by hosted scripts only",
    "openmw.nearby": "lists references in tes3.getActiveCells() (cached per frame); castRay and other queries "
                     "are not supported",
    "openmw.self.enableAI": "sets the mobile's activeAI flag; no effect when the actor is not loaded",
    "openmw.self.startingPosition": "the reference's starting position (falls back to the current position)",
    "openmw.self.startingRotation": "the reference's starting orientation (falls back to the current one)",
    "openmw.self.contentFile": "lower-case name of the plugin the reference comes from; nil for created refs",
    "openmw.self.ownerRecordId": "item owner from the reference's itemData only",
    "openmw.self.parentContainer": "always nil",
    "openmw.self.remove": "R1: content refs are disabled and tombstoned, created refs deleted",
    "openmw.self.teleport": "R2: a limbo object placed on a tombstone of the same record is resurrected; "
                            "otherwise tes3.createReference",
    "openmw.self.moveInto": "R3: during activation, redirected to a vanilla pickup of the tombstoned original",
    "openmw.storage.allPlayerSections": "returns this mod's own storage only",
    "openmw.types.*.record": "built from the MWSE object; only commonly used record fields are mapped",
    "openmw.types.*.records": "list built on demand from MWSE objects; only commonly used record fields are mapped",
    "openmw.types.*.isExpelled": "the player's faction.playerExpelled flag; other NPCs are never expelled (false)",
    "openmw.types.*.inventory": "wraps the reference's MWSE inventory; a subset of the OpenMW Inventory API",
    "openmw.types.Container.content": "wraps the reference's MWSE inventory; a subset of the OpenMW Inventory API",
    "openmw.types.*.stats.dynamic": "maps to the MWSE mobile's health/magicka/fatigue statistic; "
                                    "the actor must be loaded (in an active cell)",
    "openmw.types.*.stats.attributes": "maps to the MWSE mobile's attribute statistic; the actor must be loaded",
    "openmw.types.*.stats.ai": "fight/flee/alarm/hello from the MWSE mobile, base values from aiConfig; "
                               "the actor must be loaded",
    "openmw.types.Light.createRecordDraft": "Light (or any type) with a template only; models longer than 31 "
                                            "characters need a packager mesh alias (R4)",
    "openmw.world.createRecord": "drafts need a template; models longer than 31 characters need a packager mesh alias (R4)",
    "openmw.util.loadCode": "loadstring + setfenv (LuaJIT) with the given environment; no OpenMW sandbox",
    "openmw.vfs": "loose files only (BSA contents cannot be read); pathsWithPrefix lists one folder level (lfs)",
    "openmw.world.activeActors": "rebuilt from tes3.getActiveCells() on each access, player first",
    "openmw.world.cells": "only the active cells (tes3.getActiveCells())",
    "openmw.world.mwscript.getGlobalScript": "variables via the vanilla script context (unknown names read nil, "
                                             "writing one raises); isRunning starts/stops it; player argument ignored",
    "openmw_aux.calendar.formatGameTime": "os.date on game seconds (UTC); no in-game month names",
    "openmw_aux.time.runRepeatedly": "simulation or game time only; not saved (restarts with the script)",
    "openmw_aux.util.deepToString": "uses omwcompat's serializer; formatting differs from OpenMW",
    "settingsRenderer:color": "edited as hex text (RRGGBB), no colour picker",
}


def partial_note(api: str, manifest: dict) -> str:
    """What omwcompat does differently for a partial API: the PARTIAL_NOTES (or the manifest's
    partialNotes) entry for the longest matching prefix (`*` matches one segment), then the
    runtime manifest's `notes` for the exact name or its last segment (remove, teleport, ...),
    else the generic text. Rule-based; the verdict does not depend on it."""
    notes = dict(PARTIAL_NOTES, **manifest.get("partialNotes", {}))
    parts = api.split(".")
    best, best_len = None, -1
    for key, text in notes.items():
        kp = key.split(".")
        if len(kp) > len(parts) or len(kp) <= best_len:
            continue
        if all(k == "*" or k == p for k, p in zip(kp, parts)):
            best, best_len = text, len(kp)
    if best:
        return best
    rt_notes = manifest.get("notes", {})
    return rt_notes.get(api) or rt_notes.get(parts[-1]) or GENERIC_PARTIAL


def _uses(counted: list, attr: str, key: str) -> list[dict]:
    out, seen = [], set()
    for f in counted:
        for ln in getattr(f, attr).get(key, []):
            if (f.path, ln) not in seen:
                seen.add((f.path, ln))
                out.append({"file": f.path, "line": ln})
    return out


def partial_api_uses(counted: list, symbols: dict, handlers: dict, methods: dict, flags: dict,
                     renderers: dict, manifest: dict) -> list[dict]:
    """Every API the mod uses whose omwcompat status is `partial`, for `partialApis` in the JSON.

    Each entry: {"api", "kind" (symbol|method|engineHandler|scriptFlag|settingsRenderer; pattern
    entries are added by pattern_partials),
    "count", "uses": [{"file", "line"}], "missing"}. `uses` lists at most MAX_PARTIAL_USES
    distinct (file, line) pairs; `file` is a package-relative path with forward slashes. Kinds whose
    position the scanner does not track (handlers, flags, renderers) have `uses: []`.
    Purely informational: a `partial` API never changes the verdict."""
    out = []
    for sym, e in sorted(symbols.items()):
        if e["status"] != "partial":
            continue
        uses = _uses(counted, "use_lines", sym)
        out.append({"api": sym, "kind": "symbol", "count": e["count"], "uses": uses[:MAX_PARTIAL_USES],
                    "missing": partial_note(sym, manifest)})
    for m, e in sorted(methods.items()):
        if e["status"] != "partial":
            continue
        uses = _uses(counted, "method_lines", m)
        out.append({"api": "GameObject:" + m, "kind": "method", "count": e["count"], "uses": uses[:MAX_PARTIAL_USES],
                    "missing": partial_note(m, manifest)})
    for h, st in sorted(handlers.items()):
        if st == "partial":
            out.append({"api": "engineHandler:" + h, "kind": "engineHandler", "count": 1, "uses": [], "missing": partial_note(h, manifest)})
    for fl, st in sorted(flags.items()):
        if st == "partial":
            note = manifest.get("notes", {}).get("local scripts") if fl not in ("GLOBAL", "PLAYER", "MENU") else None
            out.append({"api": "scriptFlag:" + fl, "kind": "scriptFlag", "count": 1, "uses": [],
                        "missing": note or partial_note("scriptFlag:" + fl, manifest)})
    for r, e in sorted(renderers.items()):
        if e["status"] == "partial":
            out.append({"api": "settingsRenderer:" + r, "kind": "settingsRenderer", "count": e["count"], "uses": [],
                        "missing": partial_note("settingsRenderer:" + r, manifest)})
    return out


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
        if s.partial_apis:
            out.append(f"- Partially supported APIs ({len(s.partial_apis)}; the verdict does not change, test these first):")
            for pa in s.partial_apis[:40]:
                at = ", ".join(f"{u['file']}:{u['line']}" for u in pa["uses"][:3])
                out.append(f"  - `{pa['api']}` x{pa['count']}" + (f" ({at})" if at else "") + f": {pa['missing']}")
            if len(s.partial_apis) > 40:
                out.append(f"  - ... and {len(s.partial_apis) - 40} more")
        if s.patterns:
            out.append(f"- Rule-based workarounds ({len(s.patterns)} finding(s); the mod's Lua is not edited):")
            for x in s.patterns[:40]:
                how = "worked around by omwcompat" if x["guarded"] else "reported only, not worked around"
                out.append(f"  - `{x['rule']}` at {x['file']}:{x['line']} (`{x['table']}`): {x['detail']}; {how}")
            for path, g in sorted(s.guards.items()):
                out.append(f"  - guards for `{path}`: " + ", ".join(g))
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
