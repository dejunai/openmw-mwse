-- omwcompat 0.4.2: animations degrade quietly. openmw.animation and I.AnimationController
-- exist, every call is a no-op that answers "not playing", the first call of each mod is
-- logged once and later ones are counted. Before 0.4.2 require('openmw.animation') raised,
-- so a script that requires it (Thieves Pickpocket's tpickpocket_local.lua, MWSE.log
-- 2026-11-26 22:20:13) never started. Also types.NPC.getDisposition / getBaseDisposition,
-- the next call that script makes. Run from staging/LeaveTheLightsOff via
-- tests/run_lua_tests.sh. Written for omwcompat by dej (dejunai).
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local mock = require("mock_mwse").install({})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end
local function section(s) print("\n== " .. s) end

local SYN = (os.getenv("TMPDIR_SYNTH") or "/tmp/omwcompat-synth") .. "-v042/"
os.execute("mkdir -p '" .. SYN .. "scripts'")
local function write(rel, text)
    local f = assert(io.open(SYN .. rel, "w")); f:write(text); f:close()
end

-- an NPC script in the shape of Thieves Pickpocket's apology: a text-key handler added at
-- load, a scripted animation played from an event, a timer as the fallback when the key
-- never arrives, and every query of openmw.animation reported back.
write("scripts/gesture.lua", [[
local self = require('openmw.self')
local types = require('openmw.types')
local async = require('openmw.async')
local anim = require('openmw.animation')
local I = require('openmw.interfaces')
local keyFired, fallback = 0, 0
I.AnimationController.addTextKeyHandler('xgive', function(_, key) if key == 'stop' then keyFired = keyFired + 1 end end)
I.AnimationController.addPlayBlendedAnimationHandler(function() end)
I.AnimationController.addAnimationEndedHandler(function() end)
local function q(v) return tostring(v) end
print('REC chunk', self.recordId, I.AnimationController.version)
return {
  engineHandlers = {
    onActive = function()
      print('REC consts', anim.PRIORITY.Scripted, anim.PRIORITY.Default, anim.BLEND_MASK.All, anim.BLEND_MASK.UpperBody, anim.BONE_GROUP.RightArm)
      print('REC bools', q(anim.hasAnimation(self)), q(anim.isPlaying(self, 'idle')), q(anim.isLoopingAnimation(self, 'idle')),
        q(anim.hasGroup(self, 'xgive')), q(anim.hasBone(self, 'Bip01 Head')))
      print('REC nils', q(anim.getCurrentTime(self, 'idle')), q(anim.getCompletion(self, 'idle')), q(anim.getLoopCount(self, 'idle')),
        q(anim.getSpeed(self, 'idle')), q(anim.getActiveGroup(self, anim.BONE_GROUP.LowerBody)), q(anim.getTextKeyTime(self, 'xgive: start')))
      anim.skipAnimationThisFrame(self); anim.cancel(self, 'idle'); anim.setLoopingEnabled(self, 'idle', false)
      anim.setSpeed(self, 'idle', 2); anim.clearAnimationQueue(self, true)
      anim.playQueued(self, 'idle2', { loops = 1 }); anim.addVfx(self, 'meshes/e/magic_cast.nif', { loop = false })
      anim.removeVfx(self, 'x'); anim.removeAllVfx(self)
      anim.someFutureCall(self)
      print('REC active', 'done')
    end,
  },
  eventHandlers = {
    Apologize = function()
      I.AnimationController.playBlendedAnimation('xgive', { startKey = 'start', stopKey = 'stop', priority = anim.PRIORITY.Scripted })
      anim.playBlended(self, 'xgive', { priority = anim.PRIORITY.Scripted })
      async:newUnsavableSimulationTimer(0.5, function() fallback = fallback + 1; print('REC fallback', fallback, keyFired) end)
    end,
  },
}
]])
-- a second mod that only plays an animation: it gets its own single warning
write("scripts/other.lua", [[
local self = require('openmw.self')
local anim = require('openmw.animation')
return { engineHandlers = { onActive = function() anim.playBlended(self, 'idle3', {}) ; print('REC other', 'ran') end } }
]])
-- openmw.animation in a global script; I.AnimationController is an actor interface (nil elsewhere)
write("scripts/g.lua", [[
local anim = require('openmw.animation')
local I = require('openmw.interfaces')
print('REC global', anim.PRIORITY.Hit, tostring(I.AnimationController))
return {}
]])
write("scripts/door.lua", [[
local anim = require('openmw.animation')
local I = require('openmw.interfaces')
print('REC door', tostring(I.AnimationController), tostring(anim.isPlaying(nil, 'x')))
return {}
]])
-- disposition, the call Thieves Pickpocket makes next
write("scripts/disp.lua", [[
local self = require('openmw.self')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
return { eventHandlers = { Disp = function()
  local player
  for _, a in ipairs(nearby.actors) do if types.Player.objectIsInstance(a) then player = a end end
  local before = types.NPC.getBaseDisposition(self, player)
  types.NPC.modifyBaseDisposition(self, player, 7)
  types.NPC.setBaseDisposition(self, player, types.NPC.getBaseDisposition(self, player) + 0.4)
  print('REC disp', types.NPC.getDisposition(self, player), before, types.NPC.getBaseDisposition(self, player))
  types.NPC.setBaseDisposition(self, player, 250)
  print('REC clamp', types.NPC.getBaseDisposition(self, player))
end } }
]])

