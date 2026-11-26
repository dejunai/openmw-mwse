-- fixture: global script
local world = require('openmw.world')
local types = require('openmw.types')
local storage = require('openmw.storage')
local ok, I = pcall(require, 'openmw.interfaces')
local hasAnim, anim = pcall(require, 'openmw.animation')
local okU, util = pcall(function() return require('openmw.util') end)

local section = storage.globalSection('FormsTest')
local layout = { type = types.NPC, name = 'x', }

local function tidy(obj)
    local inv = types.Actor.inventory(obj)
    local n = inv:countOf('gold_001')
    for _, item in ipairs(types.Actor.inventory(obj):getAll()) do
        item:remove()
    end
    local cell = world.getCellByName('Balmora')
    local here = obj.cell
    for _, o in ipairs(here:getAll()) do
        local z, y, x = o.rotation:getAnglesZYX()
    end
    local t = types[layout.kind]
    local draft = t.createRecordDraft({ name = 'test' })
    local s = section:get('key')
    local low = obj.recordId:lower()
    if ok and I.Activation then
        I.Activation.addHandlerForType(types.NPC, function() return true end)
    end
    if hasAnim then anim.addGlow(obj, {}) end
    return util.vector3(0, 0, n), cell, draft, s, low, z
end

return { engineHandlers = { onUpdate = function() end }, eventHandlers = { FormsTidy = tidy } }
