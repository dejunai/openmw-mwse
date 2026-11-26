-- omwcompat.objects: GameObject / Cell / Record wrappers and openmw.types emulation.
-- Implements the lifecycle rules from DESIGN.md section 5.3:
--   R1 remove()   : content-file refs are disabled + tombstoned (ref.data flag);
--                   runtime-created refs are disabled + deleted.
--   R2 teleport() : a new object of record X placed on a tombstoned ref of X
--                   (same cell, within EPS units) resurrects that ref instead.
--   R3 moveInto() : during an activation, moving X into the activator's inventory
--                   when a tombstoned X sits under the activated object becomes a
--                   vanilla activation of the original (ownership/crime apply).
--   R4 models     : record models longer than 31 chars are mapped through the
--                   packager's mesh alias table (see runtime.lua createRecord).
-- MIT, Copyright (c) 2026 dej (dejunai).
local util = require("omwcompat.util")
local M = {}

local EPS = 2.0
M.EPS = EPS
local rt -- runtime back-reference, set by M.init
local wrappers = {}      -- id -> wrapper (session cache)
local sessionCounter = 0

function M.init(runtime) rt = runtime end
function M.reset() wrappers = {} end

local OBJ = { __omwtype = "GameObject" }

-- OpenMW record ids are lowercase, except runtime-generated ones ("Generated:0x..").
local function normId(id)
    if not id then return nil end
    local l = id:lower()
    if l:sub(1, 10) == "generated:" then return "Generated:" .. l:sub(11) end
    return l
end
M.normId = normId
local function lowerId(o) return o and o.id and normId(o.id) or nil end
M.lowerId = lowerId

-- Content-file refs are identified by plugin + form id and their tombstones live in
-- the runtime save payload (state.tombs), so omwcompat never has to touch ref.data
-- on them. For item references ref.data IS the itemData table; creating itemData
-- on every lantern would stop picked-up items from stacking.
local function contentId(ref)
    local sm, fid = ref.sourceMod, ref.sourceFormId
    if sm and fid and fid ~= 0 then return "c:" .. tostring(sm):lower() .. ":" .. tostring(fid) end
    return nil
end
M.contentId = contentId

local ITEM_TYPES
local function isItemRef(ref)
    if not ITEM_TYPES then
        local o = tes3.objectType
        ITEM_TYPES = {}
        for _, k in ipairs({ "light", "miscItem", "weapon", "armor", "clothing", "book", "alchemy", "ingredient",
            "apparatus", "lockpick", "probe", "repairItem", "ammunition" }) do
            if o[k] then ITEM_TYPES[o[k]] = true end
        end
    end
    return ref.object and ITEM_TYPES[ref.object.objectType] == true
end
-- true if reading ref.data will not create anything new
local function hasLuaData(ref)
    if not ref.supportsLuaData then return false end
    if isItemRef(ref) then return ref.itemData ~= nil end
    return true
end
M.hasLuaData = hasLuaData

local function isTomb(ref)
    local cid = contentId(ref)
    if cid then return rt._state.tombs[cid] == true end
    if not ref.disabled or not hasLuaData(ref) then return false end
    local d = ref.data
    return d and d.omwcompat_removed == true
end
M.isTomb = isTomb

local function setTomb(ref, on)
    local cid = contentId(ref)
    if cid then
        rt._state.tombs[cid] = on and true or nil
        ref.modified = true
        return
    end
    if not ref.supportsLuaData then return end
    if not on and not hasLuaData(ref) then return end
    ref.data.omwcompat_removed = on and true or nil
    ref.modified = true
end
M.setTomb = setTomb

local function newPersistentId()
    sessionCounter = sessionCounter + 1
    return string.format("r:%x:%d", os.time(), sessionCounter)
end

-- Stable id for a reference.
--   content-file refs : "c:<plugin>:<formId>" (stable across saves, no ref data touched)
--   other refs        : a persistent id in ref.data.omwcompat_id when one exists or when
--                       persist == true (we created the ref, or a script saved it);
--                       otherwise a session-only id (weak table keyed by the ref).
local sessionIds = setmetatable({}, { __mode = "k" })
function M.refId(ref, persist)
    if tes3.player and ref == tes3.player then return "player" end   -- stable across saves
    local cid = contentId(ref)
    if cid then return cid end
    if hasLuaData(ref) then
        local d = ref.data
        if d and d.omwcompat_id then return d.omwcompat_id end
    end
    local sid = sessionIds[ref]
    if persist and ref.supportsLuaData then
        local id = sid or newPersistentId()
        ref.data.omwcompat_id = id
        ref.modified = true
        sessionIds[ref] = id
        return id
    end
    if not sid then
        sessionCounter = sessionCounter + 1
        sid = "s:" .. sessionCounter
        sessionIds[ref] = sid
    end
    return sid
