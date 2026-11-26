# Leave The Lights Off 3.1 — original package reconstruction gaps

The official Nexus 3.1 archive (file id 1000066569, logical name "(OpenMW) Leave
The Lights Off") is a FOMOD installer, 1,700,345 bytes, MD5
`cedf5cc1df03dad18fca6a984dee346e`. A local copy of that zip was not found on
the machine at packaging time, so this conversion reconstructs the original
OpenMW package under `Off/LeaveTheLightsOff/OpenMW/` from surviving pieces.

## Included (reconstructed)

- `LeaveTheLightsOff.omwscripts` and `scripts/LeaveTheLightsOff/LTLO_g.lua` from
  the byte-exact reference (SHA-256 of `LTLO_g.lua` starts `7bab5f54c2ee7b6d`).
- `scripts/MaxYari/animated_lanterns/configs/lantern_off99_compat.yaml` (hash
  starts `101c9ae7f98f71f9`), placed at the path it had in the earlier install.
- Vanilla-path off99 meshes recovered from the hand-port backup
  (`G:\projects\backups\LeaveTheLightsOff-handport-2026-11-25\Data Files\meshes`),
  including root `light_*_off99.nif` and extras such as `delantpaper*` and
  `uvi_crystal_bulb_*`. These are installed both under
  `Off/LeaveTheLightsOff/OpenMW/meshes/` and at the Data Files `meshes/` root.

Long `dlr/` and `rr/` off99 meshes from the same backup are used only as sources
for the short `meshes/omwc/ltlo/*.nif` aliases. They are probably Darknut / RR
replacer files, not part of OwnlyMe's 3.1 zip, so they are not placed under
`Off/` or at `meshes/dlr/` / `meshes/rr/` in this archive (to avoid clashing
with those mods). If those replacers are installed, their long paths still
exist in Data Files; the conversion uses the aliases for the 31-character
record-path limit.

## Missing versus the official 3.1 FOMOD (not found locally)

- The FOMOD installer itself (`fomod/ModuleConfig.xml`, info, screenshots).
- Any official readme, changelog, or permissions text that shipped in the zip.
- `scripts/LeaveTheLightsOff/ui_debugWidget.lua` (7350 bytes, SHA-256 starts
  `33ca2b9291f1d7b6`). It was present in the earlier Vortex staging install but
  is not declared in `.omwscripts` and is not required for the conversion to
  run. No surviving copy was found after the staging folder was removed.
- Textures, if the 3.1 zip contained any (none were in the backup or the box
  reference).
- Anything else that was only in the Nexus zip and never copied into the
  reference trees or the hand-port backup.

The conversion loads hosted Lua from `MWSE/mods/mwsuite/openmw/LeaveTheLightsOff/omw/`, not from
`Off/`. The gaps above do not stop Leave The Lights Off from running on MWSE
through omwcompat. License of the original is still unknown; notices say to see
the Nexus Mods permissions of the original (mod 57510).
