#!/usr/bin/env python3
"""Write the Known mods table in docs/GAPS.md from docs/survey/mods.csv (dej (dejunai)).

  python3 scripts/survey_report.py --gaps-table [docs/survey/mods.csv] [docs/GAPS.md]
  python3 scripts/survey_gaps.py --gaps-table [docs/survey/mods.csv] [docs/GAPS.md]
"""
import csv
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAPS_BEGIN = "<!-- known-mods-survey-2026-11:begin -->"
GAPS_END = "<!-- known-mods-survey-2026-11:end -->"

# Short names for the ranked gap families in docs/SURVEY-2026-11.md (same order).
RANKED_SHORT = [
    ("ui layouts (openmw.ui widgets, I.MWUI templates, openmw_aux.ui)", "UI layouts"),
    ("I.UI (modes, HUD visibility)", "I.UI"),
    ("magic (core.magic records/enums, Actor spells/activeSpells/activeEffects/selected spell)", "magic"),
    ("script kind MENU (not hosted)", "MENU"),
    ("input (triggers, controller buttons, action handlers)", "input"),
    ("camera (openmw.camera, I.Camera)", "camera"),
    ("skills / stats records (core.stats Skill+Attribute records, NPC races/classes, I.SkillProgression)", "skills / stats"),
    ("animation (openmw.animation, I.AnimationController)", "animation"),
    ("self.controls (movement writes)", "self.controls"),
    ("content / markup / debug modules", "content / markup / debug"),
    ("I.Combat (onHit handlers)", "I.Combat"),
    ("api openmw.types.Item.itemData", "Item.itemData"),
    ("engine handler onControllerButtonPress", "onControllerButtonPress"),
    ("engine handler onInputAction", "onInputAction"),
    ("api openmw.self.cell.hasTag", "self.cell.hasTag"),
    ("engine handler onMouseWheel", "onMouseWheel"),
    ("api openmw.types.Actor.isSwimming", "Actor.isSwimming"),
    ("api openmw.interfaces.ItemUsage.addHandlerForType", "ItemUsage.addHandlerForType"),
    ("other: unsupported GameObject:getBoundingBox", "GameObject:getBoundingBox"),
    ("engine handler onTeleported", "onTeleported"),
]
SHORT_FAMILY = dict(RANKED_SHORT)
SHORT_FAMILY.update({
    "openmw.menu / menu events": "openmw.menu",
    "postprocessing": "postprocessing",
    "script kind LOAD (not hosted)": "LOAD",
})
_RANK_INDEX = {short: i for i, (_long, short) in enumerate(RANKED_SHORT)}


def short_family(name):
    """Short name matching the ranked gap list, or a compact form of any other family."""
    if name in SHORT_FAMILY:
        return SHORT_FAMILY[name]
    if name.startswith("api openmw."):
        return name[len("api openmw."):]
    if name.startswith("engine handler "):
        return name[len("engine handler "):]
    if name.startswith("script kind "):
        return name.split()[2]
    if name.startswith("module "):
        return name[len("module "):]
    m = re.match(r"other: (.+): (\S+) is only available to (\w+) scripts", name)
    if m:
        return "scope %s (%s only)" % (m.group(2), m.group(3))
    if name.startswith("other: unsupported "):
        return name[len("other: unsupported "):].replace("method ", "", 1)
    if name.startswith("other: script flag "):
        rest = name[len("other: script flag "):]
        flags = rest.split(" not hosted", 1)[0]
        return "flag " + flags.replace(" ", "+")
    if name.startswith("other: "):
        return name[len("other: "):]
    return name


def _md_cell(text):
    return text.replace("\\", "\\\\").replace("|", "\\|").replace("\n", " ").replace("\r", "")


def _source_of(url):
    if "nexusmods.com" in url:
        return "Nexus"
    if "github.com" in url:
        return "GitHub"
    if "gitlab.com" in url:
        return "GitLab"
    return "other"


def _families(row):
    raw = row.get("gap_families") or ""
    return [f for f in raw.split(" ; ") if f]


def _sorted_short_families(fams):
    shorts = [short_family(f) for f in fams]
    shorts.sort(key=lambda s: (_RANK_INDEX.get(s, len(_RANK_INDEX)), s.lower()))
    return shorts


def _note(row, fams):
    notes = []
    if row["verdict"] == "blocked":
        n = len(fams)
        if n == 1:
            notes.append("one family away")
        elif n == 2:
            notes.append("two families away")
    if re.search(r" \[.+\]$", row["mod"]):
        notes.append("needed --source (several source folders)")
    return "; ".join(notes)


