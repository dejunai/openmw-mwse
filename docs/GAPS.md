# Known gaps and risks (omwcompat 0.4.0 + LTLO 3.2)

## What has been verified, and only on the box

- The original `LTLO_g.lua` ran unmodified in a LuaJIT 2.1 mock of MWSE: 44 checks passed.
  - Covered: day, night, ash storm and blight transitions, menu pause, save/load round trip,
    pickup with ownership, mesh aliases and the mesh fallback.
- Parity against Dej's hand port in the same mock: 7 of 7 phases equal.
- Hand-port save migration: 6 checks passed.
- Serializer and util unit tests: 20 passed. CLI unit tests: 14 passed.
- The mock is a test double written from the MWSE docs. It shows that the Lua logic holds
  together. It does **not** show how the engine behaves.

## Needs in-game confirmation (risk ordered)

1. **Engine calls the mock only imitates:**
   - `createCopy` during play, and whether generated records survive save/load.
   - `tes3.createReference` in exteriors without `cell`.
   - Whether `referenceActivated` fires for refs created by `createReference`.
   - The `activate` event block, and `actor:activate(original)` doing a vanilla pickup with crime.
     Dej's hand port already relies on that call, so it probably works.
   - `sceneNode.appCulled` hiding the light for the frame before pickup.
2. **Weather transition direction (DESIGN Q7).** omwcompat maps OpenMW's `getTransition` to
   `1 - transitionScalar`, which assumes MWSE's scalar runs from 0 to 1. Dej's port makes the same
   assumption with `> 0.5`. If it is backwards, lights switch near the start of a storm
   transition instead of the end. Checklist item 5 tests this.
3. **Script paths.** The loader uses `loadfile("Data Files/MWSE/mods/mwsuite/openmw/<Mod>/omw/...")` and `io.open`, relative
   to the game folder, which is the working directory MWSE normally has. A different working
   directory would make the script fail to load, and MWSE.log would show it.
4. **Replacer detection** reads loose files with `io.open` and checks their sizes. This works for
   loose DLR/RR meshes. Files inside a BSA are reported as missing, which matches the mod's intent.
5. **Scripted lights** are not skipped. That matches the original LTLO, but Dej's port skipped them.
   Copies keep the template's mwscript. A quest light carrying a script could run that script on
   its unlit copy.
6. **Tombstones and uninstalling.** If omwcompat is removed mid-game, originals put out in cells
   you visited stay disabled. The original mod on OpenMW behaves the same way, because removed
   objects stay gone. Uninstall from a save made at night, or with a cleanup like the migration
   helper. That cleanup is not written yet.
7. **Non-content refs**, such as a lantern you dropped, get session-only ids until a script
   saves them. LTLO may then keep a stale `originalRotations` entry. This is harmless.

## Behaviour differences from the hand port

- No MCM or config. Day is 7:00 to 18:00 and fixed, as in LTLO, and dark weather is always on.
  `leavethelightsoff.json` is ignored.
