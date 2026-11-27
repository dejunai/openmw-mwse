# Calling omw2mwse from tidy

Conflict Tools' tidy pass (separate repo, not modified here) converts OpenMW Lua mods it
finds in staged plugin folders by calling omw2mwse. **The current call is described in
`docs/TIDY_INTERFACE.md` (`--staged-root DIR --result-json FILE`; interface 1, omw2mwse 0.3.1);
the invocation below is the older form, still accepted.** The converter works only on a staged
mod folder and never in Data Files or a game install (exit 3), and the omwcompat runtime is
always written into the staged folder (`--no-runtime` is ignored). This note is the contract. Tidy and
omw2mwse have agreed on the following, as well as the invocation and JSON below:

- tidy reads `mods[].verdict`. `blocked` means tidy removes the conversion output;
  `partial` counts as converted. omw2mwse still exits 0 for a blocked mod (`status` is
  `ok` and the blockers are in `mods[].alerts`); the verdict is the signal, not the
  exit code.
- tidy passes `--title` and `--author` (and `--license` / `--source-url` when it has
  them) so the MCM tab does not say "original author: unknown".
- tidy no longer renames plugins. omw2mwse already installs a root-level `.omwaddon`
  as `.esp` (and `.omwgame` as `.esm`); see "Plugins at the Data Files root".
- tidy `--undo` uses `omw2mwse-manifest.json` until an `omw2mwse revert` command exists.
  An *interrupted* run (no complete manifest) is undone with `omw2mwse recover DIR --rollback`
  instead; see "Interrupted runs (recovery journal)".
- All paths in `--json` and in the manifest follow the path contract below (relative,
  forward slashes).

## Author opt-out (`author-opt-out`)

If any `.lua` file in a mod's package (declared in `.omwscripts` or not) carries the author
opt-out marker in its header comment block, omw2mwse does not convert the mod. It writes no
files and moves nothing. The detection rule lives in `tools/omw2mwse/optout.py`; it is not
repeated in user-facing documentation, and no output says which file or line holds the
marker or what it says. The `--json` entry for that mod is:

```json
{
 "name": "SomeMod", "source": "SomeMod", "status": "ok", "verdict": "blocked",
 "reason": {"code": "author-opt-out",
            "message": "The original mod author has asked that this mod be excluded from mwsuite's conversion utility; contact the original mod author for details."},
 "alerts": [{"level": "error", "code": "author-opt-out", "message": "(the same message)"}],
 "files": {}, "plugins": [], "conflicts": [], "rewrites": [], "hardcodeLog": [], "changed": false
}
```

`reason` and the alert have exactly `code` and `message` (no `file`, `line` or matched text).
Exit code is 0, as for any blocked mod. Tidy should treat it like any other blocked mod
(move the package to `Off/` untouched) and keys on `reason.code`; it may show
`reason.message` to the user. If an earlier conversion's output is still present, a
`previous-output-present` warning is added and that output is left as is. `scan --json`
reports the same object as `optOut` (the first blocker is `author-opt-out: <message>`);
`package` refuses with the message as its error.

## Path contract (machine-readable paths)

Every path omw2mwse writes into `--json` output, `omw2mwse-manifest.json` and the recovery
journal is **relative to the staged folder (`<staged-mod-dir>`), with forward slashes**, on
every OS, for example `Off/LeaveTheLightsOff/OpenMW` or `MWSE/mods/mwsuite/openmw/X/main.lua`.
The staged folder itself is `"."` (for example `relocatedFrom` when the package was loose at
the folder root). This covers `mods[].source`, `off`, `relocatedFrom`, `willRelocateTo`,
`relocated[]`, the keys of `files`, `plugins[].path` / `sourceRel`, `maxPathTooLong[]`,
`partialApis[].uses[].file` (relative to the package folder), alert `file` / `path` fields,
`sidecar`, `resumed.journal` and `pendingRecovery[].journal`. Join them with the staged
folder using the OS's path functions (`os.path.join(staged, *rel.split("/"))`); compare them
case-insensitively on Windows.

Exceptions, all absolute paths in the OS's own spelling (backslashes on Windows):

- top-level `dir` (the folder that was converted, as given and resolved);
- a path outside the staged folder: `source` for an external `--source`, `sidecar` for a
  `--sidecar` elsewhere;
- `scan --json` `root` (the scanned folder).

Compare absolute paths with Windows semantics on the PC (`os.path.normcase` after
`os.path.realpath`: case-insensitive, either slash, 8.3 short names resolved), never as raw
strings. `Off/<plugin>/max_path_too_long.txt` is a text file in tidy's own format
(backslashes, see "Unified Off layout"); it is not JSON and keeps that format. Human-readable
text (`message`, `warning`, reports) may contain any spelling and is not part of the contract.

## Invocation

```
omw2mwse --convert-omwscripts[=normal|hardcode] <staged-mod-dir> --json [options]
```

is the same as `omw2mwse convert <staged-mod-dir> --mode normal|hardcode --json`. A bare
`--convert-omwscripts` means `normal`. Library use: `omw2mwse.convert.convert(path, mode, ...)`
returns the same dict that `--json` prints. Python 3.9+ stdlib only (`tomllib` when present,
else a small built-in reader for the TOML omw2mwse reads); tested on 3.9 and 3.15. The JSON
result carries `"requiresPython": ">=3.9"`.

