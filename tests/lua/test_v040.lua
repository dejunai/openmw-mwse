-- omwcompat 0.4.0: the per-mod Enabled switch, CUSTOM scripts (addScript / removeScript /
-- hasScript), PLAYER scripts (onFrame, onKeyPress, onQuestUpdate, openmw.ui/ambient/input),
-- and the new GameObject / types / core / nearby members.
-- Run from staging/LeaveTheLightsOff via tests/run_lua_tests.sh. Written for omwcompat by dej (dejunai).
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local mock = require("mock_mwse").install({})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end
local function section(s) print("\n== " .. s) end

local SYN = (os.getenv("TMPDIR_SYNTH") or "/tmp/omwcompat-synth") .. "-v040/"
os.execute("mkdir -p '" .. SYN .. "scripts'")
local function write(rel, text)
    local f = assert(io.open(SYN .. rel, "w")); f:write(text); f:close()
end

write("scripts/g.lua", [[
local world = require('openmw.world')
local types = require('openmw.types')
local core = require('openmw.core')
local async = require('openmw.async')
local ticks, loadedN = 0, 0
local cb = async:registerTimerCallback('tick', function(a) print('REC timer', a) end)
return {
  interfaceName = 'V040', interface = {
    ticks = function() return ticks end,
    timer = function(d) async:newSimulationTimer(d, cb, 'fired') end,
    add = function(o, data) o:addScript('scripts/custom.lua', data) end,
    remove = function(o) o:removeScript('scripts/custom.lua') end,
    has = function(o, p) return o:hasScript(p) end,
    eval = function(fn, ...) return fn(world, types, core, ...) end,
  },
  engineHandlers = {
    onInit = function() print('REC ginit') end,
    onUpdate = function(dt) ticks = ticks + 1 end,
    onSave = function() return { n = ticks + loadedN } end,
    onLoad = function(d) loadedN = d and d.n or 0; print('REC gload', loadedN) end,
  },
}
]])
write("scripts/custom.lua", [[
local self = require('openmw.self')
local n, base = 0, 0
return { engineHandlers = {
  onInit = function(d) print('REC cinit', self.recordId, d and d.robe or 'nil') end,
  onLoad = function(d) base = d and d.n or 0; print('REC cload', self.recordId, base) end,
  onActive = function() print('REC cactive', self.recordId) end,
  onUpdate = function() n = n + 1 end,
  onSave = function() return { n = n + base } end,
} }
]])
write("scripts/p.lua", [[
local self = require('openmw.self')
local ui = require('openmw.ui')
local ambient = require('openmw.ambient')
local input = require('openmw.input')
local types = require('openmw.types')
local frames = 0
return { engineHandlers = {
  onInit = function()
    ui.showMessage('hello from p')
    ambient.playSound('Fire', { volume = 0.5 })
    print('REC pinit', types.Player.objectIsInstance(self), tostring(types.NPC.objectIsInstance(self)))
  end,
  onFrame = function(dt) frames = frames + 1; if frames == 2 then print('REC frame', tostring(dt >= 0)) end end,
  onKeyPress = function(k)
    print('REC key', k.symbol, k.code, tostring(k.withShift), tostring(input.isKeyPressed(input.KEY.H)),
      tostring(self.controls.sneak))
  end,
  onKeyRelease = function(k) print('REC keyup', k.symbol) end,
  onQuestUpdate = function(q, s) print('REC quest', q, s) end,
} }
]])
write("scripts/n.lua", "return { engineHandlers = { onUpdate = function() end } }\n")

mock.addObject({ id = "fargoth", objectType = tes3.objectType.npc, inventory = {}, level = 4 })
mock.addObject({ id = "chest", objectType = tes3.objectType.container, inventory = {} })
mock.addObject({ id = "rock", objectType = tes3.objectType.static })
mock.addObject({ id = "iron dagger", objectType = tes3.objectType.weapon, type = 0, value = 10, weight = 3 })
mock.addObject({ id = "iron arrow", objectType = tes3.objectType.ammunition, type = 12, value = 1, weight = 0.1 })
mock.addObject({ id = "netch shield", objectType = tes3.objectType.armor, slot = 8, value = 20, weight = 5 })
mock.addObject({ id = "common robe", objectType = tes3.objectType.clothing, slot = 4, value = 5, weight = 1 })
mock.addObject({ id = "ring a", objectType = tes3.objectType.clothing, slot = 8, value = 5, weight = 0 })
mock.addObject({ id = "ring b", objectType = tes3.objectType.clothing, slot = 8, value = 5, weight = 0 })
mock.addObject({ id = "gold_001", objectType = tes3.objectType.miscItem, value = 1, weight = 0 })
mock.addObject({ id = "ex_door", objectType = tes3.objectType.door })
mock.addFaction({ id = "Fighters Guild", name = "Fighters Guild",
    ranks = { { attributes = { 30, 30 }, skill = 10, favoredSkill = 5, reputation = 0 },
              { attributes = { 35, 35 }, skill = 20, favoredSkill = 10, reputation = 10 } },
    getRankName = function(_, i) return ({ [0] = "Associate", "Apprentice" })[i] end,
    reactions = {}, attributes = { 0, 5 }, skills = { 5, 6 } })

