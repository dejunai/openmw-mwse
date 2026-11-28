"""omwcompat_smoketest: the dev-only fixture plugin's JSON source. It is an interior that behaves like an
exterior, carries only what the MWSE mod needs, matches the ids the Lua side uses, and (when tes3conv is
available) builds reproducibly. stdlib unittest; Python 3.9+. Written for omwcompat by dej (dejunai)."""
import copy
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


# Names the Construction Set truncated (FNAM is 32 bytes including NUL).
OLD_OVERLONG_FNAM = {
    "omwc_lever_respawn": "Smoke test: respawn the fixtures",
    "omwc_lever_time_preset": "Smoke test: time to next 06:00 / 12:00 / 18:00 / 00:00",
    "omwc_smoke_exit": "Smoke test: back to where you were",
}


class SmokeEspLimits(unittest.TestCase):
    """Fixed-size TES3 fields must fit the Construction Set buffers or the build fails."""

    def test_source_fields_fit(self):
        b = load_builder()
        self.assertEqual(b.validate(json.loads(JSON_PATH.read_text(encoding="utf-8"))), [])

    def test_old_overlong_activator_names_are_rejected(self):
        b = load_builder()
        recs = json.loads(JSON_PATH.read_text(encoding="utf-8"))
        by_id = {r["id"]: r for r in recs if "id" in r}
        for i, name in OLD_OVERLONG_FNAM.items():
            by_id[i]["name"] = name
        msgs = b.validate(recs)
        self.assertEqual(len(msgs), 3, msgs)
        for i in OLD_OVERLONG_FNAM:
            self.assertTrue(any(i in m and "FNAM" in m for m in msgs), (i, msgs))

    def test_validator_rejects_fixed_size_overflows(self):
        b = load_builder()
        src = json.loads(JSON_PATH.read_text(encoding="utf-8"))

        recs = copy.deepcopy(src)
        act = next(r for r in recs if r.get("id") == "omwc_lever_respawn")
        act["name"] = "x" * 32
        msgs = b.validate(recs)
        self.assertTrue(any("FNAM" in m and "33 bytes" in m for m in msgs), msgs)
        act["name"] = "x" * 31
        self.assertEqual(b.validate(recs), [])

        recs = copy.deepcopy(src)
        act = next(r for r in recs if r.get("id") == "omwc_lever_respawn")
        act["id"] = "y" * 32
        msgs = b.validate(recs)
        self.assertTrue(any(" id:" in m and "33 bytes" in m for m in msgs), msgs)
        act["id"] = "y" * 31
        self.assertEqual(b.validate(recs), [])

        recs = copy.deepcopy(src)
        cell = next(r for r in recs if r["type"] == "Cell")
        cell["name"] = "z" * 64
        msgs = b.validate(recs)
        self.assertTrue(any("Cell" in m and "65 bytes" in m for m in msgs), msgs)
        cell["name"] = "z" * 63
        self.assertEqual(b.validate(recs), [])

        recs = copy.deepcopy(src)
        recs[0]["author"] = "a" * 32
        msgs = b.validate(recs)
        self.assertTrue(any("author" in m and "33 bytes" in m for m in msgs), msgs)
        recs[0]["author"] = "a" * 31
        self.assertEqual(b.validate(recs), [])


if __name__ == "__main__":
    unittest.main()
