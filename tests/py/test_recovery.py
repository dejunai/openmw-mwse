"""Recoverable commit (audit #1) and the portable path contract (audit #5) for `convert`.

Interruptions are simulated by making os.replace (output and manifest writes) or Path.unlink
(relocation of the original package) raise part way through a run. After each one the folder
must hold a journal, a re-run must converge to exactly what an uninterrupted run produces, and
`recover --rollback` must return the folder to what it was before the run.
"""
from __future__ import annotations

import io
import json
import ntpath
import os
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path, PurePosixPath, PureWindowsPath
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from omw2mwse import recovery as RC  # noqa: E402
from omw2mwse.build import MANIFEST_NAME, portable_path  # noqa: E402
from omw2mwse.cli import main  # noqa: E402
from omw2mwse.convert import EXIT_OK, convert  # noqa: E402
from test_hardcode import LUA, SIDECAR, make_staged, tree  # noqa: E402

MOD = "MWSE/mods/mwsuite/openmw/Demo/"
JOURNAL = MOD + RC.RECOVERY_DIR + "/" + RC.JOURNAL_NAME


def same_abs(a, b) -> bool:
    """Absolute filesystem paths compared with Windows semantics (case-insensitive, either
    slash, short/long names resolved) - what the PC's NTFS does. Also right on Linux for the
    paths the tests build (they differ only by what Windows ignores)."""
    return ntpath.normcase(os.path.realpath(str(a))) == ntpath.normcase(os.path.realpath(str(b)))


def make_root_package(root: Path) -> None:
    """A package loose at the staged root, with a root .omwaddon (installed as .esp) and a mesh."""
    (root / "scripts" / "Demo").mkdir(parents=True)
    (root / "scripts" / "Demo" / "g.lua").write_text(LUA, encoding="utf-8")
    (root / "Demo.omwscripts").write_text("GLOBAL: scripts/Demo/g.lua\n", encoding="utf-8")
    (root / "Demo.omwaddon").write_bytes(b"not a TES3 file")
    (root / "meshes").mkdir()
    (root / "meshes" / "x.nif").write_bytes(b"NIF")


FIXTURES = {"legacy-off": make_staged, "root-package": make_root_package}


class Boom(Exception):
    pass


def fail_replace_after(n: int, pred=lambda dst: True):
    """os.replace that raises Boom on the (n+1)-th call whose destination matches pred."""
    real = os.replace
    count = {"n": 0}

    def fake(src, dst, *a, **k):
        if pred(str(dst)):
            if count["n"] >= n:
                raise Boom(f"simulated interruption writing {dst}")
            count["n"] += 1
        return real(src, dst, *a, **k)
    return mock.patch("os.replace", fake)


def fail_unlink_after(n: int, pred):
    real = Path.unlink
    count = {"n": 0}

    def fake(self, *a, **k):
        if pred(self):
            if count["n"] >= n:
                raise Boom(f"simulated interruption removing {self}")
            count["n"] += 1
        return real(self, *a, **k)
    return mock.patch.object(Path, "unlink", fake)


def is_output(dst: str) -> bool:
    d = dst.replace("\\", "/")
    return RC.RECOVERY_DIR not in d and not d.endswith(MANIFEST_NAME)


def is_manifest(dst: str) -> bool:
    return dst.replace("\\", "/").endswith(MANIFEST_NAME)


def no_temp_files(root: Path) -> bool:
    return not [p for p in root.rglob(".omw2mwse-*.tmp")]


