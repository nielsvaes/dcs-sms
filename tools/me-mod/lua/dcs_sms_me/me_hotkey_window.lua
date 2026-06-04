-- me_hotkey_window.lua — the ME Hotkeys tool window.
--
-- sms_window chrome + a Grid (Action | Binding). Categories render as
-- non-interactive group rows. Clicking a binding row starts capture: a small
-- modal overlay that grabs the next chord via Gui.AddKeyboardCallback and the
-- shared match_chord matcher. Ctrl+click a row resets it to its default. A
-- reset glyph (↩) marks any binding changed from its default, and a "Reset all"
-- footer button clears every override.
--
-- Verified by manual smoke (docs/release-gate/me-mod-smoke.md), not unit tests.
-- This module requires real dxgui widgets at the top (exactly like
-- prefab_manager.lua), so it is NOT loaded by the standalone test VM.
--
-- Grid API note: the dxgui Grid widget is row/column-cell based, mirroring
-- prefab_manager.lua's real usage — Grid.new() + insertColumn(width, headerCell)
-- + insertRow(nil) + setCell(col, row, widget) + removeAllRows() + selectRow()
-- + getSelectedRow() + getMouseCursorColumnRow() + addSelectRowCallback() and
-- an onMouseDown override (Grid's built-in mouse handler does NOT auto-select).
-- Every grid call is pcall-guarded so a method mismatch degrades to an empty
-- grid rather than crashing the window.

local Static;        do local ok, m = pcall(require, 'Static');        if ok then Static        = m end end
local Button;        do local ok, m = pcall(require, 'Button');        if ok then Button        = m end end
local Window;        do local ok, m = pcall(require, 'Window');        if ok then Window        = m end end
local Skin;          do local ok, m = pcall(require, 'Skin');          if ok then Skin          = m end end
local Gui;           do local ok, m = pcall(require, 'dxgui');         if ok then Gui           = m end end
local Grid;          do local ok, m = pcall(require, 'Grid');          if ok then Grid          = m end end
local GridHeaderCell;do local ok, m = pcall(require, 'GridHeaderCell');if ok then GridHeaderCell= m end end

local dtc_skins;     do local ok, m = pcall(require, 'dcs_sms_me.dtc_skins'); if ok then dtc_skins = m end end

local sms_window = require('dcs_sms_me.sms_window')
local backend    = require('dcs_sms_me.me_hotkey_backend')

local M = {}
local W = { sms_window = nil, grid = nil, _row_action = nil }

-- Lazy facade require — me_hotkeys.lua (the facade) is created in a later
-- task and itself never touches dxgui at load. Requiring it at call time keeps
-- this module loadable on the menu-click path even before the facade exists.
local function facade()
    return require('dcs_sms_me.me_hotkeys')
end

-- Apply a skin by name, mirroring prefab_manager.lua's resolver: DTC-dialog
-- skins (dtc_button / dtc_grid / dtc_grid_header / dtc_separator) come from
-- dtc_skins.lua, everything else from the Skin module. Failures degrade
-- silently so the widget keeps its default skin.
local function try_skin(widget, skin_name)
    pcall(function()
        if not (widget and widget.setSkin) then return end
        local s
        if     skin_name == 'dtc_button'      then s = dtc_skins and dtc_skins.button()
        elseif skin_name == 'dtc_grid'        then s = dtc_skins and dtc_skins.grid()
        elseif skin_name == 'dtc_grid_header' then s = dtc_skins and dtc_skins.grid_header()
        elseif skin_name == 'dtc_separator'   then s = dtc_skins and dtc_skins.separator()
        else
            local fn = Skin and Skin[skin_name]
            if not fn then return end
            s = fn()
        end
        if s then widget:setSkin(s) end
    end)
end

-- Build a Static cell widget for a Grid cell, matching prefab_manager's
-- make_cell idiom (Grid cells are widgets, not bare text).
local function make_cell(text, tooltip)
    local s = Static.new(tostring(text or ''))
    try_skin(s, 'staticSkin_ME')
    if tooltip and s.setTooltipText then
        pcall(function() s:setTooltipText(tostring(tooltip)) end)
    end
    return s
end

-- Capture overlay: grab the next chord, then call on_done(chord) or on_cancel().
local function capture_chord(on_done, on_cancel)
    local screen_w, screen_h = 1920, 1080
    pcall(function() screen_w, screen_h = Gui.GetWindowSize() end)
    local w, h = 360, 120
    local overlay, cb
    local state = backend.new_chord_state()
    local function teardown()
        pcall(function() if cb and Gui and Gui.RemoveKeyboardCallback then Gui.RemoveKeyboardCallback(cb) end end)
        pcall(function() if overlay and overlay.setVisible then overlay:setVisible(false) end end)
    end
    pcall(function()
        overlay = Window.new((screen_w - w) / 2, (screen_h - h) / 2, w, h, 'Press a key…')
        overlay:setSkin((Skin.windowSkinME and Skin.windowSkinME()) or Skin.windowSkin())
        overlay:setVisible(true); overlay:setZOrder(260)
        local lbl = Static.new()
        lbl:setBounds(16, 16, w - 32, 40)
        lbl:setText('Press a key (or Esc to cancel)…')
        try_skin(lbl, 'staticSkin_ME')
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

-- Rebuild the grid body from engine:rows(). Renders a category header row
-- (non-interactive) before each category's actions. Grid is 0-indexed for
-- both columns and rows.
local function refresh()
    if not (W.sms_window and W.grid) then return end
    local ok_eng, eng = pcall(function() return facade().engine() end)
    if not ok_eng or not eng then return end
    local rows = eng:rows()
    pcall(function()
        if W.grid.removeAllRows then W.grid:removeAllRows() end
    end)
    W._row_action = {}
    local r = 0
    local last_cat
    for _, row in ipairs(rows) do
        if row.category ~= last_cat then
            pcall(function()
                W.grid:insertRow(nil)
                W.grid:setCell(0, r, make_cell('— ' .. tostring(row.category) .. ' —'))
                W.grid:setCell(1, r, make_cell(''))
            end)
            -- category rows have no action id (W._row_action[r] stays nil)
            last_cat = row.category; r = r + 1
        end
        local key_text = row.current_key or '(unbound)'
        if row.modified then key_text = key_text .. '  ↩' end
        pcall(function()
            W.grid:insertRow(nil)
            W.grid:setCell(0, r, make_cell(row.label, row.label))
            W.grid:setCell(1, r, make_cell(key_text))
        end)
        W._row_action[r] = row.id
        r = r + 1
    end
end

-- Grid row click handler. row_index is the 0-based grid row. Single click =
-- capture a new chord for that row's action; Ctrl+click = reset it to default.
-- Category header rows (no action id) are ignored.
local function on_row_click(row_index, ctrl_held)
    local id = W._row_action and W._row_action[row_index]
    if not id then return end
    local ok_eng, eng = pcall(function() return facade().engine() end)
    if not ok_eng or not eng then return end
    if ctrl_held then
        eng:reset(id)
        pcall(function() facade().persist() end)
        refresh()
        W.sms_window:flash_status('Reset ' .. id, 'info')
        return
    end
    capture_chord(function(chord)
        local res = eng:bind(id, chord)
        pcall(function() facade().persist() end)
        refresh()
        local note = 'Bound ' .. id .. ' → ' .. chord
        if res and res.displaced and res.displaced.label then
            note = note .. ' (took it from ' .. res.displaced.label .. ')'
        elseif res and res.displaced and res.displaced.ed then
            note = note .. ' (ED: ' .. res.displaced.ed .. ')'
        end
        W.sms_window:flash_status(note, 'success')
    end, function() end)
end

-- Read the current Ctrl hold-state (best-effort; guarded). Returns false if
-- dxgui doesn't expose isKeyPressed on this build.
local function ctrl_pressed()
    local ctrl = false
    pcall(function()
        if Gui and Gui.isKeyPressed then
            ctrl = Gui.isKeyPressed('LCtrl') or Gui.isKeyPressed('RCtrl') or false
        end
    end)
    return ctrl
end

local function build_body()
    local raw = W.sms_window:raw()
    local x, y, w, h = W.sms_window:get_content_bounds()

    if Grid and GridHeaderCell then
        W.grid = Grid.new()
        try_skin(W.grid, 'dtc_grid')

        -- Two columns: Action (wider) | Binding. insertColumn(width, headerCell)
        -- mirrors prefab_manager.lua's real Grid column setup.
        local cols = {
            { label = 'Action',  width = math.floor(w * 0.6) },
            { label = 'Binding', width = math.max(60, w - math.floor(w * 0.6)) },
        }
        for _, c in ipairs(cols) do
            local hc = GridHeaderCell.new()
            try_skin(hc, 'dtc_grid_header')
            if hc.setText then pcall(function() hc:setText(c.label) end) end
            pcall(function() W.grid:insertColumn(c.width, hc) end)
        end

        pcall(function()
            if W.grid.setBounds then W.grid:setBounds(x, y, w, h - 40) end
        end)

        -- Grid's built-in onMouseDown is empty, so clicks don't change the
        -- selected row — override it to select the clicked row and dispatch
        -- to on_row_click (Ctrl+click = reset). Mirrors prefab_manager.lua.
        pcall(function()
            W.grid.onMouseDown = function(self, mx, my, button)
                if button ~= 1 then return end
                pcall(function()
                    local _, row = self:getMouseCursorColumnRow(mx, my)
                    if not (row and row >= 0) then return end
                    self:selectRow(row)
                    on_row_click(row, ctrl_pressed())
                end)
            end
        end)
        -- Also wire the select-row callback (fires on keyboard arrow-key
        -- changes). It only updates selection; the actual capture/reset is
        -- driven by clicks via onMouseDown above, so this is a no-op hook
        -- kept for parity / future use.
        pcall(function()
            if W.grid.addSelectRowCallback then
                W.grid:addSelectRowCallback(function() end)
            end
        end)

        pcall(function() if raw and raw.insertWidget then raw:insertWidget(W.grid) end end)
    else
        -- Fallback: minimal Static so the window still constructs in
        -- environments missing Grid (older dxgui builds, test VMs).
        local lbl = Static.new()
        pcall(function() if lbl.setBounds then lbl:setBounds(x, y, w, 20) end end)
        if lbl.setText then lbl:setText('Grid widget unavailable on this DCS build.') end
        try_skin(lbl, 'staticSkin_ME')
        W.grid = nil
        pcall(function() if raw and raw.insertWidget then raw:insertWidget(lbl) end end)
    end

    W.reset_all_btn = Button.new()
    pcall(function() if W.reset_all_btn.setBounds then W.reset_all_btn:setBounds(x, y + h - 30, 120, 22) end end)
    if W.reset_all_btn.setText then W.reset_all_btn:setText('Reset all') end
    try_skin(W.reset_all_btn, 'dtc_button')
    if W.reset_all_btn.addChangeCallback then
        W.reset_all_btn:addChangeCallback(function()
            local ok_eng, eng = pcall(function() return facade().engine() end)
            if ok_eng and eng then eng:reset_all() end
            pcall(function() facade().persist() end)
            refresh()
            W.sms_window:flash_status('All hotkeys reset to defaults.', 'info')
        end)
    end
    pcall(function() if raw and raw.insertWidget then raw:insertWidget(W.reset_all_btn) end end)
end

function M.show()
    if W.sms_window then W.sms_window:show(); refresh(); return end
    W.sms_window = sms_window.new({
        title = 'ME Hotkeys',
        size = { w = 460, h = 520 },
        min_size = { w = 380, h = 320 },
        persist_across_new_mission = true,  -- hotkeys aren't mission-bound
        disable_undo_hotkey = true,
    })
    if not W.sms_window then return end
    build_body()
    W.sms_window:show()
    W.sms_window:set_status('Click a binding to capture · Ctrl+click a row to reset', 'info')
    refresh()
end

function M.hide() if W.sms_window then W.sms_window:hide() end end

function M.toggle()
    if W.sms_window then W.sms_window:toggle(); refresh() else M.show() end
end

return M
