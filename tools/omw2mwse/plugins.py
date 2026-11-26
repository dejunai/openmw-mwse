"""Decide whether a root-level plugin is optional for tidy (rule-based)."""
from __future__ import annotations

import re
from pathlib import Path
from xml.etree import ElementTree as ET

from . import tes3
from .luatok import LuaSyntaxError, tokenize

PLUGIN_KINDS = {".esp": "esp", ".esm": "esm"}
# original extensions that convert may emit under a new name
PLUGIN_SOURCES = {".esp": "esp", ".esm": "esm", ".omwaddon": "esp", ".omwgame": "esm"}

# Words in a readme, next to the plugin filename, that mark it optional/legacy.
README_MARK = re.compile(
    r"\b(optional|legacy|not required|only needed|older(?:\s+openmw)?|old openmw|"
    r"pre-?april|api\s*<\s*\d+)\b",
    re.IGNORECASE,
)
README_NAMES = re.compile(r"^(readme|read me|license|changelog|notes)(\b|\.|$)", re.IGNORECASE)
OPTIONAL_DIR = re.compile(r"(^|/)(optional|optionals|legacy)(/|$)", re.IGNORECASE)


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


def live_lua_strings(src: str, revision: int | None = None) -> tuple[set[str], list[tuple[str, str]]]:
    """String literals in code that actually runs under omwcompat.

    Returns (all live string values lowercased, and getGlobalScript argument strings
    as (raw, lower) pairs). Branches proven dead from a constant
    `core.API_REVISION` comparison (omwcompat reports 70) are skipped, so a
    legacy OpenMW-0.49 path is not treated as a dependency of the conversion.
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
        if t.kind == "string" and live():
            strings.add(t.value.lower())
            if i >= 2 and is_get_global(i - 2):
                ggs.append((t.value, t.value.lower()))
        i += 1
    return strings, ggs


def _readme_files(src: Path) -> list[Path]:
    out = []
    for p in src.rglob("*"):
        if not p.is_file():
            continue
        rel = p.relative_to(src).as_posix()
        if rel.lower().startswith("mwse/") or "/__pycache__/" in "/" + rel.lower() + "/":
            continue
        name = p.name
        if README_NAMES.match(name) or p.suffix.lower() in (".md", ".txt") and name.lower() in {
            "readme.md", "readme.txt", "readme", "read me.txt", "documentation.md",
        }:
            out.append(p)
        elif name.lower() in {"readme.txt", "readme.md", "readme"}:
            out.append(p)
    # also any top-level .txt/.md
    for p in src.iterdir() if src.is_dir() else []:
        if p.is_file() and p.suffix.lower() in (".txt", ".md"):
            if p not in out:
                out.append(p)
    return out


def _readme_marks_optional(src: Path, filename: str) -> str | None:
    """Return a short reason if a readme next to the filename calls it optional/legacy."""
    needle = filename.lower()
    stem = Path(filename).stem.lower()
    for p in _readme_files(src):
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        lines = text.splitlines()
        for i, line in enumerate(lines):
            low = line.lower()
            if needle not in low and stem not in low:
                continue
            window = "\n".join(lines[max(0, i - 2):i + 3])
            if README_MARK.search(window):
                return f"readme {p.relative_to(src).as_posix()} describes {filename} as optional or legacy"
    return None


def _fomod_optional_files(src: Path) -> set[str]:
    """Basenames listed in a FOMOD optionalFileGroups entry and not in requiredInstallFiles."""
    paths = list(src.glob("fomod/ModuleConfig.xml")) + list(src.glob("ModuleConfig.xml"))
    optional: set[str] = set()
    required: set[str] = set()

    def local(tag: str) -> str:
        return tag.rsplit("}", 1)[-1].lower()

    def files_under(el) -> list[str]:
        out = []
        for n in el.iter():
            if local(n.tag) in ("file", "folder"):
                src_a = n.attrib.get("source") or n.attrib.get("Source") or ""
                dest = n.attrib.get("destination") or n.attrib.get("Destination") or src_a
                if dest:
                    out.append(Path(dest).name.lower())
                if src_a:
                    out.append(Path(src_a).name.lower())
        return out

    for cfg in paths:
        try:
            root = ET.parse(cfg).getroot()
        except (ET.ParseError, OSError):
            continue
        for n in root.iter():
            tag = local(n.tag)
            if tag == "requiredinstallfiles":
                required.update(files_under(n))
            elif tag == "optionalfilegroups":
                optional.update(files_under(n))
    return {n for n in optional if n not in required}


def package_optional_reason(src: Path, source_rel: str, filename: str) -> str | None:
    rel = source_rel.replace("\\", "/")
    if OPTIONAL_DIR.search(rel):
        return f"shipped under {rel.rsplit('/', 1)[0]}/ (optional or legacy folder)"
    fomod = _fomod_optional_files(src)
    if filename.lower() in fomod or Path(source_rel).name.lower() in fomod:
        return f"{filename} is in a FOMOD optional group"
    return _readme_marks_optional(src, filename) or _readme_marks_optional(src, Path(source_rel).name)


def _lua_needs(introduced: set[str], lua_texts: dict[str, str], revision: int | None = None) -> list[str]:
    """How the hosted Lua refers to a plugin-defined id (empty => it does not need the plugin)."""
    hits: list[str] = []
    seen: set[str] = set()
    for path, text in lua_texts.items():
        strings, ggs = live_lua_strings(text, revision)
        for raw, low in ggs:
            if low in introduced and low not in seen:
                seen.add(low)
                hits.append(f'getGlobalScript("{raw}")')
        for s in strings:
            if s in introduced and s not in seen:
                seen.add(s)
                hits.append(f'record id "{s}"')
    return hits


def classify_root_plugins(src: Path, originals: list[tuple[Path, str]],
                          renamed: list[tuple[str, str]], lua_texts: dict[str, str],
                          revision: int | None = None) -> list[dict]:
    """Describe every plugin emit-or-leave at the Data Files root.

    originals: (path, relative path in the original package)
    renamed: (original rel, Data Files root rel) for .omwaddon/.omwgame
    lua_texts: hosted Lua path -> source text
    """
    rename_to = {o.replace("\\", "/"): n for o, n in renamed}
    rename_from = {n.replace("\\", "/"): o for o, n in renamed}
    # root-level original plugins (after rename, the name at the Data Files root)
    items: list[tuple[Path, str, str]] = []  # (file, source_rel, root_name)
    seen_root: set[str] = set()
    for p, rel in originals:
        rel = rel.replace("\\", "/")
        suf = Path(rel).suffix.lower()
        if suf not in PLUGIN_SOURCES:
            continue
        if "/" in rel and not rename_to.get(rel):
            # only root-level plugins are installed at the Data Files root
            # (is_game_asset requires no slash), unless we somehow renamed one
            continue
        if "/" in rel:
            continue
        root_name = rename_to.get(rel, rel)
        # clash case: renamed_plugin was skipped, so the plugin is Off/-only
        # (not at the root). Those are not "emitted or left at the mod root".
        if rel in rename_from.values() and rel not in rename_to and root_name == rel and suf in {".omwaddon", ".omwgame"}:
            # not in rename_to means it was not installed under a new name; also
            # not left as .omwaddon at the root. skip.
            pass
        key = root_name.lower()
        if key in seen_root:
            continue
        seen_root.add(key)
        items.append((p, rel, root_name))

    out: list[dict] = []
    for path, source_rel, root_name in items:
        kind = PLUGIN_SOURCES[Path(source_rel).suffix.lower()]
        # if the installed name has a known kind, prefer that
        kind = PLUGIN_KINDS.get(Path(root_name).suffix.lower(), kind)
        plugin = tes3.parse_plugin(path)
        entry = {"name": root_name, "source": Path(source_rel).name, "kind": kind,
                 "optional": False, "reason": ""}
        if plugin.error:
            entry["reason"] = f"could not parse {Path(source_rel).name}: {plugin.error}; treated as required"
            out.append(entry)
            continue
        introduced = plugin.introduced_ids()
        needs = _lua_needs(introduced, lua_texts, revision)
        pkg = package_optional_reason(src, source_rel, root_name)
        if not needs:
            entry["optional"] = True
            ids = ", ".join(sorted(introduced)) or "no introduced record ids"
            entry["reason"] = (
                f"hosted Lua does not reference a record this plugin defines ({ids})"
            )
            if pkg:
                entry["reason"] += "; " + pkg
        elif pkg:
            entry["optional"] = True
            entry["reason"] = pkg + f" (Lua does reference {', '.join(needs)})"
        else:
            entry["optional"] = False
            entry["reason"] = "hosted Lua references " + ", ".join(needs)
        out.append(entry)
    out.sort(key=lambda e: e["name"].lower())
    return out
