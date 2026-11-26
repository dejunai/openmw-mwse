-- omwcompat conversions registrar: the single "MW Conversions" Mod Config Menu entry.
-- Every converted OpenMW mod gets its own tab (a page of this one template), whether or
-- not it has anything to configure. Same idea as the suite's mwmanagermenu ("MW Conflict
-- Tools", one entry with a tab per mod), but built natively: converted mods all register
-- through the shared omwcompat runtime, so no registerModConfig hook is needed.
-- Part of omwcompat, MIT, Copyright (c) 2026 dej (dejunai). Built with Grok Bot.
local C = {}

C.NAME = "MW Conversions"
-- The one support contact, identical whoever packed the conversion (conflict-tools or
-- MWManager). tools/omw2mwse/build.py SUPPORT_LINE must match (a test checks it).
C.SUPPORT = "Unofficial conversion by mwsuite. Do not contact the original author about it. "
    .. "Support: dej (dejunai) via the Nexus Mods forums."

-- Tab 1 of the menu: the general notice. Fixed text, shown whenever any conversion is
-- installed; the per-mod tabs follow it (from tab 2 on).
C.DISCLAIMER_LABEL = "Disclaimer"
C.DISCLAIMER = {
    "GENERAL NOTICE AND DISCLAIMER",
    "About this menu. The mods on the following tabs are OpenMW Lua mods that have been converted to run "
        .. "on the original Morrowind engine with MWSE. The conversions are produced by the omw2mwse "
        .. "conversion tool and hosted by the omwcompat runtime library, both created and maintained by "
        .. "dej (dejunai) as part of mwsuite.",
    "Experimental software. This conversion tooling is experimental and unofficial. A converted mod may "
        .. "behave differently from the original, may fail, and may be incompatible with some saves, other "
        .. "mods or future releases of MWSE. Keep backups of your saves.",
    "Rights of the original authors. Each mod listed here is the work of its original author, who retains "
        .. "all rights in it, including any license or permission terms the author published. Each tab names "
        .. "the original mod and its author. The original authors are not affiliated with mwsuite or with "
        .. "this tool, have not reviewed or endorsed these conversions, and are not responsible for them.",
    "No warranty. The conversions are provided \"as is\", without warranty of any kind, express or "
        .. "implied. You use them at your own risk.",
    "Support. Please do not contact the original authors about problems with a converted mod. "
        .. "Support is provided by dej (dejunai) via the Nexus Mods forums.",
}

-- what a tab shows about the original mod
function C.about(m)
    local c = m.credits or {}
    return {
        title = c.title or m.title or m.name,
        author = c.author or "unknown",
        url = c.url,
        license = c.license,
    }
end

function C.aboutLines(m)
    local a = C.about(m)
    local lines = { "Original mod: " .. a.title, "Original author: " .. a.author }
    if a.url then lines[#lines + 1] = "Original page: " .. a.url end
    if a.license then lines[#lines + 1] = "Original license: " .. a.license end
    lines[#lines + 1] = C.SUPPORT
    return lines
end

function C.sorted(mods)
    local list = {}
    for _, m in ipairs(mods) do list[#list + 1] = m end
    table.sort(list, function(x, y)
        local a, b = C.about(x).title:lower(), C.about(y).title:lower()
        if a ~= b then return a < b end
        return x.name < y.name
    end)
    return list
end

-- Build and register the one template. addTab(template, m) -> summary; saveMod(m) on close.
-- Returns { [m.name] = summary } and the template.
function C.build(mods, addTab, saveMod)
    local template = mwse.mcm.createTemplate({ name = C.NAME })
    template.onClose = function()
        for _, m in ipairs(mods) do saveMod(m) end
    end
    local intro = template:createSideBarPage({ label = C.DISCLAIMER_LABEL, description = C.DISCLAIMER[1] })
    if intro.sidebar then intro.sidebar:createInfo({ text = C.SUPPORT }) end
    for _, para in ipairs(C.DISCLAIMER) do intro:createInfo({ text = para }) end
    local summaries = {}
    for _, m in ipairs(C.sorted(mods)) do
        local ok, res = pcall(addTab, template, m, C.aboutLines(m))
        summaries[m.name] = ok and res or { error = tostring(res) }
        if not ok then mwse.log("[omwcompat] tab for %s failed: %s", m.name, tostring(res)) end
    end
    template:register()
    return summaries, template
end

return C