def gaps_table_markdown(rows):
    """Markdown for the Known mods section, from counted rows of docs/survey/mods.csv."""
    ready = sum(1 for r in rows if r["verdict"] == "ready")
    blocked = sum(1 for r in rows if r["verdict"] == "blocked")
    rows = sorted(
        rows,
        key=lambda r: (0 if r["verdict"] == "ready" else 1, len(_families(r)), r["mod"].lower()),
    )
    L = []
    A = L.append
    A("## Known mods (survey 2026-11)")
    A("")
    A(
        "Dry-run of omw2mwse 0.3.2 / omwcompat 0.5.0 on 27 Nov 2026 (re-run after the 0.5.0 manifest sync). Full write-up: "
        "[SURVEY-2026-11.md](SURVEY-2026-11.md). %d ready, %d blocked (%d counted). "
        "This table is generated from [survey/mods.csv](survey/mods.csv) by "
        "`python3 scripts/survey_report.py --gaps-table`. Do not edit it by hand."
        % (ready, blocked, len(rows))
    )
    A("")
    A("Gap families use the short names from the ranked list in the survey (then any other family, alphabetically):")
    A("")
    A("| # | Short name | Ranked gap family |")
    A("|---|---|---|")
    for i, (long_name, short) in enumerate(RANKED_SHORT, 1):
        A("| %d | %s | %s |" % (i, _md_cell(short), _md_cell(long_name)))
    A("")
    A(
        'Notes: "one family away" means filling that one gap would turn the mod ready. '
        '"needed --source (several source folders)" is the exit-2 case: the repo holds '
        "more than one copy, and the converter was rerun with `--source`."
    )
    A("")
    A("| Mod | Source | Verdict | Blocking gap families | Note |")
    A("|---|---|---|---|---|")
    for r in rows:
        fams = _families(r)
        name = r["mod"]
        url = r["source_url"]
        if url:
            mod = "[%s](%s)" % (_md_cell(name).replace("]", "\\]"), url)
        else:
            mod = _md_cell(name)
        gaps = ", ".join(_md_cell(s) for s in _sorted_short_families(fams)) if fams else ""
        A("| %s | %s | %s | %s | %s |" % (
            mod, _source_of(url), r["verdict"], gaps, _md_cell(_note(r, fams)),
        ))
    A("")
    return "\n".join(L), ready, blocked, len(rows)


def write_gaps_table(mods_csv, gaps_md):
    """Replace (or append) the Known mods section in GAPS.md from mods.csv.

    Returns (ready, blocked, total).
    """
    mods_csv = Path(mods_csv)
    gaps_md = Path(gaps_md)
    rows = [r for r in csv.DictReader(mods_csv.open(encoding="utf-8")) if r.get("counted") == "yes"]
    body, ready, blocked, total = gaps_table_markdown(rows)
    section = "%s\n%s\n%s\n" % (GAPS_BEGIN, body, GAPS_END)
    text = gaps_md.read_text(encoding="utf-8") if gaps_md.exists() else ""
    if GAPS_BEGIN in text and GAPS_END in text:
        pre = text.split(GAPS_BEGIN, 1)[0]
        post = text.split(GAPS_END, 1)[1]
        new = pre.rstrip() + "\n\n" + section
        if post.strip():
            new = new + post.lstrip("\n")
    else:
        new = (text.rstrip() + "\n\n" if text.strip() else "") + section
    if not new.endswith("\n"):
        new += "\n"
    gaps_md.write_text(new, encoding="utf-8")
    return ready, blocked, total


def maybe_run_gaps_table_only(argv):
    """If argv starts with --gaps-table, write the table and return True."""
    if not argv or argv[0] != "--gaps-table":
        return False
    mods = Path(argv[1]) if len(argv) > 1 else ROOT / "docs/survey/mods.csv"
    gaps = Path(argv[2]) if len(argv) > 2 else ROOT / "docs/GAPS.md"
    ready, blocked, total = write_gaps_table(mods, gaps)
    print("wrote %d rows (%d ready, %d blocked) to %s" % (total, ready, blocked, gaps))
    return True


if __name__ == "__main__":
    argv = sys.argv[1:]
    if not argv:
        argv = ["--gaps-table"]
    if not maybe_run_gaps_table_only(argv):
        sys.stderr.write("usage: survey_gaps.py --gaps-table [mods.csv] [GAPS.md]\n")
        sys.exit(64)
