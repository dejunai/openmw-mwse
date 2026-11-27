# openmw-mwse

> **EXPERIMENTAL - EARLY DEVELOPMENT.** This is beta software. Converted mods can
> behave differently from the originals, can fail, and can break saves or a load
> order. Back up your saves and your mod setup before you convert or enable
> anything. Expect missing features and breaking changes.

openmw-mwse converts **OpenMW-only Lua mods** into **MWSE mods** for the original
Morrowind engine (Morrowind.exe + MWSE). The original Lua is not rewritten to
MWSE: a runtime library named **omwcompat** provides the `openmw.*` API so those
scripts can run unmodified inside MWSE.

It is a personal project by **dej (dejunai)**. Current versions: **omw2mwse 0.3.2**
(the converter) and **omwcompat 0.4.4** (the runtime).

If you want the short path and are willing to accept the risk, see
[QUICK_START_GUIDE.md](QUICK_START_GUIDE.md). Come back here when something
looks wrong.

## What it is

The project has two parts:

- **omw2mwse** - the converter. It scans an OpenMW mod, reports which `openmw.*`
  APIs it uses, and rewrites the staged mod folder into an MWSE mod. It can be
  run by hand (see [Standalone use](#standalone-use)) or called by
  morrowind-conflict-tools' **tidy** (see [How it fits with tidy](#how-it-fits-with-tidy)).
  `omw2mwse api-audit` optionally checks omwcompat's API tables against OpenMW's
  own Lua API files (fetched on demand, never shipped).
- **omwcompat** - an MWSE Lua library that hosts the converted scripts and
  emulates the `openmw.*` API.

A conversion is unofficial. The original authors retain all rights to their mods,
are not affiliated with this tool, and have not necessarily reviewed or endorsed
the result.

## Requirements

To **play** a converted mod you need the original Morrowind engine and **MWSE**.
This project does not run under OpenMW.

To **run the converter yourself** you need **Python 3.9 or later**. There are no
third-party Python packages; the stdlib is enough. Development is on Python 3.15,
and the test suite is run on 3.9 and 3.15. The tool is not installed with pip:
run it from a checkout, with `bin/omw2mwse` (or `py -3 bin/omw2mwse` on Windows).

## How it fits with tidy

The converter is built to be called by **tidy**, the pass in
**morrowind-conflict-tools** that works on Vortex staging folders.

These rules are part of the contract, not optional flags:

- The converter runs **only on a staged mod folder** (a Vortex staging folder:
  the mod root that Vortex would merge into Data Files on deploy).
- It writes **all** of its output back into that staged folder, including a copy
  of the **omwcompat** runtime. `--no-runtime` is accepted and ignored: the
  runtime is always written into the staged mod.
- It **refuses** Data Files and game-install targets. If `--staged-root`,
  `--source`, `--sidecar`, `--meshes-from`, or the result file's folder is (or
  is inside) a folder named `Data Files`, a folder that holds `Morrowind.exe` or
  `Morrowind.esm`, or a folder that holds a `Data Files` folder with
  `Morrowind.esm`, the converter exits 3 and writes nothing to the target.
- **Data Files is touched only by Vortex's final deploy**, not by omw2mwse.
  Writes use a temp file plus `os.replace`, so a staged file that Vortex has
  hard-linked into Data Files is replaced in staging; Data Files keeps the old
  bytes until the next deploy.

The tidy handoff is:

```
omw2mwse --staged-root <staged mod dir> --result-json <file> [--dry-run]
```

`--result-json` must be a file **outside** the staged folder and outside Data
Files / a game install. `--dry-run` plans everything and writes nothing except
that result file. The same call works as `omw2mwse convert --staged-root ...`.
The contract, exit codes and JSON fields are in
[docs/TIDY_INTERFACE.md](docs/TIDY_INTERFACE.md).

## Where things land

All of the following are written **inside the staged mod folder**:

| Path | Contents |
|---|---|
| `MWSE/mods/mwsuite/openmw/<mod>/` | the generated MWSE loader (`main.lua`), the hosted Lua, a short report and `omw2mwse-manifest.json` |
| `MWSE/lib/omwcompat.lua` and `MWSE/lib/omwcompat/` | the shared runtime |
| `Off/<plugin>/OpenMW/` | the complete original package, moved here on a successful convert, file contents unchanged |
| original assets (`meshes/`, `textures/`, ...) | kept where the author put them (and also under `Off/`) |

**Plugins**

- `.omwaddon` / `.omwgame` files use the same format as `.esp` / `.esm`, so only
  the extension changes.
- A plugin at the package root stays at the root (installed as `.esp` / `.esm`)
  and is enabled by default when it is required or undetermined.
- A plugin that shipped in a subfolder goes to `Extras/<mod>/` for you to
  inspect. It is not auto-enabled.
- A root plugin that is provably obsolete (only referenced by code for old
  OpenMW versions) is kept under `Off/` only.

**Verdict.** Every conversion gets a verdict:

- **ready** - every API the mod uses is provided, fully or partially. Partial
  APIs do not change a ready verdict.
- **blocked** - the mod needs something omwcompat does not have yet, or the
  author opted out, or an output path is too long for Windows. Do not enable a
  blocked mod.
- **none** - there was nothing to convert (no `.omwscripts`).

On the tidy interface, a blocked or failed run writes only the result file; the
staged folder is left alone. tidy then moves the original plugin to
`Off\<plugin>\OpenMW\` itself.

## What converts, what is stubbed, and what is skipped

**Script kinds omwcompat hosts**

- `GLOBAL` scripts.
- Object-attached (local) scripts: `NPC`, `CREATURE`, `ACTOR`, `CONTAINER`,
  `DOOR`, `LIGHT`, `ACTIVATOR`. One instance runs per matching object while it
  is in an active cell; its saved data survives cell changes and save/load.
- `PLAYER` scripts and `CUSTOM` scripts (`addScript`), hosted since omwcompat
  0.4.0.
- `MENU` scripts are run once by the settings probe when the mod declares
  settings (since 0.4.1), so their `I.Settings` pages reach the MCM. Engine and
  event handlers returned by a MENU script are not run. `LOAD` and `ITEM`
  scripts are skipped, with a warning.

**APIs that are provided** (many of them only partially)

- `openmw.core` (time, events, GMSTs, content files, weather), `openmw.world`
  (in global scripts), `openmw.types` (lights, actors, items, containers, doors,
  records, inventories, NPC disposition), `openmw.util`, `openmw.async` (timers),
  `openmw.storage`, `openmw.vfs` (loose files), `openmw_aux.util`,
  `openmw_aux.time`, `openmw_aux.calendar`.
- `openmw.self` and `openmw.nearby` in local and player scripts.
- Actor stats: health/magicka/fatigue, attributes, skills, AI fight/flee/alarm/
  hello, `isDead`, equipment, stance, level.
- Interfaces: `I.Activation`, `I.Settings` (shown as an MCM), and `I.AI` in
  actor scripts (combat, wander, travel, follow, escort). `I.AI` can start those
  packages; `removePackages` only removes combat packages.
- `world.mwscript.getGlobalScript` (read/write vanilla global script variables).
- Engine handlers: `onInit`, `onLoad`, `onSave`, `onUpdate`, `onNewGame`,
  `onPlayerAdded`, `onObjectActive`, `onActorActive`, `onItemActive`,
  `onActivate`, and for local scripts `onActive`, `onInactive`, `onActivated`.
  Player scripts also have `onFrame`, `onKeyPress` / `onKeyRelease` and
  `onQuestUpdate`.

Exact differences are listed in [docs/GAPS.md](docs/GAPS.md).

**Settings become an MCM.** `I.Settings` pages and groups are collected
automatically and shown under the shared **MW Conversions** menu. Common
renderers (`checkbox`, `number`, `select`, `textLine`, `color`) get native MCM
controls. Since 0.4.1, a custom renderer whose value is a flat table of numbers
and/or booleans is expanded into one MCM control per key.

**Animations are not ported.** Since omwcompat 0.4.2, `openmw.animation` and
`I.AnimationController` exist so a script that requires them keeps running, but
every call does nothing and queries answer "not playing". The first call from
each mod logs one warning; later calls are counted, not logged. The converter
still treats `openmw.animation` as unsupported, so a mod that needs animation
stays **blocked** even though the runtime no longer errors on the require.

**Movement-control writes are ignored.** `self.controls.sneak`, `run` and `jump`
can be read (the actor's current state). Other fields read as nil. Since
omwcompat 0.4.3, writes no longer raise: the first write of each field logs one
warning and is ignored; later writes are silent. The actor is not steered.

**HUD and UI are not ported**, except `ui.showMessage` (a message box). There are
no windows, layouts, widgets, templates or HUD elements. Mods such as ammo
counters and compasses are out of scope.

**Sound gate (omwcompat 0.4.1).** Morrowind will play a light's own loop even
when an OpenMW mod has turned that light off or removed it. omwcompat stops
sounds on objects it has removed or disabled, and it blocks an off-by-default
copy that it generated from playing its own loop. Other mods' lights and vanilla
records are not touched. The first block of each kind is logged once.

**Not provided:** `openmw.camera`, `openmw.postprocessing`, `openmw.debug`,
`openmw.menu`, `openmw.content`, and `openmw_aux.ui`. `openmw.ambient` and
`openmw.input` are partial (sounds and keyboard keys; not actions, triggers,
gamepad or mouse). `openmw.nearby` has `castRay` but no pathfinding. Custom
magic effects, active spells and effects are not available. Events sent to an
object outside the active cells are dropped.

## The "MW Conversions" menu

All converted mods share one Mod Config Menu entry, **MW Conversions**:

- **Tab 1** is a general disclaimer (experimental software, authors' rights, no
  warranty, support, no redistribution).
- **Then one tab per converted mod**, showing the original mod's name and
  author, its settings (if any), and that support for the conversion goes to
  **dej (dejunai)** via the Nexus Mods forums.
- **Every mod tab starts with a "Mod enabled" switch** (on by default), also for
  mods that have no settings. Switching it off stops that mod from the next
  frame, and switching it back on restarts it where it left off; no reload is
  needed. It does not undo what the mod already changed in your game. The choice
  applies to all your saves.

## Standalone use

From a checkout, with Python 3.9+:

```
bin/omw2mwse scan path/to/openmw-mod
```

That reports API usage and a verdict without writing a conversion.

To preview a conversion of a **staged** folder (writes only the result JSON):

```
bin/omw2mwse --staged-root path/to/staged-mod --result-json path/to/result.json --dry-run
```

To convert that staged folder in place:

```
bin/omw2mwse --staged-root path/to/staged-mod --result-json path/to/result.json
```

`path/to/result.json` must not sit inside the staged folder, Data Files, or a
game install. The older form `omw2mwse convert path/to/staged-mod` (with
optional `--dry-run` and `--json`) still works and obeys the same target
rules, but it does not use the tidy exit codes or the result file.

If a convert run is interrupted, `omw2mwse recover path/to/staged-mod` reports
it, and `omw2mwse recover path/to/staged-mod --rollback` undoes the unfinished
work. There is no `omw2mwse revert` command yet for a finished conversion
(tidy's `--undo` uses `omw2mwse-manifest.json` when tidy drove the convert).

Developer-oriented commands (`package`, `api-audit`, tests) are in
[docs/DEVELOPER.md](docs/DEVELOPER.md).

### Exit codes (tidy interface)

These apply when `--staged-root` and `--result-json` are used:

| code | meaning | writes |
|---|---|---|
| 0 | converted, or nothing to convert (`ready` / `none`) | the mod, runtime, manifest, moved originals |
| 1 | blocked (unsupported APIs, author opt-out, or paths too long for Windows) | result file only |
| 2 | failed (not a folder, a foreign file in the way, hard-code conversions not accepted, other build error) | result file only |
| 3 | refused target (Data Files or a game install) | result file only, or nothing |
| 64 | usage error (bad or missing arguments, or the result file is inside the staged folder) | nothing |
| 70 | internal error (a bug) | result file only; the staged folder may be partly written; `omw2mwse recover DIR --rollback` undoes it |

The result JSON includes `verdict`, `blockers`, `guards`, `runtime_version`,
`written_files`, `planned_files`, `removed_files`, `moved_files`,
`excluded_by_author`, `errors[]` and `mods[]`. See
[docs/TIDY_INTERFACE.md](docs/TIDY_INTERFACE.md).

## For mod authors: opting out

If you do not want your mod converted, you can opt out. The converter honors an
opt-out marker in a header comment of your mod's Lua scripts and then leaves the
mod untouched (verdict `blocked`, `excluded_by_author` true). No user-facing
output says which file or line held the marker. Contact **dej (dejunai)** via
the Nexus Mods forums for the exact wording.

## Reading the logs

MWSE.log is kept nearly silent after load, so this library and the converted
mods do not spam it the way other authors' mods often do. Post-init output
goes to `Data Files/MWSE/logs/omwcompat.log`. That `logs/` folder sits next
to `lib/`, `mods/` and `config/` under `Data Files/MWSE/`. Each line is
timestamped (`YYYY-MM-DD HH:MM:SS`) and flushed. At session start the previous
file is kept as `omwcompat.log.prev` (one copy). If the file cannot be opened,
one MWSE.log line says so and further messages fall back to MWSE.log.

**MWSE.log only gets these initialization lines:**

- `[omwcompat 0.4.4] loaded`
- `[omwcompat 0.4.4] library log: Data Files/MWSE/logs/omwcompat.log`
- `[omwcompat 0.4.4] registered <Mod> (N script(s)).` once per registered mod
  (a short support notice may follow on the same line)
- `[omwcompat 0.4.4] could not open Data Files/MWSE/logs/omwcompat.log (...);
  further messages go to MWSE.log` if the library log could not be opened
- `[<Mod>] omwcompat runtime is missing or failed to load: ...` from the
  generated `main.lua`, because the library never loaded

**Everything else goes to the library log:** warnings, errors with a traceback
(on the first error of a site), stub and sound-gate notices, debug,
converted mods' `print()`, and a BUILT_FOR mismatch from a conversion built
by omw2mwse 0.3.2 (that line is sent through `omwcompat.note`). A few of
those lines are normal and are not a crash:

- `[omwcompat 0.4.4] SomeMod was built for omwcompat 0.4.0 (loaded 0.4.4)` -
  the shared runtime in Data Files is newer (or older) than the one the
  converter bundled when that mod was built. Newer runtimes are meant to keep
  running older conversions. Nothing is logged when the versions match. A mod
  converted with omw2mwse older than 0.3.2 still writes this line to MWSE.log;
  re-convert it to move the line into the library log. Already-converted mods
  do not need a re-convert for `print()` or runtime warnings: those go through
  the 0.4.4 shim.
- `<mod>: <call> does nothing: animations are not ported by omwcompat ...` -
  one warning per mod the first time it touches `openmw.animation` or
  `I.AnimationController`. Later calls are counted, not logged. Animations do
  not play.
- `self.controls.<name> cannot be set: movement controls are not emulated by
  omwcompat ...` - one warning per field the first time a script writes
  `self.controls`. The write is ignored; the script continues.
- `[omwcompat] sound gate: kept ... from playing ...` - one log the first time
  the sound gate blocks a removed or off-by-default light. Later blocks are
  counted, not logged.

Treat these as real problems (in the library log, or on MWSE.log if the file
could not be opened):

- `omwcompat runtime is missing or failed to load` (always on MWSE.log) - the
  shared library did not reach Data Files. Check the Vortex deploy and that
  some converted mod actually won the `MWSE/lib/omwcompat*` conflict.
- `ERROR in ...` with a traceback, or `is not supported` that is not one of the
  one-line warnings above - the script hit something the runtime still raises
  on. Note the mod, the script, and the line, and see
  [Troubleshooting](#troubleshooting).
- A handler that fails every frame is rate-limited in the library log (a
  traceback on the first error of a site, then shorter messages, then counts
  only).

## Known limits

- Animations, movement-control writes, and HUD/UI (beyond `ui.showMessage`) are
  not ported, as described above.
- MENU handlers, LOAD scripts and ITEM scripts are not hosted.
- `openmw.nearby` has no pathfinding; custom magic effects are not available;
  events to an object outside the active cells are dropped. See
  [docs/GAPS.md](docs/GAPS.md).
- **Shared runtime conflict:** every converted mod ships a copy of
  `MWSE/lib/omwcompat*`, so Vortex reports a file conflict between them. Let the
  mod with the **newest runtime** win. Newer runtimes still run older
  conversions.
- No save migration helper is shipped. If a conversion ever needs a new game, it
  says so. If you uninstall omwcompat mid-game, objects a conversion already
  disabled or removed stay that way in cells you have visited (the original
  OpenMW mods behave the same).
- The "Mod enabled" switch does not undo world changes, and interfaces a stopped
  mod already registered stay registered.

## Troubleshooting

- **The converter refused the folder (exit 3).** You pointed it at Data Files or
  the game install. Point it at the Vortex staging folder for that mod instead,
  and put `--result-json` somewhere else (a temp directory is fine).
- **The verdict is blocked.** Do not enable the mod. `omw2mwse scan` lists the
  blockers. A blocked tidy-interface run does not write a conversion.
- **Vortex says `MWSE/lib/omwcompat*` conflicts.** Keep the newest omwcompat.
  If Vortex later offers to restore an older copy, keep the current files.
- **A "built for" line appears.** Harmless if the loaded runtime is newer.
  After an omw2mwse 0.3.2 convert it is in `Data Files/MWSE/logs/omwcompat.log`.
  An older conversion still writes it to MWSE.log; re-convert the mod to move
  that line into the library log. If you want the line gone entirely, the
  loaded runtime must match the one the mod was built for.
- **Lights keep making sound after the mod turned them off.** You may be on a
  runtime older than 0.4.1, or the light is not one omwcompat generated or
  removed. The sound gate only covers omwcompat's own off copies and removed
  objects.
- **The mod is on but seems to do nothing.** Check **MW Conversions** for the
  "Mod enabled" switch, MWSE.log for a missing runtime or a failed library-log
  open, and `Data Files/MWSE/logs/omwcompat.log` for warnings and errors.
- **You want the original package back.** It is under `Off/<plugin>/OpenMW/` in
  the staged folder, untouched. Turning "Mod enabled" off only stops the
  conversion from running; it does not restore the OpenMW layout. A finished
  conversion is not undone by `recover --rollback` (that is for interrupted
  runs). When tidy drove the convert, use tidy's `--undo`.

## Tested mods

"Ready" means the converter and the test suite accept the mod. In-game testing
is still ongoing except where a note says otherwise.

| Mod | Source | Converter | Notes |
|---|---|---|---|
| Leave The Lights Off | [Nexus 57510](https://www.nexusmods.com/morrowind/mods/57510) | ready | Global script, settings MCM. In game, scheduled lights go on and off properly. |
| No Fires in Bad Weather | [Nexus 57579](https://www.nexusmods.com/morrowind/mods/57579) | ready | Global script plus a required plugin. The sound gate keeps off and removed lights quiet. |
| Wildlife Attacks NPCs Too | [Nexus 54448](https://www.nexusmods.com/morrowind/mods/54448) | ready | Creature script; the old-API plugin goes to `Off/`. |
| Mage Robes for OpenMW-Lua | [GitLab](https://gitlab.com/modding-openmw/mage-robes-for-openmw-lua) | ready | CUSTOM scripts. The Lua conversion still needs the original Mage Robes assets. |
| Shield Unequipper | [GitLab](https://gitlab.com/modding-openmw/shield-unequipper) | ready | PLAYER script. |
| Thieves Pickpocket | [Nexus 58362](https://www.nexusmods.com/morrowind/mods/58362) | blocked | The converter still blocks it: `openmw.animation` stays an unsupported module for verdicts, and UI layouts are not ported. It has been run in game on omwcompat 0.4.3: animations do not play, writes to `self.controls` are ignored, the settings MCM works, and the local script keeps running after an NPC deactivates. |

Other OpenMW Lua mods in the test corpus (HUD mods, full UI, cameras,
post-processing, magic effects, and similar) remain blocked. A blocked verdict
is the converter doing its job.

## Rights and support

- The original authors **retain all rights** to their mods, including whatever
  license or permission terms they published.
- **Distributing converted mods is forbidden.** Conversions are generated
  locally for your own personal use. Uploading, sharing or otherwise
  distributing a converted mod, in whole or in part, is not allowed.
- **Do not contact the original authors** about a converted mod. Problems may
  come from the conversion, not from the original. Report problems to
  **dej (dejunai)** on the Nexus Mods forums.

## Credits and license

By **dej (dejunai)**. The tool is MIT licensed; see [LICENSE](LICENSE).
Converted mods remain the property of their original authors and keep their own
licenses.

- Short path: [QUICK_START_GUIDE.md](QUICK_START_GUIDE.md)
- Tidy contract: [docs/TIDY_INTERFACE.md](docs/TIDY_INTERFACE.md)
- API differences: [docs/GAPS.md](docs/GAPS.md)
- Runtime internals: [docs/RUNTIME.md](docs/RUNTIME.md)
- Developer notes (tests, packaging, audit): [docs/DEVELOPER.md](docs/DEVELOPER.md)
