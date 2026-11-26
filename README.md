# openmw-mwse

Run OpenMW-only Lua mods on the original Morrowind engine with MWSE.

A personal project by **dej (dejunai)**, built with Grok Bot.

It has two parts (see [DESIGN.md](DESIGN.md) for the reasoning):

- **omwcompat** (`runtime/MWSE/lib/`) is an MWSE Lua library. It provides the `openmw.*` API
  (`world`, `types`, `core` + weather, `util`, `async`, `storage`, `vfs`, `interfaces`
  with Activation, plus `openmw_aux.calendar/util/time`). It hosts the mod's unmodified
  GLOBAL scripts with OpenMW's engine handlers and save/load semantics.
- **omw2mwse** (`tools/omw2mwse`, Python 3.13+, stdlib only) is the CLI.
  - `scan` reports which OpenMW APIs a mod uses and whether omwcompat supports each one.
  - `package` builds an MWSE mod folder. The complete original OpenMW package is always
    placed at `Off/<Mod>/OpenMW/<original paths>`. Hosted Lua is copied byte-for-byte
    (unless hard-code conversion rewrites it). A generated `main.lua` loader is added,
    and mesh paths over 31 characters get short aliases.

The first target is **Leave The Lights Off** by OwnlyMe (Nexus 57510). Its original
`LTLO_g.lua` runs unmodified on MWSE through omwcompat.

## Quick start

```sh
bin/omw2mwse scan path/to/openmw-mod
bin/omw2mwse package path/to/openmw-mod --name ModName --out staging/ModName
tests/run_lua_tests.sh                       # LuaJIT + MWSE mock scenarios
python3 -m unittest discover -s tests/py     # CLI unit tests
```

The output of `package` mirrors `Data Files`:

```
Data Files/Off/<Mod>/OpenMW/...              complete original OpenMW package (author paths)
Data Files/MWSE/mods/mwsuite/openmw/<Mod>/main.lua   generated loader (register with omwcompat)
Data Files/MWSE/mods/mwsuite/openmw/<Mod>/omw/...    hosted .omwscripts + Lua
Data Files/MWSE/lib/omwcompat.lua, omwcompat/ the runtime (unless --no-runtime)
Data Files/meshes/, textures/, ...           original game assets (also under Off/)
Data Files/meshes/omwc/<slug>/<hash>.nif     short aliases for long mesh paths
Data Files/<Mod>-metadata.toml               MWSE metadata
MESH-ALIASES.txt                             long mesh path -> short alias
OMW2MWSE-REPORT.md                           scan + file list with hashes
```

## Status

The project is an MVP. GLOBAL scripts and object-attached scripts (NPC, CREATURE, ACTOR,
CONTAINER, DOOR, LIGHT, ACTIVATOR) are hosted. Player, custom, menu and UI scripts are reported
by `scan` as blockers. Docs:
- [docs/RUNTIME.md](docs/RUNTIME.md) covers how the emulation works and the four object-lifecycle rules.
- [docs/COVERAGE.md](docs/COVERAGE.md) covers the test corpus.
- [docs/GAPS.md](docs/GAPS.md) lists the known differences.
- [docs/INSTALL-PLAN.md](docs/INSTALL-PLAN.md) has the LTLO install steps.

The `reference/`, `corpus/` and `staging/` folders are local only and git-ignored. Third-party mods
are personal test material and are not redistributed here.

## 0.2: settings, MCMs, hard-coded values, tidy entry point

- OpenMW settings (`I.Settings`, `openmw.storage`) become an MWSE MCM named
  one shared "MW Conversions" entry (tab 1 disclaimer, one tab per converted mod). See docs/RUNTIME.md.
- `omw2mwse convert <staged-mod-dir> --mode normal|hardcode --json` (or
  `--convert-omwscripts[=MODE]`) converts in place and is idempotent. See
  docs/TIDY-INTEGRATION.md.
- Hard-coded values are exposed through a sidecar (`sidecars/LeaveTheLightsOff.omw2mwse.toml`),
  after a developer-only warning.
- Every build is marked as an unofficial mwsuite conversion: report issues to
  mwsuite / dej (dejunai), not to the original author.

## License

MIT, Copyright (c) 2026 dej (dejunai). See [LICENSE](LICENSE). The mods hosted by
omwcompat keep their own authors' licenses.
