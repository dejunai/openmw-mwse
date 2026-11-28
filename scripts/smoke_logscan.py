#!/usr/bin/env python3
"""Sort and summarise the logs of an omwcompat smoke test run (stdlib only, Python 3.9+).

  scripts/smoke_logscan.py LOG [LOG ...] [--max N]

For each file it says what it is (omwcompat.log, its .prev, MWSE.log, other) and then prints:
  - the smoke test report lines (PASS / FAIL / SKIP) and every "[smoketest cell]" line (fixture census, heal, report),
  - in MWSE.log: errors and Lua tracebacks grouped by the mod that raised them, split into
      ours      (omwcompat, mwsuite/openmw, omwcompat_smoketest, converted mods),
      the cell  (errors that mention a nil region, fog, water or the test cell, and which mod made them),
      other     (everything else, counted, with the five most frequent messages),
  - memory pressure hints (out of memory, bad alloc, failed to load mesh/texture, MGE XE messages).
Personal paths (drive letters, user names) are shortened to "...\\Data Files\\" or "...". Written for omwcompat
by dej (dejunai). MIT.
"""
import argparse
import collections
import re
import sys

OURS = re.compile(r"omwcompat|mwsuite[\\/]+openmw|omwcompat_smoketest|omw2mwse", re.I)
CELL = re.compile(r"region|fog|water|OMWC Smoke Test|omwc_smoke|OMWC_SmokeTest", re.I)
MOD = re.compile(r"(?:mwse[\\/]+mods[\\/]+)([^\\/:\s]+(?:[\\/]+[^\\/:\s]+)?)", re.I)
ERR = re.compile(r"error|attempt to|stack traceback|traceback|bad argument|failed to|exception", re.I)
MEM = re.compile(r"out of memory|bad_alloc|std::bad_alloc|not enough memory|failed to (?:load|allocate|create) (?:mesh|texture|nif|dds)|"
                 r"memory|D3DERR_OUTOFVIDEOMEMORY|OUTOFMEMORY", re.I)
PATH = re.compile(r"[A-Za-z]:[\\/](?:[^\\/\s'\"]+[\\/])*?(Data Files[\\/])", re.I)
USER = re.compile(r"[A-Za-z]:[\\/]Users[\\/][^\\/\s]+", re.I)


def clean(line):
    line = PATH.sub(lambda m: "...\\" + m.group(1), line)
    return USER.sub("...", line).rstrip("\r\n")


def kind(name, lines):
    head = "\n".join(lines[:40])
    if name.lower().endswith(".prev"):
        return "omwcompat.log.prev"
    if any("[smoketest" in l or "[omwcompat" in l for l in lines[:400]) and not any("Morrowind Script Extender" in l for l in lines[:5]):
        return "omwcompat.log"
    if "Morrowind Script Extender" in head or "MWSE" in head or any(l.startswith("Lua") or "[LuaManager" in l for l in lines[:200]):
        return "MWSE.log"
    return "other"


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def blocks(lines):
    """Group each error line with the traceback lines that follow it."""
    out, cur = [], None
    for l in lines:
        if ERR.search(l):
            cur = [l]
            out.append(cur)
        elif cur is not None and (l.startswith("\t") or l.startswith(" ") or "stack traceback" in l or ".lua:" in l) and len(cur) < 25:
            cur.append(l)
        else:
            cur = None
    return out


def mod_of(block):
    for l in block:
        m = MOD.search(l)
        if m:
            return m.group(1).replace("\\", "/").lower()
    return "(unattributed)"


def scan_mwse(lines, mx, w):
    ours, cell, other = [], collections.defaultdict(list), collections.Counter()
    for b in blocks(lines):
        text = "\n".join(b)
        mod = mod_of(b)
        if OURS.search(text):
            ours.append(b)
        elif CELL.search(text):
            cell[mod].append(b)
        else:
            other[(mod, clean(b[0])[:140])] += 1
    w("MWSE.log: %d lines" % len(lines))
    w("  OURS (omwcompat / mwsuite / smoketest): %d block(s)" % len(ours))
    for b in ours[:mx]:
        for l in b[:6]:
            w("    " + clean(l)[:200])
    w("  CAUSED BY THE CELL (region / fog / water / test cell), by mod:")
    if not cell:
        w("    none")
    for mod, bl in sorted(cell.items(), key=lambda kv: -len(kv[1])):
        w("    %-40s %d x  e.g. %s" % (mod, len(bl), clean(bl[0][0])[:150]))
    w("  OTHER (unrelated noise): %d distinct, %d total" % (len(other), sum(other.values())))
    for (mod, msg), n in other.most_common(5):
        w("    %5d x %-30s %s" % (n, mod, msg))
    mem = [clean(l) for l in lines if MEM.search(l)]
    w("  memory pressure hints: %d line(s)" % len(mem))
    for l in mem[:mx]:
        w("    " + l[:200])


def scan_lib(lines, mx, w):
    rep = [l for l in lines if "[smoketest" in l and "[smoketest cell]" not in l]
    cell = [l for l in lines if "[smoketest cell]" in l]
    counts = collections.Counter()
    for l in rep:
        m = re.search(r"\]\s+(PASS|FAIL|SKIP)\b", l)
        if m:
            counts[m.group(1)] += 1
    w("library log: %d lines; smoke checks: %s" % (len(lines), dict(counts) or "no report"))
    for l in rep:
        if re.search(r"\]\s+FAIL\b", l):
            w("    " + clean(l)[:220])
    w("  fixture lines ([smoketest cell]): %d" % len(cell))
    for l in cell[-max(mx, 40):]:
        w("    " + clean(l)[:220])
    bad = [l for l in lines if ERR.search(l) and "[smoketest" not in l]
    w("  other errors/warnings in the library log: %d" % len(bad))
    for l in bad[:mx]:
        w("    " + clean(l)[:220])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--max", type=int, default=12)
    a = ap.parse_args(argv)
    out = []
    w = out.append
    for p in a.logs:
        lines = read(p)
        k = kind(p, lines)
        w("== %s: %s (%d lines)" % (p.replace("\\", "/").rsplit("/", 1)[-1][:20], k, len(lines)))
        if k.startswith("omwcompat"):
            scan_lib(lines, a.max, w)
        elif k == "MWSE.log":
            scan_mwse(lines, a.max, w)
        else:
            mem = [clean(l) for l in lines if MEM.search(l)]
            w("  first line: %s" % (clean(lines[0])[:120] if lines else ""))
            w("  memory pressure hints: %d" % len(mem))
            for l in mem[:a.max]:
                w("    " + l[:200])
        w("")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
