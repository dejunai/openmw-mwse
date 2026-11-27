# omw2mwse handoff interface for tidy (interface version 1)

Rule (Dej): the converter works **only on a staged mod folder** (a Vortex staging mod folder),
is called from tidy, and writes **all** its output back into that folder, including the
omwcompat runtime as staged content. It never reads from or writes to Data Files or the game
install. Data Files is touched only by Vortex's final deploy.

This is the contract tidy implements against. The older `--convert-omwscripts=MODE DIR --json`
form and the `convert` / `recover` / `package` / `scan` subcommands keep working (see
`docs/TIDY-INTEGRATION.md`), but they obey the same target rules below.

## Call

```
omw2mwse --staged-root <staged mod dir> --result-json <file> [--dry-run]
         [--mode normal|hardcode] [--accept-hardcode-conversions]
         [--title T] [--author A] [--license L] [--source-url U]
         [--name N] [--source DIR] [--sidecar FILE] [--adopt-existing] [--meshes-from DIR]
```

`omw2mwse convert --staged-root ...` is the same call. `--staged-root` plus `--result-json`
selects this interface (and its exit codes); `convert DIR` without them is the old interface.

- `<staged mod dir>`: the mod's folder in Vortex staging (the mod root, the folder that would be
  merged into Data Files on deploy).
- `<file>`: chosen by tidy, a temp file **outside** the staged folder and outside Data Files / a
  game install (else exit 64 / 3). Written atomically, UTF-8, LF, no BOM, on every exit code
  except 64.
- `--dry-run`: plans everything, writes **nothing** except `<file>`.
- It never prompts. A hard-code conversion (`--mode hardcode`) not accepted with
  `--accept-hardcode-conversions` is a failure (exit 2, error `hardcode-not-accepted`).
- `--no-runtime` is accepted and ignored: the runtime is always written into the staged folder.

## What it writes (all under the staged folder)

- the converted mod: `MWSE/mods/mwsuite/openmw/<Mod>/...` (loader, hosted Lua, report,
  `omw2mwse-manifest.json`);
- the runtime: `MWSE/lib/omwcompat.lua` and `MWSE/lib/omwcompat/*`;
- the originals, **moved on success** to `Off/<plugin>/OpenMW/...` inside the staged folder
  (file contents unchanged), game assets also stay or are installed at the staged root, plugins
  placed as in `TIDY-INTEGRATION.md` (subfolder plugins to `Extras/`, `.omwaddon` -> `.esp`, ...);
- a short-lived recovery journal while it runs (removed when it finishes).

