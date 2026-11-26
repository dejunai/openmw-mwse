-- omw2mwse test fixture (written for the tests, not third-party code), modeled on a common
-- OpenMW global-script pattern (No Fires in Bad Weather is one real example):
--   * onObjectActive appends the object to a list with no duplicate check, so the list
--     grows every time the cell is loaded again (rule active-collect-dedupe);
--   * onUpdate walks that list one element per frame with a next() cursor kept between
--     frames and table.remove()s invalid objects at the cursor (rule mutate-during-iteration).
-- MIT, Copyright (c) 2026 dej (dejunai).
local types = require('openmw.types')

local tracked = {}
local cursor = nil

local function onUpdate(dt)
    if dt == 0 then return end
    local obj
    cursor, obj = next(tracked, cursor)
    local seen = '-'
    if obj then
        if not obj:isValid() then
            table.remove(tracked, cursor)
        else
            seen = obj.recordId
        end
    end
    print('REC tick', #tracked, seen)
end

local function onObjectActive(object)
    if types.Light.objectIsInstance(object) then
        table.insert(tracked, object)
    end
end

return {
    engineHandlers = { onUpdate = onUpdate, onObjectActive = onObjectActive },
}