`<staged-mod-dir>` is laid out like a Data Files root but is a Vortex staging mod folder (never the real Data Files or a game install: those are refused, exit 3). omw2mwse finds every
folder below it that holds a `.omwscripts` file, outside `MWSE/` (for example a legacy
`Off/OpenMW/LeaveTheLightsOff/` or a loose package at the folder root), and writes the
MWSE build into the same folder. `package` uses the same layout under `OUT/Data Files/`.

**Package boundaries.** Each folder that directly holds a `.omwscripts` file is one package
and is converted on its own (its own `mods[]` entry, `Off/<plugin>/OpenMW/`, MWSE folder and
manifest). A package's files are everything below its folder except: a subfolder that holds
its own `.omwscripts` (a nested package, such as an add-on shipped in `example-addon/`, with
everything below it), the package's top-level `MWSE/`, `Off/` and `Extras/` output folders,
and files another converted mod in the same staged folder placed (listed in its manifest,
e.g. that mod's `<Name>-metadata.toml`). Above the first package (an archive's wrapper
folder) nothing is cut off. A nested package's opt-out or verdict does not affect its parent.

The complete original OpenMW package is **always** placed at
`Off/<plugin>/OpenMW/<the author's relative paths>`. Example:

- `Off/LeaveTheLightsOff/OpenMW/scripts/LeaveTheLightsOff/LTLO_g.lua`
- `Off/LeaveTheLightsOff/OpenMW/LeaveTheLightsOff.omwscripts`
- `Off/LeaveTheLightsOff/OpenMW/meshes/...` (and any other original files, same relative paths)

`package` copies the source tree there and never modifies the source. `convert` *moves*
an original package that is already inside the staged folder (including the legacy
`Off/OpenMW/<plugin>/` layout) to that canonical location; file contents stay
byte-identical. An external `--source` is copied, not deleted. If the package is
already at `Off/<plugin>/OpenMW/`, nothing is relocated. A second run is a no-op.

Game-loadable assets from the original package (`meshes/`, `textures/`, `icons/`,
`Sound/` or `sounds/`, `music/`, `fonts/`, `splash/`, `video/`, `bookart/`, and loose
`.bsa`) are also installed at the Data Files root so Morrowind / MWSE can load them.
A root-level `.omwaddon` is installed as `.esp` (`.omwgame` as `.esm`) when it is
required or undetermined; the original file stays under `Off/<Mod>/OpenMW/`. A root
plugin proven obsolete is kept only under `Off/`. A plugin that shipped in a package
subfolder is copied to `Extras/<Mod>/` (renamed if needed) and is not auto-enabled.
Hosted (possibly rewritten) Lua stays in
`MWSE/mods/mwsuite/openmw/<Mod>/omw/`. Generated files (the loader, aliases, runtime, metadata, reports)
are never written under `Off/`.

| Output (relative to the staged folder, or to `OUT/Data Files/` for `package`) | What |
|---|---|
| `Off/<Mod>/OpenMW/<original paths>` | complete original OpenMW package, byte-identical, author's relative paths |
| `MWSE/mods/mwsuite/openmw/<Mod>/main.lua` | generated loader (MWSE loads `main.lua` at any depth) |
| `MWSE/mods/mwsuite/openmw/<Mod>/omw/...` | the hosted OpenMW Lua, `.omwscripts`, `l10n/` (a hosted `main.lua` is stored as `main.lua.omw`) |
| `MWSE/mods/mwsuite/openmw/<Mod>/omw/_original/...` | verbatim originals of files rewritten for hard-coded values |
| `MWSE/mods/mwsuite/openmw/<Mod>/README-mwsuite.md` | notice: unofficial mwsuite conversion, support goes to dej (dejunai) via the Nexus forums, credits |
| `MWSE/mods/mwsuite/openmw/<Mod>/OMW2MWSE-REPORT.md` | human-readable report |
| `MWSE/mods/mwsuite/openmw/<Mod>/omw2mwse-manifest.json` | files omw2mwse owns (SHA-256) and `plugins` (placement, status, path, reason); tidy `--undo` uses this |
| `MWSE/lib/omwcompat.lua`, `MWSE/lib/omwcompat/` | runtime (always written; `--no-runtime` is ignored since 0.3.1) |
| `meshes/`, `textures/`, `Sound/`, ... | original game assets, also kept under `Off/<Mod>/OpenMW/` |
| `<Name>.esp` / `<Name>.esm` | root plugins that are required or undetermined (enabled by default), including an `.omwaddon` installed under an `.esp` name |
| `Extras/<Mod>/...` | plugins that shipped in a package subfolder (not auto-enabled; tidy does not look inside `Extras/`) |
| `meshes/omwc/<slug>/<hash>.nif` | short aliases for mesh paths longer than 31 chars, copied from `meshes/` in the folder |
| `<Mod>-metadata.toml` | MWSE metadata with the notice in its description |

### Unified Off layout (conflict-tools `docs/OFF-LAYOUT.md`)

