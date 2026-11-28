-- omwcompat_smoketest checks: read-only. Nothing in here spawns, moves, enables, disables or
-- deletes anything, writes tes3.player.data, or writes a config file. The runtime probes it
-- calls (omwcompat.diag) work on fake objects and scratch tables and restore what they touch.
-- Verdicts: PASS, FAIL, SKIP (could not be judged now; says why). Report lines go to the
-- omwcompat library log (Data Files/MWSE/logs/omwcompat.log), never to MWSE.log.
-- Written for omwcompat by dej (dejunai). MIT.
local C = { VERSION = "0.1.0" }

local function parseVersion(s)
    local a, b, c = tostring(s or ""):match("^(%d+)%.(%d+)%.?(%d*)")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) or 0 }
end
local function newer(a, b)   -- a > b
    for i = 1, 3 do
        if a[i] ~= b[i] then return a[i] > b[i] end
    end
    return false
end
C.parseVersion, C.newer = parseVersion, newer

-- handlers the runtime calls without timing them (not observable from outside)
local LIFECYCLE = { onInit = true, onLoad = true, onSave = true, onNewGame = true, onPlayerAdded = true,
    onInterfaceOverride = true, onInactive = true }

local Report = {}
Report.__index = Report
local function newReport()
    return setmetatable({ entries = {}, counts = { PASS = 0, FAIL = 0, SKIP = 0 } }, Report)
