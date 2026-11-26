"""TOML reading for Python 3.9+: the stdlib `tomllib` (3.11+) when present, else a small reader.

omw2mwse reads two kinds of TOML: sidecars (<Mod>.omw2mwse.toml: [mod], [mcm], [[constant]],
[[literal]] with strings, integers, floats and booleans) and MWSE metadata files
(<Mod>-metadata.toml: [package] with strings and string arrays, [tools.mwse]). The fallback
covers exactly that and a little more: comments, [table] / [a.b] / [[array]] headers, bare,
quoted and dotted keys, basic and literal strings (single- and multi-line), integers
(decimal, 0x/0o/0b, underscores), floats, booleans, arrays and inline tables. Dates/times
are not supported (TOMLDecodeError). No third-party dependencies.
MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

import re


def _backend():
    try:
        import tomllib  # Python 3.11+
        return tomllib
    except ImportError:  # Python 3.9 / 3.10
        import sys
        return sys.modules[__name__]


class TOMLDecodeError(ValueError):
    pass


def load(fp) -> dict:
    """Like tomllib.load: fp is a binary file."""
    b = _backend()
    if b is not _SELF:
        return b.load(fp)
    data = fp.read()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise TOMLDecodeError(f"not UTF-8: {e}") from e
    return _loads(text)


def loads(s: str) -> dict:
    b = _backend()
    if b is not _SELF:
        return b.loads(s)
    return _loads(s)


def decode_error():
    """The exception class the active backend raises (tomllib.TOMLDecodeError or ours)."""
    b = _backend()
    return TOMLDecodeError if b is _SELF else b.TOMLDecodeError


# ------------------------------------------------------------------ the fallback reader
_BARE = re.compile(r"[A-Za-z0-9_-]+")
_ESC = {"b": "\b", "t": "\t", "n": "\n", "f": "\f", "r": "\r", '"': '"', "\\": "\\", "e": "\x1b"}
_INT = re.compile(r"[+-]?(0|[1-9](_?[0-9])*)")
_HEX = re.compile(r"0x[0-9A-Fa-f](_?[0-9A-Fa-f])*|0o[0-7](_?[0-7])*|0b[01](_?[01])*")
_FLOAT = re.compile(r"[+-]?(0|[1-9](_?[0-9])*)(\.[0-9](_?[0-9])*)?([eE][+-]?[0-9](_?[0-9])*)?")


class _P:
    def __init__(self, s: str):
        self.s = s.replace("\r\n", "\n")
        self.i = 0
        self.line = 1

    def err(self, msg):
        line = self.s.count("\n", 0, self.i) + 1
        return TOMLDecodeError(f"{msg} (at line {line})")

    def peek(self, n=1):
        return self.s[self.i:self.i + n]

    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in " \t":
            self.i += 1

    def ws_nl(self):
        """Whitespace, newlines and comments (inside arrays)."""
        while self.i < len(self.s):
            c = self.s[self.i]
            if c in " \t\n":
                self.i += 1
            elif c == "#":
                self.skip_comment()
            else:
                break

    def skip_comment(self):
        j = self.s.find("\n", self.i)
        self.i = len(self.s) if j < 0 else j

    def eol(self):
        self.ws()
        if self.peek() == "#":
            self.skip_comment()
        if self.i < len(self.s):
            if self.s[self.i] != "\n":
                raise self.err("expected end of line")
            self.i += 1

    # keys
    def key_part(self):
        c = self.peek()
        if c == '"':
            return self.basic_string()
        if c == "'":
            return self.literal_string()
        m = _BARE.match(self.s, self.i)
        if not m:
            raise self.err("expected a key")
        self.i = m.end()
        return m.group(0)

    def key(self):
        parts = [self.key_part()]
        self.ws()
        while self.peek() == ".":
            self.i += 1
            self.ws()
            parts.append(self.key_part())
            self.ws()
        return parts

    # strings
    def basic_string(self):
        if self.peek(3) == '"""':
            return self.ml_basic()
        self.i += 1
        out = []
        while True:
            if self.i >= len(self.s) or self.s[self.i] == "\n":
                raise self.err("unterminated string")
            c = self.s[self.i]
            if c == '"':
                self.i += 1
                return "".join(out)
            if c == "\\":
                out.append(self.escape())
            else:
                out.append(c)
                self.i += 1

    def escape(self):
        self.i += 1
        c = self.peek()
        if c in _ESC:
            self.i += 1
            return _ESC[c]
        if c in ("u", "U"):
            n = 4 if c == "u" else 8
            h = self.s[self.i + 1:self.i + 1 + n]
            if len(h) != n or not re.fullmatch(r"[0-9A-Fa-f]+", h):
                raise self.err("bad unicode escape")
            self.i += 1 + n
            return chr(int(h, 16))
        raise self.err(f"bad escape \\{c}")

    def ml_basic(self):
        self.i += 3
        if self.peek() == "\n":
            self.i += 1
        out = []
        while True:
            if self.i >= len(self.s):
                raise self.err("unterminated string")
            if self.peek(3) == '"""':
                self.i += 3
                for _ in range(2):                                 # """" or """"" : quotes before the close
                    if self.peek() != '"':
                        break
                    out.append('"')
                    self.i += 1
                return "".join(out)
            c = self.s[self.i]
            if c == "\\":
                j = self.i + 1
                while j < len(self.s) and self.s[j] in " \t":
                    j += 1
                if j < len(self.s) and self.s[j] == "\n":      # line-ending backslash
                    self.i = j
                    while self.i < len(self.s) and self.s[self.i] in " \t\n":
                        self.i += 1
                    continue
                out.append(self.escape())
            else:
                out.append(c)
                self.i += 1

    def literal_string(self):
        if self.peek(3) == "'''":
            self.i += 3
            if self.peek() == "\n":
                self.i += 1
            j = self.s.find("'''", self.i)
            if j < 0:
                raise self.err("unterminated string")
            while self.s[j + 3:j + 4] == "'":
                j += 1
            v = self.s[self.i:j]
            self.i = j + 3
            return v
        self.i += 1
        j = self.i
        while j < len(self.s) and self.s[j] not in "'\n":
            j += 1
        if j >= len(self.s) or self.s[j] != "'":
            raise self.err("unterminated string")
        v = self.s[self.i:j]
        self.i = j + 1
        return v

    # values
    def value(self):
        c = self.peek()
        if c == '"':
            return self.basic_string()
        if c == "'":
            return self.literal_string()
        if c == "[":
            return self.array()
        if c == "{":
            return self.inline_table()
        for word, v in (("true", True), ("false", False)):
            if self.s.startswith(word, self.i):
                self.i += len(word)
                return v
        for word, v in (("inf", float("inf")), ("+inf", float("inf")), ("-inf", float("-inf")),
                        ("nan", float("nan")), ("+nan", float("nan")), ("-nan", float("nan"))):
            if self.s.startswith(word, self.i):
                self.i += len(word)
                return v
        m = _HEX.match(self.s, self.i)
        if m:
            self.i = m.end()
            t = m.group(0).replace("_", "")
            return int(t[2:], {"x": 16, "o": 8, "b": 2}[t[1]])
        m = _FLOAT.match(self.s, self.i)
        if m and m.group(0) not in ("", "+", "-"):
            t = m.group(0)
            nxt = self.peek_at(m.end())
            if nxt in ("-", ":") or (nxt and nxt.isdigit()):
                raise self.err("dates and times are not supported")
            self.i = m.end()
            t = t.replace("_", "")
            if _INT.fullmatch(m.group(0)):
                return int(t)
            return float(t)
        raise self.err("expected a value")

    def peek_at(self, j):
        return self.s[j:j + 1]

    def array(self):
        self.i += 1
        out = []
        while True:
            self.ws_nl()
            if self.peek() == "]":
                self.i += 1
                return out
            out.append(self.value())
            self.ws_nl()
            c = self.peek()
            if c == ",":
                self.i += 1
            elif c == "]":
                self.i += 1
                return out
            else:
                raise self.err("expected , or ] in array")

    def inline_table(self):
        self.i += 1
        t: dict = {}
        self.ws()
        if self.peek() == "}":
            self.i += 1
            return t
        while True:
            self.ws()
            k = self.key()
            if self.peek() != "=":
                raise self.err("expected =")
            self.i += 1
            self.ws()
            _set(self, t, k, self.value())
            self.ws()
            c = self.peek()
            if c == ",":
                self.i += 1
            elif c == "}":
                self.i += 1
                return t
            else:
                raise self.err("expected , or } in inline table")