- **Owner name.** `<plugin>` in `Off/<plugin>/OpenMW/` is always `mod_name_for(source)`
  (`tools/omw2mwse/build.py`): the stem of the first `*.omwscripts` directly in the package
  folder, names sorted with `os.path.normcase` (case-insensitive on Windows), everything but
  `A-Za-z0-9_-` removed, falling back to the folder name and then `OpenMWMod`. This is
  tidy's `computed_owner` for an OpenMW-only mod. `--name` changes only the
  `MWSE/mods/mwsuite/openmw/<Mod>/` folder, never the Off owner. Once the converter has
  written `Off/<plugin>/OpenMW/`, that folder is the mod's only canonical owner, so tidy keeps
  it even if the mod also ships a root `.esp` (which tidy would otherwise rank first).
- **Manifest coverage.** Every file a run places is a key of the manifest's `files`
  (originals under `Off/`, root assets, installed plugins, `Extras/`, `MWSE/`, metadata), and
  every `plugins[].path` is one of those keys. Exceptions: the manifest itself and the
  MAX_PATH list below (tidy rewrites that list too, so it is not hashed).
- **MAX_PATH.** A file whose full destination path would be over 259 characters is not
  written. An original whose `Off/<plugin>/OpenMW/` copy would be too long stays where it is
  (it is not removed from its old place). Both are listed in `Off/<plugin>/max_path_too_long.txt`
  with tidy's format (relative to the staged folder, backslashes, unique, case-insensitively
  sorted, UTF-8): an original by its current path, a generated file by the path it would have
  had. The list is this run's offenders plus earlier lines whose file still exists and is still
  too long to move; it is rewritten only when its text changes and removed when empty. The JSON
  entry gets `maxPathTooLong` (the listed paths) and one `max-path-too-long` error alert per
  file. If a file under `MWSE/` could not be written, the mod cannot run: `verdict` is
  `blocked` with `reason.code` `max-path-too-long` (move the staging folder to a shorter path).
  Note: tidy's own refresh keeps only lines whose file exists and whose own path is too long,
  so it drops the converter's lines for generated files and for originals that only failed
  because of their Off copy; the converter adds them back on its next run.

Nothing outside `<staged-mod-dir>` (or the `package` output folder) is written:
**never point convert at the live game's Data Files**; Vortex deploys the result.

## Modes

- `normal`: convert scripts as they are. Hard-coded values are not touched; each candidate
  becomes an alert with `code: "hardcode-candidate"` for tidy to show. A sidecar, if present,
  only supplies credits (an `info` alert `sidecar-ignored` says so).
- `hardcode`: also expose hard-coded values as MCM settings. Choices come from
  `<Mod>.omw2mwse.toml` (in the staged folder or the source folder, or `--sidecar PATH`);
  without a sidecar omw2mwse auto-picks eligible UPPER_CASE number/boolean top-level constants
  and logs every decision (`hardcodeLog`). Before converting it shows the **developer-only
  warning**. Non-interactive runs (tidy) get exit code 3 unless `--accept-hardcode-conversions`
  is passed.

Suggested tidy flow for `hardcode`:
1. Run with `--dry-run --json`. Nothing is written and no prompt appears; each mod's `warning`
   holds the full warning text and `rewrites` the planned conversions.
2. Show `warning` to the developer (never to players) and ask.
3. If they accept, run again with `--accept-hardcode-conversions --json`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | done (or nothing to do) |
| 2 | error (bad sidecar, bad folder, two different copies of one mod; see `alerts`) |
| 3 | hard-code conversion refused (no confirmation); nothing written for that mod |
| 4 | conflict: an output path holds a file omw2mwse did not write, or one edited by hand since the last run; nothing written for that mod |

On a first run over a folder that already holds an earlier hand-installed build, pass
`--adopt-existing` to take over those files (they are overwritten). Files that are not
omw2mwse outputs, such as `MWSE/mods/LTLOHandportMigration/`, are never deleted.

## Idempotency and safety

- Writes are two-phase: every output is planned and checked for conflicts before anything
  is written.
- Each file is written to a temp file and renamed over the target, so a Vortex hardlink in
  Data Files keeps the old content until the next deploy.
- A second run with the same inputs reports every file `unchanged` and `changed: false`.
  Files omw2mwse wrote earlier but no longer produces (for example `_original/` after going
  back to `normal`) are removed, but only when they still match the manifest.
- The manifest (and `max_path_too_long.txt`) are written the same way (temp file +
  `os.replace`), so a reader sees the old or the new manifest, never a partial one.
- Before the first change a recovery journal is written (next section).

## Interrupted runs (recovery journal)

`convert` changes a mod folder in three steps: write the outputs, relocate the original
package to `Off/<plugin>/OpenMW/` (remove the old copies once the Off copy matches), write
the manifest. **Before the first of them** it writes
`MWSE/mods/mwsuite/openmw/<Mod>/.omw2mwse-recovery/journal.json`:

```json
{"tool": "omw2mwse", "format": 1, "version": "0.2.4", "mod": "Demo", "mode": "normal",
 "source": "Off/OpenMW/Demo", "stage": "planned", "resumedFrom": null,
 "writes":  {"MWSE/mods/mwsuite/openmw/Demo/main.lua": {"old": null, "new": "<sha256>"}},
 "removes": {"MWSE/mods/mwsuite/openmw/Demo/omw/_original/scripts/Demo/g.lua": "<sha256>"},
 "relocations": [{"from": "Off/OpenMW/Demo", "to": "Off/Demo/OpenMW",
                  "files": {"Demo.omwscripts": "<sha256>", "scripts/Demo/g.lua": "<sha256>"}}],
 "aux": {"MWSE/mods/mwsuite/openmw/Demo/omw2mwse-manifest.json": {"old": null},
         "Off/Demo/max_path_too_long.txt": {"old": null}}}
```

`writes` are the files it creates (`old: null`) or replaces, with the SHA-256 before and
after; `removes` the owned files it deletes; `relocations` the originals it removes from
their old place (the Off copy has the same hash); `aux` the manifest and the MAX_PATH list.
Replaced and removed files and the previous manifest are copied first to
`.omw2mwse-recovery/backup/<sha256>` (content-addressed names, never `main.lua` or `.lua`, so
MWSE does not run them). `stage` moves `planned` -> `outputs-written` -> `relocated` ->
`manifest-written`; the whole `.omw2mwse-recovery/` folder is deleted when the run completes.
**A folder that still has a journal is an unfinished run.** Tidy should not move, sweep or
hash `.omw2mwse-recovery/` (it is not listed in the manifest).

Recovery, either way:

- **Finish:** run `convert` again with the same options. It first completes the recorded
  relocation (only originals that still match their hash, and only when the Off copy matches),
  treats files the interrupted run already wrote as its own (no `conflict`), and then runs
  normally; the result equals an uninterrupted run, and a further run is a no-op. The mod's
  entry gets `"resumed": {"stage": "<stage reached>", "journal": "<path>"}`.
- **Roll back:** `omw2mwse recover DIR --rollback [--name MOD] [--json]` copies originals
  back from Off/, deletes created files, restores replaced/removed files and the previous
  manifest from backup, and removes the journal. If a run was interrupted twice, the rollback
  still returns to the state before the first one. A file changed by hand since the
  interruption is left alone and listed in `kept`.
- `omw2mwse recover DIR [--json]` without `--rollback` only reports.

Every `convert` result carries `"pendingRecovery": [...]` (empty when nothing is unfinished):

```json
"pendingRecovery": [{"mod": "Demo", "stage": "planned", "mode": "normal",
                     "journal": "MWSE/mods/mwsuite/openmw/Demo/.omw2mwse-recovery/journal.json",
                     "writes": 41, "removes": 0, "relocations": 2}]
```

`recover --json` prints `{"command": "recover", "dir", "rollback", "rolledBack": [{"mod",
"stage", "restored": [paths], "removed": [paths], "kept": [{"path", "reason"}]}],
"pendingRecovery": [...], "alerts": [...], "exitCode"}`. A `--dry-run` convert with a
pending journal changes nothing and adds a top-level `interrupted-run-pending` warning; a run
that cannot proceed for that mod (conflict, refused, opt-out) adds the same alert to the mod.

Suggested tidy flow: write tidy's own intent before calling convert (as today). If the call
dies or the result has a non-empty `pendingRecovery`, either re-run the same convert (finish)
or call `recover --rollback` (undo), then reconcile the tidy intent with the outcome. A killed
process can leave `.omw2mwse-*.tmp` files; they are never outputs and can be deleted.

## Partially supported APIs (`partialApis`)

`verdict` is unchanged (`ready`, `blocked` or `no-lua`; tidy still treats a `partial` verdict
as converted if one ever appears). Next to it, every `mods[]` entry of `convert --json` (and
every `scan --json` result) has `partialApis`: each OpenMW API the mod uses whose omwcompat
status is `partial`, so testers know what to try first in game. Additive; nothing else changed.

```json
"partialApis": [
 {"api": "openmw.core.weather.getTransition", "kind": "symbol", "count": 1,
  "uses": [{"file": "scripts/LeaveTheLightsOff/LTLO_g.lua", "line": 378}],
  "missing": "read from MWSE's weather controller; getTransition is 1 - transitionScalar (direction not yet confirmed in game); nil in cells without sky"},
 {"api": "GameObject:remove", "kind": "method", "count": 3,
  "uses": [{"file": "scripts/LeaveTheLightsOff/LTLO_g.lua", "line": 289}, {"file": "scripts/LeaveTheLightsOff/LTLO_g.lua", "line": 437}],
  "missing": "R1: content refs disabled + tombstoned, created refs deleted"},
 {"api": "scriptFlag:CREATURE", "kind": "scriptFlag", "count": 1, "uses": [],
  "missing": "NPC/CREATURE/ACTOR/CONTAINER/DOOR/LIGHT/ACTIVATOR scripts run per object while it is in an active cell; ..."}
]
```

- `api`: the dotted OpenMW name; GameObject methods are `GameObject:<name>`, script flags
  `scriptFlag:<FLAG>`, engine handlers `engineHandler:<name>`, settings renderers
  `settingsRenderer:<name>`.
- `kind`: `symbol`, `method`, `typedMethod` (0.2.5), `scriptFlag`, `engineHandler`,
  `settingsRenderer` or `pattern` (0.2.4, see below).
