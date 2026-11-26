"""Tests for hard-coded constant conversion, sidecars, the developer warning and `convert`."""
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from omw2mwse import constants as K  # noqa: E402
from omw2mwse import sidecar as SC  # noqa: E402
from omw2mwse import warn  # noqa: E402
from omw2mwse.cli import main, translate_tidy_flag  # noqa: E402
from omw2mwse.convert import EXIT_CONFLICT, EXIT_OK, EXIT_REFUSED, convert  # noqa: E402
from omw2mwse.scan import scan_mod  # noqa: E402

LUA = """\
local world = require('openmw.world')
local RADIUS = 512
local ENABLED = true
local PREFIX = "omw_"
local counter = 0
local NEG = -2.5
local unused = 3
local EXPR = 1 + 2
local function onUpdate(dt)
    counter = counter + 1
    if counter >= 30 and RADIUS > 0 and ENABLED then
        local id = PREFIX .. tostring(counter)
        if dt < 0.25 then return NEG end
    end
end
local t = { Rain = false, Ash = true }
return { engineHandlers = { onUpdate = onUpdate } }
"""


def make_staged(root: Path, lua: str = LUA, sidecar: str | None = None) -> Path:
    src = root / "Off" / "OpenMW" / "Demo"
    (src / "scripts" / "Demo").mkdir(parents=True)
    (src / "scripts" / "Demo" / "g.lua").write_text(lua, encoding="utf-8")
    (src / "Demo.omwscripts").write_text("GLOBAL: scripts/Demo/g.lua\n", encoding="utf-8")
    if sidecar:
        (root / "Demo.omw2mwse.toml").write_text(sidecar, encoding="utf-8")
    return src


def tree(root: Path) -> dict:
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


SIDECAR = """\
[mcm]
page = "Demo"
[[constant]]
name = "RADIUS"
label = "Radius"
min = 1
max = 4096
integer = true
[[literal]]
key = "COUNT_LIMIT"
file = "scripts/Demo/g.lua"
line = 11
context = "counter >= 30"
[[literal]]
key = "DARK_RAIN"
file = "scripts/Demo/g.lua"
line = 16
context = "Rain = false"
"""


class Detect(unittest.TestCase):
    def setUp(self):
        self.consts, self.inline = K.detect(LUA)
        self.by = {c.name: c for c in self.consts}

    def test_candidates(self):
        self.assertTrue(self.by["RADIUS"].eligible)
        self.assertEqual(self.by["RADIUS"].value, 512)
        self.assertTrue(self.by["ENABLED"].eligible)
        self.assertEqual(self.by["NEG"].literal, "-2.5")
        self.assertEqual(self.by["NEG"].value, -2.5)
        self.assertNotIn("EXPR", self.by)  # an expression, not a literal

    def test_rejections(self):
        self.assertFalse(self.by["counter"].eligible)
        self.assertIn("reassigned", self.by["counter"].reason)
        self.assertFalse(self.by["unused"].eligible)

    def test_risks(self):
        self.assertTrue(self.by["PREFIX"].concat)
        self.assertTrue(any("string constant" in r for r in self.by["PREFIX"].risks))
        self.assertTrue(any("upvalue by onUpdate" in r for r in self.by["RADIUS"].risks))

    def test_inline(self):
        ctx = [x.context for x in self.inline]
        self.assertIn("counter >= 30", ctx)
        self.assertIn("dt < 0.25", ctx)
        self.assertTrue(all(x.function == "onUpdate" for x in self.inline))

    def test_auto_pick(self):
        picked = [c.name for c, why in K.auto_pick(self.consts) if why.startswith("picked")]
        self.assertEqual(picked, ["RADIUS", "ENABLED", "NEG"])

    def test_rewrite_keeps_lines(self):
        c = self.by["RADIUS"]
        conv = K.Conversion(key="RADIUS", kind="constant", file="g", line=c.line, name="RADIUS", type="number",
                            literal=c.literal, default=512, start=c.start, end=c.end, apply="reload")
        out = K.rewrite(LUA, [conv])
        self.assertEqual(out.count("\n"), LUA.count("\n"))
        self.assertIn('local RADIUS = omwcompat.cfg("RADIUS", 512) --[[omw2mwse: hard-coded 512]]', out)

    def test_find_literal(self):
        s, e, raw, kind, val, in_fn, in_tbl = K.find_literal(LUA, 11, "counter >= 30", None)
        self.assertEqual((raw, kind, val, in_fn), ("30", "number", 30, True))
        s, e, raw, kind, val, in_fn, in_tbl = K.find_literal(LUA, 16, "Rain = false", None)
        self.assertEqual((raw, val, in_fn, in_tbl), ("false", False, False, True))
        with self.assertRaises(ValueError):
            K.find_literal(LUA, 11, "nope", None)


