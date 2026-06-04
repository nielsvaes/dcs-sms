-- me_hotkey_backend.lua — the dxgui half of the hotkey engine.
--
-- Two interchangeable backends behind { attach(key,fn)->token, detach(key,token) }:
--   perkey  — attaches to the toolbar window via addHotKeyCallback (ED's own
--             ME-wide hotkey receiver). token = fn (needed by removeHotKeyCallback).
--   global  — a single Gui.AddKeyboardCallback dispatcher consulting an internal
--             key->fn map; tracks modifier hold-state and matches chords itself.
--
-- The pure chord matcher (new_chord_state / match_chord) is shared by the
-- global backend and the window's capture overlay, and is unit-tested.

local M = {}

-- ---- pure chord matcher ----

-- Keyed by lower-cased key name. DCS's keyboard callback (and KeyNames.txt)
-- spell the modifiers "left shift" / "right ctrl" / "alt gr" etc.; the short
-- LCtrl/LShift forms are kept as aliases for the unit tests and the global
-- backend. match_chord lower-cases the incoming name before the lookup, so any
-- casing resolves.
local MODIFIERS = {
    ['left ctrl']  = 'Ctrl',  ['right ctrl']  = 'Ctrl',
    ['left shift'] = 'Shift', ['right shift'] = 'Shift',
    ['left alt']   = 'Alt',   ['right alt']   = 'Alt',  ['alt gr'] = 'Alt',
    -- short aliases
    lctrl = 'Ctrl', rctrl = 'Ctrl', lshift = 'Shift', rshift = 'Shift', lalt = 'Alt', ralt = 'Alt',
}

function M.new_chord_state()
    return { Ctrl = false, Shift = false, Alt = false }
end

-- Feed one key event. Returns a chord string ('Ctrl+Shift+r', 'm', …) on a
-- non-modifier key DOWN, else nil. A modifier key alone never yields a chord —
-- it only updates hold-state — so "Shift" can't be bound on its own. Modifier
-- order is canonical: Ctrl, Shift, Alt.
function M.match_chord(state, keyName, keyState)
    local lname = (type(keyName) == 'string') and keyName:lower() or keyName
    local mod = MODIFIERS[lname]
    if mod then
        state[mod] = (keyState == 'down')
        return nil
    end
    if keyState ~= 'down' then return nil end
    local prefix = ''
    if state.Ctrl  then prefix = prefix .. 'Ctrl+'  end
    if state.Shift then prefix = prefix .. 'Shift+' end
    if state.Alt   then prefix = prefix .. 'Alt+'   end
    return prefix .. keyName
end

-- ---- dxgui-bound backends (guarded so the module loads in the test VM) ----

local function toolbar_window()
    local w
    pcall(function() w = require('me_toolbar').window end)
    return w
end

local function make_perkey()
    return {
        attach = function(key, fn)
            local w = toolbar_window()
            if w and w.addHotKeyCallback then pcall(function() w:addHotKeyCallback(key, fn) end) end
            return fn  -- removeHotKeyCallback needs the original fn
        end,
        detach = function(key, token)
            local w = toolbar_window()
            if w and w.removeHotKeyCallback and token then
                pcall(function() w:removeHotKeyCallback(key, token) end)
            end
        end,
    }
end

local function make_global()
    local map = {}            -- normalized-chord -> fn
    local state = M.new_chord_state()
    local installed = false
    local function ensure_installed()
        if installed then return end
        pcall(function()
            local Gui = require('dxgui')
            if Gui and Gui.AddKeyboardCallback then
                Gui.AddKeyboardCallback(function(keyName, keyState)
                    local chord = M.match_chord(state, keyName, keyState)
                    if chord then
                        local fn = map[chord:lower()]
                        if fn then pcall(fn) end
                    end
                end)
                installed = true
            end
        end)
    end
    return {
        attach = function(key, fn) ensure_installed(); map[key:lower()] = fn; return key:lower() end,
        detach = function(key, token) map[(token or key):lower()] = nil end,
    }
end

function M.get(mode)
    if mode == 'global' then return make_global() end
    return make_perkey()
end

return M