- `count`: total uses in the scripts that load (same counting as `coverage`).
- `uses`: up to 20 distinct `{file, line}` (file relative to the package folder, forward
  slashes); `[]` for kinds whose position is not tracked (flags, handlers, renderers).
- `missing`: a short, rule-based note on what omwcompat does differently.
- Sorted by kind (symbols, methods, handlers, flags, renderers, patterns), then by `api`. Present (possibly
  `[]`) on every `status: ok` entry, blocked mods included.
- **Author opt-out:** always `"partialApis": []`; no file, line or text is ever reported for an
  opted-out mod.

The same list is in `OMW2MWSE-REPORT.md` and the `scan` markdown ("Partially supported APIs").

## Rule-based workarounds (`pattern` entries and `guards`, 0.2.4 / omwcompat 0.3.2)

omw2mwse looks for two Lua patterns that misbehave over time and that omwcompat can work
around at run time without editing the mod's Lua (detection: `tools/omw2mwse/patterns.py`;
runtime: `omwcompat/guards.lua`). When a rule fires, two additive things appear; nothing else
in the contract changed:

1. One `partialApis` entry per rule, with the same five keys as every other entry:

```json
{"api": "pattern:active-collect-dedupe", "kind": "pattern", "count": 1,
 "uses": [{"file": "scripts/NFiBW/global.lua", "line": 101}],
 "missing": "an object from onObjectActive/onActorActive/onItemActive is added to a list with no duplicate check, ...; omwcompat (guard activeDedupe) skips ..."},
{"api": "pattern:mutate-during-iteration", "kind": "pattern", "count": 2,
 "uses": [{"file": "scripts/NFiBW/global.lua", "line": 49}, {"file": "scripts/NFiBW/global.lua", "line": 101}],
 "missing": "a table is changed while it is traversed with next/pairs/ipairs; omwcompat (guard safeIteration) ..."}
```

2. `mods[].guards` (also in `scan --json`): declared script path -> the runtime guards that
   script runs with (a script gets the guards of every file it loads, itself and its local
   `require()`s). `{}` when no rule fired, and always `{}` for an author opt-out.

```json
"guards": {"scripts/NFiBW/global.lua": ["activeDedupe", "safeIteration"]}
```

The generated `main.lua` passes them to the runtime
(`{ flags = { "GLOBAL" }, path = "scripts/NFiBW/global.lua", guards = { "activeDedupe", "safeIteration" } }`)
and `OMW2MWSE-REPORT.md` lists every finding with file, line, table name and whether the guard
covers it ("Rule-based workarounds" and "Notes"). A finding never changes the verdict. Tidy
needs no change; it may show the `pattern` entries like any other partial API.

| Rule (`api`) | Catches | Guard | Covered at run time | Reported only |
|---|---|---|---|---|
| `pattern:active-collect-dedupe` | the object argument of `onObjectActive` / `onActorActive` / `onItemActive` appended to a list kept outside the handler (`table.insert(list, obj)` or `list[#list + 1] = obj`) with no other use of that list and no `x[obj]` / `x[obj.id]` check in the handler | `activeDedupe` | `table.insert` of a GameObject that is already in the list, while that script's active handler runs (also inside functions it calls) | `list[#list + 1] = obj`; inserts done by helper functions in *other* handlers |
| `pattern:mutate-during-iteration` | `table.remove` / `table.insert` on `t` inside `for ... in pairs(t)` / `ipairs(t)` / `next, t`; `t[...] = nil` inside `ipairs(t)`; a `k, v = next(t, k)` cursor kept between calls on a table the same file changes | `safeIteration` | `table.remove` of the element just visited (the element shifted into the freed slot is visited, not skipped); `next()` with a key that no longer exists restarts the traversal instead of raising | `t[i] = nil` inside `ipairs` (ends the loop early, as in OpenMW); `table.insert` inside a `pairs` loop |

Detection is per file and token based: it does not follow calls into helper functions, and
table names are plain or dotted names (`list`, `S.list`), not expressions.

## Scanner fields and the OpenMW API audit (0.2.5)

All additive. `verdict`, `coverage` semantics and exit codes are unchanged. Tidy needs no change.

New scan rules that can add blockers to `convert` and `scan` (both, with or without OpenMW):

- A call on a typed value whose method omwcompat does not support is a blocker:
  `unsupported method Inventory:getAll (1x)` (alert `blocker` in `convert`). Partial ones are
  `partialApis` entries with `"kind": "typedMethod"` and `api` `Type:method` (`Cell:getAll`),
  `?:method` (receiver unknown, distinctive names only) or `Type.createRecordDraft`.
- Members of `openmw.self.type` are judged as `openmw.types.Actor.*` (`self.type.getEquipment`
  is `partial` since 0.3.0), and members of a value are judged by the value's
  type (`openmw.self.cell.hasTag` is unsupported).

New keys on every `scan --json` result (`convert` results keep their 0.2.4 keys plus the new
blockers and partial entries above):

