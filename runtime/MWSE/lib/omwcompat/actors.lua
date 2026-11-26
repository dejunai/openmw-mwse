-- omwcompat.actors: actor-facing OpenMW APIs for local (object-attached) scripts.
--   types.Actor.stats.dynamic.<health|magicka|fatigue>(actor)  -> mobile.<stat> (tes3statistic)
--   types.Actor.stats.attributes.<name>(actor)                 -> mobile.<name>  (tes3statistic)
--   types.Actor.stats.ai.<fight|flee|alarm|hello>(actor)       -> mobile.<stat>, base from aiConfig
--   types.Actor.isDead(actor)                                  -> mobile.isDead
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

function M.extendTypes(types)
    local stats = { dynamic = {}, attributes = {}, ai = {} }
    for k in pairs(DYNAMIC) do stats.dynamic[k] = dynamicStat(k) end
    for _, k in ipairs(ATTRIBUTES) do stats.attributes[k] = attributeStat(k) end
    for k in pairs(AISTATS) do stats.ai[k] = aiStat(k) end
    for _, T in ipairs({ types.Actor, types.NPC, types.Creature }) do
        if T then
            T.stats = stats
            T.isDead = M.isDead
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

function M.nearbyModule()
    return setmetatable({}, {
        __index = function(_, k)
            if NEARBY[k] then return collect(k) end
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
