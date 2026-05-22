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

local sms_window      = require('dcs_sms_me.sms_window')
local selection       = require('dcs_sms_me.selection')
local mass_forms      = require('dcs_sms_me.mass_edit_forms')
local skin_helper     = require('dcs_sms_me.skin_helper')
local map_sync        = require('dcs_sms_me.mass_edit_map_sync')
local me_select_writer = require('dcs_sms_me.me_select_writer')
local me_camera        = require('dcs_sms_me.me_camera')
local me_group_focus   = require('dcs_sms_me.me_group_focus')
local splitter_mod     = require('dcs_sms_me.splitter')
local clearable_edit   = require('dcs_sms_me.clearable_edit')
local marquee_hook     = require('dcs_sms_me.marquee_hook')
local airbase_detect   = require('dcs_sms_me.airbase_detect')

-- dxgui modules. pcall-required so the file still loads in test VMs.
local Static;          do local ok, m = pcall(require, 'Static');         if ok then Static         = m end end
local Grid;            do local ok, m = pcall(require, 'Grid');           if ok then Grid           = m end end
local GridHeaderCell;  do local ok, m = pcall(require, 'GridHeaderCell'); if ok then GridHeaderCell = m end end
local CheckBox;        do local ok, m = pcall(require, 'CheckBox');       if ok then CheckBox       = m end end
local EditBox;         do local ok, m = pcall(require, 'EditBox');        if ok then EditBox        = m end end
local Button;          do local ok, m = pcall(require, 'Button');         if ok then Button         = m end end
local ToggleButton;    do local ok, m = pcall(require, 'ToggleButton');   if ok then ToggleButton   = m end end
local ScrollPane;      do local ok, m = pcall(require, 'ScrollPane');     if ok then ScrollPane     = m end end

-- dxgui module: lets us query live keyboard state during a click handler so
-- shift-click can extend a checkbox range without ED exposing modifier flags
-- on the mouse-event payload itself.
local dxgui;           do local ok, m = pcall(require, 'dxgui');          if ok then dxgui          = m end end

local function shift_held()
    if not (dxgui and dxgui.GetKeyboardButtonPressed) then return false end
    local ok_l, l = pcall(dxgui.GetKeyboardButtonPressed, 'left shift')
    if ok_l and l then return true end
    local ok_r, r = pcall(dxgui.GetKeyboardButtonPressed, 'right shift')
    return ok_r and r == true
end

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
    checked     = { group = {}, unit = {}, waypoint = {}, zone = {}, drawing = {}, airbase = {} },
    -- Anchor entity (table reference) per scope -- the row a shift-click
    -- extends FROM. Set on every non-shift click; left untouched by
    -- shift-clicks so repeated extensions all originate from the same
    -- anchor (Explorer / GTK style).
    anchor      = { group = nil, unit = nil, waypoint = nil, zone = nil, drawing = nil, airbase = nil },
    filters     = { group = {}, unit = {}, waypoint = {}, zone = {}, drawing = {}, airbase = {} },
    sort_state  = {
        group    = { key = 'name',  dir = 'asc' },
        unit     = { key = 'name',  dir = 'asc' },
        waypoint = { key = 'group', dir = 'asc' },
        zone     = { key = 'name',  dir = 'asc' },
        drawing  = { key = 'name',  dir = 'asc' },
        airbase  = { key = 'name',  dir = 'asc' },
    },
    form_panels = { group = {}, unit = {}, waypoint = {}, zone = {}, drawing = {}, airbase = {} },
    -- Per-scope thin horizontal separator widgets (Static + dtc_separator
    -- skin) drawn between consecutive form panels. Length is always
    -- #form_panels[scope] - 1 (zero when the scope has 0 or 1 forms);
    -- shown/hidden along with the active scope's form stack.
    form_separators = { group = {}, unit = {}, waypoint = {}, zone = {}, drawing = {}, airbase = {} },
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
        tree         = nil,
        tree_headers = {},
        name_filter  = nil,
        refresh_btn  = nil,
        cancel_btn   = nil,
        empty_label  = nil,
        sel_all_btn  = nil,
        sel_inv_btn  = nil,
        sel_clr_btn  = nil,
        from_map_btn = nil,
        to_map_btn   = nil,
        form_scroll  = nil,
    },
    _built = false,
    marquee_subscribed = false,  -- reload-safe one-shot guard
}

local SCOPES = { 'group', 'unit', 'waypoint', 'zone', 'drawing', 'airbase' }

-- Map a coalition side → dtc-coalition-skin name for the Coalition and
-- Country cells in group scope. Unknown sides fall back to staticSkin_ME
-- (no tint).
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
    -- Clear the shift-click anchor if its entity was deleted between snapshots.
    if W.anchor[W.scope] and not in_pool[W.anchor[W.scope]] then
        W.anchor[W.scope] = nil
    end
end

