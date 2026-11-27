# omwcompat runtime

omwcompat is an MWSE Lua library at `Data Files/MWSE/lib/omwcompat.lua` plus `omwcompat/`.
It runs OpenMW GLOBAL, object-attached, CUSTOM and PLAYER scripts unmodified. Version 0.4.4.

## Layout

| File | Role |
|---|---|
| `omwcompat.lua` | Entry point: `require("omwcompat")` returns the runtime. |
| `omwcompat/runtime.lua` | Script host, the `openmw.*` module tables, events, timers, save/load, activation. |
| `omwcompat/objects.lua` | GameObject, Cell, Record and Inventory wrappers, `openmw.types`, lifecycle rules R1-R3. |
| `omwcompat/serial.lua` | Serializer for OpenMW "serializable data" into one Lua-literal string. |
| `omwcompat/util.lua` | `openmw.util`: vectors, transforms, colors, helpers. |
| `omwcompat/actors.lua` | Actor APIs: stats, `isDead`, factions (0.3.2), `openmw.nearby`, `I.AI`; equipment, stance, level, skills, controls, Player quests, `core.factions`, `castRay` (0.4.0). |
| `omwcompat/player.lua` | PLAYER-script modules `openmw.ui` (showMessage), `openmw.ambient`, `openmw.input`, `core.sound`, key events (0.4.0). |
| `omwcompat/guards.lua` | Rule-based guards `activeDedupe` / `safeIteration` (0.3.2). |
| `omwcompat/timing.lua` | Per-script handler timing counters (0.3.2). |
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
  `print` that writes to the library log (`Data Files/MWSE/logs/omwcompat.log`) with a prefix.
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
  6. Local scripts' `onUpdate(dt)`, then PLAYER scripts' `onFrame(dt)` with the real frame time (also while paused, 0.4.0).
- `referenceActivated` queues `onObjectActive`. Tombstoned, disabled and deleted references are skipped.
- Every handler runs inside `xpcall`. Errors go to the library log, at most 5 per site; only the
  first error of a site gets a `debug.traceback` (0.3.2), later ones are logged with the
  message only (2-5) or just counted, so a handler that fails every frame stays cheap. The
  counts are in the timing snapshot (`errors`).

## Local scripts (0.3.0)

Scripts declared with NPC, CREATURE, ACTOR, CONTAINER, DOOR, LIGHT or ACTIVATOR attach by rule,
never per mod:

- **Attach:** when an object of a matching type becomes active (`referenceActivated`, or the
  active cells after a load), each matching script gets its own instance. The chunk runs, then
  `onInit` the first time or `onLoad(saved)` after that, then `onActive`. The player never gets
  NPC/ACTOR scripts.
- **Run:** `onUpdate(dt)` each unpaused frame, timers, `eventHandlers` reached through
  `GameObject:sendEvent`, and `onActivated(actor)` when the object is activated.
- **Detach:** on `referenceDeactivated`, or when the object is disabled, deleted or removed:
  `onInactive`, then the `onSave` result and named timers are kept for that object and the
  instance is dropped. Unsavable timers are dropped.
- **Save:** active instances are saved as well. Data goes into the mod's save payload under the
  object's stable id. An object whose scripts keep nothing never gets an id in its `ref.data`.

Local scripts get `openmw.self` (a GameObject equal to the object, plus `object`, `isActive`,
`enableAI`) and `openmw.nearby` (actors, players, items, containers, doors, activators in the
active cells, cached per frame), and not `openmw.world`. Actor scripts also get `I.AI`
(see `omwcompat/actors.lua`). `types.Actor.stats.dynamic`, `.attributes`, `.ai` and
`types.Actor.isDead` map to the mobile (`mobile.health`, `mobile.fight`, `mobile.isDead`, ...),
falling back to the record when the actor is not loaded.

The scanner checks the same scopes: `openmw.self`/`openmw.nearby` in a GLOBAL script,
`openmw.world` in a local script, or `I.AI` outside an actor script is a blocker.

## CUSTOM and PLAYER scripts (0.4.0)

- **CUSTOM.** `obj:addScript(path, initData)` takes a CUSTOM script of any converted mod. The
  attachment is saved (`omwcompat_rt.attached`, by persistent object id). The script starts on
  the next frame if the object is active, with `onInit(initData)`, otherwise when it becomes
  active; after that it is an ordinary local script (`onSave`/`onLoad`, timers, events).
  `removeScript` drops it with its saved data, without calling a handler.
