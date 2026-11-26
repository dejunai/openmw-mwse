"""Unit tests for the omw2mwse CLI (stdlib unittest)."""
import hashlib
import io
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from omw2mwse.cli import main  # noqa: E402
from omw2mwse.luatok import tokenize  # noqa: E402
from omw2mwse.package import PackageError, default_slug, mesh_alias, package  # noqa: E402
from omw2mwse.scan import classify, load_manifest, normalize_mesh, parse_omwscripts, scan_lua, scan_mod  # noqa: E402

MANIFEST = load_manifest()
METHODS = set(MANIFEST["gameObject"]["methods"])

SAMPLE = """\
-- comment with require('openmw.ui')
--[==[ long comment
local ui = require('openmw.ui')
]==]
local world = require('openmw.world')
local types = require("openmw.types")
local I = require 'openmw.interfaces'
local core = require('openmw.core')
local Light = types.Light
local s = [[ a string with world.mwscript ]]
local function f(obj, actor)
  local o = world.createObject("x", 1)
  o:teleport(obj.cell, obj.position)
  obj:remove()
  if Light.objectIsInstance(obj) then core.sendGlobalEvent("E", {}) end
  local w = world.mwscript.getGlobalVariables()
  return 'meshes/l/x.nif', "meshes/very/long/path/that/is/over/31/chars.nif"
end
I.Activation.addHandlerForType(types.Light, f)
return { engineHandlers = { onUpdate = f, onKeyPress = f }, eventHandlers = { E = f } }
"""


class TokenizerTests(unittest.TestCase):
    def test_comments_and_long_strings_are_skipped(self):
        toks = tokenize(SAMPLE)
        names = [t.value for t in toks if t.kind == "name"]
        self.assertNotIn("ui", names)
        strings = [t.value for t in toks if t.kind == "string"]
        self.assertIn(" a string with world.mwscript ", strings)

    def test_escapes_and_lines(self):
        toks = tokenize('local a = "x\\"y\\n" -- c\nlocal b = 0x1F + 1.5e3')
        self.assertEqual(toks[3].value, 'x"y\n')
        self.assertEqual([t.value for t in toks if t.kind == "number"], ["0x1F", "1.5e3"])
        self.assertEqual(toks[-1].line, 2)

    def test_symbols(self):
        vals = [t.value for t in tokenize("a ~= b .. c ... ::lbl:: d == e")]
        for s in ("~=", "..", "...", "::", "=="):
            self.assertIn(s, vals)


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.fs = scan_lua(SAMPLE, "x.lua", METHODS)

    def test_aliases_and_uses(self):
        self.assertEqual(self.fs.requires["world"], "openmw.world")
        self.assertIn("openmw.world.createObject", self.fs.uses)
        self.assertIn("openmw.types.Light.objectIsInstance", self.fs.uses)  # via local Light = types.Light
        self.assertIn("openmw.interfaces.Activation.addHandlerForType", self.fs.uses)
        self.assertIn("openmw.world.mwscript.getGlobalVariables", self.fs.uses)
        self.assertNotIn("openmw.ui", self.fs.requires.values())

    def test_methods_handlers_meshes(self):
        self.assertEqual(self.fs.methods.get("teleport"), 1)
        self.assertEqual(self.fs.methods.get("remove"), 1)
        self.assertEqual(sorted(self.fs.engine_handlers), ["onKeyPress", "onUpdate"])
        self.assertEqual(self.fs.event_handlers, ["E"])
        self.assertEqual(len(self.fs.meshes), 2)

    def test_classify(self):
        self.assertEqual(classify("openmw.world.createObject", MANIFEST), "full")
        self.assertEqual(classify("openmw.world.mwscript.getGlobalVariables", MANIFEST), "unsupported")
        self.assertEqual(classify("openmw.world.doesNotExist", MANIFEST), "unsupported")
        self.assertEqual(classify("openmw.ui.showMessage", MANIFEST), "unsupported")
        self.assertEqual(classify("openmw.interfaces.SomeMod.fn", MANIFEST), "interface")
        self.assertEqual(classify("openmw.types.Light", MANIFEST), "full")
        self.assertEqual(classify("openmw.core.weather.getCurrent", MANIFEST), "partial")
        self.assertEqual(classify("mylib.helper", MANIFEST), "local")

    def test_omwscripts(self):
        e = parse_omwscripts("# c\nGLOBAL: scripts/a.lua\nPLAYER, NPC : scripts\\b.lua\n\n")
        self.assertEqual([x.flags for x in e], [["GLOBAL"], ["PLAYER", "NPC"]])
        self.assertEqual(e[1].path, "scripts/b.lua")

    def test_normalize_mesh(self):
        self.assertEqual(normalize_mesh("Meshes\\L\\X.nif"), "l/x.nif")


