-- omwcompat_smoketest fixtures: the DEV-ONLY test cell "OMWC Smoke Test" (OMWC_SmokeTest_DEV.esp).
-- The plugin holds only the cell, a floor, six activators (levers and an exit) and the base records.
-- This module fills the cell with test fixtures while the smoke test mod is enabled, and removes them
-- again when you leave, when a save is written, and on load, so no spawned reference stays in a save
-- (that includes copies converted mods make in the cell).
-- It never touches anything outside that cell. What it does change on purpose: the game hour
-- (forward only: a rewound clock would confuse the converted mods' timers) and the weather,
-- which is put back to what it was when you entered. Written for omwcompat by dej (dejunai). MIT.
local F = {}

F.ESP = "OMWC_SmokeTest_DEV.esp"
F.CELL = "OMWC Smoke Test"
F.EXIT_ID = "omwc_smoke_exit"
F.WEATHER = { [0] = "Clear", "Cloudy", "Foggy", "Overcast", "Rain", "Thunderstorm", "Ashstorm", "Blight", "Snow", "Blizzard" }
F.PRESET_HOURS = { 6, 12, 18, 0 }

-- id, position inside the cell (the floor is at z = 0, the cell centre, where `coc` puts you, is free)
F.FIXTURES = {
    -- LTLO: whitelisted lights (ids contain lantern / streetlight), meshes LTLO has off models for
    { id = "omwc_smoke_lantern_de", x = -360, y = 300, z = 0, tag = "ltlo" },
    { id = "omwc_smoke_lantern_paper", x = -180, y = 300, z = 0, tag = "ltlo" },
    { id = "omwc_smoke_streetlight", x = 0, y = 300, z = 0, tag = "ltlo" },
    -- No Fires in Bad Weather: fires (ids contain torch / firepit)
    { id = "omwc_smoke_torch", x = 180, y = 300, z = 0, tag = "nfibw" },
    { id = "omwc_smoke_firepit", x = 360, y = 300, z = 0, tag = "nfibw" },
    -- Thieves Pickpocket and Mage Robes: NPCs
    { id = "omwc_smoke_npc_thief", x = -200, y = -250, z = 0, rot = 0, tag = "npc" },
    { id = "omwc_smoke_npc_mage", x = 200, y = -250, z = 0, rot = 0, tag = "npc" },
    -- Wildlife Attacks NPCs Too: a vanilla creature the mod lists, next to the thief
    { id = "rat", x = -120, y = -250, z = 0, rot = 1.57, tag = "wildlife" },
    -- Mage Robes and Shield Unequipper: the items
    { id = "omwc_smoke_robe", x = -100, y = -100, z = 4, tag = "items" },
    { id = "omwc_smoke_shield", x = 100, y = -100, z = 4, tag = "items" },
}

local LEVERS = { omwc_lever_time_hour = "hour", omwc_lever_time_preset = "preset", omwc_lever_wx_next = "wxnext",
    omwc_lever_wx_prev = "wxprev", omwc_lever_respawn = "respawn" }

F.spawned = {}        -- references this module created
F.entry = nil         -- { weather = index } taken on entering the cell
F.origin = nil        -- where the player came from: { cell, exterior, gridX, gridY, pos, rot }
F.suspended = false   -- fixtures are removed for a save and come back afterwards

local function say(fmt, ...)
    if tes3.messageBox then tes3.messageBox(fmt, ...) end
end

------------------------------------------------------------------------ cell lookup
function F.cell()
    local ok, c = pcall(tes3.getCell, { id = F.CELL })
    return ok and c or nil
end
function F.available()
    if tes3.isModActive and not tes3.isModActive(F.ESP) then return false end
    return F.cell() ~= nil
end
function F.isTestCell(cell)
    return cell ~= nil and tostring(cell.id or cell.editorName or ""):lower() == F.CELL:lower()
end
function F.playerInTestCell()
    local ok, c = pcall(function() return tes3.getPlayerCell and tes3.getPlayerCell() or tes3.player.cell end)
    return ok and F.isTestCell(c)
end

------------------------------------------------------------------------ spawn / despawn
local function remove(ref)
    pcall(function()
        if ref and not ref.deleted then
            ref:disable()
            ref:delete()
        end
    end)
end

function F.despawn()
    local n = 0
    for _, ref in ipairs(F.spawned) do
        if not ref.deleted then n = n + 1 end
        remove(ref)
    end
    F.spawned = {}
    return n
end

-- Everything that is not part of the plugin: references in the test cell without a content file.
-- That is this module's fixtures, whatever a save or a crash left behind, and what converted mods
-- made there (LTLO's off-copy lights, dropped items). The plugin's own references (floor, levers,
-- exit) and any other plugin's references are never touched. Records a conversion generated
-- (for example LTLO's off-copy light records) are not references and stay in the save, unused.
function F.purgeLeftovers()
    local cell = F.cell()
    if not cell then return 0 end
    local kill = {}
    for ref in cell:iterateReferences() do
        if ref.sourceMod == nil and not ref.deleted then kill[#kill + 1] = ref end
    end
    for _, ref in ipairs(kill) do remove(ref) end
    return #kill
end

function F.spawn()
    local cell = F.cell()
    if not cell then return 0, { "test cell not found" } end
    F.despawn()
    F.purgeLeftovers()
    local errors = {}
    for _, f in ipairs(F.FIXTURES) do
        local ok, ref = pcall(tes3.createReference, { object = f.id, cell = cell, position = { f.x, f.y, f.z },
            orientation = { 0, 0, f.rot or 0 } })
        if ok and ref then F.spawned[#F.spawned + 1] = ref
        else errors[#errors + 1] = f.id .. ": " .. tostring(ref) end
    end
    return #F.spawned, errors
end

------------------------------------------------------------------------ time and weather (levers)
local function wc() return tes3.worldController end

local function showClock()
    local w = wc()
    local cur = w.weatherController and w.weatherController.currentWeather
    local h = w.hour.value
    say("Smoke test cell: %02d:%02d, weather %s", math.floor(h), math.floor((h % 1) * 60),
        cur and (F.WEATHER[cur.index] or cur.name) or "?")
end

-- forward only: past midnight the day counter moves on too, so the game clock never runs backwards
local function advanceHours(delta)
    local w = wc()
    local h = w.hour.value + delta
    while h >= 24 do
        h = h - 24
        w.daysPassed.value = w.daysPassed.value + 1
    end
    w.hour.value = h
end

function F.nextPresetDelta(hour)
    local best
    for _, p in ipairs(F.PRESET_HOURS) do
        local d = (p - hour) % 24
        if d < 0.01 then d = d + 24 end
        if not best or d < best then best = d end
    end
    return best
end

function F.setWeather(index)
    local wcon = wc().weatherController
    index = index % 10
    if wcon.switchImmediate then wcon:switchImmediate(index) end
    if wcon.updateVisuals then wcon:updateVisuals() end
end
function F.stepWeather(step)
    local cur = wc().weatherController.currentWeather
    F.setWeather(((cur and cur.index or 0) + step) % 10)
end

function F.pull(lever)
    if lever == "hour" then advanceHours(1)
    elseif lever == "preset" then advanceHours(F.nextPresetDelta(wc().hour.value))
    elseif lever == "wxnext" then F.stepWeather(1)
    elseif lever == "wxprev" then F.stepWeather(-1)
    elseif lever == "respawn" then
        local n, errs = F.spawn()
        say("Smoke test cell: %d fixtures respawned%s", n, #errs > 0 and (", " .. #errs .. " failed (see log)") or "")
        return
    end
    showClock()
end

-- the activate event: returns true when the target was one of ours (the caller blocks the default)
function F.onActivate(e, goBack)
    if e.activator ~= tes3.player or not e.target or not e.target.object then return false end
    local id = tostring(e.target.object.id):lower()
    if id == F.EXIT_ID then goBack(); return true end
    local lever = LEVERS[id]
    if lever then F.pull(lever); return true end
    return false
end

------------------------------------------------------------------------ entering and leaving
function F.onEnter()
    local wcon = wc().weatherController
    if not F.entry then F.entry = { weather = wcon and wcon.currentWeather and wcon.currentWeather.index } end
end
function F.onLeave()
    F.despawn()
    F.purgeLeftovers()
    if F.entry then
        if F.entry.weather and wc().weatherController and wc().weatherController.switchTransition then
            pcall(function() wc().weatherController:switchTransition(F.entry.weather) end)
        end
        F.entry = nil
    end
end

-- cellChanged: spawn on entering the cell, clean up on leaving it
function F.onCellChanged(e, enabled)
    if F.isTestCell(e.cell) then
        F.onEnter()
        if enabled and #F.spawned == 0 then F.spawn() end
    elseif F.isTestCell(e.previousCell) then
        F.onLeave()
    end
end

-- loaded: nothing from an earlier session may stay; if the save was made inside the cell, refill it
function F.onLoaded(enabled)
    F.spawned, F.entry, F.suspended = {}, nil, false
    F.purgeLeftovers()
    if F.playerInTestCell() then
        F.onEnter()
        if enabled then F.spawn() end
    end
end

-- save / saved: take the fixtures out for the moment the file is written
function F.onSave()
    if #F.spawned > 0 then
        F.despawn()
        F.purgeLeftovers()
        F.suspended = true
    end
end
function F.onSaved(enabled)
    if F.suspended then
        F.suspended = false
        if enabled and F.playerInTestCell() then F.spawn() end
    end
end

------------------------------------------------------------------------ teleport there and back
local function vec(v) return { v.x, v.y, v.z } end

function F.goTo(config, save)
    if not F.available() then
        say("The smoke test cell is not available: enable %s", F.ESP)
        return false
    end
    if F.playerInTestCell() then say("You are already in the smoke test cell"); return true end
    local pcell = tes3.getPlayerCell and tes3.getPlayerCell() or tes3.player.cell
    local o = { cell = pcell and (pcell.editorName or pcell.id), exterior = pcell and not pcell.isInterior or false,
        gridX = pcell and pcell.gridX, gridY = pcell and pcell.gridY, pos = vec(tes3.player.position),
        rot = tes3.player.orientation and tes3.player.orientation.z or 0 }
    F.origin = o
    if config then config.returnTo = o; if save then save() end end
    tes3.positionCell({ reference = tes3.player, cell = F.cell(), position = { 0, 0, 8 }, orientation = { 0, 0, 0 } })
    return true
end

function F.goBack(config)
    local o = F.origin or (config and config.returnTo)
    if not o or not o.pos then
        say("No return point is known; use the console (coc) to leave the smoke test cell")
        return false
    end
    local target
    if o.exterior then target = tes3.getCell({ x = o.gridX, y = o.gridY }) else target = tes3.getCell({ id = o.cell }) end
    if not target then say("Could not find the cell you came from (%s)", tostring(o.cell)); return false end
    tes3.positionCell({ reference = tes3.player, cell = target, position = o.pos, orientation = { 0, 0, o.rot or 0 } })
    return true
end

return F
