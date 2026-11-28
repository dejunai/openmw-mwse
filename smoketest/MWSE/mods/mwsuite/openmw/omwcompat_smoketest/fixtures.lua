-- omwcompat_smoketest fixtures: the DEV-ONLY test cell "OMWC Smoke Test" (OMWC_SmokeTest_DEV.esp).
-- The plugin holds only the cell, a floor, six activators (levers and an exit) and the base records.
-- This module fills the cell with test fixtures while the smoke test mod is enabled, and removes them
-- again when you leave, when a save is written, and on load, so no spawned reference stays in a save
-- (that includes copies converted mods make in the cell).
-- It never touches anything outside that cell. What it does change on purpose: the game hour
-- (forward only: a rewound clock would confuse the converted mods' timers) and the weather,
-- which is put back to what it was when you entered.
-- 0.1.2: the fixtures heal themselves. Converted mods delete, tombstone and replace references in this cell
-- (LTLO, No Fires in Bad Weather), and a save can lose its 'saved' event, so a census runs on every weather
-- change and every 1.5 s of unpaused play in the cell; when a fixture has no live reference left the cell is
-- refilled (at most 3 times a minute). Everything is logged to the omwcompat library log, never MWSE.log.
-- Written for omwcompat by dej (dejunai). MIT.
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
    -- Thieves Pickpocket and Mage Robes: NPCs (dressed in the plugin: common shirt, pants, shoes; the mage a robe)
    { id = "omwc_smoke_npc_thief", x = -200, y = -250, z = 0, rot = 0, tag = "npc" },
    { id = "omwc_smoke_npc_mage", x = 200, y = -250, z = 0, rot = 0, tag = "npc" },
    -- Wildlife Attacks NPCs Too: two weak vanilla creatures the mod lists (rat, kwama forager), one next to each NPC.
    -- Crabs and ducks are not on its list and never fight in vanilla, so they test nothing. These two are armed on
    -- arrival (fight 100, so the mod's reach of (fight - 80) * 200 = 4000 units covers the cell) whatever a
    -- passive-wildlife mod in the load order did to the vanilla records. Both hit for a few points at most.
    { id = "rat", x = -120, y = -250, z = 0, rot = 1.57, tag = "wildlife" },
    { id = "kwama forager", x = 280, y = -250, z = 0, rot = 4.71, tag = "wildlife" },
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
F.WILDLIFE_FIGHT = 100
F.CHECK_EVERY = 1.5   -- seconds of unpaused play between censuses while the player is in the cell
F.MAX_HEALS = 3       -- per HEAL_WINDOW seconds; then it stops and says so (a loop would hide the real problem)
F.HEAL_WINDOW = 60
F.REPORT_AFTER = 4    -- seconds after a refill: one report with each fixture's state (and the creatures' fight value)

local clock, sinceCheck, suspendedFor, heals, gaveUp, reportAt = 0, 0, 0, {}, false, nil
local tags = setmetatable({}, { __mode = "k" })   -- reference -> fixture tag

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

------------------------------------------------------------------------ library log
-- omwcompat's library log only (Data Files/MWSE/logs/omwcompat.log); MWSE.log gets nothing from here.
local function note(fmt, ...)
    local text = "[smoketest cell] " .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt)
    local ok, omwc = pcall(function() return package.loaded["omwcompat"] or require("omwcompat") end)
    if ok and type(omwc) == "table" and omwc.note then pcall(omwc.note, "%s", text) end
end
F.note = note

------------------------------------------------------------------------ spawn / despawn
-- 0.1.1 playtest: after a conversion had deleted a fixture, MWSE threw
-- "sol: received nil for 'self'" on any field or method of that userdata
-- (F.despawn line 78: `if not ref.deleted`). The count ran outside the pcall
-- in remove(), so despawn aborted, F.spawned was never cleared, and every later
-- spawn / respawn / save / leave failed the same way. Never touch a reference
-- except through live() / remove().
local function live(ref)
    if ref == nil then return false end
    local ok, deleted = pcall(function() return ref.deleted end)
    return ok and not deleted
