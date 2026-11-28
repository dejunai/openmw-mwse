-- omwcompat_smoketest: an optional, read-only self check for the OpenMW conversions (omwcompat).
-- OFF by default. Turn it on in Mod Config Menu > "OpenMW Smoke Test". When on, it waits a few
-- seconds after each load (so the scripts have really run), checks every registered conversion,
-- and writes a PASS / FAIL / SKIP report to Data Files/MWSE/logs/omwcompat.log. MWSE.log gets nothing.
-- "Run now" in the menu and the hotkey (default Ctrl+Shift+F10) run it on demand, also when it is off.
-- The checks never spawn, move, enable, disable or delete anything and never write to a save.
-- With the DEV-ONLY plugin OMWC_SmokeTest_DEV.esp active, the menu can also take you to a test cell
-- ("OMWC Smoke Test") where this mod, while enabled, spawns test fixtures (lanterns, fires, NPCs, a
-- creature, a robe and a shield) and removes them again on leaving, on every save and on load.
-- Written for omwcompat by dej (dejunai). MIT.
local runner = require("mwsuite.openmw.omwcompat_smoketest.runner")
local fixtures = require("mwsuite.openmw.omwcompat_smoketest.fixtures")

local CONFIG = "omwcompat_smoketest"
local F10 = (tes3.scanCode and tes3.scanCode.f10) or 68
local defaults = {
    enabled = false,        -- off by default
    runOnLoad = true,       -- when enabled: run once after every load
    delaySeconds = 20,      -- unpaused play time to wait first
    minFrames = 120,        -- ... and at least this many unpaused frames
    showMessage = true,     -- one message box with the summary
    hotkey = { keyCode = F10, isShiftDown = true, isControlDown = true, isAltDown = false },
}
local config = mwse.loadConfig(CONFIG, defaults)
for k, v in pairs(defaults) do if config[k] == nil then config[k] = v end end

local pending            -- { frames, seconds } while waiting for a post-load run
local registered = {}    -- event name -> handler, so they can be unregistered again

local function say(rep)
    if config.showMessage and tes3.messageBox then tes3.messageBox("%s", runner.messageLine(rep)) end
end

local function onEnterFrame(e)
    if not pending then return end
    if e.menuMode then return end   -- paused: nothing runs, so nothing to observe
    pending.frames = pending.frames + 1
    pending.seconds = pending.seconds + (e.delta or 0)
    if pending.seconds >= (config.delaySeconds or 20) and pending.frames >= (config.minFrames or 120) then
        local p = pending
        pending = nil
        event.unregister(tes3.event.enterFrame, onEnterFrame)
        registered.enterFrame = nil
        say(runner.run("load", p.frames, p.seconds))
    end
end

local function onLoaded()
    fixtures.onLoaded(config.enabled)
    if not config.enabled or not config.runOnLoad then return end
    pending = { frames = 0, seconds = 0 }
    if not registered.enterFrame then
        registered.enterFrame = onEnterFrame
        event.register(tes3.event.enterFrame, onEnterFrame)
    end
end

local function sameKey(e, k)
    if tes3.isKeyEqual then return tes3.isKeyEqual({ actual = e, expected = k }) end
    return e.keyCode == k.keyCode and (e.isShiftDown or false) == (k.isShiftDown or false)
        and (e.isControlDown or false) == (k.isControlDown or false) and (e.isAltDown or false) == (k.isAltDown or false)
end
local function onKeyDown(e)
    if not config.enabled or not config.hotkey or (tes3.menuMode and tes3.menuMode()) then return end
    if sameKey(e, config.hotkey) then
        local info = pending
        say(runner.run("hotkey", info and info.frames, info and info.seconds))
    end
end

local function saveCfg() mwse.saveConfig(CONFIG, config) end
local function goBack() return fixtures.goBack(config) end
local function onCellChanged(e) fixtures.onCellChanged(e, config.enabled) end
local function onSave() fixtures.onSave() end
local function onSaved() fixtures.onSaved(config.enabled) end
local function onActivate(e)
    if fixtures.onActivate(e, goBack) then return false end
