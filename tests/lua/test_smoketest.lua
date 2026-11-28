-- omwcompat_smoketest: the checks, the report, off-by-default, read-only behaviour, and the dev-only
-- test cell (fixtures spawn / despawn, levers, teleport there and back). Real LTLO hosted by omwcompat
-- inside the MWSE mock. Run from staging/LeaveTheLightsOff via tests/run_lua_tests.sh.
-- Written for omwcompat by dej (dejunai).
local ROOT = os.getenv("TESTS_DIR") .. "/../.."
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. ROOT .. "/smoketest/MWSE/mods/?.lua;" .. package.path
local mock = require("mock_mwse").install({
    files = { ["meshes\\omwc\\ltlo\\72d5ca40.nif"] = true },
    mods = { ["morrowind.esm"] = true, ["omwc_smoketest_dev.esp"] = true },
})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end
local function section(s) print("\n== " .. s) end
local function libLines()
    local out = {}
    for _, l in ipairs(mock.libLogs()) do out[#out + 1] = l end
    return out
end
local function libFind(needle, from)
    for i = from or 1, #mock.libLogs() do
        if mock.libLogs()[i]:find(needle, 1, true) then return i end
    end
end
local OT = tes3.objectType

-- world: LTLO's lights in Balmora, plus the test cell and its records -----------------------------
mock.addLight({ id = "light_de_lantern_01", mesh = "l\\light_de_lantern_01.nif", canCarry = true })
mock.addLight({ id = "light_de_streetlight_01", mesh = "l\\light_de_streetlight_01.nif" })
local ext = mock.addCell({ id = "Balmora", gridX = -3, gridY = -2 })
W.activeCell = ext
mock.placeRef(ext, "light_de_lantern_01", { 100, 200, 300 })
mock.placeRef(ext, "light_de_streetlight_01", { 500, 0, 0 })
local player = mock.newPlayer(ext)
player.position = { x = 11, y = 22, z = 33 }
player.orientation = { x = 0, y = 0, z = 0.5 }

local ESP = "OMWC_SmokeTest_DEV.esp"
local test = mock.addCell({ id = "OMWC Smoke Test", isInterior = true, behavesAsExterior = true })
mock.addLight({ id = "omwc_smoke_lantern_de", mesh = "l\\Light_De_Lantern_06.NIF" })
mock.addLight({ id = "omwc_smoke_lantern_paper", mesh = "l\\Light_Paper_Lantern_01.NIF" })
mock.addLight({ id = "omwc_smoke_streetlight", mesh = "l\\Light_De_Streetlight_01.NIF" })
mock.addLight({ id = "omwc_smoke_torch", mesh = "l\\Light_Com_Torch_01.NIF", isFire = true })
mock.addLight({ id = "omwc_smoke_firepit", mesh = "f\\furn_firepit00.nif", isFire = true })
for _, id in ipairs({ "omwc_smoke_npc_thief", "omwc_smoke_npc_mage" }) do mock.addObject({ id = id, objectType = OT.npc }) end
mock.addObject({ id = "rat", objectType = OT.creature })
mock.addObject({ id = "kwama forager", objectType = OT.creature })
mock.addObject({ id = "omwc_smoke_robe", objectType = OT.clothing })
mock.addObject({ id = "omwc_smoke_shield", objectType = OT.armor })
for _, id in ipairs({ "omwc_lever_time_hour", "omwc_lever_time_preset", "omwc_lever_wx_next", "omwc_lever_wx_prev",
    "omwc_lever_respawn", "omwc_smoke_exit" }) do mock.addObject({ id = id, objectType = OT.activator }) end
local levers = {}
for _, id in ipairs({ "omwc_lever_time_hour", "omwc_lever_time_preset", "omwc_lever_wx_next", "omwc_lever_wx_prev",
    "omwc_lever_respawn", "omwc_smoke_exit" }) do
    local r = mock.placeRef(test, id, { 0, -520, 0 }, { sourceMod = ESP })
    r.sourceMod = ESP
    levers[id] = r
end
-- tes3.positionCell that really changes the cell, like the engine, and fires cellChanged
local lastWeather = {}
tes3.positionCell = function(p)
    local prev = W.activeCell
    local r = p.reference
    r.position = { x = p.position[1] or p.position.x, y = p.position[2] or p.position.y, z = p.position[3] or p.position.z }
    r.orientation = { x = 0, y = 0, z = (p.orientation and (p.orientation[3] or p.orientation.z)) or 0 }
    if p.cell and p.cell ~= prev then
        W.activeCell = p.cell
        mock.fire("cellChanged", { cell = p.cell, previousCell = prev })
    end
end
tes3.getCell = (function(orig)
    return function(p)
        if p.x then
            for _, c in ipairs(W.cells) do if not c.isInterior and c.gridX == p.x and c.gridY == p.y then return c end end
            return nil
        end
        return orig(p)
    end
end)(tes3.getCell)
tes3.isModActive = function(n) return W.mods[n:lower()] == true end
local wcon = tes3.worldController.weatherController
function wcon:switchImmediate(i) lastWeather.immediate = i; mock.setWeather(i) end
function wcon:updateVisuals() lastWeather.visuals = (lastWeather.visuals or 0) + 1 end
function wcon:switchTransition(i) lastWeather.transition = i; mock.setWeather(i) end

local function refsOf(cell, pred)
    local n = 0
    for _, r in ipairs(cell._refs) do if not r._gone and (not pred or pred(r)) then n = n + 1 end end
    return n
end
local function created(cell) return refsOf(cell, function(r) return r.sourceMod == nil end) end
local FIXIDS = { omwc_smoke_lantern_de = 1, omwc_smoke_lantern_paper = 1, omwc_smoke_streetlight = 1, omwc_smoke_torch = 1,
    omwc_smoke_firepit = 1, omwc_smoke_npc_thief = 1, omwc_smoke_npc_mage = 1, rat = 1, ["kwama forager"] = 1, omwc_smoke_robe = 1,
    omwc_smoke_shield = 1 }
local function fixtureRefs(cell) return refsOf(cell, function(r) return r.sourceMod == nil and FIXIDS[r.object.id] end) end

-- boot omwcompat + LTLO; the smoke test is OFF (no config) ----------------------------------------
dofile("Data Files/MWSE/mods/mwsuite/openmw/LeaveTheLightsOff/main.lua")
mock.fire("initialized", {})
mock.setHour(12)
mock.fire("loaded", { newGame = true })
local handlersBefore = {}
for _, n in ipairs({ "loaded", "keyDown", "cellChanged", "save", "saved", "activate", "enterFrame" }) do
    handlersBefore[n] = #(W.handlers[n] or {})
end
local mwseLogsBefore = #W.logs
local ST = "mwsuite.openmw.omwcompat_smoketest"

section("off by default: nothing registered but the menu")
dofile(ROOT .. "/smoketest/MWSE/mods/mwsuite/openmw/omwcompat_smoketest/main.lua")
for n, c in pairs(handlersBefore) do check(#(W.handlers[n] or {}) == c, "no '" .. n .. "' handler added while off") end
check(#(W.handlers.modConfigReady or {}) >= 2, "its Mod Config Menu entry is registered")
mock.fire("modConfigReady", {})
local tpl
for _, t in ipairs(W.mcm) do if t.name == "OpenMW Smoke Test" then tpl = t end end
check(tpl ~= nil, "MCM template 'OpenMW Smoke Test' exists")
local enabledCtl = tpl and mock.mcmFind(tpl, "Enabled")
check(enabledCtl and mock.mcmGet(enabledCtl) == false, "Enabled defaults to off")
for _, label in ipairs({ "Run after every load", "Show a message with the result", "Run now (hotkey)", "Run the smoke test now",
    "Go to the test cell", "Return to where I was", "Respawn the fixtures" }) do
    check(tpl and mock.mcmFind(tpl, label) ~= nil or (tpl and (function()
        local function walk(c) if c.label == label then return true end for _, ch in ipairs(c.children) do if walk(ch) then return true end end end
        return walk(tpl)
    end)()), "MCM has: " .. label)
end
mock.frames(300)
check(libFind("[smoketest") == nil, "no report is written while off")

-- the checks, on demand through the MCM button (works while off) -------------------------------
section("Run now (MCM button) while off: report to the library log only")
local function findCtl(label)
    local found
    local function walk(c) if c.label == label then found = c end for _, ch in ipairs(c.children) do walk(ch) end end
    walk(tpl)
    return found
end
local before = #mock.libLogs()
local snapData = {}
for k, v in pairs(player.data or {}) do snapData[k] = v end
local cfgBefore = W.config and W.config.omwcompat_smoketest
local objCount = #W.objectList
local refCount = refsOf(ext)
local run = findCtl("Run the smoke test now")
run.args.callback()
local rep = require(ST .. ".runner").lastReport
check(rep ~= nil, "a report exists")
check(libFind("===== begin (trigger: mcm", before + 1) ~= nil, "begin line in the library log")
check(libFind("===== end: ", before + 1) ~= nil, "end line in the library log")
check(#W.logs == mwseLogsBefore, "MWSE.log untouched by the run (" .. #W.logs .. " lines, was " .. mwseLogsBefore .. ")")
local function entry(scope, name)
    for _, e in ipairs(rep.entries) do if e.scope == scope and e.name == name then return e end end
end
local function verdict(scope, name) local e = entry(scope, name); return e and e.status, e and e.detail end
check(rep.counts.FAIL == 0, "no FAIL in a healthy setup (" .. rep:summary() .. ")")
for _, l in ipairs(libLines()) do
    if l:find("[smoketest]", 1, true) and l:find(" FAIL ", 1, true) then print("    " .. l) end
end
check(verdict("runtime", "library log") == "PASS", "library log check")
check(verdict("LeaveTheLightsOff", "built for") == "PASS", "LTLO built-for matches")
check(verdict("LeaveTheLightsOff", "script files") == "PASS", "LTLO script parses")
check(verdict("LeaveTheLightsOff", "global scripts") == "PASS", "LTLO global script running")
check(verdict("LeaveTheLightsOff", "settings") == "PASS", "LTLO settings read")
check(verdict("LeaveTheLightsOff", "MCM tab") == "PASS", "LTLO MCM tab")
check(verdict("LeaveTheLightsOff", "save payload") == "PASS", "LTLO save payload encodes")
check(verdict("LeaveTheLightsOff", "handlers LTLO_g.lua") == "PASS", "LTLO onUpdate observed firing: " .. tostring(select(2, verdict("LeaveTheLightsOff", "handlers LTLO_g.lua"))))
for _, n in ipairs({ "animation stubs", "I.AnimationController stubs", "self.controls stubs", "sound gate" }) do
    check(verdict("stubs", n) == "PASS", "stub probe: " .. n)
end
check(verdict("storage", "settings storage round trip") == "PASS", "settings storage round trip")
check(verdict("storage", "save payload encoder round trip") == "PASS", "save payload encoder round trip")
check(verdict("LeaveTheLightsOff", "light scheduling") == "PASS", "LTLO light scheduling at noon: " .. tostring(select(2, verdict("LeaveTheLightsOff", "light scheduling"))))

section("read-only: nothing in the world, the save data or the configs changed")
local same = true
for k, v in pairs(player.data or {}) do if snapData[k] ~= v then same = false end end
check(same, "player.data unchanged")
check(#W.objectList == objCount, "no object records created")
check(refsOf(ext) == refCount, "no references added or removed")
check(W.config == nil or W.config.omwcompat_smoketest == cfgBefore, "the mod's config was not written by the run")
local sg = require("omwcompat").soundGate
check(sg.removed == 0 and sg.offCopy == 0, "sound gate counters restored after the probe")
check(next(require("omwcompat").timing.errors) == nil, "error counters untouched by the probes")

-- enable it ----------------------------------------------------------------------------------------
section("enabled: runs once after a load, after the delay, then not again")
mock.mcmSet(enabledCtl, true)
mock.mcmClose(tpl)
for n, c in pairs(handlersBefore) do
    if n ~= "enterFrame" then check(#(W.handlers[n] or {}) == c + 1, "'" .. n .. "' handler registered once enabled") end
end
mock.mcmSet(findCtl("Delay after load (seconds of play)"), 5)   -- minFrames stays 120
before = #mock.libLogs()
mock.fire("loaded", { newGame = false })
local msgBefore = #W.messages
mock.frames(100, 1 / 60)
check(libFind("trigger: load", before + 1) == nil, "not yet: 1.7 s of play is below the 5 s delay")
mock.frames(260, 1 / 60)   -- 360 frames = 6 s
local at = libFind("trigger: load", before + 1)
check(at ~= nil, "report written after the delay")
check(#W.messages == msgBefore + 1 and tostring(W.messages[#W.messages]):find("PASS") ~= nil, "one summary message box")
mock.frames(600, 1 / 60)
local n = 0
for i = before + 1, #mock.libLogs() do if mock.libLogs()[i]:find("trigger: load", 1, true) then n = n + 1 end end
check(n == 1, "one run per load")
check(#W.logs == mwseLogsBefore, "MWSE.log still untouched")
-- the paused game does not count
before = #mock.libLogs()
mock.fire("loaded", { newGame = false })
W.menuMode = true
mock.frames(900, 1 / 60)
check(libFind("trigger: load", before + 1) == nil, "paused frames do not count towards the delay")
W.menuMode = false
mock.frames(400, 1 / 60)
check(libFind("trigger: load", before + 1) ~= nil, "runs once play resumes")

section("hotkey")
before = #mock.libLogs()
mock.fire("keyDown", { keyCode = 68, isShiftDown = true, isControlDown = false, isAltDown = false })
check(libFind("trigger: hotkey", before + 1) == nil, "a different modifier does not trigger it")
mock.fire("keyDown", { keyCode = 68, isShiftDown = true, isControlDown = true, isAltDown = false })
check(libFind("trigger: hotkey", before + 1) ~= nil, "Ctrl+Shift+F10 runs it")

-- FAIL / SKIP paths ---------------------------------------------------------------------------------
if os.getenv("SMOKE_PRINT") then
    for _, l in ipairs(mock.libLogs()) do if l:find("[smoketest", 1, true) then print("SAMPLE " .. l) end end
end
section("failures are reported: handler error, broken script, runtime too old for the build, bad setting")
local rt = require("omwcompat")
local SYN = (os.getenv("TMPDIR_SYNTH") or "/tmp/omwcompat-synth") .. "-smoke/"
os.execute("mkdir -p '" .. SYN .. "scripts'")
local function write(p, s) local f = assert(io.open(SYN .. p, "w")); f:write(s); f:close() end
write("scripts/good.lua", "return { engineHandlers = { onUpdate = function() end, onActivate = function() end } }")
write("scripts/bad_update.lua", "return { engineHandlers = { onUpdate = function() error('boom') end } }")
write("scripts/syntax.lua", "return { this is not lua")
rt.register({ mod = "SynthGood", runtimeVersion = rt.VERSION, root = SYN, scripts = { { flags = { "GLOBAL" }, path = "scripts/good.lua" } } })
rt.register({ mod = "SynthBoom", runtimeVersion = "0.0.1", root = SYN, scripts = { { flags = { "GLOBAL" }, path = "scripts/bad_update.lua" } } })
rt.register({ mod = "SynthSyntax", runtimeVersion = "9.9.9", root = SYN, scripts = { { flags = { "GLOBAL" }, path = "scripts/syntax.lua" } } })
rt.register({ mod = "SynthNoVersion", root = SYN, scripts = { { flags = { "GLOBAL" }, path = "scripts/good.lua" } } })
mock.fire("loaded", { newGame = false })
mock.frames(120, 1 / 60)
rep = require(ST .. ".runner").run("mcm", 120, 2)
check(verdict("SynthGood", "handlers good.lua") == "PASS", "a healthy script passes: " .. tostring(select(2, verdict("SynthGood", "handlers good.lua"))))
check(verdict("SynthBoom", "handler errors") == "FAIL", "a script whose onUpdate throws FAILs")
check(verdict("SynthBoom", "built for") == "PASS", "older build is a PASS with a note")
check(verdict("SynthSyntax", "script files") == "FAIL", "a script that does not parse FAILs")
check(verdict("SynthSyntax", "built for") == "FAIL", "a build newer than the runtime FAILs")
check(verdict("SynthSyntax", "global scripts") == "FAIL", "a script that did not start FAILs")
check(verdict("SynthNoVersion", "built for") == "SKIP", "no recorded version is a SKIP")
check(verdict("LeaveTheLightsOff", "light scheduling") == "PASS", "LTLO still PASS")
local errs = rep.counts.FAIL
check(errs >= 4, "summary counts the failures (" .. rep:summary() .. ")")
check(#W.logs >= mwseLogsBefore and (function()
    for i = mwseLogsBefore + 1, #W.logs do
        if W.logs[i]:find("[smoketest", 1, true) then return false end
    end
    return true
end)(), "no smoke test line ever reached MWSE.log")
-- the probes did not leave their counters behind: only the real boom errors are counted
local wrongCount = false
for where in pairs(rt.timing.errors) do
    if not where:find("bad_update", 1, true) and not where:find("syntax.lua", 1, true) then wrongCount = true end
end
check(not wrongCount, "only the real errors (the throwing handler, the unparsable script) are counted")

section("SKIP: interior cell, and no save loaded")
local interior = mock.addCell({ id = "Balmora, Guild of Mages", isInterior = true })
W.activeCell = interior
rep = require(ST .. ".runner").run("mcm")
check(verdict("LeaveTheLightsOff", "light scheduling") == "SKIP", "LTLO schedule check skips in a plain interior: " .. tostring(select(2, verdict("LeaveTheLightsOff", "light scheduling"))))
W.activeCell = ext
mock.setHour(18.1)
mock.frames(5)
rep = require(ST .. ".runner").run("mcm")
check(verdict("LeaveTheLightsOff", "light scheduling") == "SKIP", "skips right after a switch hour")
mock.setHour(12)

-- the dev-only test cell -------------------------------------------------------------------------------
section("test cell: Go (teleport), fixtures spawn")
W.menuMode = false
local FIX = 11
local go = findCtl("Go to the test cell")
local startCreated = created(test)
go.args.callback()
check(W.activeCell == test, "player is in the test cell")
check(created(test) == startCreated + FIX, "fixtures spawned (" .. created(test) .. " created)")
check(refsOf(test, function(r) return r.sourceMod == ESP end) == 6, "the plugin's own references (levers, exit) are untouched")
local fx = require(ST .. ".fixtures")
check(#fx.spawned == FIX, "module tracks " .. FIX .. " spawned references")
check(W.config.omwcompat_smoketest.returnTo and W.config.omwcompat_smoketest.returnTo.cell == "Balmora", "return point stored in the mod's own config")
rep = require(ST .. ".runner").run("mcm", 200, 10)
mock.frames(200, 1 / 60)
check(verdict("world", "lights in this cell") == "PASS", "light census sees the cell's lights: " .. tostring(select(2, verdict("world", "lights in this cell"))))

section("test cell: levers")
local function pull(id) return mock.fire("activate", { activator = player, target = levers[id] }) end
mock.setHour(10)
check(pull("omwc_lever_time_hour") == false, "activation is blocked (handled)")
check(math.abs(tes3.worldController.hour.value - 11) < 1e-9, "+1 hour")
mock.setHour(23.5)
local d0 = tes3.worldController.daysPassed.value
pull("omwc_lever_time_hour")
check(math.abs(tes3.worldController.hour.value - 0.5) < 1e-9 and tes3.worldController.daysPassed.value == d0 + 1, "past midnight the day counter advances (clock never runs backwards)")
mock.setHour(7)
pull("omwc_lever_time_preset")
check(math.abs(tes3.worldController.hour.value - 12) < 1e-9, "preset: 07:00 -> 12:00")
pull("omwc_lever_time_preset"); check(math.abs(tes3.worldController.hour.value - 18) < 1e-9, "preset: 12:00 -> 18:00")
pull("omwc_lever_time_preset"); check(math.abs(tes3.worldController.hour.value - 0) < 1e-9, "preset: 18:00 -> 00:00")
pull("omwc_lever_time_preset"); check(math.abs(tes3.worldController.hour.value - 6) < 1e-9, "preset: 00:00 -> 06:00")
mock.setWeather(0)
pull("omwc_lever_wx_next")
check(lastWeather.immediate == 1 and wcon.currentWeather.index == 1, "next weather: Clear -> Cloudy")
pull("omwc_lever_wx_prev"); pull("omwc_lever_wx_prev")
check(wcon.currentWeather.index == 9, "previous weather wraps: Clear -> Blizzard")
check((lastWeather.visuals or 0) >= 3, "visuals refreshed after each change")
pull("omwc_lever_respawn")
check(fixtureRefs(test) == FIX, "respawn replaces the fixtures, no duplicates (" .. fixtureRefs(test) .. ")")

section("test cell: the fixtures heal themselves (0.1.2)")
local mwseHealBefore = #W.logs
local function killFix(id)
    local n = 0
    for _, r in ipairs(test._refs) do
        if r.sourceMod == nil and r.object.id == id and not r._gone then r:delete(); n = n + 1 end
    end
    return n
end
local function lastLine(needle)
    local out
    for i, l in ipairs(mock.libLogs()) do if l:find(needle, 1, true) then out = i end end
    return out
end
-- wildlife is armed when its mobile appears; nothing else is touched
local ratRef, npcRef
for _, r in ipairs(test._refs) do
    if r.sourceMod == nil and r.object.id == "rat" and not r._gone then ratRef = r end
    if r.sourceMod == nil and r.object.id == "omwc_smoke_npc_mage" and not r._gone then npcRef = r end
end
local ratMob, npcMob = { fight = 30 }, { fight = 30 }
mock.fire("mobileActivated", { reference = ratRef, mobile = ratMob })
mock.fire("mobileActivated", { reference = npcRef, mobile = npcMob })
check(ratMob.fight == 100, "a wildlife fixture is armed (fight 100) when its mobile appears")
check(npcMob.fight == 30, "an NPC fixture is left alone")
-- a weather change after something removed fixtures: refill at once, and say what was missing
killFix("omwc_smoke_torch"); killFix("omwc_smoke_firepit")
check(fixtureRefs(test) == FIX - 2, "(two fires were deleted behind the module's back)")
local mark = #mock.libLogs()
mock.fire("weatherTransitionFinished", {})
check(fixtureRefs(test) == FIX, "weather event: the missing fixtures are back (" .. fixtureRefs(test) .. ")")
local li = lastLine("MISSING: omwc_smoke_torch, omwc_smoke_firepit")
check(li ~= nil and li > mark, "the library log names the missing fixtures")
check(lastLine("heal: weatherTransitionFinished") ~= nil, "... and why it refilled")
-- periodic check, only while unpaused
killFix("omwc_smoke_npc_thief")
W.menuMode = true
mock.frames(200, 1 / 60)
check(fixtureRefs(test) == FIX - 1, "no refill while a menu is open")
W.menuMode = false
mock.frames(120, 1 / 60)
check(fixtureRefs(test) == FIX, "periodic check refills within 2 s of play")
-- a conversion disabling a fixture (No Fires in Bad Weather in rain) is not a loss
local before = W.created or 0
for _, r in ipairs(test._refs) do
    if r.sourceMod == nil and r.object.id == "omwc_smoke_torch" and not r._gone then r:disable() end
end
mock.fire("weatherChangedImmediate", {})
mock.frames(240, 1 / 60)
check((W.created or 0) == before, "a disabled fixture is not refilled")
-- a save whose 'saved' event never comes
mock.fire("save", { filename = "lost" })
check(created(test) == 0, "(fixtures taken out for the save)")
mock.frames(240, 1 / 60)
check(fixtureRefs(test) == FIX, "fixtures come back when 'saved' never arrives")
check(lastLine("did not arrive") ~= nil, "... and the log says so")
-- the respawn lever after everything is gone
for id in pairs(FIXIDS) do killFix(id) end
check(fixtureRefs(test) == 0, "(every fixture deleted)")
pull("omwc_lever_respawn")
check(fixtureRefs(test) == FIX, "respawn lever restores them all after a total loss, no duplicates (" .. fixtureRefs(test) .. ")")
-- something that keeps deleting them: three refills a minute, then it stops and says so
for i = 1, 4 do
    killFix("omwc_smoke_torch")
    mock.frames(100, 1 / 60)
end
check(fixtureRefs(test) == FIX - 1, "stops refilling after 3 times a minute")
check(lastLine("heal skipped") ~= nil, "... and logs that something keeps removing them")
pull("omwc_lever_respawn")
check(fixtureRefs(test) == FIX, "the respawn lever still works and resets the limit")
mock.setHour(12)


section("test cell: NFiBW-style weather and LTLO night in the cell")
mock.setWeather(4)       -- rain
mock.setHour(22)
mock.frames(300, 1 / 60)
rep = require(ST .. ".runner").run("mcm", 300, 5)
check(verdict("LeaveTheLightsOff", "light scheduling") ~= nil, "LTLO check runs in the quasi-exterior cell: " .. tostring(select(1, verdict("LeaveTheLightsOff", "light scheduling"))))

section("test cell: nothing persists in a save")
mock.setHour(12)
mock.frames(400, 1 / 60)    -- day: LTLO swaps the lanterns for off copies
local ltloCopies = created(test) - fixtureRefs(test)
check(ltloCopies > 0, "(LTLO made " .. ltloCopies .. " copies in the cell)")
mock.fire("save", { filename = "x" })
check(created(test) == 0, "everything not from the plugin is gone while the file is written (fixtures and conversion copies)")
mock.fire("saved", {})
check(fixtureRefs(test) == FIX, "fixtures are back afterwards")
-- a leftover from a crash / old save
local leftover = mock.placeRef(test, "omwc_smoke_robe", { 5, 5, 5 })
leftover.sourceMod = nil
local keep = mock.placeRef(test, "omwc_smoke_robe", { 6, 6, 6 }, { sourceMod = "Other.esp" })
mock.fire("loaded", { newGame = false })
check(leftover._gone == true and keep._gone ~= true, "load removes a leftover fixture, never another mod's reference")

section("test cell: leaving cleans up and restores the weather")
mock.setWeather(4)
mock.fire("loaded", { newGame = false })     -- loaded in the cell: entry weather is taken again
mock.setWeather(7)
check(pull("omwc_smoke_exit") == false, "the exit activator is handled")
check(W.activeCell == ext, "back in Balmora")
check(created(test) == 0, "no fixture left in the cell")
check(lastWeather.transition == 4, "weather restored to what it was on entering (" .. tostring(lastWeather.transition) .. ")")
check(math.abs(player.position.x - 11) < 1e-9 and math.abs(player.position.z - 33) < 1e-9, "player put back at the recorded position")

section("test cell: coc works without the mod's teleport; disabling removes everything")
tes3.positionCell({ reference = player, cell = test, position = { 0, 0, 0 } })   -- what `coc` does
check(created(test) == FIX, "fixtures appear when you arrive by any means")
mock.mcmSet(enabledCtl, false)
mock.mcmClose(tpl)
check(created(test) == 0, "switching the mod off removes them")
tes3.positionCell({ reference = player, cell = ext, position = { 0, 0, 0 } })

section("without the dev plugin the mod is quiet")
W.mods["omwc_smoketest_dev.esp"] = nil
tes3.getCell = (function(orig) return function(p) if p.id == "OMWC Smoke Test" then return nil end return orig(p) end end)(tes3.getCell)
check(fx.available() == false, "cell not available without the plugin")
go.args.callback()
check(W.activeCell == ext, "Go does nothing without the plugin")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
