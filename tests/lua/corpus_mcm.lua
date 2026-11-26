-- Probe one packaged corpus mod: load its generated main.lua in the mock, fire
-- modConfigReady, and dump what the generated MCM contains. Prints one line of
-- key=value pairs per template plus control rows; exits 1 on a Lua error.
-- Usage (cwd = packaged output folder): luajit corpus_mcm.lua <ModName>
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local name = assert(arg[1], "mod name")
local mock = require("mock_mwse").install({})
local W = mock.W
local ext = mock.addCell({ id = "Balmora", gridX = -3, gridY = -2, hasSky = true })
W.activeCell = ext
mock.newPlayer(ext)
dofile("Data Files/MWSE/mods/" .. name .. "/main.lua")
local rt = require("omwcompat")
mock.fire("initialized", {})
mock.fire("modConfigReady", {})
for _, l in ipairs(W.logs) do
    if l:find("probe") or l:find("renderer") then print("log\t" .. l) end
end
local reg = rt.settings.registry
local nGroups, nSettings = 0, 0
for _, k in ipairs(reg.groupOrder) do nGroups = nGroups + 1; nSettings = nSettings + #reg.groups[k].settings end
print(string.format("registry\tgroups=%d\tsettings=%d\tpages=%d", nGroups, nSettings, #reg.pageOrder))
local roundtrip_ok, roundtrip_bad = 0, 0
for _, t in ipairs(W.mcm) do
    local controls = mock.mcmControls(t)
    local infos = 0
    local function walk(c) if c.kind == "Info" then infos = infos + 1 end for _, ch in ipairs(c.children) do walk(ch) end end
    walk(t)
    print(string.format("template\t%s\tcontrols=%d\tinfo=%d", tostring(t.name), #controls, infos))
    for _, c in ipairs(controls) do
        local ok, v = pcall(mock.mcmGet, c)
        local ok2 = ok and pcall(mock.mcmSet, c, v)
        local ok3, v2 = pcall(mock.mcmGet, c)
        if ok and ok2 and ok3 and tostring(v2) == tostring(v) then roundtrip_ok = roundtrip_ok + 1 else roundtrip_bad = roundtrip_bad + 1 end
        print(string.format("control\t%s\t%s\t%s", c.kind, tostring(c.label), tostring(v)))
    end
end
mock.frames(2)
print(string.format("roundtrip\tok=%d\tbad=%d", roundtrip_ok, roundtrip_bad))
os.exit(roundtrip_bad == 0 and 0 or 1)
