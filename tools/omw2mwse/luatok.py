"""Small Lua 5.1/LuaJIT tokenizer (enough for static API scanning)."""
from __future__ import annotations

import re
from dataclasses import dataclass

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if",
    "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}

_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_NUM = re.compile(r"0[xX][0-9a-fA-F]*(\.[0-9a-fA-F]*)?([pP][+-]?\d+)?|(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?")
_SYMS = ["...", "..", "==", "~=", "<=", ">=", "::", "//", "<<", ">>"]


@dataclass
class Token:
    kind: str   # name, keyword, string, number, symbol
    value: str
    line: int


class LuaSyntaxError(Exception):
    pass


def _long_bracket(src: str, i: int):
    """If src[i] starts a long bracket [==[ return (level, end_of_open) else None."""
    m = re.match(r"\[(=*)\[", src[i:])
    if not m:
        return None
    return len(m.group(1)), i + m.end()


def tokenize(src: str) -> list[Token]:
    toks: list[Token] = []
    i, n, line = 0, len(src), 1
    if src.startswith("#!"):
        while i < n and src[i] != "\n":
            i += 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c in " \t\r\f\v":
            i += 1
            continue
        if src.startswith("--", i):
            lb = _long_bracket(src, i + 2)
            if lb:
                level, j = lb
                close = "]" + "=" * level + "]"
                k = src.find(close, j)
                if k < 0:
                    raise LuaSyntaxError(f"unfinished long comment at line {line}")
                line += src.count("\n", i, k)
                i = k + len(close)
            else:
                while i < n and src[i] != "\n":
                    i += 1
            continue
        if c == "[":
            lb = _long_bracket(src, i)
            if lb:
                level, j = lb
                close = "]" + "=" * level + "]"
                k = src.find(close, j)
                if k < 0:
                    raise LuaSyntaxError(f"unfinished long string at line {line}")
                body = src[j:k]
                if body.startswith("\n"):
                    body = body[1:]
                toks.append(Token("string", body, line))
                line += src.count("\n", i, k)
                i = k + len(close)
                continue
        if c in "\"'":
            j = i + 1
            buf = []
            while True:
                if j >= n:
                    raise LuaSyntaxError(f"unfinished string at line {line}")
                d = src[j]
                if d == "\\":
                    e = src[j + 1] if j + 1 < n else ""
                    mapping = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "a": "\a",
                               "b": "\b", "f": "\f", "v": "\v", "\n": "\n", "0": "\0"}
                    if e in mapping and e != "0":
                        buf.append(mapping[e])
                        if e == "\n":
                            line += 1
                        j += 2
                    elif e.isdigit():
                        m = re.match(r"\d{1,3}", src[j + 1:])
                        buf.append(chr(int(m.group(0)) % 256))
                        j += 1 + m.end()
                    elif e == "x":
                        buf.append(chr(int(src[j + 2:j + 4], 16)))
                        j += 4
                    elif e == "z":
                        j += 2
                        while j < n and src[j] in " \t\r\n":
                            if src[j] == "\n":
                                line += 1
                            j += 1
                    else:
                        buf.append(e)
                        j += 2
                    continue
                if d == c:
                    break
                if d == "\n":
                    raise LuaSyntaxError(f"unfinished string at line {line}")
                buf.append(d)
                j += 1
            toks.append(Token("string", "".join(buf), line))
            i = j + 1
            continue
        if c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit()):
            m = _NUM.match(src, i)
            toks.append(Token("number", m.group(0), line))
            i = m.end()
            continue
        m = _NAME.match(src, i)
        if m:
            w = m.group(0)
            toks.append(Token("keyword" if w in KEYWORDS else "name", w, line))
            i = m.end()
            continue
        for s in _SYMS:
            if src.startswith(s, i):
                toks.append(Token("symbol", s, line))
                i += len(s)
                break
        else:
            toks.append(Token("symbol", c, line))
            i += 1
    return toks
