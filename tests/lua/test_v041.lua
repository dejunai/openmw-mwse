-- omwcompat 0.4.1: removed and "off by default" lights stay silent (the No Fires in Bad Weather
-- / Leave The Lights Off fire-loop runaway of 2026-11-26), removed objects are never reported
-- active again, MENU scripts used for settings, and table-valued custom settings renderers.
-- Run from staging/LeaveTheLightsOff via tests/run_lua_tests.sh. Written for omwcompat by dej (dejunai).
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local mock = require("mock_mwse").install({})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end
local function section(s) print("\n== " .. s) end

local SYN = (os.getenv("TMPDIR_SYNTH") or "/tmp/omwcompat-synth") .. "-v041/"
os.execute("mkdir -p '" .. SYN .. "scripts'")
local function write(rel, text)
    local f = assert(io.open(SYN .. rel, "w")); f:write(text); f:close()
end

-- The swap pattern of No Fires in Bad Weather, written for this test: one list entry per
-- frame via next(list, cursor); invalid entries are dropped with table.remove; a light is
-- swapped with remove() + createObject():teleport() to an off copy made with
-- createRecordDraft{ template = original, isOffByDefault = true } and back.
write("scripts/swap.lua", [[
local types = require('openmw.types')
local world = require('openmw.world')
local list, cursor, cur = {}, nil, nil
local bad = false
local data = { gen = {}, rev = {} }
local seen = {}
local function swapTo(l, recordId)
  local pos, cell, rot, count = l.position, l.cell, l.rotation, l.count
  l:remove()
  world.createObject(recordId, count):teleport(cell, pos, { rotation = rot })
end
return {
  interfaceName = 'T041', interface = {
    setBad = function(b) bad = b end,
    size = function() return #list end,
    seen = function(id) return seen[id] or 0 end,
    offOf = function(id) return data.gen[id] end,
  },
  engineHandlers = {
    onSave = function() return { bad = bad, data = data } end,
    onLoad = function(d) if d then bad = d.bad; data = d.data end end,
    onUpdate = function(dt)
      if dt == 0 then return end
      cursor, cur = next(list, cursor)
      if not cur then return end
      if not cur:isValid() or cur.count == 0 then
        table.remove(list, cursor)
      elseif not bad and data.rev[cur.recordId] then
        swapTo(cur, data.rev[cur.recordId])
      elseif bad and not data.rev[cur.recordId] then
        if not data.gen[cur.recordId] then
          local rec = world.createRecord(types.Light.createRecordDraft({ template = types.Light.record(cur), isOffByDefault = true }))
          data.gen[cur.recordId] = rec.id
          data.rev[rec.id] = cur.recordId
        end
        swapTo(cur, data.gen[cur.recordId])
      end
    end,
    onObjectActive = function(o)
      if not types.Light.objectIsInstance(o) then return end
      seen[o.id] = (seen[o.id] or 0) + 1
      if o.recordId:find('torch') or data.rev[o.recordId] then table.insert(list, o) end
    end,
  },
}
]])

local FIRE = { id = "Fire 40" }
local SWING = { id = "plx_swingrope" }
mock.addLight({ id = "light_torch_01", sound = FIRE, isFire = true })
mock.addLight({ id = "light_tikitorch00_256", sound = FIRE, isFire = true })
mock.addLight({ id = "light_sign_torch", sound = SWING })
mock.addLight({ id = "light_vanilla_off", sound = FIRE, isOffByDefault = true })   -- a content record: never touched

local rt = require("omwcompat")
local objects = rt.objects
rt.register({ mod = "SwapTest", root = SYN, scripts = {
    { flags = { "GLOBAL" }, path = "scripts/swap.lua", guards = { "activeDedupe", "safeIteration" } },
} })
mock.fire("initialized", {})
local ext = mock.addCell({ id = "Pelagiad", gridX = 0, gridY = -8 })
W.activeCell = ext
local torch = mock.placeRef(ext, "light_torch_01", { 100, 0, 0 })
local tiki = mock.placeRef(ext, "light_tikitorch00_256", { 300, 0, 0 })
local sign = mock.placeRef(ext, "light_sign_torch", { 500, 0, 0 })
local voff = mock.placeRef(ext, "light_vanilla_off", { 700, 0, 0 })
mock.newPlayer(ext)
mock.fire("loaded", { newGame = true })
mock.frames(3)
local T = rt.getInterface("T041")

