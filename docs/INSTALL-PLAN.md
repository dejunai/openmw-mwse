# Install plan: Leave The Lights Off via omwcompat (next phase, NOT done yet)

Nothing in this plan has been run on Dej's PC. Every step below writes to the PC, so each one
needs Dej's go-ahead. The facts below were checked read-only on 2026-11-25 (America/Los_Angeles).

## Paths

| Name | Path |
|---|---|
| GAME | `G:\Program Files\Steam\steamapps\common\Morrowind` |
| DF | `GAME\Data Files` |
| VST (Vortex staging of the LTLO mod) | `G:\Vortex Mods\morrowind\LeaveTheLightsOff 57510 3.1 2026-07-03T19-04Z kg1zg4z7` |
| BK (backup) | `G:\projects\backups\LeaveTheLightsOff-handport-2026-11-25` |
| STAGE (box) | `/workspace/openmw-mwse/staging` (see `staging/SHA256SUMS.txt`) |

Current state, read-only check on 2026-11-25:
- Hand port: `DF\MWSE\mods\LeaveTheLightsOff\main.lua`, 19071 bytes, SHA-256 `8A11DC996091D62E...`,
  last modified 2026-11-25 16:25 PT.
  - This file is a **hardlink** to `VST\MWSE\mods\LeaveTheLightsOff\main.lua`, so the two paths
    are one file. The folder carries Vortex's `__folder_managed_by_vortex` marker.
  - It is newer than the copy in `reference/mwse_dej/` (18589 bytes), so the backup must take
    the file from the PC.
