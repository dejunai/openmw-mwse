-- Minimal mock of the MWSE API surface used by omwcompat and Dej's hand port.
-- It models: objects (lights, NPCs), references with data/tempData/disable/delete,
-- cells, weather, game time, events, a save/load round trip (which, like MWSE,
-- does NOT refire referenceActivated for an unchanged cell and cancels timers),
-- and vanilla activation (carriable light pickup with an ownership/theft flag).
-- This is a test double, not MWSE: results only show the Lua logic is coherent.
local M = {}

local function deepcopy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local c = {}
    seen[v] = c
    for k, x in pairs(v) do c[deepcopy(k, seen)] = deepcopy(x, seen) end
    return setmetatable(c, getmetatable(v))
end
M.deepcopy = deepcopy

function M.install(opts)
    opts = opts or {}
    local W = { objects = {}, objectList = {}, cells = {}, logs = {}, handlers = {}, crimes = {}, frame = 0,
        files = opts.files or {}, mods = opts.mods or { ["morrowind.esm"] = true } }
    M.W = W

    ------------------------------------------------------------ log / json / config
    _G.mwse = {
        log = function(fmt, ...)
            local s = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
            W.logs[#W.logs + 1] = s
            if os.getenv("MOCK_VERBOSE") then io.stderr:write(s, "\n") end
        end,
        loadConfig = function(name, defaults) return deepcopy(W.config and W.config[name] or defaults) end,
        saveConfig = function(name, t) W.config = W.config or {}; W.config[name] = deepcopy(t) end,
        mcm = {},
    }
    -- recording MCM: templates -> pages -> categories -> components (with their variables)
    W.mcm = {}
    local function container(kind, t)
        local c = { kind = kind, label = t and t.label, description = t and t.description, children = {}, args = t }
        local function add(k)
            return function(self, args)
                local child = container(k, args)
                child.variable = args and args.variable
                child.text = args and args.text
                child.options = args and args.options
                self.children[#self.children + 1] = child
                return child
            end
        end
        for _, k in ipairs({ "createSideBarPage", "createPage", "createCategory", "createOnOffButton", "createYesNoButton",
            "createSlider", "createTextField", "createDropdown", "createInfo", "createButton" }) do
            c[k] = add(k:sub(7))
        end
        return c
    end
    mwse.mcm.createTemplate = function(t)
        local tpl = container("Template", type(t) == "table" and t or { name = t })
        tpl.name = tpl.args.name
        function tpl:register() W.mcm[#W.mcm + 1] = self end
        return tpl
    end
    mwse.mcm.register = function(tpl) tpl:register() end
    mwse.mcm.createCustom = function(t) return { getter = t.getter, setter = t.setter, numbersOnly = t.numbersOnly } end
    -- walk all value components of a template
    function M.mcmControls(tpl)
        local out = {}
        local function walk(c)
            if c.variable then out[#out + 1] = c end
            for _, ch in ipairs(c.children) do walk(ch) end
        end
        walk(tpl)
        return out
    end
    function M.mcmFind(tpl, label)
        for _, c in ipairs(M.mcmControls(tpl)) do if c.label == label then return c end end
    end
    function M.mcmGet(c) return c.variable.getter(c.variable) end
    function M.mcmSet(c, v) c.variable.setter(c.variable, v) end
    function M.mcmClose(tpl) if tpl.onClose then tpl.onClose(tpl) end end
    _G.json = { encode = function() return "{}" end, decode = function() return {} end }

    ------------------------------------------------------------ objects
    local OT = { light = 1279870540, npc = 1598246990, creature = 1095062083, container = 1414418243, door = 1380929348,
        static = 1413567571, activator = 1230259009, miscItem = 1129531725, weapon = 1346454871, armor = 1330467393,
        clothing = 1414483011, book = 1263488834, alchemy = 1212369985, ingredient = 1380404809, apparatus = 1095782465,
        lockpick = 1262702412, probe = 1112494672, repairItem = 1095779666, ammunition = 1330466113 }
    local objMT = {}
    objMT.__index = objMT
    function objMT:createCopy(p)
        local c = setmetatable({}, objMT)
        for k, v in pairs(self) do c[k] = v end
        c._content = nil
        c.id = p and p.id or ("copy" .. tostring(#W.objectList))
        c.sourceless = (p and p.sourceless) or not W.inSave
        if W.objects[c.id:lower()] then error("duplicate id " .. c.id) end
        W.objects[c.id:lower()] = c
        W.objectList[#W.objectList + 1] = c
        return c
    end
    local function newObject(t)
        t._content = true
        local o = setmetatable(t, objMT)
        W.objects[o.id:lower()] = o
        W.objectList[#W.objectList + 1] = o
        return o
    end
    function M.addLight(t)
        t.objectType = OT.light
        t.mesh = t.mesh or "l\\" .. t.id .. ".nif"
        t.radius = t.radius or 256; t.time = t.time or -1; t.value = t.value or 5; t.weight = t.weight or 1
        t.color = t.color or { 255, 200, 100 }
        if t.canCarry == nil then t.canCarry = false end
        t.flickers = t.flickers or false; t.isFire = t.isFire or false; t.isOffByDefault = t.isOffByDefault or false
        local o = newObject(t)
        return o
    end
    function M.addObject(t) return newObject(t) end

    ------------------------------------------------------------ cells / refs
    local cellMT = {}
    cellMT.__index = cellMT
    function cellMT:iterateReferences(filter)
        local list = {}
        for _, r in ipairs(self._refs) do
            local ok = true
            if type(filter) == "number" then ok = r.object.objectType == filter
            elseif type(filter) == "table" then
                ok = false
                for _, f in ipairs(filter) do if r.object.objectType == f then ok = true end end
            end
            if ok and not r._gone then list[#list + 1] = r end
        end
        local i = 0
        return function() i = i + 1; return list[i] end
    end
    function M.addCell(t)
        local c = setmetatable({ _refs = {}, isInterior = t.isInterior or false, behavesAsExterior = t.behavesAsExterior or false,
            gridX = t.gridX or 0, gridY = t.gridY or 0, id = t.id or "Balmora", name = t.name or t.id, editorName = t.id or "Balmora" }, cellMT)
        c.isOrBehavesAsExterior = (not c.isInterior) or c.behavesAsExterior
        W.cells[#W.cells + 1] = c
        return c
    end
    local refMT = {}
    refMT.__index = function(r, k)
        if k == "supportsLuaData" then return true end
        -- like MWSE, for item refs data/tempData live on itemData, which is created on first access
        local isItem = r.object.objectType ~= OT.npc and r.object.objectType ~= OT.creature and r.object.objectType ~= OT.static
        if k == "tempData" then local t = rawget(r, "_temp"); if not t then t = {}; rawset(r, "_temp", t); if isItem then rawset(r, "itemData", rawget(r, "itemData") or {}) end end; return t end
        if k == "data" then local t = rawget(r, "_data"); if not t then t = {}; rawset(r, "_data", t); if isItem then rawset(r, "itemData", rawget(r, "itemData") or {}) end end; return t end
        if k == "deleted" then return rawget(r, "_deleted") or false end
        return refMT[k]
    end
    function refMT:disable() self.disabled = true; self.modified = true end
    function refMT:enable() self.disabled = false; self.modified = true end
    function refMT:delete() self._deleted = true; self._gone = true end
    function refMT:activate(target) return M.activate(self, target) end
    function refMT:detachDynamicLightFromAffectedNodes() self._detached = true end
    local vecMT = {}
    vecMT.__index = vecMT
    function vecMT:copy() return setmetatable({ x = self.x, y = self.y, z = self.z }, vecMT) end
    M.vecMT = vecMT
    local formCounter = 1000
    function M.placeRef(cell, objectId, pos, t)
        local o = W.objects[objectId:lower()]
        assert(o, "no object " .. objectId)
        formCounter = formCounter + 1
        t = t or {}
        local r = setmetatable({
            object = o, cell = cell, position = setmetatable({ x = pos[1], y = pos[2], z = pos[3] }, vecMT),
            orientation = setmetatable({ x = 0, y = 0, z = t.rotZ or 0 }, vecMT), startingOrientation = { x = 0, y = 0, z = t.rotZ or 0 },
            startingPosition = { x = pos[1], y = pos[2], z = pos[3] },
            scale = t.scale or 1, disabled = false, modified = false,
            sourceMod = t.sourceMod or "Morrowind.esm", sourceFormId = t.sourceFormId or formCounter,
            sceneNode = { appCulled = false }, owner = t.owner,
        }, refMT)
        cell._refs[#cell._refs + 1] = r
        return r
    end

    ------------------------------------------------------------ tes3
    local wc = {
        hour = { value = 12 }, daysPassed = { value = 1 },
        weatherController = { currentWeather = { index = 0, name = "Clear" }, nextWeather = nil, transitionScalar = 0 },
    }
    local WEATHER = { [0] = "Clear", "Cloudy", "Foggy", "Overcast", "Rain", "Thunderstorm", "Ashstorm", "Blight", "Snow", "Blizzard" }
    function M.setWeather(cur, nxt, scalar)
        wc.weatherController.currentWeather = { index = cur, name = WEATHER[cur] }
        wc.weatherController.nextWeather = nxt and { index = nxt, name = WEATHER[nxt] } or nil
        wc.weatherController.transitionScalar = scalar or 0
    end
    function M.setHour(h) wc.hour.value = h end

    local ev = {}
    for _, n in ipairs({ "initialized", "loaded", "save", "enterFrame", "activate", "referenceActivated", "referenceDeactivated",
        "cellChanged", "simulate", "modConfigReady", "load" }) do ev[n] = n end
    _G.tes3 = {
        objectType = OT,
        weather = { clear = 0, cloudy = 1, foggy = 2, overcast = 3, rain = 4, thunder = 5, ash = 6, blight = 7, snow = 8, blizzard = 9 },
        event = ev,
        worldController = wc,
        player = nil,
        getObject = function(id) return id and W.objects[id:lower()] or nil end,
        iterateObjects = function(ot)
            local list = {}
            for _, o in ipairs(W.objectList) do if ot == nil or o.objectType == ot then list[#list + 1] = o end end
            local i = 0
            return function() i = i + 1; return list[i] end
        end,
        getActiveCells = function() return { W.activeCell } end,
        getCell = function(p)
            for _, c in ipairs(W.cells) do
                if p.id and c.id:lower() == p.id:lower() then return c end
                if p.position and not c.isInterior then return c end
                if p.x and not c.isInterior and c.gridX == p.x and c.gridY == p.y then return c end
            end
        end,
        createReference = function(p)
            local o = type(p.object) == "string" and W.objects[p.object:lower()] or p.object
            assert(o, "createReference: unknown object")
            local cell = p.cell or W.activeCell
            local pp = p.position
            local r = M.placeRef(cell, o.id, { pp[1] or pp.x, pp[2] or pp.y, pp[3] or pp.z },
                { sourceMod = nil, sourceFormId = 0 })
            r.sourceMod, r.sourceFormId = nil, 0
            local po = p.orientation or {}
            r.orientation = setmetatable({ x = po[1] or po.x or 0, y = po[2] or po.y or 0, z = po[3] or po.z or 0 }, vecMT)
            if p.scale then r.scale = p.scale end
            r.modified = true
            W.created = (W.created or 0) + 1
            M.fire("referenceActivated", { reference = r })
            return r
        end,
        positionCell = function(p) local r = p.reference; r.position = { x = p.position[1], y = p.position[2], z = p.position[3] } end,
        addItem = function(p)
            local inv = p.reference.object.inventory
            inv[#inv + 1] = { object = W.objects[p.item:lower()], count = p.count or 1 }
        end,
        getFileExists = function(path) return W.files[path:lower():gsub("/", "\\")] ~= nil end,
        getFileSource = function(path) return W.files[path:lower()] and "file" or nil end,
        isModActive = function(n) return W.mods[n:lower()] == true end,
        findGMST = function() return nil end,
        findGlobal = function() return { value = 30 } end,
        menuMode = function() return W.menuMode == true end,
        makeSafeObjectHandle = function(ref)
            return { valid = function() return not ref._deleted end, getObject = function() return ref end }
        end,
        messageBox = function() end,
    }

    ------------------------------------------------------------ events / timers
    local function sortH(name)
        table.sort(W.handlers[name], function(a, b) return a.priority > b.priority end)
    end
    _G.event = {
        register = function(name, fn, o)
            W.handlers[name] = W.handlers[name] or {}
            table.insert(W.handlers[name], { fn = fn, priority = o and o.priority or 0, filter = o and o.filter })
            sortH(name)
        end,
        unregister = function() end,
    }
    function M.fire(name, e)
        e = e or {}
        for _, h in ipairs(W.handlers[name] or {}) do
            if h.filter == nil or h.filter == e.filter then
                local r = h.fn(e)
                if r == false or e.block then return false end
            end
        end
        return true
    end
    W.timers = {}
    _G.timer = {
        real = "real", simulate = "simulate", game = "game",
        delayOneFrame = function(fn) table.insert(W.timers, { at = W.frame + 1, fn = fn, frames = true }) end,
        start = function(p)
            local t = { at = (W.clock or 0) + (p.duration or 1), dur = p.duration or 1, fn = p.callback, iter = p.iterations or 1 }
            table.insert(W.timers, t)
            return t
        end,
        register = function() end,
    }
    _G.lfs = { attributes = function() return nil end, dir = function() return function() end end }
    package.preload["lfs"] = function() return _G.lfs end

    ------------------------------------------------------------ player / world
    local npc = newObject({ id = "player", objectType = OT.npc, inventory = {} })
    function M.newPlayer(cell)
        local p = M.placeRef(cell, "player", { 0, 0, 0 }, { sourceMod = nil, sourceFormId = 0 })
        p.sourceMod, p.sourceFormId = nil, 0
        tes3.player = p
        return p
    end

    function M.activate(actor, target)
        local ok = M.fire("activate", { activator = actor, target = target })
        if not ok then return false end
        if target.object.objectType == OT.light and target.object.canCarry and not target.disabled then
            tes3.addItem({ reference = actor, item = target.object.id, count = 1 })
            if target.owner then W.crimes[#W.crimes + 1] = target.object.id end
            target:disable(); target:delete()
            W.pickedUp = (W.pickedUp or 0) + 1
        end
        return true
    end

    function M.frame(dt)
        W.frame = W.frame + 1
        W.clock = (W.clock or 0) + (dt or 1 / 60)
        local keep = {}
        local due = {}
        for _, t in ipairs(W.timers) do
            if (t.frames and W.frame >= t.at) or (not t.frames and W.clock >= t.at) then due[#due + 1] = t else keep[#keep + 1] = t end
        end
        W.timers = keep
        for _, t in ipairs(due) do
            t.fn({ timer = t })
            if not t.frames and t.iter and (t.iter == -1 or t.iter > 1) then
                t.at = W.clock + t.dur; if t.iter > 1 then t.iter = t.iter - 1 end
                table.insert(W.timers, t)
            end
        end
        M.fire("simulate", { delta = dt or 1 / 60 })
        M.fire("enterFrame", { delta = dt or 1 / 60, menuMode = W.menuMode == true })
    end
    function M.frames(n, dt) for _ = 1, n do M.frame(dt) end end

    -- save: snapshot everything that a .ess would keep
    function M.save()
        M.fire("save", { filename = "test" })
        local snap = { cells = {}, objects = {}, player = nil, hour = wc.hour.value, days = wc.daysPassed.value }
        for _, o in ipairs(W.objectList) do
            if not o._content and not o.sourceless then snap.objects[#snap.objects + 1] = deepcopy(o) end
        end
        for ci, c in ipairs(W.cells) do
            local refs = {}
            for _, r in ipairs(c._refs) do
                if not r._gone then
                    refs[#refs + 1] = { objectId = r.object.id, position = deepcopy(r.position), orientation = deepcopy(r.orientation),
                        startingOrientation = deepcopy(r.startingOrientation), scale = r.scale, disabled = r.disabled,
                        sourceMod = r.sourceMod, sourceFormId = r.sourceFormId, data = deepcopy(rawget(r, "_data")),
                        owner = r.owner, isPlayer = (r == tes3.player), modified = r.modified, hasItemData = rawget(r, "itemData") ~= nil }
                end
            end
            snap.cells[ci] = refs
        end
        snap.inventory = deepcopy(npc.inventory)
        return snap
    end
    -- load: rebuild refs from the snapshot; generated (non-sourceless) objects come back,
    -- sourceless ones disappear; MWSE timers are cancelled; no referenceActivated.
    function M.load(snap)
        local content = {}
        for _, o in ipairs(W.objectList) do if o._content then content[#content + 1] = o end end
        W.objects, W.objectList = {}, {}
        for _, o in ipairs(content) do W.objects[o.id:lower()] = o; W.objectList[#W.objectList + 1] = o end
        for _, so in ipairs(snap.objects) do
            local o = setmetatable(deepcopy(so), objMT)
            W.objects[o.id:lower()] = o; W.objectList[#W.objectList + 1] = o
        end
        W.objects["player"] = npc
        npc.inventory = deepcopy(snap.inventory)
        W.timers = {}
        wc.hour.value, wc.daysPassed.value = snap.hour, snap.days
        for ci, c in ipairs(W.cells) do
            c._refs = {}
            for _, sr in ipairs(snap.cells[ci]) do
                local r = M.placeRef(c, sr.objectId, { sr.position.x, sr.position.y, sr.position.z },
                    { sourceMod = sr.sourceMod, sourceFormId = sr.sourceFormId, owner = sr.owner })
                r.sourceMod, r.sourceFormId = sr.sourceMod, sr.sourceFormId
                r.orientation, r.startingOrientation = setmetatable(sr.orientation, vecMT), sr.startingOrientation
                r.scale, r.disabled, r.modified = sr.scale, sr.disabled, sr.modified
                rawset(r, "_data", (sr.modified or sr.isPlayer) and sr.data or nil)
                if sr.hasItemData then rawset(r, "itemData", {}) end
                if sr.isPlayer then tes3.player = r end
            end
        end
        M.fire("loaded", { filename = "test", newGame = false })
    end
    W.inSave = true -- copies created during play are saved (not sourceless)
    return M
end

-- helpers for assertions
function M.refsIn(cell, includeDisabled)
    local out = {}
    for _, r in ipairs(cell._refs) do
        if not r._gone and (includeDisabled or not r.disabled) and r.object.objectType == tes3.objectType.light then out[#out + 1] = r end
    end
    return out
end

return M
