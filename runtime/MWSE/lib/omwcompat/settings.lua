-- omwcompat.settings: OpenMW settings (I.Settings + openmw.storage) on MWSE.
--   * registerPage / registerGroup with renderers checkbox, number, select, textLine,
--     color (hex text), inputBinding (shown, not editable), custom renderers (fallback
--     by default value type)
--   * storage sections: settings groups are backed by mwse.loadConfig/saveConfig
--     (Data Files/MWSE/config/omwcompat_<Mod>.json); other sections live in the save
--   * subscribers fire (next frame) on every set, including changes made in the MCM
--   * an MWSE MCM is generated from the declared pages and groups
--   * l10n: core.l10n(ctx) reads l10n/<ctx>/en.yaml from the mod (flat key: value)
-- MIT, Copyright (c) 2026 dej (dejunai).
local util = require("omwcompat.util")
local M = {}
local rt

local registry = { pages = {}, pageOrder = {}, groups = {}, groupOrder = {} }
M.registry = registry
local configs = {}      -- mod name -> { groups = { [groupKey] = { [k] = v } } }
local sections = {}     -- section name -> section object
local subscribers = {}  -- section name -> { { fn, owner } }

function M.init(runtime) rt = runtime end

---------------------------------------------------------------- l10n
local l10nCache = {}
local function parseYaml(path)
    local t = {}
    local f = io.open(path, "r")
    if not f then return nil end
    for line in f:lines() do
        line = line:gsub("\r$", "")
        if not line:find("^%s*#") and not line:find("^%s") then
            local k, v = line:match("^([^:]+):%s*(.-)%s*$")
            if k and v and v ~= "" and v ~= "|" and v ~= ">" then
                k = k:gsub("^[\"']", ""):gsub("[\"']$", "")
                if v:find('^"') then v = v:sub(2, -2):gsub('\\"', '"'):gsub("\\n", "\n")
                elseif v:find("^'") then v = v:sub(2, -2):gsub("''", "'") end
                t[k] = v
            end
        end
    end
    f:close()
    return t
end
function M.l10n(m, ctx)
    local key = m.name .. "|" .. tostring(ctx)
    local tbl = l10nCache[key]
    if tbl == nil then
        tbl = (ctx and (parseYaml(m.root .. "l10n/" .. ctx .. "/en.yaml") or parseYaml(m.root .. "L10n/" .. ctx .. "/en.yaml"))) or false
        l10nCache[key] = tbl
    end
    return function(k, args)
        if type(k) ~= "string" then return k end
        local s = tbl and tbl[k] or k
        if type(args) == "table" then
            s = s:gsub("{(%w+)[^}]*}", function(n) local v = args[n]; return v ~= nil and tostring(v) or nil end)
        end
        return s
    end
end

---------------------------------------------------------------- config backing
local function configOf(modName)
    local c = configs[modName]
    if not c then
        c = mwse.loadConfig("omwcompat_" .. modName, { groups = {} }) or { groups = {} }
        c.groups = c.groups or {}
        configs[modName] = c
    end
    return c
end
function M.saveConfig(modName)
    if configs[modName] then mwse.saveConfig("omwcompat_" .. modName, configs[modName]) end
end

local function settingOf(groupKey, key)
    local g = registry.groups[groupKey]
    if not g then return nil end
    for _, s in ipairs(g.settings) do if s.key == key then return s end end
    return nil
end
M.settingOf = settingOf

local function storeOf(name, owner)
    local g = registry.groups[name]
    if g then
        local c = configOf(g.mod.name)
        c.groups[name] = c.groups[name] or {}
        return c.groups[name], g
    end
    local store = owner and owner.storage or {}
    store[name] = store[name] or {}
    return store[name], nil
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = copy(x) end
    return c
end

---------------------------------------------------------------- subscribers
local function notify(name, key)
    local list = subscribers[name]
    if not list or #list == 0 then return end
    for _, sub in ipairs(list) do
        rt.defer(function() rt.safecall("storage subscriber " .. name, sub.fn, name, key) end)
    end
