# omwcompat_smoketest: the in-game smoke test (optional, dev)

An MWSE mod that checks the OpenMW conversions from inside the game and writes a PASS / FAIL / SKIP
report to the omwcompat library log. It is **off by default**, read-only, and never writes to MWSE.log.
It needs omwcompat 0.4.5 or later (the `omwcompat.diag` hooks); with an older runtime it reports one
SKIP and stops.

- Mod: `Data Files/MWSE/mods/mwsuite/openmw/omwcompat_smoketest/` (source in `smoketest/MWSE/...`).
- Optional dev-only plugin: `OMWC_SmokeTest_DEV.esp`, a test cell for the mod (source
  `smoketest/esp/omwc_smoketest.esp.json`). Not needed for the checks.
- Report: `Data Files\MWSE\logs\omwcompat.log`, lines starting `[smoketest]`.

## Turning it on and running it

Mod Config Menu > **OpenMW Smoke Test**:

| Control | What it does |
|---|---|
| Enabled | Off by default. On: a check runs once after every load, the hotkey works, and the test cell is filled. |
| Run after every load | Waits for the delay (default 20 s of unpaused play and at least 120 frames), then checks once. |
| Delay after load | 5 to 120 s. The wait is what lets the scripts run, so "handlers fired" has something to observe. |
| Show a message with the result | One message box: `OpenMW smoke test: 41 PASS, 0 FAIL, 3 SKIP. Details: ...`. |
| Run now (hotkey) | Default Ctrl+Shift+F10, while enabled and no menu is open. |
| Run the smoke test now | Button. Runs immediately, also while the mod is off. Load a save first. |
| Go to / Return / Respawn | The dev test cell (below). |

