-- omwcompat 0.5.0: ported stubs.
--   1. the sound gate covers one-off sounds (addTempSound: sound files, say, sound
--      generators) and lights a script disabled, not only removed objects and off copies;
--   2. simple openmw.animation / I.AnimationController calls on vanilla groups go through
--      tes3.playAnimation and reference.animationData; unknown ones stay quiet no-ops;
--   3. self.controls writes on NPCs and creatures: yawChange -> facing, run / sneak ->
--      forceRun / forceSneak, jump -> doJump; the rest warn once and are ignored.
-- Nothing may raise, and nothing after init goes to MWSE.log. Run from
-- staging/LeaveTheLightsOff via tests/run_lua_tests.sh. Written for omwcompat by dej (dejunai).
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local mock = require("mock_mwse").install({})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end
local function section(s) print("\n== " .. s) end

local SYN = (os.getenv("TMPDIR_SYNTH") or "/tmp/omwcompat-synth") .. "-v050/"
os.execute("mkdir -p '" .. SYN .. "scripts'")
local function write(rel, text)
    local f = assert(io.open(SYN .. rel, "w")); f:write(text); f:close()
end

---------------------------------------------------------------- MWSE pieces this test adds to the mock
-- like MWSE: tes3.playSound{ sound } raises addSound, tes3.playSound{ soundPath } and
-- tes3.say raise addTempSound; a blocked event plays nothing.
tes3.event.addTempSound, tes3.event.playGroup = "addTempSound", "playGroup"
W.played = {}
tes3.playSound = function(p)
    local e
    if p.soundPath then
        e = { reference = p.reference, path = p.soundPath, flags = p.loop and 1 or 0, volume = 250, pitch = 1, isVoiceover = false }
        if mock.fire("addTempSound", e) == false or e.block then return false end
    else
        e = { reference = p.reference, sound = type(p.sound) == "table" and p.sound or { id = p.sound }, flags = p.loop and 1 or 0,
            volume = 250, pitch = 1, isVoiceover = false }
        if mock.fire("addSound", e) == false or e.block then return false end
    end
    W.played[#W.played + 1] = { ref = p.reference, sound = p.sound, path = p.soundPath }
    return true
end
tes3.say = function(p)
    local e = { reference = p.reference, path = p.soundPath, flags = 0, volume = 250, pitch = 1, isVoiceover = true }
    if mock.fire("addTempSound", e) == false or e.block then return end
    W.played[#W.played + 1] = { ref = p.reference, path = p.soundPath, say = true }
end
-- a reference's facing is its orientation.z (MWSE tes3reference.facing)
local function withFacing(r)
    local mt = getmetatable(r)
    local idx, nidx = mt.__index, mt.__newindex
    setmetatable(r, {
        __index = function(t, k)
            if k == "facing" then return rawget(t, "orientation").z end
            if type(idx) == "function" then return idx(t, k) end
            return idx[k]
        end,
        __newindex = function(t, k, v)
            if k == "facing" then t.orientation.z = v; t.modified = true; return end
            rawset(t, k, v)
        end,
    })
    return r
end

-- animation groups (a subset of tes3.animationGroup, MWSE's ids)
tes3.animationGroup = { idle = 0, idle2 = 1, idle3 = 2, idle9 = 8, idleHandToHand = 9, hit1 = 0x13,
    walkForward = 0x35, walkForwardHandToHand = 0x44, handToHand = 0x89, weaponOneHand = 0x8D,
    inventoryHandToHand = 0x92 }
W.anims = {}
local function newAnimData(groups)
    local ad = { animationGroups = {}, currentAnimGroups = { 0, 0, 0 }, timings = { 0.25, 0.5, 0.75 } }
    for _, id in ipairs(groups) do ad.animationGroups[id + 1] = { groupId = id } end
    return ad
end
local function setCurrent(ref, s, id)
    local ad = rawget(ref, "animationData")
    if ad.currentAnimGroups[s] ~= id then
        ad.currentAnimGroups[s] = id
        mock.fire("playGroup", { reference = ref, group = id, index = s - 1, animationData = ad })
    end
end
W.failPlay = false
tes3.playAnimation = function(p)
    if W.failPlay then error("playAnimation exploded") end
    W.anims[#W.anims + 1] = p
    local ref = type(p.reference) == "table" and (p.reference.reference or p.reference) or p.reference
    if p.group then for s = 1, 3 do setCurrent(ref, s, p.group) end end
    if p.lower then setCurrent(ref, 1, p.lower) end
    if p.upper then setCurrent(ref, 2, p.upper) end
    if p.shield then setCurrent(ref, 3, p.shield) end
end
W.loopCancels, W.skips = 0, 0
tes3.cancelAnimationLoop = function() W.loopCancels = W.loopCancels + 1 end
tes3.skipAnimationFrame = function() W.skips = W.skips + 1 end

---------------------------------------------------------------- scripts
-- a global script that toggles and removes lights and plays one-off sounds on them
write("scripts/g.lua", [[
local world = require('openmw.world')
local core = require('openmw.core')
local function find(id)
  for _, c in ipairs({ world.players[1].cell }) do
    for _, l in ipairs(c:getAll()) do if l.recordId == id then return l end end
  end
end
return {
  interfaceName = 'P050', interface = {
    Off = function(d) find(d.id).enabled = false end,
    On = function(d) find(d.id).enabled = true end,
    Remove = function(d) find(d.id):remove() end,
    Ping = function(d)
      local o = d.obj or find(d.id)
      core.sound.playSound3d('Light Spell', o)
      core.sound.playSoundFile3d('Fx/torch_crackle.wav', o)
      core.sound.say('Vo/i/m/hlo_im001.mp3', o, 'hi')
    end,
  },
}
]])
-- an NPC script that uses the AnimationController and controls
write("scripts/npc.lua", [[
local self = require('openmw.self')
local anim = require('openmw.animation')
local I = require('openmw.interfaces')
local keys, ended = {}, {}
I.AnimationController.addTextKeyHandler('idle2', function(g, k) keys[#keys + 1] = g .. ':' .. k end)
I.AnimationController.addTextKeyHandler('', function(g, k) keys[#keys + 1] = '*' .. g .. ':' .. k end)
I.AnimationController.addAnimationEndedHandler(function(g, info) ended[#ended + 1] = g .. ':' .. tostring(info.completion) end)
local override
I.AnimationController.addPlayBlendedAnimationHandler(function(g, o)
  if override == 'loops' then o.loops = 5 elseif override == 'skip' then o.skip = true end
end)
local function q(v) return tostring(v) end
return {
  eventHandlers = {
    Play = function(d)
      override = d.override
      I.AnimationController.playBlendedAnimation(d.group, d.options or { priority = anim.PRIORITY.Scripted })
    end,
    Direct = function(d) anim.playBlended(self, d.group, d.options) end,
    Queue = function(d)
      if d.clear then anim.clearAnimationQueue(self, false) end
      anim.playQueued(self, d.group, d.options)
    end,
    Cancel = function(d) anim.cancel(self, d.group) end,
    NoLoop = function(d) anim.setLoopingEnabled(self, d.group, false) end,
    Skip = function() anim.skipAnimationThisFrame(self) end,
    Ask = function(d)
      print('REC ask', q(anim.hasAnimation(self)), q(anim.hasGroup(self, d.group)), q(anim.isPlaying(self, d.group)),
        q(anim.getActiveGroup(self, anim.BONE_GROUP.LowerBody)), q(anim.getActiveGroup(self, anim.BONE_GROUP.RightArm)),
        q(anim.getActiveGroup(self, anim.BONE_GROUP.LeftArm)), q(anim.getCurrentTime(self, d.group)))
    end,
    Stubs = function()
      print('REC stubs', q(anim.getCompletion(self, 'idle2')), q(anim.getTextKeyTime(self, 'idle2: start')), q(anim.hasBone(self, 'Bip01')))
      anim.addVfx(self, 'x.nif'); anim.setSpeed(self, 'idle2', 2); anim.someFutureCall(self)
    end,
    Keys = function() print('REC keys', table.concat(keys, ','), table.concat(ended, ',')); keys, ended = {}, {} end,
    Yaw = function(d) self.controls.yawChange = d.v; print('REC yaw', q(self.controls.yawChange)) end,
    Ctl = function(d) self.controls[d.k] = d.v end,
    Read = function() print('REC read', q(self.controls.movement), q(self.controls.sideMovement), q(self.controls.run), q(self.controls.pitchChange)) end,
  },
}
]])
write("scripts/player.lua", [[
local self = require('openmw.self')
local anim = require('openmw.animation')
local I = require('openmw.interfaces')
return { eventHandlers = {
  PPlay = function() I.AnimationController.playBlendedAnimation('hit1', { priority = anim.PRIORITY.Scripted }) end,
  PYaw = function() self.controls.yawChange = 1; self.controls.movement = 1; print('REC pmove', tostring(self.controls.movement)) end,
} }
]])

mock.addLight({ id = "light_a", sound = { id = "Fire 40" } })
mock.addLight({ id = "light_b", sound = { id = "Fire 40" } })
mock.addLight({ id = "light_c", sound = { id = "Fire 40" } })
mock.addLight({ id = "light_other", sound = { id = "Fire 40" } })
mock.addObject({ id = "dancer", objectType = tes3.objectType.npc, aiConfig = { fight = 0 }, health = 30, inventory = {} })
mock.addObject({ id = "rat", objectType = tes3.objectType.creature, aiConfig = { fight = 0 }, health = 10, inventory = {} })
local rt = require("omwcompat")
local actors = require("omwcompat.actors")
rt.register({ mod = "PortTest", root = SYN, scripts = {
    { flags = { "GLOBAL" }, path = "scripts/g.lua" },
    { flags = { "NPC", "CREATURE" }, path = "scripts/npc.lua" },
    { flags = { "PLAYER" }, path = "scripts/player.lua" },
} })
mock.fire("initialized", {})
local initLogs = #W.logs
local ext = mock.addCell({ id = "Balmora", gridX = -3, gridY = -2 })
W.activeCell = ext
local la = mock.placeRef(ext, "light_a", { 10, 0, 0 })
local lb = mock.placeRef(ext, "light_b", { 20, 0, 0 })
local lc = mock.placeRef(ext, "light_c", { 30, 0, 0 })
local lo = mock.placeRef(ext, "light_other", { 40, 0, 0 })
local npc = withFacing(mock.placeRef(ext, "dancer", { 100, 0, 0 }))
local rat = withFacing(mock.placeRef(ext, "rat", { 200, 0, 0 }))
local player = withFacing(mock.newPlayer(ext))
local npcMob = mock.addMobile(npc, { hp = 30 })
local ratMob = mock.addMobile(rat, { hp = 10 })
local plMob = mock.addMobile(player, { hp = 100 })
npcMob.jumps = 0
function npcMob:doJump() self.jumps = self.jumps + 1; return true end
rawset(npc, "animationData", newAnimData({ 0, 1, 2, 0x13, 0x35, 0x44, 0x8D }))
rawset(player, "animationData", newAnimData({ 0, 1, 0x13 }))
rawset(rat, "animationData", newAnimData({ 0 }))
mock.fire("loaded", { newGame = true })
mock.frames(3, 0.1)

local function logsWith(s)
    local n = 0
    for _, l in ipairs(mock.allLogs()) do if l:find(s, 1, true) then n = n + 1 end end
    return n
end
local function recs(tag)
    local out = {}
    for _, l in ipairs(mock.allLogs()) do
        local rest = l:match("^%[%w+%] REC " .. tag .. "\t?(.*)$")
        if rest then out[#out + 1] = rest end
    end
    return out
end
local function last(tag) local r = recs(tag); return r[#r] end
local function playedOn(ref)
    local n = 0
    for _, x in ipairs(W.played) do if x.ref == ref then n = n + 1 end end
    return n
end
local G = rt.objects
local function global(name, d) rt.getInterface("P050")[name](d or {}); mock.frames(1, 0.1) end
local wnpc = G.wrap(npc)
local function npcEv(name, d) wnpc:sendEvent(name, d or {}); mock.frames(1, 0.1) end
local function lastAnim() return W.anims[#W.anims] end

---------------------------------------------------------------- 1. sound gate
section("one-off sounds on an enabled light play")
global("Ping", { id = "light_a" })
check(playedOn(la) == 3, "playSound3d, playSoundFile3d and say all play on a lit light (got " .. playedOn(la) .. ")")

section("a light a script disabled stays silent, one-offs included")
global("Off", { id = "light_a" })
check(la.disabled, "light_a disabled by the script")
local before = playedOn(la)
global("Ping", { id = "light_a" })
check(playedOn(la) == before + 1, "only the voice line plays on the disabled light (voice-over is never blocked)")
check(rt.soundGate.disabled == 2, "two one-offs blocked as 'disabled' (got " .. rt.soundGate.disabled .. ")")
check(rt.soundGate.oneOff >= 2, "counted as one-off blocks")
local eLoop = { reference = la, sound = { id = "Fire 40" }, flags = 1 }
mock.fire("addSound", eLoop)
check(eLoop.block == true, "the light's own loop is blocked on the disabled light too")
check(logsWith("as OpenMW does") >= 1 and logsWith("(a light a script disabled)") == 1, "one gate line for the 'disabled' kind")

section("re-enabled, it plays again; other disabled lights are left alone")
global("On", { id = "light_a" })
before = playedOn(la)
global("Ping", { id = "light_a" })
check(playedOn(la) == before + 3, "after enabled = true all three play again")
lo:disable()  -- disabled by something else (a vanilla script, another mod): not ours
global("Ping", { obj = G.wrap(lo) })
check(playedOn(lo) == 3, "a light disabled outside omwcompat is not gated")

section("a removed light: sound files and voice are blocked as well")
global("Remove", { id = "light_b" })
check(lb.disabled and G.isTomb(lb), "light_b removed (tombstone)")
local eTemp = { reference = lb, path = "Fx/torch_crackle.wav", flags = 0, isVoiceover = false }
mock.fire("addTempSound", eTemp)
check(eTemp.block == true, "addTempSound on a removed object is blocked")
local eVo = { reference = lb, path = "Vo/x.mp3", flags = 0, isVoiceover = true }
mock.fire("addTempSound", eVo)
check(not eVo.block, "voice-over is never blocked")
local eNone = { reference = nil, path = "Fx/wind.wav", flags = 0 }
mock.fire("addTempSound", eNone)
check(not eNone.block, "sounds without a reference are never blocked")
local eOk = { reference = lc, path = "Fx/torch_crackle.wav", flags = 0 }
mock.fire("addTempSound", eOk)
check(not eOk.block, "a one-off on a lit light is not blocked")
rt.soundGate.enabled = false
local eOff = { reference = lb, path = "Fx/torch_crackle.wav", flags = 0 }
mock.fire("addTempSound", eOff)
check(not eOff.block, "soundGate.enabled = false turns the gate off")
rt.soundGate.enabled = true

---------------------------------------------------------------- 2. animations
section("playBlendedAnimation on a vanilla group: tes3.playAnimation, handlers, text keys, ended")
local n0 = #W.anims
npcEv("Play", { group = "idle2", options = { priority = 13, loops = 2 } })
local p = lastAnim()
check(#W.anims == n0 + 1 and p.group == 1 and p.loopCount == 2 and p.startFlag == 1 and p.lower == nil,
    "Scripted priority on an NPC: whole body (group = idle2), loopCount 2, immediate")
npcEv("Ask", { group = "idle2" })
check(last("ask") == "true\ttrue\ttrue\tidle2\tidle2\tidle2\t0.25", "hasAnimation / hasGroup / isPlaying / getActiveGroup / getCurrentTime (got " .. tostring(last("ask")) .. ")")
-- the animation ends: the engine goes back to idle
for s = 1, 3 do setCurrent(npc, s, 0) end
mock.frames(2, 0.1)
npcEv("Keys")
-- (the engine's idle "start" arrives first: playGroup is immediate, the end is found by the per-frame poll)
check(last("keys") == "idle2:start,*idle2:start,*idle:start,idle2:stop,*idle2:stop\tidle2:1",
    "text keys start (playGroup) / stop (ended) and one animationEnded call (got " .. tostring(last("keys")) .. ")")
check(logsWith("PortTest: I.AnimationController.playBlendedAnimation is played through MWSE") == 1, "one note for the first mapped call")

section("layering by priority and blend mask")
npcEv("Direct", { group = "hit1", options = { priority = 6 } })
p = lastAnim()
check(p.group == nil and p.lower == 0x13 and p.upper == 0x13 and p.shield == 0x13 and p.loopCount == 0,
    "Hit priority, mask All: layered on lower / upper / shield, AI keeps control, plays once")
npcEv("Direct", { group = "hit1", options = { priority = 6, blendMask = 14 } })
p = lastAnim()
check(p.lower == nil and p.upper == 0x13 and p.shield == 0x13, "BLEND_MASK.UpperBody: upper body and shield arm only")
npcEv("Direct", { group = "idle3", options = { loops = 1e9 } })
check(lastAnim().upper == 2 and lastAnim().loopCount == -1, "loops >= 1e6 means infinite (-1)")
G.wrap(player):sendEvent("PPlay", {}); mock.frames(1, 0.1)
p = lastAnim()
check(p.group == nil and p.lower == 0x13 and p.upper == 0x13, "on the player even Scripted priority is layered (never takes control)")

section("playQueued, clearAnimationQueue, cancel, looping")
npcEv("Queue", { group = "idle2" })
p = lastAnim()
check(p.group == 1 and p.loopCount == -1 and p.startFlag == 0, "playQueued: whole body, infinite by default, after the current group")
npcEv("Queue", { group = "idle2", clear = true, options = { loops = 0 } })
p = lastAnim()
check(p.startFlag == 1 and p.loopCount == 0, "clearAnimationQueue then playQueued in the same frame starts immediately")
local nC = #W.anims
npcEv("Cancel", { group = "walkforward" })
check(#W.anims == nC, "cancel of a group omwcompat did not start does nothing")
npcEv("Cancel", { group = "idle2" })
check(#W.anims == nC + 1 and lastAnim().group == 0, "cancel of our group hands the actor back to the AI (group 0)")
npcEv("Play", { group = "idle2" })
npcEv("NoLoop", { group = "idle2" })
check(W.loopCancels == 1, "setLoopingEnabled(false) on a playing group -> tes3.cancelAnimationLoop")
npcEv("NoLoop", { group = "hit1" })
check(W.loopCancels == 1, "...and nothing for a group that is not playing")
npcEv("Skip")
check(W.skips == 1, "skipAnimationThisFrame -> tes3.skipAnimationFrame")

section("aliases and active groups")
setCurrent(npc, 1, 0x44); setCurrent(npc, 2, 0x8D)
npcEv("Ask", { group = "walkforwardhh" })
check(last("ask"):match("^true\ttrue\ttrue\twalkforwardhh\tweapononehand\t") ~= nil,
    "OpenMW names: walkforwardhh (MWSE walkForwardHandToHand), weapononehand on the right arm (got " .. tostring(last("ask")) .. ")")
check(actors.groupIdOf("idlehh") == 9 and actors.groupIdOf("IdleHandToHand") == 9 and actors.groupIdOf("handtohand") == 0x89
    and actors.groupIdOf("inventoryhandtohand") == 0x92, "group-name map: hh aliases, attack and inventory groups keep their names")

section("handlers can change or skip a play")
npcEv("Play", { group = "idle3", override = "loops" })
check(lastAnim().loopCount == 5, "a playBlendedAnimation handler changed loops to 5")
nC = #W.anims
npcEv("Play", { group = "idle3", override = "skip" })
check(#W.anims == nC, "options.skip set by a handler: nothing is played")

section("what stays a quiet no-op")
nC = #W.anims
npcEv("Play", { group = "give02" })
npcEv("Play", { group = "idle9" })
npcEv("Play", { group = "idle2", options = { startKey = "self start", stopKey = "self stop" } })
check(#W.anims == nC, "a non-vanilla group, a group the actor lacks and custom start/stop keys play nothing")
npcEv("Stubs")
check(last("stubs") == "nil\tnil\tfalse", "getCompletion / getTextKeyTime nil, hasBone false")
check(logsWith("PortTest: I.AnimationController.playBlendedAnimation does nothing (group give02 is not a vanilla group)") == 1,
    "one warning for the mod, naming the first unmapped call and why")
check(logsWith("maps only simple vanilla-group calls") == 1, "...and only one, after more unmapped calls")
local wrat = G.wrap(rat)
W.failPlay = true
wrat:sendEvent("Direct", { group = "idle", options = {} }); mock.frames(1, 0.1)
W.failPlay = false
check(logsWith("MWSE refused tes3.playAnimation") == 1 and logsWith("ERROR") == 0, "a failing tes3.playAnimation is logged once and never raises")
rawset(rat, "animationData", nil)
wrat:sendEvent("Ask", { group = "idle" }); mock.frames(1, 0.1)
check(last("ask") == "false\tfalse\tfalse\tnil\tnil\tnil\tnil", "an actor without animation data answers 'not playing'")

---------------------------------------------------------------- 3. controls
section("self.controls writes")
npc.orientation.z = 0
npcEv("Yaw", { v = 0.3 })
check(math.abs(npc.orientation.z - 0.3) < 1e-9, "yawChange 0.3 turned the NPC by 0.3 rad (facing " .. npc.orientation.z .. ")")
check(last("yaw") == "0", "yawChange reads back 0, like OpenMW after the frame")
npc.orientation.z = 3.0
npcEv("Yaw", { v = 0.5 })
check(math.abs(npc.orientation.z - (3.5 - 2 * math.pi)) < 1e-9, "facing is wrapped to [-pi, pi]")
npcEv("Yaw", { v = 0 })
check(math.abs(npc.orientation.z - (3.5 - 2 * math.pi)) < 1e-9, "yawChange 0 leaves the facing alone")
npcEv("Ctl", { k = "run", v = true }); npcEv("Ctl", { k = "sneak", v = true })
check(npcMob.forceRun == true and npcMob.forceSneak == true, "run / sneak -> mobile.forceRun / forceSneak")
npcEv("Ctl", { k = "run", v = false })
check(npcMob.forceRun == false, "run = false clears forceRun")
npcEv("Ctl", { k = "jump", v = true }); npcEv("Ctl", { k = "jump", v = false })
check(npcMob.jumps == 1, "jump = true -> mobile:doJump() once; jump = false does nothing")
npcEv("Ctl", { k = "movement", v = 1 }); npcEv("Ctl", { k = "pitchChange", v = 0.2 }); npcEv("Ctl", { k = "movement", v = 0 })
check(logsWith("self.controls.movement cannot be set") == 1 and logsWith("self.controls.pitchChange cannot be set") == 1,
    "movement / pitchChange: one warning each, ignored")
wrat:sendEvent("Ctl", { k = "run", v = true }); mock.frames(1, 0.1)
check(ratMob.forceRun == nil and logsWith("creatures cannot be forced to run") == 1, "creatures: run is ignored with a warning")
rat.orientation.z = 0
wrat:sendEvent("Yaw", { v = -0.25 }); mock.frames(1, 0.1)
check(math.abs(rat.orientation.z + 0.25) < 1e-9, "a creature turns too")
player.orientation.z = 0
G.wrap(player):sendEvent("PYaw", {}); mock.frames(1, 0.1)
check(player.orientation.z == 0 and logsWith("cannot be set (the player)") >= 1, "the player is never steered (warning, ignored)")
npcMob.isMovingForward, npcMob.isMovingLeft, npcMob.isRunning = true, true, true
npcEv("Read")
check(last("read") == "1\t-1\ttrue\t0", "reads: movement / sideMovement from the movement flags, run from isRunning, pitchChange 0")
plMob.isMovingBack = true
G.wrap(player):sendEvent("PYaw", {}); mock.frames(1, 0.1)
check(last("pmove") == "-1", "the player's movement reads the keyboard state, not a write")

---------------------------------------------------------------- logging + save
section("logging and save / load")
check(logsWith("ERROR") == 0, "no runtime errors (" .. tostring(mock.allLogs()[#mock.allLogs()]) .. ")")
local extra = {}
for i = initLogs + 1, #W.logs do
    if not W.logs[i]:find("registered", 1, true) and not W.logs[i]:find("library log", 1, true) and not W.logs[i]:find("loaded", 1, true) then
        extra[#extra + 1] = W.logs[i]
    end
end
check(#extra == 0, "nothing but init lines on MWSE.log (" .. tostring(extra[1]) .. ")")
local snap = mock.save()
mock.load(snap)
mock.frames(3, 0.1)
check(logsWith("ERROR") == 0, "no errors after a save/load")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