end

local function handleOf(ref)
    if tes3.makeSafeObjectHandle then return tes3.makeSafeObjectHandle(ref) end
    return { valid = function() return not ref.deleted end, getObject = function() return ref end }
end

local function refOf(w)
    local h = rawget(w, "_h")
    if h then
        if h:valid() then return h:getObject() end
        rawset(w, "_h", nil)
    end
    local pending = rawget(w, "_pendingId")
    if pending then
        local ref = M.findRefById(pending)
        if ref then rawset(w, "_h", handleOf(ref)); return ref end
    end
    return nil
end
M.refOf = refOf

function M.findRefById(id)
    for _, cell in ipairs(tes3.getActiveCells() or {}) do
        for ref in cell:iterateReferences() do
            local ok, rid = pcall(M.refId, ref, false)
            if ok and rid == id then return ref end
        end
    end
    return nil
end

function M.wrap(ref)
    if ref == nil then return nil end
    local id = M.refId(ref, false)
    local w = wrappers[id]
    if w then
        if not rawget(w, "_h") or not rawget(w, "_h"):valid() then rawset(w, "_h", handleOf(ref)) end
        return w
    end
    w = setmetatable({ _id = id, _h = handleOf(ref) }, OBJ)
    wrappers[id] = w
    return w
end

function M.fromId(id)
    if id == "player" and tes3.player then return M.wrap(tes3.player) end
    local w = wrappers[id]
    if w then return w end
    -- an inventory item saved by a script: "inv:<owner id>:<record id>" (owner ids can contain ':')
    -- (a saved split view comes back as the whole stack)
    local ownerId, recordId = tostring(id):gsub(":split$", ""):match("^inv:(.*):([^:]+)$")
    if ownerId and recordId then return M.invItem(M.fromId(ownerId), recordId) end
    w = setmetatable({ _id = id, _pendingId = id }, OBJ)
    wrappers[id] = w
    return w
end

local function limbo(recordId, count)
    return setmetatable({ _limbo = true, _recordId = recordId, _count = count or 1 }, OBJ)
end
M.limbo = limbo

---------------------------------------------------------------- types
local TYPE_BY_OT = {}
local types = {}
M.types = types

-- true if type X is T or derives from it through baseType (Player -> NPC -> Actor)
local function isA(X, T)
    local n = 0
    while X and n < 8 do
        if X == T then return true end
        X = rawget(X, "baseType"); n = n + 1
    end
    return false
end
M.isA = isA

local function objType(name, ot, isItem)
    local T = { _name = name, _ot = ot, _isItem = isItem }
    T.objectIsInstance = function(o) return getmetatable(o) == OBJ and isA(o.type, T) end
    T.record = function(x)
        if type(x) == "table" and getmetatable(x) == OBJ then x = x.recordId end
        local o = x and tes3.getObject(x)
        if not o or (ot and o.objectType ~= ot) then return nil end
        return M.recordOf(o)
    end
    T.records = setmetatable({}, {
        __index = function(_, i)
            if type(i) == "string" then return T.record(i) end   -- records['id'] (OpenMW 0.49+)
            local list = M.recordList(T)
            return list[i]
        end,
        __len = function() return #M.recordList(T) end,
        __pairs = function() return ipairs(M.recordList(T)) end,
        __ipairs = function() return ipairs(M.recordList(T)) end,
    })
    T.createRecordDraft = function(t)
        local d = { _draftType = T }
        for k, v in pairs(t) do d[k] = v end
        return d
    end
    types[name] = T
    if ot then TYPE_BY_OT[ot] = T end
    return T
end

