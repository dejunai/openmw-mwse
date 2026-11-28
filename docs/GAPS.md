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
   directory would make the script fail to load, and the library log (or MWSE.log if the log file could not be opened) would show it.
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
  skipped with a warning. `animation` and `I.AnimationController` map simple calls on vanilla
  groups to `tes3.playAnimation` / `animationData` (0.5.0; see RUNTIME.md); custom groups, custom
  keys, speed, VFX and text keys other than start/stop are quiet no-ops (one log line per mod). `camera`, `postprocessing`, `menu`, `content` and `debug` are not
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
| `self.controls.sneak/run/jump` | partial | Read the actor's current state (`isSneaking`, `isRunning`, `isJumping`). 0.5.0 writes on NPCs: `run`/`sneak` -> `forceRun`/`forceSneak`, `jump = true` -> `doJump()`; on creatures only `jump`. Writes on the player are ignored with a warning. |
| `self.controls.yawChange` | partial | 0.5.0: a write turns an NPC or creature (`reference.facing += value`, applied at write time; the AI may turn it back); reads 0; ignored on the player. |
| `self.controls.movement/sideMovement`, `pitchChange`/`use` | partial / stub | Reads: movement flags (-1/0/1), pitchChange 0. Writes warn once and are ignored (the actor is not steered). |

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

<!-- known-mods-survey-2026-11:begin -->
## Known mods (survey 2026-11)

Dry-run of omw2mwse 0.3.2 / omwcompat 0.4.4 on 27 Nov 2026. Full write-up: [SURVEY-2026-11.md](SURVEY-2026-11.md). 19 ready, 160 blocked (179 counted). This table is generated from [survey/mods.csv](survey/mods.csv) by `python3 scripts/survey_report.py --gaps-table`. Do not edit it by hand.

Gap families use the short names from the ranked list in the survey (then any other family, alphabetically):

| # | Short name | Ranked gap family |
|---|---|---|
| 1 | UI layouts | ui layouts (openmw.ui widgets, I.MWUI templates, openmw_aux.ui) |
| 2 | I.UI | I.UI (modes, HUD visibility) |
| 3 | magic | magic (core.magic records/enums, Actor spells/activeSpells/activeEffects/selected spell) |
| 4 | MENU | script kind MENU (not hosted) |
| 5 | input | input (triggers, controller buttons, action handlers) |
| 6 | camera | camera (openmw.camera, I.Camera) |
| 7 | skills / stats | skills / stats records (core.stats Skill+Attribute records, NPC races/classes, I.SkillProgression) |
| 8 | animation | animation (openmw.animation, I.AnimationController) |
| 9 | self.controls | self.controls (movement writes) |
| 10 | content / markup / debug | content / markup / debug modules |
| 11 | I.Combat | I.Combat (onHit handlers) |
| 12 | Item.itemData | api openmw.types.Item.itemData |
| 13 | onControllerButtonPress | engine handler onControllerButtonPress |
| 14 | onInputAction | engine handler onInputAction |
| 15 | self.cell.hasTag | api openmw.self.cell.hasTag |
| 16 | onMouseWheel | engine handler onMouseWheel |
| 17 | Actor.isSwimming | api openmw.types.Actor.isSwimming |
| 18 | ItemUsage.addHandlerForType | api openmw.interfaces.ItemUsage.addHandlerForType |
| 19 | GameObject:getBoundingBox | other: unsupported GameObject:getBoundingBox |
| 20 | onTeleported | engine handler onTeleported |

Notes: "one family away" means filling that one gap would turn the mod ready. "needed --source (several source folders)" is the exit-2 case: the repo holds more than one copy, and the converter was rerun with `--source`.

