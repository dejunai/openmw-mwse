-- omwcompat.diag: read-only inspection and probe hooks for the optional omwcompat_smoketest mod
-- (Data Files/MWSE/mods/mwsuite/openmw/omwcompat_smoketest). Nothing here is used by the runtime
-- itself, nothing here writes to the game world, to a save (tes3.player.data) or to a config file.
--
--   omwcompat.diag.REVISION                         hook revision (1)
--   omwcompat.diag.inspect()                        copy of what is registered and running
--   omwcompat.diag.compileCheck(modName, path)      does the hosted script file parse? (not run)
--   omwcompat.diag.readSettings(modName)            every registered setting read once (never set)
--   omwcompat.diag.capture(fn, ...)                 run fn with library-log lines captured, and the
--                                                   counters a probe touches restored afterwards
--   omwcompat.diag.probeStubs(modName)              animation / controls / sound gate stubs
--   omwcompat.diag.roundTrips()                     settings storage and save payload encoder round trips
--   omwcompat.diag.payloadCheck(modName)            the mod's real save payload encodes and decodes
-- Probes return lists of { name = "...", ok = true|false, detail = "..." }.
-- MIT, Copyright (c) 2026 dej (dejunai). Built with Grok Bot.
local D = { REVISION = 1 }

function D.install(RT, env)
    local mods, state, actors, settings = env.mods, env.state, env.actors, env.settings
    local serial, timing, objects, errCount = env.serial, env.timing, env.objects, env.errCount
    local loadHosted = env.loadHosted

    local function copy(v)
        if type(v) ~= "table" then return v end
        local c = {}
        for k, x in pairs(v) do c[k] = copy(x) end
        return c
    end
    local function sortedKeys(t)
        local out = {}
        for k in pairs(t or {}) do out[#out + 1] = tostring(k) end
        table.sort(out)
        return out
    end
    local function modOf(name)
        for _, m in ipairs(mods) do if m.name == name then return m end end
    end
    local function result(list, name, ok, detail)
        list[#list + 1] = { name = name, ok = ok and true or false, detail = detail }
    end

    local X = { REVISION = D.REVISION }

    ------------------------------------------------------------ inspect
    function X.inspect()
        local out = {
            version = RT.VERSION, apiRevision = RT.API_REVISION, ready = state.ready == true, frame = state.frame,
            logPath = RT.LOG_PATH, logFallback = RT.logFallback() == true, logOpenError = RT.logOpenError(),
            soundGate = { enabled = RT.soundGate.enabled, removed = RT.soundGate.removed, offCopy = RT.soundGate.offCopy },
            timingEnabled = timing.enabled == true,
            errors = copy(errCount),
            calls = {},      -- "script\0handler" -> calls, per mod: calls[mod][script][handler]
            mods = {},
            hasMcm = RT.mcm ~= nil,
        }
        for _, e in ipairs(timing.snapshot().scripts) do
            local c = out.calls
            c[e.mod] = c[e.mod] or {}
            c[e.mod][e.script] = c[e.mod][e.script] or {}
            c[e.mod][e.script][e.handler] = e.calls
        end
        for _, m in ipairs(mods) do
            local im = { name = m.name, title = m.title, builtFor = m.builtFor, disabled = m.disabled == true, root = m.root,
                globalSpecs = {}, localSpecs = {}, playerSpecs = {}, customSpecs = {}, scripts = {},
                localInstances = 0, playerInstances = 0, frozen = m.frozen ~= nil,
                hasSettings = m.cfgGroup ~= nil or m.spec.probeSettings == true,
                mcmTab = RT.mcm and RT.mcm[m.name] ~= nil and not (RT.mcm[m.name] and RT.mcm[m.name].error),
                mcmError = RT.mcm and RT.mcm[m.name] and RT.mcm[m.name].error or nil }
            for _, sp in ipairs(m.globalSpecs) do im.globalSpecs[#im.globalSpecs + 1] = sp.path end
            for _, sp in ipairs(m.localSpecs) do im.localSpecs[#im.localSpecs + 1] = { path = sp.path, flags = copy(sp.localFlags) } end
            for _, sp in ipairs(m.playerSpecs) do im.playerSpecs[#im.playerSpecs + 1] = sp.path end
            for k, sp in pairs(m.customSpecs) do im.customSpecs[#im.customSpecs + 1] = sp.path or k end
            table.sort(im.customSpecs)
            for _, S in ipairs(m.scripts) do
                im.scripts[#im.scripts + 1] = { path = S.path, handlers = sortedKeys(S.engineHandlers),
                    events = sortedKeys(S.eventHandlers), isLocal = false }
            end
            for _, inst in pairs(state.localActive) do
                for _, S in ipairs(inst.scripts) do if S.mod == m then im.localInstances = im.localInstances + 1 end end
            end
            if state.playerInst then
                for _, S in ipairs(state.playerInst.scripts) do
                    if S.mod == m and not S.dead then
                        im.playerInstances = im.playerInstances + 1
                        im.scripts[#im.scripts + 1] = { path = S.path, handlers = sortedKeys(S.engineHandlers),
                            events = sortedKeys(S.eventHandlers), isLocal = true, isPlayer = true }
                    end
                end
            end
            out.mods[#out.mods + 1] = im
        end
        return out
    end

    -- the hosted script file parses (loadfile only; the chunk is never run)
    function X.compileCheck(modName, path)
        local m = modOf(modName)
        if not m then return false, "mod is not registered" end
        local f, err = loadHosted(m.root .. path)
        if f then return true end
        return false, tostring(err)
    end

    -- every registered setting of the mod, read once through a read-only section (nothing is set)
    function X.readSettings(modName)
        local m = modOf(modName)
        local out = {}
        if not m then return out end
        for _, key in ipairs(settings.registry.groupOrder) do
            local g = settings.registry.groups[key]
            if g and g.mod == m then
                local sec = settings.section(key, m, nil, true)
                for _, s in ipairs(g.settings) do
                    local ok, v = pcall(sec.get, sec, s.key)
                    out[#out + 1] = { group = key, key = s.key, ok = ok, value = ok and v or nil, err = not ok and tostring(v) or nil,
                        default = s.default, renderer = s.renderer, min = s.min, max = s.max }
                end
            end
        end
        return out
    end

    ------------------------------------------------------------ capture sandbox
    -- Runs fn(...) with every library-log line going into a list (warnOnce keys are private to the
    -- capture), then puts back what a probe may have bumped: error counts, sound gate counters,
    -- animation call counters. Returns ok, firstResult, lines.
    function X.capture(fn, ...)
        local list = { seen = {} }
        local errSave = copy(errCount)
        local g = RT.soundGate
        local gate = { removed = g.removed, offCopy = g.offCopy }
        local anim = copy(actors.animCalls)
        local prev = RT._setCapture(list)
        local ok, a = pcall(fn, ...)
        RT._setCapture(prev)
        for k in pairs(errCount) do errCount[k] = nil end
        for k, v in pairs(errSave) do errCount[k] = v end
        g.removed, g.offCopy = gate.removed, gate.offCopy
        for k in pairs(actors.animCalls) do actors.animCalls[k] = nil end
        for k, v in pairs(anim) do actors.animCalls[k] = v end
        list.seen = nil
        return ok, a, list
    end

    local function count(lines, needle)
        local n = 0
        for _, l in ipairs(lines) do if l:find(needle, 1, true) then n = n + 1 end end
        return n
    end

    ------------------------------------------------------------ stub probes
    function X.probeStubs(modName)
        local res = {}
        modName = modName or "omwcompat-smoketest"
        -- openmw.animation: every call returns quietly, and the mod is told once
        local ok, err, lines = X.capture(function()
            local A = actors.animationModule(modName)
            assert(type(A.PRIORITY) == "table" and A.PRIORITY.Scripted == 13, "PRIORITY constants")
            assert(A.isPlaying({}, "idle") == false, "isPlaying must be false")
            assert(A.hasGroup({}, "idle") == false, "hasGroup must be false")
            assert(A.getActiveGroup({}, 1) == nil, "getActiveGroup must be nil")
            assert(A.playBlended({}, "idle") == nil, "playBlended returns nothing")
            assert(A.cancel({}, "idle") == nil, "cancel returns nothing")
            assert(A.aFutureCallThatDoesNotExist({}, 1, 2) == nil, "an unknown call is a no-op")
            return true
        end)
        local warns = count(lines, "animations are not ported")
        result(res, "animation stubs", ok and err == true and warns == 1,
            ok and (warns == 1 and "6 calls returned quietly, one warning per mod" or ("expected 1 warning, saw " .. warns)) or tostring(err))
        ok, err = X.capture(function()
            local I = actors.animationControllerInterface(modName)
            assert(I.version == 1, "AnimationController version")
            assert(I.addTextKeyHandler(function() end) == nil)
            assert(I.addPlayBlendedAnimationHandler(function() end) == nil)
            assert(I.playBlendedAnimation({}, "idle", {}) == nil)
            return true
        end)
        result(res, "I.AnimationController stubs", ok and err == true, ok and "v1 interface; handlers accepted, never called" or tostring(err))
        -- self.controls: reads work, writes are ignored (0.4.3)
        local target = tes3.player and objects.wrap(tes3.player) or {}
        local mob = tes3.player and tes3.player.mobile or nil
        local before = mob and mob.isSneaking
        local controlsInfo
        ok, err, lines = X.capture(function()
            local c = actors.controlsOf(target)
            assert(type(c.sneak) == "boolean", "controls.sneak reads a boolean")
            assert(type(c.run) == "boolean" and type(c.jump) == "boolean", "controls.run/jump read booleans")
            c.yawChange = 0
            c.movement = 1
            c.sneak = not c.sneak
            assert(c.neverHeardOfIt == nil, "an unknown control reads nil")
            return true
        end)
        local afterOk = (not mob) or mob.isSneaking == before
        controlsInfo = ok and (afterOk and "reads ok, writes ignored, game state unchanged" or "a write changed the actor") or tostring(err)
        result(res, "self.controls stubs", ok and err == true and afterOk and count(lines, "cannot be set") >= 1, controlsInfo)
        -- sound gate: fake references only; the tombstone it needs is set and cleared inside the call
        ok, err = X.capture(function()
            local cid = "c:omwcompat-smoketest.esp:1048575"
            local fakeRef = { sourceMod = "omwcompat-smoketest.esp", sourceFormId = 1048575, id = "omwcompat_smoketest_fake",
                object = { objectType = -1, id = "omwcompat_smoketest_fake" } }
            local was = state.tombs[cid]
            local e1 = { reference = fakeRef, sound = { id = "fire" } }
            assert(RT.onAddSound(e1) == nil and not e1.block, "a live object's sound must not be blocked")
            state.tombs[cid] = true
            local ok2, why = pcall(function()
                assert(RT.soundBlockReason(fakeRef, { id = "fire" }) == "removed", "a removed object's sound is gated")
                local e2 = { reference = fakeRef, sound = { id = "fire" } }
                assert(RT.onAddSound(e2) == false and e2.block == true, "onAddSound blocks it")
                return true
            end)
            state.tombs[cid] = was
            assert(ok2, why)
            assert(RT.onAddSound({}) == nil, "an event without a reference is ignored")
            return true
        end)
        result(res, "sound gate", ok and err == true and RT.soundGate.enabled == true,
            ok and (RT.soundGate.enabled and "removed-object sounds blocked, live ones untouched" or "gate is switched off") or tostring(err))
        return res
    end

    ------------------------------------------------------------ round trips
    local KINDS = { { "number", 42.5 }, { "integer", 7 }, { "boolean", true }, { "string", "a \"quoted\"\nline" } }
    function X.roundTrips()
        local res = {}
        -- settings storage: a scratch section on a throwaway owner (never a mod's own store, never a config file)
        local ok, err = pcall(function()
            local owner = { storage = {} }
            local sec = settings.section("omwcompat_smoketest_scratch", owner, nil)
            for _, kv in ipairs(KINDS) do
                sec:set("k_" .. kv[1], kv[2])
                assert(sec:get("k_" .. kv[1]) == kv[2], kv[1] .. " did not round-trip")
            end
            sec:set("nested", { a = 1, b = { c = "x" } })
            local n = sec:getCopy("nested")
            assert(type(n) == "table" and n.a == 1 and n.b.c == "x", "nested table did not round-trip")
            sec:set("k_number", nil)
            assert(sec:get("k_number") == nil, "setting nil must clear the key")
            local t = sec:asTable()
            assert(t.k_boolean == true and t.k_integer == 7, "asTable")
            sec:reset({ only = 1 })
            assert(sec:get("only") == 1 and sec:get("k_boolean") == nil, "reset")
            return true
        end)
        result(res, "settings storage round trip", ok and err == true, ok and "number, integer, boolean, string, nested table, nil, reset" or tostring(err))
        -- the save payload encoder: synthetic data, then (read-only) the mod's real payload
        ok, err = pcall(function()
            local payload = { v = 1, s = "text \"q\" \\ end", n = 3.25, i = -12, b = false, t = { 1, 2, 3, x = { y = "z" } } }
            local decoded = serial.decode(serial.encode(payload))
            assert(decoded.v == 1 and decoded.s == payload.s and decoded.n == 3.25 and decoded.i == -12
                and decoded.b == false and decoded.t[3] == 3 and decoded.t.x.y == "z", "decoded data differs")
            return true
        end)
        result(res, "save payload encoder round trip", ok and err == true, ok and "serial.encode/decode of mixed data" or tostring(err))
        return res
    end

    -- the mod's real save payload (its storage and per-object data) encodes and decodes; read-only
    function X.payloadCheck(modName)
        local res = {}
        local m = modOf(modName)
        if not m then return res end
        local ok, err = pcall(function()
            local s = serial.encode({ v = 1, storage = m.storage, locals = m.localData }, function(o) return rawget(o, "_id") end)
            assert(type(s) == "string" and #s > 0)
            serial.decode(s, function(id) return id end)
            return true
        end)
        result(res, "save payload", ok and err == true, ok and "storage and per-object data encode and decode" or tostring(err))
        return res
    end

    return X
end

return D
