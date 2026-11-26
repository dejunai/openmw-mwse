# Corpus scan coverage (omwcompat 0.4.0)

Produced with `OMW2MWSE_OPENMW=none bin/omw2mwse scan corpus --corpus` over the 25 corpus mods
(LTLO included) on 2026-11-26 with omw2mwse 0.3.0 / omwcompat 0.4.0. "API uses OK" counts uses
of `openmw.*` symbols, engine handlers and GameObject methods that omwcompat supports fully or
partially, or that are stubs or optional interfaces. "(was blocked)": blocked with omwcompat
0.3.2 / omw2mwse 0.2.5.

| Mod | Script flags | API uses OK | Verdict | Main blockers |
|---|---|---:|---|---|
| block-stealing | GLOBAL, PLAYER | 103/103 (100%) | **ready** (was blocked) | none |
| harvest-lights | CUSTOM, GLOBAL, PLAYER | 43/43 (100%) | **ready** (was blocked) | none |
| leave-the-lights-off | GLOBAL | 46/46 (100%) | **ready** | none |
| mage-robes-for-openmw-lua | CUSTOM, GLOBAL | 28/28 (100%) | **ready** (was blocked) | none |
| momw-mod-template | PLAYER | 14/14 (100%) | **ready** (was blocked) | none |
| no-fires-in-bad-weather | GLOBAL | 17/17 (100%) | **ready** | none |
| shield-unequipper | PLAYER | 38/38 (100%) | **ready** (was blocked) | none |
| wildlife-attacks-npcs-too | CREATURE | 21/21 (100%) | **ready** | none |
| skyrim-style-quest-notifications | MENU, PLAYER | 99/104 (95%) | blocked | `ui` layouts, `core.dialogue`, `core.sound.records`, MENU script |
| backstabs | CREATURE, GLOBAL, MENU, NPC, PLAYER | 97/107 (90%) | blocked | `openmw.animation`, `input` actions/triggers, `I.Combat`, magic effects, ... |
| player-on-fire | GLOBAL, MENU, PLAYER | 72/81 (88%) | blocked | `openmw.animation`, `openmw.postprocessing`, magic effects, `onTeleported`, ... |
| thieves-pickpocket | CUSTOM, GLOBAL, MENU, PLAYER | 340/383 (88%) | blocked | `openmw.animation`, `ui` layouts, `self.controls` (movement), `types.NPC.getDisposition`, ... |
| friendly-autosave | GLOBAL, MENU, PLAYER | 50/57 (87%) | blocked | `openmw.menu`, `I.UI`, `self.type.isOnGround`, `self.type.sendMenuEvent`, ... |
| vaults-restricted | CUSTOM, GLOBAL, MENU, PLAYER | 213/245 (86%) | blocked | `openmw.animation`, `ui` layouts, `nearby.findNearestNavMeshPosition`, `self.controls` (movement), ... |
| action-camera-swap | PLAYER | 79/94 (84%) | blocked | `openmw.camera`, `openmw.postprocessing`, `input` actions/triggers, `I.UI`, ... |
| you-may-speak | GLOBAL, NPC, PLAYER | 29/37 (78%) | blocked | `openmw.camera`, magic effects, `nearby.asyncCastRenderingRay` |
| no-more-excessive-healing | MENU, PLAYER | 83/107 (77%) | blocked | magic effects, `ui` layouts, MENU script |
| black-soul-gems | GLOBAL, NPC, PLAYER | 52/68 (76%) | blocked | `openmw.animation`, `core.getFormId`, `interfaces.ItemUsage.addHandlerForType`, `I.UI`, ... |
| hd-forge-for-openmw-lua | GLOBAL, LOAD | 10/13 (76%) | blocked | `openmw.content`, LOAD script |
| willful-flight | CUSTOM, GLOBAL, PLAYER | 164/222 (73%) | blocked | magic effects, `input` actions/triggers, `I.UI`, `self.ATTACK_TYPE.Any`, ... |
| horizontal-compass | PLAYER | 116/181 (64%) | blocked | `openmw.camera`, `I.UI`, `types.NPC.getDisposition`, `ui` layouts |
| hostile-permadeath | MENU, PLAYER | 7/11 (63%) | blocked | `openmw.menu`, `self.type.sendMenuEvent`, MENU script |
| ranged-headshot | NPC, PLAYER | 6/10 (60%) | blocked | `I.Combat`, `self.getBoundingBox` |
| ammo-count-hud | MENU, PLAYER | 259/510 (50%) | blocked | `ui` layouts, `input` actions/triggers, `I.UI`, `onMouseWheel`, ... |
| dynamic-modern-tutorials | PLAYER | 10/26 (38%) | blocked | `ui` layouts, `I.UI` |

Totals: 1996 of 2566 API uses are supported (77%). 8 of 25 mods are ready
(3 with 0.3.2).

The five newly ready mods were also run in the MWSE mock (load, frames, keys, activation,
save/load) without runtime errors. block-stealing blocks use while not sneaking and shows its
message. mage-robes swaps a guild member's robe through `addScript`, `setEquipment` and
`removeScript`. shield-unequipper removes the shield for a two-handed weapon and puts it back
after a save/load. The mock is not the game: confirm in game before relying on them.

## What blocks the corpus

Counts are numbers of mods, out of 25:

| Blocker | Mods |
|---|---:|
| MENU script | 9 |
| `I.UI` | 7 |
| `ui` layouts | 7 |
| magic effects | 7 |
| `openmw.animation` | 5 |
| `input` actions/triggers | 4 |
| `openmw.camera` | 3 |
| `types.NPC.getDisposition` | 3 |
| `self.controls` (movement) | 3 |
| `openmw.postprocessing` | 2 |
| `I.Combat` | 2 |
| `openmw.menu` | 2 |
| `self.type.sendMenuEvent` | 2 |
| `onTeleported` | 2 |

MENU scripts (9 mods; mostly settings pages built with `ui` layouts) block the most mods,
then `I.UI` / `ui` layouts (HUDs, windows) and magic effects (`core.magic`, `activeSpells`,
`activeEffects`); `openmw.animation` blocks 5. None of these is in scope for 0.4.0.

## Scanner limits

- The scan is static. It follows `local x = require('openmw.*')` aliases and simple
  `local y = x.a.b` re-aliases. It does not follow dynamic requires, values passed through
  function arguments, or `self`-style receivers.
- GameObject methods are matched by name (`:remove(`, `:teleport(` and so on). Calls on
  non-GameObjects with the same name are counted too, which is a false positive.
- `local` symbols (the mod's own modules) are reported for information only. They are not
  counted against coverage.
