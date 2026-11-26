# Calling omw2mwse from tidy

Conflict Tools' tidy pass (separate repo, not modified here) converts OpenMW Lua mods it
finds in staged plugin folders by calling omw2mwse. This note is the contract.

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
`sounds/`, `music/`, `fonts/`, `splash/`, `video/`, `bookart/`, and loose
`.esp`/`.esm`/`.bsa`/`.omwaddon`/`.omwgame`) are also installed at the Data Files
root so Morrowind / MWSE can load them. Hosted (possibly rewritten) Lua stays in
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
| `MWSE/mods/mwsuite/openmw/<Mod>/omw2mwse-manifest.json` | files omw2mwse owns, with SHA-256 (used for idempotency) |
| `MWSE/lib/omwcompat.lua`, `MWSE/lib/omwcompat/` | runtime (skip with `--no-runtime`) |
| `meshes/`, `textures/`, ... | original game assets, also kept under `Off/<Mod>/OpenMW/` |
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
 "tool": "omw2mwse", "version": "0.2.1", "command": "convert", "mode": "normal",
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
   "alerts": [
     {"level": "info", "code": "hardcode-candidate", "file": "scripts/LeaveTheLightsOff/LTLO_g.lua",
      "line": 393, "kind": "literal", "context": "clockHour < 7", "type": "number", "value": "7",
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

## Credits and the support notice

Every build says it is an unofficial mwsuite conversion, credits the original mod, author,
license and page, and carries ONE fixed support line, the same whether conflict-tools or
MWManager packed it:

> Unofficial conversion by mwsuite. Do not contact the original author about it. Support: dej (dejunai) via the Nexus Mods forums.

(`SUPPORT_LINE` in `build.py`, `C.SUPPORT` in `conversions.lua`; a test keeps them equal.)
In game all converted mods share one Mod Config entry, **MW Conversions**: tab 1 is a fixed
general disclaimer, and every converted mod gets its own tab from tab 2 on, always, even with
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
