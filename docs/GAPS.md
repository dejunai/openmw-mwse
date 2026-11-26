# Known gaps and risks (omwcompat 0.2.2 + LTLO 3.2)

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

## Runtime limits (MVP)

- GLOBAL scripts and object-attached scripts (NPC, CREATURE, ACTOR, CONTAINER, DOOR, LIGHT,
  ACTIVATOR; 0.3.0) are hosted. PLAYER, CUSTOM, MENU, LOAD and ITEM scripts are skipped with a
  warning. `ui`, `input`, `camera`, `ambient` and `animation` are not provided.
- Local scripts (0.3.0) differ from OpenMW in a few documented ways:
  - An instance is dropped when its object leaves the active cells and recreated when it comes
    back: the chunk runs again, then `onLoad(data from onSave)`. Unsavable timers do not survive
    this, exactly as they do not survive a save/load in OpenMW.
  - `openmw.nearby` lists the references of `tes3.getActiveCells()`; `castRay`, `findPath` and the
    other queries are not provided.
  - `I.AI`: Combat uses `mobile:startCombat`; Wander/Travel/Follow/Escort use `tes3.setAI*`;
    `removePackages` only removes Combat. `getActivePackage` reports Combat while `inCombat`,
    otherwise the aiPlanner package.
  - AI stats (`fight`, `flee`, ...) have one live value per actor in MWSE; writing `base` or
    `modifier` changes that value, never the shared record.
- Several parts are partial or stubs:
  - `world.mwscript` only provides `getGlobalScript`.
  - `GameObject:sendEvent` reaches the object's local scripts while it is active; events to an
    inactive object are dropped.
  - `addScript` and `split` raise errors.
  - `storage` is minimal. Every section is saved with the game.
  - `I.Settings` only records defaults.
  - `core.l10n` returns the key itself.
  - `API_REVISION` is a fixed 70.
- `types.*` covers records, `objectIsInstance` and inventories (`countOf` only). Stats, factions,
  spells, `Lockable` and others are absent.
- `Transform` composition is exact only for single-axis rotations. LTLO only copies rotations,
  so it is not affected.

## Scanner limits

See [COVERAGE.md](COVERAGE.md#scanner-limits).

## Settings and hard-coded values (0.2)

- The generated MCM was checked only against a recording mock of `mwse.mcm`. In game, check
  that sliders with `decimalPlaces` and `createCustom` variables behave as the mock assumes.
- The settings probe runs PLAYER/MENU scripts with inert stand-ins. A script that needs real
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
