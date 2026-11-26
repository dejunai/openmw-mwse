"""Author opt-out: a mod whose Lua header says "mwsuite conversion opt-out" is never converted.

The header is the leading comment block of a .lua file, before the first line of code.
Blank lines, a UTF-8 BOM and a `#!` first line are allowed in it. Both `--` line comments
and `--[[ ... ]]` / `--[==[ ... ]==]` block comments count. Matching is case-insensitive
and tolerant of whitespace ("MWSuite  Conversion Opt - Out" matches). The phrase after
the first line of code does not count. Every .lua file in the package is checked, whether
or not .omwscripts declares it.
MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

import os
import re
from pathlib import Path

REASON_CODE = "author-opt-out"
PHRASE = "mwsuite conversion opt-out"
PHRASE_RE = re.compile(r"mwsuite\s+conversion\s+opt\s*-?\s*out", re.IGNORECASE)
_LONG_OPEN = re.compile(r"--\[(=*)\[")
SKIP_DIRS = {".git", "__pycache__"}


def header_opt_out_line(text: str) -> int | None:
    """1-based line of the opt-out phrase in the header comment block, or None."""
    if text.startswith("\ufeff"):
        text = text[1:]
    i, n, line = 0, len(text), 1
    if text.startswith("#!"):
        j = text.find("\n")
        if j < 0:
            return None
        i, line = j + 1, 2
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c in " \t\r\f\v":
            i += 1
            continue
        if not text.startswith("--", i):
            return None  # first line of code: the header has ended
        m = _LONG_OPEN.match(text, i)
        if m:
            close = "]" + m.group(1) + "]"
            end = text.find(close, m.end())
            body_end = n if end < 0 else end
            body = text[m.end():body_end]
            hit = PHRASE_RE.search(body)
            if hit:
                return line + text.count("\n", i, m.end() + hit.start())
            line += text.count("\n", i, body_end)
            i = n if end < 0 else end + len(close)
            continue
        j = text.find("\n", i)
        j = n if j < 0 else j
        if PHRASE_RE.search(text, i, j):
            return line
        i = j
    return None


def find_opt_out(root: Path) -> dict | None:
    """First opted-out .lua file under root (sorted walk), as a reason dict, or None."""
    root = Path(root)
    for dp, dns, fns in os.walk(root):
        dns[:] = sorted(d for d in dns if d not in SKIP_DIRS)
        for fn in sorted(fns):
            if not fn.lower().endswith(".lua"):
                continue
            p = Path(dp) / fn
            try:
                text = p.read_bytes().decode("utf-8", errors="replace")
            except OSError:
                continue
            ln = header_opt_out_line(text)
            if ln is not None:
                rel = p.relative_to(root).as_posix()
                return {"code": REASON_CODE, "file": rel, "line": ln,
                        "message": f"the mod author opted out of mwsuite conversion ({rel}:{ln}); not converted"}
    return None
