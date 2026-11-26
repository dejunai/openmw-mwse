"""api-audit and the optional OpenMW API catalog (0.2.5).

Uses tests/fixtures/openmw-api-stubs: a tiny hand-written stub set in OpenMW's LDT tag format (our own
text, not OpenMW's files). No network: fetch() is given a fake downloader."""
from __future__ import annotations

import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from omw2mwse import apicatalog as AC  # noqa: E402
from omw2mwse.cli import main  # noqa: E402
from omw2mwse.scan import load_manifest, scan_mod  # noqa: E402

STUBS = ROOT / "tests" / "fixtures" / "openmw-api-stubs"
SRC = STUBS / "files" / "lua_api" / "openmw"
FORMS = ROOT / "tests" / "fixtures" / "scanner-forms"

TINY = {
    "version": "test",
    "symbols": {"openmw.core.sendGlobalEvent": "full", "openmw.core.API_REVISION": "full",
                "openmw.types.Actor.isDead": "full", "openmw.types.Actor.inventory": "partial",
                "openmw.types.Actor.fly2": "full", "openmw.self.teleport": "partial",
                "openmw.world.players": "full", "openmw_aux.util.x": "full"},
    "unsupportedModules": [],
    "gameObject": {"methods": {"isValid": "full", "teleport": "partial", "oldMethod": "full"},
                   "fields": ["recordId", "position"]},
    "builtinInterfaces": {"Activation": "full", "Ours": "full"},
}


def run(argv, env=None):
    buf = io.StringIO()
    with mock.patch.dict(os.environ, env or {}), redirect_stdout(buf):
        rc = main(argv)
    return rc, buf.getvalue()


def install_layout(root: Path) -> Path:
    d = root / "resources" / "lua_api" / "openmw"
    d.mkdir(parents=True)
    for f in SRC.glob("*.lua"):
        shutil.copy(f, d / f.name)
    (root / "resources" / "version").write_text("1.2.3\nabcdef\n", encoding="utf-8")
    return root


class Parse(unittest.TestCase):
    def setUp(self):
        self.cat = AC.load(STUBS)

    def test_source_layout_and_version(self):
        info = self.cat.info()
        self.assertEqual(info["layout"], "source")
        self.assertEqual(info["version"], "9.8.7")
        self.assertEqual(info["apiRevision"], 42)
        self.assertEqual(info["files"], 7)

    def test_install_layout(self):
        with tempfile.TemporaryDirectory() as t:
            cat = AC.load(install_layout(Path(t)))
            self.assertEqual(cat.info()["layout"], "install")
            self.assertEqual(cat.info()["version"], "1.2.3")
            self.assertTrue(cat.has("openmw.core.sendGlobalEvent"))

    def test_has(self):
        c = self.cat
        self.assertTrue(c.has("openmw.core.sendGlobalEvent"))
        self.assertTrue(c.has("openmw.core.sound.playSound3d"))
        self.assertTrue(c.has("openmw.types.NPC.isDead"))           # @extends #Actor
        self.assertTrue(c.has("openmw.self.isValid"))               # Self extends GameObject
        self.assertTrue(c.has("openmw.self.ATTACK_TYPE.Any"))       # enum type not attached as a field
        self.assertFalse(c.has("openmw.self.ATTACK_TYPE.Nope"))
        self.assertFalse(c.has("openmw.core.nope"))
        self.assertFalse(c.has("openmw.nomodule.x"))
        self.assertIsNone(c.has("openmw.interfaces.SomeModInterface.go"))  # mods add interfaces
        self.assertIsNone(c.has("openmw_aux.util.x"))

    def test_contexts_methods_scope(self):
        c = self.cat
        self.assertEqual(c.contexts["world"], ["global"])
        self.assertTrue(c.has_method("Cell:getAll"))
        self.assertTrue(c.has_method("Inventory:countOf"))
        self.assertFalse(c.has_method("Inventory:findAll"))
        self.assertIsNone(c.has_method("Mystery:x"))
        self.assertIn("getYaw", c.type_members("Transform"))


class Locate(unittest.TestCase):
    def test_env_none(self):
        with mock.patch.dict(os.environ, {AC.ENV_DIR: "none"}):
            cat, searched = AC.locate()
        self.assertIsNone(cat)
        self.assertIn("none", searched[0])

    def test_explicit_env_cache(self):
        with tempfile.TemporaryDirectory() as t:
            cat, _ = AC.locate(STUBS)
            self.assertEqual(cat.info()["version"], "9.8.7")
            cat, _ = AC.locate(Path(t) / "missing")
            self.assertIsNone(cat)
            with mock.patch.dict(os.environ, {AC.ENV_DIR: str(STUBS)}):
                self.assertIsNotNone(AC.locate()[0])
            cache = Path(t) / "cache"
            for v in ("0.9.0", "0.10.0"):
                shutil.copytree(STUBS / "files", cache / v / "files")
            env = {k: v for k, v in os.environ.items() if k != AC.ENV_DIR}
            with mock.patch.dict(os.environ, env, clear=True):
                cat, searched = AC.locate(cache_root=cache, use_installs=False)
            self.assertTrue(str(cat.info()["root"]).endswith("0.10.0"))
            self.assertEqual(searched, [str(cache)])


