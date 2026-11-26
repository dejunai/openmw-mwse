---
-- Test object types.
-- @context global|local
-- @module types

--- Test actor functions.
-- @field [parent=#types] #Actor Actor

---
-- @type Actor

---
-- Test death check.
-- @function [parent=#Actor] isDead
-- @param openmw.core#GameObject actor
-- @return #boolean

---
-- Test inventory.
-- @function [parent=#Actor] inventory
-- @param openmw.core#GameObject actor
-- @return openmw.core#Inventory

---
-- Test brand-new function nobody classified.
-- @function [parent=#Actor] fly
-- @param openmw.core#GameObject actor

--- Test NPC functions.
-- @field [parent=#types] #NPC NPC

---
-- @type NPC
-- @extends #Actor

---
-- Points back at the actor table.
-- @field [parent=#NPC] #Actor baseType

return nil