def _make_mod(d: Path, script_src: str = SAMPLE, flags: str = "GLOBAL"):
    (d / "scripts" / "M").mkdir(parents=True)
    (d / "scripts" / "M" / "m.lua").write_text(script_src, encoding="utf-8")
    (d / "M.omwscripts").write_text(f"{flags}: scripts/M/m.lua\n", encoding="utf-8")


class ModScanTests(unittest.TestCase):
    def test_blockers(self):
        with tempfile.TemporaryDirectory() as t:
            _make_mod(Path(t), flags="GLOBAL, PLAYER")
            s = scan_mod(Path(t), MANIFEST)
            self.assertEqual(s.verdict, "blocked")
            text = "\n".join(s.blockers)
            self.assertIn("openmw.world.mwscript", text)
            self.assertIn("onKeyPress", text)
            self.assertIn("PLAYER", text)

    def test_ltlo_reference_is_ready(self):
        ref = ROOT / "reference" / "openmw_original"
        if not ref.exists():
            self.skipTest("reference/ not present (git-ignored)")
        s = scan_mod(ref, MANIFEST)
        self.assertEqual(s.verdict, "ready", s.blockers)

    def test_undeclared_lua_does_not_block(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            _make_mod(root, script_src="local world = require('openmw.world')\nreturn {}\n")
            (root / "scripts" / "M" / "debug.lua").write_text(
                "local ui = require('openmw.ui')\nlocal input = require('openmw.input')\nreturn {}\n",
                encoding="utf-8",
            )
            s = scan_mod(root, MANIFEST)
            self.assertEqual(s.verdict, "ready", s.blockers)
            self.assertTrue(any("debug.lua" in w and "ignored for the verdict" in w for w in s.warnings), s.warnings)

    def test_required_local_module_can_block(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = "local d = require('scripts.M.debug')\nlocal world = require('openmw.world')\nreturn {}\n"
            _make_mod(root, script_src=src)
            (root / "scripts" / "M" / "debug.lua").write_text(
                "local ui = require('openmw.ui')\nreturn {}\n",
                encoding="utf-8",
            )
            s = scan_mod(root, MANIFEST)
            self.assertEqual(s.verdict, "blocked", s.blockers)
            self.assertTrue(any("openmw.ui" in b for b in s.blockers), s.blockers)

    def test_omwscripts_in_subdir_resolves_declared_paths(self):
        """Declared paths are relative to the .omwscripts parent, not the scan root."""
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            src = root / "mod"
            (src / "scripts" / "X").mkdir(parents=True)
            (src / "scripts" / "X" / "g.lua").write_text(
                "local h = require('scripts.X.helper')\nlocal world = require('openmw.world')\nreturn {}\n",
                encoding="utf-8",
            )
            (src / "scripts" / "X" / "helper.lua").write_text(
                "local types = require('openmw.types')\nreturn {}\n", encoding="utf-8",
            )
            (src / "scripts" / "X" / "debug.lua").write_text(
                "local ui = require('openmw.ui')\nreturn {}\n", encoding="utf-8",
            )
            (src / "X.omwscripts").write_text("GLOBAL: scripts/X/g.lua\n", encoding="utf-8")
            s = scan_mod(root, MANIFEST)
            self.assertEqual(s.verdict, "ready", s.blockers)
            self.assertTrue(any("debug.lua" in w and "ignored for the verdict" in w for w in s.warnings), s.warnings)
            self.assertFalse(any("helper.lua" in w for w in s.warnings), s.warnings)

    def test_official_ltlo_32_is_ready(self):

        src = ROOT / "corpus" / "leave-the-lights-off" / "_archive" / "full" / "LeaveTheLightsOff"
        if not (src / "LeaveTheLightsOff.omwscripts").is_file():
            self.skipTest("official LTLO 3.2 extract not present (git-ignored corpus)")
        s = scan_mod(src, MANIFEST)
        self.assertEqual(s.verdict, "ready", s.blockers)
        self.assertTrue(any("ui_debugWidget.lua" in w and "ignored for the verdict" in w for w in s.warnings), s.warnings)


LOCAL_SRC = """\
local self = require('openmw.self')
local nearby = require('openmw.nearby')
local types = require('openmw.types')
local I = require('openmw.interfaces')
local function tick()
  if types.Actor.stats.dynamic.health(self).current < 1 or types.Actor.isDead(self) then return end
  local p = I.AI.getActivePackage()
  for _, a in ipairs(nearby.actors) do
    if a.type == types.NPC and types.Actor.stats.ai.fight(self).modified > 80 then
      I.AI.startPackage({ type = 'Combat', target = a })
    end
  end
end
return { engineHandlers = { onUpdate = tick, onActive = tick } }
"""


class LocalScriptScanTests(unittest.TestCase):
    def test_creature_script_with_self_nearby_ai_is_ready(self):
        with tempfile.TemporaryDirectory() as t:
            _make_mod(Path(t), script_src=LOCAL_SRC, flags="CREATURE")
            s = scan_mod(Path(t), MANIFEST)
            self.assertEqual(s.verdict, "ready", s.blockers)
            self.assertEqual(s.symbols["openmw.interfaces.AI.startPackage"]["status"], "partial")

    def test_local_modules_in_a_global_script_block(self):
        with tempfile.TemporaryDirectory() as t:
            _make_mod(Path(t), script_src=LOCAL_SRC, flags="GLOBAL")
            s = scan_mod(Path(t), MANIFEST)
            self.assertEqual(s.verdict, "blocked")
            text = "\n".join(s.blockers)
            self.assertIn("openmw.self is only available to local scripts", text)
            self.assertIn("I.AI is only available to actor scripts", text)

    def test_world_in_a_local_script_blocks(self):
        with tempfile.TemporaryDirectory() as t:
            _make_mod(Path(t), script_src="local world = require('openmw.world')\nreturn {}\n", flags="NPC")
            s = scan_mod(Path(t), MANIFEST)
            self.assertTrue(any("openmw.world is only available to global scripts" in b for b in s.blockers), s.blockers)

    def test_ai_in_a_door_script_blocks(self):
        with tempfile.TemporaryDirectory() as t:
            src = "local I = require('openmw.interfaces')\nI.AI.getActivePackage()\nreturn {}\n"
            _make_mod(Path(t), script_src=src, flags="DOOR")
            s = scan_mod(Path(t), MANIFEST)
            self.assertTrue(any("I.AI is only available to actor scripts" in b for b in s.blockers), s.blockers)

    def test_builtin_interfaces_are_checked_mod_interfaces_are_optional(self):
        self.assertEqual(classify("openmw.interfaces.UI.getMode", MANIFEST), "unsupported")
        self.assertEqual(classify("openmw.interfaces.AI.getActivePackage", MANIFEST), "partial")
        self.assertEqual(classify("openmw.interfaces.AI.forEachPackage", MANIFEST), "unsupported")
        self.assertEqual(classify("openmw.interfaces.SomeMod.fn", MANIFEST), "interface")
        self.assertEqual(classify("openmw.self.controls", MANIFEST), "unsupported")
        self.assertEqual(classify("openmw.nearby.castRay", MANIFEST), "unsupported")

    def test_wildlife_19_is_ready(self):
        src = ROOT / "corpus" / "wildlife-attacks-npcs-too" / "_archive" / "full"
        if not (src / "wildlife_attacks_npc.omwscripts").is_file():
            self.skipTest("Wildlife Attacks NPCs Too extract not present (git-ignored corpus)")
        s = scan_mod(src, MANIFEST)
        self.assertEqual(s.verdict, "ready", s.blockers)


from omw2mwse.convert import convert as convert_staged  # noqa: E402
from omw2mwse.optout import REASON_CODE, header_opt_out_line  # noqa: E402

GLOBAL_SRC = "local world = require('openmw.world')\nreturn {}\n"


class OptOutTests(unittest.TestCase):
    def test_header_line_comment(self):
        self.assertEqual(header_opt_out_line("-- My mod\n-- mwsuite conversion opt-out\nlocal x = 1\n"), 2)

    def test_block_comment(self):
        src = "--[[\n  My mod by someone\n  mwsuite conversion opt-out\n]]\nlocal x = 1\n"
        self.assertEqual(header_opt_out_line(src), 3)
        self.assertEqual(header_opt_out_line("--[==[ x ]] mwsuite conversion opt-out ]==]\nreturn 1\n"), 1)

    def test_blank_lines_bom_and_shebang_allowed(self):
        src = "\ufeff#!/usr/bin/env lua\n\n   \n-- header\n\n--mwsuite conversion opt-out\nreturn 1\n"
        self.assertEqual(header_opt_out_line(src), 6)

    def test_case_and_whitespace_variants(self):
        for phrase in ("MWSuite Conversion Opt-Out", "mwsuite   conversion\topt - out", "MWSUITE CONVERSION OPT OUT",
                       "please: mwsuite conversion opt-out."):
            self.assertEqual(header_opt_out_line(f"-- {phrase}\nreturn 1\n"), 1, phrase)

    def test_after_code_does_not_count(self):
        self.assertIsNone(header_opt_out_line("local x = 1\n-- mwsuite conversion opt-out\n"))
        self.assertIsNone(header_opt_out_line("-- header\nreturn {} -- mwsuite conversion opt-out\n"))
        self.assertIsNone(header_opt_out_line("print('x')\n--[[ mwsuite conversion opt-out ]]\n"))
        self.assertIsNone(header_opt_out_line("local s = '-- mwsuite conversion opt-out'\n"))
        self.assertIsNone(header_opt_out_line("-- mwsuite conversion\n-- opt-out\nreturn 1\n"))

    def test_scan_blocks_with_reason(self):
        with tempfile.TemporaryDirectory() as t:
            _make_mod(Path(t), script_src="-- mwsuite conversion opt-out\n" + GLOBAL_SRC)
            s = scan_mod(Path(t), MANIFEST)
            self.assertEqual(s.verdict, "blocked")
            self.assertEqual(s.opt_out["code"], REASON_CODE)
            self.assertEqual((s.opt_out["file"], s.opt_out["line"]), ("scripts/M/m.lua", 1))
            self.assertTrue(s.blockers[0].startswith(REASON_CODE + ": scripts/M/m.lua:1"))
            self.assertEqual(s.to_dict()["optOut"]["code"], REASON_CODE)

    def test_undeclared_lua_opts_out_and_convert_writes_nothing(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            _make_mod(root, script_src=GLOBAL_SRC)
            (root / "scripts" / "M" / "notes.lua").write_text("--[[ mwsuite conversion opt-out ]]\n", encoding="utf-8")
            before = sorted(p.relative_to(root).as_posix() for p in root.rglob("*"))
            r = convert_staged(root, "normal")
            after = sorted(p.relative_to(root).as_posix() for p in root.rglob("*"))
            self.assertEqual(before, after)
            m = r["mods"][0]
            self.assertEqual(m["verdict"], "blocked")
            self.assertEqual(m["reason"], {"code": REASON_CODE, "file": "scripts/M/notes.lua", "line": 1,
                                           "message": m["reason"]["message"]})
            self.assertEqual(m["alerts"][0]["code"], REASON_CODE)
            self.assertFalse(r["changed"])
            self.assertEqual(r["exitCode"], 0)

    def test_package_refuses(self):
        with tempfile.TemporaryDirectory() as t:
            src = Path(t) / "src"
            _make_mod(src, script_src="-- mwsuite conversion opt-out\n" + GLOBAL_SRC)
            with self.assertRaises(PackageError):
                package(src, Path(t) / "out", name="M")
            self.assertFalse((Path(t) / "out").exists())

    def test_no_phrase_still_converts(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            _make_mod(root, script_src="local x = 1\n-- mwsuite conversion opt-out\n" + GLOBAL_SRC)
            r = convert_staged(root, "normal")
            self.assertEqual(r["mods"][0]["verdict"], "ready")
            self.assertNotIn("reason", r["mods"][0])


class PackageTests(unittest.TestCase):
    def test_slug_and_alias(self):
        self.assertEqual(default_slug("LeaveTheLightsOff"), "ltlo")
        a = mesh_alias("ltlo", "dlr/light_de_streetlight_01_off99.nif")
        self.assertLessEqual(len(a), 31)
        self.assertTrue(a.startswith("omwc/ltlo/"))

    def test_package_roundtrip(self):
        with tempfile.TemporaryDirectory() as t:
            src, out = Path(t) / "src", Path(t) / "out"
            src.mkdir()
            _make_mod(src)
            before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in src.rglob("*") if p.is_file()}
            r = package(src, out, name="M")
            after = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in src.rglob("*") if p.is_file()}
            self.assertEqual(before, after)
            data = out / "Data Files"
            copied = data / "MWSE" / "mods" / "mwsuite" / "openmw" / "M" / "omw" / "scripts" / "M" / "m.lua"
            self.assertEqual(copied.read_bytes(), (src / "scripts" / "M" / "m.lua").read_bytes())
            off = data / "Off" / "M" / "OpenMW"
            self.assertEqual((off / "scripts" / "M" / "m.lua").read_bytes(), (src / "scripts" / "M" / "m.lua").read_bytes())
            self.assertEqual((off / "M.omwscripts").read_bytes(), (src / "M.omwscripts").read_bytes())
            self.assertFalse((data / "Off" / "OpenMW").exists())
            main_lua = (data / "MWSE" / "mods" / "mwsuite" / "openmw" / "M" / "main.lua").read_text(encoding="utf-8")
            self.assertIn('path = "scripts/M/m.lua"', main_lua)
            self.assertIn('root = "Data Files/MWSE/mods/mwsuite/openmw/M/omw/"', main_lua)
            self.assertFalse((data / "MWSE" / "mods" / "M").exists())
            self.assertFalse((data / "MWSE" / "omw").exists())
            self.assertIn("very/long/path/that/is/over/31/chars.nif", main_lua)
            self.assertTrue((data / "MWSE" / "lib" / "omwcompat.lua").exists())
            self.assertTrue((data / "MWSE" / "lib" / "omwcompat" / "runtime.lua").exists())
            self.assertTrue((data / "M-metadata.toml").read_text(encoding="utf-8").find('lua-mod = "mwsuite.openmw.M"') >= 0)
            raw = (data / "MWSE" / "mods" / "mwsuite" / "openmw" / "M" / "main.lua").read_bytes()
            self.assertFalse(raw.startswith(b"\xef\xbb\xbf"))
            self.assertNotIn(b"\r\n", raw)
            self.assertEqual(len(r["aliases"]), 1)
            # refuses to overwrite without --force; --force replaces only its own output
            with self.assertRaises(PackageError):
                package(src, out, name="M")
            package(src, out, name="M", force=True)
            foreign = Path(t) / "foreign"
            foreign.mkdir()
            (foreign / "keep.txt").write_text("x")
            with self.assertRaises(PackageError):
                package(src, foreign, name="M", force=True)
            self.assertTrue((foreign / "keep.txt").exists())
            with self.assertRaises(PackageError):
                package(src, src / "inside", name="M")

    def test_alias_copied_from_source_meshes(self):
        """Long meshes that already live in the source tree get aliases without --meshes-from."""
        with tempfile.TemporaryDirectory() as t:
            src, out = Path(t) / "src", Path(t) / "out"
            src.mkdir()
            _make_mod(src)
            long_rel = "very/long/path/that/is/over/31/chars.nif"
            mesh = src / "meshes" / long_rel
            mesh.parent.mkdir(parents=True)
            mesh.write_bytes(b"NIFSRC")
            r = package(src, out, name="M")
            alias = r["aliases"][0][1]
            self.assertEqual(r["aliases"][0][2], "copied")
            self.assertEqual((out / "Data Files" / "meshes" / alias).read_bytes(), b"NIFSRC")
            self.assertEqual((out / "Data Files" / "meshes" / long_rel).read_bytes(), b"NIFSRC")
            self.assertFalse(any(a.get("code") == "mesh-missing" for a in r["alerts"]))

    def test_meshes_from(self):

        with tempfile.TemporaryDirectory() as t:
            src, out, meshes = Path(t) / "src", Path(t) / "out", Path(t) / "meshes"
            src.mkdir()
            _make_mod(src)
            p = meshes / "very/long/path/that/is/over/31/chars.nif"
            p.parent.mkdir(parents=True)
            p.write_bytes(b"NIF")
            r = package(src, out, name="M", meshes_from=meshes)
            alias = r["aliases"][0][1]
            self.assertEqual((out / "Data Files" / "meshes" / alias).read_bytes(), b"NIF")

    def test_original_package_and_game_meshes(self):
        with tempfile.TemporaryDirectory() as t:
            src, out = Path(t) / "src", Path(t) / "out"
            src.mkdir()
            _make_mod(src)
            mesh = src / "meshes" / "light_off99.nif"
            mesh.parent.mkdir()
            mesh.write_bytes(b"NIFSHORT")
            (src / "readme.txt").write_text("hi", encoding="utf-8")
            r = package(src, out, name="M")
            data = out / "Data Files"
            off = data / "Off" / "M" / "OpenMW"
            self.assertEqual((off / "meshes" / "light_off99.nif").read_bytes(), b"NIFSHORT")
            self.assertEqual((data / "meshes" / "light_off99.nif").read_bytes(), b"NIFSHORT")
            self.assertEqual((off / "readme.txt").read_text(encoding="utf-8"), "hi")
            self.assertFalse((data / "readme.txt").exists())  # not a game asset; stays under Off/ only
            # source tree is never modified by package
            self.assertTrue((src / "meshes" / "light_off99.nif").exists())
            self.assertFalse((data / "Off" / "OpenMW").exists())
            self.assertTrue(any(rel.endswith("light_off99.nif") for rel in r["result"].off_copied))

    def test_cli(self):
        with tempfile.TemporaryDirectory() as t:
            src = Path(t) / "src"
            src.mkdir()
            _make_mod(src)
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = main(["scan", str(src), "--strict"])
            self.assertEqual(rc, 1)
            self.assertIn("blocked", buf.getvalue())
            with redirect_stdout(io.StringIO()):
                rc = main(["package", str(src), "--out", str(Path(t) / "o"), "--name", "M"])
            self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
