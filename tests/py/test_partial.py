"""Audit #3: partially supported OpenMW APIs are listed next to the verdict (`partialApis`)."""
from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from omw2mwse.cli import main  # noqa: E402
from omw2mwse.convert import convert  # noqa: E402
from omw2mwse.scan import GENERIC_PARTIAL, load_manifest, partial_note, scan_mod  # noqa: E402

MANIFEST = load_manifest()

LUA = """\
local core = require('openmw.core')
local world = require('openmw.world')
local function onUpdate(dt)
    local w = core.weather.getCurrent()
    local t = core.getRealTime()
    for _, a in ipairs(world.activeActors) do
        if w then a:remove() end
    end
end
return { engineHandlers = { onUpdate = onUpdate } }
"""


def make(root: Path, lua: str = LUA) -> None:
    (root / "scripts" / "P").mkdir(parents=True)
    (root / "scripts" / "P" / "g.lua").write_text(lua, encoding="utf-8")
    (root / "P.omwscripts").write_text("GLOBAL: scripts/P/g.lua\n", encoding="utf-8")


class PartialApis(unittest.TestCase):
    def test_scan_lists_partial_uses_with_file_and_line(self):
        with tempfile.TemporaryDirectory() as t:
            make(Path(t))
            s = scan_mod(Path(t), MANIFEST)
            self.assertEqual(s.verdict, "ready")            # partial never changes the verdict
            by = {p["api"]: p for p in s.partial_apis}
            self.assertEqual(sorted(by), ["GameObject:remove", "openmw.core.getRealTime",
                                          "openmw.core.weather.getCurrent", "openmw.world.activeActors"])
            self.assertEqual(by["openmw.core.weather.getCurrent"]["uses"], [{"file": "scripts/P/g.lua", "line": 4}])
            self.assertEqual(by["GameObject:remove"]["uses"], [{"file": "scripts/P/g.lua", "line": 7}])
            self.assertEqual(by["GameObject:remove"]["kind"], "method")
            self.assertIn("os.clock", by["openmw.core.getRealTime"]["missing"])
            for p in s.partial_apis:
                self.assertEqual(set(p), {"api", "kind", "count", "uses", "missing"})
                self.assertTrue(p["missing"])
            self.assertEqual(s.to_dict()["partialApis"], s.partial_apis)

    def test_full_apis_are_not_listed(self):
        with tempfile.TemporaryDirectory() as t:
            make(Path(t), "local async = require('openmw.async')\nasync:newGameTimer(1, nil)\nreturn {}\n")
            self.assertEqual(scan_mod(Path(t), MANIFEST).partial_apis, [])

    def test_convert_json_has_partial_apis_and_same_verdict(self):
        with tempfile.TemporaryDirectory() as t:
            make(Path(t))
            buf = io.StringIO()
            with redirect_stdout(buf):
                main(["--convert-omwscripts", t, "--json"])
            m = json.loads(buf.getvalue())["mods"][0]
            self.assertEqual(m["verdict"], "ready")
            self.assertEqual(m["status"], "ok")
            self.assertIn("openmw.world.activeActors", [p["api"] for p in m["partialApis"]])
            rep = (Path(t) / "MWSE" / "mods" / "mwsuite" / "openmw" / "P" / "OMW2MWSE-REPORT.md").read_text(encoding="utf-8")
            self.assertIn("Partially supported APIs", rep)
            self.assertIn("scripts/P/g.lua:4", rep)

    def test_blocked_mod_still_lists_partials(self):
        with tempfile.TemporaryDirectory() as t:
            make(Path(t), "local ui = require('openmw.ui')\nlocal core = require('openmw.core')\n"
                          "local x = core.getRealTime()\nreturn {}\n")
            r = convert(Path(t), "normal", dry_run=True)
            m = r["mods"][0]
            self.assertEqual(m["verdict"], "blocked")
            self.assertEqual([p["api"] for p in m["partialApis"]], ["openmw.core.getRealTime"])

    def test_opt_out_never_lists_positions(self):
        with tempfile.TemporaryDirectory() as t:
            make(Path(t), "-- mwsuite conversion opt-out\n" + LUA)
            s = scan_mod(Path(t), MANIFEST)
            self.assertEqual(s.partial_apis, [])
            r = convert(Path(t), "normal")
            self.assertEqual(r["mods"][0]["partialApis"], [])
            self.assertNotIn('"line"', json.dumps(r))

    def test_notes(self):
        self.assertIn("health", partial_note("openmw.types.NPC.stats.dynamic.health", MANIFEST))
        self.assertIn("record fields", partial_note("openmw.types.Weapon.record", MANIFEST))
        self.assertIn("R2", partial_note("teleport", MANIFEST))
        self.assertEqual(partial_note("openmw.something.new", MANIFEST), GENERIC_PARTIAL)

    def test_every_partial_symbol_has_a_specific_note(self):
        missing = [k for k, v in MANIFEST["symbols"].items() if v == "partial" and partial_note(k, MANIFEST) == GENERIC_PARTIAL]
        missing += [k for k, v in MANIFEST["gameObject"]["methods"].items()
                    if v == "partial" and partial_note(k, MANIFEST) == GENERIC_PARTIAL]
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
