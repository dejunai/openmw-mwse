"""Tests for hard-coded constant conversion, sidecars, the developer warning and `convert`."""
from __future__ import annotations

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
from omw2mwse.build import NO_REDISTRIBUTION, SUPPORT_LINE  # noqa: E402
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
            self.assertEqual(m["off"], "Off/Demo/OpenMW")
            self.assertEqual(m["source"], "Off/Demo/OpenMW")
            self.assertEqual(m["relocatedFrom"], "Off/OpenMW/Demo")
            cands = [a for a in m["alerts"] if a["code"] == "hardcode-candidate"]
            self.assertIn("RADIUS", [a.get("name") for a in cands])
            self.assertIn("counter >= 30", [a.get("context") for a in cands])
            out = root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "omw" / "scripts" / "Demo" / "g.lua"
            self.assertEqual(out.read_text(encoding="utf-8"), LUA)  # byte-identical
            self.assertTrue((root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "main.lua").exists())
            self.assertTrue((root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "omw2mwse-manifest.json").exists())
            canon = root / "Off" / "Demo" / "OpenMW"
            self.assertEqual(tree(canon), before)  # complete original package, new layout
            self.assertFalse((root / "Off" / "OpenMW" / "Demo").exists())
            self.assertFalse((root / "Off" / "OpenMW").exists())
            notice = "Unofficial mwsuite conversion of Demo (original author: unknown)"
            self.assertIn(SUPPORT_LINE, m["notice"])
            meta = (root / "Demo-metadata.toml").read_text(encoding="utf-8")
            self.assertIn(notice, meta)
            readme = (root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "README-mwsuite.md").read_text(encoding="utf-8")
            self.assertIn("Please do not send bug reports", readme)
            self.assertIn(SUPPORT_LINE, readme)
            self.assertIn(NO_REDISTRIBUTION, readme)
            r = convert(root, "normal", credits={"author": "Someone", "license": "MIT", "url": "https://x"})
            meta = (root / "Demo-metadata.toml").read_text(encoding="utf-8")
            self.assertIn("(original author: Someone). " + SUPPORT_LINE + " Original license: MIT.", meta)
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
            omw = root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "omw"
            new = (omw / "scripts" / "Demo" / "g.lua").read_text(encoding="utf-8")
            self.assertIn('if counter >= omwcompat.cfg("COUNT_LIMIT", 30) --[[omw2mwse: hard-coded 30]] and', new)
            self.assertEqual((omw / "_original" / "scripts" / "Demo" / "g.lua").read_text(encoding="utf-8"), LUA)
            main_lua = (root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "main.lua").read_text(encoding="utf-8")
            self.assertIn('key = "RADIUS"', main_lua)
            self.assertIn('apply = "live"', main_lua)
            rep = (omw.parent / "OMW2MWSE-REPORT.md").read_text(encoding="utf-8")
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
            p = root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "main.lua"
            p.parent.mkdir(parents=True)
            p.write_text("-- hand written\n", encoding="utf-8")
            r = convert(root, "normal")
            self.assertEqual(r["exitCode"], EXIT_CONFLICT)
            self.assertEqual(p.read_text(encoding="utf-8"), "-- hand written\n")
            self.assertFalse((root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "omw").exists())  # nothing written
            r = convert(root, "normal", adopt=True)
            self.assertEqual(r["exitCode"], EXIT_OK)
            self.assertIn("omwcompat.register", p.read_text(encoding="utf-8"))

    def test_hand_edit_detected(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            convert(root, "normal")
            p = root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "main.lua"
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
            orig = root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "omw" / "_original" / "scripts" / "Demo" / "g.lua"
            self.assertTrue(orig.exists())
            r = convert(root, "normal")
            self.assertFalse(orig.exists())
            self.assertEqual(r["mods"][0]["files"]["MWSE/mods/mwsuite/openmw/Demo/omw/_original/scripts/Demo/g.lua"], "removed")
            self.assertEqual((root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "omw" / "scripts" / "Demo" / "g.lua").read_text(encoding="utf-8"), LUA)

    def test_hardlink_not_modified_in_place(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            convert(root, "normal")
            p = root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "main.lua"
            deployed = Path(t) / "deployed-main.lua"
            os.link(p, deployed)
            old = deployed.read_bytes()
            with redirect_stderr(io.StringIO()):
                convert(root, "hardcode", accept=True)
            self.assertNotEqual(p.read_bytes(), old)
            self.assertEqual(deployed.read_bytes(), old)  # the hardlinked copy is untouched

    def test_canonical_off_layout_is_idempotent(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = root / "Off" / "Demo" / "OpenMW"
            (src / "scripts" / "Demo").mkdir(parents=True)
            (src / "scripts" / "Demo" / "g.lua").write_text(LUA, encoding="utf-8")
            (src / "Demo.omwscripts").write_text("GLOBAL: scripts/Demo/g.lua\n", encoding="utf-8")
            (src / "meshes" / "short.nif").parent.mkdir()
            (src / "meshes" / "short.nif").write_bytes(b"NIF")
            before = tree(src)
            r1 = convert(root, "normal")
            self.assertEqual(r1["mods"][0]["source"], "Off/Demo/OpenMW")
            self.assertNotIn("relocatedFrom", r1["mods"][0])
            self.assertEqual(tree(src), before)
            self.assertEqual((root / "meshes" / "short.nif").read_bytes(), b"NIF")
            self.assertFalse((root / "Off" / "OpenMW").exists())
            snap = tree(root)
            r2 = convert(root, "normal")
            self.assertFalse(r2["changed"])
            self.assertEqual(tree(root), snap)

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


class Layout(unittest.TestCase):
    def test_support_line_matches_lua_constant(self):
        lua = (ROOT / "runtime" / "MWSE" / "lib" / "omwcompat" / "conversions.lua").read_text(encoding="utf-8")
        import re
        m = re.search(r'C\.SUPPORT = ((?:"[^"]*"\s*(?:\.\.\s*)?)+)', lua)
        self.assertIsNotNone(m)
        self.assertEqual("".join(re.findall(r'"([^"]*)"', m.group(1))), SUPPORT_LINE)
        m = re.search(r'C\.NO_REDISTRIBUTION = ((?:"[^"]*"\s*(?:\.\.\s*)?)+)', lua)
        self.assertIsNotNone(m)
        self.assertEqual("".join(re.findall(r'"([^"]*)"', m.group(1))), NO_REDISTRIBUTION)

    def test_no_redistribution_in_disclaimer_and_readme(self):
        lua = (ROOT / "runtime" / "MWSE" / "lib" / "omwcompat" / "conversions.lua").read_text(encoding="utf-8")
        self.assertIn("No redistribution.", lua)
        self.assertIn("personal use only", lua)

    def test_credits_detected_from_fomod_info(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            (root / "fomod").mkdir()
            (root / "fomod" / "info.xml").write_text(
                "<fomod><Name>Demo Mod</Name><Author>Ann Author</Author><Website>https://x/y</Website></fomod>", encoding="utf-8")
            r = convert(root, "normal")
            self.assertIn("Unofficial mwsuite conversion of Demo Mod (original author: Ann Author)", r["mods"][0]["notice"])
            main_lua = (root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "main.lua").read_text(encoding="utf-8")
            self.assertIn('author = "Ann Author"', main_lua)
            r = convert(root, "normal", credits={"author": "Cli Override"})  # CLI option wins
            self.assertIn("original author: Cli Override", r["mods"][0]["notice"])

    def test_hosted_main_lua_is_not_a_mwse_mod(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = make_staged(root)
            (src / "scripts" / "Demo" / "main.lua").write_text("return {}\n", encoding="utf-8")
            (src / "Demo.omwscripts").write_text("GLOBAL: scripts/Demo/g.lua\nGLOBAL: scripts/Demo/main.lua\n", encoding="utf-8")
            convert(root, "normal")
            omw = root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo" / "omw" / "scripts" / "Demo"
            self.assertTrue((omw / "main.lua.omw").is_file())
            mains = [p for p in (root / "MWSE").rglob("main.lua")]
            self.assertEqual([p.relative_to(root).as_posix() for p in mains], ["MWSE/mods/mwsuite/openmw/Demo/main.lua"])
            # the complete original keeps its real name under Off/
            self.assertTrue((root / "Off" / "Demo" / "OpenMW" / "scripts" / "Demo" / "main.lua").is_file())

    def test_migrates_0_2_0_layout(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            convert(root, "normal")
            new = root / "MWSE" / "mods" / "mwsuite" / "openmw" / "Demo"
            # fake a 0.2.0 install of the same files in the old places
            import json
            old_omw, old_mod = root / "MWSE" / "omw" / "Demo", root / "MWSE" / "mods" / "Demo"
            files = {}
            for rel, dst in (("main.lua", old_mod / "main.lua"), ("omw/scripts/Demo/g.lua", old_omw / "scripts" / "Demo" / "g.lua")):
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_bytes((new / rel).read_bytes())
                from omw2mwse.build import sha256b
                files[dst.relative_to(root).as_posix()] = sha256b(dst.read_bytes())
            (old_omw / "omw2mwse-manifest.json").write_text(json.dumps({"files": files}), encoding="utf-8")
            r = convert(root, "normal")
            self.assertFalse(old_mod.exists())
            self.assertFalse((old_omw / "scripts").exists())
            self.assertTrue((new / "main.lua").exists())
            self.assertEqual(r["mods"][0]["files"]["MWSE/mods/Demo/main.lua"], "removed")


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


class PluginRename(unittest.TestCase):
    """A root .omwaddon is TES3 like an .esp; Morrowind loads only .esp/.esm."""

    def _staged(self, t, extra=()):
        root = make_staged(Path(t))
        (root / "Fires.omwaddon").write_bytes(b"TES3\x00addon")
        for n, b in extra:
            (root / n).write_bytes(b)
        return root

    def test_omwaddon_installed_as_esp_and_original_kept_in_off(self):
        with tempfile.TemporaryDirectory() as t:
            root = self._staged(t)
            r = convert(root, "normal")
            self.assertEqual(r["exitCode"], EXIT_OK)
            name = r["mods"][0]["name"]
            self.assertEqual((root / "Fires.esp").read_bytes(), b"TES3\x00addon")
            self.assertFalse((root / "Fires.omwaddon").exists())
            self.assertTrue((root / f"Off/{name}/OpenMW/Fires.omwaddon").is_file())
            self.assertIn("Fires.esp", r["mods"][0]["files"])
            md = (root / f"{name}-metadata.toml").read_text(encoding="utf-8")
            self.assertIn("Fires.omwaddon -> Fires.esp", md)
            rm = (root / f"MWSE/mods/mwsuite/openmw/{name}/README-mwsuite.md").read_text(encoding="utf-8")
            self.assertIn("`Fires.esp`", rm)
            rep = (root / f"MWSE/mods/mwsuite/openmw/{name}/OMW2MWSE-REPORT.md").read_text(encoding="utf-8")
            self.assertIn("as `Fires.esp`", rep)
            man = json.loads((root / f"MWSE/mods/mwsuite/openmw/{name}/omw2mwse-manifest.json").read_text())
            self.assertIn("Fires.esp", man["files"])
            self.assertNotIn("Fires.omwaddon", man["files"])
            # idempotent: second run changes nothing and keeps the .esp
            r2 = convert(root, "normal")
            self.assertFalse(r2["changed"])
            self.assertTrue((root / "Fires.esp").is_file())

    def test_clash_with_shipped_esp_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as t:
            root = self._staged(t, extra=[("Fires.esp", b"TES3\x00other")])
            r = convert(root, "normal")
            codes = [a["code"] for a in r["mods"][0]["alerts"]]
            self.assertIn("plugin-rename-clash", codes)
            self.assertEqual((root / "Fires.esp").read_bytes(), b"TES3\x00other")

    def test_tidy_flag_form(self):
        self.assertEqual(translate_tidy_flag(["--convert-omwscripts=hardcode", "D", "--json"]),
                         ["convert", "D", "--json", "--mode", "hardcode"])
        with tempfile.TemporaryDirectory() as t:
            root = self._staged(t)
            buf = io.StringIO()
            with redirect_stdout(buf), redirect_stderr(io.StringIO()):
                rc = main(["--convert-omwscripts=hardcode", str(root), "--accept-hardcode-conversions", "--json"])
            self.assertEqual(rc, EXIT_OK)
            self.assertEqual(json.loads(buf.getvalue())["mode"], "hardcode")


class GameAssetsStay(unittest.TestCase):
    def test_vanilla_sound_folder_stays_at_root(self):
        # Player On Fire / Thieves Pickpocket / Vaults Restricted ship Sound/<mod>/... (vanilla folder name)
        with tempfile.TemporaryDirectory() as t:
            root = make_staged(Path(t))
            (root / "Sound" / "Demo").mkdir(parents=True)
            (root / "Sound" / "Demo" / "a.wav").write_bytes(b"RIFF")
            (root / "shaders").mkdir()
            (root / "shaders" / "x.omwfx").write_bytes(b"fx")
            r = convert(root, "normal")
            name = r["mods"][0]["name"]
            self.assertTrue((root / "Sound/Demo/a.wav").is_file())
            self.assertTrue((root / f"Off/{name}/OpenMW/Sound/Demo/a.wav").is_file())
            # OpenMW-only folders are kept under Off/ only
            self.assertFalse((root / "shaders").exists())
            self.assertTrue((root / f"Off/{name}/OpenMW/shaders/x.omwfx").is_file())


class PluginPlacement(unittest.TestCase):
    """Plugins are placed by rule: root, Extras/, or Off/. No readme or FOMOD text."""

    def _write_plugin(self, path: Path, records, masters=None):
        from omw2mwse.tes3 import build_plugin
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(build_plugin(records, masters=masters or ["Morrowind.esm"]))

    def _plug(self, result, name=None):
        plugs = result["mods"][0]["plugins"]
        if name is None:
            self.assertEqual(len(plugs), 1, plugs)
            return plugs[0]
        hits = [p for p in plugs if p["name"] == name]
        self.assertEqual(len(hits), 1, plugs)
        return hits[0]

    def test_getglobalscript_makes_omwaddon_required_at_root(self):
        # No Fires in Bad Weather: Lua reads a global script the .omwaddon defines.
        from omw2mwse.tes3 import scpt, named
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = make_staged(root, lua="""\
local world = require('openmw.world')
local function onUpdate(dt)
    local w = world.mwscript.getGlobalScript("wetfire_weather_monitor").variables.actweather
end
return { engineHandlers = { onUpdate = onUpdate } }
""")
            self._write_plugin(src / "Fires.omwaddon", [
                scpt("wetfire_weather_monitor"),
                named("SSCR", "wetfire_weather_monitor"),
            ])
            r = convert(root, "normal")
            p = self._plug(r)
            self.assertEqual(p["name"], "Fires.esp")
            self.assertEqual(p["source"], "Fires.omwaddon")
            self.assertEqual(p["kind"], "esp")
            self.assertEqual(p["placement"], "root")
            self.assertEqual(p["status"], "required")
            self.assertEqual(p["path"], "Fires.esp")
            self.assertIn("getGlobalScript", p["reason"])
            self.assertIn("wetfire_weather_monitor", p["reason"])
            self.assertTrue((root / "Fires.esp").is_file())
            self.assertFalse((root / "Fires.omwaddon").exists())
            name = r["mods"][0]["name"]
            man = json.loads((root / "MWSE/mods/mwsuite/openmw" / name / "omw2mwse-manifest.json").read_text())
            self.assertEqual(man["plugins"], r["mods"][0]["plugins"])
            rep = (root / "MWSE/mods/mwsuite/openmw" / name / "OMW2MWSE-REPORT.md").read_text()
            self.assertIn("**required**", rep)
            self.assertIn("placement **root**", rep)

    def test_legacy_api_branch_moves_hook_esp_to_off(self):
        # Wildlife Attacks: the ESP defines ll_getfight + ll_fight_token and patches
        # vanilla CREA; Lua only touches the token inside `API_REVISION < 59`, which
        # is dead under omwcompat (API_REVISION 70). That is provably obsolete.
        from omw2mwse.tes3 import scpt, named
        lua = """\
local core = require('openmw.core')
local types = require('openmw.types')
local old_API = core.API_REVISION < 59
local list = { ["alit"] = true, ["guar"] = true }
local function onUpdate()
    if old_API then
        local n = types.Actor.inventory(self):countOf("ll_fight_token")
    else
        local ok = list[self.recordId]
    end
end
return { engineHandlers = { onUpdate = onUpdate } }
"""
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = make_staged(root, lua=lua)
            self._write_plugin(src / "wildlife_getfight.esp", [
                scpt("ll_getfight"),
                named("CREA", "alit", [("SCRI", b"ll_getfight\x00")]),
                named("CREA", "guar", [("SCRI", b"ll_getfight\x00")]),
                named("LIGH", "ll_fight_token"),
            ], masters=["Morrowind.esm", "Bloodmoon.esm"])
            r = convert(root, "normal")
            p = self._plug(r)
            name = r["mods"][0]["name"]
            self.assertEqual(p["name"], "wildlife_getfight.esp")
            self.assertEqual(p["source"], "wildlife_getfight.esp")
            self.assertEqual(p["kind"], "esp")
            self.assertEqual(p["placement"], "off")
            self.assertEqual(p["status"], "obsolete")
            self.assertEqual(p["path"], f"Off/{name}/OpenMW/wildlife_getfight.esp")
            self.assertIn("dead", p["reason"])
            self.assertIn("ll_fight_token", p["reason"])
            self.assertFalse((root / "wildlife_getfight.esp").exists())
            self.assertTrue((root / f"Off/{name}/OpenMW/wildlife_getfight.esp").is_file())
            # second run is a no-op and keeps the plugin only under Off/
            r2 = convert(root, "normal")
            self.assertFalse(r2["changed"])
            self.assertEqual(r2["mods"][0]["plugins"][0]["placement"], "off")
            self.assertFalse((root / "wildlife_getfight.esp").exists())
            self.assertTrue((root / f"Off/{name}/OpenMW/wildlife_getfight.esp").is_file())

    def test_live_record_id_makes_plugin_required(self):
        from omw2mwse.tes3 import named
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = make_staged(root, lua="""\
local world = require('openmw.world')
local function onInit()
    world.createObject("my_special_light", 1)
end
return { engineHandlers = { onInit = onInit } }
""")
            self._write_plugin(src / "Lights.esp", [named("LIGH", "my_special_light")])
            p = self._plug(convert(root, "normal"))
            self.assertEqual(p["placement"], "root")
            self.assertEqual(p["status"], "required")
            self.assertIn("my_special_light", p["reason"])
            self.assertTrue((root / "Lights.esp").is_file())

    def test_unreferenced_root_plugin_stays_enabled(self):
        # No Lua reference at all (live or dead) is undetermined, not obsolete:
        # MWScript or records may still need the plugin.
        from omw2mwse.tes3 import scpt
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = make_staged(root, lua="local x = 1\nreturn { engineHandlers = {} }\n")
            self._write_plugin(src / "Maybe.esp", [scpt("unused_script")])
            r = convert(root, "normal")
            p = self._plug(r)
            self.assertEqual(p["placement"], "root")
            self.assertEqual(p["status"], "undetermined")
            self.assertIn("does not reference", p["reason"])
            self.assertTrue((root / "Maybe.esp").is_file())

    def test_readme_is_ignored_when_lua_needs_the_plugin(self):
        from omw2mwse.tes3 import scpt
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = make_staged(root, lua="""\
local world = require('openmw.world')
return { engineHandlers = { onUpdate = function()
    world.mwscript.getGlobalScript("needme")
end } }
""")
            self._write_plugin(src / "NeedMe.esp", [scpt("needme")])
            (src / "Readme.txt").write_text(
                "NeedMe.esp is optional / legacy and only for older OpenMW.\n", encoding="utf-8")
            p = self._plug(convert(root, "normal"))
            self.assertEqual(p["placement"], "root")
            self.assertEqual(p["status"], "required")
            self.assertNotIn("readme", p["reason"].lower())
            self.assertTrue((root / "NeedMe.esp").is_file())

    def test_fomod_text_is_ignored_for_unreferenced_root_plugin(self):
        from omw2mwse.tes3 import scpt
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = make_staged(root, lua="local x = 1\nreturn { engineHandlers = {} }\n")
            self._write_plugin(src / "Extra.esp", [scpt("unused_script")])
            (src / "fomod").mkdir()
            (src / "fomod" / "ModuleConfig.xml").write_text(
                '<?xml version="1.0"?><config><requiredInstallFiles>'
                '<file source="Demo.omwscripts" destination="Demo.omwscripts"/>'
                '</requiredInstallFiles><installSteps><installStep name="Opts">'
                '<optionalFileGroups><group name="Extras" type="SelectAny"><plugins>'
                '<plugin name="Extra"><files>'
                '<file source="Extra.esp" destination="Extra.esp"/>'
                '</files></plugin></plugins></group></optionalFileGroups>'
                '</installStep></installSteps></config>',
                encoding="utf-8")
            p = self._plug(convert(root, "normal"))
            self.assertEqual(p["name"], "Extra.esp")
            self.assertEqual(p["placement"], "root")
            self.assertEqual(p["status"], "undetermined")
            self.assertNotIn("FOMOD", p["reason"])
            self.assertTrue((root / "Extra.esp").is_file())

    def test_subfolder_plugin_goes_to_extras(self):
        from omw2mwse.tes3 import scpt
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = make_staged(root, lua="local x = 1\nreturn { engineHandlers = {} }\n")
            self._write_plugin(src / "optional" / "Extra.esp", [scpt("unused_script")])
            r = convert(root, "normal")
            name = r["mods"][0]["name"]
            p = self._plug(r)
            self.assertEqual(p["name"], "Extra.esp")
            self.assertEqual(p["placement"], "extras")
            self.assertEqual(p["status"], "undetermined")
            self.assertEqual(p["path"], f"Extras/{name}/optional/Extra.esp")
            self.assertIn("Extras/", p["reason"])
            self.assertFalse((root / "Extra.esp").exists())
            self.assertFalse((root / "optional/Extra.esp").exists())
            self.assertTrue((root / p["path"]).is_file())
            self.assertTrue((root / f"Off/{name}/OpenMW/optional/Extra.esp").is_file())

    def test_subfolder_omwaddon_is_renamed_in_extras(self):
        from omw2mwse.tes3 import scpt
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = make_staged(root, lua="""\
local world = require('openmw.world')
return { engineHandlers = { onUpdate = function()
    world.mwscript.getGlobalScript("needme")
end } }
""")
            self._write_plugin(src / "legacy" / "NeedMe.omwaddon", [scpt("needme")])
            r = convert(root, "normal")
            name = r["mods"][0]["name"]
            p = self._plug(r)
            self.assertEqual(p["name"], "NeedMe.esp")
            self.assertEqual(p["source"], "NeedMe.omwaddon")
            self.assertEqual(p["placement"], "extras")
            self.assertEqual(p["status"], "required")
            self.assertEqual(p["path"], f"Extras/{name}/legacy/NeedMe.esp")
            self.assertTrue((root / p["path"]).is_file())
            self.assertFalse((root / "NeedMe.esp").exists())
            self.assertTrue((root / f"Off/{name}/OpenMW/legacy/NeedMe.omwaddon").is_file())

    def test_live_and_dead_refs_make_root_plugin_required(self):
        from omw2mwse.tes3 import named
        lua = """\
local core = require('openmw.core')
local old_API = core.API_REVISION < 59
local function onInit()
    if old_API then
        local a = "my_special_light"
    end
    local b = "my_special_light"
end
return { engineHandlers = { onInit = onInit } }
"""
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = make_staged(root, lua=lua)
            self._write_plugin(src / "Lights.esp", [named("LIGH", "my_special_light")])
            p = self._plug(convert(root, "normal"))
            self.assertEqual(p["placement"], "root")
            self.assertEqual(p["status"], "required")
            self.assertTrue((root / "Lights.esp").is_file())
