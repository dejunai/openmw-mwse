-- omwcompat.runtime: hosts unmodified OpenMW GLOBAL and object-attached (NPC, CREATURE,
-- ACTOR, CONTAINER, DOOR, LIGHT, ACTIVATOR) Lua scripts inside MWSE.
-- See DESIGN.md (hybrid architecture, runtime first) and docs/RUNTIME.md.
-- MIT, Copyright (c) 2026 dej (dejunai). Built with Grok Bot.
local util = require("omwcompat.util")
local serial = require("omwcompat.serial")
local objects = require("omwcompat.objects")
local settings = require("omwcompat.settings")
local conversions = require("omwcompat.conversions")
local actors = require("omwcompat.actors")

local RT = { VERSION = "0.3.1", API_REVISION = 70, PROBE_API_REVISION = 100 }
local LOCAL_FLAG_NAMES
objects.init(RT)
settings.init(RT)
actors.init(RT, objects)

local mods = {}            -- registered mods, in registration order
local state = {
    ready = false,         -- scripts instantiated for the current save
    simTime = 0,
    frame = 0,
    nextFrame = {},        -- functions to run at the start of the next enterFrame
    activeQueue = {},      -- GameObjects waiting for onObjectActive
    activeQueued = {},
    activation = nil,      -- current activation context (R3)
    passthrough = {},      -- refs whose next activation goes straight to vanilla
    generated = {},        -- generated record id -> requested model (R4 + parity)
    idCounter = 0,
    meshmap = {},          -- normalized long model path -> short alias (R4)
    tombs = {},            -- content ref id -> true while removed by a script (R1)
    localActive = {},      -- object id -> { key, self, scripts } for objects with local scripts in an active cell
}
RT._state = state

---------------------------------------------------------------- logging
local warned = {}
local errCount = {}
function RT.log(fmt, ...)
    if not RT.debug then return end
    mwse.log("[omwcompat] " .. string.format(fmt, ...))
end
function RT.warn(fmt, ...) mwse.log("[omwcompat] WARNING: " .. string.format(fmt, ...)) end
function RT.warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    RT.warn(fmt, ...)
end
local function reportError(where, err)
    local n = (errCount[where] or 0) + 1
    errCount[where] = n
    if n <= 5 then
        mwse.log("[omwcompat] ERROR in %s: %s", where, tostring(err))
        if n == 5 then mwse.log("[omwcompat] (further errors in %s suppressed)", where) end
    end
end
local function safecall(where, f, ...)
    local ok, a, b = xpcall(f, function(e) return debug.traceback(e, 2) end, ...)
    if not ok then reportError(where, a); return false end
    return true, a, b
end
RT.safecall = safecall

