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

-- Lazy facade accessor for suspend/resume_bindings. Lazy (not a load-time
-- require) so there's no cycle — the facade pulls in the script editor, which
-- pulls in this module.
local function facade()
    local ok, m = pcall(require, 'dcs_sms_me.me_hotkeys')
    if ok then return m end
    return nil
end

local M = {}
M._teardown = nil

function M.capture(on_done, on_cancel)
    local screen_w, screen_h = 1920, 1080
    pcall(function() screen_w, screen_h = Gui.GetWindowSize() end)
    local w, h = 360, 120
    local overlay, cb
    local cstate = backend.new_capture_state()
    local done = false
    local function teardown()
        if done then return end
        done = true
        M._teardown = nil
        pcall(function() if cb and Gui and Gui.RemoveKeyboardCallback then Gui.RemoveKeyboardCallback(cb) end end)
        pcall(function() if overlay and overlay.setVisible then overlay:setVisible(false) end end)
        -- Re-attach the hotkeys we suspended for the capture (runs on every exit
        -- path: captured, Esc, window-closed, or force-teardown).
        pcall(function() local f = facade(); if f and f.resume_bindings then f.resume_bindings() end end)
    end
    M._teardown = teardown
    -- Suspend every live hotkey while the overlay is up so the key the user
    -- presses to assign a binding doesn't also fire its current action.
    pcall(function() local f = facade(); if f and f.suspend_bindings then f.suspend_bindings() end end)
    local registered = false
    local ok = pcall(function()
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
            -- Finalize on key-UP (see backend.capture_step) so the key the user
            -- presses to assign a binding doesn't also fire the action it gets
            -- bound to. Bindings stay suspended through the assigning key-down.
            local r = backend.capture_step(cstate, keyName, keyState)
            if r == 'cancel' then
                teardown(); pcall(on_cancel or function() end)
            elseif type(r) == 'string' then
                teardown(); pcall(function() on_done(r) end)
            end
        end
        if Gui and Gui.AddKeyboardCallback then Gui.AddKeyboardCallback(cb); registered = true end
    end)
    -- If the overlay or keyboard hook couldn't be set up, don't strand the
    -- hotkeys in the suspended state — tear down (which resumes) right away.
    if not (ok and registered) then teardown() end
end

-- Force-close any active capture overlay (no-op if none).
function M.teardown()
    if M._teardown then pcall(M._teardown) end
end

return M