def _descend(p: _P, t: dict, parts, last_array=False):
    for k in parts:
        cur = t.get(k)
        if cur is None:
            cur = t[k] = {}
        if isinstance(cur, list):
            if not cur or not isinstance(cur[-1], dict):
                raise p.err(f"{k} is not a table")
            cur = cur[-1]
        elif not isinstance(cur, dict):
            raise p.err(f"{k} is not a table")
        t = cur
    return t


def _set(p: _P, t: dict, parts, v):
    t = _descend(p, t, parts[:-1])
    if parts[-1] in t:
        raise p.err(f"duplicate key {'.'.join(parts)}")
    t[parts[-1]] = v


def _loads(s: str) -> dict:
    p = _P(s)
    root: dict = {}
    cur = root
    while True:
        p.ws_nl()
        if p.i >= len(p.s):
            return root
        if p.peek(2) == "[[":
            p.i += 2
            p.ws()
            parts = p.key()
            if p.peek(2) != "]]":
                raise p.err("expected ]]")
            p.i += 2
            parent = _descend(p, root, parts[:-1])
            arr = parent.setdefault(parts[-1], [])
            if not isinstance(arr, list):
                raise p.err(f"{'.'.join(parts)} is not an array of tables")
            cur = {}
            arr.append(cur)
            p.eol()
        elif p.peek() == "[":
            p.i += 1
            p.ws()
            parts = p.key()
            if p.peek() != "]":
                raise p.err("expected ]")
            p.i += 1
            cur = _descend(p, root, parts)
            p.eol()
        else:
            parts = p.key()
            if p.peek() != "=":
                raise p.err("expected =")
            p.i += 1
            p.ws()
            _set(p, cur, parts, p.value())
            p.eol()


import sys as _sys  # noqa: E402

_SELF = _sys.modules[__name__]