- Hand-port config: `DF\MWSE\config\leavethelightsoff.json` (94 bytes). It is not Vortex-managed.
- Original OpenMW files: `DF\Off\OpenMW\LeaveTheLightsOff\`.
  - `LTLO_g.lua` SHA-256 `7BAB5F54...` is identical to the packaged copy.
  - `LeaveTheLightsOff.omwscripts` SHA-256 `13FF1B02...` is identical too.
- The off99 meshes in `DF\meshes`, `DF\meshes\dlr` and `DF\meshes\rr` are Vortex hardlinks
  from VST. All 30 sources needed for the aliases exist.
- None of these exist yet: `DF\MWSE\lib\omwcompat*`, `DF\MWSE\omw`, `DF\meshes\omwc`.
- `G:\projects\backups` exists.

## Step 0: Before starting

- Quit Morrowind and Vortex.
- Pick the test save. It is a good idea to also copy it, for example `GAME\Saves\<name>.ess`,
  into BK\Saves\.

## Step 1: Back up the hand port (copy only, nothing deleted)

| From | To |
|---|---|
| `DF\MWSE\mods\LeaveTheLightsOff\main.lua` | `BK\Data Files\MWSE\mods\LeaveTheLightsOff\main.lua` |
| `DF\MWSE\mods\LeaveTheLightsOff\__folder_managed_by_vortex` | `BK\Data Files\MWSE\mods\LeaveTheLightsOff\__folder_managed_by_vortex` |
| `DF\MWSE\config\leavethelightsoff.json` | `BK\Data Files\MWSE\config\leavethelightsoff.json` |

Then write `BK\SHA256SUMS.txt` and verify that each hash matches its source. Also write
`BK\RESTORE.txt` with one line: "copy Data Files\ back over the game's Data Files and over
VST, then deploy in Vortex".

```powershell
$DF='G:\Program Files\Steam\steamapps\common\Morrowind\Data Files'
$BK='G:\projects\backups\LeaveTheLightsOff-handport-2026-11-25'
foreach ($rel in 'MWSE\mods\LeaveTheLightsOff\main.lua','MWSE\mods\LeaveTheLightsOff\__folder_managed_by_vortex','MWSE\config\leavethelightsoff.json') {
  New-Item -ItemType Directory -Force (Split-Path "$BK\Data Files\$rel") | Out-Null
  Copy-Item -LiteralPath "$DF\$rel" -Destination "$BK\Data Files\$rel"
  if ((Get-FileHash "$DF\$rel").Hash -ne (Get-FileHash "$BK\Data Files\$rel").Hash) { throw "hash mismatch $rel" }
}
Get-ChildItem -Recurse -File "$BK\Data Files" | Get-FileHash | ForEach-Object { "$($_.Hash)  $($_.Path.Substring($BK.Length+1))" } | Set-Content -Encoding ascii "$BK\SHA256SUMS.txt"
```

## Step 2: Get the files onto the PC

Use CopyFromBox to copy each file under `STAGE/LeaveTheLightsOff/Data Files/` and
`STAGE/LTLOHandportMigration/Data Files/` into a temporary folder on the PC. Use a folder the
tool is allowed to write to; `C:\Users\Dejunai\` worked for reads before. Then check every file
against `staging/SHA256SUMS.txt`.

Files (target paths are relative to the install root R, chosen in step 3):

| File | SHA-256 |
|---|---|
| `LeaveTheLightsOff-metadata.toml` | `5f1a0c6dc9587036...` |
| `MWSE\lib\omwcompat.lua` | `cf500549fd4022d9...` |
| `MWSE\lib\omwcompat\manifest.json` | `52a3206b415f57da...` |
| `MWSE\lib\omwcompat\objects.lua` | `74d6ba7c9057de51...` |
| `MWSE\lib\omwcompat\runtime.lua` | `781abe872774a73d...` |
| `MWSE\lib\omwcompat\serial.lua` | `dfa465a98d1f07bd...` |
| `MWSE\lib\omwcompat\util.lua` | `b05cb536a8aaa010...` |
| `MWSE\mods\LeaveTheLightsOff\main.lua` | `9eabacaaafc829e5...` |
| `MWSE\omw\LeaveTheLightsOff\LeaveTheLightsOff.omwscripts` | `13ff1b026bc26b96...` |
| `MWSE\omw\LeaveTheLightsOff\scripts\LeaveTheLightsOff\LTLO_g.lua` | `7bab5f54c2ee7b6d...` |
| `MWSE\mods\LTLOHandportMigration\main.lua` (migration helper) | `01db3ff9755b94e5...` |

`LTLO_g.lua` and the `.omwscripts` file can also be copied on the PC from
`DF\Off\OpenMW\LeaveTheLightsOff\`. They have the same bytes.

## Step 3: Replace the hand port

**Recommended: option A, through Vortex.** Vortex keeps owning the files, so a later deploy will
not put the hand port back.

1. Set R = VST. Copy the files from step 2 into VST. This overwrites
   `VST\MWSE\mods\LeaveTheLightsOff\main.lua`. The game-folder hardlink is the same file, so
   it changes too.
2. Create the 30 mesh aliases inside VST with the PowerShell block below. They are copies of
   meshes that are already installed.
3. Dej opens Vortex and clicks **Deploy Mods**. If Vortex reports "external changes" for
   main.lua, choose to keep the staging (new) version.

**Option B, without Vortex.**
1. Set R = DF and copy the same files into DF.
2. Delete `VST\MWSE\mods\LeaveTheLightsOff\main.lua` after the step 1 backup. Otherwise the next
   Vortex deploy restores the hand port over the loader.
3. Expect Vortex to flag the new files as external.

Mesh aliases (R4). These are paths relative to R. The game limits record mesh paths to 31
characters, and these off-meshes are longer.

| Source (already installed) | Alias to create (copy) |
|---|---|
| `meshes\dlr\light_ashl_lantern_01_off99.nif` | `meshes\omwc\ltlo\54e26c80.nif` |
| `meshes\dlr\light_ashl_lantern_02_off99.nif` | `meshes\omwc\ltlo\20d32515.nif` |
| `meshes\dlr\light_ashl_lantern_03_off99.nif` | `meshes\omwc\ltlo\5fed6f52.nif` |
| `meshes\dlr\light_ashl_lantern_04_off99.nif` | `meshes\omwc\ltlo\980290ab.nif` |
| `meshes\dlr\light_ashl_lantern_05_off99.nif` | `meshes\omwc\ltlo\51459ea7.nif` |
| `meshes\dlr\light_ashl_lantern_06_off99.nif` | `meshes\omwc\ltlo\f8215e11.nif` |
| `meshes\dlr\light_ashl_lantern_07_off99.nif` | `meshes\omwc\ltlo\f09297ee.nif` |
| `meshes\dlr\light_de_lantern_01_off99.nif` | `meshes\omwc\ltlo\4d16efc4.nif` |
| `meshes\dlr\light_de_lantern_02_off99.nif` | `meshes\omwc\ltlo\4e1569e1.nif` |
| `meshes\dlr\light_de_lantern_03_off99.nif` | `meshes\omwc\ltlo\b53232c7.nif` |
| `meshes\dlr\light_de_lantern_04_off99.nif` | `meshes\omwc\ltlo\991146c0.nif` |
| `meshes\dlr\light_de_lantern_05_off99.nif` | `meshes\omwc\ltlo\020dff01.nif` |
| `meshes\dlr\light_de_lantern_06_off99.nif` | `meshes\omwc\ltlo\3644523a.nif` |
| `meshes\dlr\light_de_lantern_07_off99.nif` | `meshes\omwc\ltlo\f9f47569.nif` |
| `meshes\dlr\light_de_lantern_08_off99.nif` | `meshes\omwc\ltlo\4412771c.nif` |
| `meshes\dlr\light_de_lantern_09_off99.nif` | `meshes\omwc\ltlo\5a3e5b4f.nif` |
| `meshes\dlr\light_de_lantern_10_off99.nif` | `meshes\omwc\ltlo\8ff23c22.nif` |
| `meshes\dlr\light_de_lantern_11_off99.nif` | `meshes\omwc\ltlo\0c4afea3.nif` |
| `meshes\dlr\light_de_lantern_12_off99.nif` | `meshes\omwc\ltlo\cf0d71f3.nif` |
| `meshes\dlr\light_de_lantern_13_off99.nif` | `meshes\omwc\ltlo\18f94279.nif` |
| `meshes\dlr\light_de_lantern_14_off99.nif` | `meshes\omwc\ltlo\466128a4.nif` |
| `meshes\dlr\light_de_streetlight_01_off99.nif` | `meshes\omwc\ltlo\40f71e12.nif` |
| `meshes\dlr\light_paper_lantern_01_off99.nif` | `meshes\omwc\ltlo\932c9e98.nif` |
| `meshes\dlr\light_paper_lantern_02_off99.nif` | `meshes\omwc\ltlo\a9357a33.nif` |
| `meshes\light_de_streetlight_01_off99.nif` | `meshes\omwc\ltlo\72d5ca40.nif` |
| `meshes\light_paper_lantern_01_off99.nif` | `meshes\omwc\ltlo\29e4d3e6.nif` |
| `meshes\light_paper_lantern_02_off99.nif` | `meshes\omwc\ltlo\855cc9c7.nif` |
| `meshes\light_paper_lantern_off_off99.nif` | `meshes\omwc\ltlo\bd7915cc.nif` |
| `meshes\rr\light_com_lantern_01_off99.nif` | `meshes\omwc\ltlo\0eed30eb.nif` |
| `meshes\rr\light_com_lantern_02_off99.nif` | `meshes\omwc\ltlo\5ec88d03.nif` |

```powershell
$R='<VST or DF>'; $DF='G:\Program Files\Steam\steamapps\common\Morrowind\Data Files'
$pairs = @(
    @('dlr\light_ashl_lantern_01_off99.nif', 'omwc\ltlo\54e26c80.nif'),
    @('dlr\light_ashl_lantern_02_off99.nif', 'omwc\ltlo\20d32515.nif'),
    @('dlr\light_ashl_lantern_03_off99.nif', 'omwc\ltlo\5fed6f52.nif'),
    @('dlr\light_ashl_lantern_04_off99.nif', 'omwc\ltlo\980290ab.nif'),
    @('dlr\light_ashl_lantern_05_off99.nif', 'omwc\ltlo\51459ea7.nif'),
    @('dlr\light_ashl_lantern_06_off99.nif', 'omwc\ltlo\f8215e11.nif'),
    @('dlr\light_ashl_lantern_07_off99.nif', 'omwc\ltlo\f09297ee.nif'),
    @('dlr\light_de_lantern_01_off99.nif', 'omwc\ltlo\4d16efc4.nif'),
    @('dlr\light_de_lantern_02_off99.nif', 'omwc\ltlo\4e1569e1.nif'),
    @('dlr\light_de_lantern_03_off99.nif', 'omwc\ltlo\b53232c7.nif'),
    @('dlr\light_de_lantern_04_off99.nif', 'omwc\ltlo\991146c0.nif'),
    @('dlr\light_de_lantern_05_off99.nif', 'omwc\ltlo\020dff01.nif'),
    @('dlr\light_de_lantern_06_off99.nif', 'omwc\ltlo\3644523a.nif'),
    @('dlr\light_de_lantern_07_off99.nif', 'omwc\ltlo\f9f47569.nif'),
    @('dlr\light_de_lantern_08_off99.nif', 'omwc\ltlo\4412771c.nif'),
    @('dlr\light_de_lantern_09_off99.nif', 'omwc\ltlo\5a3e5b4f.nif'),
    @('dlr\light_de_lantern_10_off99.nif', 'omwc\ltlo\8ff23c22.nif'),
    @('dlr\light_de_lantern_11_off99.nif', 'omwc\ltlo\0c4afea3.nif'),
    @('dlr\light_de_lantern_12_off99.nif', 'omwc\ltlo\cf0d71f3.nif'),
    @('dlr\light_de_lantern_13_off99.nif', 'omwc\ltlo\18f94279.nif'),
    @('dlr\light_de_lantern_14_off99.nif', 'omwc\ltlo\466128a4.nif'),
    @('dlr\light_de_streetlight_01_off99.nif', 'omwc\ltlo\40f71e12.nif'),
    @('dlr\light_paper_lantern_01_off99.nif', 'omwc\ltlo\932c9e98.nif'),
    @('dlr\light_paper_lantern_02_off99.nif', 'omwc\ltlo\a9357a33.nif'),
    @('light_de_streetlight_01_off99.nif', 'omwc\ltlo\72d5ca40.nif'),
    @('light_paper_lantern_01_off99.nif', 'omwc\ltlo\29e4d3e6.nif'),
    @('light_paper_lantern_02_off99.nif', 'omwc\ltlo\855cc9c7.nif'),
    @('light_paper_lantern_off_off99.nif', 'omwc\ltlo\bd7915cc.nif'),
    @('rr\light_com_lantern_01_off99.nif', 'omwc\ltlo\0eed30eb.nif'),
    @('rr\light_com_lantern_02_off99.nif', 'omwc\ltlo\5ec88d03.nif')
)
foreach ($p in $pairs) {
  $src = "$DF\meshes\$($p[0])"; $dst = "$R\meshes\$($p[1])"
  New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
  Copy-Item -LiteralPath $src -Destination $dst
}
```

The DLR (`meshes\dlr\`) and RR (`meshes\rr\`) aliases are only used when LTLO detects those
replacers by file size. Copying all 30 is harmless.

Other notes:
- **Config:** `DF\MWSE\config\leavethelightsoff.json` is only read by the hand port. It is backed
  up in step 1 and can stay where it is (it is inert) or be deleted. Dej decides.
- **Migration helper** (`MWSE\mods\LTLOHandportMigration\main.lua`): install it if any save
  was played with the hand port. Once a save has been loaded and played, it can be removed.

## Step 4: In-game test checklist

1. Start the game, then open `GAME\MWSE.log`.
   - Expect `[omwcompat 0.1.0] registered LeaveTheLightsOff (1 script(s))`.
   - There must be no `[omwcompat] ERROR` lines.
2. Load a save in Balmora around 12:00 in clear weather. Within a few seconds, lanterns,
   streetlights and paper lanterns outdoors go unlit: off meshes and no light.
3. Open the console and click a dark lantern. Its id should be `Generated:0x...`. Wait (T) until
   19:00. The lights come back, and clicking one shows the original id (for example
   `light_de_lantern_01`). There should be no doubled lanterns.
4. Wait until 07:00. The lights go out again. Interior lights are never touched.
5. Weather: run `ChangeWeather "West Gash Region" 6` (ash storm) while in that region at noon.
   The lights come on once the transition is past halfway. Clear weather puts them out again.
6. Save during the day and reload. The lights are still off, there are no duplicates, and
   MWSE.log has no `Regenerating`. Save at night and reload: the lights are lit.
7. Pickup:
   - By day, take an unlit carriable lantern that is *unowned*. You should get the normal
     lantern, which lights when equipped.
   - Take one in a shop or owned house while seen. It should count as theft (red hand or
     bounty), as in vanilla.
8. Travel by silt strider or fast travel to another town by day. Lights there go out as the cells
   load.
9. Old hand-port save: the log shows `[LTLOHandportMigration] migrated N reference(s)` and then
   `hand-port state fully released` once all hidden originals are back. There should be no
   leftover hand-port copies (ids from `createCopy`, not `Generated:`).
10. Performance: there should be no stutter at dusk or dawn. LTLO swaps one light per frame.
11. If anything fails, send `MWSE.log` and the save.

## Rollback

1. Delete everything listed in step 2 and the `meshes\omwc\ltlo\` folder from R.
2. Copy `BK\Data Files\...` back to DF, and to VST under option A, then deploy.
3. In a save played with omwcompat, originals that were put out in cells you visited stay
   disabled until LTLO restores them at night. Roll back from a save made at night, or from the
   save backed up in step 0.
