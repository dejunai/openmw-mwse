"""omw2mwse 0.3.1: the tidy handoff (docs/TIDY_INTERFACE.md). Output lands only under the staged
root, Data Files / game installs are refused, the runtime is always included (stdlib unittest;
Python 3.9+). Written for omw2mwse by dej (dejunai)."""
from __future__ import annotations

import hashlib
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from omw2mwse import build as B  # noqa: E402
from omw2mwse.build import BuildError, Writer  # noqa: E402
from omw2mwse.cli import main  # noqa: E402
from omw2mwse.convert import convert  # noqa: E402
from omw2mwse.optout import REASON_MESSAGE  # noqa: E402
from omw2mwse.targets import TargetRefused, protected_reason  # noqa: E402

GLOBAL_SRC = "local world = require('openmw.world')\nreturn {}\n"


def make_mod(d: Path, script_src: str = GLOBAL_SRC, flags: str = "GLOBAL") -> None:
    (d / "scripts" / "M").mkdir(parents=True)
    (d / "scripts" / "M" / "m.lua").write_text(script_src, encoding="utf-8")
    (d / "M.omwscripts").write_text(f"{flags}: scripts/M/m.lua\n", encoding="utf-8")


def snapshot(root: Path) -> dict:
    out = {}
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root).as_posix()
        out[rel] = hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "<dir>"
    return out


def run(argv):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        try:
            rc = main(argv)
        except SystemExit as e:
            rc = e.code
    return rc, out.getvalue(), err.getvalue()


