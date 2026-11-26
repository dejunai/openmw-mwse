# Developer notes

How to run the converter by hand, the tests, and what a build contains. End-user
information is in the [README](../README.md).

Requirements: Python 3.13+ (stdlib only) for `omw2mwse`, LuaJIT for the runtime tests.

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

## Further reading

- [RUNTIME.md](RUNTIME.md): how the emulation works, local scripts, object-lifecycle rules.
- [GAPS.md](GAPS.md): known differences from OpenMW.
- [COVERAGE.md](COVERAGE.md): the test corpus.
- [TIDY-INTEGRATION.md](TIDY-INTEGRATION.md): the `convert` contract used by conflict-tools' tidy.
- [../DESIGN.md](../DESIGN.md): architecture and reasoning.

The `reference/`, `corpus/` and `staging/` folders are local only and git-ignored. Third-party
mods are personal test material and are not redistributed here.
