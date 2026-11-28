-- omwcompat 0.4.4: MWSE.log gets only initialization lines (the version banner, a
-- pointer to the library log, and one "registered <mod>" line per mod). All other
-- output (warnings, errors, print(), sound-gate notices, timing, BUILT_FOR notes,
-- debug) goes to Data Files/MWSE/logs/omwcompat.log. Run from
-- staging/LeaveTheLightsOff via tests/run_lua_tests.sh.
-- Written for omwcompat by dej (dejunai).
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path

local LOG = "Data Files/MWSE/logs/omwcompat.log"
local PREV = "Data Files/MWSE/logs/omwcompat.log.prev"
os.execute("mkdir -p 'Data Files/MWSE/logs'")
local oldf = io.open(LOG, "w")
if oldf then oldf:write("previous session line\n"); oldf:close() end

local mock = require("mock_mwse").install({})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end
local function section(s) print("\n== " .. s) end

local rt = require("omwcompat")

section("path and session start")
check(rt.VERSION == "0.5.0", "runtime 0.5.0 (" .. rt.VERSION .. ")")
check(rt.LOG_PATH == LOG, "LOG_PATH is Data Files/MWSE/logs/omwcompat.log")
check(rt.LOG_PREV == PREV, "LOG_PREV is omwcompat.log.prev")
check(not rt.logFallback(), "the library log opened")
local prev = io.open(PREV, "r")
local prevText = prev and prev:read("*a") or ""
if prev then prev:close() end
check(prevText:find("previous session line", 1, true) ~= nil, "the previous session was kept as .prev")
check(#W.logs == 2, "MWSE.log has exactly the two init lines after require (" .. #W.logs .. ")")
check(W.logs[1] == "[omwcompat 0.5.0] loaded", "banner: " .. tostring(W.logs[1]))
check(W.logs[2] == "[omwcompat 0.5.0] library log: Data Files/MWSE/logs/omwcompat.log",
    "pointer: " .. tostring(W.logs[2]))
check(mock.libLogs()[1] == "[omwcompat 0.5.0] session start", "library log starts with a session line")

section("post-init output stays off MWSE.log")
local SYN = (os.getenv("TMPDIR_SYNTH") or "/tmp/omwcompat-synth") .. "-v044/"
os.execute("mkdir -p '" .. SYN .. "scripts'")
local f = assert(io.open(SYN .. "scripts/g.lua", "w"))
f:write([[
print('REC hello', 1)
return { engineHandlers = {
  onUpdate = function() error("boom") end,
} }
]])
f:close()
rt.warn("a one-time style warning")
rt.warnOnce("k1", "deduped warning")
rt.warnOnce("k1", "deduped warning")
rt.register({ mod = "LogTest", root = SYN, scripts = { { flags = { "GLOBAL" }, path = "scripts/g.lua" } } })
check(W.logs[3]:find("^%[omwcompat 0%.4%.4%] registered LogTest %(1 script%(s%)%)", 1) ~= nil
    or (W.logs[3] and W.logs[3]:find("registered LogTest", 1, true) ~= nil),
    "register line stays on MWSE.log: " .. tostring(W.logs[3]))
check(#W.logs == 3, "still only init lines on MWSE.log after a warning and register (" .. #W.logs .. ")")
local lib = mock.libLogs()
local function libHas(s)
    local n = 0
    for _, l in ipairs(lib) do if l:find(s, 1, true) then n = n + 1 end end
    return n
end
-- lib was snapshotted before later actions; rescan
local function countLib(s)
    local n = 0
    for _, l in ipairs(mock.libLogs()) do if l:find(s, 1, true) then n = n + 1 end end
    return n
end
check(countLib("WARNING: a one-time style warning") == 1, "RT.warn went to the library log")
check(countLib("WARNING: deduped warning") == 1, "warnOnce still dedupes")
for _, l in ipairs(W.logs) do
    check(not l:find("WARNING", 1, true) and not l:find("ERROR", 1, true) and not l:find("REC hello", 1, true),
        "MWSE.log has no warning/error/print: " .. l)
end

section("hosted print() and handler errors")
mock.fire("initialized", {})
local ext = mock.addCell({ id = "Seyda Neen", gridX = -2, gridY = -9 })
W.activeCell = ext
mock.newPlayer(ext)
mock.fire("loaded", { newGame = true })
mock.frames(6, 0.1)
check(#W.logs == 3, "MWSE.log still has only the three init lines after frames (" .. #W.logs .. ")")
check(countLib("[LogTest] REC hello") == 1, "hosted print() went to the library log")
check(countLib("ERROR in scripts/g.lua onUpdate: ") >= 1, "handler errors went to the library log")
check(countLib("stack traceback") == 1, "the first error of a site carries a traceback")
check(countLib("further errors in scripts/g.lua onUpdate suppressed") == 1, "the 5th error logs the suppression notice")
local errN = countLib("ERROR in scripts/g.lua onUpdate: ")
check(errN == 5, "5 error lines, later ones only counted (" .. errN .. ")")

section("RT.note (generated main.lua hook) and fallback")
local before = #W.logs
rt.note("[omwcompat %s] SomeMod was built for omwcompat %s (loaded %s)", "0.4.5", "0.4.0", "0.4.5")
check(#W.logs == before, "RT.note does not write to MWSE.log")
check(countLib("[omwcompat 0.4.5] SomeMod was built for omwcompat 0.4.0 (loaded 0.4.5)") == 1,
    "RT.note wrote the BUILT_FOR line to the library log")

local origMkdir = lfs.mkdir
lfs.mkdir = function(path)
    if tostring(path):find("blocked044", 1, true) then return nil, "permission denied" end
    return origMkdir(path)
end
rt.LOG_PATH = "Data Files/MWSE/logs/blocked044/omwcompat.log"
rt.LOG_PREV = "Data Files/MWSE/logs/blocked044/omwcompat.log.prev"
local openErr = rt.openLibraryLog()
check(rt.logFallback() == true, "openLibraryLog sets the fallback flag when mkdir fails")
check(openErr and (openErr:find("permission denied", 1, true) or openErr:find("cannot create", 1, true)) ~= nil,
    "the error names the failure: " .. tostring(openErr))
local nMwse = #W.logs
rt.warn("goes to MWSE.log under fallback")
check(#W.logs == nMwse + 1, "fallback warn appended to MWSE.log")
check(W.logs[#W.logs] == "[omwcompat] WARNING: goes to MWSE.log under fallback",
    "fallback line is the usual warn text: " .. tostring(W.logs[#W.logs]))
lfs.mkdir = origMkdir
rt.LOG_PATH = LOG
rt.LOG_PREV = PREV
rt.openLibraryLog()
-- a line after reopening must hit the file again, not MWSE.log
local nMwse2 = #W.logs
rt.warn("back on the file")
check(#W.logs == nMwse2, "after a successful reopen, warns leave MWSE.log alone")
check(mock.libLogs()[#mock.libLogs()] == "[omwcompat] WARNING: back on the file"
    or (function()
        for _, l in ipairs(mock.libLogs()) do
            if l:find("WARNING: back on the file", 1, true) then return true end
        end
    end)(), "the warn after reopen went to the library log")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
