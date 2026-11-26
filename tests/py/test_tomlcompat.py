"""The built-in TOML reader used on Python 3.9/3.10 (tomllib is 3.11+)."""
from __future__ import annotations

import io
import math
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from omw2mwse import tomlcompat  # noqa: E402
from omw2mwse.build import render_metadata  # noqa: E402

try:
    import tomllib  # noqa: F401
except ImportError:
    tomllib = None

SAMPLE = '''# comment
title = "A \\"quoted\\" \\u00e9 \\t tab"   # trailing comment
lit = 'C:\\path\\no escapes'
ml = """
first
second \\
   joined"""
mll = \'\'\'
raw \\n here\'\'\'
n = 1_000
neg = -42
hex = 0xff
f = 3.5e2
fl = -0.25
yes = true
no = false
arr = [ 1, 2,
  3, ]  # multi-line with trailing comma
strs = ["a", 'b']
nested = [[1, 2], ["x"]]
inline = { a = 1, "b c" = "d", e.f = true }
"quoted key" = 1
dotted.key = "v"

[package]
name = "X"
authors = ["One (original mod)", "Two"]

[tools.mwse]
lua-mod = "mwsuite.openmw.X"

[[constant]]
name = "A"
min = 0

[[constant]]
name = "B"
max = 1.5
integer = false

[a.b]
c = 1
[a]
d = 2
'''


class TomlCompatTests(unittest.TestCase):
    def test_fallback_sample(self):
        d = tomlcompat._loads(SAMPLE)
        self.assertEqual(d["title"], 'A "quoted" \u00e9 \t tab')
        self.assertEqual(d["lit"], "C:\\path\\no escapes")
        self.assertEqual(d["ml"], "first\nsecond joined")
        self.assertEqual(d["mll"], "raw \\n here")
        self.assertEqual((d["n"], d["neg"], d["hex"], d["f"], d["fl"]), (1000, -42, 255, 350.0, -0.25))
        self.assertIs(d["yes"], True)
        self.assertIs(d["no"], False)
        self.assertEqual(d["arr"], [1, 2, 3])
        self.assertEqual(d["strs"], ["a", "b"])
        self.assertEqual(d["nested"], [[1, 2], ["x"]])
        self.assertEqual(d["inline"], {"a": 1, "b c": "d", "e": {"f": True}})
        self.assertEqual(d["quoted key"], 1)
        self.assertEqual(d["dotted"], {"key": "v"})
        self.assertEqual(d["package"]["authors"], ["One (original mod)", "Two"])
        self.assertEqual(d["tools"]["mwse"]["lua-mod"], "mwsuite.openmw.X")
        self.assertEqual(d["constant"], [{"name": "A", "min": 0}, {"name": "B", "max": 1.5, "integer": False}])
        self.assertEqual(d["a"], {"b": {"c": 1}, "d": 2})
        self.assertIsInstance(d["n"], int)
        self.assertIsInstance(d["f"], float)

    @unittest.skipIf(tomllib is None, "tomllib needs Python 3.11+")
    def test_same_as_tomllib(self):
        files = [SAMPLE, render_metadata("Mod", "src", {"title": "T \"q\"", "author": "Au", "url": "https://x/1"}, [])]
        files += [p.read_text(encoding="utf-8") for p in sorted((ROOT / "sidecars").glob("*.toml"))]
        for text in files:
            self.assertEqual(tomlcompat._loads(text), tomllib.loads(text))

    def test_errors_are_valueerrors(self):
        for bad in ('a = "unterminated', "a = ", "a = 1\na = 2", "[x\n", "a = 1979-05-27", "a = [1 2]",
                    "= 1", 'a = "\\q"', "a = 1 b"):
            with self.assertRaises(ValueError, msg=bad):
                tomlcompat._loads(bad)
            with self.assertRaises(tomlcompat.TOMLDecodeError, msg=bad):
                tomlcompat._loads(bad)

    def test_special_floats_and_load(self):
        d = tomlcompat._loads("a = inf\nb = -inf\nc = nan\n")
        self.assertEqual((d["a"], d["b"]), (math.inf, -math.inf))
        self.assertTrue(math.isnan(d["c"]))
        self.assertEqual(tomlcompat.load(io.BytesIO(b"x = 'y'\n")), {"x": "y"})

    def test_pyproject_requires_python(self):
        from omw2mwse import REQUIRES_PYTHON
        d = tomlcompat._loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
        self.assertEqual(d["project"]["requires-python"], REQUIRES_PYTHON)
        self.assertEqual(REQUIRES_PYTHON, ">=3.9")

    def test_backend(self):
        b = tomlcompat._backend()
        if sys.version_info >= (3, 11):
            self.assertEqual(b.__name__, "tomllib")
        else:
            self.assertIs(b, tomlcompat._SELF)


if __name__ == "__main__":
    unittest.main()
