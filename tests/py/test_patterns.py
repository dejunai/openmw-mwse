"""Rule-based pattern detection (patterns.py) and the runtime guards it switches on."""
from __future__ import annotations

import io
import json
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from omw2mwse.cli import main  # noqa: E402
from omw2mwse.patterns import RULE_DEDUPE, RULE_ITER, detect  # noqa: E402
from omw2mwse.scan import load_manifest, scan_mod  # noqa: E402

MANIFEST = load_manifest()
FIXTURE = ROOT / "tests" / "fixtures" / "active-collect"
NOFIRES = ROOT / "corpus" / "no-fires-in-bad-weather"


def rules(src: str):
    return [(f.rule, f.line, f.table, f.guarded) for f in detect(src)]


HEAD = "local types = require('openmw.types')\nlocal list = {}\n"
TAIL = "return { engineHandlers = { onObjectActive = onObjectActive } }\n"


class Detect(unittest.TestCase):
    def test_fixture(self):
        src = (FIXTURE / "scripts" / "ActiveCollect" / "global.lua").read_text(encoding="utf-8")
        got = rules(src)
        self.assertIn((RULE_DEDUPE, 30, "tracked", True), got)
        self.assertIn((RULE_ITER, 20, "tracked", True), got)      # table.remove at the next() cursor
        self.assertIn((RULE_ITER, 30, "tracked", True), got)      # append while the cursor walks
        self.assertEqual(len(got), 3)

    def test_plain_handler_name_and_inline_function(self):
        src = HEAD + "local function onObjectActive(o)\n  table.insert(list, o)\nend\n" + TAIL
        self.assertEqual(rules(src), [(RULE_DEDUPE, 4, "list", True)])
        src = HEAD + "return { engineHandlers = { onActorActive = function(a) table.insert(list, a) end } }\n"
        self.assertEqual(rules(src), [(RULE_DEDUPE, 3, "list", True)])

    def test_append_index_form_is_reported_unguarded(self):
        src = HEAD + "local function onObjectActive(o)\n  list[#list + 1] = o\nend\n" + TAIL
        self.assertEqual(rules(src), [(RULE_DEDUPE, 4, "list", False)])

    def test_dotted_table_name(self):
        src = HEAD + "local S = { l = {} }\nlocal function onItemActive(o)\n  table.insert(S.l, o)\nend\n" \
              "return { engineHandlers = { onItemActive = onItemActive } }\n"
        self.assertEqual(rules(src), [(RULE_DEDUPE, 5, "S.l", True)])

    def test_dedupe_checks_suppress_the_rule(self):
        loop = HEAD + ("local function onObjectActive(o)\n  for _, x in ipairs(list) do if x == o then return end end\n"
                       "  table.insert(list, o)\nend\n") + TAIL
        setk = HEAD + "local seen = {}\nlocal function onObjectActive(o)\n  if seen[o.id] then return end\n" \
                      "  seen[o.id] = true\n  table.insert(list, o)\nend\n" + TAIL
        setobj = HEAD + "local seen = {}\nlocal function onObjectActive(o)\n  if seen[o] then return end\n" \
                        "  seen[o] = true\n  table.insert(list, o)\nend\n" + TAIL
        local_list = HEAD + "local function onObjectActive(o)\n  local mine = {}\n  table.insert(mine, o)\nend\n" + TAIL
        other_value = HEAD + "local function onObjectActive(o)\n  table.insert(list, o.recordId)\nend\n" + TAIL
        for src in (loop, setk, setobj, local_list, other_value):
            self.assertEqual([r for r in rules(src) if r[0] == RULE_DEDUPE], [], src)

    def test_record_id_lookup_is_not_a_dedupe(self):
        src = HEAD + "local known = {}\nlocal function onObjectActive(o)\n  if not known[o.recordId] then return end\n" \
                     "  table.insert(list, o)\nend\n" + TAIL
        self.assertEqual(rules(src), [(RULE_DEDUPE, 6, "list", True)])

    def test_not_a_handler(self):
        src = HEAD + "local function collect(o)\n  table.insert(list, o)\nend\nreturn { engineHandlers = { onUpdate = collect } }\n"
        self.assertEqual(rules(src), [])

    def test_loops(self):
        p_remove = "local t = {}\nfor k, v in pairs(t) do\n  if v then table.remove(t, k) end\nend\n"
        i_nil = "local t = {}\nfor i, v in ipairs(t) do\n  t[i] = nil\nend\n"
        p_nil = "local t = {}\nfor k, v in pairs(t) do\n  t[k] = nil\nend\n"
        p_insert = "local t = {}\nfor k, v in pairs(t) do\n  table.insert(t, v)\nend\n"
        next_loop = "local t = {}\nfor k, v in next, t do\n  table.remove(t, k)\nend\n"
        other = "local t, u = {}, {}\nfor k, v in pairs(t) do\n  table.remove(u, 1)\nend\n"
        self.assertEqual(rules(p_remove), [(RULE_ITER, 3, "t", True)])
        self.assertEqual(rules(i_nil), [(RULE_ITER, 3, "t", False)])
        self.assertEqual(rules(p_nil), [])                 # legal in Lua
        self.assertEqual(rules(p_insert), [(RULE_ITER, 3, "t", False)])
        self.assertEqual(rules(next_loop), [(RULE_ITER, 3, "t", True)])
        self.assertEqual(rules(other), [])

    def test_cursor_without_mutation_is_fine(self):
        src = "local t, c = {}, nil\nlocal function onUpdate()\n  local v\n  c, v = next(t, c)\nend\n" \
              "return { engineHandlers = { onUpdate = onUpdate } }\n"
        self.assertEqual(rules(src), [])

    def test_syntax_error_gives_nothing(self):
        self.assertEqual(detect("local s = 'unterminated\n"), [])