local function liveAt(x)
    for _, r in ipairs(ext._refs) do
        if not r._gone and not r.disabled and r.position.x == x then return r end
    end
end
local function loopsAt(x)
    local n = 0
    for _, r in ipairs(ext._refs) do
        if W.loops[r] and r.position.x == x then n = n + 1 end
    end
    return n
end
local function startsOf(r) return W.loopStarts[r] or 0 end

section("baseline: lit torches play one loop each")
mock.engineSounds(3)
check(loopsAt(100) == 1 and loopsAt(300) == 1 and loopsAt(500) == 1, "one loop per lit torch")
check(startsOf(voff) == 1, "a vanilla off-by-default record still plays (only omwcompat's off copies are gated)")

section("control: the 0.4.0 behaviour reproduces the runaway")
-- 0.4.0 had no sound gate and remove() did not stop the reference's sounds
rt.soundGate.enabled = false
local realRemove = tes3.removeSound
tes3.removeSound = function(p) W.sounds[#W.sounds + 1] = { op = "noop-remove", ref = p.reference } end
W.notPlayingQuirk = true
T.setBad(true)
mock.frames(40)
local offTorch = liveAt(100)
check(offTorch and offTorch.object.isOffByDefault and objects.isGeneratedId(offTorch.object.id), "torch swapped to a Generated off copy")
check(torch.disabled and objects.isTomb(torch), "original torch removed (disabled + tombstoned)")
check(W.loops[torch] == true, "0.4.0: the removed torch keeps its loop (disable does not stop it)")
mock.engineSounds(5)
check(startsOf(offTorch) >= 5, "0.4.0: the off copy's own loop restarts every engine pass (runaway, " .. startsOf(offTorch) .. " starts)")
check(loopsAt(100) >= 1 and startsOf(offTorch) > 0, "0.4.0: the unlit torch is heard")
-- put things back for the fixed run: lit again, sounds cleared
T.setBad(false)
mock.frames(40)
tes3.removeSound = realRemove
rt.soundGate.enabled = true
for r in pairs(W.loops) do W.loops[r] = nil end
for r in pairs(W.loopStarts) do W.loopStarts[r] = nil end
check(liveAt(100) == torch and not torch.disabled, "control run restored the original torch (tomb resurrected)")

section("0.4.1: remove() silences, off copies and tombstones are gated")
mock.engineSounds(1)
check(loopsAt(100) == 1 and loopsAt(300) == 1 and loopsAt(500) == 1, "lit again: one loop per torch")
local blockedBefore = rt.soundGate.offCopy
T.setBad(true)
mock.frames(40)
local off1, off2, off3 = liveAt(100), liveAt(300), liveAt(500)
check(off1 and off1.object.isOffByDefault and off2 and off2.object.isOffByDefault and off3 and off3.object.isOffByDefault,
    "all three torches swapped to off copies")
check(W.loops[torch] == nil and W.loops[tiki] == nil and W.loops[sign] == nil, "removed originals: their loops were stopped by remove()")
local removes = 0
for _, x in ipairs(W.sounds) do if x.op == "remove" and x.ref == torch and x.sound == nil then removes = removes + 1 end end
check(removes >= 1, "remove() called tes3.removeSound{ reference = ref } on the torch")
mock.engineSounds(10)
check(startsOf(off1) == 0 and startsOf(off2) == 0 and startsOf(off3) == 0, "off copies never start their own loop (as in OpenMW)")
check(loopsAt(100) == 0 and loopsAt(300) == 0 and loopsAt(500) == 0, "nothing is heard where the torches are off")
check(rt.soundGate.offCopy > blockedBefore, "sound gate counted the blocked starts (" .. rt.soundGate.offCopy .. ")")
local gateLines = 0
for _, l in ipairs(mock.allLogs()) do if l:find("sound gate: kept", 1, true) then gateLines = gateLines + 1 end end
check(gateLines == 1, "one sound gate line in the log, later cases only counted")
-- a sound some script starts on a tombstoned reference is blocked too
local e = { reference = torch, sound = FIRE, flags = 1 }
mock.fire("addSound", e)
check(e.block == true and rt.soundGate.removed >= 1, "any sound on a removed object is blocked")
-- other sounds on an off copy (not its own) are left alone
local e2 = { reference = off1, sound = { id = "Door Open" }, flags = 0 }
mock.fire("addSound", e2)
check(not e2.block, "a different sound on an off copy plays")

section("removed objects are never reported active again")
local before = T.seen(objects.wrap(torch).id)
rt.objectBecameActive(objects.wrap(torch))
mock.fire("referenceActivated", { reference = torch })
mock.frames(2)
check(T.seen(objects.wrap(torch).id) == before, "objectBecameActive / referenceActivated of a tombstone: no onObjectActive")
check(T.size() <= 4, "the swap list does not grow with dead entries (" .. T.size() .. ")")

section("weather clears: originals back, one loop each, no duplicates")
T.setBad(false)
mock.frames(40)
check(liveAt(100) == torch and liveAt(300) == tiki and liveAt(500) == sign, "the original references are lit again (resurrected)")
local created = 0
for _, r in ipairs(ext._refs) do if not r._gone and r.object.isOffByDefault and objects.isGeneratedId(r.object.id) then created = created + 1 end end
check(created == 0, "the created off copies were deleted, not just disabled")
mock.engineSounds(5)
check(loopsAt(100) == 1 and loopsAt(300) == 1 and loopsAt(500) == 1, "exactly one loop per lit torch")
check(startsOf(torch) == 2 and startsOf(tiki) == 2, "each original started its loop once before the rain and once after")

section("GameObject.enabled = false silences too")
W.notPlayingQuirk = false
mock.engineSounds(1)
local w = objects.wrap(voff)
check(W.loops[voff] == true, "vanilla off-by-default light playing (control)")
w.enabled = false
check(voff.disabled and W.loops[voff] == nil, "disabled through GameObject.enabled: its loop stopped")
w.enabled = true

section("save / load keeps the gate working")
T.setBad(true)
mock.frames(40)
local snap = mock.save()
mock.load(snap)
mock.fire("loaded", {})
mock.frames(40)
mock.engineSounds(3)
local off = liveAt(100)
check(off and off.object.isOffByDefault and objects.isGeneratedId(off.object.id), "after a load the torch is still the off copy")
check(off and startsOf(off) == 0 and loopsAt(100) == 0, "after a load the off copy is still silent")

-- the original No Fires in Bad Weather global.lua (untracked corpus), when present
section("No Fires in Bad Weather 1.0 (corpus), when present")
local NROOT = os.getenv("TESTS_DIR") .. "/../../corpus/no-fires-in-bad-weather/_archive/full/"
local probe = io.open(NROOT .. "scripts/NFiBW/global.lua", "r")
if not probe then
    print("  corpus/no-fires-in-bad-weather missing; skipped")
else
    probe:close()
    mock = require("mock_mwse").install({})
    W = mock.W
    for k in pairs(package.loaded) do if k:find("^omwcompat") then package.loaded[k] = nil end end
    local mon = mock.addScript("wetfire_weather_monitor", { actweather = 0 })
    mock.addLight({ id = "light_torch_01", sound = FIRE, isFire = true })
    mock.addLight({ id = "light_com_candle_01", sound = nil })
    local rt2 = require("omwcompat")
    rt2.register({ mod = "NoFiresinBadWeather", root = NROOT, scripts = {
        { flags = { "GLOBAL" }, path = "scripts/NFiBW/global.lua", guards = { "activeDedupe", "safeIteration" } },
    } })
    mock.fire("initialized", {})
    local c = mock.addCell({ id = "Seyda Neen", gridX = -2, gridY = -9 })
    W.activeCell = c
    local t1 = mock.placeRef(c, "light_torch_01", { 10, 0, 0 })
    local t2 = mock.placeRef(c, "light_torch_01", { 20, 0, 0 })
    mock.placeRef(c, "light_com_candle_01", { 30, 0, 0 })
    mock.newPlayer(c)
    mock.fire("loaded", { newGame = true })
    mock.frames(5)
    mock.engineSounds(2)
    check(W.loops[t1] and W.loops[t2], "NFiBW: lit torches loop")
    mon._vars.actweather = 4   -- rain
    mock.frames(60)
    W.notPlayingQuirk = true
    mock.engineSounds(10)
    local offs, offStarts = 0, 0
    for _, r in ipairs(c._refs) do
        if not r._gone and not r.disabled and r.object.isOffByDefault then offs = offs + 1; offStarts = offStarts + (W.loopStarts[r] or 0) end
    end
    check(offs == 3, "NFiBW: both torches and the candle swapped off in the rain (" .. offs .. ")")
    check(offStarts == 0 and not W.loops[t1] and not W.loops[t2], "NFiBW: no fire loop on the off copies or the removed torches")
    mon._vars.actweather = 0
    mock.frames(60)
    W.notPlayingQuirk = false
    mock.engineSounds(3)
    check(not t1.disabled and not t2.disabled and W.loops[t1] and W.loops[t2], "NFiBW: torches lit again with their loop")
    check((W.loopStarts[t1] or 0) == 2 and (W.loopStarts[t2] or 0) == 2, "NFiBW: one start before the rain, one after")
    local errs = 0
    for _, l in ipairs(mock.allLogs()) do if l:find("ERROR", 1, true) then errs = errs + 1; print("    " .. l) end end
    check(errs == 0, "NFiBW: no runtime errors")
end

-- ThievesPickpocket 1.5.5 settings (untracked corpus), when present
section("ThievesPickpocket settings (corpus), when present")
local TROOT = os.getenv("TESTS_DIR") .. "/../../corpus/thieves-pickpocket/_archive/full/"
local tp = io.open(TROOT .. "scripts/tpickpocket_settings.lua", "r")
if not tp then
    print("  corpus/thieves-pickpocket missing; skipped")
else
    tp:close()
    mock = require("mock_mwse").install({})
    W = mock.W
    for k in pairs(package.loaded) do if k:find("^omwcompat") then package.loaded[k] = nil end end
    local rt3 = require("omwcompat")
    rt3.register({ mod = "ThievesPickpocket", root = TROOT, probeSettings = true, scripts = {
        { flags = { "GLOBAL" }, path = "scripts/tpickpocket_global.lua" },
        { flags = { "CUSTOM" }, path = "scripts/tpickpocket_local.lua" },
        { flags = { "PLAYER" }, path = "scripts/tpickpocket_player.lua" },
        { flags = { "MENU" }, path = "scripts/tpickpocket_settings.lua" },
    } })
    mock.fire("initialized", {})
    mock.fire("modConfigReady", {})
    local notHosted, fallback = 0, 0
    for _, l in ipairs(mock.allLogs()) do
        if l:find("are not hosted", 1, true) then notHosted = notHosted + 1 end
        if l:find("fallback control", 1, true) then fallback = fallback + 1 end
    end
    check(notHosted == 0, "TP: no 'MENU ... not hosted' warning (the MENU script is run by the settings probe)")
    check(fallback == 0, "TP: no fallback-control warnings for tpMultiNumber / tpMultiSelect")
    local tpl = W.mcm[#W.mcm]
    local function find(label) return mock.mcmFind(tpl, label) end
    local controls = mock.mcmControls(tpl)
    local labels = {}
    for _, cc in ipairs(controls) do labels[#labels + 1] = tostring(cc.label) end
    local chance, radius = nil, nil
    for _, cc in ipairs(controls) do
        if cc.kind == "Slider" and cc.args.min == 0 and cc.args.max == 1 then chance = cc end
        if cc.kind == "Slider" and cc.args.min == 50 and cc.args.max == 500 and not radius then radius = cc end
    end
    check(chance ~= nil and radius ~= nil, "TP: THEFT shown as per-key sliders (steal chance 0-1, radius 50-500)")
    if radius then
        mock.mcmSet(radius, 123.4)
        local sec = rt3.settings.section("SettingsTP", nil, nil, true)
        local v = sec:get("THEFT")
        check(type(v) == "table" and v.STEAL_RADIUS == 123 and v.STEAL_CHANCE ~= nil, "TP: setting one key writes the whole table (radius rounded to 123)")
    end
    local toggles = 0
    for _, cc in ipairs(controls) do if cc.kind == "OnOffButton" then toggles = toggles + 1 end end
    check(toggles >= 3 + 3, "TP: FEEDBACK keys shown as on/off buttons (" .. toggles .. " on/off controls)")
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
