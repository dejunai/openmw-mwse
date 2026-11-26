-- omwcompat.util: emulation of openmw.util (vectors, transforms, colors, helpers).
-- MIT, Copyright (c) 2026 dej (dejunai).
local M = {}

local function isnum(x) return type(x) == "number" end

---------------------------------------------------------------- Vector2/3/4
local function makeVector(n, tag)
    local mt = { __omwtype = tag }
    mt.__index = mt
    local names = { "x", "y", "z", "w" }
    local function new(...)
        local a = { ... }
        local v = {}
        for i = 1, n do v[names[i]] = a[i] or 0 end
        return setmetatable(v, mt)
    end
    local function each(a, b, f)
        local r = {}
        for i = 1, n do local k = names[i]; r[i] = f(a[k], b and (isnum(b) and b or b[k])) end
        return new(unpack(r, 1, n))
    end
    mt.__add = function(a, b) return each(a, b, function(p, q) return p + q end) end
    mt.__sub = function(a, b) return each(a, b, function(p, q) return p - q end) end
    mt.__mul = function(a, b)
        if isnum(a) then a, b = b, a end
        if isnum(b) then return each(a, b, function(p, q) return p * q end) end
        return a:dot(b)
    end
    mt.__div = function(a, b) return each(a, b, function(p, q) return p / q end) end
    mt.__unm = function(a) return each(a, nil, function(p) return -p end) end
    mt.__eq = function(a, b)
        for i = 1, n do if a[names[i]] ~= b[names[i]] then return false end end
        return true
    end
    mt.__tostring = function(a)
        local p = {}
        for i = 1, n do p[i] = string.format("%g", a[names[i]]) end
        return "(" .. table.concat(p, ", ") .. ")"
    end
    function mt:dot(b) local s = 0; for i = 1, n do s = s + self[names[i]] * b[names[i]] end; return s end
    function mt:length2() return self:dot(self) end
    function mt:length() return math.sqrt(self:dot(self)) end
    function mt:normalize()
        local l = self:length()
        if l == 0 then return new(), 0 end
        return self / l, l
    end
    function mt:emul(b) return each(self, b, function(p, q) return p * q end) end
    function mt:ediv(b) return each(self, b, function(p, q) return p / q end) end
    function mt:copy() return each(self, nil, function(p) return p end) end
    if n == 3 then
        function mt:cross(b)
            return new(self.y * b.z - self.z * b.y, self.z * b.x - self.x * b.z, self.x * b.y - self.y * b.x)
        end
        function mt:xy() return M.vector2(self.x, self.y) end
    end
    return new, mt
end

M.vector2, M._v2mt = makeVector(2, "Vector2")
M.vector3, M._v3mt = makeVector(3, "Vector3")
M.vector4, M._v4mt = makeVector(4, "Vector4")

function M.typeOf(v)
    local mt = getmetatable(v)
    return mt and mt.__omwtype
end

---------------------------------------------------------------- Transform
-- Represented by Euler angles (x, y, z) in radians, the same convention as a
-- Morrowind reference orientation. Matrix order for applying to vectors: Z * Y * X.
local tmt = { __omwtype = "Transform" }
tmt.__index = tmt
local function transform(x, y, z, move)
    return setmetatable({ ax = x or 0, ay = y or 0, az = z or 0, move = move or M.vector3(0, 0, 0) }, tmt)
end
M._newTransform = transform
local function rotate(v, t)
    local x, y, z = v.x, v.y, v.z
    -- X
    local c, s = math.cos(t.ax), math.sin(t.ax)
    y, z = y * c - z * s, y * s + z * c
    -- Y
    c, s = math.cos(t.ay), math.sin(t.ay)
    x, z = x * c + z * s, -x * s + z * c
    -- Z
    c, s = math.cos(t.az), math.sin(t.az)
    x, y = x * c - y * s, x * s + y * c
    return M.vector3(x, y, z)
end
tmt.__mul = function(a, b)
    if getmetatable(b) == M._v3mt then return rotate(b, a) + a.move end
    -- composition: exact for single-axis rotations and moves; approximate otherwise (documented)
    return transform(a.ax + b.ax, a.ay + b.ay, a.az + b.az, a.move + b.move)
end
tmt.__tostring = function(t) return string.format("Transform(%g, %g, %g)", t.ax, t.ay, t.az) end
function tmt:getYaw() return self.az end
function tmt:getPitch() return self.ax end
function tmt:getAnglesZYX() return self.az, self.ay, self.ax end
function tmt:getAnglesXZ() return self.ax, self.az end
function tmt:inverse() return transform(-self.ax, -self.ay, -self.az, -self.move) end
function tmt:apply(v) return rotate(v, self) + self.move end
M.transform = {
    identity = transform(0, 0, 0),
    rotateX = function(a) return transform(a, 0, 0) end,
    rotateY = function(a) return transform(0, a, 0) end,
    rotateZ = function(a) return transform(0, 0, a) end,
    move = function(x, y, z)
        if type(x) == "table" then return transform(0, 0, 0, x:copy()) end
        return transform(0, 0, 0, M.vector3(x, y, z))
    end,
}
M._tmt = tmt

---------------------------------------------------------------- Color
local cmt = { __omwtype = "Color" }
cmt.__index = cmt
local function color(r, g, b, a) return setmetatable({ r = r, g = g, b = b, a = a or 1 }, cmt) end
cmt.__eq = function(a, b) return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a end
cmt.__tostring = function(c) return string.format("Color(%g, %g, %g, %g)", c.r, c.g, c.b, c.a) end
function cmt:asRgb() return M.vector3(self.r, self.g, self.b) end
function cmt:asRgba() return M.vector4(self.r, self.g, self.b, self.a) end
function cmt:asHex() return string.format("%02x%02x%02x", self.r * 255 + 0.5, self.g * 255 + 0.5, self.b * 255 + 0.5) end
M.color = {
    rgb = function(r, g, b) return color(r, g, b, 1) end,
    rgba = color,
    hex = function(h)
        h = h:gsub("^#", "")
        return color(tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255, 1)
    end,
}
M._cmt = cmt

---------------------------------------------------------------- helpers
function M.clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
function M.round(v) return math.floor(v + 0.5) end
function M.remap(v, a, b, c, d) return c + (v - a) * (d - c) / (b - a) end
function M.normalizeAngle(a)
    local pi2 = 2 * math.pi
    a = a % pi2
    if a > math.pi then a = a - pi2 end
    return a
end
function M.makeReadOnly(t)
    return setmetatable({}, { __index = t, __newindex = function() error("table is read-only", 2) end, __pairs = function() return pairs(t) end })
end
function M.makeStrictReadOnly(t) return M.makeReadOnly(t) end
local bit_ok, bit = pcall(require, "bit")
if bit_ok then
    M.bitAnd, M.bitOr, M.bitXor, M.bitNot = bit.band, bit.bor, bit.bxor, bit.bnot
end
function M.loadCode(code, env)
    local f, err = loadstring(code)
    if not f then error(err, 2) end
    setfenv(f, env or {})
    return f
end

return M