```json
"typedMethods": {"Inventory:countOf": {"status": "full", "count": 1,
                 "uses": [{"file": "scripts/W/global.lua", "line": 12}], "inOpenMW": true}},
"guardedRequires": ["openmw.interfaces", "openmw.animation"],
"unlisted": ["openmw.self.position.nonsense"],
"apiCatalog": {"root": "...", "layout": "source", "stubDir": "...", "version": "0.51.0",
               "apiRevision": 129, "tag": "openmw-0.51.0", "files": 20, "symbols": 1826},
"unknownToOpenMW": ["openmw.animation.addGlow"]
```

- `typedMethods`: method calls on typed values (see above). Each entry has `status`, `count`,
  `uses`, and `inOpenMW` when a catalog is loaded.
- `guardedRequires`: modules loaded with `pcall(require, ...)` (also a `warnings` line). The
  mod checks whether the module exists.
- `unlisted`: symbols below a known one that omwcompat's tables do not list. The status
  `unlisted` (in `symbols[].status`) is non-blocking, is a `warnings` line, and does not count as
  covered.
- `apiCatalog`: the OpenMW API files used, or `null` when none was found or `--no-openmw` was
  given.
- `unknownToOpenMW`: symbols (and typed methods) those OpenMW API files do not have, usually
  another OpenMW version or a typo. `[]` without a catalog. Each `symbols[]` entry then also has
  `inOpenMW`: `true`, `false` or `null` (cannot tell: `openmw_aux.*`, interface members, opaque
  references). Warning text: `openmw.types.Player.equipment (1x) is not in OpenMW 0.51.0's Lua API
  (a typo, or an API of another OpenMW version)`.