class Sidecar(unittest.TestCase):
    def test_load_and_validate(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / "x.toml"
            p.write_text(SIDECAR, encoding="utf-8")
            d = SC.load(p)
            self.assertEqual(len(d["constant"]), 1)
            p.write_text('[[literal]]\nkey = "A"\n', encoding="utf-8")
            with self.assertRaises(SC.SidecarError):
                SC.load(p)
            p.write_text('[[constant]]\nname = "A"\nbogus = 1\n', encoding="utf-8")
            with self.assertRaises(SC.SidecarError):
                SC.load(p)


class Warning(unittest.TestCase):
    def _plan(self):
        with tempfile.TemporaryDirectory() as t:
            make_staged(Path(t), sidecar=SIDECAR)
            r = convert(Path(t), "hardcode", dry_run=True)
        return r["mods"][0]

    def test_text(self):
        m = self._plan()
        w = m["warning"]
        self.assertIn("DEVELOPER WARNING", w)
        self.assertIn("never shown to players", w)
        self.assertIn('counter >= omwcompat.cfg("COUNT_LIMIT", 30)', w)
        self.assertIn("applies: live (read every time onUpdate runs)", w)
        self.assertEqual([c["key"] for c in m["rewrites"]], ["RADIUS", "COUNT_LIMIT", "DARK_RAIN"])

    def test_confirm(self):
        convs = [K.Conversion(key="A", kind="constant", file="f", line=1, name="A", type="number", literal="1",
                              default=1, start=0, end=1, apply="reload")]
        err = io.StringIO()
        with self.assertRaises(warn.Refused):
            warn.confirm("W", convs, accept=False, interactive=False, err=err)
        self.assertEqual(warn.confirm("W", convs, accept=True, err=err), convs)
        self.assertEqual(warn.confirm("W", convs, False, interactive=True, inp=io.StringIO("a\n"), err=err), convs)
        with self.assertRaises(warn.Refused):
            warn.confirm("W", convs, False, interactive=True, inp=io.StringIO("\n"), err=err)
        with self.assertRaises(warn.Refused):
            warn.confirm("W", convs, False, interactive=True, inp=io.StringIO("r\nn\n"), err=err)


class Convert(unittest.TestCase):
    def test_normal_mode_reports_candidates_only(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = make_staged(root)
            before = tree(src)
            r = convert(root, "normal")
            self.assertEqual(r["exitCode"], EXIT_OK)
            m = r["mods"][0]
            self.assertEqual(m["name"], "Demo")
            self.assertEqual(m["rewrites"], [])
            cands = [a for a in m["alerts"] if a["code"] == "hardcode-candidate"]
            self.assertIn("RADIUS", [a.get("name") for a in cands])
            self.assertIn("counter >= 30", [a.get("context") for a in cands])
            out = root / "MWSE" / "omw" / "Demo" / "scripts" / "Demo" / "g.lua"
            self.assertEqual(out.read_text(encoding="utf-8"), LUA)  # byte-identical
            self.assertTrue((root / "MWSE" / "mods" / "Demo" / "main.lua").exists())
            self.assertTrue((root / "MWSE" / "omw" / "Demo" / "omw2mwse-manifest.json").exists())
            self.assertEqual(tree(src), before)  # source untouched
            notice = "Unofficial mwsuite conversion of Demo by the original author"
            self.assertIn("Report issues to mwsuite / dej (dejunai)", m["notice"])
            meta = (root / "Demo-metadata.toml").read_text(encoding="utf-8")
            self.assertIn(notice, meta)
            readme = (root / "MWSE" / "omw" / "Demo" / "README-mwsuite.md").read_text(encoding="utf-8")
            self.assertIn("Please do not send bug reports", readme)
            r = convert(root, "normal", credits={"author": "Someone", "license": "MIT", "url": "https://x"})
            meta = (root / "Demo-metadata.toml").read_text(encoding="utf-8")
            self.assertIn("not to Someone. Original license: MIT.", meta)
            self.assertIn('"Someone (original mod)"', meta)

    def test_idempotent(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root, sidecar=SIDECAR)
            with redirect_stderr(io.StringIO()):
                r1 = convert(root, "hardcode", accept=True)
                snap = tree(root)
                r2 = convert(root, "hardcode", accept=True)
            self.assertTrue(r1["changed"])
            self.assertFalse(r2["changed"])
            self.assertTrue(all(s == "unchanged" for s in r2["mods"][0]["files"].values()))
            self.assertEqual(tree(root), snap)

    def test_hardcode_sidecar_rewrite(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root, sidecar=SIDECAR)
            with redirect_stderr(io.StringIO()):
                r = convert(root, "hardcode", accept=True)
            omw = root / "MWSE" / "omw" / "Demo"
            new = (omw / "scripts" / "Demo" / "g.lua").read_text(encoding="utf-8")
            self.assertIn('if counter >= omwcompat.cfg("COUNT_LIMIT", 30) --[[omw2mwse: hard-coded 30]] and', new)
            self.assertEqual((omw / "_original" / "scripts" / "Demo" / "g.lua").read_text(encoding="utf-8"), LUA)
            main_lua = (root / "MWSE" / "mods" / "Demo" / "main.lua").read_text(encoding="utf-8")
            self.assertIn('key = "RADIUS"', main_lua)
            self.assertIn('apply = "live"', main_lua)
            rep = (omw / "OMW2MWSE-REPORT.md").read_text(encoding="utf-8")
            self.assertIn("**rewritten**", rep)
            self.assertEqual(r["mods"][0]["sidecar"], str(root / "Demo.omw2mwse.toml"))

    def test_hardcode_auto_pick_logs(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            with redirect_stderr(io.StringIO()):
                r = convert(root, "hardcode", accept=True)
            m = r["mods"][0]
            self.assertEqual([c["key"] for c in m["rewrites"]], ["RADIUS", "ENABLED", "NEG"])
            log = "\n".join(m["hardcodeLog"])
            self.assertIn("PREFIX: skipped: string constants are not auto-picked", log)
            self.assertIn("counter: skipped: reassigned", log)
            self.assertIn("'counter >= 30': skipped: inline literals are only converted from a sidecar", log)

    def test_hardcode_refused_without_flag(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            with redirect_stderr(io.StringIO()):
                r = convert(root, "hardcode", interactive=False)
            self.assertEqual(r["exitCode"], EXIT_REFUSED)
            self.assertEqual(r["mods"][0]["status"], "refused")
            self.assertFalse((root / "MWSE").exists())

    def test_conflict_with_foreign_file(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            p = root / "MWSE" / "mods" / "Demo" / "main.lua"
            p.parent.mkdir(parents=True)
            p.write_text("-- hand written\n", encoding="utf-8")
            r = convert(root, "normal")
            self.assertEqual(r["exitCode"], EXIT_CONFLICT)
            self.assertEqual(p.read_text(encoding="utf-8"), "-- hand written\n")
            self.assertFalse((root / "MWSE" / "omw").exists())  # nothing written
            r = convert(root, "normal", adopt=True)
            self.assertEqual(r["exitCode"], EXIT_OK)
            self.assertIn("omwcompat.register", p.read_text(encoding="utf-8"))

    def test_hand_edit_detected(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            convert(root, "normal")
            p = root / "MWSE" / "mods" / "Demo" / "main.lua"
            p.write_text(p.read_text(encoding="utf-8") + "-- edit\n", encoding="utf-8")
            r = convert(root, "normal")
            self.assertEqual(r["exitCode"], EXIT_CONFLICT)
            self.assertIn("edited by hand", r["mods"][0]["conflicts"][0]["reason"])

    def test_mode_switch_removes_original_copy(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root, sidecar=SIDECAR)
            with redirect_stderr(io.StringIO()):
                convert(root, "hardcode", accept=True)
            orig = root / "MWSE" / "omw" / "Demo" / "_original" / "scripts" / "Demo" / "g.lua"
            self.assertTrue(orig.exists())
            r = convert(root, "normal")
            self.assertFalse(orig.exists())
            self.assertEqual(r["mods"][0]["files"]["MWSE/omw/Demo/_original/scripts/Demo/g.lua"], "removed")
            self.assertEqual((root / "MWSE" / "omw" / "Demo" / "scripts" / "Demo" / "g.lua").read_text(encoding="utf-8"), LUA)

    def test_hardlink_not_modified_in_place(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            convert(root, "normal")
            p = root / "MWSE" / "mods" / "Demo" / "main.lua"
            deployed = Path(t) / "deployed-main.lua"
            os.link(p, deployed)
            old = deployed.read_bytes()
            with redirect_stderr(io.StringIO()):
                convert(root, "hardcode", accept=True)
            self.assertNotEqual(p.read_bytes(), old)
            self.assertEqual(deployed.read_bytes(), old)  # the hardlinked copy is untouched

    def test_cli_tidy_flag_json(self):
        self.assertEqual(translate_tidy_flag(["--convert-omwscripts", "D", "--json"]), ["convert", "D", "--json", "--mode", "normal"])
        self.assertEqual(translate_tidy_flag(["--convert-omwscripts=hardcode", "D"]), ["convert", "D", "--mode", "hardcode"])
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = main(["--convert-omwscripts", str(root), "--json"])
            self.assertEqual(rc, 0)
            r = json.loads(buf.getvalue())
            self.assertEqual(r["mode"], "normal")
            self.assertTrue(any(a["code"] == "hardcode-candidate" for a in r["mods"][0]["alerts"]))
            buf = io.StringIO()
            with redirect_stdout(buf), redirect_stderr(io.StringIO()):
                rc = main(["--convert-omwscripts=hardcode", str(root), "--json"])
            self.assertEqual(rc, EXIT_REFUSED)  # not a tty and no accept flag
            buf = io.StringIO()
            with redirect_stdout(buf), redirect_stderr(io.StringIO()):
                rc = main(["--convert-omwscripts=hardcode", str(root), "--json", "--accept-hardcode-conversions"])
            self.assertEqual(rc, 0)
            self.assertEqual(len(json.loads(buf.getvalue())["mods"][0]["rewrites"]), 3)


class ScanSettings(unittest.TestCase):
    def test_settings_coverage(self):
        lua = """local I = require('openmw.interfaces')
local S = { { key = 'a', renderer = 'checkbox', default = true }, { key = 'b', renderer = 'MySlider', default = 1 } }
I.Settings.registerGroup { key = 'SettingsX', page = 'X', settings = S }
I.Settings.registerGroup({ key = 'SettingsY', settings = { { key = 'c', default = 'x' } } })
"""
        with tempfile.TemporaryDirectory() as t:
            src = Path(t)
            (src / "scripts").mkdir()
            (src / "scripts" / "s.lua").write_text(lua, encoding="utf-8")
            (src / "X.omwscripts").write_text("MENU: scripts/s.lua\n", encoding="utf-8")
            sc = scan_mod(src)
            self.assertEqual([g["key"] for g in sc.settings["groups"]], ["SettingsX", "SettingsY"])
            self.assertEqual(sc.settings["renderers"]["MySlider"]["status"], "custom")
            self.assertEqual(sc.settings["renderers"]["textLine"]["count"], 1)
            self.assertEqual(sc.settings_coverage(), (2, 3))


if __name__ == "__main__":
    unittest.main()
