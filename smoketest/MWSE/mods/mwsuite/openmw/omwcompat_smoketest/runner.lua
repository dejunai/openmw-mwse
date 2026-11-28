-- omwcompat_smoketest runner: runs the checks and writes the PASS/FAIL/SKIP report to the omwcompat
-- library log (Data Files/MWSE/logs/omwcompat.log) through omwcompat.note. MWSE.log is not used,
-- except for one line when omwcompat itself is missing (there is no library log then).
-- Written for omwcompat by dej (dejunai). MIT.
local checks = require("mwsuite.openmw.omwcompat_smoketest.checks")
local R = { lastReport = nil, runs = 0 }

local function runtime()
    local loaded = package.loaded["omwcompat"]
    if loaded then return loaded end
    local ok, rt = pcall(require, "omwcompat")
    return ok and rt or nil
end

local function cellName()
    local ok, c = pcall(function() return tes3.getPlayerCell and tes3.getPlayerCell() or (tes3.player and tes3.player.cell) end)
    if ok and c then return tostring(c.editorName or c.name or c.id or "?") end
    return "no cell"
end

-- trigger: "load" | "hotkey" | "mcm"; returns the report (also kept as R.lastReport)
function R.run(trigger, frames, seconds)
    local omwc = runtime()
    local ok, rep = pcall(checks.run, { omwc = omwc, trigger = trigger, frames = frames, seconds = seconds })
    if not ok then
        local err = tostring(rep)
        rep = { entries = { { scope = "smoketest", status = "FAIL", name = "the smoke test itself", detail = err } },
            counts = { PASS = 0, FAIL = 1, SKIP = 0 } }
        function rep:line(e) return string.format("[smoketest] %-4s %s: %s - %s", e.status, e.scope, e.name, e.detail) end
        function rep:summary() return "0 PASS, 1 FAIL, 0 SKIP" end
    end
    R.lastReport, R.runs = rep, R.runs + 1
    local hour = tes3.worldController and tes3.worldController.hour and tes3.worldController.hour.value
    local lines = { string.format("[smoketest %s] ===== begin (trigger: %s, cell: %s, game hour: %s) =====", checks.VERSION,
        tostring(trigger), cellName(), hour and string.format("%.1f", hour) or "?") }
    for _, e in ipairs(rep.entries) do lines[#lines + 1] = rep:line(e) end
    lines[#lines + 1] = string.format("[smoketest %s] ===== end: %s =====", checks.VERSION, rep:summary())
    local note = omwc and omwc.note
    for _, l in ipairs(lines) do
        if note then note("%s", l) else mwse.log("%s", l) end
    end
    return rep
end

function R.messageLine(rep)
    return string.format("OpenMW smoke test: %s. Details: Data Files\\MWSE\\logs\\omwcompat.log", rep:summary())
end

return R
