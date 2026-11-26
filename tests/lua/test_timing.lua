-- omwcompat 0.3.2: per-script timing counters (omwcompat.timing), the optional periodic log
-- line, cheap repeated errors (one traceback per `where`), and types.NPC.getFactions /
-- getFactionRank / isExpelled.
-- Run from staging/LeaveTheLightsOff via tests/run_lua_tests.sh.
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local mock = require("mock_mwse").install({})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end
local function section(s) print("\n== " .. s) end

local SYN = (os.getenv("TMPDIR_SYNTH") or "/tmp/omwcompat-synth") .. "-timing/"
os.execute("mkdir -p '" .. SYN .. "scripts'")
local function write(rel, text)
    local f = assert(io.open(SYN .. rel, "w")); f:write(text); f:close()
end
local function logsWith(s, from)
    local out = {}
    for i = (from or 1), #W.logs do if W.logs[i]:find(s, 1, true) then out[#out + 1] = W.logs[i] end end
    return out
end

write("scripts/busy.lua", [[
local n = 0
return { engineHandlers = {
  onUpdate = function(dt) for i = 1, 2000 do n = n + i % 7 end end,
  onObjectActive = function(o) n = n + 1 end,
} }
]])
write("scripts/broken.lua", [[
return { engineHandlers = { onUpdate = function(dt) local t = nil; return t.field end } }
]])
-- ThievesPickpocket-style use (tpickpocket_global.lua:29): iterate the faction ids of an actor
write("scripts/fac.lua", [[
local types = require('openmw.types')
local THIEF = { ["thieves guild"] = true }
return { engineHandlers = {
  onActorActive = function(actor)
    if not types.NPC.objectIsInstance(actor) then return end
    local ids = {}
    for _, factionId in pairs(types.NPC.getFactions(actor)) do ids[#ids + 1] = factionId end
    local thief = false
    for _, f in ipairs(ids) do if THIEF[f:lower()] then thief = true end end
    print('REC fac', actor.recordId, table.concat(ids, ','), tostring(thief))
  end,
} }
]])
write("scripts/crea.lua", "return {}\n")

-- factions in the mock: an NPC record with faction/factionRank, the player's joined flags
local thieves = { id = "Thieves Guild", name = "Thieves Guild", playerJoined = true, playerRank = 3, playerExpelled = false }
local mages = { id = "Mages Guild", name = "Mages Guild", playerJoined = false, playerRank = -1, playerExpelled = false }
local fighters = { id = "Fighters Guild", name = "Fighters Guild", playerJoined = true, playerRank = 0, playerExpelled = true }
tes3.dataHandler = { nonDynamicData = { factions = { thieves, mages, fighters } } }
tes3.getFaction = function(id)
    for _, f in ipairs(tes3.dataHandler.nonDynamicData.factions) do if f.id:lower() == id:lower() then return f end end
end
local CT = tes3.objectType
mock.addObject({ id = "habasi", objectType = CT.npc, faction = thieves, factionRank = 4, inventory = {}, aiConfig = {} })
mock.addObject({ id = "fargoth", objectType = CT.npc, inventory = {}, aiConfig = {} })
mock.addObject({ id = "mudcrab", objectType = CT.creature, inventory = {}, aiConfig = {} })

local rt = require("omwcompat")
rt.register({ mod = "Busy", root = SYN, scripts = { { flags = { "GLOBAL" }, path = "scripts/busy.lua" } } })
rt.register({ mod = "Broken", root = SYN, scripts = { { flags = { "GLOBAL" }, path = "scripts/broken.lua" } } })
rt.register({ mod = "Fac", root = SYN, scripts = { { flags = { "GLOBAL" }, path = "scripts/fac.lua" } } })
mock.fire("initialized", {})
local ext = mock.addCell({ id = "Seyda Neen", gridX = -2, gridY = -9 })
W.activeCell = ext
local habasi = mock.placeRef(ext, "habasi", { 0, 0, 0 })
local fargoth = mock.placeRef(ext, "fargoth", { 100, 0, 0 })
local crab = mock.placeRef(ext, "mudcrab", { 200, 0, 0 })
local player = mock.newPlayer(ext)
mock.fire("loaded", { newGame = true })
for _, r in ipairs({ habasi, fargoth, crab }) do mock.fire("referenceActivated", { reference = r }) end
mock.frames(10, 0.1)

section("timing counters")
local T = rt.timing
check(type(T.snapshot) == "function" and rt.getTimings == T.snapshot, "omwcompat.timing.snapshot / omwcompat.getTimings exist")
local snap = T.snapshot()
check(snap.version == "0.3.2" and snap.enabled == true, "snapshot: version and enabled")
check(snap.clock == "os.clock" or snap.clock == "QueryPerformanceCounter", "clock source: " .. tostring(snap.clock))
check(snap.frame.frames == 10, "10 frames counted (" .. snap.frame.frames .. ")")
check(snap.frame.total >= 0 and snap.frame.max >= 0, "frame total/max present")
local by = {}
for _, e in ipairs(snap.scripts) do by[e.mod .. " " .. e.handler] = e end
check(by["Busy onUpdate"] and by["Busy onUpdate"].calls == 10, "Busy onUpdate: 10 calls")
check(by["Busy onObjectActive"] and by["Busy onObjectActive"].calls == 4, "Busy onObjectActive: 4 calls (3 refs + the player)")
check(by["Busy onUpdate"].script == "scripts/busy.lua" and by["Busy onUpdate"].isLocal == false, "entry names script and kind")
check(by["Busy onUpdate"].total >= by["Busy onUpdate"].max, "total >= max")
check(by["Broken onUpdate"] and by["Broken onUpdate"].errors == 10, "errors counted per handler (" .. tostring(by["Broken onUpdate"] and by["Broken onUpdate"].errors) .. ")")
local sortedOk = true
for i = 2, #snap.scripts do if snap.scripts[i - 1].total < snap.scripts[i].total then sortedOk = false end end
check(sortedOk, "scripts sorted by total time, slowest first")

section("delta windows are per consumer")
local d1 = T.delta("hangwatch")
check(d1.frame.frames == 10, "first delta covers everything since load")
mock.frames(5, 0.1)
local d2 = T.delta("hangwatch")
check(d2.frame.frames == 5, "second delta: 5 frames")
local bd
for _, e in ipairs(d2.scripts) do if e.mod == "Busy" and e.handler == "onUpdate" then bd = e end end
check(bd and bd.calls == 5, "Busy onUpdate: 5 calls in the window")
local other = T.delta("someoneElse")
check(other.frame.frames == 15, "another consumer's first window is independent (15 frames)")
local line = T.line("hangwatch", 3)
check(line:find("^omwcompat 0%.3%.2: [%d%.]+ ms/frame over 0 frames") ~= nil, "line(): " .. line)
mock.frames(2, 0.1)
line = T.line("hangwatch", 3)
check(line:find("over 2 frames", 1, true) and line:find("Busy scripts/busy.lua onUpdate", 1, true) ~= nil, "line() lists the top handlers: " .. line)
check(line:find("errors", 1, true) ~= nil, "line() shows error counts")

section("periodic log line (config timingLogSeconds)")
W.config = { omwcompat = { timing = true, timingLogSeconds = 0.000001 } }
rt.loadTimingConfig()
check(T.logEvery == 0.000001, "timingLogSeconds read from config/omwcompat.json")
local from = #W.logs + 1
local t0 = os.clock()
while os.clock() - t0 < 0.002 do end
mock.frames(1, 0.1)
while os.clock() - t0 < 0.004 do end
mock.frames(1, 0.1)
check(#logsWith("[omwcompat 0.3.2] timing: omwcompat 0.3.2:", from) >= 1, "a timing line goes to MWSE.log")
W.config = { omwcompat = { timing = false, timingLogSeconds = 0 } }
rt.loadTimingConfig()
local calls = (function() for _, e in ipairs(T.snapshot().scripts) do if e.mod == "Busy" and e.handler == "onUpdate" then return e.calls end end end)()
mock.frames(3, 0.1)
local calls2 = (function() for _, e in ipairs(T.snapshot().scripts) do if e.mod == "Busy" and e.handler == "onUpdate" then return e.calls end end end)()
check(calls == calls2 and T.enabled == false, "timing off: counters stop")
T.setEnabled(true)
T.reset()
check(T.snapshot().frame.frames == 0 and #T.snapshot().scripts == 0, "reset clears the counters")

section("repeated errors: one traceback per where")
local errs = logsWith("ERROR in scripts/broken.lua onUpdate")
check(#errs == 5, "5 error lines logged, the rest suppressed (" .. #errs .. ")")
check(errs[1] and errs[1]:find("stack traceback", 1, true) ~= nil, "the first carries a traceback")
local later = true
for i = 2, #errs do if errs[i]:find("stack traceback", 1, true) then later = false end end
check(later, "errors 2-5: message only, no traceback")
check(#logsWith("further errors in scripts/broken.lua onUpdate suppressed") == 1, "one suppression notice")

section("types.NPC.getFactions / getFactionRank / isExpelled")
local recs = {}
for _, l in ipairs(W.logs) do
    local id, ids, thief = l:match("^%[Fac%] REC fac\t([^\t]+)\t([^\t]*)\t(%a+)$")
    if id then recs[id] = { ids = ids, thief = thief } end
end
check(recs.habasi and recs.habasi.ids == "thieves guild" and recs.habasi.thief == "true",
    "NPC in a faction: { 'thieves guild' } (lower-case id), ThievesPickpocket-style loop works")
check(recs.fargoth and recs.fargoth.ids == "" and recs.fargoth.thief == "false", "NPC without a faction: empty list")
check(recs.mudcrab == nil, "creatures are filtered by the script's objectIsInstance check")
check(#logsWith("getFactions") == 0, "no 'attempt to call field getFactions' errors")
local types = rt.objects.types
local w = rt.objects.wrap
check(types.NPC.getFactionRank(w(habasi), "Thieves Guild") == 5, "NPC rank from 1 (factionRank 4 -> 5)")
check(types.NPC.getFactionRank(w(habasi), "mages guild") == 0, "not a member -> 0")
check(types.NPC.getFactionRank(w(fargoth), "thieves guild") == 0, "no faction -> 0")
check(not pcall(types.NPC.getFactionRank, w(habasi), "no such guild"), "unknown faction id raises (OpenMW)")
local pf = types.NPC.getFactions(w(player))
table.sort(pf)
check(table.concat(pf, ",") == "fighters guild,thieves guild", "player: every joined faction (" .. table.concat(pf, ",") .. ")")
check(types.Player.getFactions == types.NPC.getFactions, "types.Player has it too")
check(types.NPC.getFactionRank(w(player), "thieves guild") == 4 and types.NPC.getFactionRank(w(player), "mages guild") == 0,
    "player rank from playerRank + 1; not joined -> 0")
check(types.NPC.isExpelled(w(player), "fighters guild") == true and types.NPC.isExpelled(w(player), "thieves guild") == false,
    "player isExpelled from playerExpelled")
check(types.NPC.isExpelled(w(habasi), "thieves guild") == false, "NPCs are never expelled")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