end

-- handlers exist only while the mod is enabled (when it is switched off the fixtures are removed)
local function apply()
    if config.enabled then
        if not registered.loaded then registered.loaded = onLoaded; event.register(tes3.event.loaded, onLoaded) end
        if not registered.keyDown then registered.keyDown = onKeyDown; event.register(tes3.event.keyDown, onKeyDown) end
        if not registered.cellChanged then registered.cellChanged = onCellChanged; event.register(tes3.event.cellChanged, onCellChanged) end
        if not registered.save then registered.save = onSave; event.register(tes3.event.save, onSave) end
        if not registered.saved then registered.saved = onSaved; event.register(tes3.event.saved, onSaved) end
        if not registered.activate then registered.activate = onActivate; event.register(tes3.event.activate, onActivate) end
    else
        pending = nil
        if tes3.player and #fixtures.spawned > 0 then fixtures.onLeave() end
        for name, fn in pairs({ loaded = onLoaded, keyDown = onKeyDown, enterFrame = onEnterFrame, cellChanged = onCellChanged,
            save = onSave, saved = onSaved, activate = onActivate }) do
            if registered[name] then
                event.unregister(tes3.event[name], fn)
                registered[name] = nil
            end
        end
    end
end
apply()

event.register(tes3.event.modConfigReady, function()
    local template = mwse.mcm.createTemplate({ name = "OpenMW Smoke Test" })
    template.onClose = function() saveCfg(); apply() end
    local page = template:createSideBarPage({ label = "Smoke test",
        description = "A read-only self check for the OpenMW conversions. It never changes the game world or your saves. "
            .. "The report is written to Data Files\\MWSE\\logs\\omwcompat.log." })
    local function var(id) return mwse.mcm.createTableVariable({ id = id, table = config }) end
    page:createOnOffButton({ label = "Enabled", description = "Off by default. When on, a check runs a few seconds after every load, and the hotkey works.",
        variable = var("enabled"), callback = function() apply() end })
    page:createOnOffButton({ label = "Run after every load", description = "Wait for the delay below, then check every conversion once.",
        variable = var("runOnLoad") })
    page:createSlider({ label = "Delay after load (seconds of play)", description = "Unpaused play time to wait before checking, so the scripts have run.",
        min = 5, max = 120, step = 5, jump = 15, variable = var("delaySeconds") })
    page:createOnOffButton({ label = "Show a message with the result", variable = var("showMessage") })
    page:createKeyBinder({ label = "Run now (hotkey)", description = "Works while the mod is enabled and no menu is open.",
        allowCombinations = true, variable = var("hotkey") })
    page:createButton({ buttonText = "Run now", label = "Run the smoke test now",
        description = "Runs the check immediately, whether or not the mod is enabled. Load a save first.",
        callback = function() say(runner.run("mcm")) end })
    page:createInfo({ text = "Test cell (dev only). Needs " .. fixtures.ESP .. " in the load order. The cell is an interior that behaves "
        .. "like an exterior, so sky, sun and weather work there. While this mod is enabled it is filled with test fixtures; they are removed "
        .. "when you leave, on every save and on load. Levers in the cell step the clock forward and cycle the weather." })
    page:createButton({ buttonText = "Go", label = "Go to the test cell", description = "Remembers where you are so the button below (or the exit door in the cell) can bring you back. `coc \"OMWC Smoke Test\"` works too.",
        callback = function() fixtures.goTo(config, saveCfg) end })
    page:createButton({ buttonText = "Back", label = "Return to where I was",
        callback = function() fixtures.goBack(config) end })
    page:createButton({ buttonText = "Respawn", label = "Respawn the fixtures",
        description = "Only while you are in the test cell and this mod is enabled.",
        callback = function() if config.enabled and fixtures.playerInTestCell() then fixtures.spawn() end end })
    template:register()
end)
