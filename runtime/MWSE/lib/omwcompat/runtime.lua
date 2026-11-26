-- omwcompat.runtime: hosts unmodified OpenMW GLOBAL Lua scripts inside MWSE.
-- See DESIGN.md (hybrid architecture, runtime first) and docs/RUNTIME.md.
-- MIT, Copyright (c) 2026 dej (dejunai). Built with Grok Bot.
local util = require("omwcompat.util")
local serial = require("omwcompat.serial")
local objects = require("omwcompat.objects")

local RT = { VERSION = "0.1.0", API_REVISION = 70 }
objects.init(RT)

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
        if now(t.kind) >= t.at then due[#due + 1] = t else keep[#keep + 1] = t end
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
local function deliverEvents()
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

---------------------------------------------------------------- storage (minimal)
local function makeSection(store, name)
    local Sec = {}
    local subs = {}
    local function data() store[name] = store[name] or {}; return store[name] end
    function Sec:get(k)
        local v = data()[k]
        if v == nil and RT.settingDefaults[name] then v = RT.settingDefaults[name][k] end
        if type(v) == "table" then return util.makeReadOnly(v) end
        return v
    end
    function Sec:getCopy(k)
        local v = self:get(k)
        if type(v) ~= "table" then return v end
        local c = {}; for a, b in pairs(data()[k] or {}) do c[a] = b end; return c
    end
    function Sec:set(k, v)
        data()[k] = v
        for _, cb in ipairs(subs) do safecall("storage subscriber", cb, name, k) end
    end
    function Sec:asTable() local c = {}; for a, b in pairs(RT.settingDefaults[name] or {}) do c[a] = b end; for a, b in pairs(data()) do c[a] = b end; return c end
    function Sec:reset(t) store[name] = {}; if t then for a, b in pairs(t) do store[name][a] = b end end end
    function Sec:removeOnExit() end
    function Sec:setLifeTime() end
    function Sec:subscribe(cb) subs[#subs + 1] = cb end
    return Sec
end
RT.settingDefaults = {}

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
        l10n = function() return function(key) return key end end,
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
        mwscript = setmetatable({}, { __index = function(_, k)
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
        globalSection = function(name) return makeSection(m.storage, name) end,
        playerSection = function(name) return makeSection(m.storage, name) end,
        allPlayerSections = function() return m.storage end,
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

    local auxUtil = unsupportedProxy("openmw_aux.util", {
        deepToString = function(v, d)
            local ok, s = pcall(serial.encode, v, function(o) return o.id end)
            return ok and s or tostring(v)
        end,
        callEventHandlers = function(handlers, ...)
            for i = #handlers, 1, -1 do if handlers[i](...) == false then return true end end
            return false
        end,
        mapFilter = function(arr, f) local o = {}; for _, v in ipairs(arr) do if f(v) then o[#o + 1] = v end end; return o end,
        mapFilterSort = function(arr, f) local o = {}; for _, v in ipairs(arr) do local s = f(v); if s then o[#o + 1] = v end end; return o end,
        findMinScore = function(arr, f)
            local best, bi, bs
            for i, v in ipairs(arr) do local s = f(v); if s and (not bs or s < bs) then best, bi, bs = v, i, s end end
            return best, bi, bs
        end,
    })

    return {
        ["openmw.core"] = core,
        ["openmw.world"] = world,
        ["openmw.types"] = unsupportedProxy("openmw.types", {}, types),
        ["openmw.util"] = util,
        ["openmw.async"] = makeAsync(S),
        ["openmw.storage"] = storage,
        ["openmw.vfs"] = vfs,
        ["openmw.interfaces"] = RT.interfaces,
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
            copy.mesh = mesh
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
local activation = { typeHandlers = {}, objectHandlers = {} }
local function resetInterfaces()
    activation.typeHandlers, activation.objectHandlers = {}, {}
end
local Activation = {
    version = 0,
    addHandlerForType = function(T, fn)
        local l = activation.typeHandlers[T] or {}
        l[#l + 1] = fn
        activation.typeHandlers[T] = l
    end,
    addHandlerForObject = function(obj, fn)
        local l = activation.objectHandlers[obj.id] or {}
        l[#l + 1] = fn
        activation.objectHandlers[obj.id] = l
    end,
}
local Settings = {
    version = 1,
    registerPage = function() end,
    registerRenderer = function() end,
    registerGroup = function(g)
        local d = RT.settingDefaults[g.key] or {}
        for _, s in ipairs(g.settings or {}) do d[s.key] = s.default end
        RT.settingDefaults[g.key] = d
    end,
    updateRendererArgument = function() end,
}
local scriptInterfaces = {}
RT.interfaces = setmetatable({}, {
    __index = function(_, k)
        if k == "Activation" then return Activation end
        if k == "Settings" then return Settings end
        return scriptInterfaces[k]
    end,
    __newindex = function() error("interfaces are read-only", 2) end,
})

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
    local cache = {}
    env.require = function(name)
        if cache[name] ~= nil then return cache[name] end
        local mod = S.modules[name]
        if mod == nil and (name:find("^openmw%.") or name:find("^openmw_aux%.")) then
            error("omwcompat: module '" .. name .. "' is not supported", 2)
        end
        if mod == nil then
            local rel = name:gsub("%.", "/")
            local f = loadfile(m.root .. rel .. ".lua") or loadfile(m.root .. rel .. "/init.lua")
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

local function instantiate(m, spec)
    local S = { path = spec.path, flags = spec.flags, callbacks = {}, mod = m }
    S.modules = buildModules(m, S)
    local f, err = loadfile(m.root .. spec.path)
    if not f then reportError("load " .. spec.path, err); return nil end
    setfenv(f, makeEnv(m, S))
    local ok, ret = safecall("run " .. spec.path, f)
    if not ok then return nil end
    if type(ret) ~= "table" then ret = {} end
    S.engineHandlers = ret.engineHandlers or {}
    S.eventHandlers = ret.eventHandlers or {}
    if ret.interfaceName and ret.interface then scriptInterfaces[ret.interfaceName] = ret.interface end
    local known = { onUpdate = 1, onSave = 1, onLoad = 1, onInit = 1, onNewGame = 1, onPlayerAdded = 1,
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
        local payload = { v = 1, scripts = {}, timers = {}, storage = m.storage }
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
            if t.name and t.script.mod == m then
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
    timers, eventQueue = {}, {}
    state.nextFrame, state.activeQueue, state.activeQueued = {}, {}, {}
    state.passthrough = {}
    state.activation = nil
    objects.reset(); objects.resetCells(); objects.resetRecordCaches()
    resetInterfaces(); scriptInterfaces = {}
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
        for _, spec in ipairs(m.spec.scripts) do
            local isGlobal = false
            for _, f in ipairs(spec.flags or {}) do if f == "GLOBAL" then isGlobal = true end end
            if isGlobal then
                local S = instantiate(m, spec)
                if S then m.scripts[#m.scripts + 1] = S end
            else
                RT.warnOnce(m.name .. spec.path, "%s: only GLOBAL scripts are hosted in this MVP; skipped %s (%s)",
                    m.name, spec.path, table.concat(spec.flags or {}, ","))
            end
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
            local ok, r = safecall(where, list[i], target, actor)
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
end

---------------------------------------------------------------- registration
local wired = false
local function wire()
    if wired then return end
    wired = true
    event.register(tes3.event.initialized, function() objects.initTypes() end, { priority = 1000 })
    event.register(tes3.event.loaded, RT.onLoaded, { priority = -100 })
    event.register(tes3.event.save, RT.onSave, { priority = 100 })
    event.register(tes3.event.enterFrame, RT.onEnterFrame)
    event.register(tes3.event.activate, RT.onActivate, { priority = 10 })
    event.register(tes3.event.referenceActivated, function(e) RT.queueActive(e.reference) end)
end

-- spec = { mod = "Name", root = "Data Files/MWSE/omw/Name/", scripts = {{flags={"GLOBAL"}, path="scripts/x.lua"}},
--          meshmap = { ["long/path.nif"] = "omwc/x/abcdef12.nif" }, debug = false }
function RT.register(spec)
    assert(type(spec) == "table" and spec.mod and spec.root and spec.scripts, "omwcompat.register: bad spec")
    local root = spec.root:gsub("\\", "/")
    if root:sub(-1) ~= "/" then root = root .. "/" end
    local m = { name = spec.mod, root = root, spec = spec, scripts = {}, storage = {}, meshmap = {} }
    for k, v in pairs(spec.meshmap or {}) do
        local nk = normMesh(k)
        m.meshmap[nk] = v
        state.meshmap[nk] = v
    end
    if spec.debug then RT.debug = true end
    mods[#mods + 1] = m
    wire()
    mwse.log("[omwcompat %s] registered %s (%d script(s))", RT.VERSION, m.name, #spec.scripts)
    return m
end

RT.objects = objects
RT.util = util
RT.serial = serial
return RT
