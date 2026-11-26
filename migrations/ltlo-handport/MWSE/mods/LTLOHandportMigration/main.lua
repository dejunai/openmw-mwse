-- LTLOHandportMigration: one-way cleanup of the state left in a save by dej's MWSE hand
-- port of Leave The Lights Off (tes3.player.data.leavethelightsoff), so the omwcompat
-- build of the original mod starts from vanilla lights.
--   * unlit copies placed by the hand port are deleted
--   * originals it disabled are re-enabled and handed to omwcompat (onObjectActive)
-- Works cell by cell as cells become active; clears its data once nothing is left.
-- MIT, Copyright (c) 2026 dej (dejunai). Built with Grok Bot.
local KEY = "leavethelightsoff"

local function keyOf(cell, id, pos)
    return string.format("%s|%s|%d,%d,%d", cell.isInterior and cell.id:lower() or "ext", id,
        math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor(pos.z + 0.5))
end

local function state()
    local p = tes3.player
    return p and p.data and p.data[KEY] or nil
end

local function omw()
    local ok, rt = pcall(require, "omwcompat")
    return ok and rt or nil
end

local function migrateRef(s, ref)
    if ref.deleted or not ref.object or ref.object.objectType ~= tes3.objectType.light then return false end
    local id = ref.object.id:lower()
    if s.reverse and s.reverse[id] then
        ref:disable()
        ref:delete()
        return true
    end
    if s.hidden and ref.disabled and ref.cell then
        local k = keyOf(ref.cell, id, ref.position)
        if s.hidden[k] then
            s.hidden[k] = nil
            ref:enable()
            local rt = omw()
            if rt and rt.queueActive then rt.queueActive(ref) end
            return true
        end
    end
    return false
end

local function finishIfDone(s)
    if s and (not s.hidden or next(s.hidden) == nil) then
        tes3.player.data[KEY] = nil
        mwse.log("[LTLOHandportMigration] hand-port state fully released")
    end
end

local function sweep()
    local s = state()
    if not s then return end
    local n = 0
    for _, cell in ipairs(tes3.getActiveCells()) do
        for ref in cell:iterateReferences(tes3.objectType.light) do
            if migrateRef(s, ref) then n = n + 1 end
        end
    end
    if n > 0 then mwse.log("[LTLOHandportMigration] migrated %d reference(s)", n) end
    finishIfDone(s)
end

-- before omwcompat (priority -100) re-instantiates scripts on load
event.register(tes3.event.loaded, sweep, { priority = 50 })
event.register(tes3.event.cellChanged, sweep)
event.register(tes3.event.referenceActivated, function(e)
    local s = state()
    if s and migrateRef(s, e.reference) then finishIfDone(s) end
end, { priority = 50 })
