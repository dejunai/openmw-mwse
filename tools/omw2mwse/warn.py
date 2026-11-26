"""Developer-only warning shown before hard-coded values become settings.

Printed to the developer's terminal (stderr) by `package`/`convert`; it is never
part of the packaged mod and players never see it. MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

import sys

RULE = "=" * 78

GENERAL = [
    "The mod author chose these values; other code may silently depend on them",
    "(comparisons, loop bounds, timers, table sizes, record ids, saved data).",
    "Values read at load time (top-level code, table constructors, upvalues) change",
    "only when the scripts reload: omwcompat reloads the mod's scripts when its MCM",
    "closes after such a change, and on every save load.",
    "The MCM accepts only the type and min/max given here; anything outside the",
    "author's tested range is untested behaviour.",
    "The rewritten Lua is no longer byte-identical to the author's; the verbatim",
    "original is kept next to it under MWSE/omw/<Mod>/_original/.",
]


class Refused(Exception):
    pass


def render(mod: str, convs, mode: str, sidecar: str | None) -> str:
    out = [RULE, "omw2mwse DEVELOPER WARNING: hard-coded values will become MCM settings",
           "(shown to whoever runs omw2mwse; never shown to players in game)", RULE,
           f"Mod: {mod}    mode: {mode}    picks: {'sidecar ' + sidecar if sidecar else 'automatic (no sidecar)'}", ""]
    for i, c in enumerate(convs, 1):
        out.append(f"{i:2}. {c.key}  {c.file}:{c.line}  [{c.kind}, {c.type}, default {c.literal}]")
        out.append(f"      before: {c.before}")
        out.append(f"      after : {c.after}")
        out.append(f"      applies: {c.apply_note}")
        for r in c.risks:
            out.append(f"      risk: {r}")
        if c.origin.startswith("auto"):
            out.append(f"      chosen because: {c.origin[5:]}")
        out.append("")
    out.append("Why this can break a mod:")
    out.extend("  " + line for line in GENERAL)
    out.append(RULE)
    return "\n".join(out)


def confirm(text: str, convs, accept: bool, interactive: bool | None = None, inp=None, err=None) -> list:
    """Return the accepted conversions, or raise Refused."""
    err = err or sys.stderr
    inp = inp or sys.stdin
    print(text, file=err)
    if accept:
        print(f"Accepted {len(convs)} conversion(s) via --accept-hardcode-conversions.", file=err)
        return list(convs)
    if interactive is None:
        interactive = bool(getattr(inp, "isatty", lambda: False)()) and bool(getattr(err, "isatty", lambda: False)())
    if not interactive:
        raise Refused("hard-coded conversions need confirmation: run interactively, or pass "
                      "--accept-hardcode-conversions after reviewing the warning above")
    err.write(f"Convert these {len(convs)} value(s)? [a]ll / [r]eview each / [N]o: ")
    err.flush()
    ans = (inp.readline() or "").strip().lower()
    if ans in ("a", "all", "y", "yes"):
        return list(convs)
    if ans in ("r", "review"):
        keep = []
        for c in convs:
            err.write(f"  convert {c.key} ({c.file}:{c.line})? [y/N]: ")
            err.flush()
            if (inp.readline() or "").strip().lower() in ("y", "yes"):
                keep.append(c)
        if not keep:
            raise Refused("no conversions accepted")
        return keep
    raise Refused("declined by the developer")