local rt = require("omwcompat")
local objects = require("omwcompat.objects")
rt.register({ mod = "Main", root = SYN, scripts = {
    { flags = { "GLOBAL" }, path = "scripts/g.lua" },
    { flags = { "CUSTOM" }, path = "scripts/custom.lua" },
    { flags = { "PLAYER" }, path = "scripts/p.lua" },
} })
rt.register({ mod = "NoOpts", root = SYN, scripts = { { flags = { "GLOBAL" }, path = "scripts/n.lua" } } })
mock.fire("initialized", {})
local ext = mock.addCell({ id = "Seyda Neen", gridX = -2, gridY = -9 })
W.activeCell = ext
local npc = mock.placeRef(ext, "fargoth", { 500, 0, 0 })
local chest = mock.placeRef(ext, "chest", { 100, 0, 0 })
local rock = mock.placeRef(ext, "rock", { 200, 0, 0 })
local door = mock.placeRef(ext, "ex_door", { 300, 0, 0 })
local player = mock.newPlayer(ext)
local nm = mock.addMobile(npc, { hp = 30 })
local pm = mock.addMobile(player, { hp = 100 })
tes3.mobilePlayer = pm
pm.bounty, pm.levelUpProgress = 40, 3

local function recs(tag)
    local out = {}
    for _, l in ipairs(mock.allLogs()) do
        local rest = l:match("^%[Main%] REC " .. tag .. "\t?(.*)$")
        if rest then out[#out + 1] = rest end
    end
    return out
end
local function last(tag) local r = recs(tag); return r[#r] end
local function errors()
    local out = {}
    for _, l in ipairs(mock.allLogs()) do if l:find("ERROR", 1, true) or l:find("error in", 1, true) then out[#out + 1] = l end end
    return out
end

mock.fire("modConfigReady", {})
mock.fire("loaded", { newGame = true })
mock.frames(3, 0.1)
local V = rt.getInterface("V040")
local function eval(fn, ...) return V.eval(fn, ...) end
local wnpc, wchest, wrock, wplayer = objects.wrap(npc), objects.wrap(chest), objects.wrap(rock), objects.wrap(player)

section("Enabled switch in the MCM")
local tpl = rt.mcmTemplate
local enabledControls = {}
for _, c in ipairs(mock.mcmControls(tpl)) do if c.label == "Mod enabled" then enabledControls[#enabledControls + 1] = c end end
check(#enabledControls == 2, "every converted mod's tab has an Enabled switch, also a mod without settings (" .. #enabledControls .. ")")
local function tabOf(title)
    for _, page in ipairs(tpl.children) do if page.label == title then return page end end
end
local noOpts = tabOf("NoOpts")
check(noOpts and noOpts.children[1] and noOpts.children[1].label == "Mod enabled", "Enabled is the first control of the tab")
local noOptsText = false
for _, c in ipairs(noOpts and noOpts.children or {}) do if c.text == "This mod has no other settings." then noOptsText = true end end
check(noOptsText, "a mod without settings says it has no other settings")
check(noOpts.children[1].description:find("No reload is needed", 1, true) ~= nil, "the switch description explains it needs no reload")
check(tabOf("Disclaimer") ~= nil or tpl.children[1].label ~= nil, "the disclaimer tab is still there")
local mainSwitch
for _, c in ipairs(enabledControls) do if c ~= noOpts.children[1] then mainSwitch = c end end
check(mock.mcmGet(mainSwitch) == true, "Enabled defaults to on")

section("PLAYER scripts")
check(last("pinit") == "true\ttrue", "PLAYER script attached to the player; Player is an NPC (got " .. tostring(last("pinit")) .. ")")
check(W.messages[#W.messages] == "hello from p", "ui.showMessage -> tes3.messageBox")
local snd = nil
for _, s in ipairs(W.sounds) do if s.sound == "Fire" then snd = s end end
check(snd and snd.volume == 0.5 and snd.ref == nil, "ambient.playSound -> tes3.playSound without a reference")
check(last("frame") == "true", "onFrame runs every frame")
mock.setKeyDown(35, true)    -- DIK_H
nm.isSneaking = false; pm.isSneaking = true
mock.fire("keyDown", { keyCode = 35, isShiftDown = true })
check(last("key") == "h\t11\ttrue\ttrue\ttrue", "onKeyPress: symbol, SDL code, modifiers; input.isKeyPressed; self.controls.sneak (got " .. tostring(last("key")) .. ")")
W.menuMode = true
mock.fire("keyDown", { keyCode = 35 })
W.menuMode = false
check(#recs("key") == 1, "no key events while a menu is open")
mock.fire("keyUp", { keyCode = 35 })
check(last("keyup") == "h", "onKeyRelease")
tes3.updateJournal({ id = "A1_1_FindSpymaster", index = 10 })
check(last("quest") == "a1_1_findspymaster\t10", "onQuestUpdate(questId, stage) from the journal event")

section("CUSTOM scripts: addScript / hasScript / removeScript")
check(V.has(wnpc, "scripts/custom.lua") == false, "hasScript false before addScript")
V.add(wnpc, { robe = "common robe" })
check(V.has(wnpc, "scripts/custom.lua") == true, "hasScript true right after addScript")
check(#recs("cinit") == 0, "the script starts on the next frame")
mock.frames(2, 0.1)
check(last("cinit") == "fargoth\tcommon robe", "onInit gets initData")
check(last("cactive") == "fargoth", "onActive after attach")
V.add(wnpc, {})
mock.frames(1, 0.1)
check(#recs("cinit") == 1, "adding the same script twice is ignored")
check(not pcall(V.add, wrock, {}), "addScript on a Static raises")
check(not pcall(V.add, wnpc, nil) == false, "addScript with no initData is fine")
check(not pcall(function() wnpc:addScript("scripts/nope.lua") end), "addScript of a non-CUSTOM path raises")
check(V.has(wplayer, "scripts/p.lua") == true, "hasScript sees PLAYER scripts on the player")
mock.frames(5, 0.1)
local snap = mock.save()
mock.load(snap)
mock.frames(2, 0.1)
local cl = last("cload") or ""
check(cl:match("^fargoth\t(%d+)$") and tonumber(cl:match("(%d+)$")) >= 6, "a CUSTOM script comes back after load with its onSave data (got " .. cl .. ")")
check(#recs("cinit") == 1, "no second onInit after load")
wnpc = objects.wrap(npc)
check(V.has(objects.wrap(npc), "scripts/custom.lua") == true, "the attachment is saved")
V = rt.getInterface("V040")
V.remove(wnpc)
check(V.has(wnpc, "scripts/custom.lua") == false, "removeScript detaches")
check(not pcall(V.remove, wnpc), "removeScript of a script that is not attached raises")

section("Enabled switch: off and on mid-game")
local before = V.ticks()
local logsAt = #mock.allLogs()
V.timer(0.25)
mock.mcmSet(mainSwitch, false)
check(W.config and W.config["omwcompat_Main"] and W.config["omwcompat_Main"].enabled == false, "the switch is saved per mod")
mock.frames(5, 0.1)
check(V.ticks() == before, "global onUpdate stops")
local fired = false
local _logs = mock.allLogs()
for i = logsAt + 1, #_logs do if _logs[i]:find("REC timer", 1, true) then fired = true end end
check(not fired, "timers stop")
local nKeys = #recs("key")
mock.fire("keyDown", { keyCode = 35 })
check(#recs("key") == nKeys, "player handlers stop")
tes3.updateJournal({ id = "A1_1_FindSpymaster", index = 20 })
check(last("quest") == "a1_1_findspymaster\t10", "onQuestUpdate stops")
local frozenSnap = mock.save()
check(type(tes3.player.data["omwcompat_Main"]) == "string", "saving while off keeps the mod's state")
mock.mcmSet(mainSwitch, true)
check(mock.mcmGet(mainSwitch) == true, "switch back on")
mock.frames(3, 0.1)
check(#recs("gload") >= 2, "on: global scripts start again with onLoad")
check(#recs("pinit") == 1, "player script reloads its state (no second onInit)")
mock.fire("keyDown", { keyCode = 35 })
check(#recs("key") == nKeys + 1, "player handlers run again")
check(V.ticks() > 0, "global onUpdate runs again")

section("load while off")
mock.mcmSet(mainSwitch, false)
local gl = #recs("gload")
mock.load(frozenSnap)
mock.frames(2, 0.1)
check(#recs("gload") == gl and #recs("ginit") == 1, "a disabled mod is not started on load")
local rawBefore = tes3.player.data["omwcompat_Main"]
mock.save()
check(type(rawBefore) == "string" and tes3.player.data["omwcompat_Main"] == rawBefore, "its saved state is written back unchanged")
mock.mcmSet(mainSwitch, true)
mock.frames(2, 0.1)
check(#recs("gload") == gl + 1, "switching on after a load starts it from the saved state")
V = rt.getInterface("V040")
-- mock.load rebuilt the references: look them up again and give the actors mobiles
local function refOfId(id) for _, x in ipairs(ext._refs) do if not x._gone and x.object.id == id then return x end end end
npc, chest, rock, door, player = refOfId("fargoth"), refOfId("chest"), refOfId("rock"), refOfId("ex_door"), tes3.player
nm = mock.addMobile(npc, { hp = 30 })
pm = mock.addMobile(player, { hp = 100 })
tes3.mobilePlayer = pm
pm.bounty, pm.levelUpProgress = 40, 3
wnpc, wchest, wrock, wplayer = objects.wrap(npc), objects.wrap(chest), objects.wrap(rock), objects.wrap(player)

section("types / GameObject members")
local r = eval(function(world, types)
    local n = 0
    for k, T in pairs(types) do if type(T) == "table" and T.baseType == types.Item then n = n + 1 end end
    return n
end)
check(r >= 5, "pairs(openmw.types) iterates the types; baseType == Item (" .. tostring(r) .. ")")
r = { eval(function(_, types, _, d, c) return types.Lockable.objectIsInstance(d), types.Door.baseType == types.Lockable,
    types.Container.baseType == types.Lockable, types.NPC.baseType == types.Actor, types.Player.baseType == types.NPC end,
    objects.wrap(door), wchest) }
check(r[1] == true and r[2] and r[3] and r[4] and r[5], "Lockable / Actor / NPC base types")
eval(function(_, types, _, d) types.Lockable.lock(d, 40) end, objects.wrap(door))
r = { eval(function(_, types, _, d) return types.Lockable.isLocked(d), types.Lockable.getLockLevel(d) end, objects.wrap(door)) }
check(r[1] == true and r[2] == 40, "Lockable.lock / isLocked / getLockLevel")
eval(function(_, types, _, d) types.Lockable.unlock(d) end, objects.wrap(door))
check(eval(function(_, types, _, d) return types.Lockable.isLocked(d) end, objects.wrap(door)) == false, "Lockable.unlock")
eval(function(_, _, _, c) c.owner.recordId = "fargoth" end, wchest)
check(chest.owner and chest.owner.id == "fargoth" and chest.modified, "owner.recordId = id -> tes3.setOwner")
check(eval(function(_, _, _, c) return c.owner.recordId end, wchest) == "fargoth", "owner.recordId reads tes3.getOwner")
check(eval(function(_, _, _, c) return c.startingCell end, wchest) ~= nil, "startingCell")
check(not pcall(eval, function(_, _, _, c) return c.globalVariable end, wchest), "globalVariable raises (unsupported)")

section("Inventory")
tes3.addItem({ reference = npc, item = "iron dagger", count = 1 })
tes3.addItem({ reference = npc, item = "gold_001", count = 25 })
tes3.addItem({ reference = npc, item = "netch shield", count = 1 })
r = { eval(function(_, types, _, a)
    local inv = types.Actor.inventory(a)
    local g = inv:find("gold_001")
    return #inv:getAll(), #inv:getAll(types.Weapon), g and g.count, #inv:findAll("gold_001"), inv:find("nothing") == nil,
        g and g.type == types.Miscellaneous
end, wnpc) }
check(r[1] == 3 and r[2] == 1 and r[3] == 25 and r[4] == 1 and r[5] and r[6], "getAll / getAll(type) / find / findAll (" ..
    table.concat({ tostring(r[1]), tostring(r[2]), tostring(r[3]), tostring(r[4]) }, ",") .. ")")
eval(function(_, types, _, a) types.Actor.inventory(a):find("gold_001"):remove(5) end, wnpc)
check(eval(function(_, types, _, a) return types.Actor.inventory(a):countOf("gold_001") end, wnpc) == 20, "item:remove(n) -> tes3.removeItem")
eval(function(_, types, _, a, c) types.Actor.inventory(a):find("gold_001"):moveInto(types.Container.inventory(c)) end, wnpc, wchest)
check(eval(function(_, types, _, c) return types.Container.inventory(c):countOf("gold_001") end, wchest) == 20, "item:moveInto -> tes3.transferItem")

section("Equipment / stance / level / skills")
eval(function(_, types, _, a)
    local inv = types.Actor.inventory(a)
    types.Actor.setEquipment(a, { [types.Actor.EQUIPMENT_SLOT.CarriedRight] = inv:find("iron dagger"),
        [types.Actor.EQUIPMENT_SLOT.CarriedLeft] = "netch shield" })
end, wnpc)
r = { eval(function(_, types, _, a)
    local eq = types.Actor.getEquipment(a)
    local S = types.Actor.EQUIPMENT_SLOT
    return eq[S.CarriedRight] and eq[S.CarriedRight].recordId, eq[S.CarriedLeft] and eq[S.CarriedLeft].recordId,
        types.Actor.getEquipment(a, S.Helmet) == nil, types.Actor.hasEquipped(a, "iron dagger")
end, wnpc) }
check(r[1] == "iron dagger" and r[2] == "netch shield" and r[3] and r[4], "setEquipment / getEquipment(slot) / hasEquipped")
eval(function(_, types, _, a) types.Actor.setEquipment(a, {}) end, wnpc)
check(#(npc.object.equipment or {}) == 0, "setEquipment({}) unequips everything")
check(not pcall(eval, function(_, types, _, a) types.Actor.setEquipment(a, { [16] = "iron arrow" }) end, wnpc),
    "setEquipment of an item not in the inventory raises")
nm.weaponReady = true
check(eval(function(_, types, _, a) return types.Actor.getStance(a) == types.Actor.STANCE.Weapon end, wnpc), "getStance (weaponReady)")
eval(function(_, types, _, a) types.Actor.setStance(a, types.Actor.STANCE.Spell) end, wnpc)
check(nm.castReady == true and nm.weaponReady == false, "setStance(Spell)")
check(eval(function(_, types, _, a) return types.Actor.stats.level(a).current end, wnpc) == 4, "stats.level.current")
check(eval(function(_, types, _, p) return types.Actor.stats.level(p).progress end, wplayer) == 3, "stats.level.progress (player)")
eval(function(_, types, _, a) types.NPC.stats.skills.block(a).base = 33 end, wnpc)
check(eval(function(_, types, _, a) return types.NPC.stats.skills.block(a).base end, wnpc) == 33, "NPC.stats.skills.<id>.base write -> tes3.setStatistic{skill=}, read -> getSkillStatistic")

section("Player functions")
r = { eval(function(_, types, _, p)
    return types.Player.isCharGenFinished(p), types.Player.getCrimeLevel(p), types.Player.quests(p)["A1_1_FindSpymaster"].stage,
        types.Player.quests(p)["A1_1_FindSpymaster"].started
end, wplayer) }
check(r[1] == true and r[2] == 40 and r[3] == 20 and r[4] == true, "isCharGenFinished / getCrimeLevel / quests[id].stage, started")
eval(function(_, types, _, p) types.Player.setCrimeLevel(p, 0); types.Player.quests(p)["mq"].stage = 5 end, wplayer)
check(pm.bounty == 0 and W.journal["mq"] == 5, "setCrimeLevel / quest.stage = n")

section("core.factions / core.sound / nearby.castRay")
r = { eval(function(_, _, core)
    local f = core.factions.records["fighters guild"]
    return f and f.name, f and #f.ranks, f and f.ranks[2].name, f and f.ranks[2].primarySkillValue, f and f.skills[1], f and f.hidden
end) }
check(r[1] == "Fighters Guild" and r[2] == 2 and r[3] == "Apprentice" and r[4] == 20 and r[5] == "longblade" and r[6] == false,
    "core.factions.records[id]: name, ranks, skills, hidden = false (" .. tostring(r[3]) .. "," .. tostring(r[5]) .. ")")
eval(function(_, _, core, a) core.sound.playSound3d("Fire", a, { volume = 2, loop = true }) end, wnpc)
snd = W.sounds[#W.sounds]
check(snd.sound == "Fire" and snd.ref == npc and snd.loop == true, "core.sound.playSound3d -> tes3.playSound on the reference")
check(eval(function(_, _, core, a) return core.sound.isSoundPlaying("Fire", a) end, wnpc) == true, "core.sound.isSoundPlaying")
-- nearby is a local-script module: exercise castRay through the actors module directly
local actors = require("omwcompat.actors")
local util = rt.util
W.rayHit = { intersection = { x = 1, y = 2, z = 3 }, normal = { x = 0, y = 0, z = 1 }, reference = chest }
r = actors.castRay(util.vector3(0, 0, 0), util.vector3(100, 0, 0), { ignore = wplayer })
check(r.hit and r.hitPos.z == 3 and r.hitObject == wchest and W.lastRay.maxDistance == 100 and W.lastRay.ignore[1] == player,
    "nearby.castRay -> tes3.rayTest (hitPos, hitObject, ignore, maxDistance)")
W.rayHit = nil
check(actors.castRay(util.vector3(0, 0, 0), util.vector3(0, 0, 100)).hit == false, "castRay: no hit")

section("built-in local events")
local nMsg = #W.messages
eval(function(_, _, _, p) p:sendEvent("ShowMessage", { message = "blocked" }) end, wplayer)
mock.frames(1, 0.1)
check(W.messages[#W.messages] == "blocked" and #W.messages == nMsg + 1, "player:sendEvent('ShowMessage') -> tes3.messageBox")
eval(function(_, _, _, a) a:sendEvent("ShowMessage", { message = "not shown" }) end, wnpc)
mock.frames(1, 0.1)
check(#W.messages == nMsg + 1, "ShowMessage to a non-player does nothing")
tes3.addItem({ reference = npc, item = "iron dagger", count = 1 })
eval(function(_, types, _, a) types.Actor.setEquipment(a, { [16] = "iron dagger" }) end, wnpc)
eval(function(_, types, _, a) a:sendEvent("Unequip", { slot = types.Actor.EQUIPMENT_SLOT.CarriedRight }) end, wnpc)
mock.frames(1, 0.1)
check(#(npc.object.equipment or {}) == 0, "actor:sendEvent('Unequip', {slot}) -> mobile:unequip")
eval(function(_, _, _, a) a:sendEvent("PlaySound3d", { sound = "Hurt" }) end, wnpc)
mock.frames(1, 0.1)
check(W.sounds[#W.sounds].sound == "Hurt" and W.sounds[#W.sounds].ref == npc, "sendEvent('PlaySound3d') -> playSound3d on the object")

section("mwscript globals / addTopic")
W.globals.gamehour = { id = "GameHour", value = 9 }
check(eval(function(world) return world.mwscript.getGlobalVariables().gamehour end) == 9, "getGlobalVariables()[name] reads tes3.findGlobal")
eval(function(world) world.mwscript.getGlobalVariables().GameHour = 13 end)
check(W.globals.gamehour.value == 13, "assigning writes the global")
W.topics = {}
tes3.addTopic = function(p) W.topics[#W.topics + 1] = p.topic; return true end
eval(function(_, types, _, p) types.Player.addTopic(p, "Some Work") end, wplayer)
check(W.topics[1] == "Some Work", "types.Player.addTopic -> tes3.addTopic")
check(not pcall(eval, function(_, types, _, a) types.Player.addTopic(a, "x") end, wnpc), "addTopic on a non-player raises")

section("enabled setter / saved inventory items")
eval(function(_, _, _, c) c.enabled = false end, wchest)
check(chest.disabled == true, "obj.enabled = false -> ref:disable()")
eval(function(_, _, _, c) c.enabled = true end, wchest)
check(chest.disabled == false, "obj.enabled = true -> ref:enable()")
eval(function(_, types, _, a) types.Actor.inventory(a):find("iron dagger").enabled = false end, wnpc)
check(true, "enabled on an inventory item is ignored (no error)")
local objects2 = require("omwcompat.objects")
local item = objects2.fromId("inv:" .. rawget(wchest, "_id") .. ":gold_001")   -- never wrapped before
check(item.recordId == "gold_001" and item.count == 20 and item.parentContainer == wchest,
    "an inventory item id read back from a save is an inventory item again")
check(objects2.fromId("inv:" .. rawget(wnpc, "_id") .. ":iron dagger:split").recordId == "iron dagger", "a saved split view comes back as the stack")

section("errors")
local errs = errors()
check(#errs == 0, "no runtime errors logged (" .. tostring(errs[1]) .. ")")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
