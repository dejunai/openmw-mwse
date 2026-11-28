"""omwcompat_smoketest: the dev-only fixture plugin's JSON source. It is an interior that behaves like an
exterior, carries only what the MWSE mod needs, matches the ids the Lua side uses, and (when tes3conv is
available) builds reproducibly. stdlib unittest; Python 3.9+. Written for omwcompat by dej (dejunai)."""
import importlib.util
import json
import os
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
JSON_PATH = ROOT / "smoketest" / "esp" / "omwc_smoketest.esp.json"
LUA_DIR = ROOT / "smoketest" / "MWSE" / "mods" / "mwsuite" / "openmw" / "omwcompat_smoketest"


def load_builder():
    spec = importlib.util.spec_from_file_location("build_smoketest_esp", ROOT / "scripts" / "build-smoketest-esp.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class SmokeEspJson(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw = JSON_PATH.read_bytes()
        cls.raw = raw
        cls.data = json.loads(raw.decode("utf-8"))
        cls.by_id = {r["id"].lower(): r for r in cls.data if "id" in r}
        cls.lua = (LUA_DIR / "fixtures.lua").read_text(encoding="utf-8")

    def test_file_is_utf8_lf_without_bom(self):
        self.assertFalse(self.raw.startswith(b"\xef\xbb\xbf"))
        self.assertNotIn(b"\r", self.raw)

    def test_header(self):
        h = self.data[0]
        self.assertEqual(h["type"], "Header")
        self.assertEqual(h["file_type"], "Esp")
        self.assertEqual([m[0] for m in h["masters"]], ["Morrowind.esm"])
        self.assertEqual(h["num_objects"], len(self.data) - 1)
        self.assertIn("DEV ONLY", h["description"])

    def test_cell_is_an_interior_that_behaves_like_an_exterior(self):
        cells = [r for r in self.data if r["type"] == "Cell"]
        self.assertEqual(len(cells), 1)
        c = cells[0]
        flags = {f.strip() for f in c["data"]["flags"].split("|")}
        self.assertEqual(flags, {"IS_INTERIOR", "BEHAVES_LIKE_EXTERIOR"})  # weather and the sun work, no landscape needed
        self.assertEqual(c["name"], "OMWC Smoke Test")
        self.assertIn('F.CELL = "OMWC Smoke Test"', self.lua)

    def test_cell_references_resolve_and_only_the_plugin_ones_are_placed(self):
        c = [r for r in self.data if r["type"] == "Cell"][0]
        idx = [r["refr_index"] for r in c["references"]]
        self.assertEqual(len(idx), len(set(idx)))
        for r in c["references"]:
            self.assertIn(r["id"].lower(), self.by_id, r["id"])
            self.assertEqual(r["mast_index"], 0)
        placed = {r["id"] for r in c["references"]}
        self.assertEqual(placed, {"omwc_smoke_floor", "omwc_smoke_exit", "omwc_lever_time_hour", "omwc_lever_time_preset",
                                  "omwc_lever_wx_next", "omwc_lever_wx_prev", "omwc_lever_respawn"})

    def test_lua_fixture_ids_exist(self):
        ids = re.findall(r'\{ id = "([^"]+)", x = ', self.lua)
        self.assertEqual(len(ids), 10)
        for i in ids:
            if i == "rat":
                continue   # a vanilla creature (Wildlife Attacks NPCs Too lists it by id)
            self.assertIn(i, self.by_id, i)

    def test_lua_lever_ids_exist_as_activators(self):
        ids = re.findall(r"(omwc_lever_[a-z_]+) = ", self.lua) + re.findall(r'F\.EXIT_ID = "([^"]+)"', self.lua)
        self.assertEqual(len(ids), 6)
        for i in ids:
            self.assertEqual(self.by_id[i]["type"], "Activator", i)

    def test_conversion_light_ids_match_what_ltlo_and_nfibw_whitelist(self):
        for i in ("omwc_smoke_lantern_de", "omwc_smoke_lantern_paper", "omwc_smoke_streetlight"):
            self.assertTrue(any(p in i for p in ("lantern", "streetlight")), i)
        for i in ("omwc_smoke_torch", "omwc_smoke_firepit"):
            self.assertTrue(any(p in i for p in ("torch", "firepit")), i)
        for i in ("omwc_smoke_lantern_de", "omwc_smoke_lantern_paper", "omwc_smoke_streetlight", "omwc_smoke_torch", "omwc_smoke_firepit"):
            self.assertEqual(self.by_id[i]["type"], "Light")

    def test_robe_and_shield_have_the_right_slots(self):
        self.assertEqual(self.by_id["omwc_smoke_robe"]["data"]["clothing_type"], "Robe")
        self.assertEqual(self.by_id["omwc_smoke_shield"]["data"]["armor_type"], "Shield")

    def test_the_plugin_stays_tiny(self):
        self.assertLessEqual(len(self.data), 40)


class SmokeEspBuild(unittest.TestCase):
    def test_reproducible_build_when_tes3conv_is_available(self):
        b = load_builder()
        exe = b.find_tes3conv(None, None)
        if not exe:
            self.skipTest("tes3conv not found (set TES3CONV or CONFLICT_TOOLS)")
        with tempfile.TemporaryDirectory() as td:
            self.assertEqual(b.main(["--out", td, "--tes3conv", exe, "--check"]), 0)
            esp = Path(td) / b.ESP_NAME
            self.assertTrue(esp.is_file())
            self.assertEqual(esp.read_bytes()[:4], b"TES3")


if __name__ == "__main__":
    unittest.main()