def make(root: Path, files: dict, omwscripts: str) -> None:
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    (root / "M.omwscripts").write_text(omwscripts, encoding="utf-8")


class ScanAndConvert(unittest.TestCase):
    def test_scan_guards_and_partials(self):
        s = scan_mod(FIXTURE, MANIFEST)
        self.assertEqual(s.verdict, "ready")
        self.assertEqual(s.guards, {"scripts/ActiveCollect/global.lua": ["activeDedupe", "safeIteration"]})
        pats = {p["api"]: p for p in s.partial_apis if p["kind"] == "pattern"}
        self.assertEqual(sorted(pats), ["pattern:" + RULE_DEDUPE, "pattern:" + RULE_ITER])
        for p in pats.values():
            self.assertEqual(set(p), {"api", "kind", "count", "uses", "missing"})
        self.assertEqual(pats["pattern:" + RULE_DEDUPE]["uses"], [{"file": "scripts/ActiveCollect/global.lua", "line": 30}])
        self.assertEqual(pats["pattern:" + RULE_ITER]["count"], 2)
        self.assertIn("activeDedupe", pats["pattern:" + RULE_DEDUPE]["missing"])
        d = s.to_dict()
        self.assertEqual(d["guards"], s.guards)
        self.assertEqual(len(s.patterns), 3)

    def test_module_finding_guards_the_scripts_that_require_it(self):
        with tempfile.TemporaryDirectory() as t:
            make(Path(t), {
                "scripts/M/g.lua": "local h = require('scripts.M.helper')\nreturn { engineHandlers = { onObjectActive = h.on } }\n",
                "scripts/M/p.lua": "return {}\n",
                "scripts/M/helper.lua": "local t = {}\nlocal M = {}\nfunction M.tick()\n  for k, v in pairs(t) do table.remove(t, k) end\nend\nreturn M\n",
            }, "GLOBAL: scripts/M/g.lua\nPLAYER: scripts/M/p.lua\n")
            s = scan_mod(Path(t), MANIFEST)
            self.assertEqual(s.guards, {"scripts/M/g.lua": ["safeIteration"]})

    def test_convert_json_main_lua_and_report(self):
        with tempfile.TemporaryDirectory() as t:
            dst = Path(t) / "ActiveCollect"
            shutil.copytree(FIXTURE, dst)
            buf = io.StringIO()
            with redirect_stdout(buf):
                main(["--convert-omwscripts", str(dst), "--json"])
            m = json.loads(buf.getvalue())["mods"][0]
            self.assertEqual(m["status"], "ok")
            self.assertEqual(m["guards"], {"scripts/ActiveCollect/global.lua": ["activeDedupe", "safeIteration"]})
            self.assertIn("pattern:" + RULE_DEDUPE, [p["api"] for p in m["partialApis"]])
            mdir = dst / "MWSE" / "mods" / "mwsuite" / "openmw" / "ActiveCollect"
            main_lua = (mdir / "main.lua").read_text(encoding="utf-8")
            self.assertIn('path = "scripts/ActiveCollect/global.lua", guards = { "activeDedupe", "safeIteration" } }', main_lua)
            rep = (mdir / "OMW2MWSE-REPORT.md").read_text(encoding="utf-8")
            self.assertIn("Rule-based workarounds", rep)
            self.assertIn("rule active-collect-dedupe: scripts/ActiveCollect/global.lua:30", rep)
            # the hosted Lua is byte-identical to the source (never edited)
            self.assertEqual((mdir / "omw" / "scripts" / "ActiveCollect" / "global.lua").read_bytes(),
                             (FIXTURE / "scripts" / "ActiveCollect" / "global.lua").read_bytes())

    def test_no_findings_no_guards_line(self):
        with tempfile.TemporaryDirectory() as t:
            make(Path(t), {"scripts/M/g.lua": "return {}\n"}, "GLOBAL: scripts/M/g.lua\n")
            buf = io.StringIO()
            with redirect_stdout(buf):
                main(["--convert-omwscripts", t, "--json"])
            m = json.loads(buf.getvalue())["mods"][0]
            self.assertEqual(m["guards"], {})
            main_lua = next(Path(t).rglob("main.lua")).read_text(encoding="utf-8")
            self.assertNotIn("guards", main_lua)

    def test_opt_out_reports_nothing(self):
        with tempfile.TemporaryDirectory() as t:
            dst = Path(t) / "ActiveCollect"
            shutil.copytree(FIXTURE, dst)
            g = dst / "scripts" / "ActiveCollect" / "global.lua"
            g.write_text("-- mwsuite conversion opt-out\n" + g.read_text(encoding="utf-8"), encoding="utf-8")
            s = scan_mod(dst, MANIFEST)
            self.assertEqual((s.patterns, s.guards), ([], {}))
            self.assertEqual([p for p in s.partial_apis if p["kind"] == "pattern"], [])

    @unittest.skipUnless((NOFIRES / "scripts" / "NFiBW" / "global.lua").is_file(), "corpus/no-fires-in-bad-weather missing")
    def test_no_fires_reference_case(self):
        s = scan_mod(NOFIRES, MANIFEST)
        self.assertEqual(s.guards, {"scripts/NFiBW/global.lua": ["activeDedupe", "safeIteration"]})
        got = {(p["rule"], p["line"]) for p in s.patterns}
        self.assertIn((RULE_DEDUPE, 101), got)
        self.assertIn((RULE_ITER, 49), got)


if __name__ == "__main__":
    unittest.main()
