# Quick start guide

You skipped the [README](README.md). Fine. This is the short path for someone
who wants to play with fire and is not going to read the long version first.

It is short on purpose. It will not warn you about every edge case. If anything
breaks, **stop and read the [README](README.md).** This page is not a substitute
for a backup.

> **EXPERIMENTAL. THIS CAN BREAK SAVES AND YOUR MOD SETUP.**
>
> Back up your saves (and, ideally, a copy of the Vortex staging folder) before
> you convert or enable anything. This tooling is unofficial beta software.
> Converted mods are generated for your own personal use only. Do not upload or
> share them. Do not contact the original authors about them. Support is
> **dej (dejunai)** via the Nexus Mods forums.

## 0. Back up first

Copy your saves somewhere safe. If you use Vortex, a copy of the staging folder
for the mod you are about to convert is also a good idea. There is no
`omw2mwse revert` command yet.

## 1. What you need

- To play a conversion: original Morrowind + **MWSE** (not OpenMW).
- To run the converter yourself: **Python 3.9+**, from a checkout of this repo,
  via `bin/omw2mwse` (or `py -3 bin/omw2mwse` on Windows).

Current versions are omw2mwse 0.3.2 and omwcompat 0.4.4.

## 2. If you use tidy (morrowind-conflict-tools)

Let tidy call the converter on the **staged** OpenMW Lua mod. That is the
intended path. To install the converter where tidy looks for it, copy
`install-omw2mwse.bat` into the conflict-tools root (the folder that contains
`vortex_tidy.py`) and run it; it clones this repo into `tools\omw2mwse`.

- The converter writes the MWSE files **and** a copy of the omwcompat runtime
  into that staged folder. It does not write to Data Files. Vortex's deploy
  does that later.
- If something tries to point the converter at Data Files or the Morrowind
  install, it should refuse (exit 3). Do not "fix" that by copying files into
  the game folder by hand.
- Every converted mod ships `MWSE/lib/omwcompat*`. Vortex will report a
  conflict. **Keep the newest runtime.**
- Only enable a mod whose verdict is **ready**. A **blocked** mod is not
  something to force on and hope.

Then start the game and look for the **MW Conversions** entry in the Mod Config
Menu. Each converted mod has a tab and a "Mod enabled" switch (on by default).

## 3. If you run the converter yourself

Work on a **Vortex staging folder**, never on Data Files, never on the game
install.

Preview first (this writes only the result JSON, and that file must sit outside
the staged folder):

```
bin/omw2mwse --staged-root path/to/staged-mod --result-json path/to/result.json --dry-run
```

Read `result.json`. If `verdict` is not `ready` (and is not `none`), stop.

Then convert in place:

```
bin/omw2mwse --staged-root path/to/staged-mod --result-json path/to/result.json
```

Exit 0 means it converted, or there was nothing to convert. Exit 1 is blocked,
2 is failed, 3 means you pointed it at Data Files or the game install. After a
successful convert, deploy with Vortex the way you usually do.

`bin/omw2mwse scan path/to/mod` reports a verdict without converting anything,
and is a reasonable first look.

## 4. Logs (not a crash)

This library does not spam MWSE.log. After load, MWSE.log should only show
initialization lines:

- `[omwcompat 0.4.4] loaded`
- `[omwcompat 0.4.4] library log: Data Files/MWSE/logs/omwcompat.log`
- `[omwcompat 0.4.4] registered <Mod> (N script(s)).` once per converted mod
  (a short support notice may follow on the same line)

If the library log cannot be opened, one MWSE.log line says
`could not open Data Files/MWSE/logs/omwcompat.log (...); further messages go
to MWSE.log` and further messages stay on MWSE.log. A missing-runtime error
from `main.lua` (`omwcompat runtime is missing or failed to load`) also stays
on MWSE.log, because the library never loaded.

Everything else -- warnings, errors with tracebacks, stub and sound-gate
notices, debug, converted mods' `print()`, and a BUILT_FOR mismatch from an
omw2mwse 0.3.2 conversion (via `omwcompat.note`) -- goes to
`Data Files/MWSE/logs/omwcompat.log`. The previous session is kept as
`omwcompat.log.prev`. Lines are timestamped and flushed. A conversion older
than 0.3.2 still writes its BUILT_FOR line to MWSE.log until you re-convert.

These library-log lines can show up once and then go quiet. That is expected:

- `[omwcompat 0.4.4] SomeMod was built for omwcompat 0.4.0 (loaded 0.4.4)` -
  the deployed runtime is a different version than the one bundled at convert
  time. Newer runtimes still run older conversions.
- `... does nothing: animations are not ported by omwcompat ...` - animations
  are stubs. One warning per mod; they will not play.
- `self.controls.<name> cannot be set: movement controls are not emulated ...` -
  a write was ignored, one warning per field. The script should keep running.
- `[omwcompat] sound gate: kept ... from playing ...` - an off or removed light
  was kept silent, once per kind.

These are real problems:

- `omwcompat runtime is missing or failed to load` (on MWSE.log)
- `ERROR in ...` with a traceback (in the library log)
- a line saying something `is not supported` that is not one of the one-shot
  warnings above

If you see a real error, do not "just try another convert into Data Files".
Read the [README](README.md#reading-the-logs).

## 5. How to undo

- In game: **MW Conversions** -> the mod's tab -> turn **Mod enabled** off.
  That stops the conversion from the next frame, with no reload. It does **not**
  undo objects, equipment or other world changes the mod already made.
- The untouched original package is in the staged folder at
  `Off/<plugin>/OpenMW/`.
- If tidy ran the convert, use tidy's `--undo`.
- `omw2mwse recover path/to/staged-mod --rollback` only undoes a convert that
  was **interrupted**. It is not a revert for a finished run.

## 6. If it breaks

Read the [README](README.md). Really. The troubleshooting section, the list of
what is only stubbed, and the notes on the logs are there for this moment.

Report conversion problems to **dej (dejunai)** on the Nexus Mods forums. Do
not send them to the original mod author.
