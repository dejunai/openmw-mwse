-- omwcompat.actors: actor-facing OpenMW APIs for local (object-attached) scripts.
--   types.Actor.stats.dynamic.<health|magicka|fatigue>(actor)  -> mobile.<stat> (tes3statistic)
--   types.Actor.stats.attributes.<name>(actor)                 -> mobile.<name>  (tes3statistic)
--   types.Actor.stats.ai.<fight|flee|alarm|hello>(actor)       -> mobile.<stat>, base from aiConfig
--   types.Actor.isDead(actor)                                  -> mobile.isDead
--   types.NPC.getFactions / getFactionRank / isExpelled        -> npc.faction / factionRank, player faction flags
--   types.NPC.getDisposition / getBaseDisposition (0.4.2)       -> npc instance .disposition / .baseDisposition
--   openmw.nearby                                              -> references in tes3.getActiveCells()
--   I.AI (actor local scripts)                                 -> mobile:startCombat / tes3.setAI* / aiPlanner
--   openmw.animation, I.AnimationController                    -> vanilla groups via tes3.playAnimation /
--                                                                 animationData (0.5.0); the rest quiet no-ops
--   self.controls                                              -> mobile state reads; yawChange / run / sneak /
--                                                                 jump writes on NPCs and creatures (0.5.0)
-- Every mapping is by rule (OpenMW name -> MWSE field), never per mod. Actors whose
-- mobile is not loaded (outside the active cells) fall back to their base record values.
-- MIT, Copyright (c) 2026 dej (dejunai).
local M = {}
local objects, rt

function M.init(runtime, objs) rt, objects = runtime, objs end

local function mobileOf(o)
    local ref = objects.refOf(o)
    if not ref then return nil, nil end
    local ok, mob = pcall(function() return ref.mobile end)
    return ok and mob or nil, ref
end
M.mobileOf = mobileOf

local function baseObject(ref)
    local o = ref and ref.object
    if not o then return nil end
    local ok, b = pcall(function() return o.baseObject end)
    return (ok and b) or o
end

---------------------------------------------------------------- dynamic stats
local DYNAMIC = { health = "health", magicka = "magicka", fatigue = "fatigue" }
local function dynamicStat(key)
    return function(actor)
        local mob, ref = mobileOf(actor)
        if not ref then error("types.Actor.stats.dynamic." .. key .. ": invalid actor", 2) end
        return setmetatable({}, {
            __index = function(_, k)
                local m2 = mobileOf(actor)
                local st = m2 and m2[key]
                if k == "current" then
                    if st then return st.current end
                    local b = baseObject(ref); return b and b[key] or 0
                elseif k == "base" then
                    if st then return st.base end
                    local b = baseObject(ref); return b and b[key] or 0
                elseif k == "modifier" then
                    return 0
                end
                return nil
            end,
            __newindex = function(_, k, v)
                local r = objects.refOf(actor)
                if not r then error("types.Actor.stats.dynamic." .. key .. ": invalid actor", 2) end
                if k == "current" then tes3.setStatistic({ reference = r, name = key, current = v })
                elseif k == "base" then tes3.setStatistic({ reference = r, name = key, base = v })
                else error("omwcompat: dynamic stat field " .. tostring(k) .. " is not writable", 2) end
            end,
        })
    end
end

---------------------------------------------------------------- attributes
local ATTRIBUTES = { "strength", "intelligence", "willpower", "agility", "speed", "endurance", "personality", "luck" }
local function attributeStat(key)
    return function(actor)
        local _, ref = mobileOf(actor)
        if not ref then error("types.Actor.stats.attributes." .. key .. ": invalid actor", 2) end
        return setmetatable({}, {
            __index = function(_, k)
                local m2 = mobileOf(actor)
                local st = m2 and m2[key]
                if not st then return (k == "base" or k == "modified") and 0 or (k == "modifier" or k == "damage") and 0 or nil end
                if k == "base" then return st.base
                elseif k == "modified" then return st.current
                elseif k == "modifier" then return st.current - st.base
                elseif k == "damage" then return 0 end
                return nil
            end,
            __newindex = function(_, k, v)
                local r = objects.refOf(actor)
                if not r then error("types.Actor.stats.attributes." .. key .. ": invalid actor", 2) end
                if k == "base" then tes3.setStatistic({ reference = r, name = key, base = v })
                elseif k == "modifier" then
                    local m2 = mobileOf(actor)
                    local st = m2 and m2[key]
                    tes3.setStatistic({ reference = r, name = key, current = (st and st.base or 0) + v })
                else error("omwcompat: attribute field " .. tostring(k) .. " is not writable", 2) end
            end,
        })
    end
end

---------------------------------------------------------------- AI stats
local AISTATS = { fight = "fight", flee = "flee", alarm = "alarm", hello = "hello" }
local function aiStat(key)
    return function(actor)
        local _, ref = mobileOf(actor)
        if not ref then error("types.Actor.stats.ai." .. key .. ": invalid actor", 2) end
        local function base()
            local b = baseObject(ref)
            local ok, v = pcall(function() return b.aiConfig[key] end)
            return ok and v or 0
        end
        local function modified()
            local m2 = mobileOf(actor)
            if m2 and m2[key] ~= nil then return m2[key] end
            return base()
        end
        return setmetatable({}, {
            __index = function(_, k)
                if k == "base" then return base()
                elseif k == "modified" then return modified()
                elseif k == "modifier" then return modified() - base() end
                return nil
            end,
            __newindex = function(_, k, v)
                local m2 = mobileOf(actor)
                if not m2 then error("types.Actor.stats.ai." .. key .. ": actor is not active", 2) end
                -- MWSE keeps one live value per actor; the record base is shared by every instance.
                if k == "modifier" then m2[key] = base() + v
                elseif k == "base" then m2[key] = v + (modified() - base())
                else error("omwcompat: AI stat field " .. tostring(k) .. " is not writable", 2) end
            end,
        })
    end
end

function M.isDead(actor)
    local mob, ref = mobileOf(actor)
    if mob then
        local ok, d = pcall(function() return mob.isDead end)
        if ok and d ~= nil then return d == true end
        local h = mob.health
        return h ~= nil and h.current <= 0
    end
    return false
end

