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

import re
from pathlib import Path

REASON_CODE = "author-opt-out"
# What every user-facing output says (CLI, --json reason and alerts, scan, package errors).
# Deliberately no file, line or matched text: where the marker sits is not shown.
REASON_MESSAGE = ("The original mod author has asked that this mod be excluded from mwsuite's conversion "
                  "utility; contact the original mod author for details.")
PHRASE = "mwsuite conversion opt-out"
PHRASE_RE = re.compile(r"mwsuite\s+conversion\s+opt\s*-?\s*out", re.IGNORECASE)
_LONG_OPEN = re.compile(r"--\[(=*)\[")


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


def opt_out_reason() -> dict:
    """The reason object for an opted-out mod: {code, message}, nothing else."""
    return {"code": REASON_CODE, "message": REASON_MESSAGE}


def find_opt_out(root: Path) -> dict | None:
    """opt_out_reason() if any .lua file under root opts out in its header, else None.

    The file and line are intentionally not returned (see REASON_MESSAGE)."""
    from .scan import walk_package  # same package boundaries as the build
    root = Path(root)
    for dp, _dns, fns in walk_package(root):
        for fn in fns:
            if not fn.lower().endswith(".lua"):
                continue
            p = Path(dp) / fn
            try:
                text = p.read_bytes().decode("utf-8", errors="replace")
            except OSError:
                continue
            if header_opt_out_line(text) is not None:
                return opt_out_reason()
    return None
