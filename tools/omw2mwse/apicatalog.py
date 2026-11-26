"""OpenMW's own Lua API list, read at run time from OpenMW's API files (`api-audit`, `scan`).

OpenMW documents its Lua API in LDT-style stub files: `files/lua_api/openmw/*.lua` in the source
tree, `resources/lua_api/openmw/*.lua` in an install. Those files are OpenMW's (GPLv3): omw2mwse
never ships, vendors or commits them. It reads a copy the user already has (an install or a source
checkout), or one `fetch` downloads for a pinned release tag into a cache folder outside the
repository. Without a copy everything here is a no-op.

  load(root)       -> Catalog | None   one install / source tree / cache folder
  locate(...)      -> (Catalog | None, searched)   flag, env, cache, then common install paths
  fetch(tag, ...)  -> Path             download the stub files of one release tag (and nothing else)
  audit(cat, man)  -> dict             manifest.json vs OpenMW's list (unclassified, stale, scopes)

The parser is ours; it reads the documented tags (@module, @context, @type, @extends, @field,
@function, @param, @return) and the "only from a global script"-style notes.
MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

import datetime
import glob
import hashlib
import json
import os
import re
import shutil
import sys
from pathlib import Path

from . import apitypes as AT

ENV_DIR = "OMW2MWSE_OPENMW"         # an install, source tree or cache folder; "none" turns lookups off
ENV_CACHE = "OMW2MWSE_API_CACHE"    # cache root for `api-audit --fetch` (default: user cache folder)
SOURCE_FILE = "SOURCE.json"         # written by fetch next to the downloaded files
REPO = "OpenMW/openmw"
TAG_RE = re.compile(r"^openmw-\d+\.\d+(\.\d+)?(-rc\d+)?$")
LAYOUTS = (("install", ("resources", "lua_api", "openmw")), ("source", ("files", "lua_api", "openmw")),
           ("lua_api", ("lua_api", "openmw")), ("stubs", ()))
PRIMITIVE = {"number", "string", "boolean", "bool", "table", "function", "userdata", "nil", "any", "int",
             "float", "#", ""}
MAX_DEPTH = 6

_GLOBAL_ONLY = re.compile(r"only (?:be )?(?:called |used |available )?(?:from|in) (?:a )?global scripts?|"
                          r"only available (?:from|in) global scripts|must be used in a global script|"
                          r"available only in global scripts", re.I)
_SELF_ONLY = re.compile(r"(?:can be used |can only be used |only )on self", re.I)
_LOCAL_ONLY = re.compile(r"only (?:be )?(?:called )?from a local script", re.I)


# ------------------------------------------------------------------ parsing
def _ref(raw: str | None, here: str):
    """A type as the files write it -> 'file#Type', ('list', ref), or None (a plain value or unknown)."""
    raw = (raw or "").strip().rstrip(".,")
    m = re.match(r"^#?list<\s*(.+?)\s*>$", raw)
    if m:
        inner = _ref(m.group(1), here)
        return ("list", inner) if inner else None
    if "#" not in raw:
        return None
    mod, _, name = raw.partition("#")
    name = re.sub(r"\W.*$", "", name)
    if not name or name in PRIMITIVE:
        return None
    if mod.startswith("openmw."):
        mod = mod[len("openmw."):]
    return f"{mod or here}#{name}"


def _is_type_token(tok: str) -> bool:
    return "#" in tok or tok.startswith("list<")


def parse_file(text: str, here: str, types: dict, modules: dict, contexts: dict) -> None:
    """Add one API file's types and members. types: {'file#Type': {'members', 'extends', 'list'}}."""
    def T(key):
        return types.setdefault(key, {"members": {}, "extends": [], "list": None})

    blocks, cur_block = [], None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("---"):
            cur_block = [s[3:].strip()]
            blocks.append(cur_block)
        elif s.startswith("--") and cur_block is not None:
            cur_block.append(s[2:].strip())
        elif s:
            cur_block = None
    last_type = None
    for block in blocks:
        whole = " ".join(block)
        scope = "global" if _GLOBAL_ONLY.search(whole) else "self" if _SELF_ONLY.search(whole) else \
            "local" if _LOCAL_ONLY.search(whole) else None
        doc = next((x for x in block if x and not x.startswith("@")), "")[:160]
        cur = None
        fn = None
        for ln in block:
            if not ln.startswith("@"):
                continue
            tag, _, rest = ln.partition(" ")
            rest = rest.strip()
            words = rest.split()
            if tag == "@module" and words:
                cur = f"{here}#{words[0]}"
                T(cur)
                modules[here] = cur
                last_type = cur
            elif tag == "@context" and words:
                contexts[here] = [c for c in words[0].split("|") if c]
            elif tag == "@type" and words:
                cur = f"{here}#{words[0]}"
                T(cur)
                last_type = cur
            elif tag == "@extends" and words and (cur or last_type):
                e = _ref(words[0] if "#" in words[0] else "#" + words[0], here)
                if isinstance(e, str):
                    T(cur or last_type)["extends"].append(e)
            elif tag == "@list" and (cur or last_type):
                m = re.match(r"<\s*(\S+?)\s*>", rest)
                if m:
                    T(cur or last_type)["list"] = _ref(m.group(1), here)
            elif tag == "@field":
                parent = cur or last_type
                m = re.match(r"\[parent=#(\w+)\]\s*", rest)
                if m:
                    parent = f"{here}#{m.group(1)}"
                    words = rest[m.end():].split()
                typ = None
                if words and _is_type_token(words[0]):
                    typ, words = words[0], words[1:]
                if not words or not parent or not re.match(r"^[A-Za-z_]\w*$", words[0]):
                    continue
                T(parent)["members"][words[0]] = {"kind": "field", "type": _ref(typ, here), "doc": doc,
                                                  "scope": scope}
            elif tag == "@function":
                m = re.match(r"\[parent=#(\w+)\]\s+(\w+)", rest)
                if m:
                    fn = {"kind": "function", "parent": f"{here}#{m.group(1)}", "name": m.group(2), "params": [],
                          "method": False, "type": None, "doc": doc, "scope": scope}
            elif tag == "@param" and fn is not None and words:
                name = words[1] if len(words) > 1 and _is_type_token(words[0]) else words[0]
                name = name.rstrip(".,")
                if not fn["params"] and not fn["method"] and name.lower() == "self":
                    fn["method"] = True
                else:
                    fn["params"].append(name)
            elif tag == "@return" and fn is not None and words and fn["type"] is None:
                fn["type"] = _ref(words[0], here)
        if fn:
            parent = fn.pop("parent")
            T(parent)["members"][fn.pop("name")] = fn


