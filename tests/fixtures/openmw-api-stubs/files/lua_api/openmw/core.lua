---
-- Test core module.
-- @context global|local|player
-- @module core

---
-- Test revision number.
-- @field [parent=#core] #number API_REVISION

---
-- Sends a test event.
-- @function [parent=#core] sendGlobalEvent
-- @param #string name

---
-- Test sound helpers.
-- @field [parent=#core] #Sound sound

---
-- @type Sound

---
-- Plays a test sound at a place.
-- @function [parent=#Sound] playSound3d
-- @param #string id

---
-- A test game object.
-- @type GameObject
-- @field #string recordId Test record id.
-- @field openmw.util#Vector3 position Test position.
-- @field #Cell cell Test cell.

---
-- Test validity check.
-- @function [parent=#GameObject] isValid
-- @param self
-- @return #boolean

---
-- Moves the test object. Can be called only from a global script.
-- @function [parent=#GameObject] teleport
-- @param self
-- @param #Cell cell

---
-- A test cell.
-- @type Cell
-- @field #string name Test name.

---
-- Lists test objects; Only available from global scripts.
-- @function [parent=#Cell] getAll
-- @param self

---
-- Test tag check.
-- @function [parent=#Cell] hasTag
-- @param self
-- @param #string tag

---
-- @type Inventory

---
-- Counts test items.
-- @function [parent=#Inventory] countOf
-- @param self
-- @param #string recordId

---
-- Lists test items.
-- @function [parent=#Inventory] getAll
-- @param self

return nil
