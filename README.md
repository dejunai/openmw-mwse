# openmw-mwse

> **EXPERIMENTAL - EARLY DEVELOPMENT.** Expect bugs, missing features and breaking changes.
> Back up your saves and your mod setup before trying a converted mod.

openmw-mwse converts **OpenMW-only Lua mods** into **MWSE mods** for the original Morrowind
engine (Morrowind.exe + MWSE). It is a personal project by **dej (dejunai)**.

## What it does

It has two parts:

- **omw2mwse** - the converter. It scans an OpenMW mod, reports which `openmw.*` APIs it
  uses, and rewrites the mod's folder into an MWSE mod. It is normally run for you by
  conflict-tools' **tidy** on mods in your Vortex staging folder; it can also be run by hand
  (see [docs/DEVELOPER.md](docs/DEVELOPER.md)).
- **omwcompat** - an MWSE Lua runtime that provides the `openmw.*` API, so the mod's
  original Lua scripts run unmodified inside MWSE.

## Supported (omwcompat 0.3.0)

**Script kinds**

- `GLOBAL` scripts.
- Object-attached (local) scripts: `NPC`, `CREATURE`, `ACTOR`, `CONTAINER`, `DOOR`, `LIGHT`,
  `ACTIVATOR`. One instance runs per object while it is in an active cell; its saved data
  survives cell changes and save/load.

**Modules and APIs**

- `openmw.core` (time, events, GMSTs, content files, weather), `openmw.world` (global
  scripts), `openmw.types` (lights, actors, items, containers, doors, records, inventories),
  `openmw.util`, `openmw.async` (timers), `openmw.storage`, `openmw.vfs` (loose files),
  `openmw_aux.util`, `openmw_aux.time`, `openmw_aux.calendar`.
- `openmw.self` and `openmw.nearby` (local scripts).
- Actor stats: health/magicka/fatigue, attributes, AI fight/flee/alarm/hello, `isDead`.
- Interfaces: `I.Activation`, `I.Settings` (shown as an MCM), and `I.AI` in actor scripts
  (combat, wander, travel, follow, escort).
- `world.mwscript.getGlobalScript` (read/write vanilla global script variables).
- Engine handlers: `onInit`, `onLoad`, `onSave`, `onUpdate`, `onNewGame`, `onPlayerAdded`,
  `onObjectActive`, `onActorActive`, `onItemActive`, `onActivate`, and for local scripts
  `onActive`, `onInactive`, `onActivated`.

Many of these are partial. Exact differences are listed in [docs/GAPS.md](docs/GAPS.md).

## What a converted mod looks like

Inside the mod's folder (a `Data Files` root):

| Path | Contents |
|---|---|
| `MWSE/mods/mwsuite/openmw/<mod>/` | the generated loader and the mod's original Lua scripts |
| `MWSE/lib/omwcompat*` | the shared runtime |
| `Off/<mod>/OpenMW/` | the complete original package, untouched, for reference or reverting |
| original assets (`meshes/`, `textures/`, ...) | kept where the author put them |

**Plugins**

- `.omwaddon` / `.omwgame` files use the same format as `.esp` / `.esm`, so only the
  extension changes.
- A plugin at the package root stays at the root and is enabled by default.
- A plugin in a subfolder goes to `Extras/<mod>/` for you to inspect.
- A root plugin that is provably obsolete (only used by code for old OpenMW versions)
  goes to `Off/` only.

**Verdict.** Every conversion gets a verdict: **ready** (every API the mod uses is provided,
fully or partially) or **blocked** (it needs something omwcompat does not have yet). Don't
enable a blocked mod.

## The "MW Conversions" menu

All converted mods share one Mod Config Menu entry, **MW Conversions**:

- **Tab 1** is a general disclaimer.
- **Then one tab per converted mod**, showing the original mod's name and author, its
  settings (if any), and that support for the conversion goes to **dej (dejunai)** via the
  Nexus Mods forums.

## Rights and support

- The original authors **retain all rights** to their mods.
- **Distributing converted mods is forbidden.** Conversions are generated locally for your
  own personal use.
- **Do not contact the original authors** about a converted mod. Report problems to
  dej (dejunai) on the Nexus Mods forums.

## Known limits

- Not provided yet: `openmw.ui`, `openmw.animation`, `openmw.ambient`, `openmw.camera`,
  `openmw.input`, `openmw.postprocessing`, `openmw.debug`, `openmw.menu`, `openmw_aux.ui`.
- Not hosted yet: `PLAYER`, `MENU`, `CUSTOM` (`addScript`), `LOAD` and `ITEM` scripts.
- `openmw.nearby` has no `castRay` or pathfinding; `I.AI` only removes combat packages;
  events sent to an object outside the active cells are dropped. See
  [docs/GAPS.md](docs/GAPS.md).
- HUD mods (for example ammo counters and compasses) are out of scope.
- **Shared runtime conflict:** every converted mod ships a copy of `MWSE/lib/omwcompat*`, so
  Vortex reports a file conflict between them. Let the mod with the **newest runtime** win.
  Newer runtimes still run older conversions.
- No save migration: if a conversion ever needs a new game, it says so.

## Tested mods

| Mod | Nexus | Status | Notes |
|---|---|---|---|
| Leave The Lights Off | [57510](https://www.nexusmods.com/morrowind/mods/57510) | ready | global script, settings MCM |
| No Fires in Bad Weather | [57579](https://www.nexusmods.com/morrowind/mods/57579) | ready | global script + required plugin |
| Wildlife Attacks NPCs Too | [54448](https://www.nexusmods.com/morrowind/mods/54448) | ready | creature script; old-API plugin goes to `Off/` |
| No More Excessive Healing | [58337](https://www.nexusmods.com/morrowind/mods/58337) | blocked | player/menu scripts, `ui`, `ambient` |
| Player On Fire | [58345](https://www.nexusmods.com/morrowind/mods/58345) | blocked | player/menu scripts, `animation`, `ambient`, `postprocessing` |
| Thieves Pickpocket | [58362](https://www.nexusmods.com/morrowind/mods/58362) | blocked | player/menu/custom scripts, `ui`, `animation`, `ambient` |
| Vaults Restricted | [58405](https://www.nexusmods.com/morrowind/mods/58405) | blocked | player/menu/custom scripts, `ui`, `animation` |

"Ready" means the converter and the test suite accept it. In-game testing is ongoing.

## Roadmap

Planned, in no particular order and without dates:

- tidy running the converter automatically on Vortex installs, with omw2mwse and
  omwcompat shipped in the conflict-tools deploy.
- Player and menu script hosting, then the `ui`, `animation` and `ambient` modules.
- `omw2mwse revert`, to restore a mod from its `Off/` copy.
- Integration with the MWManager GUI.

## Credits and license

By **dej (dejunai)**. The tool is MIT licensed; see [LICENSE](LICENSE). Converted mods remain
the property of their original authors and keep their own licenses.

Developer notes: [docs/DEVELOPER.md](docs/DEVELOPER.md).
