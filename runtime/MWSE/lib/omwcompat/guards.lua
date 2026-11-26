-- omwcompat.guards: rule-based workarounds for two common OpenMW Lua patterns. omw2mwse
-- detects them statically and lists them per script in the generated main.lua
-- (`guards = { ... }`); the runtime then gives that script (and the modules it requires)
-- guarded versions of a few standard functions. The mod's own Lua is never edited.
--
--   activeDedupe   table.insert(list, obj) of a GameObject while one of the script's
--                  onObjectActive / onActorActive / onItemActive handlers runs is skipped
--                  when that same object is already in the list. GameObjects are cached per
--                  reference (objects.wrap), so the same reference is the same Lua table and
--                  rawequal is enough. Inserts outside those handlers are not touched.
--   safeIteration  next / pairs / ipairs that survive table.remove of the element just
--                  visited: the element that shifts into the freed slot is visited instead of
--                  skipped, and next() with a key that is gone restarts the traversal instead
--                  of raising "invalid key to 'next'".
--
-- Each rule logs one line the first time it changes anything for a script; later changes
-- are only counted (M.stats, also in omwcompat.timing snapshots).
-- MIT, Copyright (c) 2026 dej (dejunai). Built with Grok Bot.
local M = {}

M.KNOWN = { activeDedupe = true, safeIteration = true }
M.ACTIVE_HANDLERS = { onObjectActive = true, onActorActive = true, onItemActive = true }
M.RULE_IDS = { activeDedupe = "active-collect-dedupe", safeIteration = "mutate-during-iteration" }

local rt, isGameObject
function M.init(runtime, objects)
    rt = runtime
    local OBJ = objects.OBJ
    isGameObject = function(v) return type(v) == "table" and getmetatable(v) == OBJ end
end

-- stats[mod .. " " .. script] = { mod, script, dedupeSkipped, shiftRevisits, nextRestarts }
M.stats = {}
local function statOf(S)
    local key = S.mod.name .. " " .. S.path
    local s = M.stats[key]
    if not s then
        s = { mod = S.mod.name, script = S.path, dedupeSkipped = 0, shiftRevisits = 0, nextRestarts = 0 }
        M.stats[key] = s
    end
    return s
end

local function noteFirst(S, st, field, what)
    st[field] = st[field] + 1
    if st[field] == 1 then
        rt.warn("%s %s: %s (rule %s; further cases are counted, not logged)", S.mod.name, S.path, what,
            field == "dedupeSkipped" and M.RULE_IDS.activeDedupe or M.RULE_IDS.safeIteration)
    end
end

local rawinsert, rawremove, rawnext = table.insert, table.remove, next
local gpairs, gipairs = pairs, ipairs

-- Returns the list of valid guard names for a spec (unknown names are warned about once).
function M.normalize(S, list)
    local out = {}
    for _, g in ipairs(type(list) == "table" and list or {}) do
        if M.KNOWN[g] then out[g] = true
        else rt.warnOnce("guard " .. tostring(g), "%s: unknown guard %s ignored (omwcompat %s)", S.path, tostring(g), rt.VERSION) end
    end
    return next(out) and out or nil
end

-- Install the guarded functions into a script environment.
function M.apply(env, S)
    local g = S.guards
    if not g then return end
    local st = statOf(S)
    local tbl = setmetatable({}, { __index = table })
    env.table = tbl
    if g.activeDedupe then
        S.activeDepth = 0
        tbl.insert = function(t, ...)
            if S.activeDepth > 0 and select("#", ...) == 1 and type(t) == "table" then
                local v = ...
                if isGameObject(v) then
                    for i = 1, #t do
                        if rawequal(t[i], v) then
                            noteFirst(S, st, "dedupeSkipped",
                                "skipped table.insert of an object that is already in the list (" .. tostring(v) .. ")")
                            return
                        end
                    end
                end
            end
            return rawinsert(t, ...)
        end
    end
    if g.safeIteration then
        local cursor = setmetatable({}, { __mode = "k" })   -- table -> last key a guarded traversal returned
        local shifted = setmetatable({}, { __mode = "k" })  -- table -> key whose element was removed right after its visit
        tbl.remove = function(t, ...)
            if select("#", ...) == 0 then return rawremove(t) end
            local pos = ...
            local r = rawremove(t, pos)
            if type(t) == "table" and pos ~= nil and cursor[t] == pos then shifted[t] = pos end
            return r
        end
        local function safeNext(t, k)
            if k == nil then
                shifted[t] = nil
                local nk, nv = rawnext(t)
                cursor[t] = nk
                return nk, nv
            end
            if shifted[t] ~= nil and shifted[t] == k then
                shifted[t] = nil
                local v = rawget(t, k)
                if v ~= nil then
                    noteFirst(S, st, "shiftRevisits", "visited the element that moved into a removed slot during iteration")
                    return k, v
                end
            end
            local nk, nv
            if rawget(t, k) ~= nil then
                nk, nv = rawnext(t, k)
            else
                local ok, a, b = pcall(rawnext, t, k)
                if ok then nk, nv = a, b
                else
                    noteFirst(S, st, "nextRestarts", "next() got a key that is no longer in the table; restarted the traversal")
                    nk, nv = rawnext(t)
                end
            end
            cursor[t] = nk
            return nk, nv
        end
        local function ipairsIter(t, i)
            if i > 0 and shifted[t] == i then
                shifted[t] = nil
                local v = rawget(t, i)
                if v ~= nil then
                    noteFirst(S, st, "shiftRevisits", "visited the element that moved into a removed slot during iteration")
                    return i, v
                end
                return nil
            end
            i = i + 1
            local v = t[i]
            if v ~= nil then cursor[t] = i; return i, v end
            cursor[t] = nil
            return nil
        end
        env.next = safeNext
        env.pairs = function(t)
            if type(t) ~= "table" or getmetatable(t) ~= nil then return gpairs(t) end
            shifted[t] = nil
            return safeNext, t, nil
        end
        env.ipairs = function(t)
            if type(t) ~= "table" or getmetatable(t) ~= nil then return gipairs(t) end
            shifted[t] = nil
            return ipairsIter, t, 0
        end
    end
end

return M
