# Developer notes

How to run the converter by hand, the tests, and what a build contains. End-user
information is in the [README](../README.md).

Requirements: Python 3.9+ (stdlib only, no dependencies; `requires-python = ">=3.9"` in
`pyproject.toml`) for `omw2mwse`, developed on 3.15 and tested on 3.9 and 3.15; LuaJIT for the
runtime tests. On 3.9/3.10 TOML is read by the built-in `tomlcompat` reader (stdlib `tomllib`
from 3.11). Keep the code 3.9-clean: `from __future__ import annotations` in every module that
uses `X | None` annotations, no `match`, no other 3.10+ syntax or stdlib APIs.

## Quick start

```sh
bin/omw2mwse scan path/to/openmw-mod
bin/omw2mwse package path/to/openmw-mod --name ModName --out staging/ModName
tests/run_lua_tests.sh                       # LuaJIT + MWSE mock scenarios
python3 -m unittest discover -s tests/py     # CLI unit tests (also run with python3.9)
bin/omw2mwse recover path/to/staged          # report convert runs that were interrupted
bin/omw2mwse recover path/to/staged --rollback
```

The Python tests also run on Windows (`py -3.9 -m unittest discover -s tests/py`); the
hard-link regression (`test_hardlink_not_modified_in_place`, and the hard link in
`test_recovery`) needs a filesystem where the user can create hard links (NTFS does).
Machine-readable paths follow the path contract in
[TIDY-INTEGRATION.md](TIDY-INTEGRATION.md#path-contract-machine-readable-paths): build them
with `build.portable_path`, and compare absolute paths in tests with Windows semantics
(`ntpath.normcase(os.path.realpath(...))`, see `same_abs` in `tests/py/test_recovery.py`).

The output of `package` mirrors `Data Files`:

```
Data Files/Off/<Mod>/OpenMW/...              complete original OpenMW package (author paths)
Data Files/MWSE/mods/mwsuite/openmw/<Mod>/main.lua   generated loader (register with omwcompat)
Data Files/MWSE/mods/mwsuite/openmw/<Mod>/omw/...    hosted .omwscripts + Lua
Data Files/MWSE/lib/omwcompat.lua, omwcompat/ the runtime (always)
Data Files/meshes/, textures/, ...           original game assets (also under Off/)
Data Files/meshes/omwc/<slug>/<hash>.nif     short aliases for long mesh paths
Data Files/<Mod>-metadata.toml               MWSE metadata
MESH-ALIASES.txt                             long mesh path -> short alias
OMW2MWSE-REPORT.md                           scan + file list with hashes
```

## Rule-based guards and timing (0.2.4 / omwcompat 0.3.2)

- `tools/omw2mwse/patterns.py` detects the `active-collect-dedupe` and `mutate-during-iteration`
  patterns (token based, per file). `scan.pattern_findings` maps findings to declared scripts
  through `scan.script_closures` (a script gets the guards of every file it loads); the result
  is `ModScan.patterns` / `ModScan.guards`, `partialApis` entries of kind `pattern`
  (`scan.pattern_partials`, notes in `PATTERN_NOTES`), `guards` in `--json`, report notes, and
  `guards = { ... }` per script in `main.lua` (`build.render_main`). Contract:
  [TIDY-INTEGRATION.md](TIDY-INTEGRATION.md#rule-based-workarounds-pattern-entries-and-guards-024--omwcompat-032).
- The runtime side is `omwcompat/guards.lua`; timing counters are `omwcompat/timing.lua`
  (see [RUNTIME.md](RUNTIME.md#timing-counters-032)).
- Tests: `tests/py/test_patterns.py` (detector, scan, convert JSON, `main.lua`, report),
  `tests/lua/test_guards.lua` (guards with and without, on `tests/fixtures/active-collect`, a
  fixture written for the tests and modeled on the No Fires in Bad Weather pattern) and
  `tests/lua/test_timing.lua` (timing, periodic log, one traceback per site, factions).
  `tests/run_lua_tests.sh` rebuilds `staging/LeaveTheLightsOff` when the runtime in it is older
  than `runtime/`, so the Lua suites always run against the current runtime.
- To add a rule: a detector in `patterns.py` (with a `GUARD_FOR_RULE` entry and a
  `PATTERN_NOTES` text), the guard in `guards.lua` (`KNOWN`, `RULE_IDS`, `apply`), tests on
  both sides. Never patch a mod's Lua.

## Scanner rules and the OpenMW API audit (0.2.5)

Scanner (`tools/omw2mwse/scan.py`, value tables in `tools/omw2mwse/apitypes.py`, our own):

- `local ok, X = pcall(require, 'openmw.x')` and `pcall(function() return require('openmw.x') end)`
  alias `X` like a plain `require`; the module is listed in `guardedRequires` with a warning
  (the mod checks whether it exists). An unsupported module is still a blocker.
- Aliases come from `local a = <chain>` with exactly one target and from positional multiple
  assignment (`local p, c = self.position, self.cell`). Table keys (`{ type = ui.TYPE.X, }`) and
  field targets (`t.x = core.sound`) are not aliases.
- A member below a manifest entry no longer inherits the parent's status. It inherits only below
  an `unsupported` entry or for an ALL_CAPS enum leaf. Otherwise it is looked up through the
  parent's value type (`self.rotation` -> Transform, `self.cell` -> Cell, `recordId` -> string;
  `MEMBER_TYPES`, `TYPE_MEMBERS`), and `openmw.self.type.X` is classified as
  `openmw.types.Actor.X`. Anything not in our tables is `unlisted`: a warning, not a blocker, and
  not counted as covered.
- Method calls on typed values are counted in `typedMethods`: `Cell:getAll`, `Inventory:countOf`,
  `Transform:getAnglesZYX`, `StorageSection:get`, `Type.createRecordDraft`, ... The receiver type
  comes from the chain or a local (`local inv = types.Actor.inventory(o)`, `apitypes.returns`).
  With no known receiver, only distinctive names count, as `?:<name>` (best status of the types
  that have it). Plain Lua string methods are never counted. Unsupported ones are blockers
  (`unsupported method Inventory:getAll (1x)`); partial ones are `partialApis` kind `typedMethod`.

OpenMW API audit (`tools/omw2mwse/apicatalog.py`). This is optional: nothing needs it, and
`scan`/`convert` give the same verdicts without it.

```sh
bin/omw2mwse api-audit --fetch openmw-0.51.0          # download the stubs of one tag into the cache, then audit
bin/omw2mwse api-audit --openmw-src ~/src/openmw      # an OpenMW source tree (files/lua_api/openmw)
bin/omw2mwse api-audit --openmw "C:/Games/OpenMW 0.51.0"   # an install (resources/lua_api/openmw)
bin/omw2mwse api-audit --json --limit 0               # full lists as JSON
bin/omw2mwse scan path/to/mod --no-openmw             # scan without the catalog
```

- Lookup order: `--openmw` / `--openmw-src`, `$OMW2MWSE_OPENMW` (`none` turns the lookup off),
  the newest version in the cache, then common install paths: `OpenMW*` under Program Files and
  under `X:\`, `X:\Games` and `X:\Program Files` for drives C-H, Linux/macOS paths, and the
  parents of the `data=`/`resources=` lines of the user's `openmw.cfg`. `--no-installs`
  skips the install paths. Nothing found: `api-audit` prints that and exits 0; `scan` runs as
  before.
- Cache: `--api-cache DIR`, `$OMW2MWSE_API_CACHE`, else `%LOCALAPPDATA%/omw2mwse/openmw-api` or
  `~/.cache/omw2mwse/openmw-api` (`$XDG_CACHE_HOME`). `--fetch TAG` lists
  `files/lua_api/openmw` at that tag through the GitHub contents API, downloads only those `.lua`
  files from raw.githubusercontent.com into `<cache>/<version>/files/lua_api/openmw/`, and writes
  `SOURCE.json` (tag, version, API revision read in memory from that tag's `CMakeLists.txt`, and
  sha256 of each file). An earlier complete download is reused; `--refresh` downloads again.
- **Never commit or vendor OpenMW's API files.** They are GPLv3. They are read at run time from
  the user's own copy only. `/openmw-api-cache/` is git-ignored for a cache inside the clone. The
  tests use `tests/fixtures/openmw-api-stubs`, a tiny stub set we wrote ourselves in the same
  tag format.
- With a catalog, `scan` adds `apiCatalog`, `inOpenMW` per symbol and typed method, and
  `unknownToOpenMW`, plus a warning per symbol OpenMW does not have. That usually means another
  OpenMW version or a typo; interfaces are not judged, since mods add their own. `unlisted`
  means only that omwcompat's tables do not list it. Verdicts never change. Contract and fields:
  [TIDY-INTEGRATION.md](TIDY-INTEGRATION.md#scanner-fields-and-the-openmw-api-audit-025).
- Tests: `tests/py/test_scanner_forms.py` (fixture `tests/fixtures/scanner-forms`, our own code
  modeled on common OpenMW Lua patterns) and `tests/py/test_apiaudit.py` (parse, layouts,
  lookup, fetch with a fake downloader, audit, CLI, scan with a catalog; no network).

## omwcompat 0.4.0 / omw2mwse 0.3.0: hosting, the Enabled switch, line ends

- **Where things are.** `runtime.lua`: CUSTOM/PLAYER hosting (`attachLocal(ref, onlyMod)`,
  `startLocal`, `RT.addScript` / `removeScript` / `hasLocalScript`, `state.attached`,
  `state.playerInst`), player handlers (`RT.playerHandlers`, `RT.onKey`, `RT.onJournal`),
  built-in local events (`BUILTIN_LOCAL`), `world.mwscript.getGlobalVariables`, and the switch
  (`encodeMod` / `loadMod` used by save/load, `freezeMod` / `resumeMod`, `RT.setEnabled`).
  `settings.lua`: `modEnabled` / `setModEnabled` and the switch at the top of `addTab`.
  `objects.lua`: `Lockable`, `owner`, `startingCell`, the `enabled` setter, inventory items
  (`invItem`, `inv:` ids rebuilt by `fromId`), `addScript` methods. `actors.lua`: equipment,
  stance, level, skills, controls, Player functions, `core.factions`, `castRay`. `player.lua`:
  KEY table (OpenMW names, SDL scancodes, DirectInput codes), `ui` / `ambient` / `input` /
  `core.sound` modules.
- **API facts** come only from the OpenMW 0.51.0 stubs (local, git-ignored cache) and the OpenMW
  docs ("Events" for `ShowMessage` / `Unequip` / `PlaySound3d`); MWSE facts from the MWSE docs.
- **Manifest.** New hosted APIs need a manifest status, a `PARTIAL_NOTES` text in `scan.py` for
  every `partial` one (`test_every_partial_symbol_has_a_specific_note` checks), and a Lua test.
  API removed from OpenMW but still provided goes to `legacySymbols` (scanner yes, audit no).
- **Line ends.** `build.runtime_file_bytes` writes `.lua/.json/.md/.txt/.toml` runtime files
  with LF and no BOM (`tests/py/test_v030.py` packages from a CRLF copy of the runtime). The
  repository itself has no `.gitattributes`; a Windows clone with `core.autocrlf=true` keeps
  CRLF in the work tree, which is fine now.
- **Tests.** `tests/lua/test_v040.lua` (every new API, the switch off/on mid-game and across
  save/load, CUSTOM persistence, PLAYER handlers, built-in events), `tests/lua/mock_mwse.lua`
  (messageBox, sounds, items, locks, owners, journal, factions, rayTest, input, equip/unequip,
  skills), `tests/py/test_v030.py`. `tests/run_lua_tests.sh` rebuilds the git-ignored test
  staging `staging/LeaveTheLightsOff` whenever `runtime/` changed.

## omwcompat 0.4.1: silent off lights, MENU settings, table-valued renderers

- **Sound gate.** `runtime.lua` `RT.onAddSound` / `soundBlockReason` / `RT.soundGate` (registered
  on `addSound` at priority 1000 in `wire()`); `objects.lua` `silence(ref)` (called by `remove()`
  and the `enabled = false` setter), `isGeneratedId`, and `_removedRecordId` (a removed object
  keeps its `recordId`). See [RUNTIME.md](RUNTIME.md#sound-gate-041).
- **MENU scripts.** `RT.register` puts MENU scripts of a `probeSettings` mod in
  `m.menuSettingsOnly`; the probe in `instantiate` warns once if such a script returns handlers.
- **Table-valued renderers.** `settings.lua` `isRecordValue`, `recordKeys`, the `record` branch
  of `addSetting`; `registerRenderer` only records the name now (`M.customRenderers`).
- **Tests.** `tests/lua/test_v041.lua`: the swap pattern with a mock engine that plays light loops
  like Morrowind (`mock.engineSounds`, `W.loops`, `W.notPlayingQuirk`), a control run with the
  0.4.0 behaviour that reproduces the runaway, then the fixed run; the original No Fires in Bad
  Weather and ThievesPickpocket settings when the untracked corpus is present.

## omwcompat 0.4.2: animations degrade quietly, NPC disposition

- **Why.** Before 0.4.2 `require('openmw.animation')` raised "module ... is not supported", so a
  script that requires it never started (Thieves Pickpocket's `tpickpocket_local.lua`, in game
  2026-11-26). Animations stay out of scope; the API is there so the rest of the mod runs.
- **Where.** `actors.lua` `animationModule(modName)`, `animationControllerInterface(modName)`,
  `animNote` / `animCalls`; `runtime.lua` `buildModules` adds `openmw.animation` for every script,
  `makeInterfaces` adds `I.AnimationController` for actor scripts. `actors.lua`
  `getDisposition` / `getBaseDisposition` / `setBaseDisposition` / `modifyBaseDisposition`.
  See [RUNTIME.md](RUNTIME.md#animations-042-stubs-050-mapping).
- **Converter.** Unchanged (omw2mwse 0.3.1): `manifest.json` keeps `openmw.animation` in
  `unsupportedModules`, so scanner verdicts and coverage numbers do not move.
- **Tests.** `tests/lua/test_v042.lua`: every `openmw.animation` / `I.AnimationController` call,
  the safe return values, one warning per mod across 100 more calls and a save/load, a gesture
  finished by the mod's own timer, disposition, and the original `tpickpocket_local.lua` running
  300 frames without an error when the untracked corpus is present.

## omwcompat 0.4.3: control writes degrade quietly

- **Why.** After 0.4.2, `require('openmw.animation')` no longer raised, but Thieves Pickpocket's
  `stopTracking` still aborted `onInactive` by writing `self.controls.yawChange = 0`
  (MWSE.log 2026-11-27 04:00:03). `finishApology` and `setAI(true)` never ran.
- **Where.** `actors.lua` `controlsOf` `__newindex`: warn once, ignore the write. See
  [RUNTIME.md](RUNTIME.md#movement-controls-043-050).
- **Converter.** Unchanged (omw2mwse 0.3.1).
- **Tests.** `tests/lua/test_v043.lua`: writes no longer raise, one warning per field across
  50 more writes, `onInactive` finishes, and the original `tpickpocket_local.lua` deactivates
  without an error when the untracked corpus is present.

## omwcompat 0.4.4 / omw2mwse 0.3.2: library log

- **Why.** Dej asked that MWSE.log keep only initialization lines. Post-init output is debug,
  and converted mods must not spam MWSE.log the way other authors' mods do.
- **Where.** `runtime.lua` opens `Data Files/MWSE/logs/omwcompat.log` at load (folder created
  with `lfs`, previous file kept as `omwcompat.log.prev`, every line flushed). `RT.warn` /
  `warnOnce` / `RT.log` / `reportError` / hosted `print()` / the sound gate / the timing line /
  a settings reload / `RT.note` all write there. MWSE.log gets the `loaded` banner, a pointer
  to the file, and each `registered <mod>` line. See [RUNTIME.md](RUNTIME.md#library-log-044).
- **Converter.** omw2mwse 0.3.2: generated `main.lua` sends a BUILT_FOR mismatch through
  `omwcompat.note or mwse.log`, so 0.4.4 writes it to the library log and older runtimes still
  log it. Already-converted mods do not need a re-convert for `print()` or runtime warnings
  (those are the shim); they do if the BUILT_FOR line should leave MWSE.log.
- **Tests.** `tests/lua/test_v044.lua`: rotation of `.prev`, the exact MWSE.log init lines,
  `print()` / warnings / errors staying off MWSE.log, `RT.note`, and fallback to MWSE.log when
  the file cannot be opened. `tests/lua/test_versions.lua` covers the `note` hook and the
  older-runtime fallback.

## omwcompat 0.5.0: ported stubs (sound gate one-offs, animations, controls)

- **Sound gate.** `runtime.lua` `gate(e, temp)` backs `RT.onAddSound` and the new
  `RT.onAddTempSound` (both priority 1000 in `wire()`); `soundBlockReason(ref, snd, temp)` adds
  the `disabled` kind via `objects.isScriptDisabled(ref)` (a weak set filled by the
  `enabled = false` setter, cleared by `enabled = true`). `RT.soundGate` gained `disabled` and
  `oneOff`. See [RUNTIME.md](RUNTIME.md#sound-gate-041).
- **Animations.** `actors.lua` animations section: `groupIdOf` / `groupNameOf` (built lazily
  from `tes3.animationGroup`), `play()` shared by playBlended / playQueued / the interface,
  `plays[ref]` (weak) polled by `M.animTick()` from `frameWork`, `controllers` (weak; only
  controllers with text key or ended handlers), `M.onPlayGroup` (registered lazily on the first
  text key handler). `animationControllerInterface(modName, getSelf, S)` now takes the script.
  See [RUNTIME.md](RUNTIME.md#animations-042-stubs-050-mapping).
- **Controls.** `actors.lua` `writeControl` / `controlsOf`; counts in `M.controlWrites`.
  See [RUNTIME.md](RUNTIME.md#movement-controls-043-050).
- **Manifest (scanner gate).** The manifest now matches what the runtime handles. A stub is a
  warning, not a blocker. `openmw.animation` has moved from `unsupportedModules` to `modules`
  (partial), with every documented member listed (mapped: partial, no-op: stub, enums: full).
  `openmw.interfaces.AnimationController.*` is partial. `self.controls.yawChange`, `movement`
  and `sideMovement` are partial (reads work); `pitchChange` and `use` are stub. Notes for the
  partial report are in `scan.py` `PARTIAL_NOTES`. Re-scanning the 191 survey mods (2026-11
  survey) leaves 50 fewer mods with an animation or controls blocker (63 -> 13; the rest are
  engine-internal `_onPlayAnimation` copies and undocumented calls). One more mod is ready:
  TinkerSnail/pinchito (168 -> 167 blocked). Thieves Pickpocket goes from 20 to 15 blockers,
  all UI.
- **Tests.** `tests/lua/test_v050.lua`. The mock gets `addTempSound` / `playGroup`,
  `tes3.playAnimation`, `animationData` and `facing` there, not in `mock_mwse.lua`.
  `test_v042.lua` / `test_v043.lua` were updated for the new semantics: handler registration
  is no longer a no-op, and `yawChange` on an NPC is applied.

## omwcompat 0.5.0 (first written as 0.4.5 on smoke-test): diagnostics hooks and the smoke test mod

- **Why.** An optional in-game self check (`omwcompat_smoketest`) needs to look inside the runtime
  without changing it. See [SMOKETEST.md](SMOKETEST.md).
- **Where.** `omwcompat/diag.lua` (`RT.diag`): `inspect`, `compileCheck`, `readSettings`, `capture`,
  `probeStubs`, `roundTrips`, `payloadCheck`; `runtime.lua` has a capture list in `writeLib` /
  `warnOnce` and `RT._setCapture`. Probes must never leave state behind: `capture` restores error
  counts, sound gate counters and `actors.animCalls`.
- **Mod.** `smoketest/MWSE/mods/mwsuite/openmw/omwcompat_smoketest/` (`checks.lua` pure checks,
  `runner.lua` report writer, `fixtures.lua` dev test cell, `main.lua` events and MCM).
- **Plugin.** `smoketest/esp/omwc_smoketest.esp.json` -> `scripts/build-smoketest-esp.py` (tes3conv).
- **Tests.** `tests/lua/test_smoketest.lua`, `tests/py/test_smoketest_esp.py`; the mock gained
  `event.unregister/isRegistered`, `createKeyBinder`, `createTableVariable`, `tes3.getPlayerCell`
  and the `saved` event.

## Further reading

- [RUNTIME.md](RUNTIME.md): how the emulation works, local scripts, object-lifecycle rules.
- [GAPS.md](GAPS.md): known differences from OpenMW.
- [COVERAGE.md](COVERAGE.md): the test corpus.
- [TIDY-INTEGRATION.md](TIDY-INTEGRATION.md): the `convert` contract used by conflict-tools' tidy.
- [../DESIGN.md](../DESIGN.md): architecture and reasoning.

The `reference/`, `corpus/` and `staging/` folders are local only and git-ignored. Third-party
mods are personal test material and are not redistributed here.