function RT.generatedModel(id) return id and state.generated[id] or nil end
function RT.activationContext() return state.activation end
function RT.defer(fn) state.nextFrame[#state.nextFrame + 1] = fn end

---------------------------------------------------------------- path helpers
local function normMesh(p)
    p = p:gsub("\\", "/"):lower()
    p = p:gsub("^/+", "")
    p = p:gsub("^meshes/", "")
    return p
end
RT.normMesh = normMesh

local function dataPath(vpath)
    -- OpenMW VFS paths are relative to the data directories; MWSE's cwd is the
    -- Morrowind install folder, so loose files live under "Data Files/".
    return "Data Files/" .. vpath:gsub("\\", "/")
end

---------------------------------------------------------------- timers
local timers = {}  -- { kind="sim"|"game"|"real", at=number, script=S, name=?, fn=?, arg=? }
local function now(kind)
    if kind == "game" then return RT.gameTime() end
    if kind == "real" then return os.clock() end
    return state.simTime
end
local function addTimer(t) timers[#timers + 1] = t end
local function tickTimers()
    if #timers == 0 then return end
    local due, keep = {}, {}
    for _, t in ipairs(timers) do
        if t.script and t.script.dead then
            -- local script detached: its timers were saved with it or dropped
        elseif now(t.kind) >= t.at then due[#due + 1] = t else keep[#keep + 1] = t end
    end
    if #due == 0 then return end
    timers = keep
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, t in ipairs(due) do
        local fn = t.fn
        if not fn and t.name then
            fn = t.script.callbacks[t.name]
            if not fn then RT.warn("timer callback '%s' not registered in %s", t.name, t.script.path) end
        end
        if fn then safecall(t.script.path .. " timer", fn, t.arg) end
    end
end

local function makeAsync(S)
    local A = {}
    local CB = {}
    function A:registerTimerCallback(name, fn)
        S.callbacks[name] = fn
        return setmetatable({ _name = name }, CB)
    end
    function A:callback(fn) return fn end
    local function saved(kind, delay, cb, arg)
        if type(cb) ~= "table" or getmetatable(cb) ~= CB then
            error("callback must be created with async:registerTimerCallback", 3)
        end
        addTimer({ kind = kind, at = now(kind) + delay, script = S, name = cb._name, arg = arg })
    end
    local function unsaved(kind, delay, fn)
        addTimer({ kind = kind, at = now(kind) + delay, script = S, fn = fn })
    end
    function A:newSimulationTimer(d, cb, arg) saved("sim", d, cb, arg) end
    function A:newGameTimer(d, cb, arg) saved("game", d, cb, arg) end
    function A:newUnsavableSimulationTimer(d, fn) unsaved("sim", d, fn) end
    function A:newUnsavableGameTimer(d, fn) unsaved("game", d, fn) end
    function A:newRealTimer(d, cb, arg) unsaved("real", d, function() local f = S.callbacks[cb._name]; if f then f(arg) end end) end
    function A:newUnsavableRealTimer(d, fn) unsaved("real", d, fn) end
    return A
end

---------------------------------------------------------------- time
function RT.gameTime()
    local wc = tes3.worldController
    if not wc then return 0 end
    local days = wc.daysPassed and wc.daysPassed.value or 0
    local hour = wc.hour and wc.hour.value or 0
    return (days * 24 + hour) * 3600
end

---------------------------------------------------------------- events (sendGlobalEvent)
local eventQueue = {}
local localEventQueue = {}
local function deliverLocalEvents()
    if #localEventQueue == 0 then return end
    local q = localEventQueue
    localEventQueue = {}
    for _, ev in ipairs(q) do
        local inst = state.localActive[ev.key]
        if not inst then
            RT.log("event %s for inactive object %s dropped", ev.name, tostring(ev.key))
        else
            for i = #inst.scripts, 1, -1 do
                local S = inst.scripts[i]
                local h = S.eventHandlers and S.eventHandlers[ev.name]
                if h then
                    local ok, r = safecall(S.path .. " event " .. ev.name, h, ev.data)
                    if ok and r == false then break end
                end
            end
        end
    end
end
function RT.sendLocalEvent(obj, name, data)
    local key = rawget(obj, "_id")
    if not key or rawget(obj, "_limbo") then return end
    localEventQueue[#localEventQueue + 1] = { key = key, name = name, data = data }
end
local function deliverEvents()
    deliverLocalEvents()
    if #eventQueue == 0 then return end
    local q = eventQueue
    eventQueue = {}
    for _, ev in ipairs(q) do
        local handlers = {}
        for _, m in ipairs(mods) do
            for _, S in ipairs(m.scripts) do
                local h = S.eventHandlers and S.eventHandlers[ev.name]
                if h then handlers[#handlers + 1] = { S, h } end
            end
        end
        for i = #handlers, 1, -1 do
            local ok, r = safecall(handlers[i][1].path .. " event " .. ev.name, handlers[i][2], ev.data)
            if ok and r == false then break end
        end
    end
end

---------------------------------------------------------------- module construction
local function unsupportedProxy(modname, t, fallback)
    return setmetatable(t, {
        __index = function(_, k)
            if fallback then
                local v = fallback[k]
                if v ~= nil then return v end
            end
            RT.warnOnce(modname .. "." .. tostring(k), "%s.%s is not supported by omwcompat %s", modname, tostring(k), RT.VERSION)
            return nil
        end,
    })
end

local function playerObject()
    return tes3.player and objects.wrap(tes3.player) or nil
end

local function weatherInfo(w)
    if not w then return nil end
    local names = { [0] = "Clear", "Cloudy", "Foggy", "Overcast", "Rain", "Thunderstorm", "Ashstorm", "Blight", "Snow", "Blizzard" }
    local idx = w.index
    local name = names[idx] or w.name
    return { name = name, recordId = name and name:lower() or nil, index = idx, scriptId = name }
end

local loadHosted
local function buildModules(m, S)
    local types = objects.types
    local core = unsupportedProxy("openmw.core", {
        API_REVISION = RT.API_REVISION,
        getGameTime = RT.gameTime,
        getSimulationTime = function() return state.simTime end,
        getSimulationTimeScale = function() return 1 end,
        getGameTimeScale = function() local ts = tes3.findGlobal and tes3.findGlobal("timescale"); return ts and ts.value or 30 end,
        getRealTime = function() return os.clock() end,
        isWorldPaused = function() return tes3.menuMode() end,
        sendGlobalEvent = function(name, data) eventQueue[#eventQueue + 1] = { name = name, data = data } end,
        getGMST = function(name) local g = tes3.findGMST(name); return g and g.value or nil end,
        l10n = function(ctx) return settings.l10n(m, ctx) end,
        quit = function() RT.warnOnce("core.quit", "core.quit ignored") end,
        contentFiles = {
            has = function(name) return tes3.isModActive(name) end,
            indexOf = function() return nil end,
            list = {},
        },
        weather = {
            getCurrent = function(cell)
                local wc = tes3.worldController and tes3.worldController.weatherController
                if cell and not cell.hasSky then return nil end
                return wc and weatherInfo(wc.currentWeather) or nil
            end,
            getNext = function(cell)
                local wc = tes3.worldController and tes3.worldController.weatherController
                if cell and not cell.hasSky then return nil end
                return wc and weatherInfo(wc.nextWeather) or nil
            end,
            -- OpenMW: transition factor of the current weather (1 -> 0 while blending
            -- towards next); MWSE transitionScalar runs 0 -> 1. Open question Q7.
            getTransition = function(cell)
                local wc = tes3.worldController and tes3.worldController.weatherController
                if not wc or not wc.nextWeather then return nil end
                if cell and not cell.hasSky then return nil end
                return 1 - (wc.transitionScalar or 0)
            end,
        },
    })

    local world = unsupportedProxy("openmw.world", {
        createObject = function(recordId, count)
            if type(recordId) ~= "string" then error("createObject: recordId must be a string", 2) end
            if not tes3.getObject(recordId) then error("createObject: unknown record " .. recordId, 2) end
            return objects.limbo(recordId, count or 1)
        end,
        createRecord = function(draft) return RT.createRecord(m, draft) end,
        getCellByName = function(name) return objects.cellOf(tes3.getCell({ id = name })) end,
        getCellById = function(id) return objects.cellOf(tes3.getCell({ id = id })) end,
        getExteriorCell = function(x, y) return objects.cellOf(tes3.getCell({ x = x, y = y })) end,
        getGameTime = RT.gameTime,
        getSimulationTime = function() return state.simTime end,
        isWorldPaused = function() return tes3.menuMode() end,
        mwscript = setmetatable({ getGlobalScript = RT.getGlobalScript }, { __index = function(_, k)
            error("omwcompat: openmw.world.mwscript." .. tostring(k) .. " is not supported (MVP)", 2)
        end }),
    })
    -- dynamic fields
    local wmt = getmetatable(world)
    local wIndex = wmt.__index
    wmt.__index = function(t, k)
        if k == "players" then local p = playerObject(); return { p } end
        if k == "activeActors" then
            local out = {}
            for _, cell in ipairs(tes3.getActiveCells() or {}) do
                for ref in cell:iterateReferences({ tes3.objectType.npc, tes3.objectType.creature }) do
                    if not ref.disabled and not ref.deleted then out[#out + 1] = objects.wrap(ref) end
                end
            end
            local p = playerObject(); if p then table.insert(out, 1, p) end
            return out
        end
        if k == "cells" then
            local out = {}
            for _, c in ipairs(tes3.getActiveCells() or {}) do out[#out + 1] = objects.cellOf(c) end
            return out
        end
        return wIndex(t, k)
    end

    local vfs = unsupportedProxy("openmw.vfs", {
        open = function(path)
            local f = io.open(dataPath(path), "rb")
            if f then return f end
            return nil, "omwcompat: " .. path .. " not found as a loose file (BSA contents are not readable)"
        end,
        fileExists = function(path)
            return tes3.getFileExists(path:gsub("/", "\\")) or false
        end,
        pathsWithPrefix = function(prefix)
            local out = {}
            local base = dataPath(prefix)
            local dir = base:match("^(.*)/") or base
            local okL, lfs = pcall(require, "lfs")
            if okL and lfs and lfs.attributes(dir, "mode") == "directory" then
                for f in lfs.dir(dir) do
                    local p = (prefix:match("^(.*)/") or prefix) .. "/" .. f
                    if f ~= "." and f ~= ".." and p:lower():sub(1, #prefix) == prefix:lower() then out[#out + 1] = p:lower() end
                end
            end
            local i = 0
            return function() i = i + 1; return out[i] end
        end,
        lines = function(path)
            local f = io.open(dataPath(path), "r")
            if not f then error("file not found: " .. path, 2) end
            return f:lines()
        end,
    })

    local storage = unsupportedProxy("openmw.storage", {
        globalSection = function(name) return settings.section(name, m, S, S.probe) end,
        playerSection = function(name) return settings.section(name, m, S, S.probe) end,
        allPlayerSections = function() return m.storage end,
        LIFE_TIME = { Persistent = 0, GameSession = 1, Temporary = 2 },
    })

    local calendar = unsupportedProxy("openmw_aux.calendar", {
        gameTime = RT.gameTime,
        formatGameTime = function(fmt, t)
            t = t or RT.gameTime()
            return os.date("!" .. (fmt or "%H:%M"), math.floor(t))
        end,
        monthName = function(i) return tostring(i) end, -- stub
        daysInWeek = 7,
    })

    local function mapFilter(arr, f)
        local vals, scores = {}, {}
        for i = 1, #arr do
            local v = arr[i]
            local sc = f(v)
            if sc then vals[#vals + 1] = v; scores[#vals] = sc end
        end
        return vals, scores
    end
    local auxUtil = unsupportedProxy("openmw_aux.util", {
        deepToString = function(v, d)
            local ok, s = pcall(serial.encode, v, function(o) return o.id end)
            return ok and s or tostring(v)
        end,
        -- documented OpenMW contracts: mapFilter/mapFilterSort -> (values, scores) with
        -- falsy scores dropped (sorted ascending for mapFilterSort); findMinScore ->
        -- (element, score, index); callEventHandlers(nil) -> false.
        callEventHandlers = function(handlers, ...)
            if not handlers then return false end
            for i = #handlers, 1, -1 do if handlers[i](...) == false then return true end end
            return false
        end,
        callMultipleEventHandlers = function(lists, ...)
            for _, handlers in ipairs(lists) do
                for i = #handlers, 1, -1 do if handlers[i](...) == false then return true end end
            end
            return false
        end,
        mapFilter = mapFilter,
        mapFilterSort = function(arr, f)
            local vals, scores = mapFilter(arr, f)
            local order = {}
            for i = 1, #vals do order[i] = i end
            table.sort(order, function(a, b) return scores[a] < scores[b] end)
            local sv, ss = {}, {}
            for i, k in ipairs(order) do sv[i], ss[i] = vals[k], scores[k] end
            return sv, ss
        end,
        findMinScore = function(arr, f)
            local best, bs, bi
            for i = 1, #arr do
                local v = arr[i]
                local sc = f(v)
                if sc and (not bs or sc < bs) then best, bs, bi = v, sc, i end
            end
            return best, bs, bi
        end,
    })

    local modules = {
        ["openmw.core"] = core,
        ["openmw.world"] = world,
        ["openmw.types"] = unsupportedProxy("openmw.types", {}, types),
        ["openmw.util"] = util,
        ["openmw.async"] = makeAsync(S),
        ["openmw.storage"] = storage,
        ["openmw.vfs"] = vfs,
        ["openmw.interfaces"] = RT.makeInterfaces(m, S),
        ["openmw_aux.calendar"] = calendar,
        ["openmw_aux.util"] = auxUtil,
        ["openmw_aux.time"] = unsupportedProxy("openmw_aux.time", {
            second = 1, minute = 60, hour = 3600, day = 86400,
            GameTime = "game", SimulationTime = "sim",
            runRepeatedly = function(fn, period, opts)
                local A = S.modules["openmw.async"]
                local kind = opts and opts.type == "game" and "game" or "sim"
                local stopped = false
                local function tick()
                    if stopped then return end
                    fn()
                    addTimer({ kind = kind, at = now(kind) + period, script = S, fn = tick })
                end
                addTimer({ kind = kind, at = now(kind) + (opts and opts.initialDelay or period), script = S, fn = tick })
                return function() stopped = true end
            end,
        }),
    }
    if S.isLocal then
        -- local scripts: openmw.self / openmw.nearby exist, openmw.world does not (OpenMW rule)
        modules["openmw.world"] = nil
        modules["openmw.self"] = S.self
        modules["openmw.nearby"] = actors.nearbyModule()
    end
    return modules
end

---------------------------------------------------------------- records (R4)
local function newGeneratedId()
    repeat
        state.idCounter = state.idCounter + 1
        local id = string.format("Generated:0x%x", state.idCounter)
        if not tes3.getObject(id) then return id end
    until false
end

local SETTABLE = {
    name = "name", radius = "radius", duration = "time", value = "value", weight = "weight",
    isOffByDefault = "isOffByDefault", isFire = "isFire", isNegative = "isNegative",
    isFlicker = "flickers", isFlickerSlow = "flickersSlowly", isPulse = "pulses", isPulseSlow = "pulsesSlowly",
    isDynamic = "isDynamic", isCarriable = "canCarry",
}

function RT.resolveMesh(m, requested)
    local n = normMesh(requested)
    if #n <= 31 then return n, "direct" end
    local alias = state.meshmap[n] or (m and m.meshmap and m.meshmap[n])
    if alias and tes3.getFileExists("meshes\\" .. alias:gsub("/", "\\")) then return alias, "alias" end
    return nil, alias and "alias-missing" or "too-long"
end

-- world.mwscript.getGlobalScript(recordId[, player]) -> MWScript-like object.
-- .variables reads/writes the vanilla global script's variables through
-- tes3.getScript(id).context (MWSE tes3scriptContext). Unknown variables read as nil;
-- writing one raises. .isRunning = true/false starts/stops the global script.
-- Returns nil when no script with that id exists. The player argument is accepted
-- and ignored (single player).
function RT.getGlobalScript(recordId, player)
    if type(recordId) ~= "string" then error("getGlobalScript: recordId must be a string", 2) end
    local script = tes3.getScript(recordId)
    if not script then return nil end
    local id = script.id or recordId
    local function ctx()
        local ok, c = pcall(function() return script.context end)
        return ok and c or nil
    end
    local variables = setmetatable({}, {
        __index = function(_, k)
            local c = ctx()
            if not c then return nil end
            local ok, v = pcall(function() return c[k] end)
            if ok then return v end
            return nil
        end,
        __newindex = function(_, k, v)
            local c = ctx()
            if not c then error("omwcompat: mwscript " .. id .. " has no variable context", 2) end
            local ok = pcall(function() c[k] = v end)
            if not ok then error("omwcompat: mwscript " .. id .. " has no variable " .. tostring(k), 2) end
        end,
    })
    local running = nil
    return setmetatable({ recordId = id:lower(), variables = variables, player = player }, {
        __index = function(_, k) if k == "isRunning" then return running end end,
        __newindex = function(t, k, v)
            if k == "isRunning" then
                if v then tes3.startGlobalScript({ id = id }) else tes3.stopGlobalScript({ id = id }) end
                running = v and true or false
            else
                rawset(t, k, v)
            end
        end,
    })
end

function RT.createRecord(m, draft)
    if type(draft) ~= "table" or not draft._draftType then error("createRecord: argument must come from createRecordDraft", 2) end
    local T = draft._draftType
    local template = draft.template and objects.tesObjectOfRecord(draft.template)
    if not template then error("createRecord: drafts without a template are not supported (MVP)", 2) end
    local id = newGeneratedId()
    local copy = template:createCopy({ id = id })
    if not copy then error("createRecord: createCopy failed", 2) end
    for k, v in pairs(draft) do
        local f = SETTABLE[k]
        if f then
            local ok, err = pcall(function() copy[f] = v end)
            if not ok then RT.warnOnce("set " .. k, "createRecord: cannot set %s: %s", k, tostring(err)) end
        end
    end
    if draft.model then
        local mesh, how = RT.resolveMesh(m, draft.model)
        if mesh then
            copy.mesh = mesh:gsub("/", "\\") -- Morrowind-native separators
        else
            RT.warn("createRecord: model '%s' is longer than 31 chars and has no alias (%s); keeping template mesh '%s'",
                draft.model, how, tostring(template.mesh))
        end
        RT.log("createRecord %s <- %s model=%s (%s)", id, template.id, tostring(mesh), how)
        state.generated[objects.normId(id)] = draft.model
    end
    objects.invalidateRecordList(T)
    return objects.recordOf(copy)
end

---------------------------------------------------------------- interfaces
-- handler entries remember their owning script so a hot reload can drop them
local activation = { typeHandlers = {}, objectHandlers = {} }
local function resetInterfaces()
    activation.typeHandlers, activation.objectHandlers = {}, {}
end
local function dropHandlersOf(pred)
    for _, tbl in pairs({ activation.typeHandlers, activation.objectHandlers }) do
        for k, list in pairs(tbl) do
            local keep = {}
            for _, h in ipairs(list) do if not pred(h.owner) then keep[#keep + 1] = h end end
            tbl[k] = keep
        end
    end
end
local scriptInterfaces = {}
function RT.getInterface(name) return scriptInterfaces[name] end
function RT.makeInterfaces(m, S)
    local Activation = {
        version = 0,
        addHandlerForType = function(T, fn)
            if S.probe then return end
            local l = activation.typeHandlers[T] or {}
            l[#l + 1] = { fn = fn, owner = S }
            activation.typeHandlers[T] = l
        end,
        addHandlerForObject = function(obj, fn)
            if S.probe then return end
            local l = activation.objectHandlers[obj.id] or {}
            l[#l + 1] = { fn = fn, owner = S }
            activation.objectHandlers[obj.id] = l
        end,
    }
    local Settings = settings.interface(m, S)
    local AI = S.isActor and actors.aiInterface(function() return S.self end) or nil
    return setmetatable({}, {
        __index = function(_, k)
            if k == "Activation" then return Activation end
            if k == "AI" and AI then return AI end
            if k == "Settings" then return Settings end
            local v = scriptInterfaces[k]
            if v == nil and S.probe then return settings.dummy end
            return v
        end,
        __newindex = function() error("interfaces are read-only", 2) end,
    })
end

---------------------------------------------------------------- script host
local SAFE_GLOBALS = {
    "assert", "error", "ipairs", "next", "pairs", "pcall", "select", "tonumber", "tostring",
    "type", "unpack", "xpcall", "rawequal", "rawget", "rawset", "getmetatable", "setmetatable", "rawlen",
}
local function makeEnv(m, S)
    local env = {}
    for _, k in ipairs(SAFE_GLOBALS) do env[k] = _G[k] end
    env.math, env.string, env.table, env.coroutine = math, string, table, coroutine
    local okBit, bitlib = pcall(require, "bit")
    if okBit then env.bit = bitlib end
    env.os = { date = os.date, time = os.time, difftime = os.difftime, clock = os.clock }
    env.print = function(...)
        local p = {}
        for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
        mwse.log("[%s] %s", m.name, table.concat(p, "\t"))
    end
    env._G = env
    -- omw2mwse hard-code conversions call omwcompat.cfg(key, original value)
    local cfgSection
    env.omwcompat = {
        cfg = function(key, default)
            if not m.cfgGroup then return default end
            cfgSection = cfgSection or settings.section(m.cfgGroup, m, nil, true)
            local v = cfgSection:get(key)
            if v == nil or type(v) ~= type(default) then return default end
            return v
        end,
    }
    local cache = {}
    env.require = function(name)
        if cache[name] ~= nil then return cache[name] end
        local mod = S.modules[name]
        if mod == nil and (name:find("^openmw%.") or name:find("^openmw_aux%.")) then
            if S.probe then return settings.dummy end
            error("omwcompat: module '" .. name .. "' is not supported", 2)
        end
        if mod == nil then
            local rel = name:gsub("%.", "/")
            local f = loadHosted(m.root .. rel .. ".lua") or loadHosted(m.root .. rel .. "/init.lua")
            if not f then error("omwcompat: cannot find module '" .. name .. "' under " .. m.root, 2) end
            setfenv(f, env)
            mod = f(name)
            if mod == nil then mod = true end
        end
        cache[name] = mod
        return mod
    end
    return env
end

-- MWSE runs every main.lua it finds under MWSE/mods, at any depth. omw2mwse stores a hosted
-- script named main.lua as main.lua.omw so MWSE does not run it as a mod; load either name.
loadHosted = function(path)
    local f, err = loadfile(path)
    if f then return f end
    local f2 = loadfile(path .. ".omw")
    if f2 then return f2 end
    return nil, err
end

local LOCAL_KNOWN = { onUpdate = 1, onSave = 1, onLoad = 1, onInit = 1, onActive = 1, onInactive = 1, onActivated = 1,
    onInterfaceOverride = 1 }
local function instantiate(m, spec, probe, selfRef)
    local S = { path = spec.path, flags = spec.flags, callbacks = {}, mod = m, probe = probe }
    if selfRef then
        S.isLocal = true
        S.self = objects.selfOf(selfRef)
        local ot = selfRef.object and selfRef.object.objectType
        S.isActor = ot == tes3.objectType.npc or ot == tes3.objectType.creature
    end
    S.modules = buildModules(m, S)
    if probe then
        -- settings probe: only storage / interfaces(Settings) / l10n / util are real
        local real = { ["openmw.storage"] = true, ["openmw.interfaces"] = true, ["openmw.util"] = true }
        for k, v in pairs(S.modules) do
            if k == "openmw.core" then
                -- a high revision: probes must not stop at "requires OpenMW 0.49+" guards
                S.modules[k] = setmetatable({ l10n = v.l10n, API_REVISION = RT.PROBE_API_REVISION }, { __index = function() return settings.dummy end })
            elseif k == "openmw.async" then
                S.modules[k] = setmetatable({ callback = function(_, fn) return fn end }, { __index = function() return function() return settings.dummy end end })
            elseif not real[k] then
                S.modules[k] = settings.dummy
            end
        end
    end
    local f, err = loadHosted(m.root .. spec.path)
    if not f then reportError("load " .. spec.path, err); return nil end
    setfenv(f, makeEnv(m, S))
    if probe then
        local ok, err = pcall(f)
        if not ok then RT.warn("settings probe of %s stopped early: %s", spec.path, tostring(err)) end
        return nil
    end
    local ok, ret = safecall("run " .. spec.path, f)
    if not ok then return nil end
    if type(ret) ~= "table" then ret = {} end
    S.engineHandlers = ret.engineHandlers or {}
    S.eventHandlers = ret.eventHandlers or {}
    if ret.interfaceName and ret.interface then scriptInterfaces[ret.interfaceName] = ret.interface end
    local known = S.isLocal and LOCAL_KNOWN or { onUpdate = 1, onSave = 1, onLoad = 1, onInit = 1, onNewGame = 1, onPlayerAdded = 1,
        onObjectActive = 1, onActorActive = 1, onItemActive = 1, onActivate = 1, onInterfaceOverride = 1 }
    for k in pairs(S.engineHandlers) do
        if not known[k] then RT.warnOnce(spec.path .. k, "%s: engine handler %s is not supported", spec.path, k) end
    end
    return S
end

local function callAll(name, ...)
    for _, m in ipairs(mods) do
        for _, S in ipairs(m.scripts) do
            local h = S.engineHandlers[name]
            if h then safecall(S.path .. " " .. name, h, ...) end
        end
    end
end

---------------------------------------------------------------- save / load
local RT_KEY = "omwcompat_rt"
local function objectIdFor(o)
    local ref = objects.refOf(o)
    if ref then return objects.refId(ref, true) end
    return rawget(o, "_id")
end
local function resolveObject(id) return objects.fromId(id) end

function RT.onSave()
    if not state.ready or not tes3.player then return end
    local pdata = tes3.player.data
    for _, m in ipairs(mods) do
        for _, inst in pairs(state.localActive) do
            for _, S in ipairs(inst.scripts) do
                if S.mod == m then RT.storeLocal(S, inst) end
            end
        end
        local payload = { v = 1, scripts = {}, timers = {}, storage = m.storage, locals = m.localData }
        for _, S in ipairs(m.scripts) do
            local h = S.engineHandlers.onSave
            local data
            if h then
                local ok, r = safecall(S.path .. " onSave", h)
                if ok then data = r end
            end
            payload.scripts[S.path] = { data = data }
        end
        for _, t in ipairs(timers) do
            if t.name and t.script.mod == m and not t.script.isLocal then
                payload.timers[#payload.timers + 1] = { kind = t.kind, path = t.script.path, name = t.name, arg = t.arg,
                    left = t.kind == "sim" and (t.at - state.simTime) or nil, at = t.kind ~= "sim" and t.at or nil }
            end
        end
        local ok, s = pcall(serial.encode, payload, objectIdFor)
        if ok then
            pdata["omwcompat_" .. m.name] = s     -- one string primitive per mod
        else
            reportError(m.name .. " serialize", s)
        end
    end
    pdata[RT_KEY] = serial.encode({ v = 1, generated = state.generated, idCounter = state.idCounter, tombs = state.tombs })
end

function RT.onLoaded(e)
    state.ready = false
    timers, eventQueue, localEventQueue = {}, {}, {}
    state.localActive = {}
    state.nextFrame, state.activeQueue, state.activeQueued = {}, {}, {}
    state.passthrough = {}
    state.activation = nil
    objects.reset(); objects.resetCells(); objects.resetRecordCaches()
    resetInterfaces(); scriptInterfaces = {}
    settings.reset()
    local pdata = tes3.player and tes3.player.data or {}
    local rtp = nil
    if pdata[RT_KEY] then
        local ok, r = pcall(serial.decode, pdata[RT_KEY])
        if ok then rtp = r else reportError("decode runtime payload", r) end
    end
    state.generated = rtp and rtp.generated or {}
    state.idCounter = rtp and rtp.idCounter or 0
    state.tombs = rtp and rtp.tombs or {}
    for _, m in ipairs(mods) do
        m.scripts = {}
        local payload
        local raw = pdata["omwcompat_" .. m.name]
        if type(raw) == "string" then
            local ok, r = pcall(serial.decode, raw, resolveObject)
            if ok then payload = r else reportError(m.name .. " decode", r) end
        end
        m.storage = payload and payload.storage or {}
        m.localData = payload and payload.locals or {}
        for _, spec in ipairs(m.globalSpecs) do
            local S = instantiate(m, spec)
            if S then m.scripts[#m.scripts + 1] = S end
        end
        for _, S in ipairs(m.scripts) do
            local saved = payload and payload.scripts and payload.scripts[S.path]
            if saved then
                if S.engineHandlers.onLoad then safecall(S.path .. " onLoad", S.engineHandlers.onLoad, saved.data, nil) end
            else
                if S.engineHandlers.onInit then safecall(S.path .. " onInit", S.engineHandlers.onInit, nil) end
            end
        end
        if payload and payload.timers then
            for _, t in ipairs(payload.timers) do
                for _, S in ipairs(m.scripts) do
                    if S.path == t.path then
                        addTimer({ kind = t.kind, at = t.kind == "sim" and (state.simTime + (t.left or 0)) or t.at,
                            script = S, name = t.name, arg = t.arg })
                    end
                end
            end
        end
    end
    state.ready = true
    if e and e.newGame then callAll("onNewGame") end
    local p = playerObject()
    if p then callAll("onPlayerAdded", p) end
    -- OpenMW reports every active object after load; MWSE does not refire
    -- referenceActivated for an unchanged cell, so synthesize it.
    for _, cell in ipairs(tes3.getActiveCells() or {}) do
        for ref in cell:iterateReferences() do RT.queueActive(ref) end
    end
end

---------------------------------------------------------------- local scripts
-- OpenMW attaches NPC/CREATURE/... scripts to every matching object; they run while
-- the object is in an active cell. omwcompat follows the same rule with MWSE events:
--   attach  : the object becomes active (referenceActivated, or the active cells after
--             a load) -> one instance per (object, script): chunk runs, then onInit the
--             first time or onLoad(saved data) after that, then onActive.
--   detach  : referenceDeactivated, or the object is disabled/deleted -> onInactive,
--             onSave data and named timers are kept per object, the instance is dropped.
--             Unsavable timers are dropped (as OpenMW does on a save/load).
--   save    : active instances are saved too; data lives in the mod's save payload,
--             keyed by the object's stable id. Objects whose scripts keep nothing never
--             get an id written to their reference.
local LOCAL_FLAGS = {
    NPC = { "npc" }, CREATURE = { "creature" }, ACTOR = { "npc", "creature" },
    CONTAINER = { "container" }, DOOR = { "door" }, LIGHT = { "light" }, ACTIVATOR = { "activator" },
}
LOCAL_FLAG_NAMES = "NPC, CREATURE, ACTOR, CONTAINER, DOOR, LIGHT, ACTIVATOR"
RT.LOCAL_FLAGS = LOCAL_FLAGS

local function specMatches(spec, ot)
    for _, f in ipairs(spec.localFlags) do
        for _, n in ipairs(LOCAL_FLAGS[f]) do
            if tes3.objectType[n] == ot then return true end
        end
    end
    return false
end

function RT.storeLocal(S, inst)
    local m = S.mod
    local data
    local h = S.engineHandlers.onSave
    if h then
        local ok, r = safecall(S.path .. " onSave", h)
        if ok then data = r end
    end
    local tl = {}
    for _, t in ipairs(timers) do
        if t.script == S and t.name then
            tl[#tl + 1] = { kind = t.kind, name = t.name, arg = t.arg,
                left = t.kind == "sim" and (t.at - state.simTime) or nil, at = t.kind ~= "sim" and t.at or nil }
        end
    end
    local ref = objects.refOf(inst.self)
    if not ref or ref.deleted then m.localData[inst.key] = nil; return end
    local need = data ~= nil or #tl > 0 or S.engineHandlers.onInit ~= nil
    local key = inst.key
    if need then
        key = objects.refId(ref, true) -- reuses the session id, so it stays inst.key
        inst.key = key
    end
    local per = m.localData[key] or {}
    per[S.path] = need and { init = true, data = data, timers = tl } or nil
    m.localData[key] = next(per) and per or nil
end

function RT.attachLocal(ref)
    if not state.ready or ref == tes3.player or not ref.object then return end
    local ot = ref.object.objectType
    local list
    for _, m in ipairs(mods) do
        for _, spec in ipairs(m.localSpecs) do
            if specMatches(spec, ot) then
                list = list or {}
                list[#list + 1] = { m, spec }
            end
        end
    end
    if not list then return end
    local key = objects.refId(ref, false)
    if state.localActive[key] then return end
    local inst = { key = key, self = objects.selfOf(ref), scripts = {} }
    state.localActive[key] = inst
    for _, e in ipairs(list) do
        local m, spec = e[1], e[2]
        local S = instantiate(m, spec, false, ref)
        if S then
            S.inst = inst
            inst.scripts[#inst.scripts + 1] = S
            local saved = m.localData[key] and m.localData[key][spec.path]
            if saved and saved.init then
                if S.engineHandlers.onLoad then safecall(spec.path .. " onLoad", S.engineHandlers.onLoad, saved.data, nil) end
            elseif S.engineHandlers.onInit then
                safecall(spec.path .. " onInit", S.engineHandlers.onInit, nil)
            end
            for _, t in ipairs(saved and saved.timers or {}) do
                addTimer({ kind = t.kind, at = t.kind == "sim" and (state.simTime + (t.left or 0)) or t.at,
                    script = S, name = t.name, arg = t.arg })
            end
        end
    end
    for _, S in ipairs(inst.scripts) do
        local h = S.engineHandlers.onActive
        if h then safecall(S.path .. " onActive", h) end
    end
end

function RT.detachLocal(key)
    local inst = state.localActive[key]
    if not inst then return end
    state.localActive[key] = nil
    for _, S in ipairs(inst.scripts) do
        local h = S.engineHandlers.onInactive
        if h then safecall(S.path .. " onInactive", h) end
        RT.storeLocal(S, inst)
        S.dead = true
    end
    local keep = {}
    for _, t in ipairs(timers) do if not (t.script and t.script.dead) then keep[#keep + 1] = t end end
    timers = keep
end

function RT.onReferenceDeactivated(ref)
    if not state.ready or not ref then return end
    local ok, key = pcall(objects.refId, ref, false)
    if ok and state.localActive[key] then RT.detachLocal(key) end
end

function RT.updateLocals(dt)
    if next(state.localActive) == nil then return end
    local gone = {}
    for key, inst in pairs(state.localActive) do
        local ref = objects.refOf(inst.self)
        if not ref or ref.deleted or ref.disabled or objects.isTomb(ref) then
            gone[#gone + 1] = key
        elseif dt > 0 then
            for _, S in ipairs(inst.scripts) do
                local h = S.engineHandlers.onUpdate
                if h and not S.dead then safecall(S.path .. " onUpdate", h, dt) end
            end
        end
    end
    for _, key in ipairs(gone) do RT.detachLocal(key) end
end

function RT.isLocalActive(obj) return state.localActive[rawget(obj, "_id")] ~= nil end
function RT.hasLocalScript(obj, path)
    local inst = state.localActive[rawget(obj, "_id")]
    if not inst or type(path) ~= "string" then return false end
    local want = path:gsub("\\", "/"):lower()
    for _, S in ipairs(inst.scripts) do
        if S.path:gsub("\\", "/"):lower() == want then return true end
    end
    return false
end
RT.localInstances = function() return state.localActive end

---------------------------------------------------------------- object activity
function RT.queueActive(ref)
    if not state.ready or ref.deleted or ref.disabled or objects.isTomb(ref) then return end
    local w = objects.wrap(ref)
    local id = rawget(w, "_id")
    if state.activeQueued[id] then return end
    state.activeQueued[id] = true
    state.activeQueue[#state.activeQueue + 1] = w
end
function RT.objectBecameActive(w)
    local ref = objects.refOf(w)
    if ref then RT.queueActive(ref) end
end
local function flushActive()
    if #state.activeQueue == 0 then return end
    local q = state.activeQueue
    state.activeQueue, state.activeQueued = {}, {}
    local types = objects.types
    for _, w in ipairs(q) do
        if w:isValid() then
            local ref = objects.refOf(w)
            if ref then RT.attachLocal(ref) end
            callAll("onObjectActive", w)
            local T = w.type
            if T == types.NPC or T == types.Creature then callAll("onActorActive", w)
            elseif T and T._isItem then callAll("onItemActive", w) end
        end
    end
end

---------------------------------------------------------------- activation (R3)
local function finishPickup(actorRef, orig)
    if orig.deleted then return end
    objects.setTomb(orig, false)
    orig:enable()
    local node = orig.sceneNode
    if node then pcall(function() node.appCulled = true end) end
    pcall(function() orig:detachDynamicLightFromAffectedNodes() end)
    state.passthrough[orig] = true
    actorRef:activate(orig)
    state.passthrough[orig] = nil
    if not orig.deleted and not orig.disabled then
        -- vanilla did not take it (not carriable, or blocked by another mod): show it again
        if node then pcall(function() node.appCulled = false end) end
        RT.queueActive(orig)
    end
end

function RT.onActivate(e)
    if not state.ready then return end
    local targetRef, actorRef = e.target, e.activator
    if not targetRef or not actorRef then return end
    if state.passthrough[targetRef] then return end
    local target, actor = objects.wrap(targetRef), objects.wrap(actorRef)
    local ctx = { targetRef = targetRef, actorRef = actorRef }
    state.activation = ctx
    local blocked = false
    local function run(list, where)
        if not list then return end
        for i = #list, 1, -1 do
            local ok, r = safecall(where, list[i].fn, target, actor)
            if ok and r == false then blocked = true; return true end
        end
    end
    local stop = run(activation.objectHandlers[rawget(target, "_id")], "activation object handler")
    if not stop then stop = run(activation.typeHandlers[target.type], "activation type handler") end
    if not stop then
        for _, m in ipairs(mods) do
            for _, S in ipairs(m.scripts) do
                local h = S.engineHandlers.onActivate
                if h then safecall(S.path .. " onActivate", h, target, actor) end
            end
        end
        local inst = state.localActive[rawget(target, "_id")]
        if inst then
            for _, S in ipairs(inst.scripts) do
                local h = S.engineHandlers.onActivated
                if h then safecall(S.path .. " onActivated", h, actor) end
            end
        end
    end
    state.activation = nil
    local orig = ctx.pickupOriginal
    if orig then
        state.nextFrame[#state.nextFrame + 1] = function() finishPickup(actorRef, orig) end
        return false
    end
    if blocked or not target:isValid() then return false end
end

---------------------------------------------------------------- frame
function RT.onEnterFrame(e)
    if not state.ready or not tes3.player then return end
    state.frame = state.frame + 1
    local nf = state.nextFrame
    if #nf > 0 then
        state.nextFrame = {}
        for _, f in ipairs(nf) do safecall("deferred", f) end
    end
    local dt = e.menuMode and 0 or (e.delta or 0)
    state.simTime = state.simTime + dt
    deliverEvents()
    flushActive()
    if dt > 0 then tickTimers() end
    callAll("onUpdate", dt)
    RT.updateLocals(dt)
end

---------------------------------------------------------------- hot reload (settings)
-- Re-instantiate one mod's scripts in place: onSave -> rerun chunk -> onLoad(data).
-- Used when an MCM change touches a converted constant that is read at load time.
function RT.reloadMod(m)
    if not state.ready then return false end
    local saved = {}
    for _, S in ipairs(m.scripts) do
        local h = S.engineHandlers.onSave
        if h then local ok, r = safecall(S.path .. " onSave", h); if ok then saved[S.path] = r end end
    end
    local old = {}
    for _, S in ipairs(m.scripts) do old[S] = true end
    local keep = {}
    for _, t in ipairs(timers) do
        if not old[t.script] then keep[#keep + 1] = t elseif t.name then t.rebind = t.script.path; keep[#keep + 1] = t end
    end
    timers = keep
    dropHandlersOf(function(owner) return old[owner] end)
    settings.dropSubscribers(function(owner) return old[owner] end)
    m.scripts = {}
    for _, spec in ipairs(m.globalSpecs) do
        local S = instantiate(m, spec)
        if S then m.scripts[#m.scripts + 1] = S end
    end
    for _, S in ipairs(m.scripts) do
        if S.engineHandlers.onLoad then safecall(S.path .. " onLoad", S.engineHandlers.onLoad, saved[S.path], nil) end
        for _, t in ipairs(timers) do if t.rebind == S.path then t.script = S; t.rebind = nil end end
    end
    for _, cell in ipairs(tes3.getActiveCells() or {}) do
        for ref in cell:iterateReferences() do
            if not ref.deleted and not ref.disabled and not objects.isTomb(ref) then
                local w = objects.wrap(ref)
                for _, S in ipairs(m.scripts) do
                    local h = S.engineHandlers.onObjectActive
                    if h then RT.defer(function() if w:isValid() then safecall(S.path .. " onObjectActive", h, w) end end) end
                end
            end
        end
    end
    -- local scripts of this mod: save, detach and re-attach on every active object
    local again = {}
    for key, inst in pairs(state.localActive) do
        for _, S in ipairs(inst.scripts) do
            if S.mod == m then again[#again + 1] = key; break end
        end
    end
    for _, key in ipairs(again) do
        local ref = objects.refOf(state.localActive[key].self)
        RT.detachLocal(key)
        if ref then RT.attachLocal(ref) end
    end
    mwse.log("[omwcompat] %s reloaded to apply changed settings", m.name)
    return true
end

---------------------------------------------------------------- mwsuite notice
-- Converted mods are maintained by mwsuite; original authors must not get support
-- requests for them. They all appear in one Mod Config Menu entry, "MW Conversions",
-- one tab per mod (see conversions.lua), instead of one list entry each.
RT.MCM_NAME = conversions.NAME
function RT.notice(m)
    local a = conversions.about(m)
    local s = "Unofficial mwsuite conversion of " .. a.title .. " (original author: " .. a.author .. "). " .. conversions.SUPPORT
    if a.license then s = s .. " Original license: " .. a.license .. "." end
    if a.url then s = s .. " Original: " .. a.url end
    return s
end

---------------------------------------------------------------- settings / MCM
local function probeSettings(m)
    for _, spec in ipairs(m.spec.scripts) do instantiate(m, spec, true) end
end
RT.probeSettings = probeSettings
function RT.onModConfigReady()
    RT.mcm = RT.mcm or {}
    for _, m in ipairs(mods) do
        if m.spec.probeSettings then probeSettings(m) end
    end
    if #mods == 0 then return end
    local summaries, template = conversions.build(mods, settings.addTab, settings.closeMod)
    RT.mcm = summaries
    RT.mcmTemplate = template
end

---------------------------------------------------------------- registration
local wired = false
local function wire()
    if wired then return end
    wired = true
    event.register(tes3.event.initialized, function() objects.initTypes(); actors.extendTypes(objects.types) end, { priority = 1000 })
    event.register(tes3.event.loaded, RT.onLoaded, { priority = -100 })
    event.register(tes3.event.save, RT.onSave, { priority = 100 })
    event.register(tes3.event.enterFrame, RT.onEnterFrame)
    event.register(tes3.event.activate, RT.onActivate, { priority = 10 })
    event.register(tes3.event.referenceActivated, function(e) RT.queueActive(e.reference) end)
    if tes3.event.referenceDeactivated then
        event.register(tes3.event.referenceDeactivated, function(e) RT.onReferenceDeactivated(e.reference) end)
    end
    event.register(tes3.event.modConfigReady, RT.onModConfigReady)
end

-- spec = { mod = "Name", root = "Data Files/MWSE/mods/mwsuite/openmw/Name/omw/", scripts = {{flags={"GLOBAL"}, path="scripts/x.lua"}},
--          meshmap = { ["long/path.nif"] = "omwc/x/abcdef12.nif" }, debug = false,
--          probeSettings = true,      -- collect I.Settings declarations for the MCM at modConfigReady
--          settings = {               -- omw2mwse hard-code conversions (sidecar)
--              group = "omw2mwse_Name", page = { key=, name=, description= },
--              settings = { { key=, name=, description=, renderer=, default=, min=, max=, integer=, apply="live"|"reload" } } } }
function RT.register(spec)
    assert(type(spec) == "table" and spec.mod and spec.root and spec.scripts, "omwcompat.register: bad spec")
    -- runtimeVersion: the omwcompat the mod was converted with (omw2mwse 0.2.3+). The generated
    -- main.lua logs the one mismatch line itself (so it also works with older runtimes); here
    -- the versions only go into the warning for script flags this runtime cannot host.
    local built = spec.runtimeVersion and tostring(spec.runtimeVersion) or nil
    local versions = ""
    if built and built ~= RT.VERSION then
        versions = string.format(" (built for omwcompat %s, loaded %s)", built, RT.VERSION)
    end
    local root = spec.root:gsub("\\", "/")
    if root:sub(-1) ~= "/" then root = root .. "/" end
    local m = { name = spec.mod, builtFor = built, title = spec.title, credits = spec.credits, root = root, spec = spec, scripts = {}, storage = {}, meshmap = {},
        globalSpecs = {}, localSpecs = {}, localData = {} }
    for _, sp in ipairs(spec.scripts) do
        local isGlobal, lflags, skipped = false, {}, {}
        for _, f in ipairs(sp.flags or {}) do
            f = tostring(f):upper()
            if f == "GLOBAL" then isGlobal = true
            elseif LOCAL_FLAGS[f] then lflags[#lflags + 1] = f
            else skipped[#skipped + 1] = f end
        end
        if isGlobal then m.globalSpecs[#m.globalSpecs + 1] = sp end
        if #lflags > 0 then m.localSpecs[#m.localSpecs + 1] = { path = sp.path, flags = sp.flags, localFlags = lflags } end
        if #skipped > 0 then
            RT.warn("%s: script flag(s) %s of %s are not hosted (GLOBAL and %s are)%s", spec.mod, table.concat(skipped, ","),
                sp.path, LOCAL_FLAG_NAMES, versions)
        end
    end
    for k, v in pairs(spec.meshmap or {}) do
        local nk = normMesh(k)
        m.meshmap[nk] = v
        state.meshmap[nk] = v
    end
    if spec.debug then RT.debug = true end
    if spec.settings then
        local cs = spec.settings
        m.cfgGroup = cs.group or ("omw2mwse_" .. m.name)
        local pageKey = (cs.page and cs.page.key) or m.cfgGroup
        settings.registerPage(m, { key = pageKey, name = cs.page and cs.page.name or m.name,
            description = cs.page and cs.page.description })
        local reloadKeys, list = {}, {}
        for _, s in ipairs(cs.settings or {}) do
            local note = s.apply == "reload" and "Applies when a save is loaded or when this menu is closed in game."
                or "Applies immediately."
            list[#list + 1] = { key = s.key, name = s.name, description = s.description, renderer = s.renderer,
                default = s.default, min = s.min, max = s.max, integer = s.integer, argument = s.argument, mcmNote = note }
            if s.apply == "reload" then reloadKeys[s.key] = true end
        end
        settings.registerGroup(m, { key = m.cfgGroup, page = pageKey, name = cs.groupName or "Tunables", settings = list,
            permanentStorage = true, order = -1 })
        m.cfgNote = cs.note
        m.reloadPending = false
        m.onSettingChanged = function(groupKey, key)
            if groupKey == m.cfgGroup and reloadKeys[key] then m.reloadPending = true end
        end
        m.onSettingsClosed = function()
            if m.reloadPending and state.ready then
                m.reloadPending = false
                RT.reloadMod(m)
            end
        end
    end
    mods[#mods + 1] = m
    wire()
    mwse.log("[omwcompat %s] registered %s (%d script(s)). %s", RT.VERSION, m.name, #spec.scripts, RT.notice(m))
    return m
end

RT.settings = settings
RT.objects = objects
RT.util = util
RT.serial = serial
return RT
