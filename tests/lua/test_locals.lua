-- Local (object-attached) script hosting: CREATURE / ACTOR / DOOR scripts, openmw.self,
-- openmw.nearby, types.Actor stats, I.AI, per-object save data and cell (de)activation.
-- Run from staging/LeaveTheLightsOff via tests/run_lua_tests.sh.
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local mock = require("mock_mwse").install({})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end
local function section(s) print("\n== " .. s) end

local SYN = (os.getenv("TMPDIR_SYNTH") or "/tmp/omwcompat-synth") .. "-locals/"
os.execute("mkdir -p '" .. SYN .. "scripts'")
local function write(rel, text)
    local f = assert(io.open(SYN .. rel, "w")); f:write(text); f:close()
end

-- results channel: print() -> mwse.log "[Locals] REC ..."
write("scripts/crea.lua", [[
local self = require('openmw.self')
local types = require('openmw.types')
local nearby = require('openmw.nearby')
local async = require('openmw.async')
local I = require('openmw.interfaces')
local updates, loaded = 0, nil
print('REC chunk', self.recordId)
print('REC noworld', tostring(pcall(require, 'openmw.world')))
local function report()
  local hp = types.Actor.stats.dynamic.health(self)
  local fight = types.Actor.stats.ai.fight(self)
  local str = types.Actor.stats.attributes.strength(self)
  print('REC stats', hp.current, hp.base, fight.base, fight.modified, fight.modifier, str.base, str.modified, tostring(types.Actor.isDead(self)))
  print('REC self', tostring(self.type == types.Creature), tostring(self == self.object), tostring(self:isActive()), tostring(types.Creature.objectIsInstance(self)))
  local npcs, sawSelf, sawPlayer = 0, false, false
  for _, a in ipairs(nearby.actors) do
    if a.type == types.NPC then npcs = npcs + 1 end
    if a == self then sawSelf = true end
    if a.type == types.Player then sawPlayer = true end
  end
  print('REC nearby', npcs, tostring(sawSelf), tostring(sawPlayer), #nearby.doors)
  local p = I.AI.getActivePackage()
  print('REC pkg', p and p.type or 'nil')
end
return {
  engineHandlers = {
    onInit = function() print('REC init', self.recordId) end,
    onLoad = function(d) loaded = d; print('REC load', self.recordId, d and d.n or 'nil') end,
    onActive = function() print('REC active', self.recordId); report() end,
    onInactive = function() print('REC inactive', self.recordId) end,
    onUpdate = function(dt) updates = updates + 1 end,
    onSave = function() return { n = updates + (loaded and loaded.n or 0) } end,
  },
  eventHandlers = {
    Attack = function(d)
      I.AI.startPackage({ type = 'Combat', target = d.target })
      local p = I.AI.getActivePackage()
      print('REC attacked', p and p.type or 'nil', tostring(p and p.target == d.target))
      types.Actor.stats.dynamic.health(self).current = 7
      types.Actor.stats.ai.fight(self).modifier = 5
    end,
  },
}
]])
write("scripts/any_actor.lua", [[
local self = require('openmw.self')
print('REC actor', self.recordId)
return {}
]])
write("scripts/door.lua", [[
local self = require('openmw.self')
local I = require('openmw.interfaces')
print('REC door', self.recordId, tostring(I.AI))
return { engineHandlers = { onActivated = function(actor) print('REC opened', actor.recordId) end } }
]])
write("scripts/g.lua", [[
local world = require('openmw.world')
local types = require('openmw.types')
return { engineHandlers = {
  onActorActive = function(a) if a.type == types.Creature then print('REC globalsaw', a.recordId) end end,
} }
]])
write("scripts/bad_global.lua", "local self = require('openmw.self')\nreturn {}\n")

mock.addObject({ id = "kagouti", objectType = tes3.objectType.creature, aiConfig = { fight = 90 }, health = 40, inventory = {} })
mock.addObject({ id = "fargoth", objectType = tes3.objectType.npc, aiConfig = { fight = 0 }, health = 30, inventory = {} })
mock.addObject({ id = "ex_door", objectType = tes3.objectType.door })
local rt = require("omwcompat")
rt.register({ mod = "Locals", root = SYN, scripts = {
    { flags = { "GLOBAL" }, path = "scripts/g.lua" },
    { flags = { "GLOBAL" }, path = "scripts/bad_global.lua" },
    { flags = { "CREATURE" }, path = "scripts/crea.lua" },
    { flags = { "ACTOR" }, path = "scripts/any_actor.lua" },
    { flags = { "DOOR", "MENU" }, path = "scripts/door.lua" },
} })
mock.fire("initialized", {})
local ext = mock.addCell({ id = "Seyda Neen", gridX = -2, gridY = -9 })
W.activeCell = ext
local crea = mock.placeRef(ext, "kagouti", { 0, 0, 0 })
local npc = mock.placeRef(ext, "fargoth", { 500, 0, 0 })
local door = mock.placeRef(ext, "ex_door", { 50, 0, 0 })
local player = mock.newPlayer(ext)
local cm = mock.addMobile(crea, { hp = 40, fight = 92, str = 45, strBase = 40, pkg = tes3.aiPackage.wander, sticky = true })
local nm = mock.addMobile(npc, { hp = 30 })
mock.addMobile(player, { hp = 100 })

local function recs(tag)
    local out = {}
    for _, l in ipairs(W.logs) do
        local rest = l:match("^%[Locals%] REC " .. tag .. "\t?(.*)$")
        if rest then out[#out + 1] = rest end
    end
    return out
end
local function last(tag) local r = recs(tag); return r[#r] end

section("attach")
mock.fire("loaded", { newGame = true })
mock.frames(3, 0.1)
check(#recs("chunk") == 1 and last("chunk") == "kagouti", "CREATURE script attached once, to the creature only")
check(last("noworld") == "false", "openmw.world is not available to local scripts")
check(#recs("init") == 1, "onInit runs on first attach")
check(#recs("active") == 1, "onActive after attach")
check(last("stats") == "40\t40\t90\t92\t2\t40\t45\tfalse", "stats: health from mobile, fight base from aiConfig, modified from mobile, attributes, isDead (got " .. tostring(last("stats")) .. ")")
check(last("self") == "true\ttrue\ttrue\ttrue", "self is a Creature GameObject equal to self.object, isActive")
check(last("nearby") == "1\ttrue\ttrue\t1", "nearby.actors: the NPC, self and the player; nearby.doors (got " .. tostring(last("nearby")) .. ")")
check(last("pkg") == "Wander", "I.AI.getActivePackage maps the aiPlanner package")
local actorRecs = recs("actor")
check(#actorRecs == 2, "ACTOR script attached to the NPC and the creature, not the player (got " .. #actorRecs .. ")")
check(last("door") == "ex_door\tnil", "DOOR script attached to the door; I.AI is nil outside actor scripts")
local badGlobal = false
for _, l in ipairs(W.logs) do if l:find("bad_global.lua", 1, true) and l:find("openmw.self", 1, true) then badGlobal = true end end
check(badGlobal, "a GLOBAL script cannot require openmw.self")
local playerWarn = false
for _, l in ipairs(W.logs) do if l:find("MENU of scripts/door.lua are not hosted", 1, true) then playerWarn = true end end
check(playerWarn, "unhosted flags are reported, hosted flags of the same script still attach")
check(last("globalsaw") == "kagouti", "global onActorActive still runs next to local scripts")

section("events, I.AI, writes")
-- GameObject:sendEvent delivers to the object's local scripts
local wcrea = rt.objects.wrap(crea)
wcrea:sendEvent("Attack", { target = rt.objects.wrap(npc) })
mock.frames(1, 0.1)
check(#cm.combatCalls == 1 and cm.combatCalls[1] == nm, "startPackage{Combat} -> mobile:startCombat(target mobile)")
check(last("attacked") == "Combat\ttrue", "getActivePackage reports Combat with its target")
check(cm.health.current == 7, "health.current write -> tes3.setStatistic")
check(cm.fight == 95, "fight.modifier write -> base + modifier on the mobile")

section("activation")
mock.activate(player, door)
check(last("opened") == "player", "onActivated(actor) on the activated object's local script")

section("deactivate / reactivate")
mock.fire("referenceDeactivated", { reference = crea })
mock.frames(2, 0.1)
check(#recs("inactive") == 1, "referenceDeactivated -> onInactive")
mock.fire("referenceActivated", { reference = crea })
mock.frames(1, 0.1)
check(#recs("init") == 1, "no second onInit on reactivation")
local l = last("load")
local n = tonumber(l and l:match("\t(%d+)$"))
check(n and n >= 4, "onLoad(saved data) on reactivation (got " .. tostring(l) .. ")")
check(#recs("chunk") == 2, "the chunk runs again on reactivation")

section("save / load")
local snap = mock.save()
mock.load(snap)
for _, c in ipairs(W.cells) do
    for _, r in ipairs(c._refs) do
        if r.object.id == "kagouti" then crea = r; cm = mock.addMobile(r, { hp = 40, fight = 90 }) end
        if r.object.id == "fargoth" then npc = r; mock.addMobile(r, { hp = 30 }) end
    end
end
mock.addMobile(tes3.player, { hp = 100 })
mock.frames(2, 0.1)
local l2 = last("load")
local n2 = tonumber(l2 and l2:match("\t(%d+)$"))
check(n2 and n2 > n, "per-object onSave data survives a save/load (got " .. tostring(l2) .. ")")
check(#recs("init") == 1, "no onInit after load for an initialized object")
local npcData = rawget(npc, "_data")
check(npcData == nil or npcData.omwcompat_id == nil, "objects whose scripts keep nothing get no id written")

section("disable")
local before = #recs("inactive")
crea:disable()
mock.frames(1, 0.1)
check(#recs("inactive") == before + 1, "a disabled object's scripts become inactive")

section("errors")
local errs = {}
for _, line in ipairs(W.logs) do
    if line:find("ERROR", 1, true) and not line:find("bad_global", 1, true) then errs[#errs + 1] = line end
end
check(#errs == 0, "no runtime errors besides the intentional bad_global (" .. (errs[1] or "") .. ")")
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
