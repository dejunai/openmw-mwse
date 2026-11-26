# omwcompat runtime

omwcompat is an MWSE Lua library at `Data Files/MWSE/lib/omwcompat.lua` plus `omwcompat/`.
It runs OpenMW GLOBAL scripts unmodified. Version 0.1.0 (MVP).

## Layout

| File | Role |
|---|---|
| `omwcompat.lua` | Entry point: `require("omwcompat")` returns the runtime. |
| `omwcompat/runtime.lua` | Script host, the `openmw.*` module tables, events, timers, save/load, activation. |
| `omwcompat/objects.lua` | GameObject, Cell, Record and Inventory wrappers, `openmw.types`, lifecycle rules R1-R3. |
| `omwcompat/serial.lua` | Serializer for OpenMW "serializable data" into one Lua-literal string. |
| `omwcompat/util.lua` | `openmw.util`: vectors, transforms, colors, helpers. |
| `omwcompat/manifest.json` | Support status of each symbol. The `omw2mwse scan` command reads it. |

A packaged mod adds `MWSE/mods/mwsuite/openmw/<Mod>/main.lua`, which calls:

```lua
require("omwcompat").register({ mod = "<Mod>", root = "Data Files/MWSE/mods/mwsuite/openmw/<Mod>/omw/",
    scripts = { { flags = { "GLOBAL" }, path = "scripts/..." } }, meshmap = { ... } })
```

**Layout (0.2.1, unchanged in 0.2.2).** All converted mods live under `MWSE/mods/mwsuite/openmw/<Mod>/` (MWSE loads
`main.lua` at any depth), so they are easy to find next to the suite's own mods. The hosted
OpenMW Lua is in that folder's `omw/` subfolder, loaded with `loadfile`, not `require`, so no
`mwsuite.openmw.<Mod>` module path is involved. MWSE runs *every* `main.lua` it finds under
`MWSE/mods`, so a hosted script that is itself called `main.lua` is stored as `main.lua.omw`
(the runtime loads either name; `Off/` keeps the real name). The runtime stays at
`MWSE/lib/omwcompat*`: that is on MWSE's guaranteed library path, so `require("omwcompat")`
works with or without the suite's own `mwsuite/main.lua` (which edits `package.path`), there is
one copy shared by every converted mod, and it has no `main.lua` so MWSE never runs it as a mod.
The complete original package is `Off/<Mod>/OpenMW/<original paths>`.

## Script host

- Each script gets its own environment through `setfenv`. The environment holds safe globals and a
  `print` that writes to MWSE.log with a prefix.
- The `require` inside a script maps `openmw.*` and `openmw_aux.*` to the shims. Any other name
  loads a module relative to the mod root (`a.b` becomes `a/b.lua` or `a/b/init.lua`).
- Scripts are re-instantiated on every MWSE `loaded` event, as OpenMW does when a game loads:
  - If the save has a payload for the script, `onLoad(data)` runs. Otherwise `onInit()` runs.
  - After that come `onNewGame` (new games only) and `onPlayerAdded`.
  - Last, the runtime fires `onObjectActive` for every enabled reference in the active cells.
    MWSE does not refire `referenceActivated` for a cell that was already loaded.
- On `enterFrame`, the runtime does these steps in order:
  1. Run the deferred work from the previous frame.
  2. Deliver queued `sendGlobalEvent` events. Handlers run newest first, and `false` stops the chain.
  3. Flush the `onObjectActive` / `onActorActive` / `onItemActive` queue.
  4. Tick the timers.
  5. Call `onUpdate(dt)`. `dt` is 0 in menu mode, which matches OpenMW's paused world.
- `referenceActivated` queues `onObjectActive`. Tombstoned, disabled and deleted references are skipped.
- Every handler runs inside `xpcall`. Errors go to MWSE.log, at most 5 per site.

## Save data

- On MWSE `save`, each script's `onSave()` result is serialized into a single string:
  `tes3.player.data["omwcompat_<Mod>"]`. Saved timers and storage sections go in the same string.
- Runtime state is stored in `tes3.player.data.omwcompat_rt`. It holds the generated record models,
  the id counter and the tombstones.
- Each value is a string primitive, so a nested table is never assigned into `.data`. The MWSE
  storing-data guide warns against that.
- The serializer accepts plain tables, numbers (including inf and nan), strings and booleans. It also
  accepts `util` vectors, transforms and colors, and GameObjects, which are stored by id.
- Like OpenMW, it rejects functions, custom metatables, and shared or cyclic tables.
- Decoding runs `loadstring` in an environment that holds only the tag constructors.
- Timers are kept in omwcompat's own queue and not in MWSE timers, because MWSE cancels its timers
  right before `loaded`. Timers made with `registerTimerCallback` are saved and re-armed after
  `onLoad`. Unsavable timers are dropped on load, as in OpenMW.

## GameObject ids

