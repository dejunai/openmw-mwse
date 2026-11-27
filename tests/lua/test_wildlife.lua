-- Scenario test: the ORIGINAL Wildlife Attacks NPCs Too 1.9 CREATURE script (Nexus 54448)
-- hosted by omwcompat in the MWSE mock. Needs the untracked corpus extract; skipped without it.
-- Run from staging/LeaveTheLightsOff via tests/run_lua_tests.sh.
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local ROOT = os.getenv("TESTS_DIR") .. "/../../corpus/wildlife-attacks-npcs-too/_archive/full/"
local probe = io.open(ROOT .. "scripts/wildlife_npc/wildlife.lua", "r")
if not probe then print("corpus/wildlife-attacks-npcs-too missing; skipped"); os.exit(0) end
probe:close()

local mock = require("mock_mwse").install({})
local W = mock.W
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end
local function section(s) print("\n== " .. s) end

local CT = tes3.objectType
mock.addObject({ id = "kagouti", objectType = CT.creature, aiConfig = { fight = 90 }, health = 40, inventory = {} })
mock.addObject({ id = "rat", objectType = CT.creature, aiConfig = { fight = 85 }, health = 10, inventory = {} })
mock.addObject({ id = "scamp", objectType = CT.creature, aiConfig = { fight = 90 }, health = 30, inventory = {} }) -- not listed
mock.addObject({ id = "guar", objectType = CT.creature, aiConfig = { fight = 90 }, health = 30, inventory = {} })
mock.addObject({ id = "fargoth", objectType = CT.npc, aiConfig = { fight = 0 }, health = 30, inventory = {} })
mock.addObject({ id = "thoronor", objectType = CT.npc, aiConfig = { fight = 0 }, health = 30, inventory = {} }) -- blacklisted
mock.addObject({ id = "corpse_npc", objectType = CT.npc, aiConfig = { fight = 0 }, health = 0, inventory = {} })

local rt = require("omwcompat")
rt.register({ mod = "WildlifeAttacksNPCsToo", root = ROOT, scripts = {
    { flags = { "CREATURE" }, path = "scripts/wildlife_npc/wildlife.lua" },
} })
mock.fire("initialized", {})
local ext = mock.addCell({ id = "Bitter Coast", gridX = -3, gridY = -4 })
local far = mock.addCell({ id = "Ald'ruhn", gridX = -2, gridY = 6 })
W.activeCell = ext
-- fight 90 -> attack radius (90 - 80) * 200 = 2000; fight 85 -> 1000
local kag = mock.placeRef(ext, "kagouti", { 0, 0, 0 })
local rat = mock.placeRef(ext, "rat", { 10000, 0, 0 })
local scamp = mock.placeRef(ext, "scamp", { 20000, 0, 0 })
local guar = mock.placeRef(ext, "guar", { 30000, 0, 0 })
local fargoth = mock.placeRef(ext, "fargoth", { 1500, 0, 0 })            -- 1500 from kagouti
local npc2 = mock.placeRef(ext, "fargoth", { 11500, 0, 0 })             -- 1500 from the rat
local thor = mock.placeRef(ext, "thoronor", { 30100, 0, 0 })            -- nearest to the guar, blacklisted
local corpse = mock.placeRef(ext, "corpse_npc", { 20200, 0, 0 })        -- nearest to the scamp, dead
local player = mock.newPlayer(ext)
local mk = mock.addMobile(kag, { hp = 40, fight = 90, pkg = tes3.aiPackage.wander })
local mr = mock.addMobile(rat, { hp = 10, fight = 85, pkg = tes3.aiPackage.wander })
local ms = mock.addMobile(scamp, { hp = 30, fight = 95, pkg = tes3.aiPackage.wander })
local mg = mock.addMobile(guar, { hp = 30, fight = 90, pkg = tes3.aiPackage.wander })
local mf = mock.addMobile(fargoth, { hp = 30 })
mock.addMobile(npc2, { hp = 30 })
mock.addMobile(thor, { hp = 30 })
mock.addMobile(corpse, { hp = 0, dead = true })
mock.addMobile(player, { hp = 100 })

section("behaviour")
mock.fire("loaded", { newGame = true })
mock.frames(12, 0.1) -- 1.2 s: first check at 1 s
check(#mk.combatCalls == 1 and mk.combatCalls[1] == mf, "kagouti (fight 90) attacks the NPC 1500 units away")
check(#mr.combatCalls == 0, "rat (fight 85, radius 1000) leaves the NPC 1500 units away alone")
check(#ms.combatCalls == 0, "unlisted creature never attacks")
check(#mg.combatCalls == 0, "blacklisted nearest NPC is not attacked")
mock.frames(30, 0.1) -- t = 4.2 s: second check at 4 s
check(#mk.combatCalls == 2, "checks repeat every 3 s (got " .. #mk.combatCalls .. ")")

section("busy / dead creature")
mk.inCombat = true
mock.frames(30, 0.1) -- t = 7.2
check(#mk.combatCalls == 2, "a creature already in combat starts nothing new")
mk.inCombat = false
mk.aiPlanner.getActivePackage = function() return { type = tes3.aiPackage.follow } end
mock.frames(30, 0.1) -- t = 10.2
check(#mk.combatCalls == 2, "a creature on a Follow package starts nothing")
mk.aiPlanner.getActivePackage = function() return nil end
mock.frames(30, 0.1) -- t = 13.2
check(#mk.combatCalls == 3, "no package counts like Wander (attacks again)")
mk.health.current = 0
mock.frames(30, 0.1)
check(#mk.combatCalls == 3, "a dead creature starts nothing")
mk.health.current = 40

section("cell change")
mock.fire("referenceDeactivated", { reference = kag })
mock.frames(60, 0.1)
check(#mk.combatCalls == 3, "no checks while the creature's cell is inactive")
mock.fire("referenceActivated", { reference = kag })
local c0 = #mk.combatCalls
mock.frames(92, 0.1) -- 9.2 s after reactivation: checks at 1, 4, 7 s
check(#mk.combatCalls - c0 == 3, "one 3 s loop after reactivation, not two (got " .. (#mk.combatCalls - c0) .. ")")

section("save / load")
local snap = mock.save()
mock.load(snap)
local newKag, newFar
for _, r in ipairs(ext._refs) do
    if r.object.id == "kagouti" then newKag = r end
    if r.object.id == "fargoth" and r.position.x == 1500 then newFar = r end
    if r.object.id ~= "kagouti" and r.object.objectType ~= CT.static then
        if not rawget(r, "mobile") then mock.addMobile(r, { hp = 30, fight = 50 }) end
    end
end
local nk = mock.addMobile(newKag, { hp = 40, fight = 90, pkg = tes3.aiPackage.wander })
mock.frames(12, 0.1)
check(#nk.combatCalls == 1 and nk.combatCalls[1] == newFar.mobile, "the loop restarts after loading a save")
local d = rawget(newKag, "_data")
check(d == nil or d.omwcompat_id == nil, "no reference data written for Wildlife's creatures")

section("errors")
local errs = {}
for _, line in ipairs(mock.allLogs()) do if line:find("ERROR", 1, true) or line:find("WARNING", 1, true) then errs[#errs + 1] = line end end
check(#errs == 0, "no runtime errors or warnings (" .. (errs[1] or "") .. ")")
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
