-- omwcompat.timing: cheap per-script, per-handler time counters, so a frame-rate drop can be
-- pinned on (or cleared from) the OpenMW scripts omwcompat hosts.
--
-- Every engine handler the runtime calls through callAll (global scripts: onUpdate,
-- onObjectActive, onActorActive, ...) and updateLocals (local scripts' onUpdate) is timed:
-- calls, total seconds and the slowest single call, per mod + script path + handler (local
-- script instances of one script share an entry). `frame` is all omwcompat work in one
-- enterFrame (events, timers and deferred calls included).
--
-- Reading it from another MWSE mod (for example mwhangwatch), without depending on it:
--   local omwc = include("omwcompat")
--   if omwc and omwc.timing then
--       local snap = omwc.timing.snapshot()          -- cumulative since load/reset
--       local d = omwc.timing.delta("mwhangwatch")   -- since this consumer's previous call
--       log("%s", omwc.timing.line("mwhangwatch", 5)) -- one line, per-consumer window
--   end
-- An optional periodic line goes to MWSE.log when Data Files/MWSE/config/omwcompat.json has
-- "timingLogSeconds": N (0 = off, the default). "timing": false turns the counters off.
-- MIT, Copyright (c) 2026 dej (dejunai). Built with Grok Bot.
local M = { enabled = true, logEvery = 0, clockSource = "os.clock" }

local clock = os.clock
do -- Windows: os.clock() is only millisecond-resolution; use QueryPerformanceCounter when ffi has it
    local okFfi, ffi = pcall(require, "ffi")
    if okFfi and type(ffi) == "table" and ffi.os == "Windows" then
        local ok, qclock = pcall(function()
            pcall(ffi.cdef, "int QueryPerformanceCounter(int64_t *c); int QueryPerformanceFrequency(int64_t *f);")
            local C, buf = ffi.C, ffi.new("int64_t[1]")
            assert(C.QueryPerformanceFrequency(buf) ~= 0)
            local inv = 1 / tonumber(buf[0])
            local qpc = C.QueryPerformanceCounter
            local f = function() qpc(buf); return tonumber(buf[0]) * inv end
            f()
            return f
        end)
        if ok and qclock then clock, M.clockSource = qclock, "QueryPerformanceCounter" end
    end
end
M.clock = clock

local entries, byKey = {}, {}
M.frame = { frames = 0, total = 0, max = 0 }
M.since = clock()
M.errors = {}   -- where -> error count (set by the runtime)

-- The counter for one mod/script/handler; `where` is the label used in error messages.
function M.entry(mod, script, handler, isLocal)
    local key = mod .. "\0" .. script .. "\0" .. handler
    local e = byKey[key]
    if not e then
        e = { mod = mod, script = script, handler = handler, isLocal = isLocal == true,
            where = script .. " " .. handler, calls = 0, total = 0, max = 0 }
        byKey[key] = e
        entries[#entries + 1] = e
    end
    return e
end

function M.addFrame(d)
    local f = M.frame
    f.frames = f.frames + 1
    f.total = f.total + d
    if d > f.max then f.max = d end
end

function M.reset()
    for _, e in ipairs(entries) do e.calls, e.total, e.max = 0, 0, 0 end
    M.frame.frames, M.frame.total, M.frame.max = 0, 0, 0
    M.since = clock()
    M.baselines = {}
end
M.baselines = {}

function M.setEnabled(on) M.enabled = on and true or false end

local function copyEntry(e, calls, total)
    return { mod = e.mod, script = e.script, handler = e.handler, isLocal = e.isLocal,
        calls = calls, total = total, max = e.max, errors = M.errors[e.where] or 0 }
end
local function sorted(list)
    table.sort(list, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return (a.mod .. a.script .. a.handler) < (b.mod .. b.script .. b.handler)
    end)
    return list
end

-- Cumulative counters since load (or the last reset). Times are in seconds.
-- { version, clock, enabled, since, elapsed, frame = { frames, total, max }, scripts = { ... },
--   guards = { { mod, script, dedupeSkipped, shiftRevisits, nextRestarts }, ... } }
function M.snapshot()
    local list = {}
    for _, e in ipairs(entries) do
        if e.calls > 0 then list[#list + 1] = copyEntry(e, e.calls, e.total) end
    end
    local now = clock()
    return { version = M.version, clock = M.clockSource, enabled = M.enabled, since = M.since, elapsed = now - M.since,
        frame = { frames = M.frame.frames, total = M.frame.total, max = M.frame.max }, scripts = sorted(list),
        guards = M.guardStats and M.guardStats() or {} }
end

-- Same shape, but calls / total / frames are the change since `consumer` last called delta
-- (or line) with that name; max stays the cumulative worst call. The first call covers
-- everything since load. Each consumer has its own window, so they do not disturb each other.
function M.delta(consumer)
    consumer = consumer or "default"
    local b = M.baselines[consumer]
    if not b then b = { at = M.since, frames = 0, ftotal = 0, e = {} }; M.baselines[consumer] = b end
    local now = clock()
    local list = {}
    for _, e in ipairs(entries) do
        local prev = b.e[e] or { calls = 0, total = 0 }
        local dc, dt = e.calls - prev.calls, e.total - prev.total
        if dc > 0 then list[#list + 1] = copyEntry(e, dc, dt) end
        b.e[e] = { calls = e.calls, total = e.total }
    end
    local out = { version = M.version, clock = M.clockSource, enabled = M.enabled, since = b.at, elapsed = now - b.at,
        frame = { frames = M.frame.frames - b.frames, total = M.frame.total - b.ftotal, max = M.frame.max },
        scripts = sorted(list), guards = M.guardStats and M.guardStats() or {} }
    b.at, b.frames, b.ftotal = now, M.frame.frames, M.frame.total
    return out
end

local function ms(s) return s * 1000 end
-- One log line from delta(consumer): average omwcompat ms per frame, then the top N handlers.
function M.line(consumer, top)
    local d = M.delta(consumer)
    top = top or 5
    local f = d.frame
    local parts = { string.format("omwcompat %s: %.2f ms/frame over %d frames (worst frame %.2f ms)",
        tostring(M.version), f.frames > 0 and ms(f.total / f.frames) or 0, f.frames, ms(f.max)) }
    if not M.enabled then parts[1] = parts[1] .. " [timing off]" end
    for i = 1, math.min(top, #d.scripts) do
        local e = d.scripts[i]
        parts[#parts + 1] = string.format("%s %s %s %.2f ms/frame (%d calls, max %.2f ms%s)", e.mod, e.script, e.handler,
            f.frames > 0 and ms(e.total / f.frames) or ms(e.total), e.calls, ms(e.max),
            e.errors > 0 and (", " .. e.errors .. " errors") or "")
    end
    return table.concat(parts, "; ")
end

return M
