"""Minimal TES3 plugin reader: record ids and which of them this file introduces."""
from __future__ import annotations

import struct
from dataclasses import dataclass, field
from pathlib import Path

# Object types a plugin with masters commonly uses to *patch* existing records
# (attaching a script, changing a flag). New scripts/globals are never in this set.
OBJECT_TYPES = frozenset({
    "ACTI", "ALCH", "APPA", "ARMO", "BODY", "BOOK", "BSGN", "CELL", "CLAS", "CLOT",
    "CONT", "CREA", "DOOR", "ENCH", "FACT", "INGR", "LAND", "LEVC", "LEVI", "LIGH",
    "LOCK", "LTEX", "MGEF", "MISC", "NPC_", "PGRD", "PROB", "RACE", "REGN", "REPA",
    "SKIL", "SNDG", "SOUN", "SPEL", "STAT", "WEAP", "DIAL", "INFO",
})
# Record types whose NAME/SCHD is introduced by this plugin even when masters exist.
INTRODUCED_TYPES = frozenset({"SCPT", "SSCR", "GLOB"})


@dataclass
class Tes3Record:
    typ: str
    flags: int
    id: str | None
    script: str | None  # SCRI attachment, if any


@dataclass
class Tes3Plugin:
    path: Path
    masters: list[str] = field(default_factory=list)
    records: list[Tes3Record] = field(default_factory=list)
    error: str | None = None

    def ids_of(self, typ: str) -> set[str]:
        typ = typ.upper()
        return {r.id.lower() for r in self.records if r.id and r.typ == typ}

    def introduced_ids(self) -> set[str]:
        """Record ids this plugin *defines*, not merely overrides on a master.

        Always: SCPT, SSCR, GLOB. With no masters, every named record. With masters
        listed but not loaded: an object record (CREA, LIGH, ...) that only attaches
        a script defined in this same plugin is treated as a master override (the
        Wildlife get-fight pattern). Any other named record is treated as introduced.
        """
        own_scripts = self.ids_of("SCPT") | self.ids_of("SSCR")
        out: set[str] = set()
        has_masters = bool(self.masters)
        for r in self.records:
            if not r.id:
                continue
            name = r.id.lower()
            if r.typ in INTRODUCED_TYPES:
                out.add(name)
                continue
            if not has_masters:
                out.add(name)
                continue
            if r.typ in OBJECT_TYPES and r.script and r.script.lower() in own_scripts:
                continue  # vanilla (or other master) object with a hook script
            out.add(name)
        return out


def _zstr(b: bytes) -> str:
    return b.split(b"\x00", 1)[0].decode("latin-1", "replace").strip()


def _records(data: bytes):
    i, n = 0, len(data)
    while i + 16 <= n:
        typ = data[i:i + 4]
        if typ == b"\x00\x00\x00\x00":
            break
        size = struct.unpack_from("<I", data, i + 4)[0]
        flags = struct.unpack_from("<I", data, i + 12)[0]
        if size < 0 or i + 16 + size > n:
            break
        yield typ.decode("latin-1", "replace"), flags, data[i + 16:i + 16 + size]
        i += 16 + size


def _subrecords(body: bytes):
    i = 0
    while i + 8 <= len(body):
        typ = body[i:i + 4].decode("latin-1", "replace")
        size = struct.unpack_from("<I", body, i + 4)[0]
        if size < 0 or i + 8 + size > len(body):
            break
        yield typ, body[i + 8:i + 8 + size]
        i += 8 + size


def parse_plugin(path: Path) -> Tes3Plugin:
    p = Path(path)
    out = Tes3Plugin(path=p)
    try:
        data = p.read_bytes()
    except OSError as e:
        out.error = str(e)
        return out
    if not data.startswith(b"TES3"):
        out.error = "not a TES3 plugin"
        return out
    recs = list(_records(data))
    if not recs or recs[0][0] != "TES3":
        out.error = "missing TES3 header"
        return out
    for st, sb in _subrecords(recs[0][2]):
        if st == "MAST":
            out.masters.append(_zstr(sb))
    for typ, flags, body in recs[1:]:
        rec_id, scri = None, None
        for st, sb in _subrecords(body):
            if st == "SCHD" and typ == "SCPT":
                rec_id = _zstr(sb[:32])
            elif st == "NAME" and rec_id is None:
                rec_id = _zstr(sb)
            elif st == "SCRI":
                scri = _zstr(sb)
        out.records.append(Tes3Record(typ, flags, rec_id, scri))
    return out


def build_plugin(records: list[tuple[str, list[tuple[str, bytes]]]], *,
                 masters: list[str] | None = None, author: str = "", description: str = "") -> bytes:
    """Build a minimal TES3 plugin (for tests). records: [(TYPE, [(SUB, payload), ...]), ...]."""

    def rec(typ: str, subs: list[tuple[str, bytes]]) -> bytes:
        body = b"".join(st.encode("ascii") + struct.pack("<I", len(sb)) + sb for st, sb in subs)
        return typ.encode("ascii") + struct.pack("<III", len(body), 0, 0) + body

    def z(s: str, n: int | None = None) -> bytes:
        b = s.encode("latin-1") + b"\x00"
        return b if n is None else (b + b"\x00" * n)[:n]

    hed = struct.pack("<IfI", 1, 1.3, 0) + z(author, 32) + z(description, 256) + struct.pack("<I", 0)
    header: list[tuple[str, bytes]] = [("HEDR", hed)]
    for m in masters or []:
        header.append(("MAST", z(m)))
        header.append(("DATA", struct.pack("<Q", 0)))
    chunks = [rec("TES3", header)]
    for typ, subs in records:
        chunks.append(rec(typ, subs))
    return b"".join(chunks)


def scpt(name: str) -> tuple[str, list[tuple[str, bytes]]]:
    # SCHD: 32-byte name + 4 counts (shorts, longs, floats, data size)
    schd = (name.encode("latin-1") + b"\x00" * 32)[:32] + struct.pack("<IIII", 0, 0, 0, 0)
    return "SCPT", [("SCHD", schd)]


def named(typ: str, name: str, extra: list[tuple[str, bytes]] | None = None) -> tuple[str, list[tuple[str, bytes]]]:
    return typ, [("NAME", name.encode("latin-1") + b"\x00")] + list(extra or [])
