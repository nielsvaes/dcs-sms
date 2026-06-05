-- me_hotkey_script_editor.lua — create/edit a single user hotkey script.
--
-- sms_window chrome + a name field, a hotkey field (Capture/Clear via the shared
-- capture overlay), a multiline code EditBox, a Run button (compile + pcall now,
-- result/error shown inline), and Save/Delete/Cancel. Persists through
-- me_hotkey_scripts and asks the facade to rebuild the engine + repaint the list.
--
-- Verified by manual smoke, not unit tests (requires real dxgui widgets).

local Static; do local ok, m = pcall(require, 'Static'); if ok then Static = m end end
local Button; do local ok, m = pcall(require, 'Button'); if ok then Button = m end end
local EditBox;do local ok, m = pcall(require, 'EditBox');if ok then EditBox= m end end
local Skin;   do local ok, m = pcall(require, 'Skin');   if ok then Skin   = m end end

local dtc_skins; do local ok, m = pcall(require, 'dcs_sms_me.dtc_skins'); if ok then dtc_skins = m end end

local sms_window  = require('dcs_sms_me.sms_window')
local scripts_mod = require('dcs_sms_me.me_hotkey_scripts')
local capture     = require('dcs_sms_me.me_hotkey_capture')
local sms_scrollbars = require('dcs_sms_me.sms_scrollbars')

local M = {}
local W = {}  -- single editor instance

local function facade() return require('dcs_sms_me.me_hotkeys') end

local function try_skin(widget, skin_name)
    pcall(function()
        if not (widget and widget.setSkin) then return end
        local s
        if     skin_name == 'dtc_button' then s = dtc_skins and dtc_skins.button()
        else
            local fn = Skin and Skin[skin_name]
            if fn then s = fn() end
        end
        if s then widget:setSkin(s) end
    end)
end

