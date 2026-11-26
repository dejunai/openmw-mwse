-- Parity: run the same world through (a) original LTLO via omwcompat and (b) Dej's
-- hand port (reference/mwse_dej/main.lua), then compare which original lights are
-- hidden (disabled) in each phase. Child processes keep the two runs isolated.
local mode = arg and arg[1]
local TESTS = os.getenv("TESTS_DIR")
package.path = "Data Files/MWSE/lib/?.lua;" .. TESTS .. "/?.lua;" .. package.path

if mode == nil then
    local function run(m)
        local p = io.popen(string.format("TESTS_DIR=%q luajit %q %s 2>&1", TESTS, TESTS .. "/test_parity.lua", m))
        local out = p:read("*a"); p:close()
        return out
    end
    local a, b = run("omw"), run("dej")
    print("-- omwcompat + original LTLO:\n" .. a)
    print("-- Dej hand port:\n" .. b)
    local function lines(s) local t = {}; for l in s:gmatch("[^\n]+") do if l:find("^phase") then t[#t + 1] = l end end; return t end
    local la, lb = lines(a), lines(b)
    local pass, fail = 0, 0
    for i = 1, math.max(#la, #lb) do
        if la[i] == lb[i] then pass = pass + 1; print("  ok   " .. tostring(la[i]))
        else fail = fail + 1; print("  DIFF omw: " .. tostring(la[i]) .. "\n       dej: " .. tostring(lb[i])) end
    end
    print(string.format("\n%d phases equal, %d differ", pass, fail))
    os.exit((fail == 0 and #la > 0) and 0 or 1)
end

local mock = require("mock_mwse").install({ files = { ["meshes\\omwc\\ltlo\\72d5ca40.nif"] = true } })
local W = mock.W
mock.addLight({ id = "light_de_lantern_01", mesh = "l\\light_de_lantern_01.nif", canCarry = true })
mock.addLight({ id = "light_de_streetlight_01", mesh = "l\\light_de_streetlight_01.nif" })
mock.addLight({ id = "light_com_candle_01", mesh = "l\\light_com_candle_01.nif", canCarry = true })
mock.addLight({ id = "torch_tall_01", mesh = "l\\light_torch_tall.nif" })
local ext = mock.addCell({ id = "Balmora" })
local int = mock.addCell({ id = "Interior", isInterior = true })
W.activeCell = ext
local refs = {
    lantern = mock.placeRef(ext, "light_de_lantern_01", { 1, 0, 0 }),
    street = mock.placeRef(ext, "light_de_streetlight_01", { 2, 0, 0 }),
    candle = mock.placeRef(ext, "light_com_candle_01", { 3, 0, 0 }),
    torch = mock.placeRef(ext, "torch_tall_01", { 4, 0, 0 }),
    inner = mock.placeRef(int, "light_de_lantern_01", { 5, 0, 0 }),
}
mock.newPlayer(ext)
if mode == "omw" then
    dofile("Data Files/MWSE/mods/LeaveTheLightsOff/main.lua")
else
    W.config = { leavethelightsoff = { dayStart = 7, enabled = true, log = false, dayEnd = 18, darkWeather = true } }
    dofile(os.getenv("TESTS_DIR") .. "/../../reference/mwse_dej/main.lua")
end
mock.fire("initialized", {})
local function phase(name)
    mock.frames(300)
    local hidden, offs = {}, 0
    for _, k in ipairs({ "candle", "inner", "lantern", "street", "torch" }) do
        if refs[k].disabled then hidden[#hidden + 1] = k end
    end
    for _, r in ipairs(mock.refsIn(ext, false)) do if r.object.isOffByDefault then offs = offs + 1 end end
    print(string.format("phase %-10s hidden={%s} offCopies=%d", name, table.concat(hidden, ","), offs))
end
mock.setHour(12); mock.fire("loaded", { newGame = true }); phase("noon")
mock.setHour(22); phase("night")
mock.setHour(12); phase("noon2")
mock.setWeather(6); phase("ashstorm")
mock.setWeather(0); phase("clear")
mock.setHour(6.5); phase("06:30")
mock.setHour(18.5); phase("18:30")