class Catalog:
    """OpenMW's Lua API from one copy of its API files."""

    def __init__(self, root: Path, layout: str, stub_dir: Path):
        self.root, self.layout, self.stub_dir = Path(root), layout, Path(stub_dir)
        self.types: dict = {}
        self.modules: dict = {}
        self.contexts: dict = {}
        self.files = sorted(p for p in self.stub_dir.glob("*.lua"))
        for p in self.files:
            parse_file(p.read_text(encoding="utf-8", errors="replace"), p.stem, self.types, self.modules, self.contexts)
        self.version, self.api_revision, self.tag = detect_version(self.root, layout)
        self.paths: dict[str, dict] = {}
        # types a module exposes directly (types.NPC, core.magic): a field deeper down that points at
        # one (types.Player.baseType -> NPC) is a reference to that table, not a second copy of it
        self._top = {m["type"] for key in self.modules.values() for m in self.members(key).values()
                     if m["kind"] == "field" and isinstance(m.get("type"), str)}
        for stem, key in sorted(self.modules.items()):
            self._expand("openmw." + stem, key, 0, {key})

    def members(self, key: str, _seen=None) -> dict:
        t = self.types.get(key)
        if not t:
            return {}
        _seen = _seen or set()
        if key in _seen:
            return {}
        _seen.add(key)
        out: dict = {}
        for e in t["extends"]:
            out.update(self.members(e, _seen))
        out.update(t["members"])
        return out

    def _expand(self, prefix: str, key: str, depth: int, stack: set) -> None:
        for name, m in self.members(key).items():
            if name.startswith("__"):
                continue
            p = prefix + "." + name
            typ = m.get("type")
            ref = depth > 0 and isinstance(typ, str) and typ in self._top
            self.paths.setdefault(p, {"kind": m["kind"], "method": m.get("method", False), "scope": m.get("scope"),
                                      "type": typ if isinstance(typ, str) else None,
                                      "opaque": m["kind"] == "field" and (ref or not (isinstance(typ, str) and typ in self.types))})
            if m["kind"] == "field" and isinstance(typ, str) and typ in self.types and depth < MAX_DEPTH \
                    and typ not in stack and not ref:
                self._expand(p, typ, depth + 1, stack | {typ})

    def has(self, symbol: str):
        """True: OpenMW has it; False: it does not; None: cannot tell (not openmw.*, or below a value the
        API files do not describe, such as another script's interface)."""
        parts = symbol.split(".")
        if len(parts) < 2 or parts[0] != "openmw":
            return None
        if parts[1] not in self.modules:
            return False
        if len(parts) == 2 or symbol in self.paths:
            return True
        if parts[1] == "interfaces":
            return None  # open: mods add their own, and the API files list only some built-in ones
        enum = f"{parts[1]}#{parts[2]}"
        if enum in self.types and re.fullmatch(r"[A-Z][A-Z0-9_]*", parts[2]):
            # an enum table the file defines but does not attach to the module (self.ATTACK_TYPE)
            return len(parts) == 3 or parts[3] in self.members(enum)
        for k in range(len(parts) - 1, 1, -1):
            e = self.paths.get(".".join(parts[:k]))
            if e is not None:
                return None if (e["opaque"] or e["kind"] == "function") else False
        return False

    def type_members(self, typ: str) -> dict | None:
        key = AT.OPENMW_TYPE_KEYS.get(typ)
        return None if key is None or key not in self.types else {
            k: v for k, v in self.members(key).items() if not k.startswith("__")}

    def has_method(self, key: str):
        """Typed method keys from scan: `Cell:getAll`, `?:getAll`, `Type.createRecordDraft`."""
        if key.startswith("Type."):
            name = key[5:]
            return any(p.startswith("openmw.types.") and p.endswith("." + name) for p in self.paths)
        typ, _, name = key.partition(":")
        if typ == "?":
            return any(name in self.members(k) for k in self.types)
        ms = self.type_members(typ)
        return None if ms is None else name in ms

    def info(self) -> dict:
        return {"root": str(self.root), "layout": self.layout, "stubDir": str(self.stub_dir),
                "version": self.version, "apiRevision": self.api_revision, "tag": self.tag,
                "files": len(self.files), "symbols": len(self.paths)}


