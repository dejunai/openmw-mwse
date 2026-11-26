# OpenMW Lua → MWSE Lua: design proposal (research phase)

*Project: dej (dejunai). Status: exploratory, low priority. Nothing has been built and no repo exists yet. This is the design proposal only.*
*Written 2026-11-25. Doc links point to the live docs: OpenMW "latest" (API v166 when fetched) and mwse.github.io/MWSE.*

---

## 0. TL;DR

- **Recommendation: (c) hybrid, runtime first.** Build an MWSE-side **compatibility runtime** (`omwcompat`, an MWSE lib) that hosts OpenMW scripts more or less as they are. It emulates `openmw.*` through a sandboxed `require`, dispatches the handler tables the scripts return, runs the event bus, and handles save serialization and object identity. Next to it, a small **Python 3.15 CLI** (`omw2mwse`) scans an OpenMW mod, writes an API coverage report against the runtime's manifest, fixes asset paths, and packages a ready MWSE mod (`MWSE/mods/mwsuite/openmw/<Mod>/main.lua` bootstrap plus `-metadata.toml`; layout and the shared "MW Conversions" MCM were changed in 0.2.1, see docs/RUNTIME.md). Source-to-source rewriting is kept as a last resort and runs only on a per-rule basis.
- Why this split: OpenMW scripts differ from MWSE in **runtime semantics**, not syntax. Those semantics are handler tables, script contexts, the one-frame-delayed events, values returned from `onSave`, GameObject identity, and `remove()`/`createObject()` lifecycles. A transpiler would have to inline a runtime anyway. Syntax is nearly free: both engines run LuaJIT, and `goto`, which LTLO uses, works on both.
- **LTLO coverage estimate:** about 40 distinct API touchpoints in `LTLO_g.lua`. About 60% map directly, about 35% can be handled in the runtime, and about 5% have no MWSE equivalent (the optional Animated Lanterns interface, which simply resolves to `nil`). With 4 semantic rules in the runtime (§5.3), `LTLO_g.lua` should run with **no source edits**. Dej's hand port also adds things the original does not have (MCM, configurable hours, logging, skipping scripted lights, pickup that keeps ownership). Those cannot be derived automatically. See open question Q1.

---

## 1. Reference case: Leave The Lights Off (LTLO)

### 1.1 Files found (all read-only; nothing on the PC was changed)

| What | Path on Dej's PC | Copy on box |
|---|---|---|
| Original OpenMW global script v3.1 (605 lines, SHA-256 `7BAB5F54…F3D3`) | `…\Morrowind\Data Files\Off\OpenMW\LeaveTheLightsOff\scripts\LeaveTheLightsOff\LTLO_g.lua` (identical copy in `G:\Vortex Mods\morrowind\LeaveTheLightsOff 57510 3.1 …\Off\OpenMW\…`) | `reference/openmw_original/LTLO_g.lua` |
| omwscripts (1 line: `GLOBAL: scripts/LeaveTheLightsOff/LTLO_g.lua`) | `…\Off\OpenMW\LeaveTheLightsOff\LeaveTheLightsOff.omwscripts` | `reference/openmw_original/LeaveTheLightsOff.omwscripts` |
| Animated Lanterns compat yaml (MaxYari) | `…\Off\OpenMW\LeaveTheLightsOff\scripts\MaxYari\animated_lanterns\configs\lantern_off99_compat.yaml` | `reference/openmw_original/lantern_off99_compat.yaml` |
| `ui_debugWidget.lua` (Sun's Dusk debug widget; not in omwscripts and not `require`d by LTLO, so unused) | `…\Off\OpenMW\LeaveTheLightsOff\scripts\LeaveTheLightsOff\ui_debugWidget.lua` | not copied (not part of LTLO's runtime) |
| Dej's MWSE port (381 lines) | `…\Data Files\MWSE\mods\LeaveTheLightsOff\main.lua` | `reference/mwse_dej/main.lua` |
| Dej's live config | `…\Data Files\mwse\config\leavethelightsoff.json` | `reference/mwse_dej/leavethelightsoff.json` |
| Earlier revision of the port | `…\Morrowind\conflict-tools\backups\legacy\scripts\leavethelightsoff_main.lua.bak` | `reference/mwse_dej_earlier/leavethelightsoff_main.lua.bak` |
| Saved OpenMW overview doc + doc HTML/TXT snapshots | n/a | `reference/openmw_docs_overview.md`, `reference/docs/` |