-- Skin for the code editor: the shared themed editbox skin (monospace font +
-- the main window's thin Unit-List scrollbars). themed_editbox_skin returns a
-- fresh editBoxSkin_ME() clone per call, so this is widget-local. The call-site
-- ordering (setMultiline BEFORE setSkin) still matters and lives at the EditBox
-- construction below — setMultiline rebuilds the scrollbar widgets.
local function apply_code_skin(widget)
    if not (widget and widget.setSkin) then return end
    local s = sms_scrollbars.themed_editbox_skin({ mono = true })
    if s then pcall(function() widget:setSkin(s) end) end
end

-- Reposition every widget to the current content rect. Wired to sms_window's
-- on_resize so the dialog tracks window resizes (single source of layout truth).
local function relayout(x, y, w, h)
    local function set(widget, bx, by, bw, bh)
        if widget then pcall(function() widget:setBounds(bx, by, bw, bh) end) end
    end
    set(W.name,        x,           y,          w,       22)
    set(W.key_lbl,     x,           y + 30,     w - 180, 22)
    set(W.capture_btn, x + w - 170, y + 30,     90,      22)
    set(W.clear_btn,   x + w - 76,  y + 30,     76,      22)
    set(W.code,        x,           y + 60,     w,       h - 120)
    set(W.run_btn,     x,           y + h - 28, 70,      22)
    set(W.save_btn,    x + w - 240, y + h - 28, 74,      22)
    set(W.del_btn,     x + w - 160, y + h - 28, 74,      22)
    set(W.cancel_btn,  x + w - 80,  y + h - 28, 80,      22)
end

local function disp_key(k)
    if not k or k == '' then return '(none)' end
    return tostring(k):upper()
end

local function set_result(text, sev)
    if W.win then pcall(function() W.win:flash_status(tostring(text), sev or 'info') end) end
end

local function refresh_key_label()
    if W.key_lbl and W.key_lbl.setText then pcall(function() W.key_lbl:setText('Hotkey:  ' .. disp_key(W.key)) end) end
end

local function close()
    capture.teardown()
    if W.win then pcall(function() W.win:hide() end) end
end

local function run_now()
    local code = (W.code and W.code.getText and W.code:getText()) or ''
    local f, err = (loadstring or load)(code)
    if not f then set_result('compile error: ' .. tostring(err), 'error'); return end
    local ok, rv = pcall(f)
    if ok then set_result('→ ' .. tostring(rv), 'success')
    else set_result('error: ' .. tostring(rv), 'error') end
end

local function save()
    local name = (W.name and W.name.getText and W.name:getText()) or ''
    local code = (W.code and W.code.getText and W.code:getText()) or ''
    if name == '' then set_result('Name is required.', 'warning'); return end
    local ok, cerr = scripts_mod.compile(code)
    if not ok then set_result('compile error: ' .. tostring(cerr), 'error'); return end

    local list = scripts_mod.load()
    if W.edit_id then
        list = scripts_mod.update(list, W.edit_id, { name = name, key = W.key, code = code })
    else
        local new_id
        list, new_id = scripts_mod.add(list, { name = name, key = W.key, code = code })
        W.edit_id = new_id
    end
    scripts_mod.save(list)

    -- Warn (but don't block) if another action already holds this key.
    if W.key ~= '' then
        pcall(function()
            local holder = facade().engine():key_holder(W.key)
            if holder and holder ~= W.edit_id then
                log.write('sms.me', log.WARNING, 'script key ' .. W.key .. ' also held by ' .. tostring(holder))
            end
        end)
    end

    facade().scripts_changed()
    close()
end

local function delete_script()
    if not W.edit_id then close(); return end
    local list = scripts_mod.remove(scripts_mod.load(), W.edit_id)
    scripts_mod.save(list)
    facade().scripts_changed()
    close()
end

function M.open(id)
    capture.teardown()
    local list = scripts_mod.load()
    local s = id and scripts_mod.get(list, id) or nil
    W.edit_id = s and s.id or nil
    W.key = (s and s.key) or ''

    -- Rebuild the window fresh each open (simplest; scripts editing is infrequent).
    if W.win then pcall(function() W.win:hide() end); W.win = nil end
    W.win = sms_window.new({
        title = W.edit_id and 'Edit Script' or 'New Script',
        size = { w = 540, h = 480 },
        min_size = { w = 440, h = 340 },
        persist_across_new_mission = true,
        disable_undo_hotkey = true,
        on_resize = function(_, rx, ry, rw, rh) relayout(rx, ry, rw, rh) end,
    })
    if not W.win then return end
    local raw = W.win:raw()
    local x, y, w, h = W.win:get_content_bounds()

    -- Name field
    W.name = EditBox.new()
    try_skin(W.name, 'editBoxSkin_ME')
    pcall(function() W.name:setText((s and s.name) or '') end)
    pcall(function() if W.name.setHintText then W.name:setHintText('Script name') end end)
    pcall(function() raw:insertWidget(W.name) end)

    -- Hotkey row: label + Capture + Clear
    W.key_lbl = Static.new()
    try_skin(W.key_lbl, 'staticSkin_ME')
    pcall(function() raw:insertWidget(W.key_lbl) end)
    refresh_key_label()

    W.capture_btn = Button.new()
    pcall(function() W.capture_btn:setText('Capture') end)
    try_skin(W.capture_btn, 'dtc_button')
    if W.capture_btn.addChangeCallback then
        W.capture_btn:addChangeCallback(function()
            capture.capture(function(chord) W.key = chord; refresh_key_label() end, function() end)
        end)
    end
    pcall(function() raw:insertWidget(W.capture_btn) end)

    W.clear_btn = Button.new()
    pcall(function() W.clear_btn:setText('Clear') end)
    try_skin(W.clear_btn, 'dtc_button')
    if W.clear_btn.addChangeCallback then
        W.clear_btn:addChangeCallback(function() W.key = ''; refresh_key_label() end)
    end
    pcall(function() raw:insertWidget(W.clear_btn) end)

    -- Code: multiline EditBox (monospace + main-window scrollbars). Set multiline
    -- FIRST — it rebuilds the scrollbar widgets, so the skin must be applied after
    -- or our custom scrollbars get wiped by the default ones.
    W.code = EditBox.new()
    pcall(function() if W.code.setMultiline then W.code:setMultiline(true) end end)
    pcall(function() if W.code.setTextWrapping then W.code:setTextWrapping(false) end end)
    apply_code_skin(W.code)
    pcall(function() W.code:setText((s and s.code) or '') end)
    pcall(function() if W.code.setHintText then W.code:setHintText('-- Lua, runs in the ME GUI env') end end)
    pcall(function() raw:insertWidget(W.code) end)

    -- Bottom row: Run | (spacer) | Save / Delete / Cancel
    W.run_btn = Button.new()
    pcall(function() W.run_btn:setText('Run') end)
    try_skin(W.run_btn, 'dtc_button')
    if W.run_btn.addChangeCallback then W.run_btn:addChangeCallback(run_now) end
    pcall(function() raw:insertWidget(W.run_btn) end)

    W.save_btn = Button.new()
    pcall(function() W.save_btn:setText('Save') end)
    try_skin(W.save_btn, 'dtc_button')
    if W.save_btn.addChangeCallback then W.save_btn:addChangeCallback(save) end
    pcall(function() raw:insertWidget(W.save_btn) end)

    W.del_btn = Button.new()
    pcall(function() W.del_btn:setText('Delete') end)
    try_skin(W.del_btn, 'dtc_button')
    if W.del_btn.addChangeCallback then W.del_btn:addChangeCallback(delete_script) end
    pcall(function() if W.del_btn.setVisible then W.del_btn:setVisible(W.edit_id ~= nil) end end)
    pcall(function() raw:insertWidget(W.del_btn) end)

    W.cancel_btn = Button.new()
    pcall(function() W.cancel_btn:setText('Cancel') end)
    try_skin(W.cancel_btn, 'dtc_button')
    if W.cancel_btn.addChangeCallback then W.cancel_btn:addChangeCallback(close) end
    pcall(function() raw:insertWidget(W.cancel_btn) end)

    -- Initial layout (and every resize hereafter via on_resize).
    relayout(x, y, w, h)
    W.win:show()
    W.win:set_status(W.edit_id and 'Editing script · Run to test · Save to apply' or 'New script · Run to test · Save to apply', 'info')
end

function M.close() close() end

return M
