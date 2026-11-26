-- omwcompat runtime version a mod was built for vs the loaded runtime:
-- the generated main.lua logs exactly one line on a mismatch and nothing when they match;
-- the runtime adds both versions to its "not hosted" warning.
-- Run from staging/LeaveTheLightsOff via tests/run_lua_tests.sh.
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local mock = require("mock_mwse").install({})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end
local function section(s) print("\n== " .. s) end

local MAIN = "Data Files/MWSE/mods/mwsuite/openmw/LeaveTheLightsOff/main.lua"
local f = assert(io.open(MAIN, "r")); local src = f:read("*a"); f:close()
local rt = require("omwcompat")
local built = src:match('local BUILT_FOR = "([^"]+)"')

section("generated main.lua declares the runtime it was built for")
check(built == rt.VERSION, "BUILT_FOR " .. tostring(built) .. " == bundled runtime " .. rt.VERSION)
check(src:find("runtimeVersion = BUILT_FOR", 1, true) ~= nil, "register() gets runtimeVersion")

-- run main.lua against a stand-in runtime of a given version; returns the log lines it wrote
local function runMain(loaded, builtFor)
    local text = src:gsub('local BUILT_FOR = "[^"]+"', 'local BUILT_FOR = "' .. builtFor .. '"', 1)
    local spec
    package.loaded["omwcompat"] = { VERSION = loaded, register = function(s) spec = s end }
    local start = #W.logs
    assert(loadstring(text, "=main.lua"))()
    package.loaded["omwcompat"] = rt
    local lines = {}
    for i = start + 1, #W.logs do lines[#lines + 1] = W.logs[i] end
    return lines, spec
end

section("match: nothing logged")
local lines, spec = runMain("0.3.1", "0.3.1")
check(#lines == 0, "no log lines (" .. #lines .. ")")
check(spec and spec.runtimeVersion == "0.3.1", "spec.runtimeVersion passed through")

section("loaded runtime newer than the build")
lines = runMain("0.3.1", "0.2.2")
check(#lines == 1, "exactly one line (" .. #lines .. ")")
check(lines[1] == "[omwcompat 0.3.1] LeaveTheLightsOff was built for omwcompat 0.2.2 (loaded 0.3.1)", tostring(lines[1]))

section("loaded runtime older than the build (an older copy won in Vortex)")
lines = runMain("0.2.2", "0.3.1")
check(#lines == 1, "exactly one line (" .. #lines .. ")")
check(lines[1] == "[omwcompat 0.2.2] LeaveTheLightsOff was built for omwcompat 0.3.1 (loaded 0.2.2)", tostring(lines[1]))

section("runtime: unhosted-flag warning carries both versions only on a mismatch")
local SYN = (os.getenv("TMPDIR_SYNTH") or "/tmp/omwcompat-synth") .. "-versions/"
os.execute("mkdir -p '" .. SYN .. "scripts'")
local g = assert(io.open(SYN .. "scripts/p.lua", "w")); g:write("return {}\n"); g:close()
local function warnings(mod, builtFor)
    local start = #W.logs
    rt.register({ mod = mod, root = SYN, runtimeVersion = builtFor,
        scripts = { { flags = { "PLAYER" }, path = "scripts/p.lua" } } })
    local out = {}
    for i = start + 1, #W.logs do
        if W.logs[i]:find("not hosted", 1, true) then out[#out + 1] = W.logs[i] end
        check(not W.logs[i]:find("was built for", 1, true), mod .. ": the runtime itself adds no mismatch line")
    end
    return out
end
local same = warnings("VerSame", rt.VERSION)
check(#same == 1 and not same[1]:find("built for", 1, true), "same version: plain warning: " .. tostring(same[1]))
local newer = warnings("VerNewer", "9.9.9")
check(#newer == 1 and newer[1]:find("(built for omwcompat 9.9.9, loaded " .. rt.VERSION .. ")", 1, true) ~= nil,
    "built for a newer runtime: " .. tostring(newer[1]))
local none = warnings("VerUnknown", nil)
check(#none == 1 and not none[1]:find("built for", 1, true), "no runtimeVersion (older build): plain warning")

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
