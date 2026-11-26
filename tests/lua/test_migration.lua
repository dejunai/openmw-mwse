-- Save made with Dej's hand port at noon -> load with the omwcompat build + migration.
local TESTS = os.getenv("TESTS_DIR")
package.path = "Data Files/MWSE/lib/?.lua;" .. TESTS .. "/?.lua;" .. package.path
local mock = require("mock_mwse").install({})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end
mock.addLight({ id = "light_de_lantern_01", mesh = "l\\light_de_lantern_01.nif", canCarry = true })
mock.addLight({ id = "torch_tall_01", mesh = "l\\light_torch_tall.nif" })
local ext = mock.addCell({ id = "Balmora" })
W.activeCell = ext
mock.placeRef(ext, "light_de_lantern_01", { 1, 0, 0 })
mock.placeRef(ext, "torch_tall_01", { 2, 0, 0 })
mock.newPlayer(ext)
W.config = { leavethelightsoff = { dayStart = 7, enabled = true, log = false, dayEnd = 18, darkWeather = true } }
-- session 1: hand port
dofile(TESTS .. "/../../reference/mwse_dej/main.lua")
mock.fire("initialized", {})
mock.setHour(12); mock.fire("loaded", { newGame = true }); mock.frames(200)
local copies1 = 0
for _, r in ipairs(mock.refsIn(ext, false)) do if r.object.isOffByDefault then copies1 = copies1 + 1 end end
check(copies1 == 2 and tes3.player.data.leavethelightsoff ~= nil, "hand port put out 2 lights and stored state")
local snap = mock.save()
-- session 2: new install (fresh handlers), same save
W.handlers, W.timers = {}, {}
for k in pairs(package.loaded) do if k:find("^omwcompat") then package.loaded[k] = nil end end
dofile("Data Files/MWSE/mods/LeaveTheLightsOff/main.lua")
dofile(TESTS .. "/../../migrations/ltlo-handport/MWSE/mods/LTLOHandportMigration/main.lua")
mock.fire("initialized", {})
mock.load(snap)
mock.frames(300)
local offs, handCopies, lit, hidden = 0, 0, 0, 0
for _, r in ipairs(mock.refsIn(ext, true)) do
    if r.object.id:find("^Generated:") then if not r.disabled then offs = offs + 1 end
    elseif r.object.isOffByDefault then handCopies = handCopies + 1
    elseif r.disabled then hidden = hidden + 1 else lit = lit + 1 end
end
check(handCopies == 0, "hand-port copies removed")
check(offs == 2 and hidden == 2, "omwcompat LTLO now owns both lights (2 off copies, 2 tombstoned originals)")
check(tes3.player.data.leavethelightsoff == nil, "hand-port save data released")
mock.setHour(22); mock.frames(300)
lit = 0
for _, r in ipairs(mock.refsIn(ext, false)) do if not r.object.isOffByDefault then lit = lit + 1 end end
check(lit == 2, "night: both originals lit again (got " .. lit .. ")")
local errs = 0
for _, l in ipairs(W.logs) do if l:find("ERROR") then errs = errs + 1; print("    " .. l) end end
check(errs == 0, "no runtime errors")
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
