-- me_hotkey_capture.lua — the "press a key" chord-capture overlay, shared by the
-- ME Hotkeys window (rebinding a built-in action) and the script editor (its
-- hotkey field). Grabs the next chord via Gui.AddKeyboardCallback + the backend's
-- pure match_chord, then calls on_done(chord) or on_cancel().
--
-- A single capture is active at a time; M.teardown() force-closes a dangling
-- overlay (e.g. its host window was hidden mid-capture).

local Static; do local ok, m = pcall(require, 'Static'); if ok then Static = m end end
local Window; do local ok, m = pcall(require, 'Window'); if ok then Window = m end end
local Skin;   do local ok, m = pcall(require, 'Skin');   if ok then Skin   = m end end
local Gui;    do local ok, m = pcall(require, 'dxgui');  if ok then Gui    = m end end

local backend = require('dcs_sms_me.me_hotkey_backend')

local M = {}
M._teardown = nil

function M.capture(on_done, on_cancel)
    local screen_w, screen_h = 1920, 1080
    pcall(function() screen_w, screen_h = Gui.GetWindowSize() end)
    local w, h = 360, 120
    local overlay, cb
    local state = backend.new_chord_state()
    local done = false
    local function teardown()
        if done then return end
        done = true
        M._teardown = nil
        pcall(function() if cb and Gui and Gui.RemoveKeyboardCallback then Gui.RemoveKeyboardCallback(cb) end end)
        pcall(function() if overlay and overlay.setVisible then overlay:setVisible(false) end end)
    end
    M._teardown = teardown
    pcall(function()
        overlay = Window.new((screen_w - w) / 2, (screen_h - h) / 2, w, h, 'Press a key…')
        overlay:setSkin((Skin.windowSkinME and Skin.windowSkinME()) or Skin.windowSkin())
        overlay:setVisible(true); overlay:setZOrder(260)
        pcall(function() overlay.onClose = function() teardown(); pcall(on_cancel or function() end) end end)
        local lbl = Static.new()
        lbl:setBounds(16, 16, w - 32, 40)
        lbl:setText('Press a key (or Esc to cancel)…')
        pcall(function() if Skin and Skin.staticSkin_ME then lbl:setSkin(Skin.staticSkin_ME()) end end)
        overlay:insertWidget(lbl)
        cb = function(keyName, keyState)
            if keyName == 'escape' and keyState == 'down' then
                teardown(); pcall(on_cancel or function() end); return
            end
            local chord = backend.match_chord(state, keyName, keyState)
            if chord then teardown(); pcall(function() on_done(chord) end) end
        end
        if Gui and Gui.AddKeyboardCallback then Gui.AddKeyboardCallback(cb) end
    end)
end

-- Force-close any active capture overlay (no-op if none).
function M.teardown()
    if M._teardown then pcall(M._teardown) end
end

return M
