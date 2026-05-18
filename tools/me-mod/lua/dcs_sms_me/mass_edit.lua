-- mass_edit.lua — the Mass Edit tool window.
--
-- A single sms_window-chromed window with:
--   * a top scope tab strip (group / unit / waypoint / zone / drawing)
--   * a left pane: name-substring filter + multi-column treeview (Grid)
--     of every entity in the mission, with checkboxes for selection
--   * a right pane: vertical stack of self-contained forms (find &
--     replace, rename, set country, ...) — one per (property × operation),
--     each with its own button. No preview, no Apply gate.
--
-- The form modules live under mass_edit_forms/ and are loaded via
-- mass_edit_forms.lua. mass_edit.lua is a thin host: it manages scope
-- tabs, the entity list, and form mounting.
--
-- Toggle via DCS-SMS → Mass Edit menu entry.

local M = {}

local sms_window  = require('dcs_sms_me.sms_window')
local selection   = require('dcs_sms_me.selection')
local mass_forms  = require('dcs_sms_me.mass_edit_forms')
local skin_helper = require('dcs_sms_me.skin_helper')

-- dxgui modules. pcall-required so the file still loads in test VMs.
local Static;          do local ok, m = pcall(require, 'Static');         if ok then Static         = m end end
local Grid;            do local ok, m = pcall(require, 'Grid');           if ok then Grid           = m end end
local GridHeaderCell;  do local ok, m = pcall(require, 'GridHeaderCell'); if ok then GridHeaderCell = m end end
local CheckBox;        do local ok, m = pcall(require, 'CheckBox');       if ok then CheckBox       = m end end
local EditBox;         do local ok, m = pcall(require, 'EditBox');        if ok then EditBox        = m end end
local Button;          do local ok, m = pcall(require, 'Button');         if ok then Button         = m end end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.mass_edit', _G.log.WARNING or 2, msg) end)
end

local function make_cell(text, tooltip)
    if not (Static and Static.new) then return nil end
    local ok, s = pcall(Static.new, tostring(text or ''))
    if not (ok and s) then return nil end
    skin_helper.apply(s, 'staticSkin_ME')
    if tooltip and s.setTooltipText then pcall(function() s:setTooltipText(tostring(tooltip)) end) end
    return s
end

local function make_checkbox(state)
    if not (CheckBox and CheckBox.new) then return nil end
    local ok, cb = pcall(CheckBox.new)
    if not (ok and cb) then return nil end
    skin_helper.apply(cb, 'checkBoxSkin_MENew')
    if cb.setState then pcall(cb.setState, cb, state == true) end
    return cb
end

-- ---------------------------------------------------------------------------
-- Per-window state.
-- ---------------------------------------------------------------------------

local W = {
    sms_window  = nil,
    scope       = 'group',
    pool        = {},
    parent_map  = {},
    checked     = { group = {}, unit = {}, waypoint = {}, zone = {}, drawing = {} },
    filters     = { group = {}, unit = {}, waypoint = {}, zone = {}, drawing = {} },
    sort_state  = {
        group    = { key = 'name',  dir = 'asc' },
        unit     = { key = 'name',  dir = 'asc' },
        waypoint = { key = 'group', dir = 'asc' },
        zone     = { key = 'name',  dir = 'asc' },
        drawing  = { key = 'name',  dir = 'asc' },
    },
    form_panels = { group = {}, unit = {}, waypoint = {}, zone = {}, drawing = {} },
    -- entity → 'plane' | 'helicopter' | 'vehicle' | 'ship' | 'static' | 'unknown'
    -- Populated from selection.snapshot_mission(). Reads the Type column for
    -- the group treeview (the category lives at container-key level in the
    -- mission tree, not on the group object itself).
    categories     = {},
    -- country (table reference) → 'red' | 'blue' | 'neutral'. Built by
    -- rebuild_pool from the mission tree; the group-scope treeview's
    -- Country column applies the matching dtc_coal_* skin per row.
    country_to_side = {},
    widgets = {
        scope_tabs   = {},
        scope_counts = {},
        tree         = nil,
        tree_headers = {},
        name_filter  = nil,
        refresh_btn  = nil,
        cancel_btn   = nil,
        empty_label  = nil,
    },
    _built = false,
}

