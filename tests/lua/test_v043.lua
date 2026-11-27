-- omwcompat 0.4.3: writing self.controls (yawChange, movement, ...) warns once and is
-- ignored, instead of raising. Before 0.4.3 Thieves Pickpocket's tpickpocket_local.lua
-- stopTracking always did self.controls.yawChange = 0, which aborted onInactive
-- (MWSE.log 2026-11-27 04:00:03) so finishApology / setAI never ran. Run from
-- staging/LeaveTheLightsOff via tests/run_lua_tests.sh. Written for omwcompat by dej (dejunai).
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local mock = require("mock_mwse").install({})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end
local function section(s) print("\n== " .. s) end

local SYN = (os.getenv("TMPDIR_SYNTH") or "/tmp/omwcompat-synth") .. "-v043/"
os.execute("mkdir -p '" .. SYN .. "scripts'")
local function write(rel, text)
    local f = assert(io.open(SYN .. rel, "w")); f:write(text); f:close()
end

-- the stopTracking / onInactive pattern of tpickpocket_local.lua: yawChange is always
-- written, even when tracking was never started; more work must still run after it.
write("scripts/npc.lua", [[
local self = require('openmw.self')
local finished, left = 0, 0
local function stopTracking()
  self.controls.yawChange = 0
end
return {
  engineHandlers = {
    onActive = function()
      self.controls.yawChange = 0.2
      self.controls.yawChange = 0
      self.controls.movement = 0
      print('REC active', tostring(self.controls.sneak), tostring(self.controls.yawChange))
    end,
    onInactive = function()
      stopTracking()
      finished = finished + 1
      print('REC inactive', finished)
    end,
  },
  eventHandlers = {
    Face = function()
      self.controls.yawChange = 0.1
      left = left + 1
      print('REC face', left)
    end,
  },
}
]])

mock.addObject({ id = "thief", objectType = tes3.objectType.npc, aiConfig = { fight = 0 }, health = 30, inventory = {} })
local rt = require("omwcompat")
rt.register({ mod = "YawTest", root = SYN, scripts = { { flags = { "NPC" }, path = "scripts/npc.lua" } } })
mock.fire("initialized", {})
local ext = mock.addCell({ id = "Seyda Neen", gridX = -2, gridY = -9 })
W.activeCell = ext
local npc = mock.placeRef(ext, "thief", { 100, 0, 0 })
local player = mock.newPlayer(ext)
mock.addMobile(npc, { hp = 30 })
mock.addMobile(player, { hp = 100 })

local function recs(tag)
    local out = {}
    for _, l in ipairs(mock.allLogs()) do
        local rest = l:match("^%[YawTest%] REC " .. tag .. "\t?(.*)$")
        if rest then out[#out + 1] = rest end
    end
    return out
end
local function last(tag) local r = recs(tag); return r[#r] end
local function logsWith(s)
    local n = 0
    for _, l in ipairs(mock.allLogs()) do if l:find(s, 1, true) then n = n + 1 end end
    return n
end

section("writes no longer raise")
mock.fire("loaded", { newGame = true })
mock.frames(3, 0.1)
check(last("active") == "false\tnil", "onActive finished after the writes; sneak is readable, yawChange reads nil (got " .. tostring(last("active")) .. ")")
check(logsWith("cannot be set (controls are read-only") == 0, "the 0.4.0 raise is gone")
check(logsWith("self.controls.yawChange cannot be set") == 1, "one warning for yawChange")
check(logsWith("self.controls.movement cannot be set") == 1, "one warning for movement")
check(logsWith("ERROR") == 0, "no runtime errors after the first writes")

section("further writes are silent; onInactive still finishes")
local w = rt.objects.wrap(npc)
for _ = 1, 50 do w:sendEvent("Face", {}) end
mock.frames(2, 0.1)
check(#recs("face") == 50, "50 yawChange writes from events all completed (got " .. #recs("face") .. ")")
check(logsWith("self.controls.yawChange cannot be set") == 1, "still one yawChange warning after 50 more writes")
mock.fire("referenceDeactivated", { reference = npc })
mock.frames(2, 0.1)
check(last("inactive") == "1", "onInactive ran stopTracking and the work after it")
check(logsWith("ERROR") == 0, "no error on deactivate")

section("Thieves Pickpocket tpickpocket_local.lua (corpus), when present")
local TROOT = os.getenv("TESTS_DIR") .. "/../../corpus/thieves-pickpocket/_archive/full/"
local f = io.open(TROOT .. "scripts/tpickpocket_local.lua", "r")
if not f then
    print("  corpus/thieves-pickpocket missing; skipped")
else
    f:close()
    package.loaded["omwcompat"] = nil
    for k in pairs(package.loaded) do if k:find("^omwcompat") then package.loaded[k] = nil end end
    local mock2 = require("mock_mwse").install({})
    local W2 = mock2.W
    mock2.addObject({ id = "tp_thief", objectType = tes3.objectType.npc, aiConfig = { fight = 0 }, health = 30, inventory = {},
        disposition = 30, baseDisposition = 30 })
    local rt2 = require("omwcompat")
    rt2.register({ mod = "ThievesPickpocket", root = TROOT, probeSettings = true, scripts = {
        { flags = { "GLOBAL" }, path = "scripts/tpickpocket_global.lua" },
        { flags = { "CUSTOM" }, path = "scripts/tpickpocket_local.lua" },
        { flags = { "PLAYER" }, path = "scripts/tpickpocket_player.lua" },
        { flags = { "MENU" }, path = "scripts/tpickpocket_settings.lua" },
    } })
    mock2.fire("initialized", {})
    local cell = mock2.addCell({ id = "Seyda Neen", gridX = -2, gridY = -9 })
    W2.activeCell = cell
    local ref = mock2.placeRef(cell, "tp_thief", { 100, 0, 0 })
    local pl = mock2.newPlayer(cell)
    mock2.addMobile(ref, { hp = 30 })
    mock2.addMobile(pl, { hp = 100 })
    mock2.fire("loaded", { newGame = true })
    mock2.frames(3, 0.1)
    rt2.objects.wrap(ref):addScript("scripts/tpickpocket_local.lua")
    mock2.frames(20, 0.1)
    mock2.fire("referenceDeactivated", { reference = ref })
    mock2.frames(5, 0.1)
    local errs, yawWarn, animWarn = {}, 0, 0
    for _, l in ipairs(mock2.allLogs()) do
        if l:find("ERROR", 1, true) then errs[#errs + 1] = l end
        if l:find("self.controls.yawChange cannot be set", 1, true) then yawWarn = yawWarn + 1 end
        if l:find("animations are not ported", 1, true) then animWarn = animWarn + 1 end
    end
    check(#errs == 0, "tpickpocket_local.lua onInactive no longer errors (" .. tostring(errs[1]) .. ")")
    check(yawWarn == 1, "one yawChange warning when the NPC is deactivated")
    check(animWarn == 1, "the 0.4.2 animation warning still fires once")
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