class Fetch(unittest.TestCase):
    def fake(self, calls):
        listing = [{"name": f.name, "type": "file"} for f in sorted(SRC.glob("*.lua"))]
        listing.append({"name": "README.md", "type": "file"})

        def get(url):
            calls.append(url)
            if "api.github.com" in url:
                return json.dumps(listing).encode()
            if url.endswith("CMakeLists.txt"):
                return (STUBS / "CMakeLists.txt").read_bytes()
            return (SRC / url.rsplit("/", 1)[1]).read_bytes()
        return get

    def test_fetch_only_stub_files(self):
        with tempfile.TemporaryDirectory() as t:
            calls = []
            dest = AC.fetch("0.51.0", cache_root=t, get=self.fake(calls))
            self.assertEqual(dest, Path(t) / "0.51.0")
            self.assertTrue(any("ref=openmw-0.51.0" in c for c in calls))
            self.assertFalse(any(c.endswith("README.md") for c in calls))
            files = sorted(p.relative_to(dest).as_posix() for p in dest.rglob("*") if p.is_file())
            self.assertEqual(files, ["SOURCE.json"] + [f"files/lua_api/openmw/{f.name}" for f in sorted(SRC.glob("*.lua"))])
            meta = json.loads((dest / "SOURCE.json").read_text(encoding="utf-8"))
            self.assertEqual((meta["tag"], meta["apiRevision"]), ("openmw-0.51.0", 42))
            self.assertEqual(len(meta["files"]), 7)
            n = len(calls)
            AC.fetch("openmw-0.51.0", cache_root=t, get=self.fake(calls))   # cached: no downloads
            self.assertEqual(len(calls), n)
            self.assertEqual(AC.load(dest).info()["tag"], "openmw-0.51.0")

    def test_fetch_errors(self):
        with self.assertRaises(AC.FetchError):
            AC.normalize_tag("master; rm -rf")
        with tempfile.TemporaryDirectory() as t:
            def boom(url):
                if "api.github.com" in url:
                    return json.dumps([{"name": "core.lua", "type": "file"},
                                       {"name": "types.lua", "type": "file"}]).encode()
                raise OSError("offline")
            with self.assertRaises(AC.FetchError):
                AC.fetch("openmw-0.51.0", cache_root=t, get=boom)
            self.assertEqual(list(Path(t).iterdir()), [])                  # nothing half-written


class Audit(unittest.TestCase):
    def test_audit_tiny_manifest(self):
        r = AC.audit(AC.load(STUBS), TINY)
        unclassified = {u["symbol"] for u in r["unclassified"]}
        self.assertIn("openmw.types.Actor.fly", unclassified)
        self.assertIn("openmw.core.sound", unclassified)
        stale = {s["symbol"] for s in r["stale"]}
        self.assertEqual(stale, {"openmw.types.Actor.fly2"})
        self.assertIn("openmw_aux.util.x", r["unverifiable"])
        self.assertEqual(r["scopeNotes"], [{"symbol": "openmw.self.teleport", "scope": "global", "ours": "partial"}])
        self.assertEqual(r["gameObject"]["staleMethods"], ["oldMethod"])
        self.assertIn("cell", r["gameObject"]["missingFields"])
        self.assertEqual(r["interfaces"]["notListed"], ["Ours"])
        self.assertEqual(r["modules"]["openmw.world"]["contexts"], ["global"])
        self.assertEqual(r["openmw"]["apiRevision"], 42)

    def test_cli_json(self):
        rc, out = run(["api-audit", "--openmw-src", str(STUBS), "--json"])
        self.assertEqual(rc, 0)
        r = json.loads(out)
        for k in ("tool", "version", "command", "openmw", "manifestVersion", "counts", "unclassified",
                  "unclassifiedByModule", "unclassifiedByGroup", "stale", "unverifiable", "modules",
                  "scopeNotes", "gameObject", "typeMembers", "interfaces", "notes"):
            self.assertIn(k, r)
        self.assertEqual(r["command"], "api-audit")
        self.assertTrue(r["openmw"]["found"])

    def test_cli_not_found_is_noop(self):
        with tempfile.TemporaryDirectory() as t:
            rc, out = run(["api-audit", "--json", "--no-installs", "--api-cache", t], {AC.ENV_DIR: ""})
            self.assertEqual(rc, 0)
            r = json.loads(out)
            self.assertFalse(r["openmw"]["found"])
            rc, out = run(["api-audit", "--no-installs", "--api-cache", t], {AC.ENV_DIR: ""})
            self.assertEqual(rc, 0)
            self.assertIn("no OpenMW", out)


class ScanWithCatalog(unittest.TestCase):
    def test_scan_marks_symbols(self):
        cat = AC.load(STUBS)
        manifest = load_manifest()
        plain = scan_mod(FORMS, manifest).to_dict()
        r = scan_mod(FORMS, manifest, catalog=cat).to_dict()
        self.assertEqual(r["verdict"], plain["verdict"])
        self.assertEqual(r["blockers"], plain["blockers"])
        self.assertIsNone(plain["apiCatalog"])
        self.assertEqual(r["apiCatalog"]["version"], "9.8.7")
        self.assertTrue(r["symbols"]["openmw.world.getCellByName"]["inOpenMW"])
        self.assertFalse(r["symbols"]["openmw.util.vector3"]["inOpenMW"] is None)
        self.assertIn("openmw.storage.globalSection", r["unknownToOpenMW"])   # not in the tiny stubs
        self.assertNotIn("openmw.interfaces.Activation.addHandlerForType", r["unknownToOpenMW"])
        self.assertTrue(r["typedMethods"]["Cell:getAll"]["inOpenMW"])
        self.assertTrue(any("not in OpenMW 9.8.7" in w for w in r["warnings"]))

    def test_cli_scan_flags(self):
        rc, out = run(["scan", "--json", "--openmw-src", str(STUBS), str(FORMS)])
        self.assertEqual(json.loads(out)[0]["apiCatalog"]["apiRevision"], 42)
        rc, out = run(["scan", "--json", "--no-openmw", "--openmw-src", str(STUBS), str(FORMS)])
        self.assertIsNone(json.loads(out)[0]["apiCatalog"])


if __name__ == "__main__":
    unittest.main()
