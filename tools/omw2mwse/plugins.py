"""Place and classify plugins in a converted OpenMW package (rule-based, no prompts).

Placement is decided in code only: no readme or FOMOD text, no user prompt.
A plugin in any package subfolder goes to Extras/<Mod>/. A root plugin whose
introduced records are referenced by hosted Lua only inside branches pruned as
dead under omwcompat API_REVISION (70, post-0.49 OpenMW) is obsolete and stays
only under Off/<Mod>/OpenMW/. Every other root plugin is left at the Data Files
root and enabled by default (required if live Lua references it, otherwise
undetermined, because MWScript or records may still need it).
"""
from __future__ import annotations

import re
from pathlib import Path

from . import tes3
from .luatok import LuaSyntaxError, tokenize

PLUGIN_KINDS = {".esp": "esp", ".esm": "esm"}
# original extensions that convert may emit under a new name
PLUGIN_SOURCES = {".esp": "esp", ".esm": "esm", ".omwaddon": "esp", ".omwgame": "esm"}
PLUGIN_RENAMES = {".omwaddon": ".esp", ".omwgame": ".esm"}
PLACEMENTS = ("root", "extras", "off")
STATUSES = ("required", "undetermined", "obsolete")


def compat_api_revision(runtime_lua: Path | None = None) -> int:
    """omwcompat's openmw.core.API_REVISION (used to drop dead legacy branches)."""
    if runtime_lua is not None and runtime_lua.is_file():
        text = runtime_lua.read_text(encoding="utf-8", errors="replace")
        m = re.search(r"\bAPI_REVISION\s*=\s*(\d+)", text)
        if m:
            return int(m.group(1))
    return 70


def _require_module(toks, i) -> str | None:
    """If toks[i] is require('openmw.xxx') return the module path."""
    if i + 3 >= len(toks):
        return None
    if toks[i].kind != "name" or toks[i].value != "require":
        return None
    if toks[i + 1].value != "(" or toks[i + 2].kind != "string":
        return None
    return toks[i + 2].value


def _const_api_compare(left_is_rev: bool, op: str, n: float, revision: int) -> bool | None:
    if not left_is_rev:
        return None
    if op == "<":
        return revision < n
    if op == "<=":
        return revision <= n
    if op == ">":
        return revision > n
    if op == ">=":
        return revision >= n
    if op == "==":
        return revision == n
    if op == "~=":
        return revision != n
    return None


def _eval_cond(toks, start, end, consts: dict[str, bool], aliases: dict[str, str], revision: int) -> bool | None:
    """Constant-fold a short if-condition. None if it is not statically known."""
    sl = toks[start:end]
    if not sl:
        return None
    # not <expr>
    if sl[0].kind == "keyword" and sl[0].value == "not":
        inner = _eval_cond(toks, start + 1, end, consts, aliases, revision)
        return None if inner is None else (not inner)
    # name (a bool constant)
    if len(sl) == 1 and sl[0].kind == "name" and sl[0].value in consts:
        return consts[sl[0].value]
    # [alias.]API_REVISION <op> number   or   number <op> [alias.]API_REVISION
    def is_rev(i: int) -> tuple[bool, int]:
        t = sl[i]
        if t.kind == "name" and aliases.get(t.value) == "openmw.core" and i + 2 < len(sl) \
                and sl[i + 1].value == "." and sl[i + 2].kind == "name" and sl[i + 2].value == "API_REVISION":
            return True, i + 3
        if t.kind == "name" and t.value == "API_REVISION" and aliases.get("<self>") == "openmw.core":
            return True, i + 1
        return False, i + 1

    # scan for API_REVISION op number
    for i in range(len(sl)):
        ok, j = is_rev(i)
        if ok and j + 1 < len(sl) and sl[j].value in ("<", "<=", ">", ">=", "==", "~=") and sl[j + 1].kind == "number":
            try:
                n = float(sl[j + 1].value)
            except ValueError:
                return None
            return _const_api_compare(True, sl[j].value, n, revision)
        if sl[i].kind == "number" and i + 2 < len(sl) and sl[i + 1].value in ("<", "<=", ">", ">=", "==", "~="):
            ok, _ = is_rev(i + 2)
            if ok:
                try:
                    n = float(sl[i].value)
                except ValueError:
                    return None
                # number op API_REVISION  => flip the operator
                flip = {"<": ">", "<=": ">=", ">": "<", ">=": "<=", "==": "==", "~=": "~="}
                return _const_api_compare(True, flip[sl[i + 1].value], n, revision)
    return None


