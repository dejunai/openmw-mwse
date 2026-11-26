"""Hard-coded constant detection and conversion for omw2mwse.

detect(src) finds
  * top-level ``local NAME = <literal>`` constants (number / boolean / string), and
  * inline comparison literals inside functions (``hour < 7``), reported only.
rewrite(src, conversions) replaces chosen literals with
  ``omwcompat.cfg("KEY", <original literal>) --[[omw2mwse: hard-coded <literal>]]``
keeping every line in place. All functions are pure; nothing here touches disk.
MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field, asdict

from .luatok import tokenize, Token

BINOPS = {"+", "-", "*", "/", "%", "^", "..", "==", "~=", "<", ">", "<=", ">=", "and", "or", "(", "[", ".", ":", "{"}
COMPARE = {"<", ">", "<=", ">=", "==", "~="}
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")


@dataclass
class Constant:
    name: str
    line: int
    type: str            # number | boolean | string
    literal: str         # raw source text of the literal
    value: object
    start: int
    end: int
    uses: int = 0
    uses_in_functions: int = 0
    functions: list = field(default_factory=list)
    reassigned: bool = False
    shadowed: bool = False
    concat: bool = False
    table_key: bool = False
    upper: bool = False
    risks: list = field(default_factory=list)
    eligible: bool = True
    reason: str = ""

    def to_json(self) -> dict:
        d = asdict(self)
        d.pop("start"); d.pop("end")
        return d


@dataclass
class InlineLiteral:
    line: int
    literal: str
    type: str
    context: str         # e.g. "clockHour < 7"
    function: str
    start: int
    end: int

    def to_json(self) -> dict:
        d = asdict(self)
        d.pop("start"); d.pop("end")
        return d


def literal_value(raw: str, kind: str):
    if kind == "boolean":
        return raw == "true"
    if kind == "string":
        return None  # filled from the token value
    neg = raw.startswith("-")
    body = raw[1:].strip() if neg else raw
    try:
        v = int(body, 16) if body.lower().startswith("0x") else (int(body) if re.fullmatch(r"\d+", body) else float(body))
    except ValueError:
        return None
    return -v if neg else v


def annotate(toks: list[Token]):
    """Per token: (function depth, block depth, bracket depth, enclosing function name)."""
    out = []
    stack: list[tuple[str, str]] = []   # (kind, name)
    brackets = 0
    pending_fn = None
    for i, t in enumerate(toks):
        fdepth = sum(1 for k, _ in stack if k == "function")
        fname = next((n for k, n in reversed(stack) if k == "function"), "")
        out.append((fdepth, len(stack), brackets, fname))
        if t.kind == "keyword":
            if t.value == "function":
                name = ""
                # function NAME / local function NAME / NAME = function
                j = i + 1
                parts = []
                while j < len(toks) and (toks[j].kind == "name" or toks[j].value in (".", ":")):
                    parts.append(toks[j].value); j += 1
                name = "".join(parts)
                if not name and i >= 2 and toks[i - 1].value == "=" and toks[i - 2].kind == "name":
                    name = toks[i - 2].value
                stack.append(("function", name or "<anonymous>"))
            elif t.value in ("if", "do", "repeat"):
                # 'while x do' / 'for ... do' open one block at 'do'
                stack.append(("block", ""))
            elif t.value in ("end", "until"):
                if stack:
                    stack.pop()
        elif t.kind == "symbol":
            if t.value in ("(", "{", "["):
                brackets += 1
            elif t.value in (")", "}", "]"):
                brackets = max(0, brackets - 1)
    return out


def _lit_at(toks, i):
    """Literal starting at token i -> (kind, raw_start, raw_end, next_index, value) or None."""
    t = toks[i]
    if t.kind == "number":
        return ("number", t.start, t.end, i + 1, None)
    if t.kind == "keyword" and t.value in ("true", "false"):
        return ("boolean", t.start, t.end, i + 1, t.value == "true")
    if t.kind == "string":
        return ("string", t.start, t.end, i + 1, t.value)
    if t.kind == "symbol" and t.value == "-" and i + 1 < len(toks) and toks[i + 1].kind == "number":
        return ("number", t.start, toks[i + 1].end, i + 2, None)
    return None


def detect(src: str):
    toks = tokenize(src)
    ann = annotate(toks)
    consts: dict[str, Constant] = {}
    decl_tokens = set()
    for i, t in enumerate(toks):
        if t.kind != "keyword" or t.value != "local" or ann[i][1] != 0 or ann[i][2] != 0:
            continue
        if i + 3 >= len(toks) or toks[i + 1].kind != "name" or toks[i + 2].value != "=":
            continue
        lit = _lit_at(toks, i + 3)
        if not lit:
            continue
        kind, a, b, nxt, val = lit
        if nxt < len(toks) and (toks[nxt].value in BINOPS):
            continue  # expression, not a plain literal
        raw = src[a:b]
        name = toks[i + 1].value
        if val is None and kind == "number":
            val = literal_value(raw, kind)
        if name in consts:
            consts[name].shadowed = True
            continue
        consts[name] = Constant(name=name, line=t.line, type=kind, literal=raw, value=val, start=a, end=b,
                                upper=bool(re.fullmatch(r"[A-Z][A-Z0-9_]*", name)))
        decl_tokens.add(i + 1)
    # uses / reassignment
    for i, t in enumerate(toks):
        if t.kind != "name" or t.value not in consts or i in decl_tokens:
            continue
        c = consts[t.value]
        prev = toks[i - 1] if i else None
        nxt = toks[i + 1] if i + 1 < len(toks) else None
        if prev is not None and prev.value in (".", ":"):
            continue  # field access a.NAME
        if prev is not None and prev.value == "local" or (prev is not None and prev.value == "for"):
            c.shadowed = True
            continue
        if prev is not None and prev.value == "," and _in_local_list(toks, i):
            c.shadowed = True
            continue
        if nxt is not None and nxt.value == "=":
            if ann[i][2] > 0 and prev is not None and prev.value in ("{", ","):
                continue  # table key { NAME = ... }
            c.reassigned = True
            continue
        if nxt is not None and nxt.value == "," and _is_multi_assign(toks, i):
            c.reassigned = True
            continue
        c.uses += 1
        if ann[i][0] > 0:
            c.uses_in_functions += 1
            if ann[i][3] not in c.functions:
                c.functions.append(ann[i][3])
        if (prev is not None and prev.value == "..") or (nxt is not None and nxt.value == ".."):
            c.concat = True
        if prev is not None and prev.value == "[" and nxt is not None and nxt.value == "]":
            c.table_key = True
    for c in consts.values():
        classify(c)
    inline = []
    for i, t in enumerate(toks):
        if ann[i][0] == 0 or t.kind != "number":
            continue
        prev = toks[i - 1] if i else None
        nxt = toks[i + 1] if i + 1 < len(toks) else None
        if prev is not None and prev.value in COMPARE and i >= 2 and toks[i - 2].kind == "name":
            ctx = src[toks[i - 2].start:t.end]
        elif nxt is not None and nxt.value in COMPARE and i + 2 < len(toks) and toks[i + 2].kind == "name" \
                and (prev is None or prev.value not in BINOPS - {"(", "{", "["} - COMPARE):
            ctx = src[t.start:toks[i + 2].end]
        else:
            continue
        if t.value in ("0", "1", "-1"):
            continue  # zero/one checks are almost never tunables
        inline.append(InlineLiteral(line=t.line, literal=t.value, type="number", context=ctx,
                                    function=ann[i][3], start=t.start, end=t.end))
    return list(consts.values()), inline


def _in_local_list(toks, i):
    j = i - 1
    while j >= 0 and (toks[j].kind == "name" or toks[j].value == ","):
        j -= 1
    return j >= 0 and toks[j].value == "local"


def _is_multi_assign(toks, i):
    j = i + 1
    while j < len(toks) and (toks[j].kind == "name" or toks[j].value == ","):
        j += 1
    k = i - 1
    while k >= 0 and (toks[k].kind == "name" or toks[k].value == ","):
        k -= 1
    if k >= 0 and toks[k].value == "local":
        return False
    return j < len(toks) and toks[j].value == "=" and (k < 0 or toks[k].value not in ("{", "(", "[")
                                                        and toks[k].kind != "symbol" or toks[k].value in (";", ")", "]", "}"))


def classify(c: Constant) -> None:
    risks = []
    if c.reassigned:
        c.eligible, c.reason = False, "reassigned at runtime (it is state, not a constant)"
    elif c.shadowed:
        c.eligible, c.reason = False, "declared or shadowed more than once"
    elif c.uses == 0:
        c.eligible, c.reason = False, "never read"
    elif not KEY_RE.match(c.name):
        c.eligible, c.reason = False, "name is not usable as a config key"
    if c.uses_in_functions < c.uses:
        risks.append("read at load time (top-level code): a new value applies only after the script reloads")
    if c.uses_in_functions:
        risks.append("captured as an upvalue by " + ", ".join(sorted(c.functions)) +
                     ": a new value applies after the script reloads (save load, or closing the MCM)")
    if c.type == "string":
        risks.append("string constant: often a record id, path or event name; editing it can break lookups")
    if c.concat:
        risks.append("concatenated into strings (ids/paths/messages)")
    if c.table_key:
        risks.append("used as a table key")
    if c.type == "number" and isinstance(c.value, int) and not isinstance(c.value, bool):
        risks.append("integer: fractional values from the MCM are rounded only if 'integer' is set")
    c.risks = risks


def auto_pick(consts: list[Constant]) -> list[tuple[Constant, str]]:
    """Best-effort pick for --mode hardcode without a sidecar.

    Picks eligible UPPER_CASE number/boolean constants (the usual convention for a
    tunable). Returns (constant, reason) for every candidate, picked or skipped.
    """
    out = []
    for c in consts:
        if not c.eligible:
            out.append((c, "skipped: " + c.reason))
        elif c.type == "string":
            out.append((c, "skipped: string constants are not auto-picked"))
        elif not c.upper:
            out.append((c, "skipped: not an UPPER_CASE name (likely internal state)"))
        else:
            out.append((c, "picked: UPPER_CASE " + c.type + " literal, never reassigned"))
    return out


@dataclass
class Conversion:
    key: str
    kind: str            # constant | literal
    file: str
    line: int
    name: str            # constant name, or the context for literals
    type: str
    literal: str
    default: object
    start: int
    end: int
    apply: str           # live | reload
    label: str = ""
    description: str = ""
    min: object = None
    max: object = None
    integer: bool = False
    risks: list = field(default_factory=list)
    origin: str = ""     # "sidecar" or "auto: <reason>"
    function: str = ""   # enclosing function for literals
    before: str = ""     # source excerpt before / after the rewrite (for the warning and report)
    after: str = ""
    apply_note: str = ""

    def replacement(self) -> str:
        return 'omwcompat.cfg("%s", %s) --[[omw2mwse: hard-coded %s]]' % (self.key, self.literal, self.literal.replace("]]", "] ]"))

    def to_json(self) -> dict:
        d = asdict(self)
        d.pop("start"); d.pop("end")
        d["replacement"] = self.replacement()
        return d


def rewrite(src: str, convs: list[Conversion]) -> str:
    out = src
    for c in sorted(convs, key=lambda c: c.start, reverse=True):
        assert out[c.start:c.end] == c.literal, (c.key, out[c.start:c.end], c.literal)
        out = out[:c.start] + c.replacement() + out[c.end:]
    tokenize(out)  # must still be valid
    return out


def find_literal(src: str, line: int, context: str, literal: str | None):
    """Locate a literal by line + context. Returns (start, end, raw, kind, value, in_function)."""
    toks = tokenize(src)
    ann = annotate(toks)
    lines = src.split("\n")
    if line < 1 or line > len(lines):
        raise ValueError("line %d out of range" % line)
    line_start = sum(len(x) + 1 for x in lines[:line - 1])
    text = lines[line - 1]
    n = text.count(context)
    if n != 1:
        raise ValueError("context %r found %d times on line %d (need exactly 1)" % (context, n, line))
    a = line_start + text.index(context)
    b = a + len(context)
    hits = []
    for i, t in enumerate(toks):
        if t.start >= a and t.end <= b:
            lit = _lit_at(toks, i)
            if lit and (literal is None or src[lit[1]:lit[2]] == literal):
                if i > 0 and toks[i - 1].value == "-" and toks[i - 1].start >= a and lit[0] == "number" and literal is None:
                    continue
                hits.append((i, lit))
    # drop a bare number that is the tail of a '-N' literal already listed
    uniq = {}
    for i, lit in hits:
        uniq[(lit[1], lit[2])] = (i, lit)
    hits = list(uniq.values())
    if len(hits) != 1:
        raise ValueError("literal %r found %d times in context %r on line %d (need exactly 1)" % (literal, len(hits), context, line))
    i, (kind, s, e, _, val) = hits[0]
    raw = src[s:e]
    if kind == "number":
        val = literal_value(raw, kind)
    return s, e, raw, kind, val, ann[i][0] > 0, ann[i][2] > 0