function M.initTypes()
    local o = tes3.objectType
    objType("Light", o.light, true)
    objType("NPC", o.npc)
    objType("Creature", o.creature)
    objType("Container", o.container)
    objType("Door", o.door)
    objType("Static", o.static)
    objType("Activator", o.activator)
    objType("Miscellaneous", o.miscItem, true)
    objType("Weapon", o.weapon, true)
    objType("Armor", o.armor, true)
    objType("Clothing", o.clothing, true)
    objType("Book", o.book, true)
    objType("Potion", o.alchemy, true)
    objType("Ingredient", o.ingredient, true)
    objType("Apparatus", o.apparatus, true)
    objType("Lockpick", o.lockpick, true)
    objType("Probe", o.probe, true)
    objType("Repair", o.repairItem, true)
    types.Player = setmetatable({ _name = "Player", baseType = types.NPC }, { __index = types.NPC })
    types.Player.objectIsInstance = function(x) return getmetatable(x) == OBJ and x.type == types.Player end
    local function inventory(actor) return M.inventory(actor) end
    types.NPC.inventory, types.Creature.inventory, types.Container.inventory = inventory, inventory, inventory
    types.Container.content = inventory
    types.Actor = { _name = "Actor",
        objectIsInstance = function(x) return getmetatable(x) == OBJ and isA(x.type, types.Actor) end,
        inventory = inventory }
    types.Item = { _name = "Item", objectIsInstance = function(x) return getmetatable(x) == OBJ and x.type and x.type._isItem == true end }
    types.Lockable = { _name = "Lockable", objectIsInstance = function(x) return getmetatable(x) == OBJ and isA(x.type, types.Lockable) end }
    -- OpenMW 0.51 type hierarchy (baseType): actors -> Actor, items -> Item, containers/doors -> Lockable
    types.NPC.baseType, types.Creature.baseType = types.Actor, types.Actor
    types.Container.baseType, types.Door.baseType = types.Lockable, types.Lockable
    for _, T in pairs(types) do
        if type(T) == "table" and T._isItem then T.baseType = types.Item end
    end
    M.initLockable(types.Lockable)
    -- record type enums; the values are the ESM values MWSE reports in record.type / record.slot
    types.Weapon.TYPE = { ShortBladeOneHand = 0, LongBladeOneHand = 1, LongBladeTwoHand = 2, BluntOneHand = 3,
        BluntTwoClose = 4, BluntTwoWide = 5, SpearTwoWide = 6, AxeOneHand = 7, AxeTwoHand = 8, MarksmanBow = 9,
        MarksmanCrossbow = 10, MarksmanThrown = 11, Arrow = 12, Bolt = 13 }
    types.Armor.TYPE = { Helmet = 0, Cuirass = 1, LPauldron = 2, RPauldron = 3, Greaves = 4, Boots = 5, LGauntlet = 6,
        RGauntlet = 7, Shield = 8, LBracer = 9, RBracer = 10 }
    types.Clothing.TYPE = { Pants = 0, Shoes = 1, Shirt = 2, Belt = 3, Robe = 4, RGlove = 5, LGlove = 6, Skirt = 7,
        Ring = 8, Amulet = 9 }
end

---------------------------------------------------------------- Lockable (containers, doors)
-- types.Lockable.isLocked / getLockLevel / lock / unlock / getKeyRecord -> tes3.getLocked,
-- tes3.getLockLevel, tes3.lock, tes3.unlock and the reference's lockNode.key.
function M.initLockable(L)
    local function lref(o, fn)
        local ref = refOf(o)
        if not ref then error("types.Lockable." .. fn .. ": invalid object", 3) end
        return ref
    end
    L.isLocked = function(o) return tes3.getLocked({ reference = lref(o, "isLocked") }) == true end
    L.getLockLevel = function(o)
        local ref = lref(o, "getLockLevel")
        local ok, v = pcall(tes3.getLockLevel, { reference = ref })
        if ok and v then return v end
        local ok2, n = pcall(function() return ref.lockNode and ref.lockNode.level end)
        return ok2 and n or 0
    end
    L.lock = function(o, level) tes3.lock({ reference = lref(o, "lock"), level = level }) end
    L.unlock = function(o) tes3.unlock({ reference = lref(o, "unlock") }) end
    L.getKeyRecord = function(o)
        local ref = lref(o, "getKeyRecord")
        local ok, k = pcall(function() return ref.lockNode and ref.lockNode.key end)
        return ok and k and M.recordOf(k) or nil
    end
end