mock.addObject({ id = "thief", objectType = tes3.objectType.npc, aiConfig = { fight = 0 }, health = 30, inventory = {},
    disposition = 44, baseDisposition = 35 })
mock.addObject({ id = "guard", objectType = tes3.objectType.npc, aiConfig = { fight = 0 }, health = 30, inventory = {} })
mock.addObject({ id = "ex_door", objectType = tes3.objectType.door })
local rt = require("omwcompat")
local actors = rt.actors or require("omwcompat.actors")
rt.register({ mod = "AnimTest", root = SYN, scripts = {
    { flags = { "GLOBAL" }, path = "scripts/g.lua" },
    { flags = { "NPC" }, path = "scripts/gesture.lua" },
    { flags = { "NPC" }, path = "scripts/disp.lua" },
    { flags = { "DOOR" }, path = "scripts/door.lua" },
} })
rt.register({ mod = "AnimOther", root = SYN, scripts = { { flags = { "NPC" }, path = "scripts/other.lua" } } })
mock.fire("initialized", {})
local ext = mock.addCell({ id = "Seyda Neen", gridX = -2, gridY = -9 })
W.activeCell = ext
local thief = mock.placeRef(ext, "thief", { 100, 0, 0 })
mock.placeRef(ext, "ex_door", { 50, 0, 0 })
local player = mock.newPlayer(ext)
mock.addMobile(thief, { hp = 30 })
mock.addMobile(player, { hp = 100 })

local function recs(tag)
    local out = {}
    for _, l in ipairs(mock.allLogs()) do
        local rest = l:match("^%[%w+%] REC " .. tag .. "\t?(.*)$")
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

section("scripts that use animations start")
mock.fire("loaded", { newGame = true })
mock.frames(3, 0.1)
check(last("chunk") == "thief\t1", "the NPC script that requires openmw.animation runs; I.AnimationController.version 1 (got " .. tostring(last("chunk")) .. ")")
check(logsWith("module 'openmw.animation' is not supported") == 0, "require('openmw.animation') no longer raises")
check(last("active") == "done", "onActive ran every openmw.animation call to the end")
check(last("consts") == "13\t0\t15\t14\t4", "PRIORITY / BLEND_MASK / BONE_GROUP have OpenMW's values (got " .. tostring(last("consts")) .. ")")
check(last("bools") == "false\tfalse\tfalse\tfalse\tfalse", "queries answer like an actor with nothing playing: booleans false")
check(last("nils") == "nil\tnil\tnil\tnil\tnil\tnil", "times, speed, loop count, active group and text-key time are nil")
check(last("other") == "ran", "a second mod's animation script runs too")
check(last("global") == "6\tnil", "openmw.animation loads in a global script; I.AnimationController is nil there")
check(last("door") == "nil\tfalse", "a door script gets openmw.animation but no I.AnimationController (an actor interface)")