end
M.notify = notify
function M.dropSubscribers(pred)
    for name, list in pairs(subscribers) do
        local keep = {}
        for _, s in ipairs(list) do if not pred(s.owner) then keep[#keep + 1] = s end end
        subscribers[name] = keep
    end
end

---------------------------------------------------------------- sections
local SEC = {}
SEC.__index = SEC
local function decodeValue(name, key, v)
    local s = settingOf(name, key)
    if s and s.renderer == "color" and type(v) == "string" then
        local ok, c = pcall(util.color.hex, v)
        if ok then return c end
    end
    return v
end
local function encodeValue(v)
    if util.typeOf(v) == "Color" then return v:asHex() end
    return v
end
function SEC:get(key)
    local store = storeOf(self.name, self.owner)
    local v = store[key]
    if v == nil then
        local s = settingOf(self.name, key)
        if s then v = s.default end
    end
    v = decodeValue(self.name, key, v)
    if type(v) == "table" and util.typeOf(v) == nil then return util.makeReadOnly(copy(v)) end
    return v
end
function SEC:getCopy(key)
    local v = self:get(key)
    if type(v) == "table" and util.typeOf(v) == nil then
        local store = storeOf(self.name, self.owner)
        return copy(store[key] ~= nil and store[key] or (settingOf(self.name, key) or {}).default)
    end
    return v
end
function SEC:set(key, value)
    if self.readOnly then return end
    local store, g = storeOf(self.name, self.owner)
    store[key] = copy(encodeValue(value))
    if g then
        M.saveConfig(g.mod.name)
        if g.mod.onSettingChanged then g.mod.onSettingChanged(self.name, key) end
    end
    notify(self.name, key)
end
function SEC:asTable()
    local out = {}
    local g = registry.groups[self.name]
    if g then for _, s in ipairs(g.settings) do out[s.key] = s.default end end
    for k, v in pairs(storeOf(self.name, self.owner)) do out[k] = copy(v) end
    for k, v in pairs(out) do out[k] = decodeValue(self.name, k, v) end
    return out
end
function SEC:reset(values)
    if self.readOnly then return end
    local store, g = storeOf(self.name, self.owner)
    for k in pairs(store) do store[k] = nil end
    if values then for k, v in pairs(values) do store[k] = copy(encodeValue(v)) end end
    if g then M.saveConfig(g.mod.name) end
    notify(self.name, nil)
end
function SEC:subscribe(fn)
    if self.readOnly then return end
    subscribers[self.name] = subscribers[self.name] or {}
    table.insert(subscribers[self.name], { fn = fn, owner = self.script })
end
function SEC:removeOnExit() end
function SEC:setLifeTime() end

-- owner: the runtime mod (in-save store); script: owning script (for subscriber cleanup)
function M.section(name, owner, script, readOnly)
    return setmetatable({ name = name, owner = owner, script = script, readOnly = readOnly }, SEC)
end

---------------------------------------------------------------- registration
local KNOWN = { checkbox = "full", number = "full", select = "full", textLine = "full",
    color = "partial", inputBinding = "fallback" }
M.KNOWN_RENDERERS = KNOWN

function M.registerPage(m, page)
    if type(page) ~= "table" or not page.key then error("registerPage: key required", 3) end
    if not registry.pages[page.key] then registry.pageOrder[#registry.pageOrder + 1] = page.key end
    local p = {}
    for k, v in pairs(page) do p[k] = v end
    p.mod = m
    registry.pages[page.key] = p
end

function M.registerGroup(m, group, scriptFlags)
    if type(group) ~= "table" or not group.key then error("registerGroup: key required", 3) end
    local g = { key = group.key, page = group.page, l10n = group.l10n, name = group.name,
        description = group.description, order = group.order or 0, permanentStorage = group.permanentStorage,
        mod = m, settings = {}, flags = scriptFlags, seq = #registry.groupOrder + 1 }
    for _, s in ipairs(group.settings or {}) do
        local arg = s.argument or {}
        g.settings[#g.settings + 1] = {
            key = s.key, name = s.name, description = s.description, default = s.default,
            renderer = s.renderer or "textLine", argument = arg,
            min = arg.min or s.min, max = arg.max or s.max, integer = arg.integer or s.integer,
            items = arg.items, itemsL10n = arg.l10n,
            mcmNote = s.mcmNote,
        }
        if not KNOWN[s.renderer or "textLine"] then
            rt.warnOnce("renderer " .. tostring(s.renderer), "settings: custom renderer '%s' (%s.%s) shown with a fallback control",
                tostring(s.renderer), group.key, tostring(s.key))
        end
    end
    if not registry.groups[group.key] then registry.groupOrder[#registry.groupOrder + 1] = group.key end
    registry.groups[group.key] = g
    return g
end

function M.updateRendererArgument(groupKey, key, arg)
    local s = settingOf(groupKey, key)
    if s then
        s.argument = arg or {}
        s.min, s.max, s.integer = s.argument.min or s.min, s.argument.max or s.max, s.argument.integer or s.integer
        s.items = s.argument.items or s.items
    end
end

-- I.Settings for one script
function M.interface(m, S)
    return {
        version = 1,
        registerPage = function(p) M.registerPage(m, p) end,
        registerGroup = function(g) M.registerGroup(m, g, S and S.flags) end,
        registerRenderer = function(name) rt.warnOnce("registerRenderer " .. tostring(name),
            "settings: custom renderer '%s' registered by %s; the MCM uses a fallback control", tostring(name), m.name) end,
        updateRendererArgument = M.updateRendererArgument,
        getGroup = function(k) return registry.groups[k] end,
        getPage = function(k) return registry.pages[k] end,
    }
end

---------------------------------------------------------------- MCM generation
local function fmtDefault(s)
    local d = s.default
    if type(d) == "boolean" then return d and "on" or "off" end
    if util.typeOf(d) == "Color" then return "#" .. d:asHex() end
    return tostring(d)
end

-- returns a description of what was created, for tests/logging
local function addSetting(container, g, s, L)
    local sec = M.section(g.key, g.mod, nil, false)
    local label = L(s.name or s.key)
    local desc = s.description and L(s.description) or ""
    local function withDefault(extra)
        local t = desc
        if extra then t = (t ~= "" and (t .. "\n\n") or "") .. extra end
        return (t ~= "" and (t .. "\n\n") or "") .. "Default: " .. fmtDefault(s)
    end
    local function var(conv)
        return mwse.mcm.createCustom({
            getter = function() local v = sec:get(s.key); if util.typeOf(v) == "Color" then return v:asHex() end; return v end,
            setter = function(_, v) sec:set(s.key, conv and conv(v) or v) end,
            numbersOnly = conv == tonumber or nil,
        })
    end
    local r = s.renderer
    local kind = r
    if not KNOWN[r] then
        local t = type(s.default)
        kind = (t == "boolean" and "checkbox") or (t == "number" and "number") or (t == "string" and "textLine")
            or (util.typeOf(s.default) == "Color" and "color") or "info"
    end
    local note = s.mcmNote
    if kind == "checkbox" then
        container:createOnOffButton({ label = label, description = withDefault(note), variable = var() })
        return "onOff"
    elseif kind == "number" then
        local lo, hi = tonumber(s.min), tonumber(s.max)
        local function conv(v)
            v = tonumber(v)
            if v == nil then return s.default end
            if s.integer then v = math.floor(v + 0.5) end
            if lo and v < lo then v = lo end
            if hi and v > hi then v = hi end
            return v
        end
        if lo and hi then
            local integer = s.integer or (math.floor(lo) == lo and math.floor(hi) == hi and math.floor(s.default or 0) == (s.default or 0) and (hi - lo) >= 2)
            container:createSlider({ label = label, description = withDefault(note), min = lo, max = hi,
                step = integer and 1 or (hi - lo) / 100, jump = integer and math.max(1, math.floor((hi - lo) / 10)) or (hi - lo) / 10,
                decimalPlaces = integer and 0 or 2, variable = var(conv) })
            return "slider"
        end
        local range = (lo and ("min " .. lo) or "") .. ((lo and hi) and ", " or "") .. (hi and ("max " .. hi) or "")
        container:createTextField({ label = label, description = withDefault((note and note .. "\n" or "") .. (range ~= "" and range or "")),
            numbersOnly = true, variable = var(conv) })
        return "numberField"
    elseif kind == "select" then
        local IL = M.l10n(g.mod, s.itemsL10n or g.l10n)
        local options = {}
        for _, it in ipairs(s.items or {}) do options[#options + 1] = { label = IL(tostring(it)), value = it } end
        container:createDropdown({ label = label, description = withDefault(note), options = options, variable = var() })
        return "dropdown"
    elseif kind == "textLine" then
        container:createTextField({ label = label, description = withDefault(note), variable = var() })
        return "textField"
    elseif kind == "color" then
        container:createTextField({ label = label .. " (hex RRGGBB)", description = withDefault(note), variable = var(function(v)
            v = tostring(v):gsub("^#", "")
            if v:match("^%x%x%x%x%x%x$") then return util.color.hex(v) end
            return s.default
        end) })
        return "colorHex"
    elseif kind == "inputBinding" then
        container:createInfo({ text = label .. ": key bindings are not emulated by omwcompat (default " .. fmtDefault(s) .. ")." })
        return "info:inputBinding"
    end
    container:createInfo({ text = label .. ": custom renderer '" .. tostring(r) .. "' is not supported (value "
        .. tostring(sec:get(s.key)) .. ")." })
    return "info:custom"
end

-- Build one MCM template per mod that declared groups. Returns a summary table.
function M.buildMCM(m, opts)
    opts = opts or {}
    local groups = {}
    for _, k in ipairs(registry.groupOrder) do
        local g = registry.groups[k]
        if g.mod == m then groups[#groups + 1] = g end
    end
    if #groups == 0 then return nil end
    local pageKeys, pagesUsed = {}, {}
    for _, g in ipairs(groups) do
        local pk = (g.page and registry.pages[g.page]) and g.page or "__default"
        if not pagesUsed[pk] then pagesUsed[pk] = {}; pageKeys[#pageKeys + 1] = pk end
        table.insert(pagesUsed[pk], g)
    end
    local firstPage = registry.pages[pageKeys[1]]
    local PL = firstPage and M.l10n(m, firstPage.l10n) or function(x) return x end
    local title = (firstPage and firstPage.name and PL(firstPage.name)) or m.title or m.name
    local template = mwse.mcm.createTemplate({ name = title })
    template.onClose = function()
        M.saveConfig(m.name)
        if m.onSettingsClosed then m.onSettingsClosed() end
    end
    local summary = { title = title, pages = {} }
    for _, pk in ipairs(pageKeys) do
        local p = registry.pages[pk]
        local L = p and M.l10n(m, p.l10n) or function(x) return x end
        local plabel = p and p.name and L(p.name) or "Settings"
        local pdesc = p and p.description and L(p.description) or ""
        if opts.pageNote then pdesc = (pdesc ~= "" and (pdesc .. "\n\n") or "") .. opts.pageNote end
        local page = template:createSideBarPage({ label = plabel, description = pdesc })
        local ps = { label = plabel, groups = {} }
        table.sort(pagesUsed[pk], function(a, b) if a.order ~= b.order then return a.order < b.order end return a.seq < b.seq end)
        for _, g in ipairs(pagesUsed[pk]) do
            local GL = M.l10n(m, g.l10n)
            local glabel = g.name and GL(g.name) or g.key
            local cat = page:createCategory({ label = glabel, description = g.description and GL(g.description) or nil })
            local gs = { label = glabel, key = g.key, settings = {} }
            local hosted = false
            for _, spec in ipairs((m.spec and m.spec.scripts) or {}) do
                for _, f in ipairs(spec.flags or {}) do if f == "GLOBAL" then hosted = true end end
            end
            if not hosted then
                cat:createInfo({ text = "omwcompat only runs GLOBAL scripts and this mod has none yet "
                    .. "(these settings are declared by " .. table.concat(g.flags or { "?" }, ",")
                    .. " scripts): changes are stored but have no effect in game." })
            end
            for _, s in ipairs(g.settings) do
                local kind = addSetting(cat, g, s, GL)
                gs.settings[#gs.settings + 1] = { key = s.key, label = GL(s.name or s.key), renderer = s.renderer, control = kind,
                    default = s.default, min = s.min, max = s.max }
            end
            ps.groups[#ps.groups + 1] = gs
        end
        summary.pages[#summary.pages + 1] = ps
    end
    template:register()
    return summary
end

---------------------------------------------------------------- probe support
-- A permissive stand-in for modules omwcompat does not provide, used only when
-- collecting settings declarations at modConfigReady.
local dummy
local dmt = {}
dmt.__index = function() return dummy end
dmt.__newindex = function() end
dmt.__call = function() return dummy end
dmt.__concat = function(a, b) return (type(a) == "string" and a or "") .. (type(b) == "string" and b or "") end
dmt.__tostring = function() return "" end
dmt.__unm = function() return 0 end
for _, k in ipairs({ "__add", "__sub", "__mul", "__div", "__mod", "__pow" }) do dmt[k] = function() return 0 end end
dmt.__len = function() return 0 end
dummy = setmetatable({}, dmt)
M.dummy = dummy

function M.reset()
    sections, subscribers = {}, {}
end
function M.resetAll()
    registry.pages, registry.pageOrder, registry.groups, registry.groupOrder = {}, {}, {}, {}
    configs, l10nCache = {}, {}
    M.reset()
end
return M
