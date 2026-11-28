"""scripts/smoke_logscan.py: sorts the logs of a smoke test run. stdlib unittest; Python 3.9+. Written for omwcompat by dej (dejunai)."""
import importlib.util
import io
import contextlib
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load():
    spec = importlib.util.spec_from_file_location("smoke_logscan", ROOT / "scripts" / "smoke_logscan.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MWSE = """Morrowind Script Extender v2.1
Lua: loaded
[omwcompat 0.5.0] loaded
Lua error: C:\\Users\\someone\\Games\\Morrowind\\Data Files\\MWSE\\mods\\ab\\RegionThing\\main.lua:12: attempt to index field 'region' (a nil value)
stack traceback:
\tC:\\Users\\someone\\Games\\Morrowind\\Data Files\\MWSE\\mods\\ab\\RegionThing\\main.lua:12: in function <...>
Lua error: Data Files\\MWSE\\mods\\mwsuite\\openmw\\LeaveTheLightsOff\\main.lua:5: attempt to call a nil value
Lua error: Data Files\\MWSE\\mods\\zz\\Noise\\main.lua:3: bad argument #1 to 'x'
Lua error: Data Files\\MWSE\\mods\\zz\\Noise\\main.lua:3: bad argument #1 to 'x'
std::bad_alloc while loading mesh
"""
LIB = """2026-11-27 17:40:01  [smoketest 0.1.2] ===== begin (trigger: load) =====
2026-11-27 17:40:01  [smoketest] PASS LeaveTheLightsOff: light scheduling - ok
2026-11-27 17:40:01  [smoketest] FAIL Foo: bar - broke
[smoketest cell] check (weatherTransitionFinished, weather Rain): 9/11 fixtures present, MISSING: rat
"""


class LogScan(unittest.TestCase):
    def run_scan(self, files):
        mod = load()
        with tempfile.TemporaryDirectory() as td:
            paths = []
            for name, text in files.items():
                p = Path(td) / name
                p.write_text(text, encoding="utf-8")
                paths.append(str(p))
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                self.assertEqual(mod.main(paths), 0)
        return buf.getvalue()

    def test_sorts_files_and_splits_errors(self):
        out = self.run_scan({"a.log": MWSE, "b.log": LIB, "c.log.prev": LIB})
        self.assertIn("a.log: MWSE.log", out)
        self.assertIn("b.log: omwcompat.log", out)
        self.assertIn("c.log.prev: omwcompat.log.prev", out)
        self.assertIn("OURS (omwcompat / mwsuite / smoketest): 1 block", out)
        self.assertIn("ab/regionthing", out)          # the other mod the cell upset
        self.assertIn("OTHER (unrelated noise): 1 distinct, 2 total", out)
        self.assertIn("FAIL", out)
        self.assertIn("MISSING: rat", out)
        self.assertIn("memory pressure hints: 1", out)

    def test_personal_paths_are_shortened(self):
        out = self.run_scan({"a.log": MWSE})
        self.assertNotIn("someone", out)
        self.assertNotIn("C:\\Users", out)


if __name__ == "__main__":
    unittest.main()