local recordCache = {}
local listCache = {}
function M.resetRecordCaches() recordCache, listCache = {}, {} end
function M.recordList(T)
    local l = listCache[T]
    if l then return l end
    l = {}
    for obj in tes3.iterateObjects(T._ot) do l[#l + 1] = M.recordOf(obj) end
    listCache[T] = l
    return l
end
function M.invalidateRecordList(T) listCache[T] = nil end

---------------------------------------------------------------- records
local function modelPath(mesh)
    if not mesh or mesh == "" then return "" end
    return "meshes/" .. mesh:lower():gsub("\\", "/")
end
M.modelPath = modelPath

local REC = { __omwtype = "Record" }
local recFields = {
    id = function(o) return lowerId(o) end,
    name = function(o) return o.name end,
    model = function(o)
        local over = rt and rt.generatedModel(lowerId(o))
        if over then return over end
        return modelPath(o.mesh)
    end,
    icon = function(o) return o.icon and ("icons/" .. o.icon:lower():gsub("\\", "/")) or "" end,
    mwscript = function(o) return o.script and lowerId(o.script) or nil end,
    isOffByDefault = function(o) return o.isOffByDefault == true end,
    radius = function(o) return o.radius end,
    color = function(o)
        local c = o.color
        if not c then return nil end
        return util.color.rgb((c[1] or c.r or 0) / 255, (c[2] or c.g or 0) / 255, (c[3] or c.b or 0) / 255)
    end,
    duration = function(o) return o.time end,
    value = function(o) return o.value end,
    weight = function(o) return o.weight end,
    isCarriable = function(o) return o.canCarry == true or o.isCarriable == true end,
    isDynamic = function(o) return o.isDynamic == true end,
    isFire = function(o) return o.isFire == true end,
    isFlicker = function(o) return o.flickers == true end,
    isFlickerSlow = function(o) return o.flickersSlowly == true end,
    isNegative = function(o) return o.isNegative == true end,
    isPulse = function(o) return o.pulses == true end,
    isPulseSlow = function(o) return o.pulsesSlowly == true end,
    sound = function(o) return o.sound and lowerId(o.sound) or nil end,
    -- Weapon.TYPE / Armor.TYPE / Clothing.TYPE values (ESM numbers, as MWSE reports them)
    type = function(o)
        local ot = tes3.objectType
        if o.objectType == ot.weapon or o.objectType == ot.ammunition then return o.type end
        if o.objectType == ot.armor or o.objectType == ot.clothing then return o.slot end
        return nil
    end,
    enchant = function(o) return o.enchantment and lowerId(o.enchantment) or nil end,
}
REC.__index = function(r, k)
    local f = recFields[k]
    if f then
        local ok, v = pcall(f, rawget(r, "_o"))
        if ok then return v end
        return nil
    end
    return nil
end
REC.__newindex = function() error("records are read-only", 2) end
REC.__tostring = function(r) return "Record(" .. tostring(r.id) .. ")" end
function M.recordOf(o)
    local id = lowerId(o)
    local r = recordCache[id]
    if r and rawget(r, "_o") == o then return r end
    r = setmetatable({ _o = o }, REC)
    recordCache[id] = r
    return r
end
function M.tesObjectOfRecord(r) return rawget(r, "_o") end

---------------------------------------------------------------- cells
local CELL = { __omwtype = "Cell" }
local cellCache = {}
function M.resetCells() cellCache = {} end
CELL.__index = function(c, k)
    local cell = rawget(c, "_c")
    if k == "isExterior" then return not cell.isInterior
    elseif k == "isQuasiExterior" then return cell.isInterior and cell.behavesAsExterior == true
    elseif k == "hasSky" then return cell.isOrBehavesAsExterior == true
    elseif k == "name" then return cell.name or ""
    elseif k == "id" then return (cell.id or ""):lower()
    elseif k == "gridX" then return cell.gridX
    elseif k == "gridY" then return cell.gridY
    elseif k == "region" then return cell.region and lowerId(cell.region) or nil
    elseif k == "hasWater" then return cell.hasWater
    elseif k == "worldSpaceId" then return cell.isInterior and (cell.id or ""):lower() or "sys::default"
    elseif k == "isInSameSpace" then return function(_, other) return (not cell.isInterior and other.isExterior) or c == other end
    elseif k == "getAll" then
        return function(_, T)
            local out = {}
            for ref in cell:iterateReferences(T and T._ot or nil) do
                if not ref.deleted and not isTomb(ref) then out[#out + 1] = M.wrap(ref) end
            end
            return out
        end
    elseif k == "_tes3" then return cell
    end
    return nil
end
CELL.__eq = function(a, b) return rawget(a, "_c") == rawget(b, "_c") end
CELL.__tostring = function(c) return "Cell(" .. tostring(rawget(c, "_c").editorName or rawget(c, "_c").id) .. ")" end
function M.cellOf(cell)
    if not cell then return nil end
    local key = cell.isInterior and ("i:" .. (cell.id or "")):lower() or string.format("e:%d,%d", cell.gridX or 0, cell.gridY or 0)
    local c = cellCache[key]
    if c and rawget(c, "_c") == cell then return c end
    c = setmetatable({ _c = cell }, CELL)
    cellCache[key] = c
    return c
end

---------------------------------------------------------------- inventories
local INV = { __omwtype = "Inventory" }
INV.__index = INV
function M.inventory(owner) return setmetatable({ _owner = owner }, INV) end
local function stacks(owner)
    local ref = refOf(owner)
    local inv = ref and ref.object and ref.object.inventory
    if not inv then return {}, ref end
    local out = {}
    for _, st in pairs(inv) do
        if st.object and (st.count or 0) > 0 then out[#out + 1] = st end
    end
    return out, ref
end
function INV:countOf(recordId)
    local n = 0
    for _, st in ipairs(stacks(self._owner)) do
        if lowerId(st.object) == normId(recordId) then n = n + (st.count or 0) end
    end
    return n
end
function INV:isResolved() return true end
-- Items in an inventory are GameObjects in OpenMW. MWSE keeps item stacks, not references, so
-- omwcompat gives one GameObject per record in the inventory (M.invItem): items of the same record
-- with different conditions, charges or souls are one object here.
function INV:getAll(T)
    local out = {}
    for _, st in ipairs(stacks(self._owner)) do
        local IT = TYPE_BY_OT[st.object.objectType]
        if T == nil or (IT and (IT == T or (T == types.Item and IT._isItem))) then
            out[#out + 1] = M.invItem(self._owner, lowerId(st.object))
        end
    end
    return out
end
function INV:find(recordId)
    if self:countOf(recordId) > 0 then return M.invItem(self._owner, normId(recordId)) end
    return nil
end
function INV:findAll(recordId)
    local it = self:find(recordId)
    return it and { it } or {}
end
function INV:resolve() error("omwcompat: Inventory:resolve is not supported (MWSE resolves levelled items itself)", 2) end

---------------------------------------------------------------- GameObject
local function vec3(v) return util.vector3(v.x, v.y, v.z) end
local function rotOf(o) return util._newTransform(o.x, o.y, o.z) end

local function countOf(w, ref)
    if rawget(w, "_limbo") then return rawget(w, "_gone") and 0 or rawget(w, "_count") end
    if not ref or ref.deleted or isTomb(ref) then return 0 end
    local ok, n = pcall(function() return ref.stackSize end)
    if ok and type(n) == "number" and n > 0 then return n end
    return 1
end

local getters = {
    id = function(w, ref)
        if rawget(w, "_limbo") then return "limbo:" .. tostring(w) end
        return rawget(w, "_id")
    end,
    recordId = function(w, ref)
        if rawget(w, "_limbo") then return normId(rawget(w, "_recordId")) end
        return ref and lowerId(ref.object) or nil
    end,
    type = function(w, ref)
        if ref and tes3.player and ref == tes3.player then return types.Player end
        local o = ref and ref.object or (rawget(w, "_limbo") and tes3.getObject(rawget(w, "_recordId")))
        return o and TYPE_BY_OT[o.objectType] or nil
    end,
    cell = function(w, ref) return ref and M.cellOf(ref.cell) or nil end,
    position = function(w, ref) return ref and vec3(ref.position) or nil end,
    rotation = function(w, ref) return ref and rotOf(ref.orientation) or util.transform.identity end,
    startingPosition = function(w, ref) return ref and vec3(ref.startingPosition or ref.position) or nil end,
    startingRotation = function(w, ref) return ref and rotOf(ref.startingOrientation or ref.orientation) or util.transform.identity end,
    scale = function(w, ref) return ref and ref.scale or 1 end,
    count = function(w, ref) return countOf(w, ref) end,
    enabled = function(w, ref) return ref and not ref.disabled or false end,
    contentFile = function(w, ref) return ref and ref.sourceMod and tostring(ref.sourceMod):lower() or nil end,
    ownerRecordId = function(w, ref)
        local ok, v = pcall(function() return ref.itemData and ref.itemData.owner and lowerId(ref.itemData.owner) end)
        return ok and v or nil
    end,
    parentContainer = function() return nil end,
    owner = function(w, ref) return ref and M.ownerOf(ref) or nil end,
    -- MWSE does not keep a reference's original cell: exterior refs -> the cell containing
    -- startingPosition, interior refs -> the current cell
    startingCell = function(w, ref)
        if not ref or not ref.cell then return nil end
        if ref.cell.isInterior then return M.cellOf(ref.cell) end
        local sp = ref.startingPosition or ref.position
        local ok, c = pcall(tes3.getCell, { position = sp })
        return M.cellOf(ok and c or ref.cell)
    end,
    globalVariable = function() error("omwcompat: GameObject.globalVariable is not supported (MWSE exposes no per-reference global)", 3) end,
}

---------------------------------------------------------------- ownership
-- GameObject.owner: { recordId, factionId, factionRank } through tes3.getOwner / tes3.setOwner.
-- factionRank is the rank index stored in the reference (MWSE requiredRank, 0-based as in the ESM).
local function ownerInfo(ref)
    local ok, o, req = pcall(tes3.getOwner, { reference = ref })
    if not ok or not o then return nil, nil end
    return o, req
end
function M.ownerOf(ref)
    return setmetatable({}, {
        __index = function(_, k)
            local o, req = ownerInfo(ref)
            if not o then return nil end
            local isFaction = o.objectType == tes3.objectType.faction
            if k == "recordId" then return (not isFaction) and lowerId(o) or nil
            elseif k == "factionId" then return isFaction and lowerId(o) or nil
            elseif k == "factionRank" then return isFaction and tonumber(req) or nil end
            return nil
        end,
        __newindex = function(_, k, v)
            if k == "recordId" or k == "factionId" then
                if v == nil then tes3.setOwner({ reference = ref, remove = true })
                else tes3.setOwner({ reference = ref, owner = v }) end
            elseif k == "factionRank" then
                local o = ownerInfo(ref)
                if not o or o.objectType ~= tes3.objectType.faction then error("owner.factionRank: the object has no faction owner", 2) end
                tes3.setOwner({ reference = ref, owner = o, requiredRank = v })
            else
                error("owner." .. tostring(k) .. " is not writable", 2)
            end
            ref.modified = true
        end,
    })
end

local methods_ref
---------------------------------------------------------------- inventory items
-- A GameObject for "the items of record R in the inventory of O". Fields: id, recordId,
-- type, count (live), parentContainer; cell/position are nil like OpenMW items in a container.
-- Methods: isValid, remove(n), moveInto(inventory), teleport(cell, pos) (drops it into the
-- world). split, activateBy, setScale and local scripts are not available on them.
local invGetters = {
    id = function(w) return rawget(w, "_id") end,
    recordId = function(w) return rawget(w, "_recordId") end,
    type = function(w) local o = tes3.getObject(rawget(w, "_recordId")); return o and TYPE_BY_OT[o.objectType] or nil end,
    count = function(w)
        local have = M.inventory(rawget(w, "_owner")):countOf(rawget(w, "_recordId"))
        local take = rawget(w, "_take")
        return take and math.min(take, have) or have
    end,
    parentContainer = function(w) return rawget(w, "_owner") end,
    enabled = function() return true end,
    scale = function() return 1 end,
    rotation = function() return util.transform.identity end,
}
local invMethods = {}
function invMethods:isValid()
    local owner = rawget(self, "_owner")
    return owner ~= nil and owner:isValid() and self.count > 0
end
function invMethods:remove(n)
    local ref = refOf(rawget(self, "_owner"))
    if not ref then error("remove: inventory owner is not valid", 2) end
    local have = self.count
    if have <= 0 then return end
    tes3.removeItem({ reference = ref, item = rawget(self, "_recordId"), count = math.min(n or have, have), playSound = false })
end
function invMethods:moveInto(dest)
    if type(dest) ~= "table" or getmetatable(dest) ~= INV then error("moveInto: destination must be an Inventory", 2) end
    local from, to = refOf(rawget(self, "_owner")), refOf(dest._owner)
    if not from or not to then error("moveInto: inventory owner is not valid", 2) end
    local have = self.count
    if have <= 0 then return end
    tes3.transferItem({ from = from, to = to, item = rawget(self, "_recordId"), count = have, playSound = false })
end
function invMethods:teleport(cell, pos, opts)
    local from = refOf(rawget(self, "_owner"))
    if not from then error("teleport: inventory owner is not valid", 2) end
    local n, id = self.count, rawget(self, "_recordId")
    if n <= 0 then return end
    tes3.removeItem({ reference = from, item = id, count = n, playSound = false })
    local w = limbo(id, n)
    w:teleport(cell, pos, opts)
end
-- split(n): a view of n of these items (a new GameObject); moveInto/remove/teleport on it move n
function invMethods:split(n)
    n = math.floor(tonumber(n) or 0)
    if n <= 0 or n > self.count then error("split: count must be between 1 and " .. tostring(self.count), 2) end
    return setmetatable({ _id = rawget(self, "_id") .. ":split", _inv = true, _owner = rawget(self, "_owner"),
        _recordId = rawget(self, "_recordId"), _take = n }, OBJ)
end
function invMethods:sendEvent() rt.warnOnce("inv sendEvent", "sendEvent to an item in an inventory is ignored (no local scripts there)") end
local function invIndex(w, k)
    local m = invMethods[k]
    if m then return m end
    local g = invGetters[k]
    if g then return g(w) end
    if methods_ref and methods_ref[k] then
        return function() error("omwcompat: " .. tostring(k) .. " is not available for an item in an inventory", 2) end
    end
    return nil
end
function M.invItem(owner, recordId)
    local id = "inv:" .. tostring(rawget(owner, "_id")) .. ":" .. recordId
    local w = wrappers[id]
    if w and rawget(w, "_inv") then return w end
    w = setmetatable({ _id = id, _inv = true, _owner = owner, _recordId = recordId }, OBJ)
    wrappers[id] = w
    return w
end

local methods = {}
methods_ref = methods
local selfMethods = {}
OBJ.__index = function(w, k)
    if rawget(w, "_inv") then return invIndex(w, k) end
    if rawget(w, "_self") then
        local sm = selfMethods[k]
        if sm then return sm end
        if k == "object" then local ref = refOf(w); return ref and M.wrap(ref) or nil end
        if k == "controls" and M.controlsOf then return M.controlsOf(w) end
    end
    local m = methods[k]
    if m then return m end
    local g = getters[k]
    if g then return g(w, refOf(w)) end
    return nil
end
-- writable fields (OpenMW 0.51): enabled (global scripts; "items in containers or inventories
-- can't be disabled": ignored for them with a warning). Everything else is read-only.
OBJ.__newindex = function(w, k, v)
    if k == "enabled" then
        if rawget(w, "_inv") or rawget(w, "_limbo") then
            rt.warnOnce("enabled inv", "GameObject.enabled: items in containers or inventories can't be disabled; ignored")
            return
        end
        local ref = refOf(w)
        if not ref then error("GameObject.enabled: invalid object", 2) end
        if v then ref:enable() else ref:disable() end
        return
    end
    error("GameObject fields are read-only (" .. tostring(k) .. ")", 2)
end
OBJ.__tostring = function(w)
    local ref = refOf(w)
    return string.format("GameObject(%s, %s)", tostring(rawget(w, "_id") or "limbo"), tostring(w.recordId))
end
OBJ.__eq = function(a, b) return rawget(a, "_id") ~= nil and rawget(a, "_id") == rawget(b, "_id") end

function methods:isValid()
    if rawget(self, "_limbo") then return not rawget(self, "_gone") end
    local ref = refOf(self)
    return ref ~= nil and not ref.deleted and not isTomb(ref)
end

local function bind(w, ref, persist)
    rawset(w, "_limbo", nil); rawset(w, "_recordId", nil); rawset(w, "_count", nil)
    local id = M.refId(ref, persist)
    rawset(w, "_id", id); rawset(w, "_h", handleOf(ref))
    wrappers[id] = w
end

-- R1
function methods:remove(count)
    if rawget(self, "_limbo") then rawset(self, "_gone", true); return end
    local ref = refOf(self)
    if not ref or ref.deleted or isTomb(ref) then return end
    if not contentId(ref) and hasLuaData(ref) and ref.data.omwcompat_created then
        ref:disable()
        ref:delete()
        rt.log("remove: deleted created ref %s", rawget(self, "_id"))
    else
        ref:disable()
        setTomb(ref, true)
        rt.log("remove: tombstoned content ref %s (%s)", rawget(self, "_id"), lowerId(ref.object))
    end
end

local function toTes3Cell(c)
    if c == nil then return nil end
    if type(c) == "table" and getmetatable(c) == CELL then return rawget(c, "_c") end
    if type(c) == "string" then
        if c == "" then return nil end
        return tes3.getCell({ id = c })
    end
    return c
end

-- R2 helper: tombstoned ref of the same object at (nearly) the same position
function M.findTomb(cell, recordId, pos)
    if not cell then return nil end
    recordId = normId(recordId)
    for ref in cell:iterateReferences(nil) do
        if not ref.deleted and ref.disabled and isTomb(ref) and lowerId(ref.object) == recordId then
            local p = ref.position
            local dx, dy, dz = p.x - pos.x, p.y - pos.y, p.z - pos.z
            if dx * dx + dy * dy + dz * dz <= EPS * EPS then return ref end
        end
    end
    return nil
end

function methods:teleport(cellOrName, pos, opts)
    opts = opts or {}
    local rot = opts.rotation
    local cell = toTes3Cell(cellOrName)
    if rawget(self, "_limbo") then
        if rawget(self, "_gone") then error("object was removed", 2) end
        local recordId = rawget(self, "_recordId")
        local tcell = cell or (tes3.getCell and tes3.getCell({ position = pos }))
        local tomb = M.findTomb(tcell, recordId, pos)
        if tomb then
            setTomb(tomb, false)
            tomb:enable()
            bind(self, tomb)
            rt.log("teleport: resurrected %s (%s)", rawget(self, "_id"), recordId)
        else
            local params = {
                object = recordId,
                position = { pos.x, pos.y, pos.z },
                orientation = rot and { rot.ax, rot.ay, rot.az } or { 0, 0, 0 },
                scale = 1,
            }
            if cell and cell.isInterior then params.cell = cell end
            local ref = tes3.createReference(params)
            if not ref then error("tes3.createReference failed for " .. tostring(recordId), 2) end
            if ref.supportsLuaData then ref.data.omwcompat_created = true; ref.modified = true end
            bind(self, ref, true)
            rt.log("teleport: created %s (%s)", rawget(self, "_id"), recordId)
        end
        rt.objectBecameActive(self)
        return
    end
    local ref = refOf(self)
    if not ref then error("teleport of invalid object", 2) end
    tes3.positionCell({ reference = ref, cell = cell, position = { pos.x, pos.y, pos.z },
        orientation = rot and { rot.ax, rot.ay, rot.az } or nil })
    rt.objectBecameActive(self)
end

function methods:setScale(s)
    local ref = refOf(self)
    if ref then ref.scale = s end
end

-- R3
function methods:moveInto(dest)
    if type(dest) ~= "table" or getmetatable(dest) ~= INV then error("moveInto: destination must be an Inventory", 2) end
    local owner = dest._owner
    local ownerRef = refOf(owner)
    if not ownerRef then error("moveInto: inventory owner is not valid", 2) end
    local recordId, count
    if rawget(self, "_limbo") then
        recordId, count = normId(rawget(self, "_recordId")), rawget(self, "_count")
    else
        local ref = refOf(self)
        if not ref then error("moveInto of invalid object", 2) end
        recordId, count = lowerId(ref.object), countOf(self, ref)
    end
    local ctx = rt.activationContext()
    if ctx and ctx.actorRef == ownerRef and rawget(self, "_limbo") then
        local tgt = ctx.targetRef
        local tomb = tgt and M.findTomb(tgt.cell, recordId, tgt.position)
        if tomb then
            ctx.pickupOriginal = tomb
            rawset(self, "_gone", true)
            rt.log("moveInto: pickup redirected to original %s", lowerId(tomb.object))
            return
        end
    end
    tes3.addItem({ reference = ownerRef, item = recordId, count = count, playSound = false })
    -- (moveInto from a world object: the source is removed below)
    if rawget(self, "_limbo") then rawset(self, "_gone", true) else self:remove() end
end

function methods:activateBy(actor)
    local ref, aref = refOf(self), refOf(actor)
    if ref and aref then aref:activate(ref) end
end
function methods:sendEvent(name, data) rt.sendLocalEvent(self, name, data) end
function methods:addScript(path, initData) return rt.addScript(self, path, initData) end
function methods:removeScript(path) return rt.removeScript(self, path) end
function methods:hasScript(path) return rt.hasLocalScript(self, path) end

-- openmw.self: a GameObject for the object a local script is attached to, plus the
-- self-only members. It shares the wrapper id, so it compares equal to that object.
function M.selfOf(ref)
    local w = M.wrap(ref)
    return setmetatable({ _id = rawget(w, "_id"), _h = handleOf(ref), _self = true }, OBJ)
end
function selfMethods:isActive() return rt.isLocalActive(self) end
function selfMethods:enableAI(on)
    local ref = refOf(self)
    local mob = ref and ref.mobile
    if mob then mob.activeAI = on and true or false end
end
function methods:getBoundingBox() error("omwcompat: getBoundingBox not supported", 2) end
function methods:split(n) error("omwcompat: split not supported", 2) end

M.OBJ = OBJ
M.CELL = CELL
M.INV = INV
return M
