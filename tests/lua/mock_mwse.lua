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
    local W = { objects = {}, scripts = {}, objectList = {}, cells = {}, logs = {}, libLogs = {}, captured = {},
        handlers = {}, crimes = {}, frame = 0,
        files = opts.files or {}, mods = opts.mods or { ["morrowind.esm"] = true } }
    M.W = W

    ------------------------------------------------------------ log / json / config
    _G.mwse = {
        log = function(fmt, ...)
            local s = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
            W.logs[#W.logs + 1] = s
            W.captured[#W.captured + 1] = { dest = "mwse", text = s }
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
                if k == "SideBarPage" then child.sidebar = container("SideBar", {}) end
                self.children[#self.children + 1] = child
                return child
            end
        end
        for _, k in ipairs({ "createSideBarPage", "createPage", "createCategory", "createOnOffButton", "createYesNoButton",
            "createSlider", "createTextField", "createDropdown", "createInfo", "createButton", "createKeyBinder" }) do
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
    mwse.mcm.createTableVariable = function(t)
        return { id = t.id, getter = function() return t.table[t.id] end, setter = function(_, v) t.table[t.id] = v end }
    end
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
    -- a vanilla global script with variables; context indexing errors on unknown names like MWSE
    function M.addScript(id, vars)
        local store = {}
        for k, v in pairs(vars or {}) do store[k:lower()] = v end
        local ctx = setmetatable({}, {
            __index = function(_, k)
                local v = store[tostring(k):lower()]
                if v == nil then error("unknown variable " .. tostring(k)) end
                return v
            end,
            __newindex = function(_, k, v)
                if store[tostring(k):lower()] == nil then error("unknown variable " .. tostring(k)) end
                store[tostring(k):lower()] = v
            end,
        })
        local s = { id = id, context = ctx, _vars = store }
        W.scripts[id:lower()] = s
        return s
    end

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
        "cellChanged", "simulate", "modConfigReady", "load", "keyDown", "keyUp", "journal", "addSound", "saved" }) do ev[n] = n end
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
        getPlayerCell = function() return W.activeCell end,
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
        getScript = function(id) return id and W.scripts[id:lower()] or nil end,
        startGlobalScript = function(p) local s = W.scripts[p.id:lower()]; if s then s._running = true end end,
        stopGlobalScript = function(p) local s = W.scripts[p.id:lower()]; if s then s._running = false end end,
        menuMode = function() return W.menuMode == true end,
        makeSafeObjectHandle = function(ref)
            return { valid = function() return not ref._deleted end, getObject = function() return ref end }
        end,
        messageBox = function() end,
        aiPackage = { none = -1, wander = 0, travel = 1, escort = 2, follow = 3, activate = 4 },
        setStatistic = function(p)
            local mob = p.reference.mobile
            local st = mob and (p.skill and mob:getSkillStatistic(p.skill) or mob[p.name])
            assert(st, "setStatistic: no mobile statistic " .. tostring(p.name))
            if p.current then st.current = p.current end
            if p.base then st.base = p.base end
        end,
        setAIWander = function(p) W.aiCalls = W.aiCalls or {}; W.aiCalls[#W.aiCalls + 1] = { "wander", p } end,
        setAITravel = function(p) W.aiCalls = W.aiCalls or {}; W.aiCalls[#W.aiCalls + 1] = { "travel", p } end,
        setAIFollow = function(p) W.aiCalls = W.aiCalls or {}; W.aiCalls[#W.aiCalls + 1] = { "follow", p } end,
        setAIEscort = function(p) W.aiCalls = W.aiCalls or {}; W.aiCalls[#W.aiCalls + 1] = { "escort", p } end,
    }

    ------------------------------------------------------------ 0.4.0 additions
    -- messages, sounds, items, locks, owners, journal, factions, rayTest, input
    W.messages, W.sounds, W.journal, W.keysDown = {}, {}, {}, {}
    tes3.messageBox = function(fmt, ...)
        local t = type(fmt) == "table" and fmt.message or (select("#", ...) > 0 and string.format(fmt, ...) or fmt)
        W.messages[#W.messages + 1] = t
    end
    tes3.playSound = function(p)
        W.sounds[#W.sounds + 1] = { op = "play", sound = p.sound, path = p.soundPath, ref = p.reference, volume = p.volume,
            pitch = p.pitch, loop = p.loop }
        return true
    end
    tes3.removeSound = function(p)
        W.sounds[#W.sounds + 1] = { op = "remove", sound = p.sound, ref = p.reference }
        if p.reference and (p.sound == nil or (W.loops[p.reference] and p.reference.object.sound == p.sound)) then
            W.loops[p.reference] = nil
        end
    end
    -- engine light sounds (0.4.1 tests). Like Morrowind: a light reference in the active cell
    -- plays its record's own loop whatever isOffByDefault says, a disabled reference starts
    -- nothing new but keeps a loop that is already playing, and only tes3.removeSound stops it.
    -- W.notPlayingQuirk: like the in-game runaway (mwsoundguard: "engine says playing: no"),
    -- loops on off-by-default lights are reported as not playing, so every engine pass starts
    -- them again.
    W.loops, W.loopStarts = {}, {}
    function M.engineSounds(passes)
        for _ = 1, passes or 1 do
            for _, r in ipairs(W.activeCell and W.activeCell._refs or {}) do
                local o = r.object
                if not r._gone and not r.disabled and o.objectType == OT.light and o.sound and not W.loops[r] then
                    local e = { reference = r, sound = o.sound, flags = 1, volume = 250, pitch = 1, isVoiceover = false }
                    if M.fire("addSound", e) ~= false and not e.block then
                        W.loopStarts[r] = (W.loopStarts[r] or 0) + 1
                        if not (W.notPlayingQuirk and o.isOffByDefault) then W.loops[r] = true end
                    end
                end
            end
        end
    end
    tes3.getSoundPlaying = function(p)
        for i = #W.sounds, 1, -1 do
            local x = W.sounds[i]
            if x.ref == p.reference and (p.sound == nil or x.sound == p.sound or x.sound == nil) then return x.op == "play" end
        end
        return false
    end
    tes3.say = function(p) W.sounds[#W.sounds + 1] = { op = "say", path = p.soundPath, ref = p.reference, text = p.subtitle } end
    tes3.streamMusic = function(p) W.music = p.path end
    tes3.skill = { block = 0, sneak = 19, longBlade = 5 }
    tes3.dialogueType = { journal = 4 }
    local function invOf(r) return r.object.inventory end
    tes3.removeItem = function(p)
        local inv, id, n = invOf(p.reference), (type(p.item) == "string" and p.item or p.item.id):lower(), p.count or 1
        local removed = 0
        for i = #inv, 1, -1 do
            local st = inv[i]
            if st.object.id:lower() == id and removed < n then
                local k = math.min(st.count, n - removed)
                st.count = st.count - k; removed = removed + k
                if st.count <= 0 then table.remove(inv, i) end
            end
        end
        return removed
    end
    tes3.transferItem = function(p)
        local n = tes3.removeItem({ reference = p.from, item = p.item, count = p.count })
        if n > 0 then tes3.addItem({ reference = p.to, item = (type(p.item) == "string" and p.item or p.item.id), count = n }) end
        return n
    end
    tes3.getOwner = function(p)
        local r = p.reference
        if not r.owner then return nil, nil end
        return r.owner, r.ownerRank
    end
    tes3.setOwner = function(p)
        if p.remove then p.reference.owner, p.reference.ownerRank = nil, nil; return end
        p.reference.owner = type(p.owner) == "string" and W.objects[p.owner:lower()] or p.owner
        p.reference.ownerRank = p.requiredRank
    end
    tes3.getLocked = function(p) return p.reference.lockNode ~= nil and p.reference.lockNode.locked == true end
    tes3.getLockLevel = function(p) return p.reference.lockNode and p.reference.lockNode.level or nil end
    tes3.lock = function(p)
        local r = p.reference
        r.lockNode = r.lockNode or { level = 0 }
        r.lockNode.locked = true
        if p.level then r.lockNode.level = p.level end
        return true
    end
    tes3.unlock = function(p) if p.reference.lockNode then p.reference.lockNode.locked = false end; return true end
    tes3.getJournalIndex = function(p) return W.journal[p.id:lower()] or 0 end
    tes3.setJournalIndex = function(p) W.journal[p.id:lower()] = p.index; return true end
    tes3.updateJournal = function(p)
        W.journal[p.id:lower()] = p.index
        M.fire("journal", { topic = { id = p.id }, index = p.index, new = true })
        return true
    end
    W.dialogues = {}
    tes3.findDialogue = function(p) return W.dialogues[p.topic:lower()] end
    W.globals = { chargenstate = { value = -1 } }
    tes3.findGlobal = function(id) return W.globals[id:lower()] or { value = 30 } end
    W.factions = {}
    tes3.dataHandler = { nonDynamicData = { factions = W.factions } }
    function M.addFaction(f) W.factions[#W.factions + 1] = f; return f end
    W.rayHit = nil
    tes3.rayTest = function(p) W.lastRay = p; return W.rayHit end
    wc.inputController = { isKeyDown = function(_, dik) return W.keysDown[dik] == true end }
    function M.setKeyDown(dik, on) W.keysDown[dik] = on or nil end

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
        unregister = function(name, fn)
            local list = W.handlers[name] or {}
            for i = #list, 1, -1 do
                if list[i].fn == fn then table.remove(list, i); break end
            end
        end,
        isRegistered = function(name, fn)
            for _, h in ipairs(W.handlers[name] or {}) do if h.fn == fn then return true end end
            return false
        end,
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
    -- Real-enough lfs for omwcompat's library log (mkdir + attributes). MWSE ships lfs;
    -- the box LuaJIT does not, so the mock talks to the real filesystem.
    local function _norm(path)
        return path and path:gsub("\\", "/"):gsub("/+$", "") or path
    end
    local function _isDir(path)
        path = _norm(path)
        local f = io.open(path .. "/.", "r")
        if f then f:close(); return true end
        return false
    end
    local function _isFile(path)
        path = _norm(path)
        if _isDir(path) then return false end
        local f = io.open(path, "r")
        if f then f:close(); return true end
        return false
    end
    _G.lfs = {
        attributes = function(path, field)
            path = _norm(path)
            if not path then return nil end
            local mode
            if _isDir(path) then mode = "directory"
            elseif _isFile(path) then mode = "file"
            else return nil end
            if field == "mode" then return mode end
            if field then return nil end
            return { mode = mode }
        end,
        mkdir = function(path)
            path = _norm(path)
            if _isDir(path) then return true end
            local quoted = path:gsub("'", "'\\''")
            os.execute("mkdir -p '" .. quoted .. "'")
            if _isDir(path) then return true end
            return nil, "mkdir failed"
        end,
        dir = function() return function() end end,
    }
    package.preload["lfs"] = function() return _G.lfs end

    -- Capture writes to the library log (and still write the real file).
    -- LuaJIT file handles are userdata, so we return a proxy table instead of
    -- attaching methods to the handle.
    if not M._realIoOpen then M._realIoOpen = io.open end
    local real_open = M._realIoOpen
    io.open = function(path, mode)
        local f, err = real_open(path, mode)
        if not f then return nil, err end
        local n = path and tostring(path:gsub("\\", "/")) or ""
        if n == "Data Files/MWSE/logs/omwcompat.log" and mode and mode:find("w", 1, true) then
            local proxy = {}
            function proxy:write(...)
                local s = table.concat({ ... })
                local body = s
                if body:sub(-1) == "\n" then body = body:sub(1, -2) end
                local Wnow = M.W
                if Wnow and body ~= "" then
                    for line in (body .. "\n"):gmatch("(.-)\n") do
                        if line ~= "" then
                            local msg = line:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d  (.+)$")
                            Wnow.libLogs = Wnow.libLogs or {}
                            Wnow.captured = Wnow.captured or {}
                            if not msg and #Wnow.libLogs > 0 then
                                -- continuation (debug.traceback is multi-line)
                                Wnow.libLogs[#Wnow.libLogs] = Wnow.libLogs[#Wnow.libLogs] .. "\n" .. line
                                local cap = Wnow.captured[#Wnow.captured]
                                if cap and cap.dest == "lib" then cap.text = Wnow.libLogs[#Wnow.libLogs] end
                            else
                                msg = msg or line
                                Wnow.libLogs[#Wnow.libLogs + 1] = msg
                                Wnow.captured[#Wnow.captured + 1] = { dest = "lib", text = msg }
                            end
                        end
                    end
                end
                return f:write(...)
            end
            function proxy:flush() return f:flush() end
            function proxy:close() return f:close() end
            function proxy:seek(...) return f:seek(...) end
            return proxy
        end
        return f, err
    end

    ------------------------------------------------------------ actors (mobiles)
    -- t = { hp, fight, flee, dead, pkg = tes3.aiPackage value or nil, sticky = combat sets inCombat }
    function M.addMobile(ref, t)
        t = t or {}
        local mob = { reference = ref, health = { current = t.hp or 50, base = t.hp or 50 },
            magicka = { current = 10, base = 10 }, fatigue = { current = 100, base = 100 },
            strength = { current = t.str or 40, base = t.strBase or t.str or 40 },
            fight = t.fight or 30, flee = t.flee or 0, alarm = 0, hello = 30,
            isDead = t.dead or false, inCombat = false, activeAI = true, combatCalls = {}, actionData = {} }
        mob.aiPlanner = { getActivePackage = function() if t.pkg == nil then return nil end; return { type = t.pkg } end }
        function mob:startCombat(target)
            self.combatCalls[#self.combatCalls + 1] = target
            if t.sticky then self.inCombat = true; self.actionData.target = target end
        end
        function mob:stopCombat() self.inCombat = false; self.actionData.target = nil end
        mob.castReady, mob.weaponReady = false, false
        mob.skills = {}
        function mob:getSkillStatistic(sid)
            self.skills[sid] = self.skills[sid] or { base = 10, current = 10 }
            return self.skills[sid]
        end
        -- equip / unequip move inventory stacks in and out of ref.object.equipment
        function mob:equip(p)
            local id = (type(p.item) == "string" and p.item or p.item.id):lower()
            local o = W.objects[id]
            local eq = ref.object.equipment or {}
            rawset(ref.object, "equipment", eq)
            eq[#eq + 1] = { object = o }
            return true
        end
        function mob:unequip(p)
            local id = (type(p.item) == "string" and p.item or p.item.id):lower()
            local eq = ref.object.equipment or {}
            for i = #eq, 1, -1 do if eq[i].object.id:lower() == id then table.remove(eq, i) end end
            return true
        end
        rawset(ref, "mobile", mob)
        return mob
    end

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

-- All log lines in write order: MWSE.log and the library log (timestamps stripped).
function M.allLogs()
    local out = {}
    for _, e in ipairs((M.W and M.W.captured) or {}) do out[#out + 1] = e.text end
    return out
end
function M.libLogs()
    return (M.W and M.W.libLogs) or {}
end
function M.mwseLogs()
    return (M.W and M.W.logs) or {}
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