---------------------------------------------------------------- factions
-- types.NPC.getFactions(actor) -> list of lower-case faction ids the NPC is a member of
-- (OpenMW: expelled state not taken into account). A regular NPC has at most one faction
-- (its record's); the player has every faction with playerJoined set.
-- types.NPC.getFactionRank(actor, id) -> rank index from 1, 0 if not a member; raises for an
-- unknown faction id like OpenMW. types.NPC.isExpelled(actor, id): the player's
-- playerExpelled flag; NPCs are never expelled in vanilla data (false).
local function lowerId(x) return type(x) == "string" and x:lower() or nil end
local function factionList()
    local ok, list = pcall(function() return tes3.dataHandler.nonDynamicData.factions end)
    return ok and list or nil
end
local function factionOf(id)
    local f
    if type(id) == "string" and tes3.getFaction then
        local ok, r = pcall(tes3.getFaction, id)
        if ok then f = r end
    end
    if not f and type(id) == "string" then
        local want = id:lower()
        local list = factionList()
        if list then
            for _, x in ipairs(list) do if lowerId(x.id) == want then f = x; break end end
        end
    end
    if not f then error("no such faction: " .. tostring(id), 3) end
    return f
end
local function isPlayerRef(ref) return ref ~= nil and ref == tes3.player end
local function npcFaction(ref)
    local o = ref and ref.object
    if not o then return nil, nil end
    local ok, f, r = pcall(function() return o.faction, o.factionRank end)
    if not ok or not f then
        local b = baseObject(ref)
        ok, f, r = pcall(function() return b.faction, b.factionRank end)
        if not ok then return nil, nil end
    end
    return f, r
end
function M.getFactions(actor)
    local ref = objects.refOf(actor)
    local out = {}
    if not ref then return out end
    if isPlayerRef(ref) then
        for _, f in ipairs(factionList() or {}) do
            if f.playerJoined then out[#out + 1] = lowerId(f.id) end
        end
        return out
    end
    local f = npcFaction(ref)
    if f and f.id then out[1] = lowerId(f.id) end
    return out
end
function M.getFactionRank(actor, id)
    local fac = factionOf(id)
    local ref = objects.refOf(actor)
    if not ref then return 0 end
    if isPlayerRef(ref) then
        if not fac.playerJoined then return 0 end
        return (tonumber(fac.playerRank) or 0) + 1
    end
    local f, rank = npcFaction(ref)
    if not f or lowerId(f.id) ~= lowerId(fac.id) then return 0 end
    return (tonumber(rank) or 0) + 1
end
function M.isExpelled(actor, id)
    local fac = factionOf(id)
    local ref = objects.refOf(actor)
    if isPlayerRef(ref) then return fac.playerExpelled == true end
    return false
end


---------------------------------------------------------------- equipment (0.4.0)
-- EQUIPMENT_SLOT values follow OpenMW's slot order. An equipped MWSE item is put in the slot
-- OpenMW uses for it: armor by record.slot (bracers -> gauntlet slots, shield -> CarriedLeft),
-- clothing by record.slot (shoes -> Boots, gloves -> gauntlet slots, the first ring
-- LeftRing and the second RightRing), arrows/bolts -> Ammunition, other weapons, lockpicks
-- and probes -> CarriedRight, lights -> CarriedLeft. Items are inventory GameObjects.
local SLOT = { Helmet = 0, Cuirass = 1, Greaves = 2, LeftPauldron = 3, RightPauldron = 4, LeftGauntlet = 5,
    RightGauntlet = 6, Boots = 7, Shirt = 8, Pants = 9, Skirt = 10, Robe = 11, LeftRing = 12, RightRing = 13,
    Amulet = 14, Belt = 15, CarriedRight = 16, CarriedLeft = 17, Ammunition = 18 }
M.EQUIPMENT_SLOT = SLOT
local ARMOR_SLOT = { [0] = SLOT.Helmet, SLOT.Cuirass, SLOT.LeftPauldron, SLOT.RightPauldron, SLOT.Greaves, SLOT.Boots,
    SLOT.LeftGauntlet, SLOT.RightGauntlet, SLOT.CarriedLeft, SLOT.LeftGauntlet, SLOT.RightGauntlet }
local CLOTHING_SLOT = { [0] = SLOT.Pants, SLOT.Boots, SLOT.Shirt, SLOT.Belt, SLOT.Robe, SLOT.RightGauntlet,
    SLOT.LeftGauntlet, SLOT.Skirt, "ring", SLOT.Amulet }
local function slotOf(item, ringsSeen)
    local ot = tes3.objectType
    local t = item.objectType
    if t == ot.armor then return ARMOR_SLOT[item.slot] end
    if t == ot.clothing then
        local sl = CLOTHING_SLOT[item.slot]
        if sl == "ring" then return ringsSeen == 0 and SLOT.LeftRing or SLOT.RightRing end
        return sl
    end
    if t == ot.ammunition then return SLOT.Ammunition end
    if t == ot.weapon then
        if item.type == 12 or item.type == 13 then return SLOT.Ammunition end
        return SLOT.CarriedRight
    end
    if t == ot.lockpick or t == ot.probe then return SLOT.CarriedRight end
    if t == ot.light then return SLOT.CarriedLeft end
    return nil
end
local function idOf(x) return type(x) == "string" and x:lower() or nil end
function M.getEquipment(actor, slot)
    local ref = objects.refOf(actor)
    if not ref then error("types.Actor.getEquipment: invalid actor", 2) end
    local out, rings = {}, 0
    local ok, eq = pcall(function() return ref.object.equipment end)
    if ok and eq then
        for _, st in pairs(eq) do
            local it = st.object
            if it then
                local sl = slotOf(it, rings)
                if sl == SLOT.LeftRing or sl == SLOT.RightRing then rings = rings + 1 end
                if sl and out[sl] == nil then out[sl] = objects.invItem(objects.wrap(ref), idOf(it.id)) end
            end
        end
    end
    if slot ~= nil then return out[slot] end
    return out
end
function M.hasEquipped(actor, item)
    local want = type(item) == "string" and item:lower() or (item and item.recordId)
    for _, it in pairs(M.getEquipment(actor)) do if it.recordId == want then return true end end
    return false
end
-- setEquipment: only on an active actor (it needs the mobile): items no longer listed are
-- unequipped (mobile:unequip), listed ones equipped from the inventory (mobile:equip). An item
-- that is not in the inventory raises, as in OpenMW.
function M.setEquipment(actor, tbl)
    if type(tbl) ~= "table" then error("types.Actor.setEquipment: equipment must be a table", 2) end
    local mob, ref = mobileOf(actor)
    if not ref then error("types.Actor.setEquipment: invalid actor", 2) end
    if not mob then error("types.Actor.setEquipment: the actor is not active", 2) end
    local cur = M.getEquipment(actor)
    local want = {}
    for sl, v in pairs(tbl) do
        local id = type(v) == "string" and v:lower() or (type(v) == "table" and v.recordId) or nil
        if not id then error("types.Actor.setEquipment: slot " .. tostring(sl) .. " needs a GameObject or a record id", 2) end
        want[sl] = id
    end
    for sl, it in pairs(cur) do
        if want[sl] ~= it.recordId then mob:unequip({ item = it.recordId }) end
    end
    for sl, id in pairs(want) do
        if not (cur[sl] and cur[sl].recordId == id) then
            if objects.inventory(actor):countOf(id) <= 0 then
                error("types.Actor.setEquipment: " .. id .. " is not in the actor's inventory", 2)
            end
            mob:equip({ item = id })
        end
    end
end

---------------------------------------------------------------- stance (0.4.0)
-- STANCE.Nothing/Weapon/Spell <-> mobile.weaponReady / mobile.castReady.
local STANCE = { Nothing = 0, Weapon = 1, Spell = 2 }
M.STANCE = STANCE
function M.getStance(actor)
    local mob = mobileOf(actor)
    if not mob then return STANCE.Nothing end
    local ok, cast = pcall(function() return mob.castReady end)
    if ok and cast then return STANCE.Spell end
    local ok2, wpn = pcall(function() return mob.weaponReady end)
    if ok2 and wpn then return STANCE.Weapon end
    return STANCE.Nothing
end
function M.setStance(actor, stance)
    local mob = mobileOf(actor)
    if not mob then error("types.Actor.setStance: the actor is not active", 2) end
    if stance ~= STANCE.Nothing and stance ~= STANCE.Weapon and stance ~= STANCE.Spell then
        error("types.Actor.setStance: unknown stance " .. tostring(stance), 2)
    end
    if stance == STANCE.Spell then mob.weaponReady = false; mob.castReady = true
    elseif stance == STANCE.Weapon then mob.castReady = false; mob.weaponReady = true
    else mob.castReady = false; mob.weaponReady = false end
end

---------------------------------------------------------------- level and skills (0.4.0)
-- stats.level(actor): current = the actor's level (read-only here); progress = the player's
-- levelUpProgress (0 for other actors).
local function levelStat(actor)
    local mob, ref = mobileOf(actor)
    if not ref then error("types.Actor.stats.level: invalid actor", 2) end
    return setmetatable({}, {
        __index = function(_, k)
            if k == "current" then
                local ok, v = pcall(function() return ref.object.level end)
                if ok and v then return v end
                local b = baseObject(ref); return b and b.level or 1
            elseif k == "progress" then
                if ref == tes3.player and tes3.mobilePlayer then return tes3.mobilePlayer.levelUpProgress or 0 end
                return 0
            end
            return nil
        end,
        __newindex = function(_, k) error("omwcompat: stats.level." .. tostring(k) .. " is not writable", 2) end,
    })
end
-- OpenMW skill ids -> tes3.skill ids
local SKILLS = { block = 0, armorer = 1, mediumarmor = 2, heavyarmor = 3, bluntweapon = 4, longblade = 5, axe = 6,
    spear = 7, athletics = 8, enchant = 9, destruction = 10, alteration = 11, illusion = 12, conjuration = 13,
    mysticism = 14, restoration = 15, alchemy = 16, unarmored = 17, security = 18, sneak = 19, acrobatics = 20,
    lightarmor = 21, shortblade = 22, marksman = 23, mercantile = 24, speechcraft = 25, handtohand = 26 }
M.SKILLS = SKILLS
local function skillStat(key)
    local sid = SKILLS[key]
    return function(actor)
        local _, ref = mobileOf(actor)
        if not ref then error("types.NPC.stats.skills." .. key .. ": invalid actor", 2) end
        local function st()
            local m2 = mobileOf(actor)
            if not m2 then return nil end
            local ok, v = pcall(function() return m2:getSkillStatistic(sid) end)
            return ok and v or nil
        end
        local function recordBase()
            local b = baseObject(ref)
            local ok, v = pcall(function() return b.skills[sid + 1] end)
            return ok and v or 0
        end
        return setmetatable({}, {
            __index = function(_, k)
                local s = st()
                if k == "base" then return s and s.base or recordBase()
                elseif k == "modified" then return s and s.current or recordBase()
                elseif k == "modifier" then return s and (s.current - s.base) or 0
                elseif k == "damage" then return 0
                elseif k == "progress" then
                    local mp = tes3.mobilePlayer
                    if ref ~= tes3.player or not mp then return 0 end
                    local ok, v = pcall(function()
                        local need = mp:getSkillProgressRequirement(sid)
                        return need and need > 0 and (mp.skillProgress[sid + 1] or 0) / need or 0
                    end)
                    return ok and v or 0
                end
                return nil
            end,
            __newindex = function(_, k, v)
                local r = objects.refOf(actor)
                if not r then error("types.NPC.stats.skills." .. key .. ": invalid actor", 2) end
                if k == "base" then tes3.setStatistic({ reference = r, skill = sid, base = v })
                elseif k == "modifier" then
                    local s = st()
                    tes3.setStatistic({ reference = r, skill = sid, current = (s and s.base or recordBase()) + v })
                else error("omwcompat: skill field " .. tostring(k) .. " is not writable", 2) end
            end,
        })
    end
end

---------------------------------------------------------------- controls (0.4.0 read, 0.4.3 writes, 0.5.0 mapping)
-- self.controls reads: sneak/run/jump are the actor's current state (mobile.isSneaking,
-- isRunning, isJumping); movement / sideMovement are -1, 0 or 1 from the mobile's movement
-- flags (isMovingForward/Back, isMovingRight/Left); yawChange / pitchChange read 0 (OpenMW
-- applies them every frame and starts the next frame at 0).
-- Writes (0.5.0), on NPCs and creatures (not the player, whose controls are the keyboard):
--   yawChange   -> reference.facing += value (radians, positive turns right, as OpenMW). It is
--                  applied when written, so a script that writes it every update turns the
--                  actor by the same steps; the AI may turn the actor back
--   run, sneak  -> mobile.forceRun / forceSneak (NPCs; creatures have no such flags)
--   jump = true -> mobile:doJump()
-- Everything else (pitchChange, movement, sideMovement, use, and any write on the player)
-- warns once per field and is ignored, as in 0.4.3: Thieves Pickpocket's onInactive does
-- self.controls.yawChange = 0 and must run to the end. A write never raises.
local CONTROL_READ = { sneak = "isSneaking", run = "isRunning", jump = "isJumping" }
local FORCE_FLAG = { run = "forceRun", sneak = "forceSneak" }
M.controlWrites = { applied = {}, ignored = {} }
local function ignoredWrite(k, why)
    local t = M.controlWrites.ignored
    t[k] = (t[k] or 0) + 1
    rt.warnOnce("controls.set." .. tostring(k),
        "self.controls.%s cannot be set%s: omwcompat %s maps only yawChange, run, sneak and jump on NPCs and creatures (the write is ignored; further writes are counted, not logged)",
        tostring(k), why and (" (" .. why .. ")") or "", rt.VERSION)
end
local function appliedWrite(k, how)
    local t = M.controlWrites.applied
    t[k] = (t[k] or 0) + 1
    if t[k] == 1 and rt.note then
        rt.note("[omwcompat] self.controls.%s is applied as %s (omwcompat %s); further writes are counted, not logged", k, how, rt.VERSION)
    end
end
local TWO_PI = 2 * math.pi
local function wrapAngle(a)
    a = a % TWO_PI
    if a > math.pi then a = a - TWO_PI end
    return a
end
local function writeControl(selfObj, k, v)
    local mob, ref = mobileOf(selfObj)
    if not ref then return ignoredWrite(k, "no object") end
    local ot = ref.object and ref.object.objectType
    local OT = tes3.objectType
    local isNpc, isCreature = ot == OT.npc, ot == OT.creature
    if ref == tes3.player then return ignoredWrite(k, "the player") end
    if not (isNpc or isCreature) then return ignoredWrite(k, "not an NPC or creature") end
    if k == "yawChange" then
        if type(v) ~= "number" or v ~= v then return ignoredWrite(k, "not a number") end
        if v == 0 then appliedWrite(k, "a facing change"); return end
        local ok = pcall(function()
            local cur = ref.facing
            if type(cur) ~= "number" then cur = ref.orientation.z end
            ref.facing = wrapAngle(cur + v)
        end)
        if ok then appliedWrite(k, "a facing change") else ignoredWrite(k, "MWSE refused the facing") end
        return
    end
    if FORCE_FLAG[k] then
        if not isNpc then return ignoredWrite(k, "creatures cannot be forced to " .. k) end
        if not mob then return ignoredWrite(k, "the actor is not active") end
        local f = FORCE_FLAG[k]
        local ok = pcall(function() mob[f] = v and true or false end)
        if ok then appliedWrite(k, "mobile." .. f) else ignoredWrite(k, "MWSE refused mobile." .. f) end
        return
    end
    if k == "jump" then
        if not v then appliedWrite(k, "mobile:doJump()"); return end
        if not mob then return ignoredWrite(k, "the actor is not active") end
        local ok = pcall(function() return mob:doJump({}) end)
        if ok then appliedWrite(k, "mobile:doJump()") else ignoredWrite(k, "MWSE refused the jump") end
        return
    end
    return ignoredWrite(k)
end
M.writeControl = writeControl
function M.controlsOf(selfObj)
    return setmetatable({}, {
        __index = function(_, k)
            local mob = mobileOf(selfObj)
            local function flag(f)
                local ok, v = pcall(function() return mob and mob[f] end)
                return ok and v == true
            end
            local f = CONTROL_READ[k]
            if f then return flag(f) end
            if k == "movement" then return flag("isMovingForward") and 1 or (flag("isMovingBack") and -1 or 0) end
            if k == "sideMovement" then return flag("isMovingRight") and 1 or (flag("isMovingLeft") and -1 or 0) end
            if k == "yawChange" or k == "pitchChange" then return 0 end
            rt.warnOnce("controls." .. tostring(k), "self.controls.%s is not supported by omwcompat %s", tostring(k), rt.VERSION)
            return nil
        end,
        __newindex = function(_, k, v)
            local ok, err = pcall(writeControl, selfObj, k, v)
            if not ok then ignoredWrite(k, tostring(err)) end
        end,
    })
end

---------------------------------------------------------------- player (0.4.0)
local function playerOnly(actor, fn)
    local ref = objects.refOf(actor)
    if not ref or ref ~= tes3.player then error("types.Player." .. fn .. ": not the player", 3) end
    return ref
end
function M.isCharGenFinished(p)
    playerOnly(p, "isCharGenFinished")
    local g = tes3.findGlobal("CharGenState")
    return g ~= nil and g.value == -1
end
function M.getCrimeLevel(p)
    playerOnly(p, "getCrimeLevel")
    return tes3.mobilePlayer and tes3.mobilePlayer.bounty or 0
end
function M.setCrimeLevel(p, n)
    playerOnly(p, "setCrimeLevel")
    if tes3.mobilePlayer then tes3.mobilePlayer.bounty = math.max(0, math.floor(tonumber(n) or 0)) end
end
-- types.Player.addTopic(player, topicId) -> tes3.addTopic
function M.addTopic(p, topicId)
    playerOnly(p, "addTopic")
    if type(topicId) ~= "string" then error("types.Player.addTopic: topicId must be a string", 2) end
    tes3.addTopic({ topic = topicId })   -- false when the player already knows it (not an error)
end
function M.isWerewolf(actor)
    local mob = mobileOf(actor)
    local ok, v = pcall(function() return mob and mob.werewolf end)
    return ok and v == true
end
-- types.Player.quests(player)[id]: stage (tes3.getJournalIndex / tes3.setJournalIndex), started
-- (stage > 0), finished (the journal entry at the current stage has the Finished flag),
-- addJournalEntry(stage[, actor]) (tes3.updateJournal). Iterating all quests is not supported.
local function questFinished(id, stage)
    if stage <= 0 then return false end
    local ok, r = pcall(function()
        local d = tes3.findDialogue({ topic = id, type = tes3.dialogueType and tes3.dialogueType.journal or 4 })
        if not d then return false end
        for _, info in ipairs(d.info or {}) do
            if info.disposition == stage and info.isQuestFinished then return true end
        end
        return false
    end)
    return ok and r == true
end
function M.quests(p)
    playerOnly(p, "quests")
    return setmetatable({}, {
        __index = function(_, qid)
            if type(qid) ~= "string" then return nil end
            local id = qid:lower()
            local Q = {}
            function Q.addJournalEntry(_, stage, actor)
                local aref = actor and objects.refOf(actor) or nil
                tes3.updateJournal({ id = id, index = stage, speaker = aref and aref.object or nil })
            end
            return setmetatable(Q, {
                __index = function(_, k)
                    local stage = tes3.getJournalIndex({ id = id }) or 0
                    if k == "id" then return id
                    elseif k == "stage" then return stage
                    elseif k == "started" then return stage > 0
                    elseif k == "finished" then return questFinished(id, stage) end
                    return nil
                end,
                __newindex = function(_, k, v)
                    if k == "stage" then tes3.setJournalIndex({ id = id, index = v })
                    else error("omwcompat: quest." .. tostring(k) .. " is not writable", 2) end
                end,
            })
        end,
        __pairs = function() error("omwcompat: iterating types.Player.quests is not supported", 2) end,
    })
end

---------------------------------------------------------------- faction records (0.4.0)
-- core.factions.records[id or index] -> { id, name, ranks, reactions, attributes, skills, hidden }.
-- Read from MWSE's tes3faction: ranks[i] = { name, attributeValues, primarySkillValue,
-- favouredSkillValue, factionReputation, factionReaction }; hidden is always false (MWSE has no flag).
local ATTR_NAMES = { [0] = "strength", "intelligence", "willpower", "agility", "speed", "endurance", "personality", "luck" }
local SKILL_NAMES = {}
for k, v in pairs(SKILLS) do SKILL_NAMES[v] = k end
local factionCache = {}
-- plain tables (LuaJIT does not honour __len/__ipairs on proxies, and mods use # and ipairs)
local function readOnly(t) return t end
local function factionRecord(f)
    local id = lowerId(f.id)
    local cached = factionCache[id]
    if cached and cached._f == f then return cached end
    local ranks = {}
    local ok, rl = pcall(function() return f.ranks end)
    for i, r in ipairs(ok and rl or {}) do
        local nameOk, nm = pcall(function() return f:getRankName(i - 1) end)
        local attrs = {}
        for j, a in ipairs(r.attributes or {}) do attrs[j] = a end
        local rep = r.reputation
        ranks[i] = readOnly({ name = nameOk and nm or nil, attributeValues = readOnly(attrs), primarySkillValue = r.skill,
            favouredSkillValue = r.favoredSkill, factionReputation = rep, factionReaction = rep })
    end
    local reactions = {}
    local okR, rr = pcall(function() return f.reactions end)
    for _, x in ipairs(okR and rr or {}) do
        if x.faction then reactions[lowerId(x.faction.id)] = x.reaction end
    end
    local attributes, skills = {}, {}
    local okA, al = pcall(function() return f.attributes end)
    for _, a in ipairs(okA and al or {}) do attributes[#attributes + 1] = ATTR_NAMES[a] end
    local okS, sl = pcall(function() return f.skills end)
    for _, sk in ipairs(okS and sl or {}) do if SKILL_NAMES[sk] then skills[#skills + 1] = SKILL_NAMES[sk] end end
    local rec = readOnly({ id = id, name = f.name, ranks = readOnly(ranks), reactions = readOnly(reactions),
        attributes = readOnly(attributes), skills = readOnly(skills), hidden = false })
    rec._f = f
    factionCache[id] = rec
    return rec
end
function M.factionsModule()
    local records = setmetatable({}, {
        __index = function(_, k)
            if type(k) == "string" then
                local want = k:lower()
                for _, f in ipairs(factionList() or {}) do if lowerId(f.id) == want then return factionRecord(f) end end
                return nil
            elseif type(k) == "number" then
                local f = (factionList() or {})[k]
                return f and factionRecord(f) or nil
            end
            return nil
        end,
        __len = function() return #(factionList() or {}) end,
        __newindex = function() error("core.factions.records is read-only", 2) end,
    })
    return { records = records }
end

function M.extendTypes(types)
    local stats = { dynamic = {}, attributes = {}, ai = {} }
    for k in pairs(DYNAMIC) do stats.dynamic[k] = dynamicStat(k) end
    for _, k in ipairs(ATTRIBUTES) do stats.attributes[k] = attributeStat(k) end
    for k in pairs(AISTATS) do stats.ai[k] = aiStat(k) end
    local npcStats = setmetatable({ skills = {} }, { __index = stats })
    for k in pairs(SKILLS) do npcStats.skills[k] = skillStat(k) end
    stats.level = levelStat
    for _, T in ipairs({ types.Actor, types.NPC, types.Creature, types.Player }) do
        if T then
            rawset(T, "stats", (T == types.NPC or T == types.Player) and npcStats or stats)
            T.isDead = M.isDead
            T.EQUIPMENT_SLOT = SLOT
            T.STANCE = STANCE
            T.getEquipment = M.getEquipment
            T.setEquipment = M.setEquipment
            T.hasEquipped = M.hasEquipped
            T.equipment = M.getEquipment     -- pre-0.49 name, still used by mods
            T.getStance = M.getStance
            T.setStance = M.setStance
        end
    end
    for _, T in ipairs({ types.NPC, types.Player }) do
        if T then T.isWerewolf = M.isWerewolf end
    end
    if types.Player then
        types.Player.isCharGenFinished = M.isCharGenFinished
        types.Player.getCrimeLevel = M.getCrimeLevel
        types.Player.addTopic = M.addTopic
        types.Player.setCrimeLevel = M.setCrimeLevel
        types.Player.quests = M.quests
    end
    for _, T in ipairs({ types.NPC, types.Player }) do
        if T then
            T.getFactions = M.getFactions
            T.getFactionRank = M.getFactionRank
            T.isExpelled = M.isExpelled
        end
    end
    if types.NPC then
        types.NPC.getDisposition = M.getDisposition
        types.NPC.getBaseDisposition = M.getBaseDisposition
        types.NPC.setBaseDisposition = M.setBaseDisposition
        types.NPC.modifyBaseDisposition = M.modifyBaseDisposition
    end
end

-- Disposition (0.4.2). Morrowind keeps one disposition per NPC (toward the player), so the
-- player argument is accepted and ignored. getDisposition is the effective value MWSE reports
-- (all modifiers applied), getBaseDisposition the base value; both fall back to the record.
local function dispositionField(actor, field, fname)
    local ref = objects.refOf(actor)
    if not ref then error("types.NPC." .. fname .. ": invalid NPC", 3) end
    local o = ref.object
    local ok, d = pcall(function() return o[field] end)
    if ok and type(d) == "number" then return d, ref end
    ok, d = pcall(function() return o.baseDisposition end)
    if ok and type(d) == "number" then return d, ref end
    local b = baseObject(ref)
    ok, d = pcall(function() return b.baseDisposition or b.disposition end)
    if ok and type(d) == "number" then return d, ref end
    rt.warnOnce("disposition " .. tostring(o and o.id), "types.NPC.%s: %s has no disposition; 50 is returned", fname, tostring(o and o.id))
    return 50, ref
end
function M.getDisposition(actor, _) return (dispositionField(actor, "disposition", "getDisposition")) end
function M.getBaseDisposition(actor, _) return (dispositionField(actor, "baseDisposition", "getBaseDisposition")) end
function M.setBaseDisposition(actor, _, value)
    if type(value) ~= "number" then error("types.NPC.setBaseDisposition: value must be a number", 2) end
    local _, ref = dispositionField(actor, "baseDisposition", "setBaseDisposition")
    local v = math.max(0, math.min(100, math.floor(value + 0.5)))
    local ok = pcall(function() ref.object.baseDisposition = v end)
    if not ok then rt.warnOnce("setBaseDisposition", "types.NPC.setBaseDisposition: MWSE refused the write; ignored") end
end
function M.modifyBaseDisposition(actor, player, value)
    if type(value) ~= "number" then error("types.NPC.modifyBaseDisposition: value must be a number", 2) end
    M.setBaseDisposition(actor, player, M.getBaseDisposition(actor) + value)
end

---------------------------------------------------------------- nearby
local NEARBY = {
    actors = { "npc", "creature" },
    containers = { "container" },
    doors = { "door" },
    activators = { "activator" },
    items = { "light", "miscItem", "weapon", "armor", "clothing", "book", "alchemy", "ingredient", "apparatus",
        "lockpick", "probe", "repairItem", "ammunition" },
}
local cache = { frame = -1, lists = {} }
local function collect(kind)
    local frame = rt._state.frame
    if cache.frame ~= frame then cache.frame, cache.lists = frame, {} end
    local l = cache.lists[kind]
    if l then return l end
    l = {}
    local filter = {}
    for _, n in ipairs(NEARBY[kind]) do
        local ot = tes3.objectType[n]
        if ot then filter[#filter + 1] = ot end
    end
    local seenPlayer = false
    for _, cell in ipairs(tes3.getActiveCells() or {}) do
        for ref in cell:iterateReferences(filter) do
            if not ref.disabled and not ref.deleted and not objects.isTomb(ref) then
                if ref == tes3.player then seenPlayer = true end
                l[#l + 1] = objects.wrap(ref)
            end
        end
    end
    if kind == "actors" and tes3.player and not seenPlayer then table.insert(l, 1, objects.wrap(tes3.player)) end
    cache.lists[kind] = l
    return l
end
M.collectNearby = collect

-- nearby.castRay / castRenderingRay -> tes3.rayTest. MWSE tests rendered geometry, which is
-- what castRenderingRay does; castRay (physics shapes) is approximated by it: collisionType and
-- radius are ignored. Result: { hit, hitPos, hitNormal, hitObject }.
local function vecArgs(v) return v.x, v.y, v.z end
local function tvec(x, y, z)
    if tes3vector3 and tes3vector3.new then return tes3vector3.new(x, y, z) end
    return { x, y, z }
end
local function castRay(from, to, o)
    local fx, fy, fz = vecArgs(from)
    local tx, ty, tz = vecArgs(to)
    local dx, dy, dz = tx - fx, ty - fy, tz - fz
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len == 0 then return { hit = false } end
    local ignore = {}
    local ig = o and o.ignore
    if ig then
        local list = (getmetatable(ig) == objects.OBJ) and { ig } or ig
        for _, x in ipairs(list) do local r = objects.refOf(x); if r then ignore[#ignore + 1] = r end end
    end
    local ok, r = pcall(tes3.rayTest, { position = tvec(fx, fy, fz), direction = tvec(dx / len, dy / len, dz / len),
        maxDistance = len, ignore = ignore })
    if not ok or not r or not r.intersection then return { hit = false } end
    local U = rt.util
    local p, n = r.intersection, r.normal
    return { hit = true, hitPos = U.vector3(p.x, p.y, p.z), hitNormal = n and U.vector3(n.x, n.y, n.z) or nil,
        hitObject = r.reference and objects.wrap(r.reference) or nil }
end
M.castRay = castRay

function M.nearbyModule()
    return setmetatable({}, {
        __index = function(_, k)
            if NEARBY[k] then return collect(k) end
            if k == "castRay" or k == "castRenderingRay" then return castRay end
            if k == "COLLISION_TYPE" then
                return { World = 1, Door = 2, Actor = 4, HeightMap = 8, Projectile = 16, Water = 32, Default = 31,
                    AnyPhysical = 63, Camera = 64, VisualOnly = 128 }
            end
            if k == "players" then return tes3.player and { objects.wrap(tes3.player) } or {} end
            rt.warnOnce("openmw.nearby." .. tostring(k), "openmw.nearby.%s is not supported by omwcompat %s", tostring(k), rt.VERSION)
            return nil
        end,
        __newindex = function() error("openmw.nearby is read-only", 2) end,
    })
end

---------------------------------------------------------------- I.AI
local PKG_NAMES
local function packageName(t)
    if not PKG_NAMES then
        local P = tes3.aiPackage or { none = -1, wander = 0, travel = 1, escort = 2, follow = 3, activate = 4 }
        PKG_NAMES = {}
        for k, name in pairs({ wander = "Wander", travel = "Travel", escort = "Escort", follow = "Follow", activate = "Activate" }) do
            if P[k] ~= nil then PKG_NAMES[P[k]] = name end
        end
        M._none = P.none
    end
    if t == nil or t == M._none then return nil end
    return PKG_NAMES[t] or "Unknown"
end

local function combatTarget(mob)
    local ok, t = pcall(function() return mob.actionData and mob.actionData.target end)
    if ok and t and t.reference then return objects.wrap(t.reference) end
    return nil
end

local function vecArg(v)
    if v == nil then return nil end
    return { v.x, v.y, v.z }
end

function M.aiInterface(getSelf)
    local function mob()
        local m2, ref = mobileOf(getSelf())
        if not m2 then error("omwcompat: I.AI needs an active actor", 3) end
        return m2, ref
    end
    local AI = { version = 0 }
    function AI.getActivePackage()
        local m2 = mob()
        if m2.inCombat then return { type = "Combat", target = combatTarget(m2), sideWithTarget = false } end
        local planner = m2.aiPlanner
        local ok, pkg = pcall(function() return planner and planner:getActivePackage() end)
        if not ok or not pkg then return nil end
        local name = packageName(pkg.type)
        if not name then return nil end
        local target = nil
        pcall(function() if pkg.targetActor and pkg.targetActor.reference then target = objects.wrap(pkg.targetActor.reference) end end)
        return { type = name, target = target, sideWithTarget = false }
    end
    function AI.getActiveTarget(kind)
        local p = AI.getActivePackage()
        if p and (kind == nil or p.type == kind) then return p.target end
        return nil
    end
    function AI.startPackage(opts)
        if type(opts) ~= "table" or type(opts.type) ~= "string" then error("I.AI.startPackage: options.type is required", 2) end
        local m2, ref = mob()
        local t = opts.type
        local function targetRef()
            local r = opts.target and objects.refOf(opts.target)
            if not r then error("I.AI.startPackage(" .. t .. "): target is not a valid object", 3) end
            return r
        end
        if t == "Combat" then
            local tr = targetRef()
            local tm = tr.mobile
            if not tm then error("I.AI.startPackage(Combat): target is not an active actor", 2) end
            m2:startCombat(tm)
        elseif t == "Wander" then
            tes3.setAIWander({ reference = ref, range = opts.distance or 0, duration = opts.duration and math.floor(opts.duration / 3600) or 0,
                idles = opts.idle and { opts.idle.idle2 or 0, opts.idle.idle3 or 0, opts.idle.idle4 or 0, opts.idle.idle5 or 0,
                    opts.idle.idle6 or 0, opts.idle.idle7 or 0, opts.idle.idle8 or 0, opts.idle.idle9 or 0 } or nil,
                reset = opts.isRepeat })
        elseif t == "Travel" then
            if not opts.destPosition then error("I.AI.startPackage(Travel): destPosition is required", 2) end
            tes3.setAITravel({ reference = ref, destination = vecArg(opts.destPosition), reset = opts.isRepeat })
        elseif t == "Follow" then
            tes3.setAIFollow({ reference = ref, target = targetRef(), destination = vecArg(opts.destPosition),
                duration = opts.duration and math.floor(opts.duration / 3600) or nil, reset = opts.isRepeat })
        elseif t == "Escort" then
            tes3.setAIEscort({ reference = ref, target = targetRef(), destination = vecArg(opts.destPosition),
                duration = opts.duration and math.floor(opts.duration / 3600) or nil, reset = opts.isRepeat })
        else
            error("omwcompat: I.AI.startPackage type '" .. t .. "' is not supported", 2)
        end
    end
    function AI.removePackages(kind)
        local m2 = mob()
        if kind == nil or kind == "Combat" then
            if m2.inCombat then m2:stopCombat(true) end
        end
        if kind ~= "Combat" then
            rt.warnOnce("I.AI.removePackages." .. tostring(kind),
                "I.AI.removePackages(%s): only Combat packages are removed; others are left to the engine", tostring(kind))
        end
    end
    function AI.isFleeing()
        local m2 = mob()
        local ok, f = pcall(function() return m2.isFleeing end)
        return ok and f == true
    end
    return AI
end

---------------------------------------------------------------- animations (0.4.2 stubs, 0.5.0 mapping)
-- Since 0.5.0 the simple calls are mapped to MWSE; everything else is still a quiet no-op.
--   playBlended / playQueued / I.AnimationController.playBlendedAnimation
--       -> tes3.playAnimation, only for a vanilla group name (tes3.animationGroup, OpenMW's
--          lower-case names such as "idle2", "hit1", "walkforwardhh") that the actor has, with
--          the default start/stop keys. Priority Scripted (NPC/creature) plays on the whole
--          body ("group", the AI pauses as for a PlayGroup); other priorities, and anything on
--          the player, are layered on the body sections of the blend mask (lower/upper/shield;
--          the AI keeps control). loops -> loopCount (playQueued default: infinite). speed,
--          priority tables, startPoint and autoDisable are ignored. A playQueued right after
--          clearAnimationQueue starts immediately, otherwise after the current group.
--   hasAnimation / hasGroup / isPlaying / getActiveGroup / getCurrentTime
--       -> reference.animationData (animationGroups, currentAnimGroups, timings)
--   cancel / clearAnimationQueue(actor, true) -> back to the AI (tes3.playAnimation group 0),
--       only for a group omwcompat started; animations the engine plays are never cancelled
--   setLoopingEnabled(actor, group, false) -> tes3.cancelAnimationLoop
--   skipAnimationThisFrame -> tes3.skipAnimationFrame
--   I.AnimationController handlers: playBlendedAnimation handlers run for calls made through
--       omwcompat (newest first, false stops the chain, options.skip skips the play); text key
--       handlers get "start" when MWSE's playGroup event starts the group on the actor and
--       "stop" when a group omwcompat started ends; animationEnded handlers run when a group
--       omwcompat started ends. Other text keys ("hit", "attach", ...) never fire.
-- Unknown group names, custom start/stop keys and every other function (getTextKeyTime,
-- getCompletion, getLoopCount, getSpeed, setSpeed, hasBone, isLoopingAnimation, addGlow,
-- addVfx, removeVfx, removeAllVfx, newer API names) do nothing and answer "not playing"/nil.
-- Nothing here raises: a failing MWSE call is logged once and the call is skipped. The first
-- no-op call of each mod logs one warning and the first mapped call one note, both in the
-- library log; later calls are only counted (M.animCalls[mod][name]).
M.animCalls = {}
local ANIM_CONST = {
    PRIORITY = { Default = 0, WeaponLowerBody = 1, SneakIdleLowerBody = 2, SwimIdle = 3, Jump = 4, Movement = 5,
        Hit = 6, Weapon = 7, Block = 8, Knockdown = 9, Torch = 10, Storm = 11, Death = 12, Scripted = 13 },
    BLEND_MASK = { LowerBody = 1, Torso = 2, LeftArm = 4, RightArm = 8, UpperBody = 14, All = 15 },
    BONE_GROUP = { LowerBody = 1, Torso = 2, LeftArm = 3, RightArm = 4 },
}
local SCRIPTED = 13
-- stubs that stay: answer like an actor whose animation is not playing
local ANIM_FALSE = { isLoopingAnimation = true, hasBone = true }
local ANIM_NIL = { getTextKeyTime = true, getCompletion = true, getLoopCount = true, getSpeed = true }
local ANIM_NOOP = { setSpeed = true, addGlow = true, addVfx = true, removeVfx = true, removeAllVfx = true }

local function bump(modName, what)
    local c = M.animCalls[modName]
    if not c then c = {}; M.animCalls[modName] = c end
    c[what] = (c[what] or 0) + 1
end
local function animNote(modName, what, why)
    bump(modName, what)
    rt.warnOnce("animation " .. modName,
        "%s: %s does nothing%s: omwcompat %s maps only simple vanilla-group calls to MWSE (unmapped openmw.animation and I.AnimationController calls are skipped; further calls are counted, not logged)",
        modName, what, why and (" (" .. why .. ")") or "", rt.VERSION)
end
M.animNote = animNote
local mappedNoted = {}
local function animMapped(modName, what)
    bump(modName, what)
    if mappedNoted[modName] then return end
    mappedNoted[modName] = true
    rt.note("[omwcompat] %s: %s is played through MWSE (tes3.playAnimation); omwcompat %s maps vanilla animation groups only, speed and blending are not emulated",
        modName, what, rt.VERSION)
end
local function mwseFailed(what, err)
    rt.warnOnce("animation mwse " .. what, "openmw.animation: MWSE refused %s (%s); the call was skipped", what, tostring(err))
end

-- OpenMW group name (lower case) <-> tes3.animationGroup id. MWSE spells the hand-to-hand
-- movement/idle groups "...HandToHand"; their NIF/OpenMW names end in "hh" (idlehh, jumphh).
local groupIds, groupNames
local function buildGroups()
    if groupIds then return end
    groupIds, groupNames = {}, {}
    local G = tes3 and tes3.animationGroup
    if type(G) ~= "table" then return end
    for k, id in pairs(G) do
        if type(k) == "string" and type(id) == "number" then
            local low = k:lower()
            local pre = low:match("^(.-)handtohand$")
            local name = low
            if pre and pre ~= "" and pre ~= "inventory" then name = pre .. "hh" end
            groupIds[name] = id
            if name ~= low then groupIds[low] = groupIds[low] or id end
            groupNames[id] = name
        end
    end
end
local function groupIdOf(name)
    if type(name) ~= "string" then return nil end
    buildGroups()
    return groupIds[name:lower()]
end
M.groupIdOf = groupIdOf
local function groupNameOf(id)
    buildGroups()
    return id and groupNames[id] or nil
end
M.groupNameOf = groupNameOf

local function animRef(actor)
    local ok, ref = pcall(objects.refOf, actor)
    if not ok or not ref or ref.deleted then return nil end
    return ref
end
local function animData(ref)
    if not ref then return nil end
    local ok, ad = pcall(function() return ref.animationData end)
    if ok and ad then return ad end
    ok, ad = pcall(function() return ref.attachments and ref.attachments.animation end)
    return ok and ad or nil
end
local function hasGroupId(ad, id)
    local ok, v = pcall(function() return ad.animationGroups[id + 1] end)
    return ok and v ~= nil
end
local function currentGroups(ad)
    local ok, cur = pcall(function()
        local c = ad.currentAnimGroups
        return { c[1], c[2], c[3] }
    end)
    return ok and cur or {}
end
-- body sections (1 lower, 2 upper, 3 shield arm) where group id is current
local function sectionOf(ad, id)
    local cur = currentGroups(ad)
    for i = 1, 3 do if cur[i] == id then return i end end
    return nil
end

-- plays omwcompat started (polled for the "stop" text key and animationEnded):
-- plays[ref] = { id, name, sections, seen, frames, startKey, stopKey }
local plays = setmetatable({}, { __mode = "k" })
M._plays = plays
local controllers = setmetatable({}, { __mode = "k" })   -- controller -> true (has handlers)
local queueCleared = setmetatable({}, { __mode = "k" })  -- ref -> frame of clearAnimationQueue

local function isPlayerRef(ref) return tes3 and ref == tes3.player end
local NPC_OT
local function isActorRef(ref)
    local ot = ref and ref.object and ref.object.objectType
    NPC_OT = NPC_OT or tes3.objectType
    return ot == NPC_OT.npc or ot == NPC_OT.creature
end

local function callHandlers(list, where, ...)
    if not list then return end
    for i = #list, 1, -1 do
        local ok, r = rt.safecall(where, list[i], ...)
        if ok and r == false then return end
    end
end
local function forEachController(ref, fn)
    for c in pairs(controllers) do
        local S = c._script
        if not (S and S.dead) then
            local ok, self = pcall(c._getSelf)
            if ok and self and animRef(self) == ref then fn(c) end
        end
    end
end
local function fireTextKey(ref, name, key)
    forEachController(ref, function(c)
        callHandlers(c._textKeys[name], c._mod .. " text key handler", name, key)
        if name ~= "" then callHandlers(c._textKeys[""], c._mod .. " text key handler", name, key) end
    end)
end
local function fireEnded(ref, p)
    forEachController(ref, function(c)
        callHandlers(c._ended, c._mod .. " animationEnded handler", p.name,
            { startKey = p.startKey, stopKey = p.stopKey, time = nil, completion = 1 })
    end)
end

-- playGroup (MWSE): the "start" text key of the group, once per actor, group and frame
local playGroupWired, lastStart = false, setmetatable({}, { __mode = "k" })
function M.onPlayGroup(e)
    local ref = e and e.reference
    if not ref or not next(controllers) then return end
    local name = groupNameOf(e.group)
    if not name then return end
    local frame = rt._state and rt._state.frame or 0
    local l = lastStart[ref]
    if l and l.frame == frame and l.name == name then return end
    lastStart[ref] = { frame = frame, name = name }
    fireTextKey(ref, name, "start")
end
local function wirePlayGroup()
    if playGroupWired then return end
    playGroupWired = true
    local ev = tes3 and tes3.event and tes3.event.playGroup or "playGroup"
    pcall(event.register, ev, M.onPlayGroup)
end

-- once per frame (runtime frameWork): a group omwcompat started that is no longer current has
-- ended; one that never showed up within 10 frames is forgotten without a call.
function M.animTick()
    if not next(plays) then return end
    for ref, p in pairs(plays) do
        local ad = (not ref.deleted) and animData(ref) or nil
        if not ad then
            plays[ref] = nil
        else
            local cur, on = currentGroups(ad), false
            for _, s in ipairs(p.sections) do if cur[s] == p.id then on = true end end
            if on then
                p.seen = true
            elseif p.seen then
                plays[ref] = nil
                fireTextKey(ref, p.name, "stop")
                fireEnded(ref, p)
            else
                p.frames = p.frames + 1
                if p.frames >= 10 then plays[ref] = nil end
            end
        end
    end
end

local BIG_LOOPS = 1e6
local function loopCountOf(loops, default)
    if type(loops) ~= "number" then return default end
    if loops >= BIG_LOOPS or loops ~= loops then return -1 end
    if loops < 0 then return 0 end
    return math.floor(loops)
end
local function priorityOf(o)
    local p = o and o.priority
    if type(p) == "number" then return p end
    if type(p) == "table" then
        for _, v in pairs(p) do if v == SCRIPTED then return SCRIPTED end end
        return 0
    end
    return 0
end

-- shared by playBlended / playQueued: returns true when MWSE was asked to play
local function play(modName, what, actor, groupName, o, queued)
    o = type(o) == "table" and o or {}
    local ref = animRef(actor)
    local ad = animData(ref)
    if not ad then animNote(modName, what, "no animated actor"); return false end
    local id = groupIdOf(groupName)
    if not id then animNote(modName, what, "group " .. tostring(groupName) .. " is not a vanilla group"); return false end
    if not hasGroupId(ad, id) then animNote(modName, what, "the actor has no " .. tostring(groupName) .. " group"); return false end
    local sk, ek = o.startKey or "start", o.stopKey or "stop"
    if sk ~= "start" or ek ~= "stop" then
        animNote(modName, what, "custom start/stop keys " .. tostring(sk) .. "/" .. tostring(ek)); return false
    end
    local params = { reference = ref }
    local sections
    local frame = rt._state and rt._state.frame or 0
    if queued then
        params.group = id
        params.loopCount = loopCountOf(o.loops, -1)
        params.startFlag = queueCleared[ref] == frame and 1 or 0
        sections = { 1, 2, 3 }
    else
        params.loopCount = loopCountOf(o.loops, 0)
        params.startFlag = 1
        if priorityOf(o) == SCRIPTED and isActorRef(ref) and not isPlayerRef(ref) then
            params.group = id
            sections = { 1, 2, 3 }
        else
            local mask = type(o.blendMask) == "number" and o.blendMask or 15
            sections = {}
            if mask % 2 == 1 then params.lower = id; sections[#sections + 1] = 1 end
            if math.floor(mask / 2) % 2 == 1 or math.floor(mask / 8) % 2 == 1 then params.upper = id; sections[#sections + 1] = 2 end
            if math.floor(mask / 4) % 2 == 1 then params.shield = id; sections[#sections + 1] = 3 end
            if #sections == 0 then animNote(modName, what, "empty blend mask"); return false end
        end
    end
    local ok, err = pcall(tes3.playAnimation, params)
    if not ok then mwseFailed("tes3.playAnimation", err); return false end
    animMapped(modName, what)
    plays[ref] = { id = id, name = groupNameOf(id) or tostring(groupName):lower(), sections = sections,
        seen = false, frames = 0, startKey = sk, stopKey = ek }
    return true
end

local function backToAI(ref)
    local ok, err = pcall(tes3.playAnimation, { reference = ref, group = 0, startFlag = 1 })
    if not ok then mwseFailed("tes3.playAnimation", err) end
    plays[ref] = nil
end

-- openmw.animation for one mod's script
function M.animationModule(modName)
    local A = {}
    for k, v in pairs(ANIM_CONST) do
        local t = {}
        for n, x in pairs(v) do t[n] = x end
        A[k] = t
    end
    for k in pairs(ANIM_FALSE) do A[k] = function() animNote(modName, "openmw.animation." .. k); return false end end
    for k in pairs(ANIM_NIL) do A[k] = function() animNote(modName, "openmw.animation." .. k); return nil end end
    for k in pairs(ANIM_NOOP) do A[k] = function() animNote(modName, "openmw.animation." .. k) end end

    function A.hasAnimation(actor)
        bump(modName, "openmw.animation.hasAnimation")
        return animData(animRef(actor)) ~= nil
    end
    function A.hasGroup(actor, groupName)
        bump(modName, "openmw.animation.hasGroup")
        local ad, id = animData(animRef(actor)), groupIdOf(groupName)
        return ad ~= nil and id ~= nil and hasGroupId(ad, id)
    end
    function A.isPlaying(actor, groupName)
        bump(modName, "openmw.animation.isPlaying")
        local ad, id = animData(animRef(actor)), groupIdOf(groupName)
        return ad ~= nil and id ~= nil and sectionOf(ad, id) ~= nil
    end
    -- BONE_GROUP LowerBody -> lower section, Torso / RightArm -> upper, LeftArm -> shield arm
    local BONE_SECTION = { [1] = 1, [2] = 2, [3] = 3, [4] = 2 }
    function A.getActiveGroup(actor, boneGroup)
        bump(modName, "openmw.animation.getActiveGroup")
        local ad = animData(animRef(actor))
        local s = BONE_SECTION[boneGroup]
        if not ad or not s then return nil end
        return groupNameOf(currentGroups(ad)[s])
    end
    function A.getCurrentTime(actor, groupName)
        bump(modName, "openmw.animation.getCurrentTime")
        local ad, id = animData(animRef(actor)), groupIdOf(groupName)
        local s = ad and id and sectionOf(ad, id)
        if not s then return nil end
        local ok, t = pcall(function() return ad.timings[s] end)
        return ok and type(t) == "number" and t or nil
    end
    function A.playBlended(actor, groupName, o)
        play(modName, "openmw.animation.playBlended", actor, groupName, o, false)
    end
    function A.playQueued(actor, groupName, o)
        play(modName, "openmw.animation.playQueued", actor, groupName, o, true)
    end
    function A.clearAnimationQueue(actor, clearScripted)
        bump(modName, "openmw.animation.clearAnimationQueue")
        local ref = animRef(actor)
        if not ref then return end
        queueCleared[ref] = rt._state and rt._state.frame or 0
        if clearScripted and plays[ref] then backToAI(ref) end
    end
    function A.cancel(actor, groupName)
        bump(modName, "openmw.animation.cancel")
        local ref = animRef(actor)
        local p = ref and plays[ref]
        local id = groupIdOf(groupName)
        if p and id and p.id == id then backToAI(ref) end
    end
    function A.setLoopingEnabled(actor, groupName, enabled)
        bump(modName, "openmw.animation.setLoopingEnabled")
        if enabled ~= false then return end
        local ref = animRef(actor)
        local ad, id = animData(ref), groupIdOf(groupName)
        if ad and id and sectionOf(ad, id) then
            local ok, err = pcall(tes3.cancelAnimationLoop, { reference = ref })
            if not ok then mwseFailed("tes3.cancelAnimationLoop", err) end
        end
    end
    function A.skipAnimationThisFrame(actor)
        bump(modName, "openmw.animation.skipAnimationThisFrame")
        local ref = animRef(actor)
        if not animData(ref) then return end
        local ok, err = pcall(tes3.skipAnimationFrame, { reference = ref })
        if not ok then mwseFailed("tes3.skipAnimationFrame", err) end
    end
    return setmetatable(A, {
        -- a name this list does not know (a newer API): a no-op function, logged once
        __index = function(_, k)
            if type(k) ~= "string" then return nil end
            return function() animNote(modName, "openmw.animation." .. k) end
        end,
    })
end

-- I.AnimationController (actor local scripts), version 1
function M.animationControllerInterface(modName, getSelf, S)
    local A = M.animationModule(modName)
    local c = { _mod = modName, _getSelf = getSelf or function() return nil end, _script = S,
        _playHandlers = {}, _ended = {}, _textKeys = {} }
    local I = { version = 1 }
    function I.playBlendedAnimation(groupName, o)
        o = type(o) == "table" and o or {}
        callHandlers(c._playHandlers, modName .. " playBlendedAnimation handler", groupName, o)
        if o.skip then return end
        local self = c._getSelf()
        if self == nil then animNote(modName, "I.AnimationController.playBlendedAnimation", "no actor"); return end
        play(modName, "I.AnimationController.playBlendedAnimation", self, groupName, o, false)
    end
    function I.addPlayBlendedAnimationHandler(fn)
        bump(modName, "I.AnimationController.addPlayBlendedAnimationHandler")
        if type(fn) ~= "function" then return end
        c._playHandlers[#c._playHandlers + 1] = fn
    end
    function I.addAnimationEndedHandler(fn)
        bump(modName, "I.AnimationController.addAnimationEndedHandler")
        if type(fn) ~= "function" then return end
        c._ended[#c._ended + 1] = fn
        controllers[c] = true
    end
    function I.addTextKeyHandler(groupName, fn)
        bump(modName, "I.AnimationController.addTextKeyHandler")
        if type(fn) ~= "function" then return end
        local g = type(groupName) == "string" and groupName:lower() or ""
        local l = c._textKeys[g]
        if not l then l = {}; c._textKeys[g] = l end
        l[#l + 1] = fn
        controllers[c] = true
        wirePlayGroup()
    end
    return I
end

return M