- **PLAYER.** PLAYER scripts are local scripts on `tes3.player` (object id `player`, stable
  across saves), attached on load. They also get `openmw.ui`, `openmw.ambient` and
  `openmw.input`, and the handlers `onFrame`, `onKeyPress` / `onKeyRelease` (MWSE `keyDown` /
  `keyUp`, outside menus) and `onQuestUpdate` (MWSE `journal`).
- **Built-in events.** `obj:sendEvent` reaches the object's local scripts; afterwards, unless a
  handler returned `false`, the runtime handles OpenMW's documented built-in `ShowMessage` (to
  the player), `Unequip` and `PlaySound3d` events.

## Per-mod Enabled switch (0.4.0)

`settings.addTab` puts a **Mod enabled** on/off switch first on every mod's MCM tab;
`RT.setEnabled(m, on)` stores it (`settings.setModEnabled`, `MWSE/config/omwcompat_<Mod>.json`).
Off: `freezeMod` encodes the mod's state like a save into `m.frozen`, marks its scripts dead and
drops its timers, activation handlers and subscribers. On: `resumeMod` runs on the next frame and
starts the mod from `m.frozen` like a load (`loadMod`), attaches its local scripts to active
objects (`attachLocal(ref, m)`) and calls its active-object handlers. While off, `onSave` writes
`m.frozen` back and `onLoaded` keeps the save's string without starting the mod. Behaviour and
limits: [GAPS.md](GAPS.md#per-mod-enabled-switch-040).

## Runtime version check (0.3.1)

Each generated `main.lua` declares the omwcompat it was built with (`local BUILT_FOR = "0.4.4"`,
also passed to `register` as `runtimeVersion`). Vortex deploys one copy of the shared
`MWSE/lib/omwcompat` files, so a mod may run on a different runtime. When `omwcompat.VERSION`
differs, `main.lua` writes exactly one line, e.g.
`[omwcompat 0.3.1] SomeMod was built for omwcompat 0.2.2 (loaded 0.3.1)`. Since omw2mwse 0.3.2
that line goes through `omwcompat.note` to the library log when the loaded runtime is 0.4.4 or
newer, and falls back to MWSE.log on older runtimes (`omwcompat.note or mwse.log`). The check
lives in `main.lua` so it still works if an older copy of the library won in Vortex. Nothing is
logged when they match. If the loaded runtime cannot host some of the mod's script flags, its
"not hosted" warning ends with `(built for omwcompat X, loaded Y)` (runtimes 0.3.1 and later)
and also goes to the library log (0.4.4).

## Guards (0.3.2)

omw2mwse detects two patterns statically (`tools/omw2mwse/patterns.py`, see
[TIDY-INTEGRATION.md](TIDY-INTEGRATION.md#rule-based-workarounds-pattern-entries-and-guards-024--omwcompat-032))
and writes `guards = { ... }` next to the script in `main.lua`. The runtime then gives that
script's environment (and the modules it `require`s) guarded standard functions; the mod's
Lua is never edited and scripts without guards get the plain functions.

- `activeDedupe`: `table.insert(list, obj)` with a GameObject that is already in `list`
  (`rawequal`) is skipped while the script's `onObjectActive` / `onActorActive` /
  `onItemActive` handler runs. GameObjects are cached per reference id (`objects.wrap`), so the
  same reference is the same table, before and after its cell is unloaded and loaded again.
  Inserts at other times are unchanged.
- `safeIteration`: the script's `next`, `pairs` and `ipairs` (plain tables only; tables with a
  metatable use the normal functions) and `table.remove`. Removing the element a traversal
  just returned makes the next step visit the element that shifted into its slot instead of
  skipping it (for-in loops and `k = next(t, k)` cursors kept between frames alike);
  `next(t, k)` with a key that is no longer in the table restarts from the first key instead
  of raising "invalid key to 'next'".

The first time a guard changes something for a script, one WARNING line names the script and
the rule; later cases are counted (`omwcompat.guards.stats`, and `guards` in timing snapshots).

## Timing counters (0.3.2)

`callAll` (global scripts' engine handlers) and `updateLocals` (local scripts' `onUpdate`), and
local `onActive` / `onInactive`, are timed per mod + script + handler: `calls`, `total` and
`max` seconds (local instances of one script share an entry). `frame` is all omwcompat work in
one `enterFrame` (event delivery, timers and deferred calls included). The clock is
`QueryPerformanceCounter` through LuaJIT ffi on Windows when available, else `os.clock`.

```lua
local omwc = include("omwcompat")            -- nil when no converted mod is installed
if omwc and omwc.timing then
    local snap = omwc.timing.snapshot()      -- cumulative since load / reset
    -- snap = { version, clock, enabled, since, elapsed, frame = { frames, total, max },
    --          scripts = { { mod, script, handler, isLocal, calls, total, max, errors }, ... },  -- slowest first
    --          guards = { { mod, script, dedupeSkipped, shiftRevisits, nextRestarts }, ... } }
    local d = omwc.timing.delta("mwhangwatch")   -- same shape, calls/total/frames since this consumer's last call
    local line = omwc.timing.line("mwhangwatch", 5)  -- one line: ms/frame + the 5 slowest handlers
end
```

`omwcompat.getTimings` is `timing.snapshot`; `timing.reset()` and `timing.setEnabled(on)` exist
too. Each `delta` / `line` consumer name has its own window, so several readers do not disturb
each other. An optional periodic line goes to the library log when
`Data Files/MWSE/config/omwcompat.json` holds `{ "timingLogSeconds": 10 }` (0 or no file: off);
`"timing": false` turns the counters off. omwcompat never writes that file.

mwhangwatch (mwsuite, not changed here) already logs one line per second from its `enterFrame`
hook and looks up other suite mods with `include()`; adding
`log("  %s", omwc.timing.line("mwhangwatch", 5))` next to its fps line would put omwcompat's
share of each second in `mwhangwatch.log`.

## Save data

- On MWSE `save`, each script's `onSave()` result is serialized into a single string:
  `tes3.player.data["omwcompat_<Mod>"]`. Saved timers and storage sections go in the same string.
- Runtime state is stored in `tes3.player.data.omwcompat_rt`. It holds the generated record models,
  the id counter, the tombstones and (0.4.0) the CUSTOM scripts attached with `addScript`.
- A mod switched off keeps its last string unchanged (0.4.0).
- Each value is a string primitive, so a nested table is never assigned into `.data`. The MWSE
  storing-data guide warns against that.
- The serializer accepts plain tables, numbers (including inf and nan), strings and booleans. It also
  accepts `util` vectors, transforms and colors, and GameObjects, which are stored by id
  (inventory items as `inv:<owner id>:<record id>`, rebuilt as inventory items on load; 0.4.0).
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
  - (0.4.1) Either way the sounds playing on the reference are stopped first
    (`tes3.removeSound{ reference = ref }`): Morrowind keeps a disabled light's loop playing.
    `GameObject.enabled = false` does the same.
  - (0.4.1) The removed object keeps its `recordId`, as in OpenMW (No Fires in Bad Weather reads
    it right after `remove()`). `isValid()` is false and `count` is 0.
  - A removed reference is never reported active again: `referenceActivated` and
    `objectBecameActive` skip disabled and tombstoned references.
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

## Sound gate (0.4.1)

OpenMW never plays the own loop of a light whose record is off by default (`mwclass/light.cpp`
`insertObject`), and removed objects make no sound. Morrowind plays a light's own sound whatever
the flag says. The off copies that Leave The Lights Off and No Fires in Bad Weather place
(`createRecordDraft{ template = torch, isOffByDefault = true }`) therefore kept crackling, and the
engine restarted those loops over and over because it reported them as not playing (mwsoundguard
logged them as runaway loops on 2026-11-26). `tes3light.sound` is read-only in MWSE, so the copy
cannot simply lose its sound. An `addSound` handler (priority 1000, before mwsoundguard) blocks:

- any sound on a reference omwcompat removed (an R1 tombstone);
- the record's own sound on a light whose record omwcompat generated (`Generated:0x..`) and that is
  off by default.

Other mods' lights and vanilla records are never touched. The first block of each kind is logged
once (`[omwcompat] sound gate: kept ... from playing`); later ones are counted in
`omwcompat.soundGate` (`removed`, `offCopy`).

## MENU scripts (0.4.1)

When the mod's spec has `probeSettings` (omw2mwse sets it when the mod declares settings), a MENU
script is run once at `modConfigReady` by the settings probe, so its `I.Settings` pages and groups
reach the MCM. That is all most MENU scripts do, so there is no "not hosted" warning any more. If
the script returns engine or event handlers, one warning names them: those are not run. Without
`probeSettings` a MENU script is still skipped with the warning.

Custom settings renderers draw OpenMW UI, which the MCM cannot run. Since 0.4.1 a setting whose
value is a flat table of numbers and/or booleans (ThievesPickpocket's `tpMultiNumber` and
`tpMultiSelect`) gets one MCM control per key: sliders using the renderer argument's per-key
`min`/`max`/`integer`, on/off buttons for booleans, labels from `aliases`. Changing one key writes
the whole table back. Other custom renderers keep the fallback control and its warning.

## Animations (0.4.2)

Animations are not ported. So that a mod which plays a gesture or waits for a text key keeps
running, `require('openmw.animation')` works in every hosted script and actor local scripts have
`I.AnimationController`; every call is a no-op:

- `hasAnimation`, `isPlaying`, `isLoopingAnimation`, `hasGroup`, `hasBone` return `false`;
  `getCurrentTime`, `getCompletion`, `getLoopCount`, `getSpeed`, `getActiveGroup`,
  `getTextKeyTime` return `nil` (OpenMW's answers for an animation that is not playing).
- `playBlended`, `playQueued`, `cancel`, `setSpeed`, `setLoopingEnabled`, `clearAnimationQueue`,
  `skipAnimationThisFrame`, `addGlow`, `addVfx`, `removeVfx`, `removeAllVfx` do nothing; a name
  not in this list is a no-op function too.
- `PRIORITY`, `BLEND_MASK` and `BONE_GROUP` have OpenMW's values.
- `I.AnimationController` (version 1): `playBlendedAnimation` does nothing; handlers given to
  `addTextKeyHandler`, `addPlayBlendedAnimationHandler` and `addAnimationEndedHandler` are
  accepted and never called. Mods that end a gesture on a text key need their own timer
  fallback (Thieves Pickpocket has one).

The first call of each mod logs one line
(`<mod>: <call> does nothing: animations are not ported by omwcompat ...`); later calls are
counted in `omwcompat.actors.animCalls[mod][name]`. The scanner still lists `openmw.animation`
as unsupported, so verdicts do not change: the mod runs, its animations do not play.

`types.NPC.getDisposition` / `getBaseDisposition` (0.4.2) read the NPC instance's effective /
base disposition (Morrowind has one per NPC, the player argument is ignored);
`setBaseDisposition` / `modifyBaseDisposition` write the base value, clamped to 0..100.

## Movement controls (0.4.3)

`self.controls.sneak`, `run` and `jump` still read the actor's current state. Other fields
(`yawChange`, `movement`, ...) still read nil. Writes no longer raise: the first write of
each field logs one line (`self.controls.<name> cannot be set: movement controls are not
emulated...`); later writes are ignored silently. Thieves Pickpocket's `onInactive` always
writes `yawChange = 0` in `stopTracking`, and must still run `finishApology` afterwards.

## Library log (0.4.4)

MWSE.log gets only initialization lines, so converted mods and the runtime do not spam it:

- `[omwcompat 0.4.4] loaded`
- `[omwcompat 0.4.4] library log: Data Files/MWSE/logs/omwcompat.log`
- `[omwcompat 0.4.4] registered <Mod> (N script(s)). <notice>` once per registered mod

Everything else (warnings, errors with tracebacks, stub / sound-gate / BUILT_FOR notes, the
optional timing line, debug `RT.log`, hosted scripts' `print()`, and a settings-tab failure)
goes to `Data Files/MWSE/logs/omwcompat.log`. Relative `io.open` paths resolve from the
Morrowind install root, which is MWSE's working directory. `Data Files/MWSE/` already holds
`lib/`, `mods/` and `config/`; `logs/` sits beside them and is not overwritten when Vortex
deploys the library folder (a log under `lib/omwcompat/` would be). `lfs` creates the folder
if it is missing. At session start the previous file is renamed to `omwcompat.log.prev` (one
copy is kept) and a new file is opened; each line is timestamped (`YYYY-MM-DD HH:MM:SS`) and
flushed so a crash does not drop it. If the file cannot be opened, one MWSE.log line says so
and further messages fall back to MWSE.log. Per-site `warnOnce` and the 5-error cap are
unchanged. Hosted scripts still have no `mwse` table: OpenMW mods use `print()`, and injecting
`mwse` would make a dual-engine script take the MWSE path.

A generated `main.lua` from before omw2mwse 0.3.2 still writes its BUILT_FOR mismatch line to
MWSE.log; re-convert the mod to move that line into the library log. A missing-runtime error
from `main.lua` always stays on MWSE.log, because the library never loaded.

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