- Weather is read for the player's cell only, as in LTLO. The hand port read it globally.
- Lights are swapped one per frame (LTLO's design). The hand port did a whole cell at once
  every 1 s.
- All whitelisted meshes now get off models, including streetlights, paper lanterns and DLR/RR,
  through the aliases. The hand port skipped paths longer than 31 characters.

## Runtime limits (omwcompat 0.4.0)

- Hosted script kinds: GLOBAL; object-attached NPC, CREATURE, ACTOR, CONTAINER, DOOR, LIGHT,
  ACTIVATOR (0.3.0); CUSTOM and PLAYER (0.4.0). MENU scripts only run in the settings probe
  (0.4.1: their settings reach the MCM; menu handlers are not run). LOAD and ITEM scripts are
  skipped with a warning. `animation` and `I.AnimationController` are quiet no-ops (0.4.2: no
  animation plays, one log line per mod). `camera`, `postprocessing`, `menu`, `content` and `debug` are not
  provided; `ui` is `showMessage` only (no layouts, widgets, templates or HUD).
- Local scripts differ from OpenMW in a few documented ways:
  - An instance is dropped when its object leaves the active cells and recreated when it comes
    back: the chunk runs again, then `onLoad(data from onSave)`. Unsavable timers do not survive
    this, exactly as they do not survive a save/load in OpenMW.
  - `openmw.nearby` lists the references of `tes3.getActiveCells()`; `castRay` and
    `castRenderingRay` use `tes3.rayTest` (0.4.0); `findPath`, navmesh and the async ray
    queries are not provided.
  - `I.AI`: Combat uses `mobile:startCombat`; Wander/Travel/Follow/Escort use `tes3.setAI*`;
    `removePackages` only removes Combat. `getActivePackage` reports Combat while `inCombat`,
    otherwise the aiPlanner package.
  - AI stats (`fight`, `flee`, ...) have one live value per actor in MWSE; writing `base` or
    `modifier` changes that value, never the shared record.
- `storage` is minimal (every section is saved with the game); `I.Settings` records defaults;
  `API_REVISION` is a fixed 70; `Transform` composition is exact only for single-axis rotations.

### Per-mod Enabled switch (0.4.0)

Every converted mod's tab in the single **MW Conversions** MCM starts with a **Mod enabled**
switch (default on), also for mods that have no settings. It is not labelled just "Enabled"
because many mods have their own setting with that name.

- Saved per mod in `MWSE/config/omwcompat_<Mod>.json` (`"enabled": false`), for every save.
- **Off, mid-game: no reload needed.** At once, the mod's state is encoded as if saving
  (global `onSave`, per-object `onSave` of its active local/player/custom scripts, named timers,
  storage). Then all its scripts stop: global, per-object and player scripts are marked dead, and
  its timers, activation handlers and settings subscribers are dropped. From the next frame none
  of its handlers run (`onUpdate`, `onFrame`, keys, quest updates, events, activation, timers).
- While off, saves write the state it had when it was switched off, and loading a save does not
  start it: its saved state is kept unchanged and written back.
- **On, mid-game: no reload needed.** On the next frame its scripts start from that state, as
  after loading a save: `onLoad(data)` (or `onInit` for scripts that had no data). Its per-object
  scripts attach to active objects (`onActive`), and its global scripts get `onPlayerAdded` and
  `onObjectActive` / `onActorActive` / `onItemActive` for what is active.
- Limits: interfaces the mod registered stay registered (other mods may hold them, and calling
  one runs the stopped script's function). Changes it already made to the world (objects,
  equipment, globals) are not undone. Engine-side effects it started (a looping sound, an AI
  package) keep going until something stops them.

### New in 0.4.0: what each API maps to

| API | Status | MWSE mapping and differences |
| --- | --- | --- |
| `GameObject:addScript(path, initData)` | partial | CUSTOM scripts of converted mods only; not on Statics or items in an inventory. Saved; starts on the next frame when the object is active (`onInit(initData)`), else when it becomes active. Also callable from local scripts (OpenMW: global only). Adding an attached script again is ignored with a warning. |
| `GameObject:removeScript(path)` | partial | Only scripts added with `addScript`; drops their instance, timers and saved data without calling a handler; raises if not attached. |
| `GameObject:hasScript(path)` | partial | `addScript`'ed, running, or matched by the object's type flags (PLAYER scripts on the player). |
| `GameObject.owner` | partial | `tes3.getOwner/setOwner`: `recordId` (an NPC), `factionId` + `factionRank` (MWSE `requiredRank`). |
| `GameObject.startingCell` | partial | Interior: the current cell; exterior: the cell at the starting position. |
| `GameObject.enabled = v` | full | `ref:enable()/disable()`; items in an inventory are ignored with a warning (OpenMW cannot disable them either). |
| `GameObject.globalVariable` | unsupported | Raises. |
| `GameObject:sendEvent` | partial | Next frame to the object's hosted local scripts; built-in `ShowMessage` (to the player), `Unequip` and `PlaySound3d` run after the mod's handlers. Other built-in events (Hit, ModifyStat, AddVfx, StartAIPackage, UI modes) are not handled. |
| `types.Lockable` (`isLocked`, `getLockLevel`, `lock`, `unlock`) | full | `tes3.getLocked/getLockLevel/lock/unlock`. `getKeyRecord` is partial (the lock node's key). Doors and containers have `baseType == Lockable`. |
| `types.Weapon/Armor/Clothing.TYPE`, `record(id).type` | full | Weapon type from `object.type`; armor and clothing from `object.slot`. |
| `pairs(openmw.types)` | full | The types table itself; unknown names warn once. |
| `Inventory:getAll([type])`, `find`, `findAll` | partial | Items are inventory GameObjects (`inv:<owner>:<record>`, one per record, `count` live); they support `remove(n)`, `moveInto`, `teleport`, `split(n)` and survive save/load in script data. `resolve` raises. |
| `types.Actor.getEquipment/setEquipment/hasEquipped`, `EQUIPMENT_SLOT` | partial | Read from `object.equipment` and placed in OpenMW slots (bracers -> gauntlet slots, shield/light -> CarriedLeft, second ring -> RightRing); `setEquipment` needs an active actor (`mobile:equip/unequip`) and raises for items not in the inventory. The pre-0.49 alias `types.X.equipment` is kept. |
| `types.Actor.getStance/setStance`, `STANCE` | partial | `mobile.castReady` / `weaponReady`. |
| `types.Actor.stats.level` | partial | `current` = record level (read-only); `progress` = the player's `levelUpProgress`. |
| `types.NPC.stats.skills.<id>` | partial | `getSkillStatistic` / `tes3.setStatistic{skill=}`; `damage` is 0; `progress` for the player only. |
| `types.NPC/Player.isWerewolf`, `Player.isCharGenFinished`, `getCrimeLevel` | full | `mobile.werewolf`, `CharGenState == -1`, `mobilePlayer.bounty`. `setCrimeLevel` partial (sets bounty). |
| `types.Player.quests(p)[id]` | partial | `stage` get/set (journal index), `started`, `finished` (Finished flag of the current entry), `addJournalEntry` (`tes3.updateJournal`); cannot be iterated. |
| `types.Player.addTopic` | full | `tes3.addTopic`. |
| `core.factions.records[id or index]` | partial | From MWSE factions: id, name, ranks (name, attributeValues, primarySkillValue, favouredSkillValue, factionReputation = factionReaction = MWSE rank reputation), reactions, attributes, skills; `hidden` is always false. |
| `core.sound.*3d`, `isSoundPlaying`, `say`, `stopSay` | partial | `tes3.playSound/removeSound/getSoundPlaying/say` on the object's reference; `timeOffset` ignored; `stopSay` stops every sound on it; `isEnabled` is always true. |
| `world.mwscript.getGlobalVariables()` | partial | `tes3.findGlobal(name).value`; unknown names read nil, writing one raises; `pairs()` needs MWSE's Lua 5.2 compatibility. Other `world.mwscript` functions (except `getGlobalScript`) raise. |
| `nearby.castRay`, `castRenderingRay` | partial | `tes3.rayTest` against rendered geometry; `collisionType` and `radius` are ignored. |
| PLAYER scripts | partial | Hosted on the player: `openmw.self`, `nearby`, `ui`, `ambient`, `input`. `onFrame` every frame, also while paused. |
| `onKeyPress` / `onKeyRelease` | partial | MWSE `keyDown` / `keyUp`, outside menus only; `key.code` is the SDL scancode mapped from DirectInput, `symbol` the key name. |
| `onQuestUpdate(questId, stage)` | partial | MWSE `journal` event. |
| `ui.showMessage` | partial | `tes3.messageBox`; options are ignored. |
| `ambient.playSound/playSoundFile/stopSound/isSoundPlaying/say/streamMusic` | partial | `tes3.playSound` without a reference (volume, pitch, loop passed through), `tes3.say` without subtitles, `tes3.streamMusic`. |
| `input.isKeyPressed`, `KEY`, `isShift/Ctrl/AltPressed` | full | `inputController:isKeyDown`; actions, triggers, gamepad and mouse are unsupported. |
| `self.controls.sneak/run/jump` | partial | Read the actor's current state (`isSneaking`, `isRunning`, `isJumping`); other controls warn and read nil; writes warn once and are ignored (0.4.3; they used to raise). |

OpenMW 0.51 no longer has `async.newRealTimer`, `newUnsavableRealTimer`, `self.ownerRecordId`,
`types.Actor/Item.record(s)` or `types.<Actor>.equipment`. omwcompat still provides them for older
mods; the manifest lists them under `legacySymbols`, which the scanner accepts and `api-audit`
leaves out.

## Scanner limits

See [COVERAGE.md](COVERAGE.md#scanner-limits).

## Settings and hard-coded values (0.2)

- The generated MCM was checked only against a recording mock of `mwse.mcm`. In game, check
  that sliders with `decimalPlaces` and `createCustom` variables behave as the mock assumes.
- To build the MCM, the settings probe runs PLAYER and MENU scripts once with inert stand-ins. A script that needs real
  values at top level (string ops on engine data, version gates) stops early, and the
  groups it had not registered yet are missing from the MCM. The probe logs this as a warning.
- The "hosted" note is per mod: if the mod has any GLOBAL script, its MCM does not warn,
  even when a setting is read only by a PLAYER script.
- `reload`-type tunables rerun the mod's chunk while a game is loaded. For LTLO this was
  checked in the mock (no errors, state restored through onSave/onLoad). Other mods with
  side effects at top level could repeat them.
- LTLO candidates not exposed: `transition < 0.5` (weather blend threshold, internal) and
  the light whitelist/blacklist tables (record ids, so editing them breaks lookups). Clear,
  Cloudy and Snow stay non-dark (the author's choice). Unsafe to convert, and refused or
  never auto-picked by omw2mwse: state variables reassigned at runtime (`lightIndex`,
  `wasNight`, `shouldRun`, `weatherUpdater`, `darkWeather`), the unused `dlrInstalled`, and
  string constants used as ids.
- If Night ends >= Night starts, it is always night. The MCM does not cross-check the two.