def stub_dir(root) -> tuple[str, Path] | None:
    root = Path(root)
    for layout, sub in LAYOUTS:
        d = root.joinpath(*sub)
        if (d / "core.lua").is_file() and (d / "types.lua").is_file():
            return layout, d
    return None


def detect_version(root: Path, layout: str):
    """(version, apiRevision, tag) from a fetch's SOURCE.json, a source tree's CMakeLists.txt, or an
    install's resources/version (no API revision there)."""
    meta = root / SOURCE_FILE
    if meta.is_file():
        try:
            d = json.loads(meta.read_text(encoding="utf-8"))
            return d.get("version"), d.get("apiRevision"), d.get("tag")
        except (OSError, ValueError):
            pass
    cm = root / "CMakeLists.txt"
    if cm.is_file():
        v = parse_cmake(cm.read_text(encoding="utf-8", errors="replace"))
        if v[0]:
            return v[0], v[1], None
    vf = root / "resources" / "version"
    if vf.is_file():
        first = vf.read_text(encoding="utf-8", errors="replace").splitlines()[:1]
        if first and re.match(r"^\d+\.\d+", first[0].strip()):
            return first[0].strip(), None, None
    return None, None, None


def parse_cmake(text: str):
    def get(name):
        m = re.search(r"set\(\s*%s\s+(\d+)\s*\)" % name, text)
        return int(m.group(1)) if m else None
    major, minor, release = get("OPENMW_VERSION_MAJOR"), get("OPENMW_VERSION_MINOR"), get("OPENMW_VERSION_RELEASE")
    version = f"{major}.{minor}.{release or 0}" if major is not None and minor is not None else None
    return version, get("OPENMW_LUA_API_REVISION")


