-- fixture: local (NPC) script
local self = require('openmw.self')
local storage = require('openmw.storage')

local function onUpdate(dt)
    local p, c = self.position, self.cell
    local name = c.name
    local yaw = self.rotation:getYaw()
    local id = self.cell.id:lower()
    local odd = self.position.nonsense
    local dead = self.type.isDead(self)
    local life = storage.LIFE_TIME.Temporary
    if self.cell:hasTag('NoSleep') then return end
    return p, name, yaw, id, odd, dead, life
end

return { engineHandlers = { onUpdate = onUpdate } }