On exit 1, 2 or 3, and with `--dry-run`, none of this happens: tidy moves the plugin to
`Off\<plugin>\OpenMW\` itself on 1 and 2. If the staged folder holds several OpenMW mods the
call is all-or-nothing: one blocked mod blocks the whole call (use `--source DIR` to convert
one of them at a time).

Writes are temp file + `os.replace`, so a staged file that Vortex hardlinked into Data Files
is replaced, never written through; Data Files keeps the old file until the next deploy.

## Refused targets

Exit 3 (nothing read or written, result file written if its own location is allowed) when
`--staged-root`, `--source`, `--sidecar`, `--meshes-from` or the result file's folder is, or is
inside, a folder that: is named `Data Files` (any case), holds `Morrowind.exe` or
`Morrowind.esm`, or holds a `Data Files` folder with `Morrowind.esm`; checked on the resolved
path, for the folder and every parent. The same check guards `convert DIR`, `recover`,
`package` (source and output) and `scan -o` (exit 3 there too).

## Exit codes

| code | meaning | `verdict` | writes |
|---|---|---|---|
| 0 | converted (also: nothing to convert) | `ready` / `none` | the mod, runtime, manifest, moved originals |
| 1 | blocked: author exclusion, or unsupported (incl. MWSE files too long for Windows MAX_PATH) | `blocked` | result only |
| 2 | failed: not a folder, a file that is not omw2mwse's is in the way, hard-code conversions not accepted, other `BuildError` | `failed` | result only |
| 3 | refused target (Data Files / game install) | `refused` | result only (or nothing) |
| 64 | usage error (bad or missing arguments, result file inside the staged folder) | - | nothing |
| 70 | internal error (a bug) | `error` | result only; the staged folder may be partly written, `omw2mwse recover DIR --rollback` undoes it |

Anything else is an internal error. Python 3.9+ (`requiresPython`).

## Result JSON

```json
{
 "tool": "omw2mwse", "version": "0.3.2", "interface": 1, "requiresPython": ">=3.9",
 "staged_root": "G:\\...\\mods\\MyMod",
 "dry_run": false,
 "exit_code": 0,
 "verdict": "ready",
 "blockers": [],
 "guards": ["activeDedupe", "safeIteration"],
 "runtime_version": "0.4.4",
 "written_files": ["MWSE/lib/omwcompat.lua", "MWSE/lib/omwcompat/runtime.lua",
                   "MWSE/mods/mwsuite/openmw/M/main.lua",
                   "MWSE/mods/mwsuite/openmw/M/omw2mwse-manifest.json"],
 "planned_files": ["(same as written_files; the plan of a dry run)"],
 "removed_files": [],
 "moved_files": ["M.omwscripts", "scripts/M/m.lua"],
 "excluded_by_author": false,
 "errors": [],
 "mods": [{"name": "M", "source": "Off/M/OpenMW", "status": "ok", "verdict": "ready",
           "blockers": [], "guards": {"scripts/M/m.lua": ["activeDedupe"]},
           "written_files": ["..."], "planned_files": ["..."], "off": "Off/M/OpenMW",
           "excluded_by_author": false}]
}
```

| field | |
|---|---|
| `verdict` | `ready` (converted; partly supported APIs do not change it, see `mods[]`/`--json` `partialApis`), `none` (no `.omwscripts`), `blocked`, `failed`, `refused`, `error` |
| `blockers` | strings; for an author exclusion the one fixed message, nothing else |
| `guards` | sorted names of the omwcompat run-time guards the converted scripts run with (`activeDedupe`, `safeIteration`, ...); per script in `mods[].guards` |
| `runtime_version` | version of the omwcompat runtime written into the staged folder |
| `written_files` | files created or changed this run, relative to `staged_root`, forward slashes, sorted; `[]` for a dry run and for a rerun that changes nothing |
| `planned_files` | the same list as it would be written (filled by `--dry-run` and real runs) |
| `removed_files` | earlier omw2mwse output files removed (layout migration) |
| `moved_files` | originals moved to `Off/<plugin>/OpenMW/` (their old staged-relative paths) |
| `excluded_by_author` | true when a mod's author asked to be excluded; never says which file or line, and `mods[]` / `errors[]` carry nothing more |
| `errors` | `{code, message[, mod, path]}`: `target-refused`, `not-a-directory`, `conflict`, `hardcode-not-accepted`, `error`, `internal-error` |

All paths are relative to `staged_root` with forward slashes, except `staged_root` itself.
Unknown fields may be added in a compatible way; `interface` changes only on a break.

## What tidy needs to change (Conflict Tools)

Today (`vortex_tidy.run_converter`, read only here) tidy runs
`omw2mwse --convert-omwscripts=<mode> <mod_dir> --json [--accept-hardcode-conversions] [--title T] [--author A] [--dry-run]`,
reads `mods[].verdict` / `reason` / `changed` / `relocated` / `plugins` / `partialApis` /
`requiresPython` from stdout, treats exit 0 + `blocked` as "undo what was written", and calls
`omw2mwse recover <mod_dir> --rollback --json`. `find_converter` finds `bin/omw2mwse` or
`-m omw2mwse` without any game path. That already runs on staged folders, but a blocked mod
still had a loader written, `--no-runtime` could leave the runtime out, and nothing stopped it
from being pointed at Data Files. To adopt this interface tidy should:

1. call `--staged-root <mod_dir> --result-json <temp file outside staging> [--dry-run]` (plus the
   options it already passes) and read the file, not stdout; keep using the dry run for the plan;
2. switch on the exit code (0 / 1 / 2 / 3 / other = internal); on 1 and 2 move the plugin to
   `Off\<plugin>\OpenMW\` itself (nothing needs undoing: the converter wrote nothing);
3. use `excluded_by_author` for the no-file/no-line warning;
4. take `written_files` / `removed_files` / `moved_files` for its `--undo` journal instead of
   deriving them (the manifest still lists the owned files);
5. never pass a Data Files / game path, and never pass `--no-runtime`.

`recover --rollback` is unchanged.