end
F.live = live

local function remove(ref)
    if not live(ref) then return end
    pcall(function() ref:disable() end)
    pcall(function() ref:delete() end)
end

function F.despawn()
    local leftover = F.spawned
    F.spawned = {}   -- clear first so a later failure cannot leave a stale list
    local n = 0
    for _, ref in ipairs(leftover) do
        if live(ref) then n = n + 1 end
        remove(ref)
    end
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
        local ok, skip = pcall(function() return ref.sourceMod ~= nil or ref.deleted end)
        if ok and not skip then kill[#kill + 1] = ref end
    end
    for _, ref in ipairs(kill) do remove(ref) end
    return #kill
end

function F.spawn(reason)
    local cell = F.cell()
    if not cell then return 0, { "test cell not found" } end
    local before = F.despawn()
    local purged = F.purgeLeftovers()
    local errors = {}
    for _, f in ipairs(F.FIXTURES) do
        local ok, ref = pcall(tes3.createReference, { object = f.id, cell = cell, position = { f.x, f.y, f.z },
            orientation = { 0, 0, f.rot or 0 } })
        if ok and ref then
            F.spawned[#F.spawned + 1] = ref
            tags[ref] = f.tag
        else errors[#errors + 1] = f.id .. ": " .. tostring(ref) end
    end
    reportAt = clock + F.REPORT_AFTER
    note("spawn (%s): %d created, %d failed; removed %d of ours and %d leftovers first", reason or "?", #F.spawned, #errors, before, purged)
    for _, e in ipairs(errors) do note("spawn failed: %s", e) end
    return #F.spawned, errors
end

------------------------------------------------------------------------ census, heal, report
-- A fixture is "present" while a live reference without a content file (ours, not the plugin's) exists for its id,
-- enabled or not: a conversion that disabled or tombstoned it (No Fires in Bad Weather in rain) is doing its job.
-- It is "missing" when nothing is left: deleted, or never created. Records are looked up lower case.
function F.census()
    local c = { total = #F.FIXTURES, present = 0, enabled = 0, hidden = 0, missing = {}, others = 0 }
    local cell = F.cell()
    if not cell then c.missing = nil; return c end
    local byId, created = {}, 0
    for ref in cell:iterateReferences() do
        local ok, keep = pcall(function() return ref.sourceMod == nil and not ref.deleted end)
        if ok and keep then
            created = created + 1
            local id = tostring(ref.object and ref.object.id or "?"):lower()
            local e = byId[id]
            if not e then e = { n = 0, on = 0 }; byId[id] = e end
            e.n = e.n + 1
            if not ref.disabled then e.on = e.on + 1 end
        end
    end
    local counted = 0
    for _, f in ipairs(F.FIXTURES) do
        local e = byId[f.id:lower()]
        if not e then c.missing[#c.missing + 1] = f.id
        else
            c.present = c.present + 1
            counted = counted + e.n
            if e.on > 0 then c.enabled = c.enabled + 1 else c.hidden = c.hidden + 1 end
        end
    end
    c.others = created - counted   -- conversion copies (LTLO's off lights and so on)
    return c
end

local function censusLine(c)
    return string.format("%d/%d fixtures present (%d enabled, %d disabled by a conversion), %d conversion copies%s", c.present, c.total,
        c.enabled, c.hidden, c.others, #(c.missing or {}) > 0 and (", MISSING: " .. table.concat(c.missing, ", ")) or "")
end
F.censusLine = censusLine

local function weatherName()
    local w = tes3.worldController and tes3.worldController.weatherController
    local cur = w and w.currentWeather
    return cur and (F.WEATHER[cur.index] or cur.name) or "?"
end

-- refill the cell; rate limited. Returns true when it refilled.
function F.heal(reason)
    local now = clock
    local recent = {}
    for _, t in ipairs(heals) do if now - t < F.HEAL_WINDOW then recent[#recent + 1] = t end end
    heals = recent
    if #heals >= F.MAX_HEALS then
        if not gaveUp then
            gaveUp = true
            note("heal skipped (%s): already refilled %d times in %d s; something keeps removing the fixtures. Use the respawn lever to retry",
                reason, #heals, F.HEAL_WINDOW)
        end
        return false
    end
    heals[#heals + 1] = now
    local n, errs = F.spawn("heal: " .. reason)
    say("Smoke test cell: fixtures were missing, refilled (%d%s)", n, #errs > 0 and (", " .. #errs .. " failed (see log)") or "")
    return true
end

-- one report with the state of each fixture and, for creatures, the fight value the mod will read
function F.report()
    local cell = F.cell()
    if not cell then return end
    note("report: %s; weather %s, hour %.1f", censusLine(F.census()), weatherName(), tes3.worldController and tes3.worldController.hour.value or -1)
    for _, ref in ipairs(F.spawned) do
        if live(ref) then
            local okm, mob = pcall(function() return ref.mobile end)
            mob = okm and mob or nil
            local extra = ""
            if mob and tags[ref] == "wildlife" then
                extra = string.format(", fight %s, health %s", tostring(mob.fight), tostring(mob.health and mob.health.current))
            end
            note("  %s: %s%s", tostring(ref.object and ref.object.id), ref.disabled and "disabled" or "enabled", extra)
        end
    end
end

-- weather events and the periodic check call this; `why` is only for the log
function F.check(why, enabled)
    if not enabled or F.suspended or not F.playerInTestCell() then return end
    local c = F.census()
    if c.missing == nil then return end
    if #c.missing > 0 then
        note("check (%s, weather %s): %s", why, weatherName(), censusLine(c))
        F.heal(why)
    elseif why ~= "periodic" then
        note("check (%s, weather %s): %s", why, weatherName(), censusLine(c))
    end
end

-- enterFrame: delta is seconds; only while unpaused
function F.tick(e, enabled)
    if not enabled or (e and e.menuMode) then return end
    local dt = e and e.delta or 0
    clock = clock + dt
    if not F.playerInTestCell() then return end
    if reportAt and clock >= reportAt then reportAt = nil; F.report() end
    sinceCheck = sinceCheck + dt
    if sinceCheck < F.CHECK_EVERY then return end
    sinceCheck = 0
    if F.suspended then
        suspendedFor = suspendedFor + F.CHECK_EVERY
        if suspendedFor >= 3 then
            -- 'save' took the fixtures out and 'saved' never came (a failed or blocked save, another mod's handler)
            note("the 'saved' event did not arrive within %d s of 'save'; putting the fixtures back", suspendedFor)
            F.suspended, suspendedFor = false, 0
            F.spawn("saved event missing")
        end
        return
    end
    F.check("periodic", enabled)
end

-- weather events: log the state, check right away
function F.onWeather(name, enabled)
    if not enabled or not F.playerInTestCell() then return end
    F.check(name, enabled)
    sinceCheck = F.CHECK_EVERY / 2   -- and once more shortly after, when the converted mods have reacted
end

-- mobileActivated: arm the wildlife fixtures so Wildlife Attacks NPCs Too has something that fights
function F.onMobileActivated(e)
    local ref = e and e.reference
    if ref and tags[ref] == "wildlife" and e.mobile then
        pcall(function() e.mobile.fight = F.WILDLIFE_FIGHT end)
    end
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
        heals, gaveUp = {}, false
        local n, errs = F.spawn("respawn lever")
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
    sinceCheck, suspendedFor, heals, gaveUp = 0, 0, {}, false
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
        if enabled and #F.spawned == 0 then F.spawn("entered") end
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
        if enabled then F.spawn("loaded in the cell") end
    end
end

-- save / saved: take the fixtures out for the moment the file is written
function F.onSave()
    if #F.spawned > 0 then
        F.despawn()
        F.purgeLeftovers()
        F.suspended, suspendedFor = true, 0
        note("save: fixtures taken out while the file is written")
    end
end
function F.onSaved(enabled)
    if F.suspended then
        F.suspended = false
        if enabled and F.playerInTestCell() then F.spawn("saved") end
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
