-- Unit tests for omwcompat.serial and omwcompat.util (pure Lua, no mock needed).
package.path = "Data Files/MWSE/lib/?.lua;" .. package.path
local serial = require("omwcompat.serial")
local util = require("omwcompat.util")
local pass, fail = 0, 0
local function check(c, m) if c then pass = pass + 1; print("  ok   " .. m) else fail = fail + 1; print("  FAIL " .. m) end end

local data = { a = 1, b = "x\n\"y\"", c = { 1, 2, 3 }, d = true, e = 1.5e-7, f = util.vector3(1, -2, 3.25),
    g = util.transform.rotateZ(0.5), h = util.color.rgba(0.1, 0.2, 0.3, 0.4), i = { nested = { deep = "z" } }, [7] = "seven",
    big = 2 ^ 40, neg = -3 }
local s = serial.encode(data)
check(type(s) == "string", "encode returns a string")
local d = serial.decode(s)
check(d.a == 1 and d.b == data.b and d.c[3] == 3 and d.d == true and d[7] == "seven", "scalars/arrays round trip")
check(math.abs(d.e - 1.5e-7) < 1e-20 and d.big == 2 ^ 40 and d.neg == -3, "numbers round trip")
check(util.typeOf(d.f) == "Vector3" and d.f == data.f, "Vector3 round trip")
check(util.typeOf(d.g) == "Transform" and math.abs(d.g:getYaw() - 0.5) < 1e-12, "Transform round trip")
check(util.typeOf(d.h) == "Color" and d.h == data.h, "Color round trip")
check(d.i.nested.deep == "z", "nested tables")
local inf = serial.decode(serial.encode({ x = math.huge, y = -math.huge }))
check(inf.x == math.huge and inf.y == -math.huge, "inf round trip")
local nan = serial.decode(serial.encode({ x = 0 / 0 }))
check(nan.x ~= nan.x, "nan round trip")
check(not pcall(serial.encode, { f = function() end }), "functions rejected")
local t = {}
check(not pcall(serial.encode, { t, t }), "shared tables rejected")
local cyc = {}; cyc.self = cyc
check(not pcall(serial.encode, cyc), "cycles rejected")
check(not pcall(serial.encode, setmetatable({}, {})), "custom metatables rejected")
local env_escape = pcall(serial.decode, "os.exit(1)")
check(not env_escape, "decode runs in an empty environment")
local obj = setmetatable({ _id = "c:morrowind.esm:42" }, { __omwtype = "GameObject" })
-- GameObject encoding needs an id resolver
local e2 = serial.encode({ o = obj }, function(o) return o._id end)
local d2 = serial.decode(e2, function(id) return { resolved = id } end)
check(d2.o.resolved == "c:morrowind.esm:42", "GameObject encoded by id and resolved on decode")

local v = util.vector3(3, 4, 0)
check(v:length() == 5 and (v * 2).x == 6 and (v - v):length() == 0, "vector arithmetic")
local r = util.transform.rotateZ(math.pi / 2) * util.vector3(1, 0, 0)
check(math.abs(r.x) < 1e-9 and math.abs(r.y - 1) < 1e-9, "rotateZ applies to vectors")
check(util.clamp(5, 0, 3) == 3 and util.round(2.5) == 3, "clamp/round")
check(math.abs(util.normalizeAngle(3 * math.pi) - math.pi) < 1e-9 or math.abs(util.normalizeAngle(3 * math.pi) + math.pi) < 1e-9, "normalizeAngle")
check(util.color.hex("ff0000").r == 1, "color.hex")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