def lua_branch_strings(src: str, revision: int | None = None):
    """String literals in live vs dead Lua under omwcompat.

    Returns (live_strings, live_getGlobalScript, dead_strings, dead_getGlobalScript).
    String sets are lowercased; getGlobalScript entries are (raw, lower) pairs.
    Branches proven dead from a constant `core.API_REVISION` comparison
    (omwcompat reports 70) go in the dead sets, so a legacy OpenMW-0.49 path
    can prove a plugin obsolete without making it required.
    """
    revision = compat_api_revision() if revision is None else revision
    try:
        toks = tokenize(src)
    except LuaSyntaxError:
        # If we cannot parse, treat every quoted string as live (safe: may mark required).
        raw = set(re.findall(r"[\"']([^\"']+)[\"']", src))
        return {s.lower() for s in raw}, []
    aliases: dict[str, str] = {}
    consts: dict[str, bool] = {}
    n = len(toks)

    def assigned_name(i: int) -> str | None:
        # local X = ...  or  X = ...
        if i >= 2 and toks[i - 1].value == "=" and toks[i - 2].kind == "name":
            return toks[i - 2].value
        return None

    for i, t in enumerate(toks):
        mod = _require_module(toks, i)
        if mod and assigned_name(i):
            aliases[assigned_name(i)] = mod
        # local old_API = core.API_REVISION < 59
        if t.kind == "name" and assigned_name(i) is None:
            continue
    # second pass for consts: find `local name = <cond>`
    for i, t in enumerate(toks):
        if t.value != "=" or i == 0 or toks[i - 1].kind != "name":
            continue
        # bound the rhs until newline-equivalent: until keyword that starts a block or symbol `,` at depth 0? 
        # Use tokens up to the next keyword that's not `not` or until end of comparison.
        j = i + 1
        depth = 0
        while j < n:
            v = toks[j].value
            k = toks[j].kind
            if k == "symbol" and v == "(":
                depth += 1
            elif k == "symbol" and v == ")":
                depth = max(0, depth - 1)
            elif depth == 0 and k == "keyword" and v in (
                "if", "then", "else", "elseif", "end", "function", "for", "while", "repeat",
                "do", "local", "return", "break",
            ):
                break
            elif depth == 0 and k == "symbol" and v == ";":
                break
            j += 1
        name = toks[i - 1].value
        val = _eval_cond(toks, i + 1, j, consts, aliases, revision)
        if val is not None:
            consts[name] = val

    # Walk blocks. Stack entries: ('if', live_of_this_branch, cond, live_before)
    # 'do'/'function'/'for'/'while' just track end matching; live is inherited.
    live_stack = [True]
    block: list[tuple[str, bool | None]] = []  # (kind, cond_or_None)

    def live() -> bool:
        return all(live_stack)

    strings: set[str] = set()
    ggs: list[tuple[str, str]] = []
    dead_strings: set[str] = set()
    dead_ggs: list[tuple[str, str]] = []

    def is_get_global(i: int) -> bool:
        # ...mwscript.getGlobalScript ( "id"
        # or getGlobalScript ( "id"
        if toks[i].kind != "name" or toks[i].value != "getGlobalScript":
            return False
        if i + 2 < n and toks[i + 1].value == "(" and toks[i + 2].kind == "string":
            return True
        return False

    i = 0
    while i < n:
        t = toks[i]
        if t.kind == "keyword":
            if t.value == "if":
                # find then
                j = i + 1
                depth = 0
                while j < n and not (toks[j].kind == "keyword" and toks[j].value == "then" and depth == 0):
                    if toks[j].value == "(":
                        depth += 1
                    elif toks[j].value == ")":
                        depth = max(0, depth - 1)
                    j += 1
                cond = _eval_cond(toks, i + 1, j, consts, aliases, revision)
                parent = live()
                branch = parent if cond is None else (parent and cond)
                live_stack.append(branch)
                block.append(("if", cond))
                i = j + 1 if j < n else i + 1
                continue
            if t.value == "elseif":
                if block and block[-1][0] in ("if", "elseif"):
                    prev_cond = block[-1][1]
                    live_stack.pop()
                    parent = live()
                    # find then
                    j = i + 1
                    depth = 0
                    while j < n and not (toks[j].kind == "keyword" and toks[j].value == "then" and depth == 0):
                        if toks[j].value == "(":
                            depth += 1
                        elif toks[j].value == ")":
                            depth = max(0, depth - 1)
                        j += 1
                    cond = _eval_cond(toks, i + 1, j, consts, aliases, revision)
                    # elseif runs only if previous if/elseif cond was false (when known)
                    if prev_cond is True:
                        branch = False
                    elif prev_cond is False:
                        branch = parent if cond is None else (parent and cond)
                    else:
                        branch = parent if cond is None else (parent and cond)
                    live_stack.append(branch)
                    block.append(("elseif", cond if prev_cond is not True else True))
                    i = j + 1 if j < n else i + 1
                    continue
            if t.value == "else":
                if block and block[-1][0] in ("if", "elseif"):
                    prev_cond = block[-1][1]
                    live_stack.pop()
                    parent = live()
                    if prev_cond is True:
                        branch = False
                    elif prev_cond is False:
                        branch = parent
                    else:
                        branch = parent
                    live_stack.append(branch)
                    block.append(("else", None))
                    i += 1
                    continue
            if t.value in ("function", "for", "while", "do"):
                # `do` after for/while is a sub-token; treat any as a block to match end
                # Skip attaching a new block for the `do` that belongs to for/while? Extra
                # 'do' would require an extra 'end'. for X=1,2 do ... end  has for and do.
                # We should only push on for/while/function, and on a bare `do`.
                if t.value == "do" and block and block[-1][0] in ("for", "while"):
                    i += 1
                    continue
                block.append((t.value, None))
                live_stack.append(live())
                i += 1
                continue
            if t.value == "repeat":
                block.append(("repeat", None))
                live_stack.append(live())
                i += 1
                continue
            if t.value == "until":
                if block and block[-1][0] == "repeat":
                    block.pop()
                    live_stack.pop()
                i += 1
                continue
            if t.value == "end":
                if block:
                    kind, _ = block.pop()
                    # pop all elseif/else until the if, already flattened as one stack entry each
                    # Each if/elseif/else pushed one live_stack entry; 'end' closes the current
                    # (if or else) only. That's correct for `if ... else ... end` if we popped
                    # the if entry when we saw else (we did: pop then push else).
                    live_stack.pop()
                i += 1
                continue
        if t.kind == "string":
            low = t.value.lower()
            pair = (t.value, low)
            if live():
                strings.add(low)
                if i >= 2 and is_get_global(i - 2):
                    ggs.append(pair)
            else:
                dead_strings.add(low)
                if i >= 2 and is_get_global(i - 2):
                    dead_ggs.append(pair)
        i += 1
    return strings, ggs, dead_strings, dead_ggs