| Kind | id |
|---|---|
| Reference from an ESM/ESP | `c:<plugin>:<sourceFormId>`. Stable across saves. `ref.data` is never touched. |
| Reference created by omwcompat | `r:<hex time>:<n>`, stored in `ref.data.omwcompat_id`. |
| Other runtime reference (dropped item, spawn) | `s:<n>`, valid for the session only. It is made persistent only if a script saves the object. |

Lights are items, and on item references `ref.data` *is* the itemData. omwcompat therefore never
creates itemData on content references. Doing so could stop picked-up lanterns from stacking.

## Lifecycle rules

These rules turn OpenMW's "objects are values" model into Morrowind references.

- **R1 `remove()`**
  - A content reference is disabled and tombstoned. The tombstone set is saved in `omwcompat_rt`.
  - A reference created by omwcompat is disabled and deleted.
- **R2 `world.createObject(id):teleport(cell, pos, {rotation})`**
  - If a tombstoned reference of the same record lies within 2 units in the target cell, it is
    re-enabled and returned. This avoids reference growth with day/night swaps.
  - Otherwise `tes3.createReference` is called. The cell is passed only for interiors.
  - Either way, `onObjectActive` fires for the object.
- **R3 `createObject(X):moveInto(types.NPC.inventory(actor))` inside an activation handler**
  - If a tombstoned X sits under the activated object, the vanilla activation is blocked.
  - Next frame, the original is re-enabled with `appCulled` set, its dynamic light is detached, and
    `actor:activate(original)` runs. Vanilla then handles pickup, ownership and crime.
  - If vanilla does not take the item, the original is shown again and reported active again.
  - In every other case `tes3.addItem` is used.
- **R4 record models longer than 31 characters**
  - `world.createRecord` sets `mesh` to the packager's alias `omwc/<slug>/<sha1-8>.nif` when that
    file exists.
  - Otherwise it keeps the template mesh and logs a warning (the documented fallback).
  - `record.model` of a generated record reports the *requested* model, so mods that compare models
    on load (LTLO does) do not regenerate records on every load.

Generated records get ids `Generated:0x<n>`, like OpenMW. They are created with `createCopy`
during play, so MWSE writes them to the save.

## Activation dispatch

1. Object handlers (`addHandlerForObject`), newest first.
2. Type handlers (`addHandlerForType`), newest first.
3. Global `onActivate(object, actor)` engine handlers.

A handler that returns `false` stops the chain and blocks the vanilla activation. The vanilla
activation is also blocked when the target becomes invalid inside a handler, for example
`remove()`. omwcompat's own `actor:activate(original)` call in R3 passes straight through to vanilla.

## Settings (0.2)

`omwcompat.settings` emulates `I.Settings` and `openmw.storage`:

- `registerPage` and `registerGroup` record pages and groups. The renderers `checkbox`,
  `number` (min/max/integer), `select` (items, l10n), `textLine` and `color` (hex text) get
  native MCM controls. `inputBinding` is shown as info only. Custom renderers fall back to a
  control chosen by the default value's type.
- Storage sections named after a settings group are kept in
  `MWSE/config/omwcompat_<Mod>.json` (`mwse.loadConfig`/`saveConfig`), not in the save. Other
  sections stay in the mod's save payload. `subscribe` callbacks run on the next frame after
  every `set`, including MCM edits. Old subscribers are dropped on load.
- At `modConfigReady`, mods with `probeSettings = true` run their declared scripts once in
  probe mode: openmw modules other than storage, interfaces, util, core.l10n and
  async:callback are inert stand-ins, and `API_REVISION` reads 100. That collects the groups
  even from PLAYER/MENU scripts that omwcompat cannot host yet. Their MCM then says changes
  have no effect in game.
- **One shared MCM, "MW Conversions"** (`omwcompat/conversions.lua`). MWSE's Mod Config list
  is flat, so all converted mods share one template, as the suite's `mwmanagermenu` does for
  "MW Conflict Tools". That mod hooks `mwse.registerModConfig` to capture templates the suite
  mods already built; converted mods all register through this one runtime, so the template is
  built directly at `modConfigReady`, one MWSE page (tab) per mod. Tab 1 is always the fixed
  `Disclaimer` page (`C.DISCLAIMER`), including a no-redistribution paragraph (personal use only;
  uploading or sharing a converted mod is forbidden); mod tabs start at tab 2, sorted by original mod name. A
  mod tab is always created, even with nothing to configure, and shows `Original mod:`,
  `Original author:` (or `unknown`), page/license when known, and the one support constant
  `C.SUPPORT` (in the sidebar and as the first item). Settings groups follow as categories. The
  same support line ends the MWSE.log registration line. Closing the menu saves every mod's
  settings and applies pending reloads.
- Hard-coded values that omw2mwse converted call `omwcompat.cfg(key, original)`, which reads
  the `omw2mwse_<Mod>` group (and falls back to the original value when the stored type is
  wrong). `apply = "live"` values are read on every evaluation. For `apply = "reload"` values,
  closing the MCM after a change reloads the mod's scripts in place: `onSave`, then the chunk
  runs again, then `onLoad(saved)`. Activation handlers, subscribers and named timers are
  rebound, and `onObjectActive` refires for active objects.