section("warn once per mod, then count")
check(logsWith("AnimTest: I.AnimationController.addTextKeyHandler does nothing") == 1, "AnimTest: one warning, naming the first call")
check(logsWith("AnimOther: openmw.animation.playBlended does nothing") == 1, "AnimOther: its own single warning")
check(logsWith("animations are not ported") == 2, "exactly two animation warnings in all (one per mod)")
local c = actors.animCalls.AnimTest
check(c and c["openmw.animation.someFutureCall"] == 1, "an unknown openmw.animation member is a counted no-op function")
check(c and c["I.AnimationController.addTextKeyHandler"] == 1 and c["openmw.animation.playQueued"] == 1, "calls are counted per name")

section("a scripted gesture: no text key ever fires, the mod's fallback timer finishes it")
local wthief = rt.objects.wrap(thief)
for _ = 1, 50 do wthief:sendEvent("Apologize", {}) end
mock.frames(10, 0.1)
check(#recs("fallback") == 50, "the 50 fallback timers ran (got " .. #recs("fallback") .. ")")
check(last("fallback") == "50\t0", "no text-key handler was called")
check(c["I.AnimationController.playBlendedAnimation"] == 50 and c["openmw.animation.playBlended"] == 50, "50 + 50 play calls counted")
check(logsWith("animations are not ported") == 2, "still two warnings after 100 more calls (no spam)")
check(logsWith("ERROR") == 0, "no runtime errors (" .. tostring(mock.allLogs()[#mock.allLogs()]) .. ")")

section("disposition")
wthief:sendEvent("Disp", {})
mock.frames(1, 0.1)
check(last("disp") == "44\t35\t42", "getDisposition is the effective value, getBaseDisposition the base; modify +7 then set rounds (got " .. tostring(last("disp")) .. ")")
check(last("clamp") == "100", "setBaseDisposition clamps to 0..100")

section("save / load keeps working")
local snap = mock.save()
mock.load(snap)
for _, cl in ipairs(W.cells) do
    for _, r in ipairs(cl._refs) do if r.object.id == "thief" then mock.addMobile(r, { hp = 30 }) end end
end
mock.addMobile(tes3.player, { hp = 100 })
mock.frames(3, 0.1)
check(logsWith("ERROR") == 0, "no errors after a save/load")
check(logsWith("animations are not ported") == 2, "no repeated warning after load")

-- Thieves Pickpocket 1.5.5 (untracked corpus), when present: the script that failed in game
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
    local npc = mock2.placeRef(cell, "tp_thief", { 100, 0, 0 })
    local pl = mock2.newPlayer(cell)
    mock2.addMobile(npc, { hp = 30 })
    mock2.addMobile(pl, { hp = 100 })
    mock2.fire("loaded", { newGame = true })
    mock2.frames(3, 0.1)
    rt2.objects.wrap(npc):addScript("scripts/tpickpocket_local.lua")
    mock2.frames(300, 0.1)
    local errs, warns = {}, 0
    for _, l in ipairs(mock2.allLogs()) do
        if l:find("ERROR", 1, true) then errs[#errs + 1] = l end
        if l:find("animations are not ported", 1, true) then warns = warns + 1 end
    end
    check(#errs == 0, "tpickpocket_local.lua starts and runs 300 frames without an error (" .. tostring(errs[1]) .. ")")
    check(warns == 1, "one animation warning for the mod")
    local tc = require("omwcompat.actors").animCalls.ThievesPickpocket
    check(tc and tc["I.AnimationController.addTextKeyHandler"] == 1, "its load-time addTextKeyHandler was accepted")
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