def live_lua_strings(src: str, revision: int | None = None) -> tuple[set[str], list[tuple[str, str]]]:
    """Live string literals only (legacy helper)."""
    live, ggs, _dead, _dg = lua_branch_strings(src, revision)
    return live, ggs


def is_plugin_path(rel: str) -> bool:
    """True if this original-package relative path is a TES3 plugin (any folder)."""
    return Path(rel.replace("\\", "/")).suffix.lower() in PLUGIN_SOURCES


def installed_plugin_rel(rel: str) -> str:
    """Relative path with .omwaddon/.omwgame renamed so the original engine can load it."""
    rel = rel.replace("\\", "/")
    suf = Path(rel).suffix.lower()
    if suf in PLUGIN_RENAMES:
        return rel[: -len(suf)] + PLUGIN_RENAMES[suf]
    return rel


def extras_prefix(name: str, data_prefix: str = "") -> str:
    """Extras/<Mod>/ under a Data Files root (tidy does not look inside Extras/)."""
    d = (data_prefix.rstrip("/") + "/") if data_prefix else ""
    return f"{d}Extras/{name}/"


def _hits(introduced: set[str], strings: set[str], ggs: list[tuple[str, str]]) -> list[str]:
    """How Lua refers to a plugin-defined id (empty => no such reference in this set)."""
    hits: list[str] = []
    seen: set[str] = set()
    for raw, low in ggs:
        if low in introduced and low not in seen:
            seen.add(low)
            hits.append(f'getGlobalScript("{raw}")')
    for s in strings:
        if s in introduced and s not in seen:
            seen.add(s)
            hits.append(f'record id "{s}"')
    return hits


def _lua_refs(introduced: set[str], lua_texts: dict[str, str], revision: int | None = None):
    """Live and dead-branch references from hosted Lua to a plugin's introduced ids."""
    live: list[str] = []
    dead: list[str] = []
    seen_live: set[str] = set()
    seen_dead: set[str] = set()
    for _path, text in lua_texts.items():
        live_s, live_g, dead_s, dead_g = lua_branch_strings(text, revision)
        for h in _hits(introduced, live_s, live_g):
            if h not in seen_live:
                seen_live.add(h)
                live.append(h)
        for h in _hits(introduced, dead_s, dead_g):
            if h not in seen_dead and h not in seen_live:
                seen_dead.add(h)
                dead.append(h)
    return live, dead