| Mod | Source | Verdict | Blocking gap families | Note |
|---|---|---|---|---|
| [BlockStealing](https://github.com/kundrun/Block-Stealing-OpenMW) | GitHub | ready |  |  |
| [dynamic-telvanni-armor-replacer](https://gitlab.com/modding-openmw/dynamic-telvanni-armor-replacer) | GitLab | ready |  |  |
| [dynamic_morag_tong_armor](https://github.com/wgrodzicki/dynamic-morag-tong-armor) | GitHub | ready |  |  |
| [EssentialsKnockout](https://github.com/kundrun/Essentials-Knockout-OpenMW) | GitHub | ready |  |  |
| [fast_equip](https://gitlab.com/ptmikheev/openmw-lua-examples) | GitLab | ready |  |  |
| [harvest-lights](https://gitlab.com/modding-openmw/harvest-lights) | GitLab | ready |  |  |
| [harvest-lights-td-addon](https://gitlab.com/modding-openmw/harvest-lights) | GitLab | ready |  |  |
| [LeaveTheLightsOff](https://www.nexusmods.com/morrowind/mods/57510) | Nexus | ready |  |  |
| [m5_auto](https://github.com/indicozy/razdor-openmw) | GitHub | ready |  |  |
| [mage-robes-for-openmw-lua](https://gitlab.com/modding-openmw/mage-robes-for-openmw-lua) | GitLab | ready |  |  |
| [momw-camera](https://gitlab.com/modding-openmw/momw-camera) | GitLab | ready |  |  |
| [MOMWModTemplate](https://gitlab.com/modding-openmw/momw-mod-template) | GitLab | ready |  |  |
| [morrowind_ai](https://github.com/ButCheR-PRO/morrowind_ai_openmw) | GitHub | ready |  |  |
| [NoFiresinBadWeather](https://www.nexusmods.com/morrowind/mods/57579) | Nexus | ready |  |  |
| [setbonus_rebalance](https://github.com/staticnation/set_bonus) | GitHub | ready |  |  |
| [shield-unequipper](https://gitlab.com/modding-openmw/shield-unequipper) | GitLab | ready |  |  |
| [TheGardenOfDreams [07 Tel Raloran Patch (OpenMW)\]](https://github.com/MelchiorDahrk/Expedition32) | GitHub | ready |  | needed --source (several source folders) |
| [TheGardenOfDreams [08 Completionist (OpenMW)\]](https://github.com/MelchiorDahrk/Expedition32) | GitHub | ready |  | needed --source (several source folders) |
| [wildlife_attacks_npc](https://www.nexusmods.com/morrowind/mods/54448) | Nexus | ready |  |  |
| [audiobook_mod](https://github.com/silly-ursus/morrowind-audiobook) | GitHub | blocked | UI layouts | one family away |
| [distant-fixes-lua-edition](https://gitlab.com/modding-openmw/distant-fixes-lua-edition) | GitLab | blocked | content / markup / debug | one family away |
| [DwemerLightningRods](https://gitlab.com/modding-openmw/dwemer-lightning-rods-for-openmw-lua) | GitLab | blocked | Cell:hasTag | one family away |
| [dynamic-main-menu-replacer](https://gitlab.com/modding-openmw/gonzos-dynamic-main-menu-replacer) | GitLab | blocked | MENU | one family away |
| [ErnSunderRandomizer](https://github.com/ernmw/ErnSunderRandomizer) | GitHub | blocked | types.Book.createRecordDraft | one family away |
| [mmc](https://github.com/cpassuel/Morrowind-Mods) | GitHub | blocked | onInputAction | one family away |
| [omwanalytics-survey](https://github.com/brody327/OpenMWAnalytics) | GitHub | blocked | onConsume | one family away |
| [OpenMWLinuxRichPresence](https://github.com/careb0t/OpenMWLinuxDiscordRichPresence) | GitHub | blocked | skills / stats | one family away |
| [Pay_taxes_timer](https://github.com/rampageeee/openmw-mods-and-ports-hub) | GitHub | blocked | I.UI | one family away |
| [PetMudcrab](https://github.com/TinkerSnail/pinchito) | GitHub | blocked | animation | one family away |
| [pharis-magicka-regeneration](https://gitlab.com/modding-openmw/pharis-magicka-regeneration) | GitLab | blocked | magic | one family away |
| [placeStacks](https://github.com/ArshvirGoraya/PlaceStacks-Morrowind-Mod) | GitHub | blocked | I.UI | one family away |
| [racesrespected](https://gitlab.com/modding-openmw/momw-patches) | GitLab | blocked | input | one family away |
| [smart-ammo](https://gitlab.com/modding-openmw/smart-ammo) | GitLab | blocked | ItemUsage.addHandlerForType | one family away |
| [ThePopularPlague](https://gitlab.com/modding-openmw/momw-patches) | GitLab | blocked | magic | one family away |
| [usual-holiday](https://gitlab.com/modding-openmw/usual-holiday) | GitLab | blocked | magic | one family away |
| [bufftimers](https://github.com/voshond/openmw-buff-timers) | GitHub | blocked | UI layouts, magic | two families away |
| [dynamic-modern-tutorials](https://gitlab.com/modding-openmw/dynamic-modern-tutorials) | GitLab | blocked | UI layouts, I.UI | two families away |
| [DynamicMusic](https://github.com/eMOElein/DynamicMusic) | GitHub | blocked | ambient.isMusicPlaying, types.Actor.isInActorsProcessingRange | two families away |
| [HDForge](https://gitlab.com/modding-openmw/hd-forge-for-openmw-lua) | GitLab | blocked | content / markup / debug, LOAD | two families away |
| [hostile-permadeath](https://gitlab.com/modding-openmw/hostile-permadeath) | GitLab | blocked | MENU, openmw.menu | two families away |
| [ModernMehrunesRazor](https://github.com/OpenMW-Mod-Collection/ModernMehrunesRazor) | GitHub | blocked | MENU, I.Combat | two families away |
| [MyManor](https://github.com/dev-chenxing/MyManor) | GitHub | blocked | types.Lockable.setKeyRecord, world.getObjectByFormId | two families away |
| [OtcInfiniteArrowsBolts](https://github.com/OffTheClockMods/morrowind-openmw-mods) | GitHub | blocked | I.UI, MENU | two families away |
| [OtcNoWeaponArmorWear](https://github.com/OffTheClockMods/morrowind-openmw-mods) | GitHub | blocked | MENU, Item.itemData | two families away |
| [OtcSkillGainMultiplier](https://github.com/OffTheClockMods/morrowind-openmw-mods) | GitHub | blocked | MENU, skills / stats | two families away |
| [pause-control](https://gitlab.com/modding-openmw/pause-control) | GitLab | blocked | I.UI, self.controls | two families away |
| [PharisConvenientThiefTools](https://github.com/lucipharis/convenient-thief-tools) | GitHub | blocked | UI layouts, types.Lockable.getTrapSpell | two families away |
| [provincial-beginning-anvil](https://gitlab.com/modding-openmw/provincial-beginning) | GitLab | blocked | core.getFormId, world.getObjectByFormId | two families away |
| [ranged-headshot](https://gitlab.com/modding-openmw/ranged-headshot) | GitLab | blocked | I.Combat, self.getBoundingBox | two families away |
| [ReAnimation_API](https://github.com/MaxYari/OpenMWReAnimation) | GitHub | blocked | animation, flag PLAYER+NPC+CREATURE | two families away |
| [SetBonusFlags](https://github.com/staticnation/set_bonus) | GitHub | blocked | Actor.isSwimming, types.Actor.getCurrentSpeed | two families away |
| [ShelfControl](https://github.com/OpenMW-Mod-Collection/ShelfControl) | GitHub | blocked | interfaces.Crimes.commitCrime, types.Player.OFFENSE_TYPE.Theft | two families away |
| [SneakAttackXp](https://github.com/Gogglebrian/OpenMW-SneakAttackXp) | GitHub | blocked | skills / stats, self.type.getCurrentSpeed | two families away |
| [starwind-immersive-bings-races](https://gitlab.com/modding-openmw/starwind-immersive-bings-races) | GitLab | blocked | I.UI, ItemUsage.addHandlerForType | two families away |
| [tabToClose](https://github.com/ArshvirGoraya/TabToClose-Morrowind-Mod) | GitHub | blocked | I.UI, input | two families away |
| [TrulyConstantEffects](https://github.com/OpenMW-Mod-Collection/TrulyConstantEffects) | GitHub | blocked | magic, MENU | two families away |
| [voshondsQuickSelectPresentation](https://github.com/voshond/openmw-quick-select) | GitHub | blocked | UI layouts, I.UI | two families away |
| [Abandoned_Flat_Containers](https://gitlab.com/modding-openmw/abandoned-flat-containers) | GitLab | blocked | skills / stats, ambient.isMusicPlaying, ambient.stopMusic |  |
| [archipelago](https://github.com/AdrienPiechocki/OpenMW-Archipelago) | GitHub | blocked | magic, MENU, onStateChanged |  |
| [carefree_leveling [0.49 or later\]](https://github.com/phi-fell/carefree_leveling) | GitHub | blocked | UI layouts, MENU, skills / stats | needed --source (several source folders) |
| [clockextended](https://gitlab.com/zuzaman/openmw-lua-tests) | GitLab | blocked | UI layouts, core.i18n, openmw.settings |  |
| [fist_strike](https://github.com/artmonkeystudioscrypto-coder/COS-Gauntlets-MW) | GitHub | blocked | magic, skills / stats, Item.itemData |  |
| [HorizontalCompass](https://www.nexusmods.com/morrowind/mods/58214) | Nexus | blocked | UI layouts, I.UI, camera |  |
| [MI_UniversalSorter](https://github.com/rampageeee/openmw-mods-and-ports-hub) | GitHub | blocked | UI layouts, I.UI, types.Lockable.getTrapSpell |  |
| [momw-lua-patcher](https://gitlab.com/modding-openmw/momw-lua-patcher) | GitLab | blocked | content / markup / debug, core.getFormId, world.getObjectByFormId |  |
| [momw-lua-settings-EV](https://gitlab.com/modding-openmw/momw-lua-settings) | GitLab | blocked | UI layouts, MENU, content / markup / debug |  |
| [nomoreexcessivehealing](https://www.nexusmods.com/morrowind/mods/58337) | Nexus | blocked | UI layouts, magic, MENU |  |
| [protected-beasts](https://gitlab.com/modding-openmw/protected-beasts) | GitLab | blocked | I.UI, content / markup / debug, ItemUsage.addHandlerForType |  |
| [skooma_effect](https://gitlab.com/ptmikheev/openmw-lua-examples) | GitLab | blocked | camera, self.controls, onConsume |  |
| [YouMaySpeak](https://github.com/rumaks-xyz/YouMaySpeak) | GitHub | blocked | magic, camera, nearby.asyncCastRenderingRay |  |
| [ZonosVoice](https://github.com/leto19/ZonosVoice) | GitHub | blocked | skills / stats, core.dialogue, core.sound.isSayActive |  |
| [convenient-thief-tools](https://gitlab.com/modding-openmw/convenient-thief-tools) | GitLab | blocked | I.UI, MENU, input, types.Lockable.getTrapSpell |  |
| [friendly-autosave](https://gitlab.com/modding-openmw/friendly-autosave) | GitLab | blocked | I.UI, MENU, openmw.menu, self.type.isOnGround |  |
| [LiberateSpell](https://github.com/MVXK21/liberate-spell) | GitHub | blocked | magic, content / markup / debug, LOAD, world.mwscript.getLocalScript |  |
| [LuaPoweredArtifacts](https://github.com/OpenMW-Mod-Collection/LuaPoweredArtifacts) | GitHub | blocked | MENU, I.Combat, self.type.activeEffects, self.type.activeSpells |  |
| [t1ski](https://github.com/slowchu/OpenMW-Ski) | GitHub | blocked | input, camera, self.controls, interfaces.Controls.overrideMovementControls |  |
| [ThievesPickpocket](https://www.nexusmods.com/morrowind/mods/58362) | Nexus | blocked | UI layouts, MENU, animation, self.controls |  |
| [wandering-creature-merchants-lua-edition](https://gitlab.com/modding-openmw/wandering-creature-merchants-lua-edition) | GitLab | blocked | UI layouts, camera, api openmw_aux.time.newSimulationTimer, api openmw_aux.time.registerTimerCallback |  |
| [AdvancedCamera](https://gitlab.com/ptmikheev/openmw-lua-examples) | GitLab | blocked | input, camera, self.controls, onInputAction, types.Actor.stance |  |
| [AmmoCountHUD](https://www.nexusmods.com/morrowind/mods/58307) | Nexus | blocked | UI layouts, I.UI, MENU, input, onMouseWheel |  |
| [angry_monsters](https://gitlab.com/ptmikheev/openmw-lua-examples) | GitLab | blocked | types.Actor.canMove, types.Actor.runSpeed, types.Door.destCell, types.Door.destPosition, types.Door.destRotation |  |
| [Backstabs](https://github.com/OpenMW-Mod-Collection/Backstabs) | GitHub | blocked | magic, MENU, input, animation, I.Combat |  |
| [CameraHIM](https://gitlab.com/urm-openmw-mods/camerahim) | GitLab | blocked | UI layouts, input, camera, self.controls, util.transform.rotate |  |
| [CustomSkillCaps](https://github.com/Qlonever/CSC-OpenMW) | GitHub | blocked | UI layouts, I.UI, MENU, input, skills / stats |  |
| [dynamictimescale](https://gitlab.com/zuzaman/openmw-lua-mods) | GitLab | blocked | input, self.controls, interfaces.AI.getTargets, types.Actor.currentSpeed, world.setGameTimeScale |  |
| [enhanced-invisibility](https://gitlab.com/fallchildren/openmw-enhanced-invisibility) | GitLab | blocked | magic, animation, postprocessing, types.Creature.TYPE.Daedra, types.Creature.TYPE.Undead |  |
| [EvenGround](https://github.com/OpenMW-Mod-Collection/EvenGround) | GitHub | blocked | UI layouts, magic, MENU, skills / stats, types.Player.birthSigns.records |  |
| [HUDweaponCharge](https://github.com/nitroinferno/HUDweaponCharge) | GitHub | blocked | UI layouts, I.UI, magic, MENU, Item.itemData |  |
| [mom](https://github.com/Ember2528/MOM) | GitHub | blocked | content / markup / debug, LOAD, onContentFilesLoaded, onNewExterior, scripts/mom/compiler/cell_index.lua: openmw.world is only available to global sc |  |
| [personal-journal](https://github.com/Genny4Real1/PersonalJournal) | GitHub | blocked | UI layouts, I.UI, input, ItemUsage.addHandlerForType, types.Book.createRecordDraft |  |
| [PlayerOnFire](https://www.nexusmods.com/morrowind/mods/58345) | Nexus | blocked | magic, MENU, animation, onTeleported, postprocessing |  |
| [RandomisedBasicLoot](https://github.com/STiX360/FortunesSpoils-RandomisedEquipment) | GitHub | blocked | magic, Item.itemData, Inventory:resolve, types.Actor.isDeathFinished, types.Item.isRestocking |  |
| [SSQN](https://www.nexusmods.com/morrowind/mods/54148) | Nexus | blocked | UI layouts, MENU, core.dialogue, core.dialogue.journal.records, core.sound.records |  |
| [WillfulFlight](https://github.com/STiX360/WillfulFlight) | GitHub | blocked | magic, self.controls, types.Actor.getCapacity, types.Actor.getCurrentSpeed, types.Actor.getEncumbrance |  |
| [action-camera-swap](https://gitlab.com/modding-openmw/action-camera-swap) | GitLab | blocked | I.UI, input, camera, self.cell.hasTag, postprocessing, self.type.stance |  |
| [animated-levitation](https://gitlab.com/fallchildren/openmw-animated-levitation) | GitLab | blocked | magic, MENU, camera, animation, self.controls, core.sound.stopSoundFile3d |  |
| [BattleExp](https://github.com/the-overdriven/mw-BattleExp) | GitHub | blocked | magic, MENU, input, skills / stats, I.Combat, onInputAction |  |
| [bound-balance](https://gitlab.com/modding-openmw/bound-balance) | GitLab | blocked | input, api openmw_aux.time.newSimulationTimer, api openmw_aux.time.registerTimerCallback, self.type.activeEffects, self.type.activeSpells, self.type.getSelectedSpell |  |
| [footsteps](https://gitlab.com/modding-openmw/openmw-footsteps) | GitLab | blocked | magic, MENU, animation, content / markup / debug, core.land, core.land.getTextureAt |  |
| [MeritsOfService](https://github.com/OpenMW-Mod-Collection/MeritsOfService) | GitHub | blocked | UI layouts, I.UI, MENU, skills / stats, core.dialogue.journal.records, onConsoleCommand |  |
| [real-telekinesis-openmw](https://github.com/crazoter/openmw-real-telekinesis) | GitHub | blocked | UI layouts, input, camera, onInputAction, Actor.isSwimming, scripts/real-telekinesis-openmw/PAIN.lua: openmw.ui is only available to player  |  |
| [sanctuary-from-unarmored](https://github.com/Grobarch/SanctuaryFromUnarmored) | GitHub | blocked | UI layouts, magic, MENU, skills / stats, I.Combat, api openmw_aux.util.shallowCopy |  |
| [ScalableDwemerPuzzleBoxRandomizer](https://gitlab.com/modding-openmw/gonzos-scalable-dwemer-puzzle-box-randomizer) | GitLab | blocked | MENU, animation, core.getFormId, core.sound.isSoundFilePlaying, core.sound.stopSoundFile3d, world.getObjectByFormId |  |
| [speechcraft_bribe](https://github.com/slowchu/Speechcraft-Bribery-OpenMW-Lua) | GitHub | blocked | UI layouts, I.UI, MENU, input, skills / stats, Inventory:resolve |  |
| [third-person-alt-attacks](https://gitlab.com/fallchildren/openmw-third-person-alt-attacks) | GitLab | blocked | magic, MENU, camera, skills / stats, animation, flag PLAYER+NPC |  |
| [WayfarerPacks](https://github.com/STiX360/WayfarerPacks) | GitHub | blocked | UI layouts, magic, camera, animation, ItemUsage.addHandlerForType, types.Miscellaneous.createRecordDraft |  |
| [AttendMe](https://github.com/cyberplanner/AttendMe) | GitHub | blocked | UI layouts, interfaces.AI.getTargets, nearby.castNavigationRay, nearby.NAVIGATOR_FLAGS.UsePathgrid, nearby.NAVIGATOR_FLAGS.Walk, types.Actor.stance, util.transform.rotate |  |
| [MemorialLedger](https://github.com/STiX360/Memorial-Ledger) | GitHub | blocked | UI layouts, I.UI, MENU, input, onControllerButtonPress, onMouseButtonPress, openmw.menu |  |
| [PotentialCharacterProgression](https://github.com/Qlonever/PCP-OpenMW) | GitHub | blocked | UI layouts, I.UI, MENU, input, skills / stats, types.Player.classes.record, types.Player.races.record |  |
| [ragdoll_manual_autostart [scripts_data_ragdoll_wounds\]](https://github.com/gabrielczeta-ctrl/kinetic) | GitHub | blocked | camera, ragdolltest.clearLimbDamage, ragdolltest.getState, ragdolltest.prepareEquippedWeapon, ragdolltest.setCombatTarget, ragdolltest.setPowered, types.NPC.createRecordDraft | needed --source (several source folders) |
| [setbonus](https://github.com/staticnation/set_bonus) | GitHub | blocked | UI layouts, magic, I.Combat, scripts/SetBonus/conditions.lua: openmw.world is only available to global script, types.Actor.getCapacity, types.Actor.getEncumbrance, types.Player.getBirthSign |  |
| [takeall](https://github.com/voshond/openmw-takeall) | GitHub | blocked | I.UI, input, Inventory:resolve, self.animations, self.animations.hasScript, self.animations.playScript, types.Item.isCarriable |  |
| [BlackSoulGems](https://gitlab.com/modding-openmw/black-soul-gems) | GitLab | blocked | I.UI, magic, animation, ItemUsage.addHandlerForType, core.getFormId, types.Miscellaneous.getSoul, world.getObjectByFormId, world.mwscript.getLocalScript |  |
| [codex_bridge](https://github.com/TommyPhelps/codex-exe) | GitHub | blocked | magic, skills / stats, onTeleported, core.dialogue.journal.records, core.regions.records, types.Player.birthSigns.record, types.Player.getBirthSign, types.Player.journal |  |
| [CombatJuice](https://github.com/MaxYari/TheCombatJuiceOpenMW) | GitHub | blocked | UI layouts, I.UI, magic, MENU, camera, I.Combat, nearby.asyncCastRenderingRay, world.setSimulationTimeScale |  |
| [LightHotkey](https://gitlab.com/modding-openmw/light-hotkey) | GitLab | blocked | UI layouts, I.UI, MENU, input, animation, I.Combat, Item.itemData, Actor.isSwimming |  |
| [UltimateFishingOpenMW](https://github.com/rampageeee/openmw-mods-and-ports-hub) | GitHub | blocked | UI layouts, I.UI, camera, animation, I.Combat, Actor.isSwimming, onTeleported, self.object.cell.waterLevel |  |
| [BookWorm](https://github.com/zerac/OpenMW-BookWorm) | GitHub | blocked | UI layouts, I.UI, magic, MENU, input, camera, core.sendEvent, nearby.asyncCastRenderingRay, types.Container.capacity |  |
| [dash_dodge](https://github.com/wgrodzicki/dash-dodge) | GitHub | blocked | magic, input, content / markup / debug, Actor.isSwimming, types.Actor.canMove, types.Actor.getCurrentSpeed, types.Actor.getRunSpeed, types.Actor.getWalkSpeed, types.Actor.isOnGround |  |
| [EnchantMachine](https://github.com/JohnFlyIII/EnchantMachine-OpenMW) | GitHub | blocked | UI layouts, I.UI, magic, ItemUsage.addHandlerForType, types.Armor.itemData, types.Clothing.itemData, types.Miscellaneous.createRecordDraft, types.Miscellaneous.itemData, types.Weapon.itemData |  |
| [openmw-tavern-keeper](https://github.com/nibbyy/openmw-tavern-keeper) | GitHub | blocked | UI layouts, I.UI, MENU, input, content / markup / debug, onMouseWheel, onTeleported, onMouseButtonPress, types.NPC.createRecordDraft |  |
| [refined_alchemy](https://github.com/kapitansen/RefinedAlchemy) | GitHub | blocked | UI layouts, I.UI, magic, MENU, skills / stats, onMouseWheel, core.stats, types.Apparatus.TYPE, types.Potion.createRecordDraft |  |
| [UiModes](https://gitlab.com/modding-openmw/ui-modes) | GitLab | blocked | UI layouts, I.UI, magic, input, camera, self.controls, onControllerButtonPress, onInputAction, interfaces.Controls.overrideUiControls |  |
| [UniversalContainerSorter](https://github.com/rampageeee/openmw-mods-and-ports-hub) | GitHub | blocked | UI layouts, I.UI, MENU, onTeleported, types.Container.getCapacity, types.Container.getEncumbrance, types.Item.isCarriable, types.Item.isRestocking, types.Lockable.getTrapSpell |  |
| [vaults_restricted](https://www.nexusmods.com/morrowind/mods/58405) | Nexus | blocked | UI layouts, magic, MENU, animation, self.controls, onTeleported, nearby.findNearestNavMeshPosition, types.Actor.getPathfindingAgentBounds, types.NPC.expel |  |
| [balance-correlation](https://github.com/KingDavid73/Dreamforged) | GitHub | blocked | I.UI, MENU, camera, content / markup / debug, I.Combat, nearby.findRandomPointAroundCircle, nearby.NAVIGATOR_FLAGS.Walk, openmw.menu, types.Actor.getPathfindingAgentBounds, types.Creature.TYPE.Creatures |  |
| [bms-IER](https://gitlab.com/modding-openmw/better-merchants-skills) | GitLab | blocked | UI layouts, I.UI, magic, MENU, skills / stats, interfaces.Controls, scope I.Activation (global only), scope I.AI (actor only), scope I.Controls (player only), scope openmw.self (local only) |  |
| [GreaterIntervention](https://github.com/renekuhs/OpenMW-Greater-Intervention) | GitHub | blocked | UI layouts, I.UI, magic, input, onControllerButtonPress, onConsoleCommand, types.Door.destCell, types.Door.destPosition, types.Door.isTeleport, types.Player.getSelectedSpell |  |
| [Hestatur](https://gitlab.com/modding-openmw/hestatur) | GitLab | blocked | UI layouts, I.UI, camera, animation, onInputAction, core.vfx.spawn, nearby.findRandomPointAroundCircle, onConsoleCommand, types.Miscellaneous.getSoul, world._runStandardActivationAction |  |
| [omw-achievements](https://github.com/caz1que/OMW-Achievements) | GitHub | blocked | UI layouts, I.UI, MENU, input, Item.itemData, onInputAction, onMouseWheel, core.getRealFrameDuration, onConsume, openmw.menu |  |
| [Pedalator](https://github.com/arielkuzminski/pedalator) | GitHub | blocked | I.UI, input, self.controls, interfaces.Controls.overrideCombatControls, interfaces.Controls.overrideMovementControls, self.ATTACK_TYPE.Any, self.ATTACK_TYPE.NoAttack, types.Player.CONTROL_SWITCH.Fighting, types.Player.CONTROL_SWITCH.Magic, types.Player.getControlSwitch |  |
| [SkyrimCompat](https://gitlab.com/ptmikheev/openmw-lua-examples) | GitLab | blocked | input, core.getFormId, types.ESM4Activator, types.ESM4Armor, types.ESM4Clothing, types.ESM4Ingredient, types.ESM4Miscellaneous, types.ESM4Potion, types.ESM4Weapon, world.getObjectByFormId |  |
| [TwentyTwentyObjects](https://github.com/maxbickett/twentytwentyobjects) | GitHub | blocked | UI layouts, MENU, camera, GameObject:getBoundingBox, api openmw_aux.util.map, nearby.statics, openmw.menu, types.Door.destCell, types.Gold, util.transform.apply |  |
| [piagent](https://github.com/maxeozakh/pi-plays-morrowind) | GitHub | blocked | I.UI, camera, self.controls, interfaces.Controls.overrideCombatControls, interfaces.Controls.overrideMovementControls, self.ATTACK_TYPE.Any, self.ATTACK_TYPE.NoAttack, self.cell.displayName, types.Player.CONTROL_SWITCH, types.Player.getControlSwitch, types.Player.journal |  |
| [echo](https://github.com/misza3444/morrowind) | GitHub | blocked | UI layouts, I.UI, MENU, camera, animation, self.controls, interfaces.Controls.overrideCombatControls, interfaces.Controls.overrideMovementControls, interfaces.Controls.overrideUiControls, onMouseButtonPress, openmw.menu, self.ATTACK_TYPE.NoAttack |  |
| [FactionIntervention](https://github.com/STiX360/FactionIntervention) | GitHub | blocked | magic, skills / stats, animation, self.controls, self.ATTACK_TYPE.NoAttack, types.Activator.createRecordDraft, types.NPC.joinFaction, types.NPC.leaveFaction, types.NPC.setFactionRank, types.Player.isTeleportingEnabled, world.advanceTime, world.mwscript.getLocalScript |  |
| [QuickSelect](https://gitlab.com/modding-openmw/quickselect) | GitLab | blocked | UI layouts, I.UI, magic, input, camera, Item.itemData, onControllerButtonPress, onInputAction, onMouseWheel, types.Miscellaneous.getSoul, types.Player.CONTROL_SWITCH.Controls, types.Player.getControlSwitch |  |
| [voshondsQuickSelect](https://github.com/voshond/openmw-quick-select) | GitHub | blocked | UI layouts, I.UI, magic, input, Item.itemData, onControllerButtonPress, onInputAction, onMouseWheel, types.Item.getEnchantmentCharge, types.Item.itemData.condition, types.Item.itemData.enchantmentCharge, types.Miscellaneous.getSoul |  |
| [comprehensive_objective_mod](https://github.com/spdforbital/comprehensive-objective-mod) | GitHub | blocked | UI layouts, I.UI, magic, input, camera, skills / stats, onControllerButtonPress, self.cell.hasTag, core.dialogue.journal.records, types.Door.destCell, types.Door.destPosition, types.Door.isTeleport, types.Player.journal |  |
| [go-home-fr](https://gitlab.com/modding-openmw/go-home) | GitLab | blocked | UI layouts, camera, self.cell.hasTag, ?:hasTag, api openmw_aux.time.newSimulationTimer, api openmw_aux.time.registerTimerCallback, Cell:hasTag, nearby.asyncCastRenderingRay, nearby.FIND_PATH_STATUS.Success, nearby.findPath, nearby.NAVIGATOR_FLAGS.OpenDoor, nearby.NAVIGATOR_FLAGS.UsePathgrid, nearby.NAVIGATOR_FLAGS.Walk |  |
| [halveth](https://github.com/Juri-Halveth/halveth-morrowind-genesis) | GitHub | blocked | UI layouts, I.UI, magic, camera, skills / stats, content / markup / debug, Item.itemData, core.weather.getCurrentSunPercentage, postprocessing, self.cell.displayName, types.Apparatus.TYPE.MortarPestle, types.Book.createRecordDraft, types.NPC.createRecordDraft |  |
| [MercyCAO](https://github.com/MaxYari/OpenMWMercyCAO) | GitHub | blocked | UI layouts, magic, animation, self.controls, content / markup / debug, I.Combat, self.cell.hasTag, interfaces.AI.filterPackages, interfaces.AI.forEachPackage, interfaces.AI.getTargets, onConsoleCommand, onConsume, types.Door.activateDoor |  |
| [openmw_books_enhanced](https://gitlab.com/modding-openmw/openmw-books-enhanced) | GitLab | blocked | UI layouts, I.UI, magic, input, camera, onControllerButtonPress, onMouseWheel, interfaces.Crimes.commitCrime, onControllerButtonRelease, types.Player.classes.records, types.Player.OFFENSE_TYPE.Theft, types.Player.races.records, world._runStandardActivationAction |  |
| [questman](https://github.com/fixer-m/morrowind-questman) | GitHub | blocked | UI layouts, I.UI, MENU, input, onControllerButtonPress, onMouseWheel, core.dialogue.greeting, core.dialogue.journal.records, core.dialogue.topic, core.getRealFrameDuration, interfaces.Controls.overrideUiControls, types.Player.journal, util.color.commaString |  |
| [skeleton_key_hud](https://gitlab.com/modding-openmw/the-skeleton-key) | GitLab | blocked | UI layouts, I.UI, magic, skills / stats, onMouseWheel, core.dialogue.journal.records, self.cell.displayName, types.Actor.getCapacity, types.Actor.getEncumbrance, types.NPC.getFactionReputation, types.Player.birthSigns.records, types.Player.getBirthSign, types.Player.journal |  |
| [state-based-magicka-regen](https://gitlab.com/modding-openmw/state-based-magicka-regen) | GitLab | blocked | UI layouts, magic, MENU, self.controls, self.cell.hasTag, interfaces.Controls, scope I.Activation (global only), scope I.AI (actor only), scope I.Controls (player only), scope openmw.self (local only), self.type.get, types.Actor.getCapacity, types.Actor.getEncumbrance |  |
| [signpost-fast-travel](https://gitlab.com/modding-openmw/signpost-fast-travel) | GitLab | blocked | UI layouts, I.UI, input, onControllerButtonPress, self.cell.hasTag, interfaces.AI.getTargets, nearby.castNavigationRay, nearby.findNearestNavMeshPosition, nearby.findRandomPointAroundCircle, nearby.NAVIGATOR_FLAGS.UsePathgrid, nearby.NAVIGATOR_FLAGS.Walk, types.Player.isOnGround, util.transform.rotate, world.advanceTime |  |
| [TeleportTransition](https://github.com/STiX360/TeleportTransition) | GitHub | blocked | UI layouts, I.UI, magic, skills / stats, animation, self.controls, onTeleported, interfaces.Controls.overrideCombatControls, postprocessing, self.ATTACK_TYPE.Any, self.ATTACK_TYPE.NoAttack, types.NPC.isSwimming, types.Player.isTeleportingEnabled, types.Player.setTeleportingEnabled |  |
| [GMSTProfiles](https://github.com/STiX360/GMST-editor) | GitHub | blocked | UI layouts, I.UI, MENU, content / markup / debug, LOAD, onContentFilesLoaded, types.Actor.getCapacity, types.Actor.getEncumbrance, types.Actor.getRunSpeed, types.Miscellaneous.createRecordDraft, types.Player.CONTROL_SWITCH, types.Player.CONTROL_SWITCH.Controls, types.Player.CONTROL_SWITCH.Fighting, types.Player.getControlSwitch, types.Player.setControlSwitch |  |
| [KatarsKnuckles](https://github.com/MaxYari/Katars-KnucklesOpenMW) | GitHub | blocked | UI layouts, magic, MENU, camera, skills / stats, animation, content / markup / debug, I.Combat, Item.itemData, onTeleported, LOAD, onContentFilesLoaded, scripts/MaxYari/H2HWeapons/animations.lua: openmw.ui is only available to player, types.Weapon.createRecordDraft, world.vfx.spawn |  |
| [NGLAMapandTrackingOverhaul](https://github.com/MVXK21/NGLA-Map-and-Tracking-Overhaul) | GitHub | blocked | UI layouts, I.UI, MENU, input, camera, onControllerButtonPress, self.cell.hasTag, onMouseWheel, core.getRealFrameDuration, interfaces.AI.getTargets, self.cell.displayName, types.Actor.getCapacity, types.Actor.getEncumbrance, types.Player.isTeleportingEnabled, world.advanceTime |  |
| [thedarkproject](https://gitlab.com/modding-openmw/thedarkproject) | GitLab | blocked | UI layouts, magic, MENU, camera, animation, self.controls, self.cell.hasTag, GameObject:getBoundingBox, core.sound.isSayActive, nearby.findPath, scope I.AI (actor only), self.getBoundingBox, types.Actor.getPathfindingAgentBounds, types.NPC.activeEffects, world.vfx.spawn |  |
| [Art_of_Alchemy_Record_Balance](https://github.com/rampageeee/openmw-mods-and-ports-hub) | GitHub | blocked | UI layouts, I.UI, magic, skills / stats, content / markup / debug, onMouseWheel, ItemUsage.addHandlerForType, core.sound.records, LOAD, onConsume, onContentFilesLoaded, types.Apparatus.TYPE.Alembic, types.Apparatus.TYPE.Calcinator, types.Apparatus.TYPE.MortarPestle, types.Apparatus.TYPE.Retort, types.Potion.createRecordDraft, world.vfx.spawn |  |
| [OpenNevermind](https://gitlab.com/modding-openmw/opennevermind) | GitLab | blocked | UI layouts, I.UI, input, camera, self.controls, onInputAction, GameObject:getBoundingBox, nearby.FIND_PATH_STATUS.Success, nearby.findPath, nearby.NAVIGATOR_FLAGS.Swim, nearby.NAVIGATOR_FLAGS.UsePathgrid, nearby.NAVIGATOR_FLAGS.Walk, self.getBoundingBox, types.Actor.stance, types.ESM4Door, types.ESM4Door.objectIsInstance, types.ESM4Static |  |
| [MRF](https://gitlab.com/modding-openmw/magic-rebalance-and-fixes) | GitLab | blocked | UI layouts, I.UI, magic, MENU, camera, skills / stats, content / markup / debug, ItemUsage.addHandlerForType, interfaces.Controls, LOAD, onContentFilesLoaded, scope I.Activation (global only), scope I.AI (actor only), scope I.Controls (player only), scope openmw.self (local only), world.getPausedTags, world.pause, world.unpause |  |
| [HestaturLife](https://github.com/nox7/openmw-hestatur-life) | GitHub | blocked | UI layouts, core.dialogue, core.dialogue.CONDITION_TYPE.Choice, types.Book.createRecordDraft, ui2.Alignment.Center, ui2.border, ui2.cursor, ui2.dimension, ui2.dimensions, ui2.Flex.new, ui2.FlexDirection.Column, ui2.FlexDirection.Row, ui2.Grid.new, ui2.Image.new, ui2.LayerPlacement.Above, ui2.Text.new, ui2.texture, ui2.UILayer.new, ui2.Widget.new |  |
| [FLOW_AMF](https://github.com/dubiousNPC/Parkourwind-Flow_Moveset_Framework) | GitHub | blocked | UI layouts, I.UI, magic, input, camera, skills / stats, animation, self.controls, Actor.isSwimming, interfaces.Controls.overrideCombatControls, interfaces.Controls.overrideMovementControls, nearby.asyncCastRenderingRay, nearby.findNearestNavMeshPosition, self.cell.waterLevel, self.getBoundingBox, types.Activator.createRecordDraft, types.Actor.canMove, types.Actor.getCapacity, types.Actor.getEncumbrance, types.Actor.isOnGround |  |
| [HBFS](https://gitlab.com/modding-openmw/harder-better-faster-stronger) | GitLab | blocked | UI layouts, I.UI, magic, MENU, input, skills / stats, self.controls, content / markup / debug, I.Combat, Item.itemData, self.cell.hasTag, core.weather.getCurrentSunVisibility, interfaces.AI.getTargets, interfaces.Crimes.commitCrime, scope I.Activation (global only), scope I.Activation (global only), scope openmw.self (local only), types.Creature.TYPE.Undead, types.Player.OFFENSE_TYPE.Theft, world.mwscript.getLocalScript |  |
| [living_morrowind](https://github.com/MVXK21/Living-Morrowind) | GitHub | blocked | UI layouts, I.UI, magic, input, camera, skills / stats, self.cell.hasTag, onMouseWheel, Actor.isSwimming, core.dialogue, core.dialogue.records, interfaces.Controls, interfaces.Controls.overrideCombatControls, interfaces.Controls.overrideMovementControls, interfaces.Controls.overrideUiControls, types.Door.destCell, types.Door.isTeleport, types.NPC.stats.disposition, types.Player.journal, types.Spell, types.Spell.record |  |
| [ragdoll_manual_autostart [scripts_data_ragdoll_hub\]](https://github.com/gabrielczeta-ctrl/kinetic) | GitHub | blocked | magic, ragdolltest.applyCombatImpulse, ragdolltest.captureScreenshot, ragdolltest.clearLimbDamage, ragdolltest.getState, ragdolltest.injectMouseInput, ragdolltest.playerRollWanted, ragdolltest.prepareEquippedWeapon, ragdolltest.releaseWeapon, ragdolltest.resurrect, ragdolltest.setAutomaticRecovery, ragdolltest.setCombatTarget, ragdolltest.setGuard, ragdolltest.setPlayerAlwaysHits, ragdolltest.setPowered, ragdolltest.setRecoveryDirection, ragdolltest.spawnSparks, types.Door.destCell, types.Door.destPosition, types.Door.destRotation, types.Door.isTeleport, types.NPC.createRecordDraft | needed --source (several source folders) |
| [ambient](https://github.com/studioroor/tomorrowind) | GitHub | blocked | I.UI, MENU, camera, self.controls, content / markup / debug, GameObject:getBoundingBox, core.land.getHeightAt, core.land.getTextureAt, core.weather.changeWeather, core.weather.getCurrentSunLightDirection, core.weather.records, nearby.findPath, openmw.menu, types.Door.getDoorState, types.Door.isOpen, types.Static.createRecordDraft, world.setGameTimeScale, world.terrain, world.terrain.flatten, world.terrain.paint, world.terrain.raise, world.terrain.reset, world.terrain.VERSION |  |
| [TakeCover](https://gitlab.com/modding-openmw/take-cover-openmw) | GitLab | blocked | UI layouts, magic, MENU, animation, self.controls, Actor.isSwimming, interfaces.Controls, nearby.castNavigationRay, nearby.FIND_PATH_STATUS, nearby.FIND_PATH_STATUS.PartialPath, nearby.FIND_PATH_STATUS.Success, nearby.findNearestNavMeshPosition, nearby.findPath, nearby.findRandomPointAroundCircle, nearby.NAVIGATOR_FLAGS.Walk, scope I.AI (actor only), scope I.Controls (player only), scope openmw.self (local only), scripts/TakeCover/config/store.lua: I.Activation is only available to global scr, self.ATTACK_TYPE.NoAttack, types.Actor.canMove, types.Actor.getPathfindingAgentBounds, types.Actor.isOnGround |  |
| [ncgdmw](https://gitlab.com/modding-openmw/ncgdmw-lua) | GitLab | blocked | UI layouts, magic, MENU, input, camera, skills / stats, animation, self.controls, I.Combat, Item.itemData, self.cell.hasTag, Actor.isSwimming, self.cell.waterLevel, self.getBoundingBox, types.Actor.getCapacity, types.Actor.getEncumbrance, types.Actor.getPathfindingAgentBounds, types.Actor.getRunSpeed, types.Actor.isOnGround, types.Lockable.getTrapSpell, types.Player.birthSigns.record, types.Player.getBirthSign, types.Player.getSelectedSpell, types.Player.races.record |  |
| [AshenLoot](https://github.com/KingDavid73/Dreamforged) | GitHub | blocked | UI layouts, I.UI, magic, MENU, input, camera, skills / stats, animation, I.Combat, onControllerButtonPress, self.cell.hasTag, ItemUsage.addHandlerForType, onTeleported, interfaces.AI.forEachPackage, interfaces.ItemUsage, nearby.findRandomPointAroundCircle, nearby.NAVIGATOR_FLAGS.Walk, types.Actor.getPathfindingAgentBounds, types.Armor.createRecordDraft, types.Book.createRecordDraft, types.Creature.createRecordDraft, types.Creature.TYPE.Creatures, types.Creature.TYPE.Daedra, types.Creature.TYPE.Undead, types.LevelledCreature.records |  |
| [SPELL_FRAMEWORK_PLUS](https://github.com/skrow-42/OpenMW_SPELLFRAMEWORKPLUS) | GitHub | blocked | magic, MENU, camera, skills / stats, animation, self.controls, content / markup / debug, I.Combat, Item.itemData, GameObject:getBoundingBox, engineHandlers, eventHandlers, interfaces.Crimes, interfaces.Crimes.commitCrime, scripts/OMW_MagExp/magexp_global.lua: I.Combat is only available to actor script, self.getBoundingBox, types.Lockable.lockLevel, types.MiscItem, types.MiscItem.records, types.OFFENSE_TYPE_IDS, types.OFFENSE_TYPE_IDS.Trespassing, types.RepairPick, world.vfx, world.vfx.remove, world.vfx.spawn |  |
| [OblivionStyleSpellCastingOSSC](https://github.com/MrZer0x0/ArenaMP) | GitHub | blocked | UI layouts, I.UI, magic, input, camera, skills / stats, animation, self.controls, content / markup / debug, Item.itemData, Actor.isSwimming, core.regions, core.regions.records, interfaces.AI.forEachPackage, interfaces.AI.getTarget, interfaces.Controls, interfaces.Controls.overrideCombatControls, self.ATTACK_TYPE.NoAttack, self.getBoundingBox, types.Actor.canMove, types.Actor.getCapacity, types.Actor.getEncumbrance, types.MiscItem, types.MiscItem.record, types.Player.getSelectedEnchantedItem, types.Player.getSelectedSpell |  |
| [LuaMultiMark](https://gitlab.com/modding-openmw/daisys-lua-multimark) | GitLab | blocked | UI layouts, I.UI, magic, input, camera, content / markup / debug, onControllerButtonPress, onInputAction, core.regions.records, interfaces.AI.forEachPackage, LOAD, self.cell.displayName, self.headerUi, self.headerUi.destroy, self.infoUi, self.infoUi.destroy, self.list, self.listMode, self.reDraw, self.rowCountX, self.rowCountY, self.scrollOffset, self.ui, self.ui.destroy, self.windowType, types.Player.isTeleportingEnabled, world.getSimulationTimeScale, world.setSimulationTimeScale |  |
| [ncg](https://gitlab.com/modding-openmw/natural-character-growth) | GitLab | blocked | UI layouts, I.UI, magic, MENU, input, camera, skills / stats, I.Combat, Item.itemData, self.cell.hasTag, Actor.isSwimming, core.regions.records, interfaces.Controls, openmw.menu, scope I.AI (actor only), scope I.Controls (player only), scope I.Controls (player only), scope openmw.self (local only), types.Actor.canMove, types.Actor.getCapacity, types.Actor.getEncumbrance, types.Actor.isOnGround, types.Lockable.getTrapSpell, types.NPC.stats.reputation, types.Player.birthSigns.record, types.Player.getBirthSign, types.Player.races.record, world.mwscript.getLocalScript |  |
| [SHOP](https://github.com/skrow-42/SHOP) | GitHub | blocked | UI layouts, magic, animation, I.Combat, Item.itemData, onInputAction, core.sound.playSound3D, core.ui, core.ui.getMode, scripts/antitheftai/modules/companion_detection.lua: openmw.nearby is only avail, scripts/antitheftai/modules/companion_detection.lua: openmw.self is only availab, scripts/antitheftai/modules/companion_detection.lua: openmw.world is only availa, scripts/antitheftai/npc_rotation.lua: openmw.world is only available to global s, types.Actor.activeAI, types.Actor.getAiSequence, types.Door.activateDoor, types.Door.getDoorState, types.Door.isClosed, types.Door.isOpen, types.Door.isTeleport, types.Door.STATE.Closing, types.Door.STATE.Idle, types.Door.STATE.Opening, types.NPC.getFactionReputation, types.Player.factions, types.Player.getBounty, types.Player.setBounty, types.Spell.record, world.mwscript.run |  |
| [fresh-loot](https://gitlab.com/modding-openmw/fresh-loot) | GitLab | blocked | UI layouts, I.UI, magic, MENU, input, skills / stats, content / markup / debug, Item.itemData, ItemUsage.addHandlerForType, GameObject:getBoundingBox, onTeleported, interfaces.AI.getTargets, Inventory:resolve, LOAD, nearby.FIND_PATH_STATUS.EndPolygonNotFound, nearby.FIND_PATH_STATUS.NavMeshNotFound, nearby.FIND_PATH_STATUS.PartialPath, nearby.FIND_PATH_STATUS.StartPolygonNotFound, nearby.FIND_PATH_STATUS.Success, nearby.findPath, nearby.NAVIGATOR_FLAGS.Swim, nearby.NAVIGATOR_FLAGS.Walk, onContentFilesLoaded, scripts/fresh-loot/settings/settings.lua: I.Activation is only available to glob, scripts/fresh-loot/settings/store.lua: I.Activation is only available to global , types.Actor.getBarterGold, types.Actor.getPathfindingAgentBounds, types.Actor.setBarterGold, types.Creature.TYPE, types.LevelledCreature.records, types.Lockable.getTrapSpell |  |
| [FairCare](https://gitlab.com/modding-openmw/fair-care) | GitLab | blocked | UI layouts, magic, MENU, skills / stats, animation, self.controls, content / markup / debug, Item.itemData, GameObject:getBoundingBox, onTeleported, interfaces.Controls, LOAD, nearby.FIND_PATH_STATUS.PartialPath, nearby.FIND_PATH_STATUS.Success, nearby.findPath, nearby.findRandomPointAroundCircle, nearby.NAVIGATOR_FLAGS.Swim, nearby.NAVIGATOR_FLAGS.Walk, scope I.AI (actor only), scope I.Controls (player only), scope openmw.self (local only), scripts/FairCare/config/store.lua: I.Activation is only available to global scri, self.ATTACK_TYPE.Any, types.Actor.canMove, types.Actor.getCapacity, types.Actor.getEncumbrance, types.Actor.getPathfindingAgentBounds, types.Actor.getRunSpeed, types.Actor.getWalkSpeed, types.Actor.isInActorsProcessingRange, types.Creature.TYPE.Creatures, types.Creature.TYPE.Daedra, types.Creature.TYPE.Humanoid, types.Creature.TYPE.Undead |  |
| [skill-evolution](https://gitlab.com/modding-openmw/skill-evolution) | GitLab | blocked | UI layouts, magic, MENU, input, camera, skills / stats, animation, self.controls, I.Combat, Item.itemData, self.cell.hasTag, Actor.isSwimming, onTeleported, interfaces.Controls, openmw.menu, scope I.AI (actor only), scripts/skill-evolution/config/configuration.lua: I.SkillProgression is only ava, scripts/skill-evolution/config/store.lua: I.Controls is only available to player, scripts/skill-evolution/util/log.lua: I.Controls is only available to player scr, scripts/skill-evolution/util/log.lua: openmw.self is only available to local scr, self.cell.waterLevel, self.getBoundingBox, types.Actor.getCapacity, types.Actor.getEncumbrance, types.Actor.getPathfindingAgentBounds, types.Actor.getRunSpeed, types.Actor.isOnGround, types.Lockable.getTrapSpell, types.Player.getSelectedSpell, types.Potion.createRecordDraft, world.getGameTimeScale, world.getPausedTags, world.pause, world.setGameTimeScale, world.unpause |  |
| [Deckwind](https://gitlab.com/modding-openmw/deckwind) | GitLab | blocked | UI layouts, I.UI, magic, MENU, input, camera, skills / stats, animation, self.controls, content / markup / debug, Item.itemData, onControllerButtonPress, onInputAction, self.cell.hasTag, onMouseWheel, GameObject:getBoundingBox, ARMOR, core.dialogue.journal.records, core.sound.sounds, interfaces.Controls.overrideCombatControls, interfaces.Controls.overrideUiControls, interfaces.Crimes.commitCrime, onConsoleCommand, onControllerButtonRelease, onStateChanged, openmw.menu, types.Actor.Repairs, types.Door.destCell, types.Item.isRestocking, types.Miscellaneous.getSoul, types.Player.birthSigns.records, types.Player.CONTROL_SWITCH.Controls, types.Player.getBirthSign, types.Player.getControlSwitch, types.Player.OFFENSE_TYPE.Theft, util.transform.rotate, WEAPON, world._runStandardActivationAction, world._runStandardUseAction, world.setSimulationTimeScale |  |
| [ui_reboot](https://github.com/nicko996/UIReboot) | GitHub | blocked | UI layouts, I.UI, magic, MENU, input, camera, skills / stats, I.Combat, Item.itemData, onControllerButtonPress, onMouseWheel, GameObject:getBoundingBox, core.dialogue.journal.records, interfaces.Controls, interfaces.Controls.overrideUiControls, onViewportResized, self.cell.displayName, self.type.activeEffects, self.type.activeSpells, self.type.birthSigns.records, self.type.classes.records, self.type.clearSelectedCastable, self.type.getBirthSign, self.type.getFactionReputation, self.type.getSelectedEnchantedItem, self.type.getSelectedEnchantedItem.id, self.type.getSelectedSpell, self.type.getSelectedSpell.id, self.type.races.records, self.type.setSelectedEnchantedItem, self.type.setSelectedSpell, self.type.spells, self.type.stats.reputation, storage.get, types.Actor.getCapacity, types.Actor.getEncumbrance, types.Apparatus.TYPE, types.Player.birthSigns.records, types.Player.getBirthSign, types.Player.journal, world.mwscript.getLocalScript |  |
| [isowind](https://github.com/pw-tf/isowind) | GitHub | blocked | UI layouts, I.UI, magic, MENU, input, camera, self.controls, onControllerButtonPress, onInputAction, Actor.isSwimming, GameObject:getBoundingBox, onTeleported, core.regions.records, interfaces.Controls.overrideMovementControls, nearby.FIND_PATH_STATUS, nearby.FIND_PATH_STATUS.PartialPath, nearby.FIND_PATH_STATUS.Success, nearby.findNearestNavMeshPosition, nearby.findPath, nearby.isAlly, nearby.isMmo, nearby.isOtherPlayer, onMouseButtonPress, postprocessing, self.ATTACK_TYPE.Any, self.ATTACK_TYPE.Chop, self.ATTACK_TYPE.Chop.position, self.ATTACK_TYPE.Chop.position.length, self.ATTACK_TYPE.Chop.position.x, self.ATTACK_TYPE.Chop.position.y, self.ATTACK_TYPE.Chop.position.z, self.ATTACK_TYPE.NoAttack, self.ATTACK_TYPE.Slash, self.ATTACK_TYPE.Thrust, types.Actor.canMove, types.Actor.getPathfindingAgentBounds, types.Door.destCell, types.Door.isTeleport, types.Lockable.getTrapSpell, types.Player.CONTROL_SWITCH.Controls, types.Player.CONTROL_SWITCH.Jumping, types.Player.CONTROL_SWITCH.Looking, types.Player.getControlSwitch, types.Player.setControlSwitch |  |
| [Tomorrowind](https://github.com/studioroor/tomorrowind) | GitHub | blocked | UI layouts, I.UI, camera, animation, self.controls, I.Combat, GameObject:getBoundingBox, core.land.getHeightAt, Inventory:resolve, nearby.findNearestNavMeshPosition, types.Activator.createRecordDraft, types.Actor.getPathfindingAgentBounds, types.BodyPart, types.BodyPart.records, types.Container.createRecordDraft, types.Door.createRecordDraft, types.NPC.createRecordDraft, types.Static.createRecordDraft, types.Weapon.createRecordDraft, util.transform.caravanTimer, util.transform.felled, util.transform.footOff, util.transform.grow, util.transform.id, util.transform.isValid, util.transform.keep, util.transform.model, util.transform.planted, util.transform.pos, util.transform.pos.x, util.transform.pos.y, util.transform.pos.z, util.transform.position, util.transform.regrown, util.transform.rotate, util.transform.scale0, util.transform.sink, util.transform.size, util.transform.want, util.transform.wood, util.transform.yaw, world.advanceTime, world.getGameTimeScale, world.terrain, world.terrain.flatten, world.terrain.paint, world.terrain.paintLine, world.terrain.raise |  |
| [Bardcraft](https://github.com/raltsmc/Bardcraft) | GitHub | blocked | UI layouts, I.UI, MENU, input, camera, skills / stats, animation, content / markup / debug, onControllerButtonPress, onMouseWheel, ItemUsage.addHandlerForType, ambient.isSoundFilePlaying, ambient.stopMusic, ambient.stopSoundFile, core.getRealFrameDuration, core.sound.isSoundFilePlaying, core.sound.stopSoundFile3d, interfaces.AI.filterPackages, interfaces.AI.getTargets, interfaces.Crimes.commitCrime, MISC_ITEM, onConsoleCommand, onMouseButtonPress, onStateChanged, openmw.menu, self.active, self.closeUI, self.controllerMode, self.createUI, self.deletePartClickCount, self.deletePartConfirmTimer, self.deletePartIndex, self.destroyUI, self.name, self.noteMap, self.playback, self.props.active, self.props.position, self.props.text, self.song, self.song.scale.mode, self.state, self.STATE.PERFORMANCE, self.STATE.SONG, self.STATE.STATS, self.type.isInActorsProcessingRange, self.windowXOff, self.ZOOM_LEVELS, self.zoomLevel, types.Player.OFFENSE_TYPE.Theft, types.Player.OFFENSE_TYPE.Trespassing, world.mwscript.getLocalScript |  |
| [brutal-morrowind](https://github.com/sunhawken/bru) | GitHub | blocked | UI layouts, I.UI, MENU, input, camera, animation, self.controls, I.Combat, Actor.isSwimming, GameObject:getBoundingBox, api openmw_aux.util.shallowCopy, api openmw_aux.util.shallowCopy.adjustDamageForDifficulty, api openmw_aux.util.shallowCopy.brutalFeedbackStats, api openmw_aux.util.shallowCopy.onHit, api openmw_aux.util.shallowCopy.pickRandomArmor, api openmw_aux.util.shallowCopy.spawnBloodEffect, onConsoleCommand, postprocessing, types.Actor.addExternalVelocity, types.Actor.armPowerStrike, types.Actor.cancelPowerStrike, types.Actor.cancelSwordClinch, types.Actor.canMove, types.Actor.configureSwordClinch, types.Actor.getBrutalOption, types.Actor.getKineticSlide, types.Actor.getLimbSeveringPoseData, types.Actor.getPathfindingAgentBounds, types.Actor.getPowerStrikeToken, types.Actor.getSeveredLimbsMask, types.Actor.getSwordClinchState, types.Actor.getTorsoSeveredPoseData, types.Actor.isHeadSevered, types.Actor.isOnGround, types.Actor.isShieldBlockRaised, types.Actor.isTorsoSevered, types.Actor.requestKineticSlide, types.Actor.setAdrenalineEffectActive, types.Actor.setBrutalOption, types.Actor.setKineticGait, types.Actor.setShieldBlock, types.Actor.stagger, types.Actor.tripKineticSlideNpc, types.Player.CONTROL_SWITCH.Controls, types.Player.CONTROL_SWITCH.Fighting, types.Player.getControlSwitch, world.applyNpcKick, world.applyNpcSuperKick, world.applyObjectImpulse, world.getBrutalImpactStats, world.getNpcRagdollState, world.kickNpcRagdoll, world.restoreNpcBloodDecals, world.setSimulationTimeScale, world.spawnBrutalImpact, world.startNpcBisection, world.startNpcDecapitation, world.startNpcLimbSevering, world.startNpcRagdoll |  |
| [LORKHAN](https://github.com/Dwemer-Dynamics/LORKHAN) | GitHub | blocked | UI layouts, I.UI, magic, MENU, input, content / markup / debug, onControllerButtonPress, onInputAction, ItemUsage.addHandlerForType, GameObject:getBoundingBox, interfaces.ItemUsage, lorkhan.actorConversationState, lorkhan.cancelMenuDialogueTts, lorkhan.cancelPlayerAutochat, lorkhan.cancelVoiceCapture, lorkhan.currentVoiceCaptureDeviceName, lorkhan.isSpeechActive, lorkhan.menuDialogueTtsStatus, lorkhan.playerAutochatStatus, lorkhan.playSpeech, lorkhan.pumpDebugCommand, lorkhan.pumpMenuDialogueTts, lorkhan.pumpPlayerAutochat, lorkhan.pumpSessionControls, lorkhan.requestBookReadAloud, lorkhan.requestDebugCommand, lorkhan.requestMenuDialogueTts, lorkhan.requestPlayerAutochat, lorkhan.requestSessionControls, lorkhan.selectSessionControl, lorkhan.sessionControls, lorkhan.sessionInfo, lorkhan.sessionInfo.client_settings, lorkhan.sessionInfo.config_revision, lorkhan.sessionInfo.generation, lorkhan.sessionInfo.session_id, lorkhan.sessionInfo.session_id.distance, lorkhan.sessionInfo.session_id.execution_mode, lorkhan.sessionInfo.session_id.identity, lorkhan.sessionInfo.session_id.identity.display_name, lorkhan.sessionInfo.session_id.player_speech_played, lorkhan.sessionInfo.session_id.speaker, lorkhan.sessionInfo.session_id.text, lorkhan.showSubtitle, lorkhan.stopSpeech, lorkhan.submitActorProfile, lorkhan.submitActorResurrected, lorkhan.submitAutomaticDiary, lorkhan.submitBoredEvent, lorkhan.submitCapturedDialogue, lorkhan.submitDebugCommandResult, lorkhan.submitDisposition, lorkhan.submitInventory, lorkhan.submitItemPickup, lorkhan.submitQuestEvent, lorkhan.submitRpgEvent, lorkhan.submitSpellCast, lorkhan.updateSessionSetting, lorkhan.voiceCaptureDevices, onMouseButtonPress, scripts/LORKHAN/adapters/openmw.lua: openmw.ui is only available to player scrip, world.advanceTime, world.getGameTimeScale, world.mwscript, world.setGameTimeScale |  |

<!-- known-mods-survey-2026-11:end -->
