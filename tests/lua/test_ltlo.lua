-- Scenario tests: the ORIGINAL LTLO_g.lua hosted by omwcompat inside the MWSE mock.
-- Run from the packaged output folder (cwd = staging/LeaveTheLightsOff) via tests/run_lua_tests.sh.
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local mock = require("mock_mwse").install({ files = {
    ["meshes\\omwc\\ltlo\\72d5ca40.nif"] = true, -- alias for light_de_streetlight_01_off99.nif (exists)
    -- no alias file for light_paper_lantern_01_off99.nif: exercises the documented fallback
} })
local W = mock.W

local pass, fail = 0, 0
local function check(cond, msg)
    if cond then pass = pass + 1; print("  ok   " .. msg) else fail = fail + 1; print("  FAIL " .. msg) end
end
local function section(s) print("\n== " .. s) end

-- world -------------------------------------------------------------------
mock.addLight({ id = "light_de_lantern_01", mesh = "l\\light_de_lantern_01.nif", canCarry = true, name = "Lantern" })
mock.addLight({ id = "light_de_streetlight_01", mesh = "l\\light_de_streetlight_01.nif", canCarry = false })
mock.addLight({ id = "light_paper_lantern_01", mesh = "l\\light_paper_lantern_01.nif", canCarry = true })
mock.addLight({ id = "light_com_candle_01", mesh = "l\\light_com_candle_01.nif", canCarry = true }) -- not whitelisted
mock.addLight({ id = "chargen_lantern_03_sway", mesh = "l\\light_de_lantern_03.nif" })       -- blacklisted
local ext = mock.addCell({ id = "Balmora", gridX = -3, gridY = -2 })
local int = mock.addCell({ id = "Balmora, Guild of Mages", isInterior = true })
W.activeCell = ext
local lantern = mock.placeRef(ext, "light_de_lantern_01", { 100, 200, 300 }, { rotZ = 1.25, owner = "hlaalu" })
local street = mock.placeRef(ext, "light_de_streetlight_01", { 500, 0, 0 }, { scale = 1.5 })
local paper = mock.placeRef(ext, "light_paper_lantern_01", { 900, 0, 0 })
local candle = mock.placeRef(ext, "light_com_candle_01", { 50, 50, 0 })
local sway = mock.placeRef(ext, "chargen_lantern_03_sway", { 70, 70, 0 })
local inner = mock.placeRef(int, "light_de_lantern_01", { 0, 0, 0 })
local player = mock.newPlayer(ext)
local initialRefCount = #mock.refsIn(ext, true)

