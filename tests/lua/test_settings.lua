-- Settings scenarios: (1) LTLO converted with its sidecar -> generated MCM, live and
-- reload-applied tunables; (2) a synthetic GLOBAL mod using I.Settings + openmw.storage
-- with every renderer, subscribers, l10n and config persistence.
-- Run from staging/LeaveTheLightsOff via tests/run_lua_tests.sh.
package.path = "Data Files/MWSE/lib/?.lua;" .. os.getenv("TESTS_DIR") .. "/?.lua;" .. package.path
local mock = require("mock_mwse").install({ files = { ["meshes\\omwc\\ltlo\\72d5ca40.nif"] = true } })
local W = mock.W
local pass, fail = 0, 0
local function check(cond, msg)
    if cond then pass = pass + 1; print("  ok   " .. msg) else fail = fail + 1; print("  FAIL " .. msg) end
end
local function section(s) print("\n== " .. s) end

-- synthetic mod on disk ------------------------------------------------------
local SYN = os.getenv("TMPDIR_SYNTH") or "/tmp/omwcompat-synth/"
os.execute("mkdir -p '" .. SYN .. "scripts' '" .. SYN .. "l10n/Synth'")
local function write(p, s) local f = assert(io.open(SYN .. p, "w")); f:write(s); f:close() end
write("l10n/Synth/en.yaml", [[
page_name: "Synth Page"
group_name: Synth Group
enabled_name: Enabled
radius_name: "Radius"
radius_desc: "Search radius in {unit}."
fast: Fast mode
slow: Slow mode
]])
write("scripts/s.lua", [[
local storage = require('openmw.storage')
local I = require('openmw.interfaces')
local async = require('openmw.async')
local util = require('openmw.util')
I.Settings.registerPage { key = 'SynthPage', l10n = 'Synth', name = 'page_name' }
I.Settings.registerGroup { key = 'SettingsSynth', page = 'SynthPage', l10n = 'Synth', name = 'group_name', permanentStorage = true,
  settings = {
    { key = 'enabled', renderer = 'checkbox', name = 'enabled_name', default = true },
    { key = 'radius', renderer = 'number', name = 'radius_name', description = 'radius_desc', default = 5, argument = { min = 1, max = 10, integer = true } },
    { key = 'scale', renderer = 'number', name = 'scale', default = 1.5, argument = { min = 0 } },
    { key = 'mode', renderer = 'select', name = 'mode', default = 'fast', argument = { l10n = 'Synth', items = { 'fast', 'slow' } } },
    { key = 'label', renderer = 'textLine', name = 'label', default = 'hi' },
    { key = 'tint', renderer = 'color', name = 'tint', default = util.color.hex('ff8000') },
    { key = 'bind', renderer = 'inputBinding', name = 'bind', default = 'x', argument = { key = 'x', type = 'action' } },
    { key = 'fancy', renderer = 'SuperSlider', name = 'fancy', default = 3 },
  } }
local sec = storage.globalSection('SettingsSynth')
local seen = {}
sec:subscribe(async:callback(function(group, key) seen[#seen + 1] = group .. ':' .. tostring(key) end))
local other = storage.globalSection('SynthState')
return { interfaceName = 'Synth', interface = { seen = seen, sec = sec, other = other } }
]])

-- boot -------------------------------------------------------------------------
mock.addLight({ id = "light_de_lantern_01", mesh = "l\\light_de_lantern_01.nif", canCarry = true, name = "Lantern" })
local ext = mock.addCell({ id = "Balmora", gridX = -3, gridY = -2, hasSky = true })
W.activeCell = ext
local lantern = mock.placeRef(ext, "light_de_lantern_01", { 100, 200, 300 })
local player = mock.newPlayer(ext)
local function lit(r) return not r.disabled end

dofile("Data Files/MWSE/mods/mwsuite/openmw/LeaveTheLightsOff/main.lua")
local rt = require("omwcompat")
rt.register({ mod = "Synth", root = SYN, scripts = { { flags = { "GLOBAL" }, path = "scripts/s.lua" } }, probeSettings = true })
rt.register({ mod = "Plain", root = SYN, scripts = {}, credits = { title = "Plain Mod", author = "Zed" } })
mock.fire("initialized", {})
mock.fire("modConfigReady", {})

section("generated MCM: one 'MW Conversions' entry, one tab per mod")
local SUPPORT = "Unofficial conversion by mwsuite. Do not contact the original author about it. Support: dej (dejunai) via the Nexus Mods forums."
check(#W.mcm == 1, "exactly one MCM template registered (got " .. #W.mcm .. ")")
local tpl = W.mcm[1]
check(tpl and tpl.name == "MW Conversions", "template is named 'MW Conversions'")
local ltloT, synT
for _, pg in ipairs(tpl.children) do
    if pg.kind == "SideBarPage" then
        if pg.label == "Leave The Lights Off" then ltloT = pg elseif pg.label == "Synth" then synT = pg end
    end
end
check(#tpl.children == 4, "four tabs: disclaimer plus one per converted mod (got " .. #tpl.children .. ")")
local disc = tpl.children[1]
check(disc.label == "Disclaimer", "tab 1 is the general disclaimer")
local dtext = {}
for _, ch in ipairs(disc.children) do dtext[#dtext + 1] = ch.text end
dtext = table.concat(dtext, "\n")
for _, phrase in ipairs({ "experimental and unofficial", "retains all rights", "not affiliated with mwsuite", "without warranty of any kind",
    "omw2mwse", "omwcompat", "dej (dejunai) via the Nexus Mods forums" }) do
    check(dtext:find(phrase, 1, true), "disclaimer says: " .. phrase)
end
local plainT = tpl.children[3]
check(plainT.label == "Plain Mod" and plainT.children[1].text:find("Original author: Zed", 1, true) and plainT.children[2].text == "This mod has no settings to configure.", "a mod with nothing to configure still gets a tab with name, author and support")
check(tpl.children[2] == ltloT and tpl.children[4] == synT, "per-mod tabs start at tab 2, sorted by original mod name")
check(ltloT ~= nil, "LTLO tab labelled with the original mod name")
check(synT ~= nil, "synthetic mod tab exists (name fallback, no credits)")
local controls = ltloT and mock.mcmControls(ltloT) or {}
check(#controls == 11, "LTLO tab has 11 controls (got " .. #controls .. ")")
local function find(t, label) return mock.mcmFind(t, label) end
local endH = find(ltloT, "Night ends at (hour)")
local startH = find(ltloT, "Night starts after (hour)")
local rain = find(ltloT, "Light up during rain")
local stale = find(ltloT, "Animated light stale threshold (seconds)")
check(endH and endH.kind == "Slider" and endH.args.min == 0 and endH.args.max == 24 and endH.args.step == 1, "night end: integer slider 0-24")
check(stale and stale.kind == "Slider" and stale.args.decimalPlaces == 2, "stale threshold: decimal slider")
check(rain and rain.kind == "OnOffButton" and mock.mcmGet(rain) == false, "rain: on/off button, default off")
check(endH and endH.description:find("Default: 7", 1, true) and endH.description:find("Applies immediately", 1, true), "night end description shows default and live apply")
check(rain and rain.description:find("Applies when a save is loaded", 1, true), "rain description says it applies on reload")
local page1 = ltloT
local info1 = page1 and page1.children[1]
local cat = page1 and page1.children[2]
check(cat and cat.label == "Tunables (hard-coded in the original)", "LTLO category label from sidecar")
local NOTICE = "Unofficial mwsuite conversion of Leave The Lights Off (original author: OwnlyMe)"
check(info1 and info1.kind == "Info" and info1.text:find("Original mod: Leave The Lights Off\nOriginal author: OwnlyMe", 1, true)
    and info1.text:find(SUPPORT, 1, true), "tab text: original mod, author, support line")
local sb = page1.sidebar and page1.sidebar.children[1]
check(sb and sb.text == info1.text, "sidebar repeats the same text")
check(page1.description:find("nexusmods.com/morrowind/mods/57510", 1, true), "tab credits the original page")
local synInfo = synT.children[1]
check(synInfo.text:find("Original mod: Synth\nOriginal author: unknown", 1, true) and synInfo.text:find(SUPPORT, 1, true),
    "a mod without credits still names itself, 'unknown' author and the support line")
local logged = false
for _, l in ipairs(W.logs) do
    if l:find("registered LeaveTheLightsOff", 1, true) and l:find(NOTICE, 1, true) and l:find(SUPPORT, 1, true) then logged = true end
end
check(logged, "MWSE.log registration line carries the notice")


section("LTLO: day/night with defaults")
mock.setHour(12)
mock.fire("loaded", { newGame = true })
mock.frames(120)
check(not lit(lantern), "12:00 is day: original swapped out")
mock.setHour(20)
mock.frames(120)
check(lit(lantern), "20:00 is night (default starts after 18): original lit")

section("LTLO: live setting (NIGHT_START_HOUR) changed in the MCM")
W.menuMode = true
mock.mcmSet(startH, 21)
mock.frames(5)
W.menuMode = false
mock.mcmClose(tpl)
mock.frames(120)
check(mock.mcmGet(startH) == 21, "MCM reads back 21")
check(not lit(lantern), "20:00 is now day: change applied without reload")
local cfg = W.config and W.config["omwcompat_LeaveTheLightsOff"]
check(cfg and cfg.groups.omw2mwse_LeaveTheLightsOff.NIGHT_START_HOUR == 21, "saved to MWSE/config/omwcompat_LeaveTheLightsOff.json")
mock.mcmSet(startH, 99)
check(mock.mcmGet(startH) == 24, "slider value clamped to max 24")
mock.mcmSet(startH, 21)

section("LTLO: reload-applied setting (DARK_RAIN)")
mock.setHour(12)
mock.setWeather(4)
mock.frames(120)
check(not lit(lantern), "rain at noon with default DARK_RAIN=false: lights stay off")
W.menuMode = true
mock.mcmSet(rain, true)
mock.frames(60)
check(not lit(lantern), "not applied while the menu is open")
mock.mcmClose(tpl)
W.menuMode = false
local reloaded = false
for _, l in ipairs(W.logs) do if l:find("reloaded to apply changed settings") then reloaded = true end end
check(reloaded, "closing the MCM reloaded the mod's scripts")
mock.frames(120)
check(lit(lantern), "rain now counts as dark: original lit")
local errs = 0
for _, l in ipairs(W.logs) do if l:find("ERROR") or l:find("error in") then errs = errs + 1; print("    " .. l) end end
check(errs == 0, "no runtime errors after the reload")

section("LTLO: settings survive save/load and do not touch the save")
local snap = mock.save()
mock.load(snap)
mock.frames(120)
check(lit(lantern), "after load: DARK_RAIN=true still applied (read from config)")
check(not tes3.player.data.omwcompat_LeaveTheLightsOff:find("NIGHT_START_HOUR", 1, true), "tunables are not written into the save payload")

section("synthetic: every renderer")
local function syn(label) return find(synT, label) end
local en = syn("Enabled")
local rad = syn("Radius")
local mode = syn("mode")
local tint = syn("tint (hex RRGGBB)")
local fancy = syn("fancy")
check(en and en.kind == "OnOffButton", "checkbox -> on/off button (l10n label)")
check(rad and rad.kind == "Slider" and rad.args.step == 1, "number with min/max -> integer slider")
check(rad and rad.description:find("Search radius in {unit}.", 1, true), "description from l10n")
check(syn("scale") and syn("scale").kind == "TextField" and syn("scale").args.numbersOnly, "number with only min -> numeric text field")
check(mode and mode.kind == "Dropdown" and mode.options[1].label == "Fast mode" and mode.options[2].value == "slow", "select -> dropdown with l10n item labels")
check(syn("label") and syn("label").kind == "TextField", "textLine -> text field")
check(tint and mock.mcmGet(tint) == "ff8000", "color -> hex text field (ff8000)")
check(fancy and fancy.kind == "TextField", "custom renderer with a number default -> numeric fallback")
local infos = 0
local function walk(c) if c.kind == "Info" then infos = infos + 1 end for _, ch in ipairs(c.children) do walk(ch) end end
walk(synT)
check(infos >= 1, "inputBinding shown as info text")
local warned = false
for _, l in ipairs(W.logs) do if l:find("custom renderer 'SuperSlider'", 1, true) then warned = true end end
check(warned, "custom renderer logged once")

section("synthetic: storage + subscribers")
local S = rt.getInterface("Synth")
check(S and S.sec:get("radius") == 5, "section:get returns the declared default")
mock.mcmSet(rad, 8)
check(S.sec:get("radius") == 8, "MCM change visible through openmw.storage")
check(#S.seen == 0, "subscriber deferred to the next frame")
mock.frames(1)
check(S.seen[#S.seen] == "SettingsSynth:radius", "subscriber fired for the MCM change (" .. tostring(S.seen[#S.seen]) .. ")")
S.sec:set("enabled", false)
mock.frames(1)
check(mock.mcmGet(en) == false and S.seen[#S.seen] == "SettingsSynth:enabled", "script set shows in MCM and fires subscriber")
mock.mcmSet(tint, "00ff00")
local c = S.sec:get("tint")
check(type(c) == "table" and c.g and math.abs(c.g - 1) < 1e-6, "color stored as hex, returned as util.color")
mock.mcmSet(tint, "nope")
check(mock.mcmGet(tint) == "ff8000", "invalid hex resets to default")
S.other:set("count", 3)
check(S.other:get("count") == 3, "non-settings section stores values")
local scfg = W.config and W.config["omwcompat_Synth"]
check(scfg and scfg.groups.SettingsSynth.radius == 8 and scfg.groups.SynthState == nil, "settings group in config; other sections in the save")
local snap2 = mock.save()
check(tes3.player.data.omwcompat_Synth:find("SynthState", 1, true) ~= nil, "non-settings section saved in the save payload")
mock.load(snap2)
mock.frames(1)
S = rt.getInterface("Synth")
check(S.other:get("count") == 3 and S.sec:get("radius") == 8, "after load: save section and config values restored")
local before = #S.seen
mock.mcmSet(rad, 2)
mock.frames(1)
check(#S.seen == before + 1, "after load: exactly one subscriber (old ones dropped)")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
