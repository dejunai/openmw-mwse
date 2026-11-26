# Corpus scan coverage (omwcompat 0.1.0)

Produced with `bin/omw2mwse scan <corpus> --corpus` over the 19 corpus mods plus LTLO, on
2026-11-25. The full per-symbol report is regenerated into `reports/generated/corpus-scan.md`
and `.json`, which are git-ignored. "API uses OK" counts uses of `openmw.*` symbols, engine
handlers and GameObject methods that omwcompat supports fully or partially, or that are stubs or
optional interfaces.

| Mod | Script flags | API uses OK | Verdict | Main blockers |
|---|---|---:|---|---|
| leave-the-lights-off | GLOBAL | 46/46 (100%) | **ready** | none |
| no-fires-in-bad-weather | GLOBAL | 27/29 (93%) | blocked | `world.mwscript.getGlobalScript` |
| block-stealing | GLOBAL, PLAYER | 118/126 (93%) | blocked | PLAYER script, `openmw.self`, `types.Lockable`, NPC faction APIs |
| harvest-lights | CUSTOM, GLOBAL, PLAYER | 37/42 (88%) | blocked | CUSTOM/PLAYER scripts, `openmw.self` |
| skyrim-style-quest-notifications | MENU, PLAYER | 158/195 (81%) | blocked | `openmw.ui`, `openmw.self`, `openmw.ambient` |
| action-camera-swap | PLAYER | 70/92 (76%) | blocked | `openmw.camera`, `openmw.input`, `openmw.self` |
| hd-forge-for-openmw-lua | GLOBAL, LOAD | 10/13 (76%) | blocked | `openmw.content` (LOAD scripts) |
| mage-robes-for-openmw-lua | CUSTOM, GLOBAL | 19/26 (73%) | blocked | `GameObject:addScript`, CUSTOM script |
| black-soul-gems | GLOBAL, NPC, PLAYER | 46/65 (70%) | blocked | `openmw.self`, `openmw.animation`, `openmw.ui` |
| friendly-autosave | GLOBAL, MENU, PLAYER | 41/59 (69%) | blocked | `openmw.menu`, `openmw.self` |
| ammo-count-hud | MENU, PLAYER | 615/1017 (60%) | blocked | `openmw.ui`, `openmw.input`, `openmw.self` |
| momw-mod-template | PLAYER | 7/13 (53%) | blocked | `openmw.input`, `openmw.ui`, `onKeyPress` |
| willful-flight | CUSTOM, GLOBAL, PLAYER | 109/205 (53%) | blocked | `openmw.ui`, `openmw.input`, `onFrame` |
| you-may-speak | GLOBAL, NPC, PLAYER | 18/34 (52%) | blocked | `openmw.nearby`, `openmw.camera`, `onFrame` |
| ranged-headshot | NPC, PLAYER | 5/10 (50%) | blocked | `openmw.self`, `openmw.ui`, `openmw.ambient` |
| horizontal-compass | PLAYER | 186/375 (49%) | blocked | `openmw.ui`, `openmw.nearby`, `openmw.camera` |
| backstabs | CREATURE, GLOBAL, MENU, NPC, PLAYER | 32/71 (45%) | blocked | `openmw.animation`, `openmw.ambient`, `openmw.self` |
| dynamic-modern-tutorials | PLAYER | 18/41 (43%) | blocked | `openmw.ui`, `openmw.input`, `onKeyPress` |
| shield-unequipper | PLAYER | 13/32 (40%) | blocked | `openmw.self`, `onFrame` |
| hostile-permadeath | MENU, PLAYER | 4/11 (36%) | blocked | `openmw.menu`, `openmw.ui` |

Totals: 1579 of 2502 API uses are supported (63%). 1 of 20 mods is ready.

## What blocks the corpus

Counts are numbers of mods, out of 20:

| Blocker | Mods |
|---|---:|
| `openmw.self` (needs local/PLAYER script hosting) | 17 |
| PLAYER scripts not hosted | 16 |
| `openmw.ui` | 11 |
| `openmw.types` symbols not yet emulated (Actor stats, Lockable, NPC factions, ...) | 10 |
| `openmw.input` | 6 |
| MENU scripts | 5 |
| `onFrame` handler | 5 |
| `openmw.ambient`, NPC scripts | 4 each |
| `openmw.camera`, `openmw.nearby`, `onKeyPress`, CUSTOM scripts | 3 each |

The most useful next step is **PLAYER script hosting**. It needs `openmw.self`, `onFrame`,
`onKeyPress`, and `openmw.ui` messages and widgets. Hosting PLAYER scripts would unlock most of
the corpus. The cheapest next win is `world.mwscript` global variables, which would make
no-fires-in-bad-weather ready, since everything else it uses is already supported.

## Scanner limits

- The scan is static. It follows `local x = require('openmw.*')` aliases and simple
  `local y = x.a.b` re-aliases. It does not follow dynamic requires, values passed through
  function arguments, or `self`-style receivers.
- GameObject methods are matched by name (`:remove(`, `:teleport(` and so on). Calls on
  non-GameObjects with the same name are counted too, which is a false positive.
- `local` symbols (the mod's own modules) are reported for information only. They are not
  counted against coverage.