local SCOPES = { 'group', 'unit', 'waypoint', 'zone', 'drawing' }

-- Map a coalition side → dtc-coalition-skin name for the Country cell in
-- group scope. Unknown sides fall back to staticSkin_ME (no tint).
local COALITION_CELL_SKIN = {
    red     = 'dtc_coal_red',
    blue    = 'dtc_coal_blue',
    neutral = 'dtc_coal_neutral',
}

-- ---------------------------------------------------------------------------
-- Data flow
-- ---------------------------------------------------------------------------

local function rebuild_pool()
    local snap = selection.snapshot_mission(W.scope)
    if not snap.ok then
        log_warn('snapshot_mission failed: ' .. tostring(snap.error))
        W.pool, W.parent_map, W.categories, W.country_to_side = {}, {}, {}, {}
        return
    end
    W.pool, W.parent_map = snap.pool, snap.parent_map
    W.categories = snap.categories or {}

    -- Rebuild the country → side index. Walks mission.coalition once;
    -- typical missions have under a dozen countries so this is cheap. Side
    -- keys in mission.coalition are 'red' / 'blue' / 'neutrals' (plural in
    -- some DCS versions) — we normalise 'neutrals' to 'neutral' so the
    -- skin lookup table can use one canonical key.
    W.country_to_side = {}
    do
        local ok_req, Mission = pcall(require, 'me_mission')
        local mission = ok_req and Mission and Mission.mission
        if type(mission) == 'table' and type(mission.coalition) == 'table' then
            for side_name, side in pairs(mission.coalition) do
                if type(side) == 'table' and type(side.country) == 'table' then
                    local canonical = (side_name == 'red' and 'red')
                                   or (side_name == 'blue' and 'blue')
                                   or 'neutral'
                    for _, c in ipairs(side.country) do
                        W.country_to_side[c] = canonical
                    end
                end
            end
        end
    end

    -- Drop checked entries no longer in the pool.
    local in_pool = {}
    for _, e in ipairs(W.pool) do in_pool[e] = true end
    for e, _ in pairs(W.checked[W.scope] or {}) do
        if not in_pool[e] then W.checked[W.scope][e] = nil end
    end
end

local function scope_pool_counts()
    local counts = {}
    for _, s in ipairs(SCOPES) do
        local snap = selection.snapshot_mission(s)
        counts[s] = snap.ok and #snap.pool or 0
    end
    return counts
end

