"""<Mod>.omw2mwse.toml: opt-in list of hard-coded values to expose as settings.

    [mod]                                  # credits for the original (shown in the MCM, log, README)
    title = "Leave The Lights Off"  author = "OwnlyMe"  license = "..."  url = "https://..."

    [mcm]
    page = "Leave The Lights Off"          # MCM page title (default: mod name)
    description = "..."                    # optional page text
    group = "Tunables"                     # optional category label

    [[constant]]                           # a top-level `local NAME = <literal>`
    name = "ANIM_STALE_THRESHOLD"
    file = "scripts/LeaveTheLightsOff/LTLO_g.lua"   # optional when the name is unique
    key = "ANIM_STALE_THRESHOLD"           # optional config key (default: name)
    label = "..."  description = "..."  min = 0.1  max = 5  integer = false

    [[literal]]                            # a literal inside an expression
    key = "DAY_START"
    file = "scripts/LeaveTheLightsOff/LTLO_g.lua"
    line = 396
    context = "clockHour < 7"              # must occur exactly once on that line
    literal = "7"                          # optional when the context holds one literal
    label = "..."  min = 0  max = 24  integer = true

`default` may be given but must equal the original literal (the default is
always the author's value). MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

import tomllib
from pathlib import Path

FIELDS_COMMON = {"key", "file", "label", "description", "min", "max", "integer", "default"}
FIELDS_CONST = FIELDS_COMMON | {"name"}
FIELDS_LIT = FIELDS_COMMON | {"line", "context", "literal"}
FIELDS_MOD = {"name", "title", "author", "license", "url", "version"}


class SidecarError(Exception):
    pass


def load(path: Path) -> dict:
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        raise SidecarError(f"{path}: {e}") from e
    unknown = set(data) - {"mod", "mcm", "constant", "literal"}
    if unknown:
        raise SidecarError(f"{path}: unknown table(s) {sorted(unknown)}")
    bad = set(data.get("mod", {})) - FIELDS_MOD
    if bad:
        raise SidecarError(f"{path}: [mod]: unknown field(s) {sorted(bad)}")
    for i, c in enumerate(data.get("constant", [])):
        if "name" not in c:
            raise SidecarError(f"{path}: constant #{i + 1} needs name")
        bad = set(c) - FIELDS_CONST
        if bad:
            raise SidecarError(f"{path}: constant {c['name']}: unknown field(s) {sorted(bad)}")
    for i, c in enumerate(data.get("literal", [])):
        for k in ("key", "file", "line", "context"):
            if k not in c:
                raise SidecarError(f"{path}: literal #{i + 1} needs {k}")
        bad = set(c) - FIELDS_LIT
        if bad:
            raise SidecarError(f"{path}: literal {c['key']}: unknown field(s) {sorted(bad)}")
    keys = [c.get("key", c.get("name")) for c in data.get("constant", [])] + [c["key"] for c in data.get("literal", [])]
    dup = sorted({k for k in keys if keys.count(k) > 1})
    if dup:
        raise SidecarError(f"{path}: duplicate key(s) {dup}")
    data["_path"] = str(path)
    return data


def find(name: str, *dirs: Path) -> Path | None:
    for d in dirs:
        if d is None:
            continue
        for cand in (Path(d) / f"{name}.omw2mwse.toml", Path(d) / "omw2mwse.toml"):
            if cand.is_file():
                return cand
    return None