local function offCopies()
    local out = {}
    for _, r in ipairs(mock.refsIn(ext, false)) do
        if r.object.isOffByDefault then out[#out + 1] = r end
    end
    return out
end
local function copyAt(x)
    for _, r in ipairs(offCopies()) do if r.position.x == x then return r end end
end
local function isLit(r) return not r.disabled and not r._gone end

-- boot ---------------------------------------------------------------------
dofile("Data Files/MWSE/mods/LeaveTheLightsOff/main.lua")
mock.fire("initialized", {})
mock.setHour(12)
mock.fire("loaded", { newGame = true })

section("day: lights swapped to off copies (R1 + createRecord)")
mock.frames(240)
local function tombed(r) return require("omwcompat").objects.isTomb(r) end
check(lantern.disabled and tombed(lantern), "lantern original disabled + tombstoned")
check(street.disabled and paper.disabled, "streetlight and paper lantern originals disabled")
check(isLit(candle), "candle (not whitelisted) untouched")
check(isLit(sway), "blacklisted chargen_lantern_03_sway untouched")
check(isLit(inner), "interior lantern untouched")
check(#offCopies() == 3, "three off copies placed (got " .. #offCopies() .. ")")
local lc = copyAt(100)
check(lc and lc.object.id:find("^Generated:0x") ~= nil, "copy record id is Generated:0x..")
check(lc and lc.object.mesh == "light_de_lantern_01_off99.nif", "lantern copy uses off99 mesh (" .. tostring(lc and lc.object.mesh) .. ")")
check(lc and math.abs(lc.orientation.z - 1.25) < 1e-9, "rotation preserved")
local sc = copyAt(500)
check(sc and sc.object.mesh == "omwc\\ltlo\\72d5ca40.nif", "R4: streetlight copy uses short alias (" .. tostring(sc and sc.object.mesh) .. ")")
check(sc and sc.scale == 1.5, "scale preserved")
local pc = copyAt(900)
check(pc and pc.object.mesh == "l\\light_paper_lantern_01.nif", "R4 fallback: paper lantern keeps template mesh when alias missing")
local warned = false
for _, l in ipairs(W.logs) do if l:find("longer than 31 chars") then warned = true end end
check(warned, "R4 fallback logged a warning")
local maxMesh = 0
for _, o in ipairs(W.objectList) do if o.mesh and #o.mesh > maxMesh then maxMesh = #o.mesh end end
check(maxMesh <= 31, "no record mesh longer than 31 chars (max " .. maxMesh .. ")")

section("night: originals restored, no reference growth (R2)")
mock.setHour(22)
mock.frames(240)
check(isLit(lantern) and not tombed(lantern), "lantern original re-enabled, tombstone cleared")
local noItemData = true
for _, r in ipairs(ext._refs) do if r.sourceMod and rawget(r, "itemData") ~= nil then noItemData = false end end
check(noItemData, "no itemData created on content-file light refs")
check(isLit(street) and isLit(paper), "streetlight + paper lantern re-enabled")
check(#offCopies() == 0, "off copies deleted")
check(#mock.refsIn(ext, true) == initialRefCount, "cell reference count unchanged (" .. #mock.refsIn(ext, true) .. "/" .. initialRefCount .. ")")
local gen = 0
for _, o in ipairs(W.objectList) do if o.id:find("^Generated:") then gen = gen + 1 end end
check(gen == 3, "only 3 generated records (one per base light), got " .. gen)

section("day cycle again reuses generated records")
mock.setHour(13)
mock.frames(240)
gen = 0
for _, o in ipairs(W.objectList) do if o.id:find("^Generated:") then gen = gen + 1 end end
check(#offCopies() == 3 and gen == 3, "3 copies, still 3 generated records")

section("weather: ash storm at noon turns lights on; transition uses next weather")
mock.setWeather(6)
mock.frames(240)
check(isLit(lantern) and #offCopies() == 0, "ashstorm -> lights on")
mock.setWeather(0)
mock.frames(240)
check(#offCopies() == 3, "clear -> lights off again")
mock.setWeather(0, 7, 0.7) -- blight coming, transition factor 0.3 (< 0.5) -> next weather counts
mock.frames(240)
check(#offCopies() == 0, "clear->blight past halfway -> lights on")
mock.setWeather(0, 7, 0.2) -- factor 0.8 -> still current weather (clear)
mock.frames(240)
check(#offCopies() == 3, "clear->blight early -> lights stay off")
mock.setWeather(0)
mock.frames(60)

section("menu mode: dt == 0 does nothing")
mock.setHour(23)
W.menuMode = true
mock.frames(240)
check(#offCopies() == 3, "no swaps while paused")
W.menuMode = false
mock.setHour(12)
mock.frames(60)

section("save / load round trip")
local snap = mock.save()
check(type(player.data.omwcompat_LeaveTheLightsOff) == "string", "payload stored as one string in tes3.player.data")
local logsBefore = #W.logs
mock.load(snap)
check(tes3.player.data.omwcompat_LeaveTheLightsOff ~= nil, "mock kept the player data through load")

-- refs were rebuilt by the mock: rebind locals by position
local function refAt(cell, id, x)
    for _, r in ipairs(cell._refs) do if r.object.id == id and r.position.x == x and not r._gone then return r end end
end
lantern = refAt(ext, "light_de_lantern_01", 100); street = refAt(ext, "light_de_streetlight_01", 500)
paper = refAt(ext, "light_paper_lantern_01", 900)
player = tes3.player
mock.frames(240)
check(#offCopies() == 3, "after load: still exactly 3 off copies (no duplicates)")
check(lantern.disabled and tombed(lantern), "after load: original still tombstoned")
local regen = false
for i = logsBefore, #W.logs do if W.logs[i]:find("Regenerating") then regen = true end end
check(not regen, "after load: generated records not regenerated (model map persisted)")
gen = 0
for _, o in ipairs(W.objectList) do if o.id:find("^Generated:") then gen = gen + 1 end end
check(gen == 3, "after load: LTLO saveData restored via onLoad (still 3 generated records, got " .. gen .. ")")
mock.setHour(21)
mock.frames(240)
check(isLit(lantern) and isLit(street) and #offCopies() == 0, "after load: night restores the original refs")
check(#mock.refsIn(ext, true) == initialRefCount, "after load: reference count unchanged")
mock.setHour(12)
mock.frames(240)
gen = 0
for _, o in ipairs(W.objectList) do if o.id:find("^Generated:") then gen = gen + 1 end end
check(gen == 3 and #offCopies() == 3, "after load: next day reuses saved generated records")

section("pickup of an off lantern during the day (R3)")
local copy = copyAt(100)
check(copy ~= nil, "off copy present before pickup")
local invBefore = #tes3.getObject("player").inventory
local result = player:activate(copy)
check(result == false, "vanilla activation of the copy was blocked")
mock.frames(2)
local inv = tes3.getObject("player").inventory
local got = inv[#inv]
check(#inv == invBefore + 1 and got.object.id == "light_de_lantern_01", "player received the ORIGINAL light record (" .. tostring(got and got.object.id) .. ")")
check(#W.crimes == 1 and W.crimes[1] == "light_de_lantern_01", "ownership honoured: theft registered by vanilla pickup")
check(lantern._gone and copy._gone, "original picked up (removed) and copy deleted")
mock.frames(240)
check(copyAt(100) == nil, "no copy re-created at the picked-up spot")

section("activating a non-carriable off streetlight")
local scopy = copyAt(500)
invBefore = #inv
player:activate(scopy)
mock.frames(240)
check(#tes3.getObject("player").inventory == invBefore, "no item added")
check(copyAt(500) ~= nil and street.disabled, "streetlight is off again after the attempt")

section("errors")
local errs = 0
for _, l in ipairs(W.logs) do if l:find("ERROR") then errs = errs + 1; print("    " .. l:sub(1, 300)) end end
check(errs == 0, "no runtime errors logged")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
