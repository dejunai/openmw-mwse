-- world.mwscript.getGlobalScript: .variables read/write through tes3.getScript(id).context.
-- Pattern from No Fires in Bad Weather (Nexus 57579):
--   world.mwscript.getGlobalScript('wetfire_weather_monitor').variables.actweather
-- Run from staging/LeaveTheLightsOff via tests/run_lua_tests.sh.
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local mock = require("mock_mwse").install({})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end

local SYN = (os.getenv("TMPDIR_SYNTH") or "/tmp/omwcompat-synth") .. "-mws/"
os.execute("mkdir -p '" .. SYN .. "scripts'")
local f = assert(io.open(SYN .. "scripts/g.lua", "w"))
f:write([[
local world = require('openmw.world')
return { engineHandlers = {
  onUpdate = function()
    local seen = world.mwscript.getGlobalScript('mws_out').variables  -- results channel (the sandbox has no shared globals)
    local s = world.mwscript.getGlobalScript('Wetfire_Weather_Monitor')
    seen.weather = s and s.variables.actweather
    seen.recordId = s and s.recordId
    seen.missingVar = tostring(s and s.variables.nosuchvar)
    seen.missingScript = tostring(world.mwscript.getGlobalScript('no_such_script'))
    if s then s.variables.counter = (s.variables.counter or 0) + 1 end
    seen.badWrite = not pcall(function() s.variables.nosuchvar = 1 end)
    seen.badArg = not pcall(world.mwscript.getGlobalScript, 42)
    seen.otherFn = not pcall(function() return world.mwscript.getLocalScript end)
    if s and not seen.started then s.isRunning = false; seen.stoppedFlag = s.isRunning; seen.started = true end
  end,
} }
]])
f:close()

local sc = mock.addScript("wetfire_weather_monitor", { actweather = 4, counter = 0 })
local out = mock.addScript("mws_out", { weather = 0, recordId = "", missingVar = "unset", missingScript = "unset", badWrite = 0, badArg = 0, otherFn = 0, stoppedFlag = 0, started = false })
local rt = require("omwcompat")
rt.register({ mod = "MwsDemo", root = SYN, scripts = { { flags = { "GLOBAL" }, path = "scripts/g.lua" } } })
mock.fire("initialized", {})
local ext = mock.addCell({ id = "Ebonheart", gridX = 1, gridY = -13 })
W.activeCell = W.activeCell or ext
mock.newPlayer(ext)
mock.fire("loaded", { newGame = true })
mock.frames(3, 0.1)
local s = out._vars
check(s.weather == 4, "variables.actweather reads the global script variable (got " .. tostring(s.weather) .. ")")
check(s.recordid == "wetfire_weather_monitor", "recordId is lower-case")
check(s.missingvar == "nil", "unknown variable reads as nil")
check(s.missingscript == "nil", "unknown script returns nil")
check(sc._vars.counter >= 1, "write through .variables reaches the script context")
check(s.badwrite == true, "writing an unknown variable raises")
check(s.badarg == true, "non-string recordId raises")
check(s.otherfn == true, "other mwscript functions still raise (unsupported)")
check(sc._running == false and s.stoppedflag == false, "isRunning = false stops the global script")
sc._vars.actweather = 7
mock.frames(1, 0.1)
check(out._vars.weather == 7, "reads are live, not cached")
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