class Interruptions(unittest.TestCase):
    def reference(self, fixture, mode="normal") -> dict:
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            FIXTURES[fixture](root)
            with redirect_stderr(io.StringIO()):
                r = convert(root, mode, accept=True)
            self.assertEqual(r["exitCode"], EXIT_OK)
            return tree(root)

    def interrupted(self, root: Path, patcher, mode="normal") -> dict:
        with patcher, redirect_stderr(io.StringIO()):
            with self.assertRaises(Boom):
                convert(root, mode, accept=True)
        self.assertTrue((root / JOURNAL).is_file(), "journal must exist after an interruption")
        self.assertTrue(no_temp_files(root))
        return json.loads((root / JOURNAL).read_text(encoding="utf-8"))

    def check_converges(self, root: Path, fixture, mode="normal"):
        with redirect_stderr(io.StringIO()):
            r = convert(root, mode, accept=True)
        self.assertEqual(r["exitCode"], EXIT_OK, r)
        self.assertEqual(r["pendingRecovery"], [])
        self.assertIn("resumed", r["mods"][0])
        self.assertFalse((root / MOD / RC.RECOVERY_DIR).exists())
        self.assertEqual(tree(root), self.reference(fixture, mode))
        with redirect_stderr(io.StringIO()):
            r2 = convert(root, mode, accept=True)
        self.assertFalse(r2["changed"])
        self.assertNotIn("resumed", r2["mods"][0])

    def check_rollback(self, root: Path, before: dict):
        out = io.StringIO()
        with redirect_stdout(out):
            rc = main(["recover", str(root), "--rollback", "--json"])
        self.assertEqual(rc, 0, out.getvalue())
        rep = json.loads(out.getvalue())
        self.assertEqual(rep["pendingRecovery"], [])
        self.assertEqual(rep["rolledBack"][0]["kept"], [])
        self.assertEqual(tree(root), before)

    def scenario(self, fixture, patcher_factory, stage, mode="normal", prepare=None):
        for finish in ("rerun", "rollback"):
            with self.subTest(fixture=fixture, finish=finish), tempfile.TemporaryDirectory() as t:
                root = Path(t)
                FIXTURES[fixture](root)
                if prepare:
                    prepare(root)
                before = tree(root)
                j = self.interrupted(root, patcher_factory(), mode)
                self.assertEqual(j["stage"], stage)
                self.assertNotEqual(tree(root), before)
                if finish == "rerun":
                    self.check_converges(root, fixture, mode)
                else:
                    self.check_rollback(root, before)

    def test_interrupted_during_output_writes(self):
        for fixture in FIXTURES:
            self.scenario(fixture, lambda: fail_replace_after(3, is_output), "planned")

    def test_interrupted_during_original_relocation(self):
        def orig(p: Path) -> bool:
            s = p.as_posix()
            return "/MWSE/" not in s and RC.RECOVERY_DIR not in s and "/Off/Demo/" not in s
        for fixture in FIXTURES:
            self.scenario(fixture, lambda: fail_unlink_after(1, orig), "outputs-written")

    def test_interrupted_during_manifest_write(self):
        for fixture in FIXTURES:
            self.scenario(fixture, lambda: fail_replace_after(0, is_manifest), "relocated")

    def test_hard_stop_is_recoverable_too(self):
        # KeyboardInterrupt (BaseException) half way through the outputs
        real = os.replace
        count = {"n": 0}

        def fake(src, dst, *a, **k):
            if is_output(str(dst)):
                count["n"] += 1
                if count["n"] == 5:
                    raise KeyboardInterrupt
            return real(src, dst, *a, **k)
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            with mock.patch("os.replace", fake), self.assertRaises(KeyboardInterrupt):
                convert(root, "normal")
            self.assertTrue((root / JOURNAL).is_file())
            self.check_converges(root, "legacy-off")

    def test_interrupted_update_rolls_back_to_the_previous_build(self):
        """A completed normal build, then a hardcode run interrupted while replacing files:
        rollback restores the replaced files from backup and drops the new ones; the
        manifest write is atomic, so the old manifest is intact throughout."""
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root, sidecar=SIDECAR)
            convert(root, "normal")
            before = tree(root)
            man_before = (root / MOD / MANIFEST_NAME).read_bytes()
            deployed = root / "deployed-main.lua"
            os.link(root / MOD / "main.lua", deployed)        # a Vortex hard link
            j = self.interrupted(root, fail_replace_after(2, is_output), "hardcode")
            self.assertTrue(any(rec["old"] for rec in j["writes"].values()))
            self.assertEqual((root / MOD / MANIFEST_NAME).read_bytes(), man_before)
            self.check_rollback(root, dict(before, **{"deployed-main.lua": before[MOD + "main.lua"]}))
            self.assertEqual(deployed.read_bytes(), before[MOD + "main.lua"])

    def test_manifest_interruption_keeps_old_manifest(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root, sidecar=SIDECAR)
            convert(root, "normal")
            man_before = (root / MOD / MANIFEST_NAME).read_bytes()
            self.interrupted(root, fail_replace_after(0, is_manifest), "hardcode")
            self.assertEqual((root / MOD / MANIFEST_NAME).read_bytes(), man_before)
            with redirect_stderr(io.StringIO()):
                r = convert(root, "hardcode", accept=True)
            self.assertEqual(r["exitCode"], EXIT_OK)
            self.assertNotEqual((root / MOD / MANIFEST_NAME).read_bytes(), man_before)
            self.assertFalse((root / JOURNAL).exists())

    def test_two_interruptions_then_rollback_returns_to_the_start(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_root_package(root)
            before = tree(root)
            self.interrupted(root, fail_replace_after(2, is_output))
            j = self.interrupted(root, fail_replace_after(0, is_manifest))
            self.assertEqual(j["resumedFrom"], "planned")
            self.check_rollback(root, before)

    def test_journal_is_written_before_any_change(self):
        """The first os.replace of a run is the journal itself."""
        seen = []
        real = os.replace

        def spy(src, dst, *a, **k):
            seen.append(str(dst).replace("\\", "/"))
            return real(src, dst, *a, **k)
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            with mock.patch("os.replace", spy):
                convert(root, "normal")
        self.assertTrue(seen[0].endswith(RC.RECOVERY_DIR + "/" + RC.JOURNAL_NAME), seen[:3])

    def test_no_op_run_writes_nothing(self):
        seen = []
        real = os.replace

        def spy(src, dst, *a, **k):
            seen.append(str(dst))
            return real(src, dst, *a, **k)
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            convert(root, "normal")
            with mock.patch("os.replace", spy):
                r = convert(root, "normal")
            self.assertFalse(r["changed"])
            self.assertEqual(seen, [])

    def test_journal_paths_and_backups(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root, sidecar=SIDECAR)
            convert(root, "normal")
            j = self.interrupted(root, fail_replace_after(1, is_output), "hardcode")
            rels = list(j["writes"]) + list(j["removes"]) + list(j["aux"])
            for rl in j["relocations"]:
                rels += [rl["from"], rl["to"]] + list(rl["files"])
            for rel in rels:
                self.assertNotIn("\\", rel)
                self.assertFalse(PurePosixPath(rel).is_absolute() or PureWindowsPath(rel).is_absolute(), rel)
            for rec in j["writes"].values():
                self.assertRegex(rec["new"], r"^[0-9a-f]{64}$")
            backups = list((root / MOD / RC.RECOVERY_DIR / "backup").iterdir())
            self.assertTrue(backups)
            for b in backups:
                self.assertRegex(b.name, r"^[0-9a-f]{64}$")   # never main.lua or *.lua: MWSE must not run them

    def test_dry_run_reports_pending_and_changes_nothing(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            self.interrupted(root, fail_replace_after(2, is_output))
            snap = tree(root)
            r = convert(root, "normal", dry_run=True)
            self.assertIn("interrupted-run-pending", [a["code"] for a in r["alerts"]])
            self.assertEqual([p["journal"] for p in r["pendingRecovery"]], [JOURNAL])
            self.assertEqual(tree(root), snap)
            out = io.StringIO()
            with redirect_stdout(out):
                rc = main(["recover", str(root), "--json"])
            self.assertEqual(rc, 0)
            rep = json.loads(out.getvalue())
            self.assertEqual(rep["pendingRecovery"][0]["mod"], "Demo")
            self.assertEqual(rep["pendingRecovery"][0]["stage"], "planned")
            self.assertEqual(tree(root), snap)

    def test_rollback_leaves_edited_files_alone(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_staged(root)
            j = self.interrupted(root, fail_replace_after(4, is_output))
            written = [rel for rel, rec in sorted(j["writes"].items())
                       if (root / rel).is_file() and rec["old"] is None and rel.startswith("MWSE/")]
            self.assertTrue(written)
            edited = root / written[0]
            edited.write_text("-- edited\n", encoding="utf-8")
            out = io.StringIO()
            with redirect_stdout(out):
                main(["recover", str(root), "--rollback", "--json"])
            rep = json.loads(out.getvalue())
            self.assertIn(written[0], [k["path"] for k in rep["rolledBack"][0]["kept"]])
            self.assertEqual(edited.read_text(encoding="utf-8"), "-- edited\n")


class PathContract(unittest.TestCase):
    """Audit #5: machine-readable paths are relative with forward slashes."""

    WIN_ABS = re.compile(r"^[A-Za-z]:[\\/]|^\\\\")

    def assert_portable(self, rel, what=""):
        self.assertIsInstance(rel, str, what)
        self.assertNotIn("\\", rel, what)
        self.assertFalse(rel.startswith("/") or self.WIN_ABS.match(rel), f"{what}: {rel}")

    def check_result(self, r: dict, root: Path):
        for m in r["mods"]:
            for k in ("source", "off", "relocatedFrom", "willRelocateTo"):
                if k in m:
                    self.assert_portable(m[k], k)
            for rel in list(m.get("files", {})) + m.get("relocated", []) + m.get("maxPathTooLong", []):
                self.assert_portable(rel, "files/relocated")
            for p in m.get("plugins", []):
                self.assert_portable(p["path"], "plugins.path")
                self.assert_portable(p["sourceRel"], "plugins.sourceRel")
            for pa in m.get("partialApis", []):
                for u in pa["uses"]:
                    self.assert_portable(u["file"], "partialApis.uses.file")
            for al in m.get("alerts", []):
                for k in ("file", "path"):
                    if k in al:
                        self.assert_portable(al[k], f"alert {al['code']}.{k}")
            if "sidecar" in m:
                self.assert_portable(m["sidecar"], "sidecar")
            mp = root / "MWSE" / "mods" / "mwsuite" / "openmw" / m["name"] / MANIFEST_NAME
            if mp.is_file():
                man = json.loads(mp.read_text(encoding="utf-8"))
                self.assert_portable(man["source"], "manifest.source")
                for rel in man["files"]:
                    self.assert_portable(rel, "manifest.files")
                for p in man["plugins"]:
                    self.assert_portable(p["path"], "manifest.plugins.path")
        for p in r.get("pendingRecovery", []):
            self.assert_portable(p["journal"], "pendingRecovery.journal")

    def test_json_and_manifest_paths(self):
        for fixture in FIXTURES:
            with self.subTest(fixture=fixture), tempfile.TemporaryDirectory() as t:
                root = Path(t)
                FIXTURES[fixture](root)
                (root / "Demo.omw2mwse.toml").write_text(SIDECAR, encoding="utf-8")
                self.check_result(convert(root, "normal", dry_run=True), root)
                self.check_result(convert(root, "normal"), root)
                with redirect_stderr(io.StringIO()):
                    r = convert(root, "hardcode", accept=True)
                self.check_result(r, root)
                self.assertEqual(r["mods"][0]["sidecar"], "Demo.omw2mwse.toml")

    def test_root_package_source_is_dot(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            make_root_package(root)
            r = convert(root, "normal")
            self.assertEqual(r["mods"][0]["relocatedFrom"], ".")
            self.assertEqual(r["mods"][0]["source"], "Off/Demo/OpenMW")

    def test_external_sidecar_is_absolute_native(self):
        with tempfile.TemporaryDirectory() as t, tempfile.TemporaryDirectory() as t2:
            root = Path(t)
            make_staged(root)
            sc = Path(t2) / "Demo.omw2mwse.toml"
            sc.write_text(SIDECAR, encoding="utf-8")
            with redirect_stderr(io.StringIO()):
                r = convert(root, "hardcode", accept=True, sidecar_path=sc)
            self.assertTrue(os.path.isabs(r["mods"][0]["sidecar"]))
            self.assertTrue(same_abs(r["mods"][0]["sidecar"], sc))
            self.assertTrue(same_abs(r["dir"], root))

    def test_portable_path_windows_semantics(self):
        W = PureWindowsPath
        self.assertEqual(portable_path(W(r"C:\Stage\Mod\Off\X\OpenMW"), W(r"C:\Stage\Mod")), "Off/X/OpenMW")
        self.assertEqual(portable_path(W(r"C:\STAGE\mod\Off\X"), W(r"c:\stage\Mod")), "Off/X")
        self.assertEqual(portable_path(W(r"C:\Stage\Mod"), W(r"c:\stage\mod")), ".")
        self.assertEqual(portable_path(W(r"D:\Other\Demo.omw2mwse.toml"), W(r"C:\Stage")), r"D:\Other\Demo.omw2mwse.toml")
        self.assertEqual(portable_path(PurePosixPath("/s/m/Off/X"), PurePosixPath("/s/m")), "Off/X")
        self.assertEqual(portable_path(PurePosixPath("/s/m"), PurePosixPath("/s/m")), ".")

    def test_same_abs_uses_windows_rules(self):
        self.assertTrue(ntpath.normcase(r"C:\Users\Dej\Stage") == ntpath.normcase("c:/users/dej/stage"))


if __name__ == "__main__":
    unittest.main()
