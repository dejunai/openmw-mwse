-- Rule-based guards (omwcompat 0.3.2): activeDedupe and safeIteration, switched on per script
-- by omw2mwse (spec.guards). Uses tests/fixtures/active-collect, a fixture modeled on the
-- "collect from onObjectActive, walk with a next() cursor, table.remove at the cursor"
-- pattern, hosted twice: with the guards and without (control).
-- Run from staging/LeaveTheLightsOff via tests/run_lua_tests.sh.
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local mock = require("mock_mwse").install({})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end
local function section(s) print("\n== " .. s) end

local FIX = os.getenv("TESTS_DIR") .. "/../fixtures/active-collect/"
local SYN = (os.getenv("TMPDIR_SYNTH") or "/tmp/omwcompat-synth") .. "-guards/"
os.execute("mkdir -p '" .. SYN .. "scripts'")
local function write(rel, text)
    local f = assert(io.open(SYN .. rel, "w")); f:write(text); f:close()
end

-- REC lines of one mod since log index `from`
local function recs(mod, kind, from)
    local out = {}
    local pre = "[" .. mod .. "] REC " .. kind
    local logs = mock.allLogs()
    for i = (from or 1), #logs do
        local l = logs[i]
        if l:sub(1, #pre) == pre then
            local parts = {}
            for p in l:sub(#pre + 2):gmatch("[^\t]+") do parts[#parts + 1] = p end
            out[#out + 1] = parts
        end
    end
    return out
end
local function lastSize(mod)
    local r = recs(mod, "tick")
    return r[#r] and tonumber(r[#r][1])
end

write("scripts/iter.lua", [[
local t = { 2, 4, 6, 1 }
for i, v in ipairs(t) do if v % 2 == 0 then table.remove(t, i) end end
print('REC ipairs', table.concat(t, ','))
local p = { 2, 4, 6, 1 }
for k, v in pairs(p) do if v % 2 == 0 then table.remove(p, k) end end
print('REC pairs', table.concat(p, ','))
local h = {}
for i = 1, 8 do h['k' .. i] = i end
local k = next(h)
h[k] = nil
for i = 1, 64 do h['x' .. i] = i end   -- rehash: the dead key is dropped
local ok, a = pcall(next, h, k)
print('REC nextkey', tostring(ok), tostring(a ~= nil))
local u = { 1, 2, 3 }
table.insert(u, 2)
table.insert(u, 1, 0)
print('REC plain', table.concat(u, ','), tostring(table.remove(u)), tostring(table.concat ~= nil))
return {}
]])

local rt = require("omwcompat")
check(rt.VERSION == "0.4.5", "runtime 0.4.5 (" .. rt.VERSION .. ")")
rt.register({ mod = "ACGuarded", root = FIX, scripts = {
    { flags = { "GLOBAL" }, path = "scripts/ActiveCollect/global.lua", guards = { "activeDedupe", "safeIteration" } } } })
rt.register({ mod = "ACPlain", root = FIX, scripts = {
    { flags = { "GLOBAL" }, path = "scripts/ActiveCollect/global.lua" } } })
rt.register({ mod = "IterGuarded", root = SYN, scripts = {
    { flags = { "GLOBAL" }, path = "scripts/iter.lua", guards = { "safeIteration", "bogusGuard" } } } })
rt.register({ mod = "IterPlain", root = SYN, scripts = { { flags = { "GLOBAL" }, path = "scripts/iter.lua" } } })
mock.fire("initialized", {})

local ext = mock.addCell({ id = "Seyda Neen", gridX = -2, gridY = -9 })
W.activeCell = ext
for _, id in ipairs({ "torch_a", "torch_b", "torch_c" }) do mock.addLight({ id = id }) end
local refs = {}
for i, id in ipairs({ "torch_a", "torch_b", "torch_c" }) do refs[i] = mock.placeRef(ext, id, { i * 100, 0, 0 }) end
mock.newPlayer(ext)
mock.fire("loaded", { newGame = true })
for _, r in ipairs(refs) do mock.fire("referenceActivated", { reference = r }) end
mock.frames(3, 0.1)

section("safeIteration: next / pairs / ipairs (synthetic script)")
local g, p = recs("IterGuarded", "ipairs"), recs("IterPlain", "ipairs")
check(g[1] and g[1][1] == "1", "guarded ipairs + table.remove visits shifted elements: {2,4,6,1} -> " .. tostring(g[1] and g[1][1]))
check(p[1] and p[1][1] == "4,1", "control (no guard) skips them: " .. tostring(p[1] and p[1][1]))
g, p = recs("IterGuarded", "pairs"), recs("IterPlain", "pairs")
check(g[1] and g[1][1] == "1", "guarded pairs + table.remove: " .. tostring(g[1] and g[1][1]))
check(p[1] and p[1][1] ~= "1", "control pairs differs: " .. tostring(p[1] and p[1][1]))
g, p = recs("IterGuarded", "nextkey"), recs("IterPlain", "nextkey")
check(g[1] and g[1][1] == "true", "guarded next() with a vanished key restarts instead of raising")
check(p[1] and p[1][1] == "false", "control next() raises 'invalid key to next'")
g, p = recs("IterGuarded", "plain"), recs("IterPlain", "plain")
check(g[1] and p[1] and g[1][1] == p[1][1] and g[1][2] == p[1][2], "plain table.insert/remove unchanged: " .. tostring(g[1] and g[1][1]))
local function logHas(s) for _, l in ipairs(mock.allLogs()) do if l:find(s, 1, true) then return true end end return false end
check(logHas("unknown guard bogusGuard ignored"), "unknown guard name: one warning")
check(logHas("IterGuarded scripts/iter.lua: next() got a key that is no longer in the table"), "first restart logged once")

section("activeDedupe: cell reloads do not grow the list")
check(lastSize("ACGuarded") == 3 and lastSize("ACPlain") == 3, "3 lights tracked after the first load")
for round = 1, 2 do
    for _, r in ipairs(refs) do mock.fire("referenceDeactivated", { reference = r }) end
    for _, r in ipairs(refs) do mock.fire("referenceActivated", { reference = r }) end
    mock.frames(1, 0.1)
end
check(lastSize("ACGuarded") == 3, "guarded: still 3 after two reloads (" .. tostring(lastSize("ACGuarded")) .. ")")
check(lastSize("ACPlain") == 9, "control: 9 after two reloads (" .. tostring(lastSize("ACPlain")) .. ")")
check(logHas("ACGuarded scripts/ActiveCollect/global.lua: skipped table.insert of an object that is already in the list"),
    "first skipped insert logged with the rule name")
local st
for _, s in ipairs(rt.timing.snapshot().guards) do if s.mod == "ACGuarded" then st = s end end
check(st and st.dedupeSkipped == 6, "6 duplicate inserts counted (" .. tostring(st and st.dedupeSkipped) .. ")")

section("GameObjects are cached per reference (identity = equality)")
local w1, w2 = rt.objects.wrap(refs[1]), rt.objects.wrap(refs[1])
check(rawequal(w1, w2), "wrap(ref) twice -> the same table")
mock.fire("referenceDeactivated", { reference = refs[1] })
mock.fire("referenceActivated", { reference = refs[1] })
check(rawequal(rt.objects.wrap(refs[1]), w1), "same table after the reference is deactivated and activated again")

section("activeDedupe only acts inside the active handlers")
local guards = rt.guards
local S = { mod = { name = "Unit" }, path = "unit.lua" }
S.guards = guards.normalize(S, { "activeDedupe" })
local env = {}
guards.apply(env, S)
local list = {}
env.table.insert(list, w1); env.table.insert(list, w1)
check(#list == 2, "outside onObjectActive: duplicates are kept (" .. #list .. ")")
S.activeDepth = 1
env.table.insert(list, w1); env.table.insert(list, "x"); env.table.insert(list, "x")
check(#list == 4, "inside: the GameObject is skipped, non-objects are not (" .. #list .. ")")
S.activeDepth = 0

section("safeIteration: next() cursor + table.remove at the cursor (fixture)")
-- find a frame where the guarded walk is at torch_b, delete it, and see what the next frames visit
local function walkTo(mod, id)
    for _ = 1, 20 do
        mock.frames(1, 0.1)
        local r = recs(mod, "tick")
        if r[#r][2] == id then return true end
    end
    return false
end
check(walkTo("ACGuarded", "torch_a"), "guarded walk reaches torch_a")
refs[2]:delete()
local from = #mock.allLogs() + 1
mock.frames(4, 0.1)
local r = recs("ACGuarded", "tick", from)
check(r[1] and r[1][1] == "2" and r[1][2] == "-", "frame 1: torch_b is invalid and removed at the cursor (size 2)")
check(r[2] and r[2][2] == "torch_c", "frame 2: torch_c (shifted into the freed slot) is visited, not skipped: " .. tostring(r[2] and r[2][2]))
check(r[3] and r[3][2] == "-", "frame 3: end of the lap (next returns nil once, as in Lua)")
check(r[4] and r[4][2] == "torch_a", "frame 4: the walk starts again at torch_a")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