def _status_for(live_hits: list[str], dead_hits: list[str], introduced: set[str], revision: int):
    ids = ", ".join(sorted(introduced)) or "no introduced record ids"
    if live_hits:
        return "required", "hosted Lua references " + ", ".join(live_hits)
    if dead_hits:
        return "obsolete", (
            f"hosted Lua references {', '.join(dead_hits)} only inside a dead "
            f"API_REVISION branch (omwcompat API_REVISION={revision}); "
            f"no live reference to this plugin's records ({ids})"
        )
    return "undetermined", (
        f"hosted Lua does not reference a record this plugin defines ({ids}); "
        "MWScript or records may still need it"
    )


def classify_plugins(src: Path, originals: list[tuple[Path, str]],
                     lua_texts: dict[str, str], name: str,
                     revision: int | None = None,
                     data_prefix: str = "", off_rel: str = "") -> list[dict]:
    """Describe every plugin in the original package and where it is installed.

    originals: (path, relative path in the original package)
    lua_texts: hosted Lua path -> source text
    name: the converted mod id (Extras/<name>/, Off/<name>/OpenMW/)
    """
    revision = compat_api_revision() if revision is None else revision
    d = (data_prefix.rstrip("/") + "/") if data_prefix else ""
    off = off_rel or f"{d}Off/{name}/OpenMW/"
    extras = extras_prefix(name, data_prefix)
    original_names = {rel.replace("\\", "/").lower() for _p, rel in originals}

    items: list[tuple[Path, str]] = []
    seen: set[str] = set()
    for p, rel in originals:
        rel = rel.replace("\\", "/")
        if not is_plugin_path(rel):
            continue
        key = rel.lower()
        if key in seen:
            continue
        seen.add(key)
        items.append((p, rel))

    out: list[dict] = []
    for path, source_rel in items:
        kind = PLUGIN_SOURCES[Path(source_rel).suffix.lower()]
        installed_rel = installed_plugin_rel(source_rel)
        root_name = Path(installed_rel).name
        kind = PLUGIN_KINDS.get(Path(installed_rel).suffix.lower(), kind)
        is_root = "/" not in source_rel
        plugin = tes3.parse_plugin(path)
        entry = {
            "name": root_name,
            "source": Path(source_rel).name,
            "sourceRel": source_rel,
            "kind": kind,
            "placement": "root",
            "status": "undetermined",
            "path": d + root_name,
            "reason": "",
        }
        # Root .omwaddon/.omwgame whose renamed name is already a file in the
        # package is not installed (the shipped .esp/.esm wins).
        clash = (
            is_root
            and Path(source_rel).suffix.lower() in PLUGIN_RENAMES
            and installed_rel.lower() in original_names
            and installed_rel.lower() != source_rel.lower()
        )

        if plugin.error:
            status, reason = "required", (
                f"could not parse {Path(source_rel).name}: {plugin.error}; treated as required"
            )
            live_hits, dead_hits = [], []
            introduced: set[str] = set()
        else:
            introduced = plugin.introduced_ids()
            live_hits, dead_hits = _lua_refs(introduced, lua_texts, revision)
            status, reason = _status_for(live_hits, dead_hits, introduced, revision)

        if not is_root:
            entry["placement"] = "extras"
            entry["status"] = status
            entry["path"] = extras + installed_rel
            folder = source_rel.rsplit("/", 1)[0]
            entry["reason"] = (
                reason.rstrip(".")
                + f". Shipped under {folder}/; placed in Extras/ for the user to inspect "
                "(not auto-enabled)"
            )
        elif clash:
            entry["placement"] = "off"
            entry["status"] = status
            entry["path"] = off + source_rel
            entry["name"] = Path(source_rel).name  # not installed under the .esp name
            entry["reason"] = (
                reason.rstrip(".")
                + f"; not installed as {root_name}: the package also ships that file"
            )
        elif status == "obsolete":
            entry["placement"] = "off"
            entry["status"] = "obsolete"
            entry["path"] = off + source_rel
            entry["reason"] = reason
        else:
            entry["placement"] = "root"
            entry["status"] = status
            entry["path"] = d + root_name
            entry["reason"] = reason
        out.append(entry)
    out.sort(key=lambda e: (e["placement"], e["name"].lower(), e.get("path", "").lower()))
    return out