The config is `Data Files/MWSE/config/omwcompat_smoketest.json` (the mod's own file, nothing else is written).

## What it checks

Runtime (once): omwcompat loaded and its version; the library log opened; a save is loaded; handler
errors the runtime recorded outside converted scripts; the MW Conversions menu exists; sound gate
counters; **stub probes**: `openmw.animation` calls return quietly and warn once per mod,
`I.AnimationController` v1, `self.controls` reads work and writes are ignored (and change nothing),
the sound gate blocks a removed object's sound and leaves a live one alone; **storage round trips**:
a scratch settings section (number, integer, boolean, string, nested table, nil, reset) and the save
payload encoder. The probes use fake objects and scratch tables inside `omwcompat.diag.capture`, which
restores error counts, sound gate counters and animation counters, so the real counters and the log
are not disturbed.

World (info): the lights in the current cell (enabled, disabled, off-by-default, off copies).

Per converted mod:

| Check | PASS when | FAIL / SKIP |
|---|---|---|
| built for | built for the loaded version, or older (noted, still supported) | FAIL: built for a newer omwcompat than is loaded. SKIP: no version recorded |
| script files | every declared script file exists and parses (`loadfile`, never run) | FAIL: lists the file and error |
| enabled switch | config and runtime agree | FAIL: they differ |
| MCM tab | tab present in MW Conversions | FAIL: missing or errored. SKIP: menu not built |
| settings | every registered setting reads, type matches its default, within min/max | FAIL: lists them. SKIP: none |
| save payload | the mod's real storage and per-object data encode and decode | FAIL |
| global scripts / player scripts | every declared script is running | FAIL: did not start. SKIP: mod disabled or no save |
| object scripts | instances active in this area | SKIP: no matching object here |
| handlers | `onUpdate` observed firing; event handlers listed as fired / not triggered yet | FAIL: `onUpdate` never ran in 30+ frames. SKIP: timing counters off, or only event-driven handlers |
| handler errors | none recorded for this mod's scripts | FAIL: lists `where xN` |
| light scheduling (LTLO only) | day: at least one off copy exists; night: off copies are at most 25% of the scheduled lights | FAIL: nothing switched off by day / lights still off at night. SKIP: interior (not behave-like-exterior), within 15 min of a switch hour, weather changing, no scheduled lights |

"Handlers" are **observed**, never simulated: calling a mod's `onUpdate` from outside could change its
state, so the test reads omwcompat's own timing counters (`omwcompat.timing`). Lifecycle handlers
(`onInit`, `onLoad`, `onSave`, ...) cannot be observed and are not judged.

## Read-only guarantee

The checks never spawn, move, enable, disable or delete anything, never write `tes3.player.data` or a
save, and write no config except the mod's own. `tests/lua/test_smoketest.lua` snapshots `player.data`,
object records, cell references and configs around a run and compares them.

## Sample report

```
2026-11-27 17:40:01  [smoketest 0.1.0] ===== begin (trigger: load, cell: Seyda Neen, game hour: 12.0) =====
2026-11-27 17:40:01  [smoketest] PASS runtime: omwcompat 0.4.5 - loaded
2026-11-27 17:40:01  [smoketest] PASS runtime: library log - writing to Data Files/MWSE/logs/omwcompat.log
2026-11-27 17:40:01  [smoketest] PASS runtime: save loaded - 2560 frame(s) seen by omwcompat; waited 1200 unpaused frames / 20 s after the load
2026-11-27 17:40:01  [smoketest] PASS runtime: handler errors - none outside converted mods' scripts
2026-11-27 17:40:01  [smoketest] PASS runtime: MW Conversions menu - built by omwcompat at modConfigReady
2026-11-27 17:40:01  [smoketest] PASS runtime: sound gate counters - enabled; blocked so far: 0 removed-object, 0 off-by-default copy
2026-11-27 17:40:01  [smoketest] PASS stubs: animation stubs - 6 calls returned quietly, one warning per mod
2026-11-27 17:40:01  [smoketest] PASS stubs: I.AnimationController stubs - v1 interface; handlers accepted, never called
2026-11-27 17:40:01  [smoketest] PASS stubs: self.controls stubs - reads ok, writes ignored, game state unchanged
2026-11-27 17:40:01  [smoketest] PASS stubs: sound gate - removed-object sounds blocked, live ones untouched
2026-11-27 17:40:01  [smoketest] PASS storage: settings storage round trip - number, integer, boolean, string, nested table, nil, reset
2026-11-27 17:40:01  [smoketest] PASS storage: save payload encoder round trip - serial.encode/decode of mixed data
2026-11-27 17:40:01  [smoketest] PASS world: lights in this cell - 14 lights: 6 enabled, 8 disabled, 8 off-by-default, 6 off copies lit by a conversion
2026-11-27 17:40:01  [smoketest] PASS LeaveTheLightsOff: built for - omwcompat 0.4.5
2026-11-27 17:40:01  [smoketest] PASS LeaveTheLightsOff: script files - 1 file(s) present and parse
2026-11-27 17:40:01  [smoketest] PASS LeaveTheLightsOff: settings - 11 setting(s) read, types and ranges ok
2026-11-27 17:40:01  [smoketest] PASS LeaveTheLightsOff: handlers LTLO_g.lua - fired: onObjectActive x11, onUpdate x2461
2026-11-27 17:40:01  [smoketest] PASS LeaveTheLightsOff: light scheduling - day, hour 12.0, weather Clear: 0 whitelisted lit, 2 off copies
2026-11-27 17:40:01  [smoketest] SKIP Thieves Pickpocket: object scripts - no matching object is active in this area
2026-11-27 17:40:01  [smoketest] FAIL Wildlife Attacks NPCs Too: handler errors - scripts/wildlife.lua onUpdate x3
2026-11-27 17:40:01  [smoketest 0.1.0] ===== end: 41 PASS, 1 FAIL, 1 SKIP =====
```

(The sample is the real format; the lines for other mods are illustrative. The real LTLO lines come
from `tests/lua/test_smoketest.lua`.)

## The dev-only test cell

`OMWC_SmokeTest_DEV.esp` holds one cell, **OMWC Smoke Test**, and about 25 records. It is never part of
the normal mod archive.

**Cell type: an interior flagged "behave like exterior".** Weather, the sun and the sky only apply in
exteriors and in interiors with that flag. A real exterior would need a grid location (and a landscape
or the player falls through the void), would stream the surrounding real cells and could collide with
other mods' cells. The flagged interior is isolated, loads instantly, `coc "OMWC Smoke Test"` puts you
in its centre, and the converted mods treat it as an exterior (`isQuasiExterior`, `hasSky`): LTLO
schedules its lights there and the weather checks of No Fires in Bad Weather and LTLO run. Weather
follows the region you came from and can be forced; it is restored when you leave.

In the plugin: the cell, a floor (`ex_imp_plaza.nif`; if it looks wrong in game, change the one mesh in
the JSON), five levers (`act_sotha_lever.NIF`) and an exit (`in_hlaalu_door.nif`), the light, NPC,
robe and shield base records. In the cell, while the mod is **enabled**, the mod spawns:

| Fixture | For |
|---|---|
| 3 lanterns / streetlight (ids contain `lantern`, `streetlight`; LTLO has off models for these meshes) | Leave The Lights Off |
| a torch and a firepit (ids contain `torch`, `firepit`) | No Fires in Bad Weather |
| a thief NPC | Thieves Pickpocket |
| a mage NPC | Mage Robes |
| vanilla `rat`, next to the thief | Wildlife Attacks NPCs Too |
| a robe and a shield on the floor | Mage Robes, Shield Unequipper |

Levers (activate with the normal key): **+1 hour**, **next 06:00 / 12:00 / 18:00 / 00:00**, **next
weather**, **previous weather** (all ten, Clear to Blizzard, switched immediately), **respawn the
fixtures**. The exit door takes you back.

Nothing spawned stays in a save: the fixtures (and anything else a conversion or you put in the cell
that is not from the plugin, such as LTLO's off copies) are removed when you leave the cell, while
every save is written (they come back after it), on load, and when the mod is switched off. The
weather is put back to what it was when you entered. Two things do persist, on purpose or by necessity:
the **game hour** only moves forward (a rewound clock would confuse the converted mods' timers; past
midnight the day counter advances too), and **records** a conversion generated (LTLO's off-copy light
records) stay in the save, unused.

Teleporting: MCM **Go to the test cell** remembers where you were (in memory and in the mod's config, so
it works after a reload), **Return** or the exit door brings you back; `coc "OMWC Smoke Test"` also
works and the fixtures appear on arrival by any means.

Not verified in the engine yet (only in the mock): the exact `tes3.createReference`/`delete` behaviour
in an inactive cell, deleting inside the `save` event, `weatherController:switchImmediate`, and how
the floor mesh looks. The first in-game run should confirm those.

## Building the plugin

`scripts/build-smoketest-esp.py [--out DIR] [--tes3conv EXE | --conflict-tools DIR] [--check]`

tes3conv is looked up in `--tes3conv`, `$TES3CONV`, a conflict-tools checkout (`tools\tes3conv\tes3conv.exe`,
v0.4.1), then PATH. The build is reproducible: same JSON and tes3conv, same bytes
(`sha256 c3eaf31b1b009787a8aab09b76ac87add2c9ac5c77992cf105082dc1069b65fd`, 3256 bytes, built with the Linux
tes3conv 0.4.1; the Windows build should match, `--check` verifies reproducibility and a round trip on whichever
build you use). Edit the JSON, not the .esp.

## The hooks it needs in omwcompat (`omwcompat/diag.lua`, 0.4.5)

`omwcompat.diag`: `inspect()`, `compileCheck`, `readSettings`, `capture`, `probeStubs`, `roundTrips`,
`payloadCheck`. All read-only. `runtime.lua` gains a library-log capture (two lines in `writeLib`
and `warnOnce`) and the one `RT.diag = ...` line.
Tests: `tests/lua/test_smoketest.lua`, `tests/py/test_smoketest_esp.py`.