end
function Report:add(scope, status, name, detail)
    self.entries[#self.entries + 1] = { scope = scope, status = status, name = name, detail = detail }
    self.counts[status] = self.counts[status] + 1
end
function Report:line(e)
    return string.format("[smoketest] %-4s %s: %s%s", e.status, e.scope, e.name, e.detail and (" - " .. e.detail) or "")
end
function Report:summary()
    return string.format("%d PASS, %d FAIL, %d SKIP", self.counts.PASS, self.counts.FAIL, self.counts.SKIP)
end

local function joinMax(list, n)
    n = n or 4
    if #list <= n then return table.concat(list, ", ") end
    local head = {}
    for i = 1, n do head[i] = list[i] end
    return table.concat(head, ", ") .. string.format(" (+%d more)", #list - n)
end

local function normName(s) return (tostring(s):lower():gsub("[^%w]", "")) end

------------------------------------------------------------------------ light census
local WEATHER_NAMES = { [0] = "Clear", "Cloudy", "Foggy", "Overcast", "Rain", "Thunderstorm", "Ashstorm", "Blight", "Snow", "Blizzard" }
local DARK_KEY = { Foggy = "DARK_FOGGY", Overcast = "DARK_OVERCAST", Rain = "DARK_RAIN", Thunderstorm = "DARK_THUNDERSTORM",
    Ashstorm = "DARK_ASHSTORM", Blight = "DARK_BLIGHT", Blizzard = "DARK_BLIZZARD" }
-- LTLO_g.lua whitelistPatterns (substrings of the base light's record id)
local LTLO_PATTERNS = { "streetlight", "lantern", "torch", "lamp", "pc_m1_anv_light_", "delantpaper", "uvi_crystal_bulb" }

local function playerCell()
    if tes3.getPlayerCell then
        local ok, c = pcall(tes3.getPlayerCell)
        if ok and c then return c end
    end
    return tes3.player and tes3.player.cell or nil
end

-- read-only: classify the light references of one cell
function C.lightCensus(cell)
    local n = { total = 0, enabled = 0, disabled = 0, offByDefault = 0, offCopies = 0, litWhitelisted = 0, whitelisted = 0 }
    if not cell then return n end
    for ref in cell:iterateReferences(tes3.objectType.light) do
        local obj = ref.object
        if obj and not ref.deleted then
            n.total = n.total + 1
            if ref.disabled then n.disabled = n.disabled + 1 else n.enabled = n.enabled + 1 end
            local id = tostring(obj.id)
            local generated = id:lower():sub(1, 10) == "generated:"
            if obj.isOffByDefault then n.offByDefault = n.offByDefault + 1 end
            if generated and obj.isOffByDefault and not ref.disabled then n.offCopies = n.offCopies + 1 end
            if not generated then
                local low = id:lower()
                for _, p in ipairs(LTLO_PATTERNS) do
                    if low:find(p, 1, true) then
                        n.whitelisted = n.whitelisted + 1
                        if not ref.disabled and not obj.isOffByDefault then n.litWhitelisted = n.litWhitelisted + 1 end
                        break
                    end
                end
            end
        end
    end
    return n
end

local function ltloCheck(R, scope, omwc, settingsRead)
    local cell = playerCell()
    if not cell then R:add(scope, "SKIP", "light scheduling", "no player cell"); return end
    if cell.isInterior and not cell.behavesAsExterior then
        R:add(scope, "SKIP", "light scheduling", "interior cell: LTLO only schedules exterior lights (try again outdoors)")
        return
    end
    local cfg = {}
    for _, s in ipairs(settingsRead) do if s.ok then cfg[s.key] = s.value end end
    local startH, endH = tonumber(cfg.NIGHT_START_HOUR) or 18, tonumber(cfg.NIGHT_END_HOUR) or 7
    local hour = tes3.worldController and tes3.worldController.hour and tes3.worldController.hour.value
    if not hour then R:add(scope, "SKIP", "light scheduling", "game hour not readable"); return end
    for _, edge in ipairs({ startH, endH }) do
        if math.abs(hour - edge) < 0.25 then
            R:add(scope, "SKIP", "light scheduling", string.format("game hour %.2f is within 15 minutes of a switch time (%d); retry later", hour, edge))
            return
        end
    end
    local wc = tes3.worldController.weatherController
    local weather = wc and wc.currentWeather
    if wc and wc.nextWeather and (wc.transitionScalar or 0) > 0 then
        R:add(scope, "SKIP", "light scheduling", "the weather is changing; retry in a minute")
        return
    end
    local wname = weather and (weather.name or WEATHER_NAMES[weather.index]) or "unknown"
    local darkWeather = DARK_KEY[wname] and cfg[DARK_KEY[wname]] == true
    local night = hour < endH or hour > startH or darkWeather
    local n = C.lightCensus(cell)
    local what = string.format("%s, hour %.1f, weather %s: %d whitelisted lit, %d off copies", night and "night" or "day", hour, wname,
        n.litWhitelisted, n.offCopies)
    if n.litWhitelisted + n.offCopies == 0 then
        R:add(scope, "SKIP", "light scheduling", "no scheduled lights in this cell (" .. what .. ")")
    elseif night then
        -- lights are lit: off copies should have been swapped back (a few may be pending)
        local total = n.litWhitelisted + n.offCopies
        local ok = n.offCopies <= math.max(1, math.floor(total * 0.25))
        R:add(scope, ok and "PASS" or "FAIL", "light scheduling", what .. (ok and "" or "; lights should be back on"))
    else
        -- lights are off: some off copies must exist, whitelisted lights that LTLO has no off model for may stay lit
        local ok = n.offCopies >= 1
        R:add(scope, ok and "PASS" or "FAIL", "light scheduling", what .. (ok and "" or "; no light was switched off"))
    end
end

------------------------------------------------------------------------ main run
-- ctx = { omwc = runtime or nil, trigger = "load"|"hotkey"|"mcm", frames = N, seconds = S }
function C.run(ctx)
    local R = newReport()
    local omwc = ctx.omwc
    R.trigger = ctx.trigger
    if not omwc then
        R:add("runtime", "FAIL", "omwcompat", "the runtime library is not loaded (Data Files/MWSE/lib/omwcompat missing?)")
        return R
    end
    R:add("runtime", "PASS", "omwcompat " .. tostring(omwc.VERSION), "loaded")
    local diag = omwc.diag
    if not diag then
        R:add("runtime", "SKIP", "deep checks", "this omwcompat has no diagnostics hooks (omwcompat.diag); update the runtime to 0.4.5 or later")
        return R
    end
    local info = diag.inspect()
    R:add("runtime", info.logFallback and "FAIL" or "PASS", "library log",
        info.logFallback and ("could not open " .. tostring(info.logPath) .. ": " .. tostring(info.logOpenError)) or ("writing to " .. info.logPath))
    if #info.mods == 0 then
        R:add("runtime", "SKIP", "conversions", "no converted mod is registered")
    end
    if not info.ready then
        R:add("runtime", "SKIP", "scripts", "no save is loaded yet, so no script is instantiated; load a save and run again")
    else
        R:add("runtime", "PASS", "save loaded", ctx.frames
            and string.format("%d frame(s) seen by omwcompat; waited %d unpaused frames / %.0f s after the load", info.frame or 0, ctx.frames, ctx.seconds or 0)
            or string.format("%d frame(s) seen by omwcompat", info.frame or 0))
    end

    -- errors recorded by the runtime since this save loaded, by script path
    local errsByMod, errsOther = {}, {}
    for where, n in pairs(info.errors) do
        local owner
        for _, im in ipairs(info.mods) do
            local all = {}
            for _, p in ipairs(im.globalSpecs) do all[#all + 1] = p end
            for _, sp in ipairs(im.localSpecs) do all[#all + 1] = sp.path end
            for _, p in ipairs(im.playerSpecs) do all[#all + 1] = p end
            for _, p in ipairs(all) do if where:find(p, 1, true) then owner = im.name end end
        end
        local t = owner and (errsByMod[owner] or {}) or errsOther
        t[#t + 1] = string.format("%s x%d", where, n)
        if owner then errsByMod[owner] = t end
    end
    table.sort(errsOther)
    if #errsOther > 0 then
        R:add("runtime", "FAIL", "handler errors", joinMax(errsOther))
    else
        R:add("runtime", "PASS", "handler errors", "none outside converted mods' scripts")
    end

    -- MCM
    if #info.mods > 0 then
        R:add("runtime", info.hasMcm and "PASS" or "FAIL", "MW Conversions menu",
            info.hasMcm and "built by omwcompat at modConfigReady" or "not built (modConfigReady did not run?)")
    end
    local gate = info.soundGate
    R:add("runtime", "PASS", "sound gate counters",
        string.format("%s; blocked so far: %d removed-object, %d off-by-default copy", gate.enabled and "enabled" or "OFF", gate.removed, gate.offCopy))

    -- stub probes and round trips (fake objects and scratch tables; counters restored)
    for _, r in ipairs(diag.probeStubs("omwcompat-smoketest")) do R:add("stubs", r.ok and "PASS" or "FAIL", r.name, r.detail) end
    for _, r in ipairs(diag.roundTrips()) do R:add("storage", r.ok and "PASS" or "FAIL", r.name, r.detail) end

    -- light census of the current cell (info)
    local census = C.lightCensus(playerCell())
    R:add("world", census.total > 0 and "PASS" or "SKIP", "lights in this cell",
        census.total > 0 and string.format("%d lights: %d enabled, %d disabled, %d off-by-default, %d off copies lit by a conversion",
            census.total, census.enabled, census.disabled, census.offByDefault, census.offCopies) or "none")

    -- per mod
    local frames = tonumber(ctx.frames) or info.frame or 0
    for _, im in ipairs(info.mods) do
        local scope = im.name
        -- 1. built-for vs loaded
        local built, loaded = parseVersion(im.builtFor), parseVersion(omwc.VERSION)
        if not built then
            R:add(scope, "SKIP", "built for", "no runtimeVersion recorded (very old conversion); re-convert to record one")
        elseif loaded and newer(built, loaded) then
            R:add(scope, "FAIL", "built for", string.format("needs omwcompat %s but %s is loaded", im.builtFor, omwc.VERSION))
        elseif im.builtFor == omwc.VERSION then
            R:add(scope, "PASS", "built for", "omwcompat " .. im.builtFor)
        else
            R:add(scope, "PASS", "built for", string.format("omwcompat %s, loaded %s (older build, still supported)", im.builtFor, omwc.VERSION))
        end
        -- 2. script files parse
        local paths, seen = {}, {}
        local function addPath(p) if not seen[p] then seen[p] = true; paths[#paths + 1] = p end end
        for _, p in ipairs(im.globalSpecs) do addPath(p) end
        for _, sp in ipairs(im.localSpecs) do addPath(sp.path) end
        for _, p in ipairs(im.playerSpecs) do addPath(p) end
        for _, p in ipairs(im.customSpecs) do addPath(p) end
        local bad = {}
        for _, p in ipairs(paths) do
            local ok, err = diag.compileCheck(im.name, p)
            if not ok then bad[#bad + 1] = p .. ": " .. tostring(err) end
        end
        if #paths == 0 then R:add(scope, "SKIP", "script files", "no hosted scripts declared")
        elseif #bad > 0 then R:add(scope, "FAIL", "script files", joinMax(bad, 2))
        else R:add(scope, "PASS", "script files", string.format("%d file(s) present and parse", #paths)) end
        -- 3. enabled switch
        local cfgOn = omwc.settings and omwc.settings.modEnabled and omwc.settings.modEnabled(im.name)
        if cfgOn ~= nil and (cfgOn == not im.disabled) then
            R:add(scope, "PASS", "enabled switch", im.disabled and "disabled in the MCM" or "enabled")
        elseif cfgOn ~= nil then
            R:add(scope, "FAIL", "enabled switch", "the config says " .. tostring(cfgOn) .. " but the runtime state is " .. tostring(not im.disabled))
        end
        -- 4. MCM tab
        if not info.hasMcm then
            R:add(scope, "SKIP", "MCM tab", "menu not built yet")
        elseif im.mcmError then
            R:add(scope, "FAIL", "MCM tab", tostring(im.mcmError))
        else
            R:add(scope, im.mcmTab and "PASS" or "FAIL", "MCM tab", im.mcmTab and "present" or "missing from the MW Conversions menu")
        end
        -- 5. settings: every registered setting reads and matches its default's type
        local sread = diag.readSettings(im.name)
        if #sread == 0 then
            R:add(scope, "SKIP", "settings", "none registered")
        else
            local badS = {}
            for _, s in ipairs(sread) do
                if not s.ok then badS[#badS + 1] = s.key .. ": " .. tostring(s.err)
                elseif s.renderer ~= "color" and type(s.default) ~= type(s.value) and s.value ~= nil then
                    badS[#badS + 1] = string.format("%s is %s, default is %s", s.key, type(s.value), type(s.default))
                elseif type(s.value) == "number" and type(s.min) == "number" and type(s.max) == "number"
                    and (s.value < s.min or s.value > s.max) then
                    badS[#badS + 1] = string.format("%s=%s outside %s..%s", s.key, tostring(s.value), tostring(s.min), tostring(s.max))
                end
            end
            R:add(scope, #badS == 0 and "PASS" or "FAIL", "settings", #badS == 0
                and string.format("%d setting(s) read, types and ranges ok", #sread) or joinMax(badS, 3))
        end
        -- 6. save payload
        for _, r in ipairs(diag.payloadCheck(im.name)) do R:add(scope, r.ok and "PASS" or "FAIL", r.name, r.detail) end
        -- 7..9 need running scripts
        if im.disabled then
            R:add(scope, "SKIP", "scripts running", "mod is disabled (its scripts are frozen)")
        elseif not info.ready then
            R:add(scope, "SKIP", "scripts running", "no save loaded")
        else
            -- instantiated global scripts
            local globalRunning = {}
            for _, s in ipairs(im.scripts) do if not s.isLocal then globalRunning[#globalRunning + 1] = s end end
            if #im.globalSpecs > 0 then
                local have = {}
                for _, s in ipairs(globalRunning) do have[s.path] = true end
                local missing = {}
                for _, p in ipairs(im.globalSpecs) do if not have[p] then missing[#missing + 1] = p end end
                if #missing == 0 then R:add(scope, "PASS", "global scripts", string.format("%d running", #globalRunning))
                else R:add(scope, "FAIL", "global scripts", "did not start: " .. joinMax(missing, 2) .. " (see ERROR lines above in this log)") end
            end
            if #im.playerSpecs > 0 then
                local want = #im.playerSpecs
                if tes3.player == nil then R:add(scope, "SKIP", "player scripts", "no player")
                else R:add(scope, im.playerInstances >= want and "PASS" or "FAIL", "player scripts",
                    string.format("%d of %d running", im.playerInstances, want)) end
            end
            if #im.localSpecs > 0 then
                if im.localInstances > 0 then R:add(scope, "PASS", "object scripts", string.format("%d instance(s) active in this area", im.localInstances))
                else R:add(scope, "SKIP", "object scripts", "no matching object is active in this area") end
            end
            -- handlers observed (never simulated)
            local obs = info.calls[im.name] or {}
            for _, s in ipairs(globalRunning) do
                local calls = obs[s.path] or {}
                local fired, waiting = {}, {}
                for _, h in ipairs(s.handlers) do
                    if LIFECYCLE[h] then -- not observable
                    elseif (calls[h] or 0) > 0 then fired[#fired + 1] = string.format("%s x%d", h, calls[h])
                    else waiting[#waiting + 1] = h end
                end
                local hasUpdate = false
                for _, h in ipairs(s.handlers) do if h == "onUpdate" then hasUpdate = true end end
                local name = "handlers " .. s.path:match("([^/\\]+)$")
                if not info.timingEnabled then
                    R:add(scope, "SKIP", name, "timing counters are off (omwcompat.json timing=false), so calls cannot be observed")
                elseif hasUpdate and (calls.onUpdate or 0) == 0 and frames >= 30 then
                    R:add(scope, "FAIL", name, "onUpdate never ran in " .. frames .. " frames")
                elseif hasUpdate and (calls.onUpdate or 0) == 0 then
                    R:add(scope, "SKIP", name, "too few frames observed yet")
                elseif #fired == 0 and #waiting > 0 then
                    R:add(scope, "SKIP", name, "event-driven only, not triggered yet: " .. joinMax(waiting))
                else
                    R:add(scope, "PASS", name, "fired: " .. (#fired > 0 and joinMax(fired) or "none needed")
                        .. (#waiting > 0 and ("; not triggered yet: " .. joinMax(waiting)) or ""))
                end
            end
            -- errors this mod's scripts logged
            local me = errsByMod[im.name]
            if me then table.sort(me); R:add(scope, "FAIL", "handler errors", joinMax(me, 3))
            else R:add(scope, "PASS", "handler errors", "none recorded") end
            -- LTLO-style light scheduling
            if normName(im.name):find("leavethelightsoff", 1, true) then ltloCheck(R, scope, omwc, sread) end
        end
    end
    return R
end

return C
