"""Where omw2mwse may work: never in a Data Files folder or a game install.

Dej's rule (0.3.1): the converter runs on a *staged* mod folder (a Vortex staging mod folder,
called from tidy) and writes all its output, including the omwcompat runtime, back into that
folder. Data Files is touched only by Vortex's final deploy. So every folder the converter
writes to, and every folder it reads mod content from, is checked here first.

A path is protected when it, or any folder above it:
  * is named "Data Files" (case-insensitive) or
  * holds Morrowind.exe or Morrowind.esm (the game folder, or a Data Files folder), or holds
    Data Files/Morrowind.esm.
The check is done on the resolved path (symlinks and junctions followed). Hardlinks cannot be
seen from here; every write is a temp file + os.replace, which replaces a hardlink instead of
writing through it, so a staged file that Vortex hardlinked into Data Files is never changed
there.
MIT, Copyright (c) 2026 dej (dejunai).
"""
from __future__ import annotations

from pathlib import Path

from .build import BuildError

GAME_MARKERS = ("morrowind.exe", "morrowind.esm")
DATA_FILES = "data files"


class TargetRefused(BuildError):
    """The folder is a Data Files folder or a game install (or inside one)."""

    def __init__(self, path, why: str):
        self.path = str(path)
        self.why = why
        super().__init__(f"refusing {path}: {why}. omw2mwse works only inside a staged mod folder "
                         "(for example a Vortex staging mod folder), never in Data Files or the game install")


def _names(folder: Path) -> set:
    try:
        return {c.name.lower() for c in folder.iterdir()}
    except OSError:
        return set()


def protected_reason(path) -> str | None:
    """Why `path` may not be used as a read or write location, or None when it is fine."""
    try:
        p = Path(path).resolve()
    except (OSError, RuntimeError):
        p = Path(path).absolute()
    for cur in [p] + list(p.parents):
        if cur.name.lower() == DATA_FILES:
            return f"{cur} is a Data Files folder"
        # only existing folders are listed; a not-yet-created output folder has nothing to list
        names = _names(cur) if cur.is_dir() else set()
        for m in GAME_MARKERS:
            if m in names:
                return f"{cur} holds {m} (a game install or Data Files folder)"
        if DATA_FILES in names:
            for c in cur.iterdir():
                if c.name.lower() == DATA_FILES and "morrowind.esm" in _names(c):
                    return f"{cur} holds a Data Files folder with Morrowind.esm (a game install)"
    return None


def refuse_protected(path, what: str = "folder") -> None:
    why = protected_reason(path)
    if why:
        raise TargetRefused(path, f"{what} is not allowed: {why}")