def load(root) -> Catalog | None:
    if not root:
        return None
    found = stub_dir(root)
    if not found:
        return None
    return Catalog(Path(root), found[0], found[1])


# ------------------------------------------------------------------ finding a copy
def default_cache_root() -> Path:
    if os.environ.get(ENV_CACHE):
        return Path(os.environ[ENV_CACHE])
    if os.name == "nt" and os.environ.get("LOCALAPPDATA"):
        return Path(os.environ["LOCALAPPDATA"]) / "omw2mwse" / "openmw-api"
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return Path(base) / "omw2mwse" / "openmw-api"


def _vkey(name: str):
    return [int(x) if x.isdigit() else -1 for x in re.split(r"[.\-]", name)]


def cached_versions(cache_root: Path) -> list[Path]:
    """Version folders under the cache root, newest first."""
    if not Path(cache_root).is_dir():
        return []
    return sorted((p for p in Path(cache_root).iterdir() if p.is_dir() and stub_dir(p)), key=lambda p: _vkey(p.name),
                  reverse=True)


def install_candidates() -> list[Path]:
    """Common OpenMW install folders (fallback when no flag, env var or cached copy)."""
    pats: list[str] = []
    if os.name == "nt":
        for env in ("ProgramFiles", "ProgramFiles(x86)", "ProgramW6432"):
            if os.environ.get(env):
                pats.append(os.path.join(os.environ[env], "OpenMW*"))
        for drive in "CDEFGH":
            pats += [f"{drive}:\\OpenMW*", f"{drive}:\\Games\\OpenMW*", f"{drive}:\\Program Files\\OpenMW*"]
        docs = os.path.join(os.path.expanduser("~"), "Documents", "My Games", "OpenMW", "openmw.cfg")
        cfgs = [docs]
    else:
        pats += ["/usr/share/games/openmw", "/usr/share/openmw", "/usr/local/share/games/openmw",
                 "/usr/local/share/openmw", "/app/share/games/openmw", "/Applications/OpenMW.app/Contents/Resources",
                 os.path.join(os.path.expanduser("~"), "openmw*"), os.path.join(os.path.expanduser("~"), "OpenMW*")]
        cfgs = [os.path.join(os.path.expanduser("~"), ".config", "openmw", "openmw.cfg")]
    out: list[Path] = []
    for pat in pats:
        out.extend(Path(p) for p in sorted(glob.glob(pat), reverse=True))
    # data=/resources= paths in the user's openmw.cfg: their parent folders may be the install
    for cfg in cfgs:
        try:
            lines = Path(cfg).read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for ln in lines:
            k, _, v = ln.partition("=")
            if k.strip() in ("data", "resources") and v.strip():
                p = Path(v.strip().strip('"'))
                out.extend(list(p.parents)[:3])
    seen, uniq = set(), []
    for p in out:
        if str(p) not in seen:
            seen.add(str(p))
            uniq.append(p)
    return uniq


def locate(explicit=None, cache_root=None, use_installs: bool = True) -> tuple[Catalog | None, list[str]]:
    """The first usable copy: explicit folder, $OMW2MWSE_OPENMW, newest cached fetch, install paths."""
    searched: list[str] = []
    if explicit:
        searched.append(str(explicit))
        return load(explicit), searched
    env = os.environ.get(ENV_DIR)
    if env:
        if env.lower() == "none":
            return None, ["$%s=none" % ENV_DIR]
        searched.append(env)
        return load(env), searched
    root = Path(cache_root) if cache_root else default_cache_root()
    searched.append(str(root))
    for p in cached_versions(root):
        cat = load(p)
        if cat:
            return cat, searched
    if use_installs:
        for p in install_candidates():
            searched.append(str(p))
            cat = load(p)
            if cat:
                return cat, searched
    return None, searched


# ------------------------------------------------------------------ fetching one release's files
class FetchError(Exception):
    pass