-- Get the entities checked in the active scope. Closure handed to each
-- form so its apply handler can read the current selection. Returns a
-- second value -- a categories map keyed by the same entities -- so
-- forms that care about per-entity category (e.g. toggle_group_flags's
-- applicability lookup) can read it. Older forms only assign the first
-- return value; the second is silently discarded.
local function get_checked_for_active_scope()
    local out = {}
    for _, e in ipairs(W.pool) do
        if W.checked[W.scope][e] then out[#out + 1] = e end
    end
    return out, W.categories or {}
end

-- Closure form so the form contract can take an opaque
-- get_categories() instead of digging into mass_edit's state. Returns
-- the same categories map that get_checked's second return value
-- surfaces. Cheap (just exposes W.categories); each form decides
-- whether to call it.
local function get_categories_for_active_scope()
    return W.categories or {}
end

-- Called by forms after a successful apply. Refreshes the entity list,
-- updates scope counts, and plays whatever toast/severity the form
-- supplied. The host treats result.toast/result.sev as opaque strings —
-- each form decides its own wording so the host stays form-agnostic.
local function on_after_apply(result)
    rebuild_pool()
    M.update_scope_counts()
    M.rebuild_treeview()
    if result and result.toast and W.sms_window and W.sms_window.set_status then
        pcall(W.sms_window.set_status, W.sms_window, result.toast, result.sev or 'info')
    end
end

local function show_forms_for_active_scope()
    -- Hide every panel in every scope.
    for _, scope in ipairs(SCOPES) do
        for _, panel in ipairs(W.form_panels[scope] or {}) do
            if panel.hide then panel:hide() end
        end
    end
    -- Show the active scope's panels (or the empty-label fallback).
    local active = W.form_panels[W.scope] or {}
    if #active == 0 then
        if W.widgets.empty_label and W.widgets.empty_label.setVisible then
            pcall(W.widgets.empty_label.setVisible, W.widgets.empty_label, true)
        end
    else
        if W.widgets.empty_label and W.widgets.empty_label.setVisible then
            pcall(W.widgets.empty_label.setVisible, W.widgets.empty_label, false)
        end
        for _, panel in ipairs(active) do
            if panel.show then panel:show() end
        end
    end
end

local function on_scope_changed(new_scope)
    if new_scope == W.scope then return end
    W.scope = new_scope
    rebuild_pool()
    M._build_tree_widget()
    M.rebuild_treeview()
    show_forms_for_active_scope()
    if M._relayout and W.sms_window and W.sms_window:raw() then
        local cw, ch = W.sms_window:raw():getSize()
        M._relayout(cw, ch)
    end
end

local function on_refresh_clicked()
    rebuild_pool()
    M.update_scope_counts()
    M.rebuild_treeview()
end

-- ---------------------------------------------------------------------------
-- Treeview (per-scope columns, sortable, checkbox col 0).
-- ---------------------------------------------------------------------------

local SCOPE_COLUMNS = {
    group = {
        { key = 'check',   label = '',        width = 28,  type = 'check'  },
        { key = 'name',    label = 'Name',    width = 170, type = 'string' },
        { key = 'country', label = 'Country', width = 100, type = 'string' },
        { key = 'type',    label = 'Type',    width = 80,  type = 'string' },
        { key = 'units',   label = '# Units', width = 50,  type = 'number' },
    },
    unit = {
        { key = 'check', label = '',      width = 28,  type = 'check'  },
        { key = 'name',  label = 'Name',  width = 160, type = 'string' },
        { key = 'type',  label = 'Type',  width = 110, type = 'string' },
        { key = 'skill', label = 'Skill', width = 75,  type = 'string' },
        { key = 'group', label = 'Group', width = 55,  type = 'string' },
    },
    waypoint = {
        { key = 'check', label = '',      width = 28,  type = 'check'  },
        { key = 'group', label = 'Group', width = 130, type = 'string' },
        { key = 'idx',   label = '#',     width = 40,  type = 'number' },
        { key = 'type',  label = 'Type',  width = 100, type = 'string' },
        { key = 'alt',   label = 'Alt',   width = 65,  type = 'number' },
        { key = 'speed', label = 'Speed', width = 65,  type = 'number' },
    },
    zone = {
        { key = 'check',  label = '',       width = 28,  type = 'check'  },
        { key = 'name',   label = 'Name',   width = 280, type = 'string' },
        { key = 'radius', label = 'Radius', width = 120, type = 'number' },
    },
    drawing = {
        { key = 'check', label = '',      width = 28,  type = 'check'  },
        { key = 'name',  label = 'Name',  width = 280, type = 'string' },
        { key = 'layer', label = 'Layer', width = 120, type = 'string' },
    },
}

local function row_values(scope, entity, group)
    if scope == 'group' then
        -- Country lives on the back-reference (g.boss → country table);
        -- category lives in W.categories (populated from snapshot_mission).
        -- Neither is a field on the group object itself.
        local country = (entity.boss and entity.boss.name) or ''
        local category = W.categories[entity] or ''
        return { name = tostring(entity.name or ''),
                 country = tostring(country),
                 type    = tostring(category),
                 units   = #(entity.units or {}) }
    elseif scope == 'unit' then
        return { name  = tostring(entity.name or ''),
                 type  = tostring(entity.type or ''),
                 skill = tostring(entity.skill or ''),
                 group = tostring((group or {}).name or '') }
    elseif scope == 'waypoint' then
        local idx = 0
        if group and group.route and group.route.points then
            for i, p in ipairs(group.route.points) do if p == entity then idx = i; break end end
        end
        return { group = tostring((group or {}).name or ''),
                 idx   = idx,
                 type  = tostring(entity.type or ''),
                 alt   = tonumber(entity.alt) or 0,
                 speed = tonumber(entity.speed) or 0 }
    elseif scope == 'zone' then
        return { name = tostring(entity.name or ''), radius = tonumber(entity.radius) or 0 }
    elseif scope == 'drawing' then
        return { name = tostring(entity.name or ''),
                 layer = tostring((entity.layer and entity.layer.name) or '') }
    end
    return {}
end

local function passes_filters(scope, entity, group, filters)
    if not filters or next(filters) == nil then return true end
    local name = tostring(entity.name or (group or {}).name or '')
    if filters.name_substr and filters.name_substr ~= '' then
        if not name:lower():find(filters.name_substr:lower(), 1, true) then return false end
    end
    return true
end

local function update_sort_indicators()
    local cols = SCOPE_COLUMNS[W.scope] or {}
    local ss = W.sort_state[W.scope] or {}
    for i, c in ipairs(cols) do
        local hc = W.widgets.tree_headers[i]
        if hc and hc.setText then
            local label = c.label
            if ss.key == c.key and c.key ~= 'check' then
                label = label .. (ss.dir == 'desc' and ' v' or ' ^')
            end
            pcall(hc.setText, hc, label)
        end
    end
end

local function sort_rows(rows)
    local ss = W.sort_state[W.scope]
    if not (ss and ss.key) then return end
    local cols = SCOPE_COLUMNS[W.scope] or {}
    local col_type
    for _, c in ipairs(cols) do if c.key == ss.key then col_type = c.type; break end end
    if col_type == 'check' or col_type == nil then return end
    local asc, numeric = ss.dir ~= 'desc', col_type == 'number'
    for i, r in ipairs(rows) do r._idx = i end
    table.sort(rows, function(a, b)
        local av, bv = a.values[ss.key], b.values[ss.key]
        if numeric then av, bv = tonumber(av) or 0, tonumber(bv) or 0
        else            av, bv = tostring(av or ''):lower(), tostring(bv or ''):lower() end
        if av == bv then return a._idx < b._idx end
        if asc then return av < bv else return av > bv end
    end)
    for _, r in ipairs(rows) do r._idx = nil end
end

local function build_tree_widget()
    if not (Grid and Grid.new and GridHeaderCell and GridHeaderCell.new) then return end
    if not W.sms_window then return end
    local raw = W.sms_window:raw()
    if not raw then return end

    if W.widgets.tree then pcall(W.widgets.tree.setVisible, W.widgets.tree, false) end

    local ok_grid, grid = pcall(Grid.new)
    if not (ok_grid and grid) then return end
    skin_helper.apply(grid, 'dtc_grid')
    if grid.setBounds then pcall(grid.setBounds, grid, 8, 72, 430, 460) end

    W.widgets.tree_headers = {}
    local cols = SCOPE_COLUMNS[W.scope] or {}
    for i, c in ipairs(cols) do
        local ok_hc, hc = pcall(GridHeaderCell.new)
        if ok_hc and hc then
            skin_helper.apply(hc, 'dtc_grid_header')
            if hc.setText then pcall(hc.setText, hc, c.label) end
            if c.key ~= 'check' and hc.addChangeCallback then
                local key = c.key
                pcall(hc.addChangeCallback, hc, function()
                    local ss = W.sort_state[W.scope]
                    if ss.key == key then ss.dir = (ss.dir == 'asc') and 'desc' or 'asc'
                    else ss.key = key; ss.dir = 'asc' end
                    M.rebuild_treeview()
                end)
            end
            W.widgets.tree_headers[i] = hc
            pcall(grid.insertColumn, grid, c.width, hc)
        end
    end

    grid.onMouseDown = function(self, x, y, button)
        if button ~= 1 then return end
        pcall(function()
            local col_idx, row_idx = self:getMouseCursorColumnRow(x, y)
            if not (row_idx and row_idx >= 0) then return end
            if col_idx == 0 then return end
            local r = W._tree_rows and W._tree_rows[row_idx + 1]
            if not r then return end
            local new_state = not (W.checked[W.scope][r.entity] == true)
            W.checked[W.scope][r.entity] = new_state or nil
            M.rebuild_treeview()
        end)
    end

    pcall(raw.insertWidget, raw, grid)
    W.widgets.tree = grid
    update_sort_indicators()
    pcall(function()
        if W.sms_window and W.sms_window:raw() and M._relayout then
            local cw, ch = W.sms_window:raw():getSize()
            M._relayout(cw, ch)
        end
    end)
end
M._build_tree_widget = build_tree_widget

function M.rebuild_treeview()
    local rows = {}
    for _, e in ipairs(W.pool) do
        local g = W.parent_map[e] or e
        if passes_filters(W.scope, e, g, W.filters[W.scope]) then
            rows[#rows + 1] = { entity = e, group = g, values = row_values(W.scope, e, g),
                                checked = W.checked[W.scope][e] == true }
        end
    end
    sort_rows(rows)
    W._tree_rows = rows
    W._tree_columns = SCOPE_COLUMNS[W.scope] or {}

    update_sort_indicators()

    local grid = W.widgets.tree
    if not grid then return end
    pcall(grid.removeAllRows, grid)

    local cols = SCOPE_COLUMNS[W.scope] or {}
    for i, r in ipairs(rows) do
        pcall(grid.insertRow, grid, nil)
        local row_idx = i - 1
        for col_idx, c in ipairs(cols) do
            if c.key == 'check' then
                local cb = make_checkbox(r.checked)
                if cb then
                    if cb.addChangeCallback then
                        local entity = r.entity
                        pcall(cb.addChangeCallback, cb, function(box)
                            local state = box.getState and box:getState() == true
                            W.checked[W.scope][entity] = state or nil
                        end)
                    end
                    pcall(grid.setCell, grid, col_idx - 1, row_idx, cb)
                end
            else
                local v = r.values[c.key]
                local cell = make_cell((v == nil) and '' or tostring(v), tostring(v or ''))
                if cell then
                    -- Coalition tint for the group-scope Country column —
                    -- echoes the colored marker the country ComboList already
                    -- shows on its ListBoxItem entries. Skin override has to
                    -- happen after make_cell's default staticSkin_ME apply.
                    if cell and W.scope == 'group' and c.key == 'country' then
                        local side = W.country_to_side[r.entity.boss]
                        local skin = COALITION_CELL_SKIN[side]
                        if skin then skin_helper.apply(cell, skin) end
                    end
                    pcall(grid.setCell, grid, col_idx - 1, row_idx, cell)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Scope counts label
-- ---------------------------------------------------------------------------

local SCOPE_LABEL = {
    group = 'Group', unit = 'Unit', waypoint = 'Waypoint',
    zone = 'Zone', drawing = 'Drawing',
}

function M.update_scope_counts()
    if not W.widgets.scope_counts then return end
    local counts = scope_pool_counts()
    for scope, lbl in pairs(W.widgets.scope_counts) do
        if lbl and lbl.setText then
            local text = (SCOPE_LABEL[scope] or scope) .. ' · ' .. tostring(counts[scope] or 0)
            pcall(lbl.setText, lbl, text)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

local LAYOUT = {
    EDGE            = 8,
    TOP_Y           = 4,
    TAB_H           = 28,
    TAB_W           = 100,
    ROW_H           = 24,
    GAP             = 4,
    BTN_H           = 26,
    BTN_W           = 80,
    REFRESH_W       = 90,
    SPLIT_GUTTER    = 4,
    FOOTER_RESERVED = 80,
    FORM_GAP        = 8,
}

local function relayout(w, h)
    if not (W.sms_window and W.sms_window:raw()) then return end
    local L = LAYOUT
    local function set(widget, x, y, ww, hh)
        if widget and widget.setBounds then pcall(widget.setBounds, widget, x, y, ww, hh) end
    end

    -- Row 0: scope tabs + refresh button.
    local tab_x = L.EDGE
    for _, scope in ipairs(SCOPES) do
        set(W.widgets.scope_tabs[scope], tab_x, L.TOP_Y, L.TAB_W, L.TAB_H)
        tab_x = tab_x + L.TAB_W + L.GAP
    end
    set(W.widgets.refresh_btn, w - L.EDGE - L.REFRESH_W, L.TOP_Y, L.REFRESH_W, L.TAB_H)

    local left_w  = math.floor((w - 2 * L.EDGE - L.SPLIT_GUTTER) / 2)
    local right_x = L.EDGE + left_w + L.SPLIT_GUTTER
    local right_w = w - L.EDGE - right_x

    -- Row 1: name filter (left half).
    local row1_y = L.TOP_Y + L.TAB_H + L.GAP
    set(W.widgets.name_filter, L.EDGE, row1_y, left_w, L.ROW_H)

    -- Bottom button band (right-anchored Cancel only — no Apply in this UI).
    local btn_y       = h - L.FOOTER_RESERVED - L.BTN_H - L.GAP
    local body_bottom = btn_y - L.GAP
    set(W.widgets.cancel_btn, w - L.EDGE - L.BTN_W, btn_y, L.BTN_W, L.BTN_H)

    -- Left pane: tree fills from row1_y to body_bottom.
    local tree_y = row1_y + L.ROW_H + L.GAP
    local tree_h = math.max(60, body_bottom - tree_y)
    set(W.widgets.tree, L.EDGE, tree_y, left_w, tree_h)

    -- Right pane: stack the active scope's forms vertically, starting at row1_y.
    local active = W.form_panels[W.scope] or {}
    local y_cursor = row1_y
    for _, panel in ipairs(active) do
        local ph = (panel.get_height and panel:get_height()) or 80
        if panel.set_bounds then panel:set_bounds(right_x, y_cursor, right_w, ph) end
        y_cursor = y_cursor + ph + L.FORM_GAP
    end

    if #active == 0 then
        set(W.widgets.empty_label, right_x, row1_y, right_w, L.ROW_H)
    end
end
M._relayout = relayout

-- ---------------------------------------------------------------------------
-- Window construction
-- ---------------------------------------------------------------------------

local function make_scope_tab(scope_name, label, count_str, on_click)
    local ok_dl, DialogLoader = pcall(require, 'DialogLoader')
    local tab = nil
    if ok_dl and DialogLoader and DialogLoader.spawnDialogFromString then
        local raw_xml = [[
<Static name="tab" type="Static">
  <skin>staticSkin_ME</skin>
  <bounds x="0" y="0" w="120" h="32"/>
</Static>
]]
        local ok2, dialog = pcall(DialogLoader.spawnDialogFromString, raw_xml)
        if ok2 and dialog then tab = dialog.tab end
    end
    if not tab and Static and Static.new then
        local ok3, s = pcall(Static.new)
        if ok3 then tab = s end
    end
    if not tab then return nil, nil end
    if tab.setText then pcall(tab.setText, tab, label .. ' · ' .. count_str) end
    if tab.addMouseDownCallback then
        pcall(tab.addMouseDownCallback, tab, function() on_click(scope_name) end)
    elseif tab.addMouseUpCallback then
        pcall(tab.addMouseUpCallback, tab, function() on_click(scope_name) end)
    end
    return tab, tab
end

local function build_window()
    if W._built then return end

    W.sms_window = sms_window.new({
        title    = 'Mass Edit  [loaded ' .. os.date('%H:%M:%S') .. ']',
        size     = { w = 900, h = 600 },
        min_size = { w = 720, h = 500 },
        -- Compose default_on_undo with a list refresh so the user sees the
        -- restored values immediately after Ctrl+Z (instead of stale ones
        -- until they click Refresh).
        on_undo = function(swin)
            sms_window.default_on_undo(swin)
            pcall(function()
                rebuild_pool()
                M.update_scope_counts()
                M.rebuild_treeview()
            end)
        end,
        on_resize = function(swin)
            pcall(function() local cw, ch = swin:raw():getSize(); relayout(cw, ch) end)
        end,
    })
    if not W.sms_window then log_warn('sms_window.new returned nil'); return end
    local raw = W.sms_window:raw()
    if not raw then log_warn('sms_window:raw() returned nil'); return end

    -- Scope tabs.
    for _, scope in ipairs(SCOPES) do
        local tab, count_lbl = make_scope_tab(scope, SCOPE_LABEL[scope], '0', on_scope_changed)
        if tab then
            if tab.setBounds then pcall(tab.setBounds, tab, 8, 4, 140, 28) end
            pcall(raw.insertWidget, raw, tab)
            W.widgets.scope_tabs[scope] = tab
            W.widgets.scope_counts[scope] = count_lbl
        end
    end

    -- Refresh button.
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Refresh') end
            if b.addMouseDownCallback then pcall(b.addMouseDownCallback, b, on_refresh_clicked) end
            pcall(raw.insertWidget, raw, b)
            W.widgets.refresh_btn = b
        end
    end

    -- Name filter.
    if EditBox and EditBox.new then
        local ok, ed = pcall(EditBox.new)
        if ok and ed then
            skin_helper.apply(ed, 'editBoxSkin_ME')
            if ed.addChangeCallback then
                pcall(ed.addChangeCallback, ed, function(box)
                    local txt = box.getText and box:getText() or ''
                    W.filters[W.scope].name_substr = txt
                    M.rebuild_treeview()
                end)
            end
            pcall(raw.insertWidget, raw, ed)
            W.widgets.name_filter = ed
        end
    end

    -- Empty-scope placeholder (shared across scopes; toggled in show_forms_for_active_scope).
    if Static and Static.new then
        local ok, s = pcall(Static.new, 'No forms yet for this scope')
        if ok and s then
            skin_helper.apply(s, 'staticSkin_ME')
            pcall(raw.insertWidget, raw, s)
            W.widgets.empty_label = s
        end
    end

    -- Cancel button.
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Cancel') end
            if b.addMouseDownCallback then pcall(b.addMouseDownCallback, b, function() M.hide() end) end
            pcall(raw.insertWidget, raw, b)
            W.widgets.cancel_btn = b
        end
    end

    -- Mount form panels for every scope (one-time allocation per Q2 of the design).
    for _, scope in ipairs(SCOPES) do
        local panels = {}
        for _, form_module in ipairs(mass_forms.forms_for(scope)) do
            local panel = form_module.new(raw, get_checked_for_active_scope, on_after_apply, get_categories_for_active_scope)
            if panel then
                panels[#panels + 1] = panel
                if panel.hide then panel:hide() end
            end
        end
        W.form_panels[scope] = panels
    end

    W._built = true

    pcall(function() local cw, ch = raw:getSize(); relayout(cw, ch) end)
end

function M.show()
    build_window()
    if not W.sms_window then return end
    if not W.widgets.tree then M._build_tree_widget() end
    rebuild_pool()
    M.update_scope_counts()
    M.rebuild_treeview()
    show_forms_for_active_scope()
    pcall(function() local cw, ch = W.sms_window:raw():getSize(); relayout(cw, ch) end)
    W.sms_window:show()
end

function M.hide()
    if W.sms_window then W.sms_window:hide() end
end

function M.toggle()
    if W.sms_window and W.sms_window:raw() and W.sms_window:raw():isVisible() then
        M.hide()
    else
        M.show()
    end
end

-- Expose internals for tests.
M._W                  = W
M._scope_pool_counts  = scope_pool_counts
M._rebuild_pool       = rebuild_pool
M._on_scope_changed   = on_scope_changed
M._on_refresh_clicked = on_refresh_clicked

return M