class Base(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.t = Path(self._t.name).resolve()
        self.staged = self.t / "staging" / "MyMod"
        self.staged.mkdir(parents=True)
        self.result = self.t / "result" / "r.json"
        self.result.parent.mkdir()

    def tearDown(self):
        self._t.cleanup()

    def call(self, *extra, staged=None):
        return run(["--staged-root", str(staged or self.staged), "--result-json", str(self.result), *extra])

    def res(self):
        return json.loads(self.result.read_text(encoding="utf-8"))


class Converts(Base):
    def test_output_only_under_staged_root_runtime_included(self):
        make_mod(self.staged)
        other = self.t / "other"
        other.mkdir()
        (other / "x.txt").write_text("x", encoding="utf-8")
        before_other = snapshot(other)
        rc, _o, _e = self.call()
        self.assertEqual(rc, 0)
        r = self.res()
        self.assertEqual((r["verdict"], r["interface"], r["exit_code"], r["excluded_by_author"]), ("ready", 1, 0, False))
        self.assertEqual(r["runtime_version"], B.runtime_version())
        self.assertEqual(r["staged_root"], str(self.staged))
        w = r["written_files"]
        self.assertTrue(w and all(not x.startswith(("/", "..")) and "\\" not in x and ":" not in x for x in w))
        for x in w:
            self.assertTrue((self.staged / x).is_file(), x)
        # the runtime is staged content, and so is the converted mod
        self.assertIn("MWSE/lib/omwcompat.lua", w)
        self.assertIn("MWSE/lib/omwcompat/runtime.lua", w)
        self.assertIn("MWSE/mods/mwsuite/openmw/M/main.lua", w)
        self.assertIn("MWSE/mods/mwsuite/openmw/M/omw2mwse-manifest.json", w)
        self.assertEqual(r["mods"][0]["off"], "Off/M/OpenMW")
        self.assertTrue((self.staged / "Off" / "M" / "OpenMW" / "M.omwscripts").is_file())  # originals move inside staging
        self.assertIn("M.omwscripts", r["moved_files"])
        # nothing outside the staged root changed, and the only other new file is the result
        self.assertEqual(snapshot(other), before_other)
        self.assertEqual(sorted(p.name for p in (self.t).iterdir()), ["other", "result", "staging"])
        self.assertEqual([p.name for p in self.result.parent.iterdir()], ["r.json"])
        self.assertEqual([p.name for p in (self.t / "staging").iterdir()], ["MyMod"])
        # idempotent: a second run writes nothing
        self.assertEqual(self.call()[0], 0)
        self.assertEqual(self.res()["written_files"], [])

    def test_no_runtime_flag_is_ignored(self):
        make_mod(self.staged)
        rc, _o, e = self.call("--no-runtime")
        self.assertEqual(rc, 0)
        self.assertIn("MWSE/lib/omwcompat/runtime.lua", self.res()["written_files"])
        self.assertTrue((self.staged / "MWSE" / "lib" / "omwcompat" / "runtime.lua").is_file())
        self.assertIn("ignored", e)
        legacy = self.t / "legacy"
        legacy.mkdir()
        make_mod(legacy)
        self.assertEqual(run(["convert", str(legacy), "--no-runtime"])[0], 0)
        self.assertTrue((legacy / "MWSE" / "lib" / "omwcompat" / "runtime.lua").is_file())

    def test_subcommand_form_is_the_same(self):
        make_mod(self.staged)
        rc, _o, _e = run(["convert", "--staged-root", str(self.staged), "--result-json", str(self.result), "--dry-run"])
        self.assertEqual(rc, 0)
        self.assertTrue(self.res()["dry_run"])

    def test_dry_run_writes_only_the_result(self):
        make_mod(self.staged)
        before = snapshot(self.staged)
        rc, _o, _e = self.call("--dry-run")
        self.assertEqual(rc, 0)
        self.assertEqual(snapshot(self.staged), before)
        r = self.res()
        self.assertEqual((r["verdict"], r["written_files"], r["dry_run"]), ("ready", [], True))
        self.assertIn("MWSE/lib/omwcompat/runtime.lua", r["planned_files"])

    def test_nothing_to_convert(self):
        (self.staged / "meshes").mkdir()
        (self.staged / "meshes" / "a.nif").write_bytes(b"x")
        rc, _o, _e = self.call()
        self.assertEqual(rc, 0)
        r = self.res()
        self.assertEqual((r["verdict"], r["written_files"]), ("none", []))
        self.assertEqual(sorted(p.name for p in self.staged.iterdir()), ["meshes"])

    def test_legacy_forms_still_work(self):
        make_mod(self.staged)
        rc, _o, _e = run(["--convert-omwscripts", str(self.staged)])
        self.assertEqual(rc, 0)
        self.assertTrue((self.staged / "MWSE" / "mods" / "mwsuite" / "openmw" / "M" / "main.lua").is_file())

    def test_guards_reported(self):
        src = ("local world = require('openmw.world')\nlocal t = {}\nreturn {engineHandlers = {onUpdate = function() end}}\n")
        make_mod(self.staged, script_src=src)
        self.assertEqual(self.call("--dry-run")[0], 0)
        r = self.res()
        self.assertIsInstance(r["guards"], list)
        self.assertIn("guards", r["mods"][0])


class BlockedAndFailed(Base):
    def test_blocked_writes_nothing_but_the_result(self):
        make_mod(self.staged, flags="GLOBAL, MENU")
        before = snapshot(self.staged)
        rc, _o, _e = self.call()
        self.assertEqual(rc, 1)
        self.assertEqual(snapshot(self.staged), before)
        r = self.res()
        self.assertEqual((r["verdict"], r["written_files"], r["excluded_by_author"]), ("blocked", [], False))
        self.assertTrue(any("MENU" in b for b in r["blockers"]))

    def test_blocked_mod_blocks_the_whole_folder(self):
        make_mod(self.staged)
        two = self.staged / "Two"
        two.mkdir()
        make_mod(two, flags="GLOBAL, MENU")
        (two / "M.omwscripts").rename(two / "Two.omwscripts")
        before = snapshot(self.staged)
        self.assertEqual(self.call()[0], 1)
        self.assertEqual(snapshot(self.staged), before)

    def test_author_opt_out(self):
        make_mod(self.staged)
        (self.staged / "scripts" / "M" / "notes.lua").write_text("-- mwsuite conversion opt-out\n", encoding="utf-8")
        before = snapshot(self.staged)
        rc, out, err = self.call()
        self.assertEqual(rc, 1)
        self.assertEqual(snapshot(self.staged), before)
        text = self.result.read_text(encoding="utf-8")
        r = json.loads(text)
        self.assertTrue(r["excluded_by_author"])
        self.assertEqual((r["verdict"], r["written_files"]), ("blocked", []))
        self.assertIn(REASON_MESSAGE, r["blockers"])
        for leak in ("notes.lua", '"line"', '"file"', "mwsuite conversion opt", "opt-out"):
            self.assertNotIn(leak, (text + out + err).lower(), leak)

    def test_conflict_is_failed_and_writes_nothing(self):
        make_mod(self.staged)
        hand = self.staged / "MWSE" / "mods" / "mwsuite" / "openmw" / "M" / "main.lua"
        hand.parent.mkdir(parents=True)
        hand.write_text("-- hand written\n", encoding="utf-8")
        before = snapshot(self.staged)
        rc, _o, _e = self.call()
        self.assertEqual(rc, 2)
        self.assertEqual(snapshot(self.staged), before)
        r = self.res()
        self.assertEqual((r["verdict"], r["written_files"]), ("failed", []))
        self.assertTrue(any(e["code"] == "conflict" for e in r["errors"]))

    def test_missing_staged_folder_is_failed(self):
        rc, _o, _e = self.call(staged=self.t / "nope")
        self.assertEqual(rc, 2)
        self.assertEqual(self.res()["verdict"], "failed")
        self.assertFalse((self.t / "nope").exists())

    def test_usage_errors(self):
        self.assertEqual(run(["--staged-root", str(self.staged)])[0], 64)     # no --result-json
        self.assertEqual(run(["--staged-root", str(self.staged), "--bogus"])[0], 64)
        make_mod(self.staged)
        inside = self.staged / "r.json"
        before = snapshot(self.staged)
        self.assertEqual(run(["--staged-root", str(self.staged), "--result-json", str(inside)])[0], 64)
        self.assertEqual(snapshot(self.staged), before)                       # the result may not go in staging


class Refused(Base):
    def folders(self):
        game = self.t / "Morrowind"
        data = game / "Data Files"
        (data / "MWSE").mkdir(parents=True)
        (game / "Morrowind.exe").write_bytes(b"MZ")
        (data / "Morrowind.esm").write_bytes(b"TES3")
        loose = self.t / "Games" / "Data Files"          # a Data Files folder with no game marker around it
        loose.mkdir(parents=True)
        esm_only = self.t / "Unpacked"                   # a folder that holds Morrowind.esm itself
        esm_only.mkdir()
        (esm_only / "Morrowind.esm").write_bytes(b"TES3")
        return {"data files": data, "game root": game, "inside mod in data files": data / "Mods" / "X",
                "loose Data Files": loose, "esm folder": esm_only, "exe ancestor": game / "Other" / "Deep"}

    def test_every_protected_target_is_refused_without_writing(self):
        for label, folder in self.folders().items():
            folder.mkdir(parents=True, exist_ok=True)
            with self.subTest(label):
                (folder / "M.omwscripts").write_text("GLOBAL: scripts/M/m.lua\n", encoding="utf-8")
                before = snapshot(self.t / "Morrowind") if (self.t / "Morrowind").exists() else {}
                if self.result.exists():
                    self.result.unlink()
                rc, _o, e = self.call(staged=folder)
                self.assertEqual(rc, 3, e)
                r = self.res()
                self.assertEqual((r["verdict"], r["written_files"]), ("refused", []))
                self.assertEqual(r["errors"][0]["code"], "target-refused")
                if before:
                    self.assertEqual(snapshot(self.t / "Morrowind"), before)
                self.assertFalse((folder / "MWSE" / "lib" / "omwcompat").exists())
                self.assertFalse((folder / "Off").exists())
                # the same through the other entry points
                self.assertEqual(run(["convert", str(folder)])[0], 3)
                self.assertEqual(run(["convert", str(folder), "--json"])[0], 3)
                self.assertEqual(run(["recover", str(folder), "--rollback"])[0], 3)
                self.assertEqual(run(["--convert-omwscripts", str(folder)])[0], 3)
                with self.assertRaises(TargetRefused):
                    convert(folder, "normal")
                with self.assertRaises(TargetRefused):
                    convert(folder, "normal", dry_run=True)

    def test_protected_reason_unit(self):
        self.assertIsNone(protected_reason(self.t / "staging" / "MyMod"))
        d = self.t / "Games" / "DATA FILES" / "m"
        self.assertIn("Data Files", protected_reason(d))

    def test_source_sidecar_meshes_inputs_in_data_files_are_refused(self):
        make_mod(self.staged)
        data = self.folders()["data files"]
        before = snapshot(self.staged)
        for flag in ("--source", "--sidecar", "--meshes-from"):
            with self.subTest(flag):
                rc, _o, _e = self.call(flag, str(data))
                self.assertEqual(rc, 3)
                self.assertEqual(self.res()["verdict"], "refused")
                self.assertEqual(snapshot(self.staged), before)

    def test_result_json_in_data_files_is_refused(self):
        make_mod(self.staged)
        data = self.folders()["data files"]
        before = snapshot(self.staged)
        rc, _o, _e = run(["--staged-root", str(self.staged), "--result-json", str(data / "r.json")])
        self.assertEqual(rc, 3)
        self.assertFalse((data / "r.json").exists())
        self.assertEqual(snapshot(self.staged), before)

    def test_package_and_scan_report_refuse_data_files(self):
        src = self.t / "src"
        src.mkdir()
        make_mod(src)
        data = self.folders()["data files"]
        before = snapshot(self.t / "Morrowind")
        self.assertEqual(run(["package", str(src), "--out", str(data / "pkg"), "--name", "M"])[0], 3)
        self.assertEqual(run(["package", str(data), "--out", str(self.t / "out"), "--name", "M"])[0], 3)
        self.assertEqual(run(["scan", str(src), "-o", str(data / "report.md")])[0], 3)
        self.assertEqual(snapshot(self.t / "Morrowind"), before)
        self.assertFalse((self.t / "out").exists())


class WriterSafety(unittest.TestCase):
    def test_writer_refuses_paths_that_leave_the_root(self):
        w = Writer(Path("/tmp/x"))
        for bad in ("../x", "a/../../x", "/etc/x", "C:/x"):
            with self.assertRaises(BuildError, msg=bad):
                w.put(bad, b"x")
        w.put("a/b.txt", b"x")


if __name__ == "__main__":
    unittest.main()