def _http_get(url: str) -> bytes:
    import urllib.request
    req = urllib.request.Request(url, headers={"User-Agent": "omw2mwse-api-audit", "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310 (fixed https hosts)
        return r.read()


def normalize_tag(tag: str) -> str:
    tag = tag.strip()
    if not tag.startswith("openmw-"):
        tag = "openmw-" + tag
    if not TAG_RE.match(tag):
        raise FetchError(f"not a release tag: {tag!r} (expected e.g. openmw-0.51.0)")
    return tag


def fetch(tag: str, cache_root=None, get=None, refresh: bool = False, repo: str = REPO) -> Path:
    """Download files/lua_api/openmw/*.lua of one release tag into <cache>/<version>/ (source-tree
    layout) plus SOURCE.json (tag, version, API revision, hashes). Nothing else is stored; the API
    revision is read from that tag's CMakeLists.txt in memory. Reuses a complete earlier download."""
    get = get or _http_get
    tag = normalize_tag(tag)
    version = tag[len("openmw-"):]
    root = Path(cache_root) if cache_root else default_cache_root()
    dest = root / version
    meta = dest / SOURCE_FILE
    if not refresh and meta.is_file() and stub_dir(dest):
        try:
            if json.loads(meta.read_text(encoding="utf-8")).get("tag") == tag:
                return dest
        except ValueError:
            pass
    api = f"https://api.github.com/repos/{repo}/contents/files/lua_api/openmw?ref={tag}"
    try:
        listing = json.loads(get(api).decode("utf-8"))
        names = sorted(x["name"] for x in listing if x.get("type") == "file" and x["name"].endswith(".lua"))
    except Exception as e:  # noqa: BLE001 (network, JSON)
        raise FetchError(f"cannot list the API files of {tag}: {e}") from e
    if "core.lua" not in names or "types.lua" not in names:
        raise FetchError(f"{tag} has no files/lua_api/openmw/core.lua and types.lua")
    raw = f"https://raw.githubusercontent.com/{repo}/{tag}"
    tmp = root / f".{version}.tmp-{os.getpid()}"
    if tmp.exists():
        shutil.rmtree(tmp)
    sub = tmp / "files" / "lua_api" / "openmw"
    sub.mkdir(parents=True)
    hashes = {}
    try:
        for n in names:
            data = get(f"{raw}/files/lua_api/openmw/{n}")
            (sub / n).write_bytes(data)
            hashes[n] = hashlib.sha256(data).hexdigest()
        try:
            v, rev = parse_cmake(get(f"{raw}/CMakeLists.txt").decode("utf-8", "replace"))
        except Exception:  # noqa: BLE001 (the revision is optional)
            v, rev = None, None
        info = {"repo": repo, "tag": tag, "version": v or version, "apiRevision": rev,
                "fetchedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "license": "OpenMW's files (GPLv3); a local cache, never part of omw2mwse",
                "files": hashes}
        with open(tmp / SOURCE_FILE, "w", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(info, indent=1) + "\n")
    except Exception as e:  # noqa: BLE001
        shutil.rmtree(tmp, ignore_errors=True)
        raise FetchError(f"download of {tag} failed: {e}") from e
    if dest.exists():
        shutil.rmtree(dest)
    tmp.rename(dest)
    return dest


# ------------------------------------------------------------------ audit
def _covered(path: str, syms: set, prefixes: set, unsup: list) -> str:
    if path in syms:
        return "listed"
    if path in prefixes:
        return "namespace"
    parts = path.split(".")
    for k in range(len(parts) - 1, 1, -1):
        if ".".join(parts[:k]) in syms:
            return "belowListed"
    if any(path == u or path.startswith(u + ".") for u in unsup):
        return "unsupportedModule"
    return "unclassified"


def audit(cat: Catalog, manifest: dict, limit: int = 0) -> dict:
    syms = set(manifest["symbols"])
    prefixes = {".".join(s.split(".")[:k]) for s in syms for k in range(2, len(s.split(".")))}
    unsup = list(manifest.get("unsupportedModules", []))
    status = {p: _covered(p, syms, prefixes, unsup) for p in cat.paths if not p.startswith("openmw.interfaces.")}
    counts = {"openmwSymbols": len(status), "manifestSymbols": len(syms)}
    for st in ("listed", "namespace", "belowListed", "unsupportedModule", "unclassified"):
        counts[st] = sum(1 for v in status.values() if v == st)
    # unclassified, reported at the top of each unclassified subtree (size = paths in it)
    tops = []
    for p in sorted(status):
        if status[p] != "unclassified":
            continue
        parent = p.rsplit(".", 1)[0]
        if status.get(parent) == "unclassified":
            continue
        e = cat.paths[p]
        size = sum(1 for q in status if q == p or q.startswith(p + "."))
        tops.append({"symbol": p, "kind": "method" if e["method"] else e["kind"], "size": size,
                     **({"scope": e["scope"]} if e["scope"] else {})})
    by_module: dict[str, int] = {}
    by_group: dict[str, int] = {}
    for p, v in status.items():
        if v == "unclassified":
            parts = p.split(".")
            by_module[".".join(parts[:2])] = by_module.get(".".join(parts[:2]), 0) + 1
            g = ".".join(parts[:3]) if parts[1] == "types" and len(parts) > 3 else ".".join(parts[:2])
            by_group[g] = by_group.get(g, 0) + 1
    counts["unclassifiedTop"] = len(tops)
    stale, unverifiable = [], []
    for s in sorted(syms):
        if s.startswith("openmw.interfaces."):
            continue
        h = cat.has(s)
        if h is False:
            stale.append({"symbol": s, "ours": manifest["symbols"][s]})
        elif h is None:
            unverifiable.append(s)
    counts["stale"], counts["unverifiable"] = len(stale), len(unverifiable)
    hosted = {"global", "local"}
    our_mods = manifest.get("modules", {})
    scopes = manifest.get("moduleScopes", {})
    modules = {}
    for stem in sorted(cat.modules):
        name = "openmw." + stem
        ctx = cat.contexts.get(stem, [])
        ours = our_mods.get(name) or ("unsupported" if name in unsup else "absent")
        e = {"contexts": ctx, "ours": ours, "hostedKinds": bool(set(ctx) & hosted) if ctx else None}
        if name in scopes and ctx and scopes[name] not in ctx:
            e["scopeMismatch"] = f"manifest moduleScopes says {scopes[name]}, OpenMW says {'|'.join(ctx)}"
        modules[name] = e
    for name in sorted(set(our_mods) | set(unsup)):
        if name.startswith("openmw.") and name.split(".", 1)[1] not in cat.modules:
            modules[name] = {"contexts": [], "ours": our_mods.get(name, "unsupported"), "notInOpenMW": True}
    scope_notes = []
    for s in sorted(syms):
        e = cat.paths.get(s)
        if e and e.get("scope") and manifest["symbols"][s] != "unsupported":
            scope_notes.append({"symbol": s, "scope": e["scope"], "ours": manifest["symbols"][s]})
    go = manifest.get("gameObject", {})
    gom = cat.type_members("GameObject") or {}
    om_methods = {k for k, v in gom.items() if v["kind"] == "function"}
    om_fields = {k for k, v in gom.items() if v["kind"] == "field"}
    game_object = {"missingMethods": sorted(om_methods - set(go.get("methods", {}))),
                   "missingFields": sorted(om_fields - set(go.get("fields", []))),
                   "staleMethods": sorted(set(go.get("methods", {})) - om_methods),
                   "staleFields": sorted(set(go.get("fields", [])) - om_fields)}
    type_members = {}
    for typ in sorted(AT.TYPE_MEMBERS):
        ms = cat.type_members(typ)
        if ms is None:
            continue
        ours = set(AT.TYPE_MEMBERS[typ])
        swz = "xyz01" in ms  # vectors document swizzles (v.xy, v.zyx, ...) as one pseudo field
        type_members[typ] = {"missing": sorted(k for k in set(ms) - ours if not (swz and k == "xyz01")),
                             "stale": sorted(k for k in ours - set(ms) if not (swz and re.fullmatch(r"[xyzw01]+", k)))}
    om_if = sorted(cat.members(cat.modules["interfaces"]).keys() - {"__index"}) if "interfaces" in cat.modules else []
    our_if = sorted(manifest.get("builtinInterfaces", {}))
    # interfaces.lua lists the documented built-in interfaces; ours may also name player ones it leaves out
    interfaces = {"openmw": om_if, "ours": our_if, "missing": sorted(set(om_if) - set(our_if)),
                  "notListed": sorted(set(our_if) - set(om_if))}
    lim = (lambda xs: xs[:limit]) if limit else (lambda xs: xs)
    tops.sort(key=lambda x: (-x["size"], x["symbol"]))
    from . import __version__
    return {
        "tool": "omw2mwse", "version": __version__, "command": "api-audit",
        "openmw": dict(cat.info(), found=True), "manifestVersion": manifest.get("version"),
        "counts": counts,
        "unclassified": lim(tops),
        "unclassifiedByModule": dict(sorted(by_module.items(), key=lambda kv: (-kv[1], kv[0]))),
        "unclassifiedByGroup": dict(sorted(by_group.items(), key=lambda kv: (-kv[1], kv[0]))),
        "stale": stale, "unverifiable": lim(unverifiable),
        "modules": modules, "scopeNotes": scope_notes, "gameObject": game_object,
        "typeMembers": type_members, "interfaces": interfaces,
        "notes": ["engine handlers are not in OpenMW's API files; they are not audited",
                  "openmw_aux.* and the members of interfaces (I.AI.startPackage, ...) live in OpenMW's "
                  "scripts, not its API files: reported as unverifiable, never stale"],
    }


def not_found(searched: list[str]) -> dict:
    from . import __version__
    return {"tool": "omw2mwse", "version": __version__, "command": "api-audit",
            "openmw": {"found": False, "searched": searched}, "counts": {}, "notes": [
                "no OpenMW API files found: pass --openmw DIR (an install or source tree), set "
                f"${ENV_DIR}, or download one release's files with --fetch openmw-X.Y.Z"]}


def render(r: dict, top: int = 15) -> str:
    o = r["openmw"]
    if not o.get("found"):
        return "api-audit: " + r["notes"][0] + "\n"
    c = r["counts"]
    out = [f"OpenMW {o.get('version') or '?'} (API revision {o.get('apiRevision') or '?'}, {o['layout']}: "
           f"{o['root']}), {o['files']} API files, {c['openmwSymbols']} symbols; manifest {r['manifestVersion']} "
           f"has {c['manifestSymbols']}",
           f"  listed {c['listed']}, namespaces {c['namespace']}, below a listed entry {c['belowListed']}, "
           f"in unsupported modules {c['unsupportedModule']}, unclassified {c['unclassified']} "
           f"({c['unclassifiedTop']} subtrees)",
           f"  stale manifest entries (not in OpenMW): {c['stale']}; unverifiable: {c['unverifiable']}"]
    out.append("Unclassified by group:")
    out.extend(f"  {g}: {n}" for g, n in list(r["unclassifiedByGroup"].items())[:top])
    out.append("Largest unclassified subtrees:")
    out.extend(f"  {x['symbol']} ({x['kind']}, {x['size']})" for x in r["unclassified"][:top])
    if r["stale"]:
        out.append("Stale:")
        out.extend(f"  {x['symbol']} ({x['ours']})" for x in r["stale"])
    for name, m in r["modules"].items():
        if m.get("scopeMismatch") or m.get("notInOpenMW"):
            out.append(f"  module {name}: " + (m.get("scopeMismatch") or "not an OpenMW module"))
    g = r["gameObject"]
    out.append("GameObject: missing methods " + (", ".join(g["missingMethods"]) or "-")
               + "; missing fields " + (", ".join(g["missingFields"]) or "-")
               + "; stale " + (", ".join(g["staleMethods"] + g["staleFields"]) or "-"))
    for t, d in r["typeMembers"].items():
        if d["missing"] or d["stale"]:
            out.append(f"{t}: missing {', '.join(d['missing']) or '-'}; stale {', '.join(d['stale']) or '-'}")
    i = r["interfaces"]
    out.append(f"Interfaces: missing {', '.join(i['missing']) or '-'}; ours but not in interfaces.lua "
               f"{', '.join(i['notListed']) or '-'}")
    out.append(f"Scope notes (global-/self-only in OpenMW, emulated without that limit): {len(r['scopeNotes'])}")
    return "\n".join(out) + "\n"


if __name__ == "__main__":  # pragma: no cover
    sys.exit("use: omw2mwse api-audit")
