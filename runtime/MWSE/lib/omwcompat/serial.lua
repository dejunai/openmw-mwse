-- omwcompat.serial: encode OpenMW "serializable data" into a plain string that
-- is stored as ONE string field in tes3.player.data (no nested-table reassignment).
-- Supports nil/bool/number/string, plain tables, GameObjects (by persistent id) and
-- openmw.util Vector2/3/4, Transform, Color. Rejects functions, custom metatables,
-- shared and circular tables, mirroring OpenMW's rules.
-- MIT, Copyright (c) 2026 dej (dejunai).
local util = require("omwcompat.util")
local M = {}

local function num(n)
    if n ~= n then return "(0/0)" end
    if n == math.huge then return "(1/0)" end
    if n == -math.huge then return "(-1/0)" end
    if n == math.floor(n) and math.abs(n) < 2^53 then return string.format("%d", n) end
    return string.format("%.17g", n)
end

-- objectId(v) -> string|nil : supplied by the runtime, returns a persistent id for GameObjects
function M.encode(value, objectId)
    local out, seen = {}, {}
    local function enc(v, path)
        local t = type(v)
        if t == "nil" then out[#out + 1] = "nil"
        elseif t == "boolean" then out[#out + 1] = v and "true" or "false"
        elseif t == "number" then out[#out + 1] = num(v)
        elseif t == "string" then out[#out + 1] = string.format("%q", v)
        elseif t == "table" then
            local tag = util.typeOf(v)
            if tag == "Vector2" then out[#out + 1] = string.format("V2(%s,%s)", num(v.x), num(v.y))
            elseif tag == "Vector3" then out[#out + 1] = string.format("V3(%s,%s,%s)", num(v.x), num(v.y), num(v.z))
            elseif tag == "Vector4" then out[#out + 1] = string.format("V4(%s,%s,%s,%s)", num(v.x), num(v.y), num(v.z), num(v.w))
            elseif tag == "Transform" then
                out[#out + 1] = string.format("T(%s,%s,%s,%s,%s,%s)", num(v.ax), num(v.ay), num(v.az), num(v.move.x), num(v.move.y), num(v.move.z))
            elseif tag == "Color" then out[#out + 1] = string.format("C(%s,%s,%s,%s)", num(v.r), num(v.g), num(v.b), num(v.a))
            elseif tag == "GameObject" then
                local id = objectId and objectId(v)
                if not id then error("cannot serialize GameObject without id at " .. path, 0) end
                out[#out + 1] = string.format("O(%q)", id)
            elseif getmetatable(v) ~= nil then
                error("cannot serialize table with custom metatable at " .. path, 0)
            else
                if seen[v] then error("shared or circular table reference at " .. path, 0) end
                seen[v] = true
                out[#out + 1] = "{"
                for k, val in pairs(v) do
                    local kt = type(k)
                    if kt ~= "string" and kt ~= "number" and kt ~= "boolean" then
                        error("unsupported key type " .. kt .. " at " .. path, 0)
                    end
                    out[#out + 1] = "["; enc(k, path); out[#out + 1] = "]="
                    enc(val, path .. "." .. tostring(k)); out[#out + 1] = ","
                end
                out[#out + 1] = "}"
            end
        else
            error("cannot serialize value of type " .. t .. " at " .. path, 0)
        end
    end
    enc(value, "data")
    return table.concat(out)
end

-- resolveObject(id) -> GameObject wrapper
function M.decode(s, resolveObject)
    if s == nil or s == "" then return nil end
    local f, err = loadstring("return " .. s)
    if not f then error("omwcompat: corrupt save payload: " .. tostring(err), 0) end
    setfenv(f, {
        V2 = util.vector2, V3 = util.vector3, V4 = util.vector4,
        T = function(x, y, z, mx, my, mz) return util._newTransform(x, y, z, util.vector3(mx or 0, my or 0, mz or 0)) end,
        C = util.color.rgba,
        O = function(id) return resolveObject and resolveObject(id) or id end,
    })
    return f()
end

return M
