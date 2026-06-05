-- me_hotkey_window.lua — the ME Hotkeys tool window.
--
-- sms_window chrome + a two-column Grid (Action | Binding), mirroring the
-- Prefab Manager / Mass Edit table look. Rows are grouped under clickable
-- category header rows (Map/Selection, Object-add, Panel) that collapse/expand
-- the actions beneath them.
--
-- Interaction:
--   * click a category row  → collapse / expand that category
--   * single-click a row    → selects it (footer shows what's selected)
--   * double-click a row     → capture overlay grabs the next chord and rebinds
--   * "↩ Reset selected"     → reverts the selected row to its default
--   * "Reset all"            → reverts every override
--
-- A trailing "*" on the binding marks a row changed from its default. Collapse
-- state lives in W.collapsed and is preserved across re-renders (bind / reset).
--
-- Verified by manual smoke (docs/release-gate/me-mod-smoke.md), not unit tests:
-- this module requires real dxgui widgets at the top (exactly like
-- prefab_manager.lua), so it is NOT loaded by the standalone test VM.

local Static;        do local ok, m = pcall(require, 'Static');        if ok then Static        = m end end
local Button;        do local ok, m = pcall(require, 'Button');        if ok then Button        = m end end
local Window;        do local ok, m = pcall(require, 'Window');        if ok then Window        = m end end
local Skin;          do local ok, m = pcall(require, 'Skin');          if ok then Skin          = m end end
local Gui;           do local ok, m = pcall(require, 'dxgui');         if ok then Gui           = m end end
local Grid;          do local ok, m = pcall(require, 'Grid');          if ok then Grid          = m end end
local GridHeaderCell;do local ok, m = pcall(require, 'GridHeaderCell');if ok then GridHeaderCell= m end end

local dtc_skins; do local ok, m = pcall(require, 'dcs_sms_me.dtc_skins'); if ok then dtc_skins = m end end

local sms_window    = require('dcs_sms_me.sms_window')
local backend       = require('dcs_sms_me.me_hotkey_backend')
local actions       = require('dcs_sms_me.me_hotkey_actions')
local clearable_edit = require('dcs_sms_me.clearable_edit')
local capture       = require('dcs_sms_me.me_hotkey_capture')

local M = {}
local W = {
    sms_window  = nil,
    grid        = nil,
    search      = nil,  -- clearable_edit filter box
    filter_text = '',   -- live filter (matches label / category / bound key)
    collapsed   = {},   -- category name -> true when folded shut
    selected_id = nil,  -- currently-selected action id (drives Reset selected)
    _row_meta   = {},   -- grid row index -> { kind='cat', cat=… } | { kind='action', id=… }
}

local function facade()
    return require('dcs_sms_me.me_hotkeys')
end

local function eng()
    local ok, e = pcall(function() return facade().engine() end)
    if ok then return e end
    return nil
end

-- Apply a skin by name, mirroring prefab_manager.lua's resolver: DTC-dialog
-- skins come from dtc_skins.lua, everything else from the Skin module.
local function try_skin(widget, skin_name)
    pcall(function()
        if not (widget and widget.setSkin) then return end
        local s
        if     skin_name == 'dtc_button'      then s = dtc_skins and dtc_skins.button()
        elseif skin_name == 'dtc_grid'        then s = dtc_skins and dtc_skins.grid()
        elseif skin_name == 'dtc_grid_header' then s = dtc_skins and dtc_skins.grid_header()
        else
            local fn = Skin and Skin[skin_name]
            if not fn then return end
            s = fn()
        end
        if s then widget:setSkin(s) end
    end)
end

-- Cell text styling. The DejaVu condensed family ships regular / bold / oblique
-- variants in dxgui/skins/fonts, and the static skin exposes per-state
-- text.font / text.color (string form) + text.horzAlign.offset (pixel indent).
local FONT_REGULAR  = 'DejaVuLGCSansCondensed.ttf'
local FONT_BOLD     = 'DejaVuLGCSansCondensed-Bold.ttf'
local FONT_OBLIQUE  = 'DejaVuLGCSansCondensed-Oblique.ttf'
local COLOR_DEFAULT  = '0xc8c8c8ff'  -- stock light grey
local COLOR_CATEGORY = '0xffffffff'  -- brighter white for the bold headers
local COLOR_MODIFIED = '0xffc24dff'  -- amber — a binding changed from its default
local COLOR_DISABLED = '0x707070ff'  -- dim grey — action not yet available
local ACTION_INDENT  = 38            -- px the action rows sit right of the category
                                     -- (must clear the "▼ " glyph so they nest)

-- Per-"kind" overrides applied over a fresh staticSkin_ME() clone.
local CELL_STYLES = {
    default   = {},
    category  = { font = FONT_BOLD,    color = COLOR_CATEGORY },
    action    = { font = FONT_REGULAR, color = COLOR_DEFAULT,  offset = ACTION_INDENT },
    modified  = { font = FONT_OBLIQUE, color = COLOR_MODIFIED, offset = ACTION_INDENT },
    disabled  = { font = FONT_REGULAR, color = COLOR_DISABLED, offset = ACTION_INDENT },
}

-- Build a fresh static skin with the given kind's font/colour/indent baked in.
-- staticSkin_ME() returns a deep copy per call, so the mutations are
-- widget-local. Colours MUST stay string form or the skin engine drops them.
local function cell_skin(kind)
    local opts = CELL_STYLES[kind] or CELL_STYLES.default
    local s = Skin and Skin.staticSkin_ME and Skin.staticSkin_ME()
    if not (s and s.skinData and s.skinData.states) then return nil end
    for _, state in ipairs({ 'released', 'disabled' }) do
        local txt = s.skinData.states[state] and s.skinData.states[state][1] and s.skinData.states[state][1].text
        if txt then
            if opts.font  then txt.font  = opts.font  end
            if opts.color then txt.color = opts.color end
            if opts.offset and txt.horzAlign then txt.horzAlign.offset = opts.offset end
        end
    end
    return s
end

-- Grid cells are widgets, not bare text — same make_cell idiom as prefab_manager,
-- plus a `kind` that selects the font/colour/indent style.
local function make_cell(text, kind, tooltip)
    local s = Static.new(tostring(text or ''))
    local skin = cell_skin(kind)
    if skin then pcall(function() s:setSkin(skin) end) else try_skin(s, 'staticSkin_ME') end
    if tooltip and s.setTooltipText then
        pcall(function() s:setTooltipText(tostring(tooltip)) end)
    end
    return s
end

local function rows_by_id()
    local e, map = eng(), {}
    if not e then return map end
    for _, r in ipairs(e:rows()) do map[r.id] = r end
    return map
end

-- How a key is shown in the UI: always upper-cased (m → M, alt+y → ALT+Y), or
-- "(unbound)" when there's no key. Display-only — the stored/normalized key the
-- engine matches on is untouched.
local function disp_key(k)
    if not k or k == '' then return '(unbound)' end
    return tostring(k):upper()
end

-- Does a row match the active filter? Plain-text (case-insensitive) substring
-- against the label, the category, and the current bound key — so "save",
-- "file", "ctrl+s" or "shift" all narrow the list. Empty query matches all.
local function row_matches(row, q)
    if q == '' then return true end
    local hay = ((row.label or '') .. ' ' .. (row.category or '') .. ' ' ..
                 (row.current_key or '')):lower()
    return hay:find(q, 1, true) ~= nil
end

-- ---- status + render ----

local function set_hint()
    if not W.sms_window then return end
    if W.selected_id then
        local r = rows_by_id()[W.selected_id]
        local label = r and r.label or W.selected_id
        local key   = disp_key(r and r.current_key)
        W.sms_window:set_status(
            'Selected: ' .. label .. '  ·  ' .. key .. '   —  double-click to rebind, ↩ to reset', 'info')
    else
        W.sms_window:set_status(
            'Click a category to fold it · click a row to select · double-click to rebind', 'info')
    end
end

-- Rebuild the grid body from engine:rows(), honouring collapse state. Re-selects
-- the previously-selected action's row so the highlight survives a re-render.
local function render()
    if not W.grid then return end
    pcall(function() if W.grid.removeAllRows then W.grid:removeAllRows() end end)
    W._row_meta = {}
    local selected_row = nil
    local e = eng(); if not e then return end
    local rows = e:rows()
    local q = (W.filter_text or ''):lower()
    local filtering = q ~= ''
    local r = 0
    for _, cat in ipairs(actions.CATEGORIES) do
        -- Collect this category's matching rows first so an empty category is
        -- dropped entirely while a filter is active.
        local cat_rows = {}
        for _, row in ipairs(rows) do
            if row.category == cat and row_matches(row, q) then cat_rows[#cat_rows + 1] = row end
        end
        -- Hide a category with no rows: always for Scripts (it's empty until you
        -- add one), and for any category while a filter is active.
        local hide_empty = (#cat_rows == 0) and (filtering or cat == 'Scripts')
        if not hide_empty then
            -- While filtering, force-expand so matches inside a folded category
            -- still surface.
            local expanded = filtering or (not W.collapsed[cat])
            local glyph = expanded and '▼' or '▶'
            pcall(function()
                W.grid:insertRow(nil)
                W.grid:setCell(0, r, make_cell(glyph .. '  ' .. cat, 'category'))
                W.grid:setCell(1, r, make_cell('', 'default'))
            end)
            W._row_meta[r] = { kind = 'cat', cat = cat }
            r = r + 1
            if expanded then
                for _, row in ipairs(cat_rows) do
                    local style, key
                    if row.disabled then
                        style, key = 'disabled', '—'
                    else
                        style = row.modified and 'modified' or 'action'
                        key   = disp_key(row.current_key)
                    end
                    pcall(function()
                        W.grid:insertRow(nil)
                        W.grid:setCell(0, r, make_cell(row.label, style, row.label))
                        W.grid:setCell(1, r, make_cell(key, row.disabled and 'disabled' or 'default'))
                    end)
                    W._row_meta[r] = { kind = 'action', id = row.id, disabled = row.disabled, script = row.script }
                    if (not row.disabled) and row.id == W.selected_id then selected_row = r end
                    r = r + 1
                end
            end
        end
    end
    if selected_row then pcall(function() W.grid:selectRow(selected_row) end) end
end

local function select_action(id)
    W.selected_id = id
    set_hint()
end

local function start_capture(id)
    local e = eng(); if not e then return end
    W.selected_id = id
    capture.capture(function(chord)
        local res = e:bind(id, chord)
        pcall(function() facade().persist() end)
        render()
        local r = rows_by_id()[id]
        local note = 'Bound ' .. (r and r.label or id) .. ' → ' .. disp_key(chord)
        if res and res.displaced and res.displaced.label then
            note = note .. ' (took it from ' .. res.displaced.label .. ')'
        elseif res and res.displaced and res.displaced.ed then
            note = note .. ' (ED: ' .. res.displaced.ed .. ')'
        end
        W.sms_window:flash_status(note, 'success')
    end, function() set_hint() end)
end

local function reset_selected()
    if not W.selected_id then
        if W.sms_window then W.sms_window:flash_status('Select a row first.', 'info') end
        return
    end
    if tostring(W.selected_id):match('^script%.') then
        if W.sms_window then W.sms_window:flash_status('Scripts are edited from the editor (double-click).', 'info') end
        return
    end
    local e = eng(); if not e then return end
    local id = W.selected_id
    e:reset(id)
    pcall(function() facade().persist() end)
    render()
    local r = rows_by_id()[id]
    W.sms_window:flash_status('Reset ' .. (r and r.label or id) .. ' → ' .. disp_key(r and r.current_key), 'info')
end

local function reset_all()
    local e = eng(); if not e then return end
    e:reset_all()
    pcall(function() facade().persist() end)
    render()
    W.sms_window:flash_status('All hotkeys reset to defaults.', 'info')
end

-- ---- click dispatch ----

local function row_at(self, x, y)
    local row
    pcall(function() local _, rr = self:getMouseCursorColumnRow(x, y); row = rr end)
    if row and row >= 0 then return W._row_meta[row], row end
    return nil
end

local FOOTER_H = 36
local SEARCH_H = 30   -- search box band above the grid (22px field + gap)

-- Column-0 (Action) width as a fraction of the content area; column 1 takes the
-- rest. Shared by build_body's initial insertColumn and relayout.
local function col_widths(w)
    local c0 = math.floor(w * 0.62)
    return c0, math.max(80, w - c0)
end

-- Reposition every body widget to the current content rect. Wired to
-- sms_window's on_resize so the grid + footer track window resizes.
local function relayout(x, y, w, h)
    if W.search then pcall(function() W.search:set_bounds(x, y, w, 22) end) end
    if W.grid then
        pcall(function() if W.grid.setBounds then W.grid:setBounds(x, y + SEARCH_H, w, h - SEARCH_H - FOOTER_H) end end)
        local c0, c1 = col_widths(w)
        pcall(function()
            if W.grid.setColumnWidth then W.grid:setColumnWidth(0, c0); W.grid:setColumnWidth(1, c1) end
        end)
    end
    if W.reset_sel_btn then pcall(function() W.reset_sel_btn:setBounds(x, y + h - 28, 150, 22) end) end
    if W.reset_all_btn then pcall(function() W.reset_all_btn:setBounds(x + 160, y + h - 28, 110, 22) end) end
    if W.new_script_btn then pcall(function() W.new_script_btn:setBounds(x + 278, y + h - 28, 130, 22) end) end
end

local function build_body()
    local raw = W.sms_window:raw()
    local x, y, w, h = W.sms_window:get_content_bounds()
    local footer_h = FOOTER_H

    -- Search box at the top — filters the list by name, category or bound key.
    W.search = clearable_edit.new(raw, {
        on_change = function(text)
            W.filter_text = text or ''
            render()
        end,
    })
    pcall(function()
        if W.search then
            W.search:set_bounds(x, y, w, 22)
            local eb = W.search.widget and W.search:widget()
            if eb and eb.setHintText then pcall(function() eb:setHintText('Search name or key…') end) end
        end
    end)

    if Grid and GridHeaderCell then
        W.grid = Grid.new()
        try_skin(W.grid, 'dtc_grid')

        local c0, c1 = col_widths(w)
        local cols = {
            { label = 'Action',  width = c0 },
            { label = 'Binding', width = c1 },
        }
        for _, c in ipairs(cols) do
            local hc = GridHeaderCell.new()
            try_skin(hc, 'dtc_grid_header')
            if hc.setText then pcall(function() hc:setText(c.label) end) end
            pcall(function() W.grid:insertColumn(c.width, hc) end)
        end

        pcall(function() if W.grid.setBounds then W.grid:setBounds(x, y + SEARCH_H, w, h - SEARCH_H - footer_h) end end)

        -- Grid's built-in onMouseDown/onMouseDoubleClick are empty stubs the
        -- construct wires to mouse + double-click events; override both.
        W.grid.onMouseDown = function(self, mx, my, button)
            if button ~= 1 then return end
            local meta, row = row_at(self, mx, my)
            if not meta then return end
            if meta.kind == 'cat' then
                W.collapsed[meta.cat] = not W.collapsed[meta.cat]
                render()
            elseif meta.kind == 'action' and not meta.disabled then
                pcall(function() self:selectRow(row) end)
                select_action(meta.id)
            end
        end
        W.grid.onMouseDoubleClick = function(self, mx, my, button)
            if button ~= 1 then return end
            local meta = row_at(self, mx, my)
            if not (meta and meta.kind == 'action' and not meta.disabled) then return end
            if meta.script then
                facade().open_script_editor(meta.id)
            else
                start_capture(meta.id)
            end
        end

        render()
        pcall(function() if raw and raw.insertWidget then raw:insertWidget(W.grid) end end)
    else
        local lbl = Static.new()
        pcall(function() if lbl.setBounds then lbl:setBounds(x, y, w, 20) end end)
        if lbl.setText then lbl:setText('Grid widget unavailable on this DCS build.') end
        try_skin(lbl, 'staticSkin_ME')
        W.grid = nil
        pcall(function() if raw and raw.insertWidget then raw:insertWidget(lbl) end end)
    end

    -- Footer: "↩ Reset selected" (acts on the selected row) + "Reset all".
    W.reset_sel_btn = Button.new()
    pcall(function() if W.reset_sel_btn.setBounds then W.reset_sel_btn:setBounds(x, y + h - 28, 150, 22) end end)
    if W.reset_sel_btn.setText then W.reset_sel_btn:setText('↩  Reset selected') end
    try_skin(W.reset_sel_btn, 'dtc_button')
    if W.reset_sel_btn.addChangeCallback then
        W.reset_sel_btn:addChangeCallback(function() reset_selected() end)
    end
    pcall(function() if raw and raw.insertWidget then raw:insertWidget(W.reset_sel_btn) end end)

    W.reset_all_btn = Button.new()
    pcall(function() if W.reset_all_btn.setBounds then W.reset_all_btn:setBounds(x + 160, y + h - 28, 110, 22) end end)
    if W.reset_all_btn.setText then W.reset_all_btn:setText('Reset all') end
    try_skin(W.reset_all_btn, 'dtc_button')
    if W.reset_all_btn.addChangeCallback then
        W.reset_all_btn:addChangeCallback(function() reset_all() end)
    end
    pcall(function() if raw and raw.insertWidget then raw:insertWidget(W.reset_all_btn) end end)

    W.new_script_btn = Button.new()
    pcall(function() if W.new_script_btn.setBounds then W.new_script_btn:setBounds(x + 278, y + h - 28, 130, 22) end end)
    if W.new_script_btn.setText then W.new_script_btn:setText('+ New Script') end
    try_skin(W.new_script_btn, 'dtc_button')
    if W.new_script_btn.addChangeCallback then
        W.new_script_btn:addChangeCallback(function() facade().open_script_editor(nil) end)
    end
    pcall(function() if raw and raw.insertWidget then raw:insertWidget(W.new_script_btn) end end)
end

function M.show()
    capture.teardown()
    if W.sms_window then W.sms_window:show(); render(); set_hint(); return end
    W.sms_window = sms_window.new({
        title = 'ME Hotkeys',
        size = { w = 480, h = 520 },
        min_size = { w = 380, h = 320 },
        persist_across_new_mission = true,  -- hotkeys aren't mission-bound
        disable_undo_hotkey = true,
        on_resize = function(_, x, y, w, h) relayout(x, y, w, h) end,
    })
    if not W.sms_window then return end
    build_body()
    W.sms_window:show()
    set_hint()
end

function M.hide()
    capture.teardown()
    if W.sms_window then W.sms_window:hide() end
end

function M.toggle()
    if W.sms_window then W.sms_window:toggle(); render(); set_hint() else M.show() end
end

-- Re-render the list from the (possibly rebuilt) engine. Called by the facade
-- after a script is added/edited/deleted. No-op if the window isn't built.
function M.refresh()
    if W.sms_window and W.grid then render() end
end

return M
