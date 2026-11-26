-- omwcompat.player: modules for PLAYER scripts (openmw.ui, openmw.ambient, openmw.input), the
-- keyboard events they receive (onKeyPress / onKeyRelease) and openmw.core.sound.
-- Each function maps to one MWSE call; differences are listed in the manifest notes and GAPS.md.
--   ui.showMessage(msg)              -> tes3.messageBox(msg)  (showInDialogue is ignored)
--   ambient.playSound / playSoundFile / stopSound / isSoundPlaying / say
--                                    -> tes3.playSound / tes3.removeSound / tes3.getSoundPlaying /
--                                       tes3.say on the player (MWSE has no listener-relative 2D sound)
--   input.KEY, isKeyPressed, isShiftPressed/isCtrlPressed/isAltPressed/isSuperPressed, getKeyName
--                                    -> DirectInput scan codes through inputController:isKeyDown
--   core.sound.playSound3d / playSoundFile3d / stopSound3d / isSoundPlaying / say / stopSay / isEnabled
--                                    -> tes3.playSound / removeSound / getSoundPlaying / say on the object
-- MIT, Copyright (c) 2026 dej (dejunai).
local M = {}
local rt, objects

function M.init(runtime, objs) rt, objects = runtime, objs end

---------------------------------------------------------------- key codes
-- OpenMW key codes are SDL scancodes; MWSE reports DirectInput scan codes. Pairs: name, SDL, DIK.
local KEYS = {
    { "A", 4, 30 }, { "B", 5, 48 }, { "C", 6, 46 }, { "D", 7, 32 }, { "E", 8, 18 }, { "F", 9, 33 }, { "G", 10, 34 },
    { "H", 11, 35 }, { "I", 12, 23 }, { "J", 13, 36 }, { "K", 14, 37 }, { "L", 15, 38 }, { "M", 16, 50 }, { "N", 17, 49 },
    { "O", 18, 24 }, { "P", 19, 25 }, { "Q", 20, 16 }, { "R", 21, 19 }, { "S", 22, 31 }, { "T", 23, 20 }, { "U", 24, 22 },
    { "V", 25, 47 }, { "W", 26, 17 }, { "X", 27, 45 }, { "Y", 28, 21 }, { "Z", 29, 44 },
    { "_1", 30, 2 }, { "_2", 31, 3 }, { "_3", 32, 4 }, { "_4", 33, 5 }, { "_5", 34, 6 }, { "_6", 35, 7 }, { "_7", 36, 8 },
    { "_8", 37, 9 }, { "_9", 38, 10 }, { "_0", 39, 11 },
    { "Enter", 40, 28 }, { "Escape", 41, 1 }, { "Backspace", 42, 14 }, { "Tab", 43, 15 }, { "Space", 44, 57 },
    { "Minus", 45, 12 }, { "Equals", 46, 13 }, { "LeftBracket", 47, 26 }, { "RightBracket", 48, 27 },
    { "BackSlash", 49, 43 }, { "Semicolon", 51, 39 }, { "Apostrophe", 52, 40 }, { "Comma", 54, 51 },
    { "Period", 55, 52 }, { "Slash", 56, 53 }, { "CapsLock", 57, 58 },
    { "F1", 58, 59 }, { "F2", 59, 60 }, { "F3", 60, 61 }, { "F4", 61, 62 }, { "F5", 62, 63 }, { "F6", 63, 64 },
    { "F7", 64, 65 }, { "F8", 65, 66 }, { "F9", 66, 67 }, { "F10", 67, 68 }, { "F11", 68, 87 }, { "F12", 69, 88 },
    { "PrintScreen", 70, 183 }, { "ScrollLock", 71, 70 }, { "Pause", 72, 197 }, { "Insert", 73, 210 },
    { "Home", 74, 199 }, { "PageUp", 75, 201 }, { "Delete", 76, 211 }, { "End", 77, 207 }, { "PageDown", 78, 209 },
    { "RightArrow", 79, 205 }, { "LeftArrow", 80, 203 }, { "DownArrow", 81, 208 }, { "UpArrow", 82, 200 },
    { "NumLock", 83, 69 }, { "NP_Divide", 84, 181 }, { "NP_Multiply", 85, 55 }, { "NP_Minus", 86, 74 },
    { "NP_Plus", 87, 78 }, { "NP_Enter", 88, 156 }, { "NP_1", 89, 79 }, { "NP_2", 90, 80 }, { "NP_3", 91, 81 },
    { "NP_4", 92, 75 }, { "NP_5", 93, 76 }, { "NP_6", 94, 77 }, { "NP_7", 95, 71 }, { "NP_8", 96, 72 },
    { "NP_9", 97, 73 }, { "NP_0", 98, 82 }, { "NP_Delete", 99, 83 },
    { "LeftCtrl", 224, 29 }, { "LeftShift", 225, 42 }, { "LeftAlt", 226, 56 }, { "LeftSuper", 227, 219 },
    { "RightCtrl", 228, 157 }, { "RightShift", 229, 54 }, { "RightAlt", 230, 184 }, { "RightSuper", 231, 220 },
}
local KEY, SDL_OF_DIK, DIK_OF_SDL, NAME_OF_SDL = {}, {}, {}, {}
for _, k in ipairs(KEYS) do
    KEY[k[1]] = k[2]
    SDL_OF_DIK[k[3]] = k[2]
    DIK_OF_SDL[k[2]] = k[3]
    NAME_OF_SDL[k[2]] = k[1]:gsub("^_", ""):gsub("^NP_", "Keypad ")
