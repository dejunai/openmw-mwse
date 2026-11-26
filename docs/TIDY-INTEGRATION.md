# Calling omw2mwse from tidy

Conflict Tools' tidy pass (separate repo, not modified here) converts OpenMW Lua mods it
finds in staged plugin folders by calling omw2mwse. This note is the contract. Tidy and
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

## Invocation

```
omw2mwse --convert-omwscripts[=normal|hardcode] <staged-mod-dir> --json [options]
```

is the same as `omw2mwse convert <staged-mod-dir> --mode normal|hardcode --json`. A bare
`--convert-omwscripts` means `normal`. Library use: `omw2mwse.convert.convert(path, mode, ...)`
returns the same dict that `--json` prints. Python 3.11+ stdlib only (tomllib); tested on 3.13,
written for 3.15.

`<staged-mod-dir>` is a Data Files root (a Vortex staging mod folder). omw2mwse finds every
folder below it that holds a `.omwscripts` file, outside `MWSE/` (for example a legacy
`Off/OpenMW/LeaveTheLightsOff/` or a loose package at the folder root), and writes the
MWSE build into the same folder. `package` uses the same layout under `OUT/Data Files/`.

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
| `MWSE/lib/omwcompat.lua`, `MWSE/lib/omwcompat/` | runtime (skip with `--no-runtime`) |
| `meshes/`, `textures/`, `Sound/`, ... | original game assets, also kept under `Off/<Mod>/OpenMW/` |
| `<Name>.esp` / `<Name>.esm` | root plugins that are required or undetermined (enabled by default), including an `.omwaddon` installed under an `.esp` name |
| `Extras/<Mod>/...` | plugins that shipped in a package subfolder (not auto-enabled; tidy does not look inside `Extras/`) |
| `meshes/omwc/<slug>/<hash>.nif` | short aliases for mesh paths longer than 31 chars, copied from `meshes/` in the folder |
| `<Mod>-metadata.toml` | MWSE metadata with the notice in its description |

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

## JSON result (abridged)

```json
{
 "tool": "omw2mwse", "version": "0.2.3", "command": "convert", "mode": "normal",
 "dir": "...", "dryRun": false, "changed": true, "exitCode": 0, "alerts": [],
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
`duplicate-source`, `sidecar-ignored`, `hardcode-none`, `no-openmw-scripts`.
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
converted mods built by the same omw2mwse version, or ship the runtime as its own mod and
pass `--no-runtime`.