`omw2mwse api-audit [--openmw DIR | --openmw-src DIR] [--fetch TAG [--refresh]] [--api-cache DIR]
[--no-installs] [--json] [--limit N]` compares omwcompat's manifest with OpenMW's own API files
(see [DEVELOPER.md](DEVELOPER.md#scanner-rules-and-the-openmw-api-audit-025)). It always exits
0; a failed `--fetch` exits 2. JSON:

- `tool`, `version`, `command` (`api-audit`), `manifestVersion`.
- `openmw`: `apiCatalog` plus `found`. When nothing was found: `{"found": false, "searched": [...]}`,
  `counts` is `{}`, `notes` says how to point at a copy, and the other audit keys are absent.
- `counts`: `openmwSymbols`, `manifestSymbols`, `listed` (in both), `namespace` (a parent of
  listed entries), `belowListed` (members of a listed value), `unsupportedModule`,
  `unclassified`, `unclassifiedTop` (subtrees), `stale`, `unverifiable`.
- `unclassified`: top unclassified subtrees `{symbol, kind, size, scope?}`, largest first;
  `unclassifiedByModule` and `unclassifiedByGroup`: counts.
- `stale`: manifest entries OpenMW does not have `{symbol, ours}`. `unverifiable`: entries the
  API files cannot confirm (`openmw_aux.*`, interface members).
- `modules`: per OpenMW module, `contexts` (global/local/player/menu/load), `ours`,
  `hostedKinds`, and `scopeMismatch` or `notInOpenMW` when they apply.
- `scopeNotes`: APIs OpenMW limits to one script kind ("only from a global script")
  `{symbol, scope, ours}`.
- `gameObject`: `missingMethods`, `missingFields`, `staleMethods`, `staleFields`.
- `typeMembers`: per value type, `missing` and `stale`. `interfaces`: `openmw`, `ours`,
  `missing`, `notListed`. `notes`: what the audit does not cover.

## omw2mwse 0.3.0 / omwcompat 0.4.0

All additive: no key was removed or renamed, `verdict` and exit codes keep their meaning. Tidy
needs no change. What tidy will see:

- **More mods convert.** PLAYER and CUSTOM scripts are hosted (`scriptFlags` `partial`), so their
  "script flag ... not hosted" blocker is gone; `ui.showMessage`, `ambient`, `input`, the
  `onFrame` / `onKeyPress` / `onKeyRelease` / `onQuestUpdate` handlers, `addScript` /
  `removeScript` / `hasScript`, `Inventory:getAll/find/findAll`, equipment, stance, skills,
  `core.factions`, `core.sound`, `castRay`, `Player.quests` / `addTopic`,
  `world.mwscript.getGlobalVariables` and `Lockable` are `partial` or `full`. Each partial one
  is a `partialApis` entry with its note (`kind` `symbol`, `method`, `typedMethod`,
  `engineHandler` or `scriptFlag`). In the 25-mod test corpus, 5 more mods are `ready`.
- **Still blockers:** MENU and LOAD scripts, `ui` layouts / widgets / templates (`ui.create`,
  `ui.content`, `I.MWUI`), `openmw.animation` and `I.AnimationController`, `camera`,
  `postprocessing`, `menu`, `content`, magic effects / `activeEffects` / `activeSpells`,
  `onTeleported`, `Inventory:resolve`, `GameObject.globalVariable`.
- CUSTOM scripts may use actor-only APIs (`I.AI`) without a scope blocker, since the scanner
  cannot know what they get attached to (omwcompat provides them on actors only).
- Manifest: `legacySymbols` (new key) lists API that OpenMW 0.51 removed but omwcompat still
  provides (`async.newRealTimer`, `self.ownerRecordId`, `types.Actor/Item.record(s)`,
  `types.<Actor>.equipment`). `scan` accepts them; `api-audit` leaves them out of `stale`.
- Runtime files (`MWSE/lib/omwcompat*`) are written with LF line ends and no BOM whatever the
  checkout has (a Windows clone with `core.autocrlf=true` used to produce CRLF copies).
- Every converted mod's MCM tab starts with a **Mod enabled** switch (default on, saved in
  `MWSE/config/omwcompat_<Mod>.json`). It is runtime-only and adds nothing to `--json`. Off and
  on take effect from the next frame without a reload; see
  [GAPS.md](GAPS.md#per-mod-enabled-switch-040).
- `main.lua` declares `BUILT_FOR = "0.4.0"`; the mismatch line and the dev override are
  unchanged.

## JSON result (abridged)

```json
{
 "tool": "omw2mwse", "version": "0.3.0", "command": "convert", "mode": "normal",
 "dir": "...", "dryRun": false, "changed": true, "exitCode": 0, "alerts": [], "pendingRecovery": [],
 "mods": [{
   "name": "LeaveTheLightsOff", "source": "Off/LeaveTheLightsOff/OpenMW",
   "off": "Off/LeaveTheLightsOff/OpenMW",
   "relocatedFrom": "Off/OpenMW/LeaveTheLightsOff",
   "status": "ok", "verdict": "ready", "coverage": [46, 46],
   "settings": {"groups": [], "coverage": [0, 0], "mcm": false},
   "rewrites": [], "hardcodeLog": [], "conflicts": [],
   "files": {"MWSE/mods/mwsuite/openmw/LeaveTheLightsOff/main.lua": "created"},
   "newGameRequired": false,
   "notice": "Unofficial mwsuite conversion of ... (original author: ...). Unofficial conversion by mwsuite. Do not contact the original author about it. Support: dej (dejunai) via the Nexus Mods forums.",
   "partialApis": [{"api": "openmw.vfs.open", "kind": "symbol", "count": 1,
                    "uses": [{"file": "scripts/LeaveTheLightsOff/LTLO_g.lua", "line": 201}],
                    "missing": "loose files only (BSA contents cannot be read); ..."}],
   "guards": {},
   "plugins": [
     {"name": "No Fires in Bad Weather.esp", "source": "No Fires in Bad Weather.omwaddon",
      "sourceRel": "No Fires in Bad Weather.omwaddon", "kind": "esp",
      "placement": "root", "status": "required", "path": "No Fires in Bad Weather.esp",
      "reason": "hosted Lua references getGlobalScript("wetfire_weather_monitor")"}
   ],
   "alerts": [
     {"level": "info", "code": "hardcode-candidate", "file": "scripts/LeaveTheLightsOff/LTLO_g.lua",
      "line": 396, "kind": "literal", "context": "clockHour < 7", "type": "number", "value": "7",
      "function": "onUpdate", "autoPick": false, "message": "..."},
     {"level": "error", "code": "blocker", "message": "requires unsupported module openmw.ui"},
     {"level": "warning", "code": "settings-renderer-fallback", "renderer": "SuperSlider6", "count": 4}
   ]
 }]
}
```

`status` is `ok`, `conflict` or `refused`. Alert codes: `hardcode-candidate`, `blocker`
(the mod will not run fully), `scan-warning`, `settings-renderer-fallback`, `mesh-missing`,
`duplicate-source`, `sidecar-ignored`, `hardcode-none`, `no-openmw-scripts`, `interrupted-run-pending`.
On a first run that relocates a legacy `Off/OpenMW/<Mod>/` (or other in-folder) package,
`source` is the canonical `Off/<Mod>/OpenMW` path and `relocatedFrom` names the previous
location. A `--dry-run` reports `willRelocateTo` instead and writes nothing.
`newGameRequired` is always `false` from omw2mwse: settings live in
`MWSE/config/omwcompat_<Mod>.json`, not in the save. Switching an existing save from some
other implementation of the same mod (such as Dej's LTLO hand port) is a separate matter; omw2mwse
cannot tell, so tidy should say so when it replaces a non-omw2mwse `main.lua` (the `conflict` case).

## Plugins

Every plugin in the original package (a loose `.esp`/`.esm`, or an `.omwaddon`/`.omwgame`
installed as `.esp`/`.esm`) is listed in `mods[].plugins` and in `omw2mwse-manifest.json`
under `plugins`. Tidy should act on `placement` and `status`, not on the filename, and
must not parse readmes or FOMOD text for this decision (omw2mwse does not either).

Each entry is:

```json
{"name": "wildlife_getfight.esp", "source": "wildlife_getfight.esp",
 "sourceRel": "wildlife_getfight.esp", "kind": "esp",
 "placement": "off", "status": "obsolete",
 "path": "Off/wildlife_attacks_npc/OpenMW/wildlife_getfight.esp",
 "reason": "hosted Lua references record id \"ll_fight_token\" only inside a dead API_REVISION branch (omwcompat API_REVISION=70); no live reference to this plugin's records (ll_fight_token, ll_getfight)"}
```

- `name`: the installed filename after any `.omwaddon` -> `.esp` rename (even when the file is not at the Data Files root).
- `source`: the filename in the original package (`Fires.omwaddon` when `name` is `Fires.esp`).
- `sourceRel`: the original-package relative path (`optional/Extra.esp`, or a root filename).
- `kind`: `esp` or `esm`.
- `placement`: `root`, `extras`, or `off`. This is where the installed copy lives (see `path`).
- `status`: `required`, `undetermined`, or `obsolete`.
- `path`: the destination relative to the staged Data Files root.
- `reason`: a short, rule-based explanation (also copied into `OMW2MWSE-REPORT.md`).

The boolean `optional` field from 0.2.2 is gone. Tidy should **auto-enable only** plugins
with `placement` `root` (status `required` or `undetermined`). Plugins with placement
`extras` or `off` are not in the load order.

### Placement rules (code only)

These rules are decided entirely in omw2mwse. There is no prompt, no AI, and no
readme or FOMOD heuristic.

1. **A plugin in a package subfolder, not at the root, goes to `Extras/<Mod>/`**,
   keeping the original relative path (with `.omwaddon`/`.omwgame` renamed). Example:
   `optional/Extra.esp` becomes `Extras/<Mod>/optional/Extra.esp`. This replaces the
   earlier `optional/` / `legacy/` folder and FOMOD-group logic for placement. The
   original file also stays under `Off/<Mod>/OpenMW/`. Tidy does not look inside
   `Extras/`; the end user inspects it themselves. `status` is still filled from the
   Lua analysis so a required plugin in Extras is obvious, but it is not auto-enabled.

2. **A root plugin that is provably obsolete goes to `Off/<Mod>/OpenMW/...`** with
   the rest of the original package and is **not** installed at the Data Files root.
   Provably obsolete means the hosted Lua references the plugin's introduced records
   *only* inside branches pruned as dead under `API_REVISION = 70` (omwcompat; assume
   post-0.49 OpenMW). That is why `wildlife_getfight.esp` lands in `Off/`:
   `ll_fight_token` is only read in the `core.API_REVISION < 59` branch, and
   `ll_getfight` is never referenced. A second `convert` run on a folder that still
   has the plugin at the root moves it into `Off/` when the file still matches the
   original (or, on a later run, when the previous manifest owns the root copy).

3. **Every other root plugin is left at the Data Files root and enabled by default.**
   That includes:
   - `required`: live hosted Lua references an introduced record (for example
     `getGlobalScript("wetfire_weather_monitor")` makes `No Fires in Bad Weather.esp`
     required).
   - `undetermined`: hosted Lua does not reference the plugin at all (live or dead).
     The plugin stays at the root because MWScript or records may still need it.

omw2mwse parses the TES3 file and collects the record ids the plugin *defines*
(introduces), not merely overrides on a master: always `SCPT`, `SSCR` and `GLOB`;
and any other named record, except that when the plugin lists masters, an object
record (`CREA`, `NPC_`, `LIGH`, ...) whose only hook is a `SCRI` pointing at a
script defined in the same plugin is treated as a master override (the Wildlife
`wildlife_getfight.esp` pattern: it attaches `ll_getfight` to vanilla creatures).
Those override ids are ignored, so a Lua table of vanilla creature ids does not
make the hook ESP required.

If a TES3 file cannot be parsed, a root plugin is **required** and left at the root
(`reason` says so). Unparseable Lua is treated as live (safe: may mark required,
never obsolete). A root `.omwaddon` that cannot be installed because the package
also ships the same `.esp` name stays only under `Off/`, with a clash warning;
`status` still reflects the Lua analysis.

## Credits and the support notice

Every build says it is an unofficial mwsuite conversion, credits the original mod, author,
license and page, and carries ONE fixed support line, the same whether conflict-tools or
MWManager packed it:

> Unofficial conversion by mwsuite. Do not contact the original author about it. Support: dej (dejunai) via the Nexus Mods forums.

(`SUPPORT_LINE` in `build.py`, `C.SUPPORT` in `conversions.lua`; a test keeps them equal.)
In game all converted mods share one Mod Config entry, **MW Conversions**: tab 1 is a fixed
general disclaimer (including that converted mods are for personal use only and must not be
redistributed), and every converted mod gets its own tab from tab 2 on, always, even with
nothing to configure. Each tab shows the original mod name, original author and the support
line. The same text goes in the MWSE.log registration line, the metadata, the README and the
report. Mod name, author and page come from, in order: `--title` / `--author` / `--license` /
`--source-url`, the sidecar's `[mod]` table, then metadata found next to the source
(`fomod/info.xml` Name/Author/Website, or an original `*-metadata.toml`; `convert` also looks in
the staged folder root). Without any of these the tab says `Original author: unknown`; tidy
should pass the options when it knows them.

## Migrating a 0.2.0 layout

`convert` recognises the 0.2.0 locations (`MWSE/mods/<Mod>/main.lua`, `MWSE/omw/<Mod>/`) via
their manifest, removes those files when they are unmodified, and writes the new layout. A
hand-written `MWSE/mods/<Mod>/main.lua` is left alone and reported (`legacy-loader-present`).

## Several converted mods in one load order

Each converted mod bundles the same `MWSE/lib/omwcompat` files. Vortex reports these as file
conflicts between the mods; the files are identical, so either winner is fine. Keep all
converted mods built by the same omw2mwse version (the runtime is always written into each
staged mod since 0.3.1; `--no-runtime` is ignored).
