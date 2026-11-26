-- omwcompat.actors: actor-facing OpenMW APIs for local (object-attached) scripts.
--   types.Actor.stats.dynamic.<health|magicka|fatigue>(actor)  -> mobile.<stat> (tes3statistic)
--   types.Actor.stats.attributes.<name>(actor)                 -> mobile.<name>  (tes3statistic)
--   types.Actor.stats.ai.<fight|flee|alarm|hello>(actor)       -> mobile.<stat>, base from aiConfig
--   types.Actor.isDead(actor)                                  -> mobile.isDead
--   types.NPC.getFactions / getFactionRank / isExpelled        -> npc.faction / factionRank, player faction flags
--   openmw.nearby                                              -> references in tes3.getActiveCells()
--   I.AI (actor local scripts)                                 -> mobile:startCombat / tes3.setAI* / aiPlanner
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

---------------------------------------------------------------- controls (0.4.0, read-only)
-- self.controls: sneak/run/jump read the actor's current state (mobile.isSneaking, isRunning,
-- isJumping); OpenMW's controls are inputs a script can set, which omwcompat does not emulate.
local CONTROLS = { sneak = "isSneaking", run = "isRunning", jump = "isJumping" }
function M.controlsOf(selfObj)
    return setmetatable({}, {
        __index = function(_, k)
            local f = CONTROLS[k]
            if not f then
                rt.warnOnce("controls." .. tostring(k), "self.controls.%s is not supported by omwcompat %s", tostring(k), rt.VERSION)
                return nil
            end
            local mob = mobileOf(selfObj)
            local ok, v = pcall(function() return mob and mob[f] end)
            return ok and v == true or false
        end,
        __newindex = function(_, k)
            error("omwcompat: self.controls." .. tostring(k) .. " cannot be set (controls are read-only in omwcompat)", 2)
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

return M