end
M.KEY, M.SDL_OF_DIK, M.DIK_OF_SDL = KEY, SDL_OF_DIK, DIK_OF_SDL
local SYMBOLS = { Space = " ", Minus = "-", Equals = "=", LeftBracket = "[", RightBracket = "]", BackSlash = "\\",
    Semicolon = ";", Apostrophe = "'", Comma = ",", Period = ".", Slash = "/" }

local function keyDown(dik)
    local ic = tes3.worldController and tes3.worldController.inputController
    if not ic or not dik then return false end
    local ok, v = pcall(function() return ic:isKeyDown(dik) end)
    return ok and v == true
end

-- the KeyboardEvent OpenMW passes to onKeyPress / onKeyRelease, from an MWSE keyDown/keyUp event
function M.keyEvent(e)
    local code = SDL_OF_DIK[e.keyCode]
    if not code then return nil end
    local name = NAME_OF_SDL[code]
    local raw = nil
    for _, k in ipairs(KEYS) do if k[2] == code then raw = k[1] end end
    local symbol = ""
    if raw and #raw == 1 then symbol = raw:lower()
    elseif raw and raw:match("^_%d$") then symbol = raw:sub(2)
    elseif raw and SYMBOLS[raw] then symbol = SYMBOLS[raw] end
    return { code = code, symbol = symbol, withShift = e.isShiftDown == true, withCtrl = e.isControlDown == true,
        withAlt = e.isAltDown == true, withSuper = e.isSuperDown == true, _name = name }
end

---------------------------------------------------------------- sound helpers
-- OpenMW VFS paths ("sound/x/y.wav") -> MWSE soundPath (relative to Data Files\Sound)
local function soundPath(p)
    p = tostring(p):gsub("/", "\\")
    return (p:gsub("^[Ss][Oo][Uu][Nn][Dd]\\", ""))
end
local function musicPath(p)
    p = tostring(p):gsub("/", "\\")
    return (p:gsub("^[Mm][Uu][Ss][Ii][Cc]\\", ""))
end
local function opts(o, t)
    o = o or {}
    t.volume, t.pitch, t.loop = o.volume, o.pitch, o.loop
    return t
end
local function refArg(obj, fn)
    local ref = obj and objects.refOf(obj)
    if not ref then error("core.sound." .. fn .. ": invalid object", 3) end
    return ref
end

---------------------------------------------------------------- modules
function M.uiModule(proxy)
    return proxy("openmw.ui", {
        showMessage = function(msg, options)
            tes3.messageBox(tostring(msg))
        end,
    })
end

function M.ambientModule(proxy)
    return proxy("openmw.ambient", {
        playSound = function(id, o) tes3.playSound(opts(o, { sound = id })) end,
        playSoundFile = function(path, o) tes3.playSound(opts(o, { soundPath = soundPath(path) })) end,
        stopSound = function(id) tes3.removeSound({ sound = id, reference = tes3.player }) end,
        isSoundPlaying = function(id) return tes3.getSoundPlaying({ sound = id, reference = tes3.player }) == true end,
        say = function(path, text)
            tes3.say({ reference = tes3.player, soundPath = soundPath(path), subtitle = text })
        end,
        streamMusic = function(path) tes3.streamMusic({ path = musicPath(path) }) end,
    })
end

function M.inputModule(proxy)
    return proxy("openmw.input", {
        KEY = KEY,
        isKeyPressed = function(code) return keyDown(DIK_OF_SDL[code]) end,
        isShiftPressed = function() return keyDown(42) or keyDown(54) end,
        isCtrlPressed = function() return keyDown(29) or keyDown(157) end,
        isAltPressed = function() return keyDown(56) or keyDown(184) end,
        isSuperPressed = function() return keyDown(219) or keyDown(220) end,
        getKeyName = function(code) return NAME_OF_SDL[code] or "" end,
    })
end

function M.soundModule(proxy)
    return proxy("openmw.core.sound", {
        isEnabled = function() return true end,
        playSound3d = function(id, obj, o) tes3.playSound(opts(o, { sound = id, reference = refArg(obj, "playSound3d") })) end,
        playSoundFile3d = function(path, obj, o)
            tes3.playSound(opts(o, { soundPath = soundPath(path), reference = refArg(obj, "playSoundFile3d") }))
        end,
        stopSound3d = function(id, obj) tes3.removeSound({ sound = id, reference = refArg(obj, "stopSound3d") }) end,
        isSoundPlaying = function(id, obj)
            return tes3.getSoundPlaying({ sound = id, reference = refArg(obj, "isSoundPlaying") }) == true
        end,
        say = function(path, obj, text)
            tes3.say({ reference = refArg(obj, "say"), soundPath = soundPath(path), subtitle = text })
        end,
        -- MWSE has no "stop voice" call: removeSound without a sound stops every sound on the object
        stopSay = function(path, obj)
            if obj == nil and type(path) == "table" then obj = path end
            tes3.removeSound({ reference = refArg(obj, "stopSay") })
        end,
    })
end

return M