Nexus id **57510** is inferred from the Vortex folder name (`LeaveTheLightsOff 57510 3.1 …`). The Nexus page blocks scripted fetches (403), so it was not checked online. The off meshes (`*_off99.nif`, plus the `dlr\` variants) are installed under `Data Files\meshes\`.

The earlier `.bak` differs from the current port in two places. First, the 31-character mesh-path guard was added. Second, the pickup handler now defers *all* work to `timer.delayOneFrame`: it enables the original, sets `appCulled`, detaches dynamic light, then calls `who:activate(orig)`, then deletes the off copy.

### 1.2 What the original does (OpenMW)
One GLOBAL script:
1. At load it builds `offModels` (mesh → `_off99` mesh). It detects mesh replacers (DLR, RR, Enlightened Flames, OAAB) by **file size via `vfs.open(path):seek("end")`**.
2. `onObjectActive(object)`: if the object is a Light whose recordId matches a whitelist substring, is not blacklisted, and sits in an exterior or quasi-exterior cell, it is queued in `activeLightsList`.
3. `onUpdate(dt)`: every 30th frame it re-reads the player cell's weather (`core.weather.getCurrent/getNext/getTransition`). Otherwise it processes **one queued light per frame**. Hour comes from `calendar.gameTime()/3600 % 24`, night is `<7 or >18 or darkWeather`. On a day/night flip it rescans.
4. To switch a light it does `oldLight:remove()`, then `world.createObject(newRecordId, count)`, then `:teleport(cell, pos, {rotation})`, then `:setScale`. The "off" record is created once per original with `types.Light.createRecordDraft{template=orig, isOffByDefault=true, model=offMesh}` and `world.createRecord`.
5. `I.Activation.addHandlerForType(types.Light, …)`: activating an off light creates an object of the **original** record, `moveInto(types.NPC.inventory(actor))`, and removes the off light.
6. `onSave` returns `saveData` (`generatedRecords`, `reverseRecordLookup`, `originalRotations`, `regenerateToDo`). `onLoad`/`onInit` restore it, prune records that vanished, and regenerate off records if a replacer changed. It can also rebuild the lookup by scanning `Generated:*` records.
7. Optional integration with *Animated Lanterns and Signs* (`I.AnimatedLanternsAndSigns`): it defers swaps while a lantern is swaying.

### 1.3 Mapping: original OpenMW construct → Dej's MWSE construct

| # | OpenMW (LTLO_g.lua) | Dej's MWSE port (main.lua) | Class |
|---|---|---|---|
| 1 | `.omwscripts` `GLOBAL:` line | `MWSE\mods\LeaveTheLightsOff\main.lua` (auto-loaded; [creating-a-mod](https://mwse.github.io/MWSE/guides/creating-a-mod/)) | direct |
| 2 | `return { engineHandlers = {...} }` | top-level `event.register(tes3.event.X, fn)` | direct (structural) |
| 3 | `onInit` / `onLoad(data)` | `event.register(tes3.event.loaded)` + `getState()` lazily creating `tes3.player.data.leavethelightsoff` | shim |
| 4 | `onSave() return saveData` | nothing; state lives in `tes3.player.data`, which MWSE saves automatically ([tes3reference.data](https://mwse.github.io/MWSE/types/tes3reference/), [storing-data](https://mwse.github.io/MWSE/guides/storing-data/)) | shim |
| 5 | `onUpdate(dt)` per-frame round-robin, 1 light/frame | `timer.start{type=timer.real, duration=1, iterations=-1}` from `initialized`, skips `tes3.menuMode()`, processes **all active cells** when dark/light flips | rewrite (strategy changed) |
| 6 | `onObjectActive(object)` queueing | dropped. Instead `cellChanged` + `loaded` → `timer.delayOneFrame(settleActive(true))` iterating `tes3.getActiveCells()` → `cell:iterateReferences(tes3.objectType.light)` | rewrite (MWSE has [`referenceActivated`](https://mwse.github.io/MWSE/events/referenceActivated/), so a shim *can* map it directly) |
| 7 | `types.Light.objectIsInstance(o)` | `ref.object.objectType == tes3.objectType.light` / iterator filter | direct |
| 8 | `object.recordId` (already lowercase) | `ref.object.id:lower()` | direct |
| 9 | `str:find(pattern)` (Lua pattern) | `id:find(p, 1, true)` (plain). Equivalent for these patterns | direct |
| 10 | `cell.isExterior or cell.isQuasiExterior` | `cell.isOrBehavesAsExterior` ([tes3cell](https://mwse.github.io/MWSE/types/tes3cell/)) | direct |
| 11 | `types.Light.record(id)` / `types.Light.records` | `tes3.getObject(id)` / (`tes3.iterateObjects` would be the analogue for `.records`) | direct |
| 12 | `createRecordDraft{template, isOffByDefault, model}` + `world.createRecord` | `orig:createCopy({})`, `copy.isOffByDefault = true`, `copy.mesh = m` ([tes3light](https://mwse.github.io/MWSE/types/tes3light/)). Copies made during play are saved; copies made outside a save are always sourceless (same page, `createCopy`) | shim |
| 13 | `record.model` = `"meshes/l/x.nif"` | `obj.mesh` = `"l\\x.nif"` (no `meshes\`, backslashes) | shim (path normalisation) |
| 14 | — | **31-character mesh limit**: `if m and #m <= 31 then copy.mesh = m end` (Dej's comment: "the game takes model paths of 31 characters at most") | no equivalent → asset fix (§5.3 R4) |
| 15 | `vfs.open(p):seek("end")` (VFS: loose files + archives) | `lfs.attributes("Data Files\\meshes\\"..p, "size")` (loose files only). For BSA awareness: [`tes3.getFileSource`](https://mwse.github.io/MWSE/apis/tes3/) returns `"file"`/`"bsa"` | shim |
| 16 | `oldLight:remove()` + `world.createObject` + `:teleport(cell,pos,{rotation})` + `:setScale` | **different model**: the original is `ref:disable()`d and *kept*. The off copy is placed with `tes3.createReference{object, position, orientation, cell, scale}`. At night the copy gets `disable()`+`delete()` and the original gets `enable()`. Tracked by `state.hidden["cell|id|x,y,z"]` | rewrite → shim rule R1/R2 |
| 17 | `saveData.originalRotations[light.id] = startingRotation` (util.Transform in save) | dropped (not needed because the original never moves) | rewrite (consequence of #16) |
| 18 | `light:isValid()`, `light.count == 0` | `ref.deleted`, `ref.disabled` | shim |
| 19 | `world.players[1]` | `tes3.player` | direct |
| 20 | `calendar.gameTime()/3600 % 24` | `tes3.worldController.hour.value` ([tes3worldController.hour](https://mwse.github.io/MWSE/types/tes3worldController/)) | direct |
| 21 | night = `h<7 or h>18` (hard-coded) | `h < config.dayStart or h >= config.dayEnd` (configurable) | direct + addition |
| 22 | `core.weather.getCurrent/getNext/getTransition(playerCell)`, `w.name` in {`Ashstorm`,`Blight`,`Blizzard`}, gated on `cell.hasSky` | `tes3.worldController.weatherController.currentWeather/nextWeather/transitionScalar`, `w.index` vs `tes3.weather.ash/blight/blizzard` ([tes3weatherController](https://mwse.github.io/MWSE/types/tes3weatherController/)). Global, not per-cell | shim (name↔index table). Transition direction is undocumented on both sides; see Q7 |
| 23 | `I.Activation.addHandlerForType(types.Light, fn(light, actor))` ([Activation](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/interface_activation.html)) | `event.register(tes3.event.activate, fn(e))` with `e.target`/`e.activator`, `return false` blocks ([activate](https://mwse.github.io/MWSE/events/activate/)) | shim |
| 24 | `world.createObject(onId, n):moveInto(types.NPC.inventory(actor))` + `light:remove()` | enables the original, culls its scene node, detaches its dynamic light, then `who:activate(orig)` **next frame** so vanilla pickup and **ownership/theft** apply. Then deletes the off copy | rewrite (behaviour change: ownership kept) |
| 25 | `print("LTLO: …")` | `log()` to `Data Files\MWSE\logs\leavethelightsoff.log` via `io`/`lfs` (OpenMW's sandbox has no `io`; [overview](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/overview.html)) | direct + addition |
| 26 | — (no settings) | `mwse.loadConfig` + MCM (`modConfigReady`, `mwse.mcm.createTemplate`, sidebar page, on/off buttons, sliders, `saveOnClose`) | addition |
| 27 | No skip for scripted lights | `if obj.script then return false end` (a copy would run the mwscript twice) | addition (correctness) |
| 28 | `I.AnimatedLanternsAndSigns.*` (OpenMW-only mod) | dropped | no equivalent (the interface is `nil`, so the code is inert) |
| 29 | `reconstructReverseLookup()` scanning `Generated:` records | dropped. `loaded` prunes copies whose object no longer exists | dropped |
| 30 | Regenerating off records when a replacer changes the model | dropped | gap (minor) |

**Takeaways for automation:** rows 1–4, 7–13, 15, 18–20, 22–23 are mechanical. Rows 5, 6, 16, 17, 24 are where Dej made *engine-driven* design changes. MWSE can't truly delete content-file references (it can only disable them), so "remove + recreate" turns into "disable original + place copy". The runtime can make that change automatically (§5.3). Rows 21, 25–27 are Dej's improvements and fall outside what conversion can produce.

---

## 2. API surface: OpenMW Lua vs MWSE

OpenMW's own docs note the terminology clash: OpenMW "game object" = MWSE **reference**, OpenMW "record" = MWSE **object** ([overview](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/overview.html)).

### 2.1 Script model

| OpenMW | MWSE | Notes |
|---|---|---|
| `.omwscripts` lines `FLAGS: path` (GLOBAL, MENU, PLAYER, CUSTOM, LOAD, NPC, CREATURE, LIGHT, …) ([overview §Format](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/overview.html)) | `Data Files\MWSE\mods\<Mod>\main.lua` auto-loaded; optional `<Mod>-metadata.toml` with `[tools.mwse] lua-mod`, `load-priority`, `wait-until-initialize` ([metadata](https://mwse.github.io/MWSE/guides/metadata/)) | The runtime reads omwscripts and instantiates scripts per flag |
| Script = file returning `{engineHandlers, eventHandlers, interfaceName, interface}` | Imperative `event.register(id, cb, {filter, priority, doOnce})` ([event](https://mwse.github.io/MWSE/apis/event/)) | Runtime dispatches the table |
| Per-script sandbox; only coroutine, math, string, table, limited `os`; `require` of API packages or VFS lua files; no DLLs ([overview §Language](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/overview.html)) | Not sandboxed, with full `io`, `lfs`, `os` ([timer.register note](https://mwse.github.io/MWSE/apis/timer/): "nothing in MWSE is sandboxed") | Runtime gives each script instance its own env (`setfenv`) and a custom `require` |
| Lua 5.1 + some 5.2/5.3 bits (goto, utf8…) on LuaJIT | LuaJIT 2.1.0-beta3 ([intro-to-lua](https://mwse.github.io/MWSE/guides/introduction-to-lua/)) | Language level matches. `utf8` lib may need a pure-Lua polyfill (unverified on MWSE) |
| Contexts: global (whole world, read-write), local (attached object, read-write on self, read-only nearby), player, menu, load | One context: everything, everywhere | Collapsing contexts is easy. Emulating the *restrictions* isn't needed |

### 2.2 Engine handlers → MWSE events ([engine_handlers](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/engine_handlers.html))

| OpenMW handler | MWSE source | Class |
|---|---|---|
| `onInit(initData)` | first `loaded` for a save without the script's data (and `newGame`) | shim |
| `onLoad(saved, initData)` / `onSave()` | `loaded` (`e.newGame`, [loaded](https://mwse.github.io/MWSE/events/loaded/)) / `save` ([save](https://mwse.github.io/MWSE/events/save/)) + `tes3.player.data` | shim |
| `onUpdate(dt)` ("every frame … even if paused", `dt` = simulation time) | `enterFrame` (every frame, has `menuMode`) with `dt=0` in menu mode. `simulate` fires only when not paused ([simulate](https://mwse.github.io/MWSE/events/simulate/), [enterFrame](https://mwse.github.io/MWSE/events/enterFrame/)) | shim |
| `onNewGame`, `onPlayerAdded` | `loaded` with `e.newGame` / every `loaded` | shim |
| `onObjectActive`, `onActorActive`, `onItemActive` | `referenceActivated` (+ `mobileActivated` for actors). **Caveat:** loading a save in the player's current cell doesn't fire it for unmodified refs ([referenceActivated](https://mwse.github.io/MWSE/events/referenceActivated/)), so the runtime must synthesize those on `loaded` by walking `tes3.getActiveCells()` | shim |
| `onActivate(obj, actor)` (global), `onActivated(actor)` (local) | `activate` (`e.target`, `e.activator`, block via `return false`) | shim. Ordering semantics differ (below) |
| `onActive`/`onInactive` (local) | `referenceActivated` / `referenceDeactivated` | shim |
| `onTeleported`, `onConsume`, `onDropped`, `onPlaced` | various MWSE events (e.g. `itemDropped`, `equip`); per-event work | shim (case by case) |
| `onKeyPress/Release`, `onMouse*`, `onControllerButton*`, `onFrame` (player/menu) | `keyDown`/`keyUp`/`mouseButtonDown`/`mouseWheel`/`enterFrame` ([keyDown](https://mwse.github.io/MWSE/events/keyDown/)) | shim (key-symbol table) |
| `onQuestUpdate`, `onConsoleCommand` | `journal` event / no clean equivalent for `lua` console prefix | shim / rewrite |
| `onInterfaceOverride` | runtime-internal interface registry | shim |
| Menu `onStateChanged`, load `onContentFilesLoaded` | `initialized` / none for "before main menu" record editing | partial / rewrite |

### 2.3 Packages

| OpenMW package | MWSE counterpart | Class |
|---|---|---|
| `openmw.world` ([doc](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_world.html)): `players`, `activeActors`, `cells`, `getCellByName`, `getExteriorCell`, `createObject`, `createRecord`, `getObjectsByRecordId`, time/pause controls | `tes3.player`, `tes3.getActiveCells`, `tes3.getCell`, `tes3.createReference`, `obj:createCopy`/`tes3.createObject` ([tes3 API](https://mwse.github.io/MWSE/apis/tes3/)) | shim. `createObject` yields an object *with no location* until `teleport`/`moveInto`, so the runtime needs a "limbo" handle |
| `openmw.types` ([doc](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_types.html)): per-type `record()`, `records`, `objectIsInstance`, `createRecordDraft`, `inventory()`, stats… | `tes3.getObject`, `tes3.iterateObjects(type)`, `objectType`, `tes3mobile*` stats, `ref.object.inventory` | mostly shim (large but regular: a field-name table per type) |
| `openmw.core` ([doc](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_core.html)): `sendGlobalEvent`, `getGameTime`, `getSimulationTime`, `getGMST`, `l10n`, `weather.*`, `magic`, `stats`, `GameObject` (`id`, `recordId`, `cell`, `position`, `rotation` (Transform), `scale`, `count`, `isValid`, `remove`, `teleport`, `moveInto`, `split`, `addScript`, `sendEvent`, `activateBy`…) | `tes3.getGMST`/`tes3.findGMST`, weather controller, `tes3reference` (`position`, `orientation` Euler vector, `scale`, `disable/enable/delete`, `data`) | shim. Transform↔Euler conversion in pure Lua. `l10n` → MWSE `mwse.loadTranslations` (MWSE has [mod-translations](https://mwse.github.io/MWSE/guides/mod-translations/)) |
| `openmw.self` / `openmw.nearby` ([self](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_self.html), [nearby](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_nearby.html)) | the attached reference / iterate active cells; `tes3.rayTest` for `castRay` | shim. Navmesh `findPath` has **no equivalent** |
| `openmw.async` ([doc](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_async.html)): `callback`, `registerTimerCallback`, `newSimulationTimer/GameTimer/RealTimeTimer` (reliable, saved) and `newUnsavable*` | `timer.start{type=timer.simulate/game/real}`, `timer.register(name, fn)` for persistent timers; all active timers cancelled right before `loaded` ([timer](https://mwse.github.io/MWSE/apis/timer/)) | shim. Recommend the runtime's **own** timer queue serialized into the save, mirroring OpenMW's "name + time + arg" record ([overview §Timers](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/overview.html)) |
| `openmw.storage` ([doc](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_storage.html)): `globalSection`, `playerSection`, `get/set/subscribe`, lifetimes Persistent/GameSession/Temporary | `mwse.loadConfig/saveConfig` (JSON in `MWSE\config`), `json` API, `tes3.player.data` | shim |
| `I.Settings.registerPage/registerGroup` (renderers checkbox/number/select/textLine/color…) ([Settings](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/interface_settings.html)) | MCM (`mwse.mcm` templates, pages, OnOffButton, Slider, Dropdown, TextField, ColorPicker) ([mod-config](https://mwse.github.io/MWSE/guides/mod-config/)) | shim (**auto-generate the MCM**) |
| `openmw.ui` + `I.MWUI` templates ([ui](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_ui.html), [MWUI](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/interface_mwui.html)): declarative layout tree, `ui.create`, `Flex/Text/Image/Container`, layers, `showMessage` | `tes3ui` imperative element tree ([tes3ui](https://mwse.github.io/MWSE/apis/tes3ui/)), `tes3.messageBox` | `showMessage` is direct. Layouts are partially shim-able (subset); complex HUD/drag UIs need a rewrite |
| `openmw.input` ([doc](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_input.html)): actions, triggers, key state | `keyDown` etc., `tes3.worldController.inputController` | partial shim |
| `openmw.util` ([doc](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_util.html)): vector2/3/4, transform, color, clamp, bit ops | `tes3vector3`, `niColor`; pure Lua for the rest | shim (pure Lua) |
| `openmw.vfs` ([doc](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/openmw_vfs.html)) | `io.open("Data Files\\…")`, `lfs`, `tes3.getFileExists`, `tes3.getFileSource` | shim (BSA *reads* not available; only existence/source) |
| `openmw_aux.*` (calendar, time, util, ui): Lua libs ([overview §Auxiliary](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/overview.html)) | n/a | ship ports of the aux Lua files on top of the shim (license check: they're from OpenMW's GPL tree) |
| `openmw.camera`, `postprocessing`, `animation`, `ambient`, `debug`, `menu`, `content`, `markup` | partial: `tes3.playAnimation`, sound APIs, MGE XE shaders; no menu-script/save-manager; `markup` (YAML) → pure-Lua YAML lib | mostly rewrite / no equivalent |

### 2.4 Cross-context messaging
OpenMW: `core.sendGlobalEvent`, `obj:sendEvent`, `types.Player.sendMenuEvent`. Delivery waits **one frame**, data must be serializable, handlers run in *reverse* load order, and `return false` stops the chain ([overview §Event system](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/overview.html)). MWSE: `event.trigger(id, payload, {filter})` is **synchronous**, with priority order ([event](https://mwse.github.io/MWSE/apis/event/)). → The runtime keeps its own queue: deep-copy the payload (which also enforces serializability), deliver on the next `enterFrame`, and route to the target object's script instances. Fully shim-able.

---

## 3. Hard parts (classified)

| # | Hard part | Why | Class |
|---|---|---|---|
| H1 | **Object identity and lifecycle** (`GameObject.id`, `isValid`, `remove()`, `count`, `createObject`→limbo→`teleport`/`moveInto`) | MWSE refs dangle after events ([object-lifetimes](https://mwse.github.io/MWSE/guides/object-lifetimes/)). There's no documented stable string id on a reference. Content-file refs can only be disabled, not deleted | **shim**, the core of the runtime: wrapper objects over `tes3.makeSafeObjectHandle` ([tes3 API](https://mwse.github.io/MWSE/apis/tes3/)), lazily assigned ids stored in `ref.data` (needs `ref.modified = true`, [storing-data](https://mwse.github.io/MWSE/guides/storing-data/)), tombstones for removed content refs |
| H2 | **Save serialization** of `onSave` return values (may contain GameObjects and util types, e.g. LTLO's `originalRotations` holds Transforms) | `tes3.player.data` takes only JSON-able primitives/tables, and the guide warns about assigning nested tables at once | **shim**: tagged encoding (`{__omw="obj", id=…}`, `{__omw="v3", …}`) written as one JSON string per script into `tes3.player.data` |
| H3 | **Local scripts** (auto-attach by type, `CUSTOM` + `addScript`, per-object env + per-object save data, `self`/`nearby`) | MWSE has no per-reference Lua script concept | **shim**: instances created on `referenceActivated` and parked on `referenceDeactivated`, state in `ref.data`. Perf risk when auto-attaching to every NPC/LIGHT. Scripts on items in inventories are inactive in OpenMW too ([overview](https://openmw.readthedocs.io/en/latest/reference/lua-scripting/overview.html)) |
| H4 | **Activation and handler-ordering semantics** (Activation interface vs `activate` event; `onActivated` runs *after* pickup with `count` already 0) | Different order, and what "default activation" means differs | **shim** with rules: if a handler removed or invalidated the target, block vanilla. Re-synthesize `onActivated` after the pickup (next frame) |
| H5 | **Async / serializable callbacks** (`registerTimerCallback` names + reliable timers; `async:callback` for UI/storage) | MWSE timers are cancelled on load; `timer.register` is global-namespace | **shim**: own timer wheel, saved alongside script data |
| H6 | **Settings & storage UI** | `I.Settings` groups → MCM pages; `storage` subscribe callbacks | **shim** (auto MCM generation is a nice win) |
| H7 | **UI layouts / input actions** | declarative vs imperative trees; layers, templates, relative sizing | **partial shim / rewrite** |
| H8 | **Engine-only features**: navmesh, postprocessing, animation blending, menu scripts, `content` load-time record edits, OpenMW-only record fields | not in the vanilla engine | **no equivalent / rewrite** |
| H9 | **Engine limits that leak into assets**, e.g. the 31-char mesh path (row 14) | MWSE can't set longer paths (per Dej's port) | **packager fix** (short-path asset aliases) |
| H10 | **Mod interop** with other OpenMW-only mods (`I.AnimatedLanternsAndSigns`) | the dependency doesn't exist on MWSE | **no equivalent** (degrades to nil, as LTLO already handles) |

**Top 5 for this project:** H1 object identity/lifecycle, H2 save serialization, H3 local scripts, H4 activation/handler semantics, H5 async timers. (H7 UI is the biggest for *other* mods but isn't needed for the MVP.)

---

## 4. Architecture options

### (a) Source-to-source transpiler (Python 3.15)
Parse Lua, rewrite `require('openmw.x')` calls and API idioms into MWSE calls, then emit `main.lua`.
- + Output is readable and has no runtime dependency. You could hand-tune it afterwards (as Dej did).
- − Semantics (handler tables, event queue, save, identity, lifecycle) still need runtime support, so you end up generating a runtime anyway. Dynamic code (`I.X`, tables of callbacks, `types[name]`) can't be resolved statically. Every OpenMW API change means updating the rewrite rules. Not "on the fly".

### (b) MWSE runtime shim (`require` redirection)
An MWSE lib that loads OpenMW scripts in per-script environments where `require('openmw.world')` etc. return emulation modules. It runs the omwscripts file directly.
- + Truly on the fly: drop an OpenMW mod in, and the runtime reads its `.omwscripts`. Scripts stay unmodified, so upstream updates just work. One implementation of each API serves every mod.
- − No pre-flight warning about unsupported APIs. Can't fix assets (31-char paths). Runtime overhead (wrapper objects). Debugging goes through a layer.

### (c) Hybrid (recommended)
**(b) as the engine, plus a thin Python 3.15 tool around it:**
1. `omwcompat` (MWSE lib, `Data Files\MWSE\lib\omwcompat\`): script host, `require` redirection, `openmw.*` emulation, event bus, timers, save codec, GameObject wrappers, MCM generator. It ships a machine-readable **manifest** (`api_manifest.json`) listing every emulated symbol and its status (full / partial / stub).
2. `omw2mwse` (Python 3.15 CLI, stdlib + a Lua parser such as `luaparser` or a small hand-rolled tokenizer):
   - `scan <openmw-mod>`: parse `.omwscripts` and Lua, collect API references, diff against the manifest, then print a **coverage report** (green/yellow/red per call site).
   - `package <openmw-mod> -o <out>`: copy scripts to `MWSE\mods\<Mod>\omw\…`, write a 5-line `main.lua` bootstrap (`require("omwcompat").load{ root = …, omwscripts = {…} }`) and `<Mod>-metadata.toml` depending on omwcompat, and write **asset fix-ups** (e.g. short-path aliases for meshes longer than 31 chars, plus a path map the runtime applies).
   - `--rewrite` (opt-in): small AST rules only for things the runtime truly can't cover, with every rule logged.
3. Optional **per-mod overlay** (`omwcompat/overlays/<Mod>.lua`) for behaviour that has to differ on the original engine. Off by default.

Also supports a "zero-tool" mode: the runtime can scan `Data Files\MWSE\omw\*\*.omwscripts` at `initialized`. That is real on-the-fly conversion, and the Python tool becomes purely diagnostic.

**Why (c):** the LTLO diff shows the gaps are lifecycle and semantics (rows 5, 6, 16, 17, 24), and only a runtime solves those generically. Asset limits and "will this mod work?" need an offline step, and that's where Python fits. Keeping rewriting opt-in keeps upstream scripts byte-identical.

---

## 5. MVP: auto-convert LTLO and match Dej's port behaviourally

### 5.1 Definition of "match"
At default settings (day 7–18; dark weather on), in every cell the converted mod and Dej's port touch:
1. By day, whitelisted exterior/quasi-exterior lights show the unlit mesh and emit no light. At night or in Ashstorm/Blight/Blizzard they're lit.
2. Picking up an unlit lantern puts the **lit original** in the inventory, and **ownership/theft** behaves like vanilla.
3. Save → load mid-day and mid-night gives the same visible state. No duplicate lanterns, no lingering disabled copies after N day/night cycles (reference count stable).
4. Lights with an mwscript are not touched.
5. The log shows the same per-cell "lit / put out" counts.

Points 2 and 4 aren't in the original LTLO. Hitting them needs either the runtime's general rules (R1–R3 cover point 2's mechanics) or an overlay. See Q1.

### 5.2 LTLO API inventory vs runtime (coverage)
About 40 touchpoints:
- **Direct (~60%)**: `world.players[1]`, `objectIsInstance`, `recordId`, `cell.isExterior/isQuasiExterior/hasSky`, `types.Light.record(s)`, `position`, `scale`, `count`, `setScale`, `print`, `goto`, `string.find`, `calendar.gameTime`, `core.getSimulationTime`, `onInit/onLoad/onSave/onUpdate/onObjectActive` wiring.
- **Runtime shim (~35%)**: `createRecordDraft`/`createRecord` (→ `createCopy` + field map, model path normalisation, the `Generated:` id prefix), `createObject`+`teleport`/`moveInto` (limbo handle → `tes3.createReference` / `tes3.addItem`), `remove()` (R1), `isValid`, `rotation`/`startingRotation` (Transform), `types.NPC.inventory`, `I.Activation.addHandlerForType`, `core.weather.*` (name↔index), `vfs.open():seek("end")`, save codec for Transforms.
- **No equivalent (~5%)**: `I.AnimatedLanternsAndSigns`. It's already guarded by `if I.AnimatedLanternsAndSigns`, so `nil` makes it inert.
- **Expected source edits to `LTLO_g.lua`: 0.**

### 5.3 Runtime rules the MVP needs (general, not LTLO-specific)
- **R1 Tombstone removal:** `obj:remove()` on a content-file ref → `disable()` + tombstone in `ref.data` (`modified=true`). The wrapper then reports `isValid()==false` and `count==0`, and runtime queries hide it. On a runtime-created ref → `disable()` + `delete()`.
- **R2 Resurrection:** `world.createObject(recordId)` followed by `teleport(cell, pos)` onto a tombstoned ref of the **same record** within ε in the same cell → re-enable that original instead of creating a new ref. This reproduces Dej's "disable original / re-enable at night" model generically and keeps original ownership. It also makes `originalRotations` harmless.
- **R3 Pickup fidelity:** in an Activation handler, `createObject(id):moveInto(inventory(actor))` + `remove()` of the target → if R2 can resolve the original under the target, do Dej's sequence instead: next frame, enable the original, cull it, then `actor:activate(original)`, then delete the off copy. Otherwise `tes3.addItem`. Ownership then comes for free. (This is the riskiest heuristic; the overlay is the fallback.)
- **R4 Mesh path limit:** a model longer than 31 chars gets mapped through the packager's alias table (short copies such as `ltlo\a01.nif`). Without the packager it behaves like Dej's port: the mesh isn't changed and a warning is logged.
- Plus: `onObjectActive` synthesis on `loaded` (referenceActivated caveat), `onUpdate` via `enterFrame` with `dt=0` in menu mode (LTLO returns early on `dt==0`, which matches Dej's `menuMode()` skip).

### 5.4 Phases
- **P0 Spike (1–2 evenings).** Offline: `omw2mwse scan` on LTLO gives the touchpoint list (the table above, machine-generated). In-game: a stub runtime where every `openmw.*` access logs and returns a recording proxy, then load `LTLO_g.lua` and capture its API trace in `MWSE.log`.
- **P1 MVP runtime (GLOBAL scripts only).** Script host + `require` redirection; handlers onInit/onLoad/onSave/onUpdate/onObjectActive; save codec; `world` / `types.Light` / `core.weather` / `calendar` / `vfs` / `Activation`; GameObject wrapper; R1–R4.
- **P2 Parity test.** Same savegames run under Dej's port and the converted LTLO, never both at once. Scenarios: Balmora and Seyda Neen at 6:55 → 7:05 and 17:55 → 18:05 (`set GameHour`), `ChangeWeather` to Ashstorm/Blizzard, pickup owned and unowned lanterns, save/load mid-transition, 20 fast-forwarded cycles with a reference-count check, a quasi-exterior cell. Compare the per-cell logs and screenshots. Possibly use MWSE's testing guide ([testing](https://mwse.github.io/MWSE/guides/testing/)) for unit tests of the codec and util.
- **P3 Breadth.** Local/PLAYER scripts (H3), event bus, async reliable timers, storage + `I.Settings`→MCM, `openmw.util`, `aux` ports.
- **P4 Corpus.** Run `scan` across 10–20 popular OpenMW-only mods, rank the missing APIs, and implement by frequency. A `ui`/`input` subset goes here.

---

## 6. Observations about Dej's port worth checking (not changes, just notes)
1. **31-char guard skips many meshes.** Measured from the port's tables: `light_de_streetlight_01_off99.nif` (33), `light_paper_lantern_01/02_off99.nif` (32), `light_paper_lantern_off_off99.nif` (33), and **every** `dlr\…`/`rr\…` replacer mesh except the two `dlr\delantpaper{grn,red}_00` (31) are over 31 chars. Those copies keep the *lit* mesh by day: the light is off, but the flame/glow mesh still shows. The replacer table is therefore mostly inert in MWSE.
2. **Polling timer vs load.** The MWSE timer docs say "All active timers will be canceled right before the loaded event triggers" ([timer](https://mwse.github.io/MWSE/apis/timer/)). The 1 s `timer.real` loop is started in `initialized`. If real timers are also cancelled, dawn/dusk switching while standing in one cell after loading a save would only happen on the next `cellChanged`. Worth a quick in-game check.
3. **Nested table assignment into `.data`.** The storing-data guide shows `tes3.player.data.myMod = { var1 = {}, … }` as the "wrong way" ([storing-data](https://mwse.github.io/MWSE/guides/storing-data/)). `getState()` does exactly that. If it works in practice, ignore this.
4. Weather is read from the global weather controller, not per cell (the original gates on `cell.hasSky`). That's fine for exteriors, but interiors that behave as exteriors will follow the region's weather.

---

## 7. Open questions for Dej
- **Q1 Parity target:** match the *original* LTLO behaviour, or *your* enhanced behaviour (ownership-preserving pickup, skip scripted lights, MCM with hours, logging)? The runtime rules give you most of the first and pickup mechanics. MCM/config/skip-scripted need an overlay.
- **Q2 Mesh limit:** is the lit-mesh-by-day fallback for streetlights, paper lanterns and DLR/RR intended? Would you accept the packager shipping short-path copies of the `_off99` meshes?
- **Q3 On the fly vs offline:** should the runtime pick up OpenMW mods straight from a folder (e.g. Vortex's `Off\OpenMW\…` layout or `MWSE\omw\`) at game start, or do you prefer an explicit `package` step that produces a normal MWSE mod?
- **Q4 Tooling:** Python 3.15 with one dependency (a Lua parser) OK, or stdlib-only (hand-rolled tokenizer)? (The box currently has 3.13.)
- **Q5 Your MWSE build date/version**, so the runtime targets the right API (e.g. `isOrBehavesAsExterior`, `createCopy` params).
- **Q6 Animated Lanterns and Signs:** do you use an MWSE counterpart that the runtime should bridge `I.AnimatedLanternsAndSigns` to?
- **Q7 Weather transition direction:** the original uses `next` when `getTransition < 0.5`, your port when `transitionScalar > 0.5`. Neither doc defines the direction (both just say "transition value"). Did you verify the timing in-game?
- **Q8 Distribution:** personal use only? Auto-converted outputs of other authors' mods, plus ported GPL `openmw_aux` files, have licensing implications if shared.

---

## 8. Key sources
- OpenMW Lua overview (sandbox, omwscripts, events, timers, serializable data): https://openmw.readthedocs.io/en/latest/reference/lua-scripting/overview.html
- Engine handlers: https://openmw.readthedocs.io/en/latest/reference/lua-scripting/engine_handlers.html
- openmw.world / core / types / async / storage / vfs / aux calendar: https://openmw.readthedocs.io/en/latest/reference/lua-scripting/ (`openmw_world.html`, `openmw_core.html`, `openmw_types.html`, `openmw_async.html`, `openmw_storage.html`, `openmw_vfs.html`, `openmw_aux_calendar.html`)
- Activation / Settings interfaces: `interface_activation.html`, `interface_settings.html` (same base)
- MWSE: creating a mod https://mwse.github.io/MWSE/guides/creating-a-mod/ · metadata https://mwse.github.io/MWSE/guides/metadata/ · event API https://mwse.github.io/MWSE/apis/event/ · timer https://mwse.github.io/MWSE/apis/timer/ · tes3 API https://mwse.github.io/MWSE/apis/tes3/ · tes3reference https://mwse.github.io/MWSE/types/tes3reference/ · tes3light https://mwse.github.io/MWSE/types/tes3light/ · tes3cell https://mwse.github.io/MWSE/types/tes3cell/ · weather controller https://mwse.github.io/MWSE/types/tes3weatherController/ · storing data https://mwse.github.io/MWSE/guides/storing-data/ · object lifetimes https://mwse.github.io/MWSE/guides/object-lifetimes/ · MCM https://mwse.github.io/MWSE/guides/mod-config/ · events: activate, simulate, enterFrame, loaded, save, initialized, cellChanged, referenceActivated (under https://mwse.github.io/MWSE/events/)

*Credit: project and LTLO MWSE port by dej (dejunai). Original Leave The Lights Off by its OpenMW author(s) (Nexus 57510, inferred).*
