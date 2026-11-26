# Leave The Lights Off — original package (3.2, no gaps)

This document is kept under its original filename so earlier links still work.
The reconstruction gaps it listed for 0.2.1 are closed.

Dej's official Nexus download, used from 0.2.2 on, is Leave The Lights Off **3.2**,
not the 3.1 FOMOD described in earlier revisions of this file.

- Archive: `LeaveTheLightsOff 57510 3.2 2026-11-12T17-31Z nOlkOzk1.zip`
- 1,888,504 bytes, MD5 `db79bdaeeed14c3a5f7b07e2e7819543`, SHA-256 starts `833c66da6fbd45dc`
- The previously expected 3.1 FOMOD (file id 1000066569, 1,700,345 bytes, MD5
  `cedf5cc1df03dad18fca6a984dee346e`) was not in the downloads folder. The 3.2
  zip is a loose `LeaveTheLightsOff/` folder, not a FOMOD, so there is no
  installer and no options to choose. The complete package is converted.

Provenance of the box copy is in `corpus/leave-the-lights-off/_SOURCE.txt`
(untracked, with the archive). The original file in
`K:\Downloads\Vortex\morrowind` was not modified or moved.

## Complete official 3.2 package

Everything from the zip is preserved byte-exact under
`Off/LeaveTheLightsOff/OpenMW/`:

- `LeaveTheLightsOff.omwscripts` (same bytes as the 3.1 reference, SHA-256
  starts `13ff1b026bc26b96`)
- `scripts/LeaveTheLightsOff/LTLO_g.lua` (3.2, 25,058 bytes, SHA-256 starts
  `6db3d7a7335ee451`; this is not the 3.1 reference `7bab5f54c2ee7b6d`)
- `scripts/LeaveTheLightsOff/ui_debugWidget.lua` (7,350 bytes, SHA-256 starts
  `33ca2b9291f1d7b6`). Present in 3.2; this was the main text-file gap in the
  0.2.1 reconstruction. It is not declared in `.omwscripts` and is not required
  for the conversion to run.
- `scripts/MaxYari/animated_lanterns/configs/lantern_off99_compat.yaml` (same
  bytes as the earlier copy, SHA-256 starts `101c9ae7f98f71f9`)
- `meshes/`, including vanilla-path off99 files, official `dlr/` and `rr/`
  off99 meshes, `delantpaper*`, and `uvi_crystal_bulb_*`
- `textures/`, the `tx_ashl_lantern_*_off99.dds` and
  `tx_misc_lantern_paper_*_off99.dds` files (none of these were in the 0.2.1
  reconstruction)

The 0.2.1 reconstruction left `dlr/` and `rr/` off99 meshes out of `Off/` and
out of the Data Files `meshes/` root, on the belief they belonged to Darknut /
RR replacers rather than OwnlyMe's zip. They ship in the official 3.2 archive,
so 0.2.2 includes them both under `Off/` and at `meshes/dlr/` and `meshes/rr/`.
Paths over 31 characters still get short aliases at `meshes/omwc/ltlo/<hash>.nif`.

There is no FOMOD (`fomod/ModuleConfig.xml`), and no separate official readme,
changelog, or permissions text in the 3.2 zip. Those were listed as 3.1 FOMOD
gaps; they are simply not part of this 3.2 package. License notices still say
to see the Nexus Mods permissions of the original (mod 57510).

The conversion loads hosted Lua from
`MWSE/mods/mwsuite/openmw/LeaveTheLightsOff/omw/`, not from `Off/`.

## What changed in the 3.2 script versus the 3.1 reference

- Mesh-size tables: a `dlr_legacy` entry, more `dlr_glow` mappings, and
  smoothed Ashlander lanterns now point at `meshes/dlr/light_ashl_lantern_*s_off99.nif`.
- The unused `dlrInstalled` flag was removed.
- Blacklist keys are record ids, not mesh paths (the hardcoded
  `chargen_lantern_03_sway` entry is unchanged).
- Invalid lights are also dropped when `light.enabled` is false.

## Retired 3.1 reconstruction

The gaps listed through 0.2.1 (missing FOMOD, readme, `ui_debugWidget.lua`,
textures, and uncertainty about official meshes) applied only to the
reconstructed 3.1 tree. They do not apply to this official 3.2 archive.
