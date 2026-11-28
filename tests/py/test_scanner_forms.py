"""0.2.5 scanner fixes: pcall(require) aliases, members of values (`unlisted`), typed method calls.

Fixture tests/fixtures/scanner-forms is our own code, modeled on common OpenMW Lua patterns."""
from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from omw2mwse import apitypes as AT  # noqa: E402
from omw2mwse.cli import main  # noqa: E402
from omw2mwse.scan import classify, load_manifest, scan_mod  # noqa: E402

MANIFEST = load_manifest()
FORMS = ROOT / "tests" / "fixtures" / "scanner-forms"


def scan_lua(lua: str, kind: str = "GLOBAL"):
    with tempfile.TemporaryDirectory() as t:
        root = Path(t)
        (root / "scripts" / "T").mkdir(parents=True)
        (root / "scripts" / "T" / "s.lua").write_text(lua, encoding="utf-8")
        (root / "T.omwscripts").write_text(f"{kind}: scripts/T/s.lua\n", encoding="utf-8")
        return scan_mod(root, MANIFEST).to_dict()


class FixtureScan(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.r = scan_mod(FORMS, MANIFEST).to_dict()
        cls.sym = {k: v["status"] for k, v in cls.r["symbols"].items()}
        cls.typed = {k: v["status"] for k, v in cls.r["typedMethods"].items()}

    def test_pcall_require_both_forms(self):
        self.assertEqual(self.r["guardedRequires"], ["openmw.interfaces", "openmw.animation", "openmw.util"])
        self.assertEqual(self.sym["openmw.interfaces.Activation.addHandlerForType"], "full")
        self.assertEqual(self.sym["openmw.util.vector3"], "full")
        self.assertEqual(self.sym["openmw.animation.addGlow"], "stub")  # 0.5.0: a quiet no-op, not a blocker
        self.assertNotIn("requires unsupported module openmw.animation", self.r["blockers"])
        self.assertTrue(any("pcall(require" in w for w in self.r["warnings"]))

    def test_multi_assign_and_table_keys(self):
        self.assertEqual(self.sym["openmw.self.cell.name"], "full")          # local p, c = self.position, self.cell
        self.assertNotIn("openmw.self.position.name", self.sym)
        self.assertFalse(any(k.startswith("openmw.types.NPC.") for k in self.sym))  # { type = types.NPC, }

    def test_members_of_values(self):
        self.assertEqual(self.sym["openmw.self.rotation.getYaw"], "full")
        self.assertEqual(self.sym["openmw.self.cell.id.lower"], "full")
        self.assertEqual(self.sym["openmw.self.type.isDead"], "full")
        self.assertEqual(self.sym["openmw.storage.LIFE_TIME.Temporary"], "stub")
        self.assertEqual(self.sym["openmw.self.cell.hasTag"], "unsupported")
        self.assertIn("unsupported API openmw.self.cell.hasTag (1x)", self.r["blockers"])

    def test_unknown_member_is_unlisted_not_full(self):
        self.assertEqual(self.sym["openmw.self.position.nonsense"], "unlisted")
        self.assertEqual(self.r["unlisted"], ["openmw.self.position.nonsense"])
        self.assertFalse(any("nonsense" in b for b in self.r["blockers"]))
        self.assertTrue(any("unlisted API openmw.self.position.nonsense" in w for w in self.r["warnings"]))

    def test_typed_methods(self):
        self.assertEqual(self.typed["Inventory:countOf"], "full")
        self.assertEqual(self.typed["Inventory:getAll"], "partial")
        self.assertEqual(self.typed["Cell:getAll"], "partial")
        self.assertEqual(self.typed["Transform:getAnglesZYX"], "full")
        self.assertEqual(self.typed["Type.createRecordDraft"], "partial")
        self.assertEqual(self.typed["StorageSection:get"], "full")
        self.assertNotIn("unsupported method Inventory:getAll (1x)", self.r["blockers"])  # partial since 0.4.0
        kinds = {p["api"]: p["kind"] for p in self.r["partialApis"]}
        self.assertEqual(kinds["Cell:getAll"], "typedMethod")
        self.assertNotIn("string:lower", self.typed)           # obj.recordId:lower() is plain Lua

    def test_verdict(self):
        self.assertEqual(self.r["verdict"], "blocked")


class SmallForms(unittest.TestCase):
    def test_unknown_receiver_distinctive_only(self):
        r = scan_lua("local function f(c, x)\n  for _, o in ipairs(c:getAll()) do end\n"
                     "  return x:get('k'), x:find('a')\nend\nreturn { eventHandlers = { E = f } }\n")
        self.assertEqual(r["typedMethods"]["?:getAll"]["status"], "partial")
        self.assertNotIn("?:get", r["typedMethods"])
        self.assertEqual(r["verdict"], "ready")

    def test_inventory_find_is_partial_resolve_blocks(self):
        src = ("local types = require('openmw.types')\nlocal self = require('openmw.self')\n"
               "local function f()\n  local inv = types.Actor.inventory(self)\n"
               "  return inv:%s\nend\nreturn { engineHandlers = { onUpdate = f } }\n")
        r = scan_lua(src % "find('gold_001')", kind="NPC")
        self.assertEqual(r["typedMethods"]["Inventory:find"]["status"], "partial")
        self.assertNotEqual(r["verdict"], "blocked")
        r = scan_lua(src % "resolve()", kind="NPC")
        self.assertEqual(r["typedMethods"]["Inventory:resolve"]["status"], "unsupported")
        self.assertEqual(r["verdict"], "blocked")

    def test_no_alias_from_field_target(self):
        r = scan_lua("local core = require('openmw.core')\nlocal t = {}\nt.x = core.sound\n"
                     "return { engineHandlers = { onUpdate = function() return t.x end } }\n")
        self.assertNotIn("openmw.core.sound.x", r["symbols"])

    def test_classify_rules(self):
        self.assertEqual(classify("openmw.self.position.foo", MANIFEST), "unlisted")
        self.assertEqual(classify("openmw.self.rotation.getYaw", MANIFEST), "full")
        self.assertEqual(classify("openmw.self.type.isDead", MANIFEST),
                         classify("openmw.types.Actor.isDead", MANIFEST))

    def test_value_types(self):
        go = AT.game_object_members(MANIFEST)
        self.assertEqual(AT.member_status("Cell", ["getAll"], go), "partial")
        self.assertEqual(AT.member_status("Inventory", ["getAll"], go), "partial")
        self.assertEqual(AT.member_status("Inventory", ["resolve"], go), "unsupported")
        self.assertEqual(AT.member_status("GameObject", ["owner", "recordId"], go), "partial")
        self.assertEqual(AT.member_status("string", ["gsub"], go), "full")
        self.assertEqual(AT.member_status("Vector3", ["nonsense"], go), "unlisted")
        self.assertEqual(AT.member_status("GameObject", ["cell", "name"], go), "full")
        self.assertEqual(AT.returns("openmw.types.Actor.inventory"), "Inventory")


class CorpusStaysReady(unittest.TestCase):
    def test_ready_mods(self):
        names = ["leave-the-lights-off", "no-fires-in-bad-weather", "wildlife-attacks-npcs-too"]
        present = [n for n in names if (ROOT / "corpus" / n).is_dir()]
        if not present:
            self.skipTest("corpus not present (git-ignored)")
        os.environ["OMW2MWSE_OPENMW"] = "none"
        try:
            buf = io.StringIO()
            with redirect_stdout(buf):
                main(["scan", "--corpus", "--json", str(ROOT / "corpus")])
        finally:
            del os.environ["OMW2MWSE_OPENMW"]
        got = {m["name"]: m["verdict"] for m in json.loads(buf.getvalue())}
        for n in present:
            if n in got:
                self.assertEqual(got[n], "ready", n)


if __name__ == "__main__":
    unittest.main()
