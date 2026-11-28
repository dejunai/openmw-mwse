"""omw2mwse 0.3.0 / omwcompat 0.4.0: runtime files are written with LF line ends, PLAYER and
CUSTOM scripts are hosted, legacy symbols are still accepted (stdlib unittest; Python 3.9+).
Written for omw2mwse by dej (dejunai)."""
from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import omw2mwse  # noqa: E402
from omw2mwse import build as B  # noqa: E402
from omw2mwse.package import package  # noqa: E402
from omw2mwse.scan import classify, load_manifest, scan_mod  # noqa: E402

MANIFEST = load_manifest()


def make_mod(root: Path, files: dict, omwscripts: str) -> None:
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(text.encode("utf-8"))
    (root / "M.omwscripts").write_bytes(omwscripts.encode("utf-8"))


class Versions(unittest.TestCase):
    def test_versions(self):
        self.assertEqual(omw2mwse.__version__, "0.3.2")
        self.assertEqual(MANIFEST["version"], "0.5.0")
        self.assertEqual(B.runtime_version(), "0.5.0")
        rt = (ROOT / "runtime/MWSE/lib/omwcompat/runtime.lua").read_text(encoding="utf-8")
        self.assertIn('VERSION = "0.5.0"', rt)


class RuntimeLineEnds(unittest.TestCase):
    def test_runtime_file_bytes_normalizes_text(self):
        with tempfile.TemporaryDirectory() as t:
            lua = Path(t) / "x.lua"
            lua.write_bytes(b"\xef\xbb\xbfa = 1\r\nb = 2\r\n")
            self.assertEqual(B.runtime_file_bytes(lua), b"a = 1\nb = 2\n")
            js = Path(t) / "m.json"
            js.write_bytes(b'{\r\n "a": 1\r\n}\r\n')
            self.assertEqual(B.runtime_file_bytes(js), b'{\n "a": 1\n}\n')
            nif = Path(t) / "m.nif"
            nif.write_bytes(b"NIF\r\n\x00\r\n")
            self.assertEqual(B.runtime_file_bytes(nif), b"NIF\r\n\x00\r\n")  # binary: untouched

    def test_package_writes_lf_runtime_from_a_crlf_checkout(self):
        # a Windows clone with core.autocrlf=true has CRLF in runtime/: the package must not
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            lib = t / "lib"
            shutil.copytree(B.RUNTIME_LIB, lib)
            for f in lib.rglob("*"):
                if f.is_file() and f.suffix in (".lua", ".json"):
                    f.write_bytes(f.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
            self.assertIn(b"\r\n", (lib / "omwcompat" / "runtime.lua").read_bytes())
            src = t / "src"
            make_mod(src, {"scripts/M/g.lua": "return { engineHandlers = { onUpdate = function() end } }\n"},
                     "GLOBAL: scripts/M/g.lua\n")
            old = B.RUNTIME_LIB
            B.RUNTIME_LIB = lib
            try:
                package(src, t / "out", name="M")
            finally:
                B.RUNTIME_LIB = old
            written = list((t / "out").rglob("omwcompat*")) + list((t / "out").rglob("omwcompat/*"))
            files = [f for f in written if f.is_file()]
            self.assertTrue(any(f.name == "runtime.lua" for f in files))
            for f in files:
                self.assertNotIn(b"\r", f.read_bytes(), f.name)
            for f in (t / "out").rglob("main.lua"):
                self.assertNotIn(b"\r", f.read_bytes())


class PlayerAndCustomHosting(unittest.TestCase):
    def scan(self, files: dict, omwscripts: str):
        with tempfile.TemporaryDirectory() as t:
            make_mod(Path(t), files, omwscripts)
            return scan_mod(Path(t), MANIFEST)

    def test_player_script_with_show_message_and_keys_is_hosted(self):
        s = self.scan({"scripts/M/p.lua": (
            "local ui = require('openmw.ui')\nlocal input = require('openmw.input')\n"
            "local ambient = require('openmw.ambient')\n"
            "return { engineHandlers = {\n"
            "  onKeyPress = function(k) if k.code == input.KEY.H then ui.showMessage('hi') end end,\n"
            "  onFrame = function() end,\n"
            "  onQuestUpdate = function(q, s) ambient.playSound('Fire') end,\n} }\n")},
            "PLAYER: scripts/M/p.lua\n")
        self.assertNotEqual(s.verdict, "blocked", s.blockers)
        self.assertEqual(s.flags["PLAYER"], "partial")
        self.assertEqual(s.handlers["onFrame"], "full")
        self.assertEqual(s.handlers["onKeyPress"], "partial")
        apis = {p["api"]: p["missing"] for p in s.partial_apis}
        self.assertIn("tes3.messageBox", apis["openmw.ui.showMessage"])
        self.assertIn("outside menus", apis["engineHandler:onKeyPress"])

    def test_ui_layouts_stay_blocked_animation_does_not(self):
        s = self.scan({"scripts/M/p.lua": (
            "local ui = require('openmw.ui')\nlocal anim = require('openmw.animation')\n"
            "return { engineHandlers = { onFrame = function() ui.create({}) ; anim.playBlended(nil, 'x', {}) end } }\n")},
            "PLAYER: scripts/M/p.lua\n")
        self.assertEqual(s.verdict, "blocked")
        text = "\n".join(s.blockers)
        self.assertIn("openmw.ui.create", text)
        self.assertNotIn("openmw.animation", text)  # 0.5.0: mapped / stubbed, never a blocker

    def test_custom_scripts_and_add_script(self):
        s = self.scan({
            "scripts/M/g.lua": ("local world = require('openmw.world')\nlocal types = require('openmw.types')\n"
                                "return { engineHandlers = { onActorActive = function(a)\n"
                                "  if not a:hasScript('scripts/M/c.lua') then a:addScript('scripts/M/c.lua', { x = 1 }) end\n"
                                "end } }\n"),
            "scripts/M/c.lua": ("local self = require('openmw.self')\nlocal types = require('openmw.types')\n"
                                "return { engineHandlers = { onInit = function(d)\n"
                                "  local eq = types.Actor.getEquipment(self)\n"
                                "  eq[types.Actor.EQUIPMENT_SLOT.Robe] = d.robe\n"
                                "  types.Actor.setEquipment(self, eq)\n"
                                "end } }\n")},
            "GLOBAL: scripts/M/g.lua\nCUSTOM: scripts/M/c.lua\n")
        self.assertNotEqual(s.verdict, "blocked", s.blockers)
        self.assertEqual(s.flags["CUSTOM"], "partial")
        self.assertEqual(s.methods["addScript"]["status"], "partial")

    def test_menu_flag_is_still_not_hosted(self):
        s = self.scan({"scripts/M/m.lua": "return {}\n"}, "MENU: scripts/M/m.lua\n")
        self.assertEqual(s.verdict, "blocked")


class ManifestEntries(unittest.TestCase):
    def test_stale_entries_moved_to_legacy(self):
        for k in ("openmw.async.newRealTimer", "openmw.self.ownerRecordId", "openmw.types.Actor.record",
                  "openmw.types.Item.records", "openmw.types.Player.equipment"):
            self.assertNotIn(k, MANIFEST["symbols"])
            self.assertIn(k, MANIFEST["legacySymbols"])
            self.assertEqual(classify(k, MANIFEST), "partial")

    def test_new_game_object_members(self):
        go = MANIFEST["gameObject"]
        self.assertNotIn("ownerRecordId", go["fields"])
        for f in ("owner", "startingCell", "globalVariable"):
            self.assertIn(f, go["fields"])
        self.assertEqual(MANIFEST["symbols"]["openmw.self.globalVariable"], "unsupported")
        for m in ("addScript", "removeScript", "hasScript"):
            self.assertEqual(go["methods"][m], "partial")

    def test_new_symbols(self):
        for k, v in {"openmw.core.factions.records": "partial", "openmw.core.sound.playSound3d": "partial",
                     "openmw.nearby.castRay": "partial", "openmw.types.Actor.getStance": "partial",
                     "openmw.types.NPC.stats.skills.block": "partial", "openmw.types.Player.quests": "partial",
                     "openmw.types.Lockable.lock": "full"}.items():
            self.assertEqual(classify(k, MANIFEST), v, k)
        self.assertNotIn("openmw.ui", MANIFEST["unsupportedModules"])
        self.assertNotIn("openmw.animation", MANIFEST["unsupportedModules"])  # 0.5.0
        self.assertIn("Enabled switch", MANIFEST["notes"])

    def test_manifest_is_ascii_lf_no_bom(self):
        raw = (B.RUNTIME_LIB / "omwcompat" / "manifest.json").read_bytes()
        self.assertFalse(raw.startswith(b"\xef\xbb\xbf"))
        raw.decode("ascii")
        json.loads(raw.decode("utf-8"))


class SelfTypeFallback(unittest.TestCase):
    def test_self_type_uses_player_and_npc_members(self):
        from omw2mwse.scan import classify, load_manifest
        m = load_manifest()
        # Actor member
        self.assertEqual(classify("openmw.self.type.stats.skills.block", m), "partial")
        # Player-only member (PLAYER scripts): no longer a false blocker
        self.assertEqual(classify("openmw.self.type.isCharGenFinished", m), "full")
        # still unsupported everywhere
        self.assertEqual(classify("openmw.self.type.sendMenuEvent", m), "unsupported")


if __name__ == "__main__":
    unittest.main()
