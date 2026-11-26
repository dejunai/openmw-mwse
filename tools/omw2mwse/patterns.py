"""Static detection of two OpenMW Lua patterns that omwcompat works around by rule.

Rule `active-collect-dedupe` (runtime guard `activeDedupe`)
    An onObjectActive / onActorActive / onItemActive handler appends its object argument to a
    list kept outside the handler (`table.insert(list, obj)` or `list[#list + 1] = obj`) and the
    handler never looks at that list (or at `x[obj]` / `x[obj.id]`) otherwise, so nothing stops the same object
    from being added again each time its cell is loaded. omwcompat skips a `table.insert` of a
    GameObject that is already in the list while that script's active handler runs. The
    `list[#list + 1] = obj` form is reported but cannot be intercepted.

Rule `mutate-during-iteration` (runtime guard `safeIteration`)
    A table is changed while it is traversed:
      - inside `for k, v in pairs(t)` / `ipairs(t)` / `next, t`: `table.remove(t, ...)`,
        `table.insert(t, ...)`, or `t[...] = nil` in an ipairs loop (ends the loop early);
      - a `k, v = next(t, k)` cursor kept between calls (one element per frame) on a table that
        the same file also changes with `table.remove` / `table.insert` / `t[...] = nil`.
    omwcompat gives the script next / pairs / ipairs that do not skip the element shifted into
    a slot freed by `table.remove` and that restart instead of raising "invalid key to 'next'".
    `t[k] = nil` in an ipairs loop and inserts during a pairs loop are reported only.

Detection is token based (luatok), per file, and conservative: it looks only at the handler's
own body (not at helper functions it calls) and at plain or dotted table names.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .luatok import LuaSyntaxError, Token, tokenize

ACTIVE_HANDLERS = ("onObjectActive", "onActorActive", "onItemActive")
RULE_DEDUPE = "active-collect-dedupe"
RULE_ITER = "mutate-during-iteration"
GUARD_FOR_RULE = {RULE_DEDUPE: "activeDedupe", RULE_ITER: "safeIteration"}
OPENERS = {"function", "if", "do", "repeat"}
CLOSERS = {"end", "until"}


@dataclass
class Finding:
    rule: str
    line: int
    table: str
    detail: str          # short machine-ish description, e.g. "table.insert in onObjectActive"
    guarded: bool        # True when omwcompat's guard covers this case
    handler: str | None = None
    file: str = ""
    extra: dict = field(default_factory=dict)

    def to_json(self) -> dict:
        d = {"rule": self.rule, "file": self.file, "line": self.line, "table": self.table,
             "detail": self.detail, "guarded": self.guarded}
        if self.handler:
            d["handler"] = self.handler
        return d


def _is(t: Token, kind: str, value: str | None = None) -> bool:
    return t.kind == kind and (value is None or t.value == value)


def _sym(toks, i, v) -> bool:
    return 0 <= i < len(toks) and toks[i].kind == "symbol" and toks[i].value == v


def _kw(toks, i, v) -> bool:
    return 0 <= i < len(toks) and toks[i].kind == "keyword" and toks[i].value == v


def _name_at(toks, i) -> tuple[str | None, int]:
    """Dotted name a.b.c starting at i -> (text, index after it)."""
    if i >= len(toks) or toks[i].kind != "name":
        return None, i
    parts = [toks[i].value]
    j = i + 1
    while _sym(toks, j, ".") and j + 1 < len(toks) and toks[j + 1].kind == "name":
        parts.append(toks[j + 1].value)
        j += 2
    return ".".join(parts), j


def _block_end(toks, i) -> int:
    """i is the index of a block opener (function/if/do/repeat); index of its closing end/until."""
    depth = 0
    for j in range(i, len(toks)):
        t = toks[j]
        if t.kind != "keyword":
            continue
        if t.value in OPENERS:
            depth += 1
        elif t.value in CLOSERS:
            depth -= 1
            if depth == 0:
                return j
    return len(toks) - 1


def _function_at(toks, i):
    """i = index of `function`; returns (params, body_start, body_end) or None."""
    j = i + 1
    while j < len(toks) and not _sym(toks, j, "("):
        j += 1
    if j >= len(toks):
        return None
    params, k = [], j + 1
    while k < len(toks) and not _sym(toks, k, ")"):
        if toks[k].kind == "name":
            params.append(toks[k].value)
        k += 1
    return params, k + 1, _block_end(toks, i)


def _function_defs(toks) -> dict[str, int]:
    """name -> index of its `function` keyword (local function f / function f / [local] f = function)."""
    out: dict[str, int] = {}
    for i, t in enumerate(toks):
        if _is(t, "keyword", "function") and i + 1 < len(toks) and toks[i + 1].kind == "name":
            name, j = _name_at(toks, i + 1)
            if name and _sym(toks, j, "("):
                out.setdefault(name, i)
        elif t.kind == "name" and _sym(toks, i + 1, "=") and _kw(toks, i + 2, "function") and not _sym(toks, i - 1, "."):
            if _kw(toks, i - 1, "local") or not (_sym(toks, i - 1, "{") or _sym(toks, i - 1, ",")):
                out.setdefault(t.value, i + 2)
    return out


def _handler_functions(toks, defs) -> list[tuple[str, int]]:
    """(handler name, index of `function`) for onObjectActive = f / onObjectActive = function ... in tables."""
    found = []
    for i, t in enumerate(toks):
        if t.kind == "name" and t.value in ACTIVE_HANDLERS and _sym(toks, i + 1, "=") and \
                (_sym(toks, i - 1, "{") or _sym(toks, i - 1, ",")):
            if _kw(toks, i + 2, "function"):
                found.append((t.value, i + 2))
            else:
                ref, _ = _name_at(toks, i + 2)
                if ref and ref in defs:
                    found.append((t.value, defs[ref]))
    return found


def _call_args(toks, i):
    """i = index of `(`; returns (list of (start, end) token ranges per argument, index of `)`)."""
    args, depth, start = [], 0, i + 1
    for j in range(i, len(toks)):
        t = toks[j]
        if t.kind == "symbol" and t.value in ("(", "{", "["):
            depth += 1
        elif t.kind == "symbol" and t.value in (")", "}", "]"):
            depth -= 1
            if depth == 0:
                if j > start:
                    args.append((start, j))
                return args, j
        elif t.kind == "symbol" and t.value == "," and depth == 1:
            args.append((start, j))
            start = j + 1
    return args, len(toks) - 1


def _text(toks, a, b) -> str:
    return "".join(t.value if t.kind != "string" else repr(t.value) for t in toks[a:b])


def _table_calls(toks, lo, hi, fn):
    """`table.<fn>(` calls in [lo, hi): yields (index of `table`, args, close)."""
    for i in range(lo, hi):
        if toks[i].kind == "name" and toks[i].value == "table" and _sym(toks, i + 1, ".") and \
                i + 2 < len(toks) and toks[i + 2].kind == "name" and toks[i + 2].value == fn and _sym(toks, i + 3, "(") \
                and not _sym(toks, i - 1, "."):
            args, close = _call_args(toks, i + 3)
            yield i, args, close


def _nil_assigns(toks, lo, hi, table):
    """`table[ ... ] = nil` in [lo, hi): yields index of the table name."""
    for i in range(lo, hi):
        name, j = _name_at(toks, i)
        if name != table or _sym(toks, i - 1, ".") or not _sym(toks, j, "["):
            continue
        depth, k = 0, j
        while k < hi:
            if _sym(toks, k, "["):
                depth += 1
            elif _sym(toks, k, "]"):
                depth -= 1
                if depth == 0:
                    break
            k += 1
        if _sym(toks, k + 1, "=") and _kw(toks, k + 2, "nil"):
            yield i


def _detect_dedupe(toks, handler, fi, out):
    fn = _function_at(toks, fi)
    if not fn:
        return
    params, lo, hi = fn
    if not params:
        return
    obj = params[0]
    local_names = {toks[i + 1].value for i in range(lo, hi) if _kw(toks, i, "local") and i + 1 < hi
                   and toks[i + 1].kind == "name"}
    sites = []   # (table name, line, form, token range)
    for i, args, close in _table_calls(toks, lo, hi, "insert"):
        if len(args) != 2:
            continue
        (a0, b0), (a1, b1) = args
        tname, end0 = _name_at(toks, a0)
        if tname is None or end0 != b0 or b1 - a1 != 1 or toks[a1].kind != "name" or toks[a1].value != obj:
            continue
        sites.append((tname, toks[i].line, "table.insert", (i, close + 1)))
    for i in range(lo, hi):
        # list[#list + 1] = obj
        tname, j = _name_at(toks, i)
        if not tname or _sym(toks, i - 1, ".") or not (_sym(toks, j, "[") and _sym(toks, j + 1, "#")):
            continue
        n2, k = _name_at(toks, j + 2)
        if n2 != tname or not (_sym(toks, k, "+") and k + 1 < hi and toks[k + 1].value == "1" and _sym(toks, k + 2, "]")
                               and _sym(toks, k + 3, "=") and k + 4 < hi and toks[k + 4].kind == "name"
                               and toks[k + 4].value == obj and not _sym(toks, k + 5, ".") and not _sym(toks, k + 5, ":")):
            continue
        sites.append((tname, toks[i].line, "append-index", (i, k + 5)))
    # a set-style check anywhere in the handler (x[obj] or x[obj.id]: both identify the object)
    # counts as deduplication; x[obj.recordId] does not (many objects share a record)
    def _keyed(i):
        if not (_sym(toks, i, "[") and i + 1 < hi and toks[i + 1].kind == "name" and toks[i + 1].value == obj):
            return False
        if _sym(toks, i + 2, "]"):
            return True
        return _sym(toks, i + 2, ".") and i + 3 < hi and toks[i + 3].value == "id" and _sym(toks, i + 4, "]")
    indexed_by_obj = any(_keyed(i) for i in range(lo, hi))
    for tname, line, form, (sa, sb) in sites:
        if tname.split(".")[0] in local_names or tname == obj or indexed_by_obj:
            continue
        other = False
        for i in range(lo, hi):
            if sa <= i < sb:
                continue
            nm, _ = _name_at(toks, i)
            if nm == tname and not _sym(toks, i - 1, "."):
                other = True
                break
        if other:
            continue
        out.append(Finding(RULE_DEDUPE, line, tname, f"{form} of the {handler} argument with no duplicate check",
                           guarded=(form == "table.insert"), handler=handler))


def _iter_header(toks, i):
    """i = index of `for`; generic for over pairs/ipairs/next of a named table ->
    (kind, table, index of `do`) or None."""
    j = i + 1
    while j < len(toks) and not _kw(toks, j, "in") and not _sym(toks, j, "="):
        j += 1
    if not _kw(toks, j, "in"):
        return None
    k = j + 1
    if k < len(toks) and toks[k].kind == "name" and toks[k].value in ("pairs", "ipairs") and _sym(toks, k + 1, "("):
        tname, e = _name_at(toks, k + 2)
        if tname and _sym(toks, e, ")") and _kw(toks, e + 1, "do"):
            return toks[k].value, tname, e + 1
    if k < len(toks) and toks[k].kind == "name" and toks[k].value == "next" and _sym(toks, k + 1, ","):
        tname, e = _name_at(toks, k + 2)
        if tname and _kw(toks, e, "do"):
            return "next", tname, e
    return None


def _mutations(toks, lo, hi, tname, with_nil: bool):
    """(line, what, guarded) for table.remove/insert on tname (and tname[...] = nil if with_nil)."""
    out = []
    for fn in ("remove", "insert"):
        for i, args, _ in _table_calls(toks, lo, hi, fn):
            if not args:
                continue
            a0, b0 = args[0]
            nm, e = _name_at(toks, a0)
            if nm == tname and e == b0:
                out.append((toks[i].line, f"table.{fn}", fn == "remove"))
    if with_nil:
        for i in _nil_assigns(toks, lo, hi, tname):
            out.append((toks[i].line, "nil-assign", False))
    return out


def _detect_iteration(toks, out):
    seen = set()
    for i, t in enumerate(toks):
        if not _is(t, "keyword", "for"):
            continue
        h = _iter_header(toks, i)
        if not h:
            continue
        kind, tname, do_i = h
        end_i = _block_end(toks, do_i)
        for line, what, guarded in _mutations(toks, do_i, end_i, tname, with_nil=(kind == "ipairs")):
            if what == "table.insert":
                guarded = False
            key = (line, tname, what)
            if key in seen:
                continue
            seen.add(key)
            out.append(Finding(RULE_ITER, line, tname, f"{what} on {tname} inside a for ... in {kind}({tname}) loop",
                               guarded=guarded))
    # cursor: k, v = next(t, k) (or k = next(t, k)) kept between calls
    cursors = {}
    for i, t in enumerate(toks):
        if not (t.kind == "name" and t.value == "next" and _sym(toks, i + 1, "(")) or _sym(toks, i - 1, "."):
            continue
        args, _ = _call_args(toks, i + 1)
        if len(args) != 2:
            continue
        tname, e = _name_at(toks, args[0][0])
        kname, e2 = _name_at(toks, args[1][0])
        if not tname or e != args[0][1] or not kname or e2 != args[1][1]:
            continue
        # the cursor must be assigned from this call: `kname [, v] = next(...)`
        j = i - 1
        if not _sym(toks, j, "="):
            continue
        j -= 1
        names = []
        while j >= 0 and toks[j].kind == "name":
            names.append(toks[j].value)
            if _sym(toks, j - 1, ","):
                j -= 2
            else:
                break
        if kname in names:
            cursors.setdefault(tname, toks[i].line)
    for tname, cline in cursors.items():
        for line, what, guarded in _mutations(toks, 0, len(toks), tname, with_nil=True):
            if what == "table.insert":
                guarded = True   # appends do not move the cursor; a vanished key restarts the traversal
            if what == "nil-assign":
                guarded = True   # next() keeps working after t[k] = nil; a vanished key restarts the traversal
            key = (line, tname, what)
            if key in seen:
                continue
            seen.add(key)
            out.append(Finding(RULE_ITER, line, tname,
                               f"{what} on {tname} while a next({tname}, cursor) traversal (line {cline}) is in progress",
                               guarded=guarded, extra={"cursorLine": cline}))


def detect(src: str) -> list[Finding]:
    """All findings for one Lua source, ordered by line."""
    try:
        toks = tokenize(src)
    except LuaSyntaxError:
        return []
    out: list[Finding] = []
    defs = _function_defs(toks)
    for handler, fi in _handler_functions(toks, defs):
        _detect_dedupe(toks, handler, fi, out)
    _detect_iteration(toks, out)
    out.sort(key=lambda f: (f.line, f.rule))
    return out