-- Get the entities checked in the active scope. Closure handed to each
-- form so its apply handler can read the current selection.
local function get_checked_for_active_scope()
    local out = {}
    for _, e in ipairs(W.pool) do
        if W.checked[W.scope][e] then out[#out + 1] = e end
    end
    return out
end

-- Companion closure -- exposes the per-entity category map. Passed as
-- the 4th arg to each form's M.new so forms that need applicability
-- (e.g. toggle_group_flags) can look up an entity's category without
-- reaching into mass_edit state directly. Forms that don't need it
-- ignore the argument.
local function get_categories_for_active_scope()
    return W.categories or {}
end

-- Called by forms after a successful apply. Refreshes the entity list and
-- plays whatever toast/severity the form supplied. The host treats
-- result.toast/result.sev as opaque strings — each form decides its own
-- wording so the host stays form-agnostic.
local function on_after_apply(result)
    rebuild_pool()
    M.rebuild_treeview()
    if result and result.toast and W.sms_window and W.sms_window.set_status then
        pcall(W.sms_window.set_status, W.sms_window, result.toast, result.sev or 'info')
    end
end

local function show_forms_for_active_scope()
    -- Hide every panel + separator in every scope.
    for _, scope in ipairs(SCOPES) do
        for _, panel in ipairs(W.form_panels[scope] or {}) do
            if panel.hide then panel:hide() end
        end
        for _, sep in ipairs(W.form_separators[scope] or {}) do
            if sep.setVisible then pcall(sep.setVisible, sep, false) end
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
        for _, sep in ipairs(W.form_separators[W.scope] or {}) do
            if sep.setVisible then pcall(sep.setVisible, sep, true) end
        end
    end
end

local function update_map_buttons_visibility()
    local visible = (W.scope == 'group')
    local function show(btn, v)
        if btn and btn.setVisible then pcall(btn.setVisible, btn, v) end
    end
    show(W.widgets.from_map_btn, visible)
    show(W.widgets.to_map_btn,   visible)
end

-- Module-level recursion guard. When on_scope_changed programmatically
-- updates a tab's state via setState, the change-callback fires for each
-- updated tab; checking this flag at the top of the callback short-circuits
-- those echo-fires so the handler doesn't reenter.
local _set_state_internal = false

local function set_tab_state(tab, state)
    if not tab then return end
    local on = state and true or false
    -- Skin-swap drives the visual: dxgui's ToggleButton renderer doesn't
    -- pick a distinct visual for sticky-on, so a single skin can't
    -- distinguish active/inactive when the mouse is off the tab. Active
    -- tabs get dtc_tab (gold-on-cream every state); inactive get dtc_tab_off
    -- (text-only every state).
    skin_helper.apply(tab, on and 'dtc_tab' or 'dtc_tab_off')
    if tab.setState then
        _set_state_internal = true
        pcall(tab.setState, tab, on)
        _set_state_internal = false
    end
end

local function on_scope_changed(new_scope)
    if new_scope == W.scope then return end
    W.scope = new_scope
    -- Walk every scope tab and update its toggle state so exactly one tab
    -- is visually active (pressed/teal) at a time. set_tab_state is guarded
    -- so these programmatic setState calls don't re-enter the change
    -- callback we set up in make_scope_tab.
    for scope, tab in pairs(W.widgets.scope_tabs) do
        set_tab_state(tab, scope == new_scope)
    end
    rebuild_pool()
    M._build_tree_widget()
    M.rebuild_treeview()
    show_forms_for_active_scope()
    update_map_buttons_visibility()
    if M._relayout and W.sms_window and W.sms_window:raw() then
        local cw, ch = W.sms_window:raw():getSize()
        M._relayout(cw, ch)
    end
    -- Reset right-pane scroll so a tab switch always starts at the top
    -- of the (possibly different) form stack. Matches the left-pane
    -- grid's "rebuild from scratch" behavior on scope switch.
    if W.widgets.form_scroll and W.widgets.form_scroll.setVertScrollValue then
        pcall(W.widgets.form_scroll.setVertScrollValue, W.widgets.form_scroll, 0)
    end
end

local function on_refresh_clicked()
    rebuild_pool()
    M.rebuild_treeview()
end

local function install_airbase_marquee()
    if W.marquee_subscribed then return end
    -- marquee_hook.install is idempotent; calling here is safe even when
    -- a previous Mass Edit window or the prefab_manager already installed.
    pcall(marquee_hook.install)
    marquee_hook.subscribe(function(start_xy, end_xy)
        local hits = airbase_detect.airbases_in_rect(start_xy, end_xy)
        if type(hits) ~= 'table' or #hits == 0 then return end
        -- Ensure the airbase entry cache is populated so the by-id lookup
        -- below finds rows. snapshot_airbases_now is a no-op if already
        -- populated by a recent snapshot_mission('airbase') call; either
        -- way it returns a pool we can fall back to for name-only matches.
        local pool = selection._snapshot_airbases_now and selection._snapshot_airbases_now() or {}
        local by_name = {}
        for _, e in ipairs(pool) do by_name[e.name] = e end

        local changed = false
        for _, hit in ipairs(hits) do
            local entry = nil
            if hit.airdrome_number_at_save and selection.airbase_entry_by_id then
                entry = selection.airbase_entry_by_id(hit.airdrome_number_at_save)
            end
            if not entry then entry = by_name[hit.name] end
            if entry then
                W.checked.airbase[entry] = true
                changed = true
            end
        end
        if changed and W.scope == 'airbase' and M.rebuild_treeview then
            pcall(M.rebuild_treeview)
        end
    end)
    W.marquee_subscribed = true
end

-- ---------------------------------------------------------------------------
-- Treeview (per-scope columns, sortable, checkbox col 0).
-- ---------------------------------------------------------------------------

local SCOPE_COLUMNS = {
    group = {
        { key = 'check',     label = '',          width = 28,  type = 'check'  },
        { key = 'name',      label = 'Name',      width = 130, type = 'string' },
        { key = 'coalition', label = 'Coalition', width = 60,  type = 'string' },
        { key = 'country',   label = 'Country',   width = 80,  type = 'string' },
        { key = 'type',      label = 'Type',      width = 80,  type = 'string' },
        { key = 'units',     label = '# Units',   width = 50,  type = 'number' },
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
    airbase = {
        { key = 'check',     label = '',          width = 28,  type = 'check'  },
        { key = 'name',      label = 'Name',      width = 180, type = 'string' },
        { key = 'coalition', label = 'Coalition', width = 80,  type = 'string' },
        { key = 'north',     label = 'North',     width = 90,  type = 'number' },
        { key = 'east',      label = 'East',      width = 90,  type = 'number' },
    },
}

local function row_values(scope, entity, group)
    if scope == 'group' then
        -- Country lives on the back-reference (g.boss → country table);
        -- coalition is derived from country via W.country_to_side; category
        -- lives in W.categories (populated from snapshot_mission). None
        -- are fields on the group object itself.
        local country   = (entity.boss and entity.boss.name) or ''
        local coalition = (entity.boss and W.country_to_side[entity.boss]) or ''
        local category  = W.categories[entity] or ''
        return { name      = tostring(entity.name or ''),
                 coalition = tostring(coalition),
                 country   = tostring(country),
                 type      = tostring(category),
                 units     = #(entity.units or {}) }
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
    elseif scope == 'airbase' then
        return { name      = tostring(entity.name or ''),
                 coalition = tostring(entity.coalition or ''),
                 north     = tonumber(entity.north) or 0,
                 east      = tonumber(entity.east) or 0 }
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

    -- Drop the prior grid: detach it from the sms_window container so it
    -- can be GC'd instead of accumulating on every scope-tab switch.
    -- removeWidget is on the Window-class API; pcall'd so a dxgui without
    -- it still degrades to "old grid stays parented and just goes
    -- invisible" (the previous behavior).
    if W.widgets.tree then
        pcall(W.widgets.tree.setVisible, W.widgets.tree, false)
        if raw.removeWidget then pcall(raw.removeWidget, raw, W.widgets.tree) end
        W.widgets.tree = nil
    end

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
            local rows = W._tree_rows
            local r = rows and rows[row_idx + 1]
            if not r then return end

            local scope_checked = W.checked[W.scope]
            local anchor_entity = W.anchor[W.scope]
            local anchor_idx
            if anchor_entity then
                for i, rr in ipairs(rows) do
                    if rr.entity == anchor_entity then anchor_idx = i; break end
                end
            end

            if shift_held() and anchor_idx then
                -- Shift-click on the row body keeps the existing
                -- Explorer/GTK range-fill behavior: every row from the
                -- anchor to the clicked row, inclusive, gets the anchor's
                -- checked state. Anchor itself is NOT updated so repeated
                -- shift-clicks extend from the same origin.
                local clicked_idx  = row_idx + 1
                local from         = math.min(anchor_idx, clicked_idx)
                local to           = math.max(anchor_idx, clicked_idx)
                local target_state = scope_checked[anchor_entity] == true
                for i = from, to do
                    local e = rows[i] and rows[i].entity
                    if e then scope_checked[e] = target_state or nil end
                end
                M.rebuild_treeview()
            else
                -- Plain click on a row body: mirror the vanilla ME Unit
                -- List behavior — single-select the entity's group on
                -- the map AND mount its right-side properties panel,
                -- then pan the camera onto it. Does NOT touch the Mass
                -- Edit checkbox; batch inclusion is via the checkbox
                -- column only. Re-anchors here so a follow-up shift-
                -- click extends from this row.
                local entity       = r.entity
                local parent_group = W.parent_map[entity] or entity
                local cam_x = (type(entity.x)       == 'number' and entity.x)
                           or (type(parent_group.x) == 'number' and parent_group.x)
                local cam_y = (type(entity.y)       == 'number' and entity.y)
                           or (type(parent_group.y) == 'number' and parent_group.y)
                if cam_x and cam_y then me_camera.pan_to(cam_x, cam_y) end
                if type(parent_group) == 'table' and parent_group.groupId then
                    -- Unit scope: surface the clicked unit inside the
                    -- panel. Other scopes default to units[1].
                    local opt_unit = (W.scope == 'unit') and entity or nil
                    me_group_focus.focus(parent_group, opt_unit)
                end
                W.anchor[W.scope] = entity
            end
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

    -- Capture scroll position so the rebuild doesn't jump the view back to
    -- the top after every checkbox click / range fill / bulk-button press.
    -- Grid:removeAllRows + insertRow re-emits the whole tree, which loses
    -- the user's scroll context unless we restore it after.
    local saved_v, saved_h
    if grid.getVertScrollPosition then
        local ok_v, v = pcall(grid.getVertScrollPosition, grid); if ok_v then saved_v = v end
    end
    if grid.getHorzScrollPosition then
        local ok_h, hp = pcall(grid.getHorzScrollPosition, grid); if ok_h then saved_h = hp end
    end

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
                            local rows  = W._tree_rows or {}
                            local anchor_entity = W.anchor[W.scope]

                            -- Shift-click on a checkbox: same range-fill
                            -- semantics as shift-click on the row body. dxgui
                            -- has already toggled the checkbox visually by
                            -- the time this callback fires, so we have to
                            -- find the anchor and the clicked row indices in
                            -- the visible-row order, overwrite every entity
                            -- in the range with the anchor's checked state,
                            -- and trigger a rebuild so the just-toggled
                            -- checkbox's display matches the new W.checked
                            -- value. Anchor stays put.
                            if shift_held() and anchor_entity and anchor_entity ~= entity then
                                local anchor_idx, clicked_idx
                                for i, rr in ipairs(rows) do
                                    if rr.entity == anchor_entity then anchor_idx  = i end
                                    if rr.entity == entity        then clicked_idx = i end
                                end
                                if anchor_idx and clicked_idx then
                                    local from = math.min(anchor_idx, clicked_idx)
                                    local to   = math.max(anchor_idx, clicked_idx)
                                    local target_state = W.checked[W.scope][anchor_entity] == true
                                    for i = from, to do
                                        local e = rows[i] and rows[i].entity
                                        if e then W.checked[W.scope][e] = target_state or nil end
                                    end
                                    M.rebuild_treeview()
                                    return
                                end
                            end

                            -- Plain click on the checkbox: record the toggle
                            -- and update the anchor so a follow-up shift-
                            -- click extends from here.
                            W.checked[W.scope][entity] = state or nil
                            W.anchor[W.scope] = entity
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
                    if cell and c.key == 'coalition' then
                        local side
                        if W.scope == 'group' then
                            side = W.country_to_side[r.entity.boss]
                        elseif W.scope == 'airbase' then
                            -- entry.coalition is 'red'/'blue'/'neutrals' from
                            -- mission.AirportsEquipment. Normalise 'neutrals'
                            -- to 'neutral' so it matches COALITION_CELL_SKIN's
                            -- key set.
                            local c_str = r.entity.coalition
                            if     c_str == 'red'  then side = 'red'
                            elseif c_str == 'blue' then side = 'blue'
                            else                       side = 'neutral' end
                        end
                        local skin = side and COALITION_CELL_SKIN[side]
                        if skin then skin_helper.apply(cell, skin) end
                    elseif cell and W.scope == 'group' and c.key == 'country' then
                        local side = W.country_to_side[r.entity.boss]
                        local skin = COALITION_CELL_SKIN[side]
                        if skin then skin_helper.apply(cell, skin) end
                    end
                    pcall(grid.setCell, grid, col_idx - 1, row_idx, cell)
                end
            end
        end
    end

    -- Restore the user's pre-rebuild scroll position. Has to happen after
    -- every insertRow so the grid knows its max scroll extent.
    if saved_v and grid.setVertScrollPosition then
        pcall(grid.setVertScrollPosition, grid, saved_v)
    end
    if saved_h and grid.setHorzScrollPosition then
        pcall(grid.setHorzScrollPosition, grid, saved_h)
    end
end

-- ---------------------------------------------------------------------------
-- Scope labels (set once at tab construction; tabs no longer carry counts)
-- ---------------------------------------------------------------------------

local SCOPE_LABEL = {
    group = 'Group', unit = 'Unit', waypoint = 'Waypoint',
    zone = 'Zone', drawing = 'Drawing',
    airbase = 'Airbase',
}

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

local LAYOUT = {
    EDGE            = 8,
    TOP_Y           = 4,
    TAB_H           = 28,
    ROW_H           = 24,
    GAP             = 4,
    BTN_H           = 26,
    BTN_W           = 80,
    REFRESH_W       = 90,
    -- Gap between tree and form panes. The splitter sits inside it
    -- centered, leaving SPLITTER_MARGIN of breathing room on each side
    -- so the grab bar doesn't visually butt against either pane.
    SPLITTER_W      = 6,
    SPLITTER_MARGIN = 10,
    SPLIT_GUTTER    = 26,  -- 10 + 6 + 10 — keep in sync with the two above
    -- Right pane (forms) starts at this width and the left (tree) pane
    -- absorbs all horizontal slack as the window grows / shrinks. The
    -- user can drag the inter-pane splitter to override this value.
    FORM_PANE_W     = 440,
    -- Clamp range for the user-draggable splitter. Min keeps the form
    -- pane wide enough for label + input + toggle + button on a single
    -- row; max leaves at least ~260px for the tree.
    FORM_PANE_MIN_W = 340,
    FORM_PANE_MAX_W = 640,
    FOOTER_RESERVED = 80,
    -- Total vertical space between consecutive form panels. A 1px
    -- separator is drawn at the midpoint, leaving ~7px of breathing
    -- room on each side.
    FORM_GAP        = 16,
    SEPARATOR_H     = 1,
}

local function relayout(w, h)
    if not (W.sms_window and W.sms_window:raw()) then return end
    local L = LAYOUT
    local function set(widget, x, y, ww, hh)
        if widget and widget.setBounds then pcall(widget.setBounds, widget, x, y, ww, hh) end
    end

    local right_w = L.FORM_PANE_W
    local left_w  = math.max(60, w - 2 * L.EDGE - L.SPLIT_GUTTER - right_w)
    local right_x = L.EDGE + left_w + L.SPLIT_GUTTER
    local split_x = L.EDGE + left_w   -- splitter occupies the SPLIT_GUTTER strip

    -- Row 0: scope tabs. Share left_w equally across the five tabs so the
    -- strip stays anchored within the left (tree) pane and resizes with
    -- the name-filter + tree when the splitter is dragged. Refresh moved
    -- to the bottom-left of the tree pane (positioned with the bulk-
    -- button strip below).
    local n_tabs    = #SCOPES
    local tab_gaps  = L.GAP * math.max(0, n_tabs - 1)
    local tab_w     = math.max(1, math.floor((left_w - tab_gaps) / n_tabs))
    local tab_x     = L.EDGE
    for _, scope in ipairs(SCOPES) do
        set(W.widgets.scope_tabs[scope], tab_x, L.TOP_Y, tab_w, L.TAB_H)
        tab_x = tab_x + tab_w + L.GAP
    end

    -- Row 1: name filter (left half).
    local row1_y = L.TOP_Y + L.TAB_H + L.GAP
    if W.widgets.name_filter and W.widgets.name_filter.set_bounds then
        W.widgets.name_filter:set_bounds(L.EDGE, row1_y, left_w, L.ROW_H)
    end

    -- Bottom button band (right-anchored Cancel only — no Apply in this UI).
    local btn_y       = h - L.FOOTER_RESERVED - L.BTN_H - L.GAP
    local body_bottom = btn_y - L.GAP
    set(W.widgets.cancel_btn, w - L.EDGE - L.BTN_W, btn_y, L.BTN_W, L.BTN_H)

    -- Bottom-of-left-pane button strip: Refresh on the left, bulk-
    -- selection buttons right-aligned to the tree's right edge.
    -- Bulk order left→right: Select all · Invert · Clear · [From map
    -- · Highlight] -- the last two only on group scope (other scopes
    -- hide them; see below).
    local sel_btn_w   = 70
    local sel_strip_y = body_bottom - L.BTN_H
    set(W.widgets.refresh_btn, L.EDGE, sel_strip_y, L.REFRESH_W, L.BTN_H)
    local on_group    = W.scope == 'group'
    local strip_n     = on_group and 5 or 3
    local sel_total_w = sel_btn_w * strip_n + L.GAP * (strip_n - 1)
    local sel_x       = L.EDGE + left_w - sel_total_w
    -- Don't overlap the left-anchored Refresh button if the tree is narrow.
    local refresh_right = L.EDGE + L.REFRESH_W + L.GAP
    if sel_x < refresh_right then sel_x = refresh_right end
    set(W.widgets.sel_all_btn, sel_x, sel_strip_y, sel_btn_w, L.BTN_H)
    set(W.widgets.sel_inv_btn, sel_x + sel_btn_w + L.GAP, sel_strip_y, sel_btn_w, L.BTN_H)
    set(W.widgets.sel_clr_btn, sel_x + (sel_btn_w + L.GAP) * 2, sel_strip_y, sel_btn_w, L.BTN_H)
    if on_group then
        set(W.widgets.from_map_btn, sel_x + (sel_btn_w + L.GAP) * 3, sel_strip_y, sel_btn_w, L.BTN_H)
        set(W.widgets.to_map_btn,   sel_x + (sel_btn_w + L.GAP) * 4, sel_strip_y, sel_btn_w, L.BTN_H)
    end

    -- Left pane: tree fills from row1_y to just above the bulk-button strip.
    local tree_y = row1_y + L.ROW_H + L.GAP
    local tree_h = math.max(60, sel_strip_y - L.GAP - tree_y)
    set(W.widgets.tree, L.EDGE, tree_y, left_w, tree_h)

    -- Splitter handle: thin vertical grab bar centered in the SPLIT_GUTTER
    -- strip with SPLITTER_MARGIN of breathing room on each side. Spans
    -- the full body height — top of the name-filter row to bottom of the
    -- Cancel button — so the user has a tall grab target instead of just
    -- the tree-pane slice.
    local splitter_y = row1_y
    local splitter_h = (btn_y + L.BTN_H) - splitter_y
    if W.splitter then
        W.splitter:set_bounds(split_x + L.SPLITTER_MARGIN, splitter_y, L.SPLITTER_W, splitter_h)
        -- Keep its draggable range in sync with the current window size.
        -- Cap the max at "window minus minimum tree width" so the user
        -- can't drag past the point where the tree would collapse.
        local tree_min = 220
        local max_form = math.max(L.FORM_PANE_MIN_W, w - 2 * L.EDGE - L.SPLIT_GUTTER - tree_min)
        W.splitter:set_range(L.FORM_PANE_MIN_W, math.min(L.FORM_PANE_MAX_W, max_form))
        W.splitter:set_value(L.FORM_PANE_W)
    end

    -- Right pane: ScrollPane wraps the form stack so all forms are
    -- reachable at any window height. Outer bounds cover the right
    -- area; child widgets (forms + empty-scope label) use scroll-
    -- relative coordinates (origin at the pane's top-left, not the
    -- window's). When no ScrollPane exists (older DCS / test VM
    -- fallback), forms position at absolute right_x/row1_y as before.
    local has_pane = W.widgets.form_scroll ~= nil
    local body_h   = body_bottom - row1_y
    if has_pane then
        set(W.widgets.form_scroll, right_x, row1_y, right_w, body_h)
    end

    local active = W.form_panels[W.scope] or {}
    local seps   = W.form_separators[W.scope] or {}
    local form_x = has_pane and 0 or right_x
    local form_y = has_pane and 0 or row1_y
    local form_w = right_w
    local y_cursor = form_y
    for i, panel in ipairs(active) do
        local ph = (panel.get_height and panel:get_height()) or 80
        if panel.set_bounds then panel:set_bounds(form_x, y_cursor, form_w, ph) end
        y_cursor = y_cursor + ph
        -- Draw a separator between consecutive forms; positioned at the
        -- midpoint of the FORM_GAP so it has breathing room on both sides.
        if i < #active then
            local sep = seps[i]
            if sep and sep.setBounds then
                local sep_x = form_x + L.EDGE
                local sep_y = y_cursor + math.floor((L.FORM_GAP - L.SEPARATOR_H) / 2)
                local sep_w = form_w - 2 * L.EDGE
                pcall(sep.setBounds, sep, sep_x, sep_y, sep_w, L.SEPARATOR_H)
            end
            y_cursor = y_cursor + L.FORM_GAP
        end
    end

    if #active == 0 then
        set(W.widgets.empty_label, form_x, form_y, form_w, L.ROW_H)
    end

    -- ScrollPane doesn't auto-detect child-bound changes — tell it to
    -- recompute the scroll extent. Without this, the vertical scrollbar
    -- range stays at whatever it was last time relayout fired.
    if has_pane and W.widgets.form_scroll.updateWidgetsBounds then
        pcall(W.widgets.form_scroll.updateWidgetsBounds, W.widgets.form_scroll)
    end
end
M._relayout = relayout

-- ---------------------------------------------------------------------------
-- Window construction
-- ---------------------------------------------------------------------------

local function make_scope_tab(scope_name, label, on_click)
    if not (ToggleButton and ToggleButton.new) then return nil end
    local ok, tab = pcall(ToggleButton.new)
    if not (ok and tab) then return nil end
    -- Skin is applied by set_tab_state (called by the build_window seed
    -- loop and on_scope_changed) based on the active/inactive state, so
    -- we don't apply one here.
    if tab.setText then pcall(tab.setText, tab, label) end
    if tab.addChangeCallback then
        pcall(tab.addChangeCallback, tab, function(self)
            if _set_state_internal then return end
            local on = self.getState and self:getState() == true
            if on then
                on_click(scope_name)
            else
                -- User clicked the already-active tab: ToggleButton's
                -- default would toggle off, leaving no scope selected.
                -- Re-assert active state so there's always exactly one
                -- selected scope.
                set_tab_state(self, true)
            end
        end)
    end
    return tab
end

local function build_window()
    if W._built then return end

    W.sms_window = sms_window.new({
        title    = 'Mass Edit  [loaded ' .. os.date('%H:%M:%S') .. ']',
        size     = { w = 900, h = 621 },
        min_size = { w = 720, h = 500 },
        -- Compose default_on_undo with a list refresh so the user sees the
        -- restored values immediately after Ctrl+Z (instead of stale ones
        -- until they click Refresh).
        on_undo = function(swin)
            sms_window.default_on_undo(swin)
            pcall(function()
                rebuild_pool()
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
        local tab = make_scope_tab(scope, SCOPE_LABEL[scope], on_scope_changed)
        if tab then
            if tab.setBounds then pcall(tab.setBounds, tab, 8, 4, 140, 28) end
            pcall(raw.insertWidget, raw, tab)
            W.widgets.scope_tabs[scope] = tab
            -- Seed the active state so the default scope (W.scope, set to
            -- 'group' at module load) renders pressed/teal on first paint.
            set_tab_state(tab, scope == W.scope)
            -- Airbase scope is the only scope where marquee-drag-on-F10
            -- bulk-checks rows; advertise the trick via a tooltip since
            -- it's otherwise invisible from this UI.
            if scope == 'airbase' and tab.setTooltipText then
                pcall(tab.setTooltipText, tab,
                    'Tip: drag on the F10 map to bulk-check airbases.')
            end
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

    -- Name filter. clearable_edit wraps an EditBox + an inline × clear
    -- button that auto-hides when the filter is empty, so the user can
    -- wipe the active filter with one click instead of selecting +
    -- backspacing.
    W.widgets.name_filter = clearable_edit.new(raw, {
        on_change = function(txt)
            W.filters[W.scope].name_substr = txt
            M.rebuild_treeview()
        end,
    })

    -- Bulk-selection buttons. All three act on the LEFT-pane treeview's
    -- current scope and (where it matters) its currently-visible rows --
    -- i.e. whatever passes the name filter. "Select all visible" and
    -- "Invert visible" work on the post-filter set; "Clear" wipes the
    -- whole scope's selection regardless of filter (which is almost
    -- always what the user wants when they hit Clear).
    local function for_each_visible(fn)
        local rows = W._tree_rows or {}
        for _, r in ipairs(rows) do fn(r.entity) end
    end

    local function on_select_all_visible()
        pcall(function()
            for_each_visible(function(e) W.checked[W.scope][e] = true end)
            M.rebuild_treeview()
        end)
    end

    local function on_invert_visible()
        pcall(function()
            for_each_visible(function(e)
                W.checked[W.scope][e] = (W.checked[W.scope][e] ~= true) or nil
            end)
            M.rebuild_treeview()
        end)
    end

    local function on_clear_selection()
        pcall(function()
            W.checked[W.scope] = {}
            W.anchor[W.scope] = nil
            M.rebuild_treeview()
        end)
    end

    local function make_bulk_btn(label, cb)
        if not (Button and Button.new) then return nil end
        local ok, b = pcall(Button.new)
        if not (ok and b) then return nil end
        skin_helper.apply(b, 'dtc_button')
        if b.setText then pcall(b.setText, b, label) end
        if b.addMouseDownCallback then pcall(b.addMouseDownCallback, b, cb) end
        pcall(raw.insertWidget, raw, b)
        return b
    end

    W.widgets.sel_all_btn = make_bulk_btn('Select all',    on_select_all_visible)
    W.widgets.sel_inv_btn = make_bulk_btn('Invert',        on_invert_visible)
    W.widgets.sel_clr_btn = make_bulk_btn('Clear',         on_clear_selection)

    -- Map-sync buttons: pure compute via map_sync, side effects (writer
    -- call + rebuild + toast) here. Both are group-scope-only; non-group
    -- scopes hide the widgets in relayout (see Task 8).
    local function toast(msg, sev)
        if W.sms_window and W.sms_window.set_status then
            pcall(W.sms_window.set_status, W.sms_window, msg, sev or 'info')
        end
    end

    local function on_fetch_from_map()
        pcall(function()
            local snap = selection.snapshot()
            local r = map_sync.compute_fetch(W, snap)
            if r.toast then toast(r.toast, r.sev) end
            -- compute_fetch already mutated W on success; rebuild reflects it.
            if r.ok and not r.empty then M.rebuild_treeview() end
        end)
    end

    local function on_push_to_map()
        pcall(function()
            local r = map_sync.compute_push(W)
            if r.empty then
                toast(r.toast, r.sev)
                return
            end
            local wr = me_select_writer.set_group_selection(r.group_refs)
            if not wr.ok then
                toast('Failed to push: ' .. tostring(wr.error), 'err')
                return
            end
            toast(string.format('Pushed %d groups to map', wr.count), 'info')
        end)
    end

    W.widgets.from_map_btn = make_bulk_btn('From map',  on_fetch_from_map)
    W.widgets.to_map_btn   = make_bulk_btn('Highlight', on_push_to_map)

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

    -- Right-pane container — a ScrollPane that holds every scope's
    -- forms (and the empty-scope placeholder). When dxgui's ScrollPane
    -- module is unavailable (older DCS / test VMs), fall back to raw
    -- so behavior matches the pre-scroll layout.
    local form_parent = raw
    if ScrollPane and ScrollPane.new then
        local ok_sp, sp = pcall(ScrollPane.new)
        if ok_sp and sp then
            -- dtc_scroll_pane = me_managerDTC.dlg's noinserts pane background
            -- + grid4mulnew's thin "tools" scrollbar (the lighter look the
            -- treeview uses). Plain scrollPane_modul_noinserts ships with
            -- the dark-gray vertScrollBarSkinSV which clashes.
            skin_helper.apply(sp, 'dtc_scroll_pane')
            pcall(raw.insertWidget, raw, sp)
            W.widgets.form_scroll = sp
            form_parent = sp
        end
    end

    -- Inter-pane splitter: thin vertical drag bar between the tree and
    -- the form ScrollPane. Parented to the raw window so it sits in the
    -- gutter strip (NOT inside either pane). Constructed AFTER the
    -- ScrollPane so it inserts later in dxgui's z-order — even if a
    -- future LAYOUT.SPLIT_GUTTER tweak made the splitter's right edge
    -- bleed into the ScrollPane's x range, the splitter would stay
    -- clickable instead of being silently swallowed.
    --
    -- on_drag mutates the layout constant and re-runs relayout, which
    -- repositions every pane plus the splitter itself (set_value below
    -- in relayout keeps the widget consistent if anyone else mutates
    -- FORM_PANE_W externally).
    W.splitter = splitter_mod.new(raw, {
        initial  = LAYOUT.FORM_PANE_W,
        min      = LAYOUT.FORM_PANE_MIN_W,
        max      = LAYOUT.FORM_PANE_MAX_W,
        skin     = 'dtc_splitter',
        invert   = true,  -- dragging RIGHT shrinks the right (form) pane
        on_drag  = function(new_w)
            LAYOUT.FORM_PANE_W = new_w
            local cw, ch = raw:getSize()
            relayout(cw, ch)
        end,
    })

    -- Mount form panels for every scope (one-time allocation per Q2 of the design).
    for _, scope in ipairs(SCOPES) do
        local panels = {}
        for _, form_module in ipairs(mass_forms.forms_for(scope)) do
            local panel = form_module.new(form_parent, get_checked_for_active_scope, on_after_apply, get_categories_for_active_scope)
            if panel then
                panels[#panels + 1] = panel
                if panel.hide then panel:hide() end
            end
        end
        W.form_panels[scope] = panels

        -- Allocate N-1 separator widgets to slot between consecutive
        -- forms in this scope. Hidden by default; show_forms_for_active_scope
        -- toggles them along with the panels.
        local seps = {}
        for _ = 1, math.max(0, #panels - 1) do
            if Static and Static.new then
                local ok, s = pcall(Static.new, '')
                if ok and s then
                    skin_helper.apply(s, 'dtc_separator')
                    pcall(form_parent.insertWidget, form_parent, s)
                    if s.setVisible then pcall(s.setVisible, s, false) end
                    seps[#seps + 1] = s
                end
            end
        end
        W.form_separators[scope] = seps
    end

    -- Empty-scope placeholder (shared across scopes; toggled in show_forms_for_active_scope).
    -- Parented to the ScrollPane (or raw if pane unavailable) so it scrolls / hides with the forms.
    if Static and Static.new then
        local ok, s = pcall(Static.new, 'No forms yet for this scope')
        if ok and s then
            skin_helper.apply(s, 'staticSkin_ME')
            pcall(form_parent.insertWidget, form_parent, s)
            W.widgets.empty_label = s
        end
    end

    W._built = true

    pcall(function() local cw, ch = raw:getSize(); relayout(cw, ch) end)
end

function M.show()
    build_window()
    if not W.sms_window then return end
    pcall(install_airbase_marquee)
    if not W.widgets.tree then M._build_tree_widget() end
    rebuild_pool()
    M.rebuild_treeview()
    show_forms_for_active_scope()
    update_map_buttons_visibility()
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
M._rebuild_pool       = rebuild_pool
M._on_scope_changed   = on_scope_changed
M._on_refresh_clicked = on_refresh_clicked

-- Test seams: invoked only by test_mass_edit_airbase_marquee.lua. These
-- have no consumer in production code.
M._reset_checked_airbase = function() W.checked.airbase = {} end
M._install_airbase_marquee_for_test = install_airbase_marquee
M._get_checked_airbase = function() return W.checked.airbase end

return M
