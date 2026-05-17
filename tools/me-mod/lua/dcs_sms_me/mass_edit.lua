-- mass_edit.lua — the Mass Edit tool window.
--
-- A single sms_window-chromed window with a top-of-window scope tab strip
-- and (filled in by later tasks) a treeview / filter widgets / property
-- panel / preview table. Toggle via DCS-SMS → Mass Edit menu entry.
--
-- The window's lifecycle is idempotent — show() reuses the previous
-- widget tree (hidden, not destroyed) when re-opened in the same session.
-- All per-session state lives in the W table; rebuild_pool / rebuild_
-- treeview / rebuild_property_panel / recompute_plan / rebuild_preview
-- helpers wire the data flow.

local M = {}

local sms_window = require('dcs_sms_me.sms_window')
local selection  = require('dcs_sms_me.selection')
local registry   = require('dcs_sms_me.mass_edit_registry')
local ops        = require('dcs_sms_me.mass_edit_ops')
local version    = require('dcs_sms_me.version')

-- dxgui widget modules. All pcall-required so the module still loads in
-- test VMs / older DCS builds without these classes.
local Skin;            do local ok, m = pcall(require, 'Skin');           if ok then Skin           = m end end
local Static;          do local ok, m = pcall(require, 'Static');         if ok then Static         = m end end
local Grid;            do local ok, m = pcall(require, 'Grid');           if ok then Grid           = m end end
local GridHeaderCell;  do local ok, m = pcall(require, 'GridHeaderCell'); if ok then GridHeaderCell = m end end
local CheckBox;        do local ok, m = pcall(require, 'CheckBox');       if ok then CheckBox       = m end end

local dtc_skins = require('dcs_sms_me.dtc_skins')

-- Apply a skin by short name. Resolves dtc_grid / dtc_grid_header against
-- dtc_skins.lua first (these aren't auto-generated entries in Skin), then
-- falls back to Skin.<name>() for stock ME skins (staticSkin_ME,
-- checkBoxSkin_MENew, etc). Failures degrade silently.
local function try_skin(widget, skin_name)
    pcall(function()
        if not (widget and widget.setSkin) then return end
        local s
        if     skin_name == 'dtc_grid'        then s = dtc_skins.grid()
        elseif skin_name == 'dtc_grid_header' then s = dtc_skins.grid_header()
        elseif skin_name == 'dtc_button'      then s = dtc_skins.button()
        else
            local fn = Skin and Skin[skin_name]
            if not fn then return end
            s = fn()
        end
        if s then widget:setSkin(s) end
    end)
end

local function make_cell(text, tooltip)
    if not (Static and Static.new) then return nil end
    local ok, s = pcall(Static.new, tostring(text or ''))
    if not (ok and s) then return nil end
    try_skin(s, 'staticSkin_ME')
    if tooltip and s.setTooltipText then
        pcall(function() s:setTooltipText(tostring(tooltip)) end)
    end
    return s
end

local function make_checkbox(state)
    if not (CheckBox and CheckBox.new) then return nil end
    local ok, cb = pcall(CheckBox.new)
    if not (ok and cb) then return nil end
    try_skin(cb, 'checkBoxSkin_MENew')
    if cb.setState then pcall(cb.setState, cb, state == true) end
    return cb
end

-- ---------------------------------------------------------------------------
-- Per-window state.
-- ---------------------------------------------------------------------------

local W = {
    sms_window         = nil,
    scope              = 'group',   -- 'group' | 'unit' | 'waypoint' | 'zone' | 'drawing'
    source             = 'marquee',
    pool               = {},
    parent_map         = {},
    checked            = { group = {}, unit = {}, waypoint = {}, zone = {}, drawing = {} },
    filters            = { group = {}, unit = {}, waypoint = {}, zone = {}, drawing = {} },
    sort_state         = {
        group    = { key = 'name',  dir = 'asc' },
        unit     = { key = 'name',  dir = 'asc' },
        waypoint = { key = 'group', dir = 'asc' },
        zone     = { key = 'name',  dir = 'asc' },
        drawing  = { key = 'name',  dir = 'asc' },
    },
    property_id        = nil,
    operation          = nil,
    op_args            = {},
    plan               = nil,
    debounce_deadline  = nil,
    -- Widget handles (populated lazily on first show).
    widgets = {
        scope_tabs   = {},
        scope_counts = {},
        tree         = nil,
        tree_headers = {},
        property_sel = nil,
        operation_sel = nil,
        args_panel   = nil,
        preview_grid = nil,
        apply_btn    = nil,
        cancel_btn   = nil,
        refresh_btn  = nil,
        banner_label = nil,
    },
    _built = false,
}

local SCOPES = { 'group', 'unit', 'waypoint', 'zone', 'drawing' }

local function log_info(msg)
    pcall(function() _G.log.write('sms.me.mass_edit', _G.log.INFO or 0, msg) end)
end
local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.mass_edit', _G.log.WARNING or 2, msg) end)
end

-- ---------------------------------------------------------------------------
-- Data flow helpers.
-- ---------------------------------------------------------------------------

local function rebuild_pool()
    local snap = selection.snapshot_drilled(W.scope)
    if not snap.ok then
        log_warn('snapshot_drilled failed: ' .. tostring(snap.error))
        W.pool = {}; W.parent_map = {}; W.source = 'marquee'
        return
    end
    W.pool, W.parent_map, W.source = snap.pool, snap.parent_map, snap.source

    -- Drop checked entries for items no longer in the pool.
    local in_pool = {}
    for _, e in ipairs(W.pool) do in_pool[e] = true end
    for e, _ in pairs(W.checked[W.scope] or {}) do
        if not in_pool[e] then W.checked[W.scope][e] = nil end
    end
end

local function scope_pool_counts()
    local counts = {}
    for _, s in ipairs(SCOPES) do
        local snap = selection.snapshot_drilled(s)
        counts[s] = snap.ok and #snap.pool or 0
    end
    return counts
end

local function recompute_plan()
    if not W.property_id or not W.operation then
        W.plan = nil
        return
    end
    local checked_entities = {}
    for _, e in ipairs(W.pool) do
        if W.checked[W.scope][e] then
            checked_entities[#checked_entities + 1] = e
        end
    end
    W.plan = ops.compute_plan(W.scope, checked_entities, W.parent_map,
                              W.property_id, W.operation, W.op_args)
end

local function on_scope_changed(new_scope)
    if new_scope == W.scope then return end
    W.scope = new_scope
    W.property_id, W.operation, W.op_args = nil, nil, {}
    rebuild_pool()
    M._build_tree_widget()  -- columns differ per scope → rebuild the Grid
    M.rebuild_treeview()
    M.rebuild_property_panel()
    recompute_plan()
    M.rebuild_preview()
end

local function on_refresh_clicked()
    rebuild_pool()
    M.update_scope_counts()
    M.rebuild_treeview()
    M.rebuild_property_panel()
    recompute_plan()
    M.rebuild_preview()
end

-- ---------------------------------------------------------------------------
-- Treeview + filter widgets
--
-- dxgui doesn't have a tree widget; we render a flat sortable table inside
-- a ListBox. Each row is a horizontal strip with a checkbox + per-column
-- Static labels. Sorting is in-pool (rebuild_treeview re-sorts W.pool by
-- the active column).
-- ---------------------------------------------------------------------------

-- Per-scope column definitions. Column 0 is always 'check' (CheckBox cell);
-- the rest are data columns rendered as Static cells. Widths sum to ~428px
-- to fit the 430px tree area.
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

-- Default sort key per scope (matches the spec's "sort default" column).
local DEFAULT_SORT = {
    group    = 'name',
    unit     = 'name',
    waypoint = 'group',
    zone     = 'name',
    drawing  = 'name',
}

-- row_values returns a keyed table aligned to SCOPE_COLUMNS data-column keys.
-- Numeric columns return numbers (not strings) so the sort comparator can
-- treat them as numbers without re-parsing.
local function row_values(scope, entity, group)
    if scope == 'group' then
        return {
            name    = tostring(entity.name or ''),
            country = tostring(entity.country or ''),
            type    = tostring(entity.category or ''),
            units   = #(entity.units or {}),
        }
    elseif scope == 'unit' then
        return {
            name  = tostring(entity.name or ''),
            type  = tostring(entity.type or ''),
            skill = tostring(entity.skill or ''),
            group = tostring((group or {}).name or ''),
        }
    elseif scope == 'waypoint' then
        local idx = 0
        if group and group.route and group.route.points then
            for i, p in ipairs(group.route.points) do
                if p == entity then idx = i; break end
            end
        end
        return {
            group = tostring((group or {}).name or ''),
            idx   = idx,
            type  = tostring(entity.type or ''),
            alt   = tonumber(entity.alt) or 0,
            speed = tonumber(entity.speed) or 0,
        }
    elseif scope == 'zone' then
        return {
            name   = tostring(entity.name or ''),
            radius = tonumber(entity.radius) or 0,
        }
    elseif scope == 'drawing' then
        return {
            name  = tostring(entity.name or ''),
            layer = tostring((entity.layer and entity.layer.name) or ''),
        }
    end
    return {}
end

local function passes_filters(scope, entity, group, filters)
    if not filters or next(filters) == nil then return true end
    local name = tostring(entity.name or (group or {}).name or '')
    if filters.name_substr and filters.name_substr ~= '' then
        if not name:lower():find(filters.name_substr:lower(), 1, true) then return false end
    end
    if filters.country and filters.country ~= '' and filters.country ~= 'any' then
        if tostring(entity.country or (group or {}).country or '') ~= filters.country then return false end
    end
    if filters.type and filters.type ~= '' and filters.type ~= 'any' then
        if tostring(entity.type or entity.category or '') ~= filters.type then return false end
    end
    if filters.skill and filters.skill ~= '' and filters.skill ~= 'any' then
        if tostring(entity.skill or '') ~= filters.skill then return false end
    end
    return true
end

-- Re-text headers so the active sort column gets the ▲/▼ glyph and the
-- others reset to their plain label.
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

-- Stable in-place sort of `rows` by the column key/dir in W.sort_state.
local function sort_rows(rows)
    local ss = W.sort_state[W.scope]
    if not (ss and ss.key) then return end
    local cols = SCOPE_COLUMNS[W.scope] or {}
    local col_type
    for _, c in ipairs(cols) do
        if c.key == ss.key then col_type = c.type; break end
    end
    if col_type == 'check' or col_type == nil then return end
    local asc = ss.dir ~= 'desc'
    local numeric = col_type == 'number'
    for i, r in ipairs(rows) do r._idx = i end
    table.sort(rows, function(a, b)
        local av, bv = a.values[ss.key], b.values[ss.key]
        if numeric then
            av, bv = tonumber(av) or 0, tonumber(bv) or 0
        else
            av, bv = tostring(av or ''):lower(), tostring(bv or ''):lower()
        end
        if av == bv then return a._idx < b._idx end
        if asc then return av < bv else return av > bv end
    end)
    for _, r in ipairs(rows) do r._idx = nil end
end

-- Construct (or replace) the Grid widget for the active scope. Columns
-- differ per scope so we rebuild the Grid on every scope change. The
-- previous Grid is hidden (dxgui has no widget removal API exposed
-- consistently); the visual leak is bounded by the number of scope
-- switches in a session.
local function build_tree_widget()
    if not (Grid and Grid.new and GridHeaderCell and GridHeaderCell.new) then
        return  -- fallback: no Grid → leave W.widgets.tree as nil
    end
    if not W.sms_window then return end
    local raw = W.sms_window:raw()
    if not raw then return end

    -- Tear down the previous Grid.
    if W.widgets.tree then
        pcall(W.widgets.tree.setVisible, W.widgets.tree, false)
    end

    local ok_grid, grid = pcall(Grid.new)
    if not (ok_grid and grid) then return end
    try_skin(grid, 'dtc_grid')
    if grid.setBounds then pcall(grid.setBounds, grid, 8, 72, 430, 460) end

    -- Insert per-scope columns with sort-on-click headers.
    W.widgets.tree_headers = {}
    local cols = SCOPE_COLUMNS[W.scope] or {}
    for i, c in ipairs(cols) do
        local ok_hc, hc = pcall(GridHeaderCell.new)
        if ok_hc and hc then
            try_skin(hc, 'dtc_grid_header')
            if hc.setText then pcall(hc.setText, hc, c.label) end
            if c.key ~= 'check' and hc.addChangeCallback then
                local key = c.key
                pcall(hc.addChangeCallback, hc, function()
                    local ss = W.sort_state[W.scope]
                    if ss.key == key then
                        ss.dir = (ss.dir == 'asc') and 'desc' or 'asc'
                    else
                        ss.key = key
                        ss.dir = 'asc'
                    end
                    M.rebuild_treeview()
                end)
            end
            W.widgets.tree_headers[i] = hc
            pcall(grid.insertColumn, grid, c.width, hc)
        end
    end

    -- Whole-row click toggles the row's checked state. Skip col 0 — the
    -- CheckBox there fires its own change callback. Right-click is a no-op
    -- for v1.
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
            recompute_plan(); M.rebuild_preview()
        end)
    end

    pcall(raw.insertWidget, raw, grid)
    W.widgets.tree = grid
    update_sort_indicators()
    -- The newly-constructed Grid was inserted with placeholder bounds; have
    -- relayout reposition it (and every other widget) against the current
    -- outer window size. M._relayout is the layout closure assigned at end
    -- of the module — uses M dispatch because relayout is defined later
    -- in the file than build_tree_widget.
    pcall(function()
        if W.sms_window and W.sms_window:raw() then
            local cw, ch = W.sms_window:raw():getSize()
            if M._relayout then M._relayout(cw, ch) end
        end
    end)
end
M._build_tree_widget = build_tree_widget

function M.rebuild_treeview()
    -- Compose rows from pool + filters.
    local rows = {}
    for _, e in ipairs(W.pool) do
        local g = W.parent_map[e] or e
        if passes_filters(W.scope, e, g, W.filters[W.scope]) then
            rows[#rows + 1] = {
                entity   = e,
                group    = g,
                values   = row_values(W.scope, e, g),
                checked  = W.checked[W.scope][e] == true,
            }
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
                            recompute_plan(); M.rebuild_preview()
                        end)
                    end
                    pcall(grid.setCell, grid, col_idx - 1, row_idx, cb)
                end
            else
                local v = r.values[c.key]
                local text = (v == nil) and '' or tostring(v)
                local cell = make_cell(text, text)
                if cell then
                    pcall(grid.setCell, grid, col_idx - 1, row_idx, cell)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Property panel
-- ---------------------------------------------------------------------------

local OP_LABEL = {
    set_all       = 'Set all to one value',
    add_prefix    = 'Add prefix',
    add_suffix    = 'Add suffix',
    find_replace  = 'Find & replace text',
    auto_number   = 'Auto-number',
    offset        = 'Adjust by amount',
    toggle_set    = 'Set toggle',
}

-- Filter registry to the active scope and the categories present in the
-- pool's parent groups.
local function applicable_properties()
    local present_cats = {}
    if W.scope == 'unit' or W.scope == 'waypoint' or W.scope == 'group' then
        for _, e in ipairs(W.pool) do
            local g = W.parent_map[e] or e
            local cat = g.category
            if not cat then
                cat = (W.scope == 'group' and (e.category or 'unknown')) or 'unknown'
            end
            present_cats[cat] = true
        end
    end

    local out = {}
    for _, entry in ipairs(registry) do
        if entry.scope == W.scope then
            local ok
            if entry.applies_to[1] == '*' then ok = true
            else
                for _, c in ipairs(entry.applies_to) do
                    if present_cats[c] then ok = true; break end
                end
                if W.scope == 'zone' or W.scope == 'drawing' then ok = true end
                if next(present_cats) == nil then ok = true end
            end
            if ok then out[#out + 1] = entry end
        end
    end
    return out
end

local function distribute_current_value()
    if not W.property_id then return 'pick a property' end
    local entry_obj
    for _, e in ipairs(registry) do if e.id == W.property_id then entry_obj = e; break end end
    if not entry_obj then return '' end
    local seen, count = {}, 0
    for _, ent in ipairs(W.pool) do
        if W.checked[W.scope][ent] then
            local v = tostring(entry_obj.reader(ent))
            if not seen[v] then seen[v] = true; count = count + 1 end
        end
    end
    if count == 0 then return '(none selected)' end
    if count == 1 then
        for v, _ in pairs(seen) do return v end
    end
    return 'Mixed (' .. count .. ' values)'
end

function M.rebuild_property_panel()
    local props = applicable_properties()

    -- Rebuild the property ComboBox.
    if W.widgets.property_sel and W.widgets.property_sel.removeAllItems then
        pcall(W.widgets.property_sel.removeAllItems, W.widgets.property_sel)
        local by_cat = {}
        for _, p in ipairs(props) do
            by_cat[p.category] = by_cat[p.category] or {}
            table.insert(by_cat[p.category], p)
        end
        for _, cat in ipairs({ 'Identity', 'Behaviour', 'Appearance', 'Geometry' }) do
            if by_cat[cat] then
                pcall(W.widgets.property_sel.addItem, W.widgets.property_sel, '-- ' .. cat .. ' --')
                for _, p in ipairs(by_cat[cat]) do
                    pcall(W.widgets.property_sel.addItem, W.widgets.property_sel, p.label .. '|' .. p.id)
                end
            end
        end
        if W.widgets.property_sel.addChangeCallback then
            pcall(W.widgets.property_sel.addChangeCallback, W.widgets.property_sel, function(cb)
                local text = cb.getText and cb:getText() or ''
                local id = text:match('|(.+)$')
                if id then
                    W.property_id = id
                    W.operation = nil
                    W.op_args = {}
                    M.rebuild_property_panel()
                    recompute_plan(); M.rebuild_preview()
                end
            end)
        end
    end

    -- Rebuild the operation ComboBox for the chosen property.
    local entry_obj
    if W.property_id then
        for _, e in ipairs(registry) do if e.id == W.property_id then entry_obj = e; break end end
    end
    if W.widgets.operation_sel and W.widgets.operation_sel.removeAllItems then
        pcall(W.widgets.operation_sel.removeAllItems, W.widgets.operation_sel)
        if entry_obj then
            for _, op in ipairs(entry_obj.operations) do
                pcall(W.widgets.operation_sel.addItem, W.widgets.operation_sel,
                      (OP_LABEL[op] or op) .. '|' .. op)
            end
            if W.widgets.operation_sel.addChangeCallback then
                pcall(W.widgets.operation_sel.addChangeCallback, W.widgets.operation_sel, function(cb)
                    local text = cb.getText and cb:getText() or ''
                    local op = text:match('|(.+)$')
                    if op then
                        W.operation = op
                        W.op_args = {}
                        M.rebuild_property_panel()
                        recompute_plan(); M.rebuild_preview()
                    end
                end)
            end
        end
    end

    -- Rebuild the args panel.
    if W.widgets.args_panel and entry_obj and W.operation then
        if W.widgets.args_panel.setText then
            local current = distribute_current_value()
            local op_summary = W.operation .. '  (current: ' .. current .. ')'
            pcall(W.widgets.args_panel.setText, W.widgets.args_panel, op_summary)
        end
        local ok_eb, EditBox = pcall(require, 'EditBox')
        if not W.widgets.set_all_edit and ok_eb and EditBox and EditBox.new then
            local ok2, ed = pcall(EditBox.new)
            if ok2 and ed then
                W.widgets.set_all_edit = ed
                try_skin(ed, 'editBoxSkin_ME')
                local raw = W.sms_window and W.sms_window:raw()
                if raw then pcall(raw.insertWidget, raw, ed) end
                -- Have relayout position the freshly-inserted EditBox in
                -- the right-pane args row (instead of a hardcoded coord).
                pcall(function()
                    if W.sms_window and W.sms_window:raw() and M._relayout then
                        local cw, ch = W.sms_window:raw():getSize()
                        M._relayout(cw, ch)
                    end
                end)
                if ed.addChangeCallback then
                    pcall(ed.addChangeCallback, ed, function(box)
                        local txt = box.getText and box:getText() or ''
                        if W.operation == 'set_all'      then W.op_args = { value = txt }
                        elseif W.operation == 'add_prefix' then W.op_args = { text = txt }
                        elseif W.operation == 'add_suffix' then W.op_args = { text = txt }
                        elseif W.operation == 'offset'    then W.op_args = { delta = tonumber(txt) or 0 }
                        elseif W.operation == 'find_replace' then
                            local f, r = txt:match('^(.-)|(.*)$')
                            W.op_args = { find = f or '', replace = r or '' }
                        elseif W.operation == 'auto_number' then
                            W.op_args = { pattern = txt, start = 1, step = 1, pad = 2, order = 'name_asc' }
                        elseif W.operation == 'toggle_set' then
                            local v = txt:lower()
                            if v == 'true' then W.op_args = { value = true }
                            elseif v == 'false' then W.op_args = { value = false }
                            else W.op_args = { value = nil } end
                        end
                        recompute_plan(); M.rebuild_preview()
                    end)
                end
            end
        end
    end
end
-- ---------------------------------------------------------------------------
-- Preview + Apply
-- ---------------------------------------------------------------------------

function M.rebuild_preview()
    if not W.widgets.preview_grid then return end
    if not W.widgets.preview_grid.removeAllItems then return end
    pcall(W.widgets.preview_grid.removeAllItems, W.widgets.preview_grid)

    local plan = W.plan
    if not plan or not plan.rows then return end

    local ok_lbi, ListBoxItem = pcall(require, 'ListBoxItem')
    if not (ok_lbi and ListBoxItem and ListBoxItem.new) then return end

    local n_ok, n_fail = 0, 0
    for _, r in ipairs(plan.rows) do
        local name = tostring((r.entity and r.entity.name) or '?')
        local line
        if r.ok then
            line = string.format('  %-30s  %s  →  %s', name, tostring(r.old), tostring(r.new))
            n_ok = n_ok + 1
        else
            line = string.format('✗ %-30s  (%s)', name, tostring(r.error))
            n_fail = n_fail + 1
        end
        local ok_item, item = pcall(ListBoxItem.new)
        if ok_item and item then
            if item.setText then pcall(item.setText, item, line) end
            pcall(W.widgets.preview_grid.insertItem, W.widgets.preview_grid, item)
        end
    end

    -- Footer status: "<n_ok> to apply · <n_fail> mismatched"
    if W.sms_window and W.sms_window.set_status then
        local sev = (n_ok > 0 and 'info') or 'warning'
        local text = string.format('%d to apply · %d mismatched', n_ok, n_fail)
        pcall(W.sms_window.set_status, W.sms_window, text, sev)
    end

    -- Apply button enabled iff n_ok > 0.
    if W.widgets.apply_btn and W.widgets.apply_btn.setEnabled then
        pcall(W.widgets.apply_btn.setEnabled, W.widgets.apply_btn, n_ok > 0)
    end
end

function M.on_apply_clicked()
    -- Always recompute before applying (freshness guarantee — spec §Apply pipeline).
    recompute_plan()
    if not W.plan or #W.plan.rows == 0 then return end
    local result = ops.apply_plan(W.plan)
    -- Surface the summary in the footer with a severity matched to the
    -- result mix.
    local sev = (result.failed == 0 and 'success') or
                (result.changed == 0 and 'error') or 'warning'
    local text = string.format('%d changed · %d failed', result.changed, result.failed)
    if W.sms_window and W.sms_window.set_status then
        pcall(W.sms_window.set_status, W.sms_window, text, sev)
    end
    -- Re-snapshot reader values so the preview shows the post-mutation state.
    recompute_plan()
    M.rebuild_preview()
end

local SCOPE_LABEL = {
    group = 'Group', unit = 'Unit', waypoint = 'Waypoint',
    zone = 'Zone', drawing = 'Drawing',
}

function M.update_scope_counts()
    if not W.widgets.scope_counts then return end
    local counts = scope_pool_counts()
    -- Each tab widget shows "<scope> · <count>". Re-render the full string;
    -- the tab widget IS the label widget (single Static), so we must include
    -- the scope name or it gets dropped.
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

-- Single source of truth for child widget geometry. Called once at the end of
-- build_window and again on every sms_window resize. Mirrors prefab_manager's
-- relayout(w, h) pattern. All positions are derived from outer (w, h); no
-- widget owns a hard-coded coordinate.
local LAYOUT = {
    EDGE             = 8,    -- left/right padding inside the window
    TOP_Y            = 4,    -- top of the tab strip
    TAB_H            = 28,
    TAB_W            = 100,  -- per-tab width (5 tabs fit at min_w=720)
    ROW_H            = 24,   -- standard row height (EditBox / ComboBox)
    GAP              = 4,    -- vertical/horizontal gap between rows / panes
    BTN_H            = 26,
    BTN_W            = 80,
    REFRESH_W        = 90,
    SPLIT_GUTTER     = 4,    -- gutter between left (tree) and right (panel) panes
    FOOTER_RESERVED  = 80,   -- bottom band reserved for sms_window's footer
}

local function relayout(w, h)
    if not (W.sms_window and W.sms_window:raw()) then return end
    local L = LAYOUT
    local function set(widget, x, y, ww, hh)
        if widget and widget.setBounds then
            pcall(widget.setBounds, widget, x, y, ww, hh)
        end
    end

    -- Row 0: scope tabs (left-anchored) + Refresh button (right-anchored).
    local tab_x = L.EDGE
    for _, scope in ipairs(SCOPES) do
        set(W.widgets.scope_tabs[scope], tab_x, L.TOP_Y, L.TAB_W, L.TAB_H)
        tab_x = tab_x + L.TAB_W + L.GAP
    end
    set(W.widgets.refresh_btn, w - L.EDGE - L.REFRESH_W, L.TOP_Y, L.REFRESH_W, L.TAB_H)

    -- Horizontal split: 50/50 between treeview pane (left) and property /
    -- preview pane (right), with a small gutter.
    local left_w  = math.floor((w - 2 * L.EDGE - L.SPLIT_GUTTER) / 2)
    local right_x = L.EDGE + left_w + L.SPLIT_GUTTER
    local right_w = w - L.EDGE - right_x

    -- Row 1: name filter (left) + property combo (right).
    local row1_y = L.TOP_Y + L.TAB_H + L.GAP                            -- 36
    set(W.widgets.name_filter,  L.EDGE, row1_y, left_w,  L.ROW_H)
    set(W.widgets.property_sel, right_x, row1_y, right_w, L.ROW_H)

    -- Right pane stacked rows: operation, args summary, args input.
    local row2_y = row1_y + L.ROW_H + L.GAP                             -- 64
    local row3_y = row2_y + L.ROW_H + L.GAP                             -- 92
    local row4_y = row3_y + L.ROW_H + L.GAP                             -- 120
    set(W.widgets.operation_sel, right_x, row2_y, right_w, L.ROW_H)
    set(W.widgets.args_panel,    right_x, row3_y, right_w, L.ROW_H)
    set(W.widgets.set_all_edit,  right_x, row4_y, right_w, L.ROW_H)

    -- Bottom button band (anchored to bottom).
    local btn_y       = h - L.FOOTER_RESERVED - L.BTN_H - L.GAP
    local body_bottom = btn_y - L.GAP
    set(W.widgets.apply_btn,  w - L.EDGE - L.BTN_W,                        btn_y, L.BTN_W, L.BTN_H)
    set(W.widgets.cancel_btn, w - L.EDGE - L.BTN_W - L.GAP - L.BTN_W,      btn_y, L.BTN_W, L.BTN_H)

    -- Body fills the space between the top rows and the button band.
    -- Treeview starts just below the name filter (row2_y); preview list
    -- starts below the args input (row4_y + ROW_H + GAP).
    local tree_y      = row2_y
    local tree_h      = math.max(60, body_bottom - tree_y)
    local preview_y   = row4_y + L.ROW_H + L.GAP                        -- 148
    local preview_h   = math.max(60, body_bottom - preview_y)
    set(W.widgets.tree,         L.EDGE,  tree_y,    left_w,  tree_h)
    set(W.widgets.preview_grid, right_x, preview_y, right_w, preview_h)
end
M._relayout = relayout

-- ---------------------------------------------------------------------------
-- Window construction.
-- ---------------------------------------------------------------------------

-- Build a single tab "button" out of a Static + click handler, since dxgui
-- doesn't have a Tab widget. Highlight the active tab by swapping skin.
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
    if not tab then
        local ok_s, Static = pcall(require, 'Static')
        if ok_s and Static and Static.new then
            local ok3, s = pcall(Static.new)
            if ok3 then tab = s end
        end
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
        title    = 'Mass Edit',
        size     = { w = 900, h = 600 },
        min_size = { w = 720, h = 500 },
        on_undo  = sms_window.default_on_undo,
        -- on_resize fires after every user-driven resize. Use the dxgui
        -- Window's outer dimensions (raw():getSize()) — same pattern as
        -- prefab_manager.lua — so relayout's anchors match the chrome.
        on_resize = function(swin)
            pcall(function()
                local cw, ch = swin:raw():getSize()
                relayout(cw, ch)
            end)
        end,
    })
    if not W.sms_window then
        log_warn('sms_window.new returned nil')
        return
    end

    local raw = W.sms_window:raw()
    if not raw then
        log_warn('sms_window:raw() returned nil')
        return
    end

    -- ----- scope tab strip ----------------------------------------------
    local tab_y = 4
    local tab_w = 140
    local tab_x = 8
    for _, scope in ipairs(SCOPES) do
        local label_map = { group = 'Group', unit = 'Unit', waypoint = 'Waypoint',
                            zone = 'Zone', drawing = 'Drawing' }
        local tab, count_lbl = make_scope_tab(scope, label_map[scope], '0', on_scope_changed)
        if tab then
            if tab.setBounds then pcall(tab.setBounds, tab, tab_x, tab_y, tab_w, 28) end
            pcall(raw.insertWidget, raw, tab)
            W.widgets.scope_tabs[scope] = tab
            W.widgets.scope_counts[scope] = count_lbl
            tab_x = tab_x + tab_w + 4
        end
    end

    -- ----- Refresh button (top-right of tab strip) ----------------------
    local ok_btn, Button = pcall(require, 'Button')
    local refresh_btn
    if ok_btn and Button and Button.new then
        local ok2, b = pcall(Button.new)
        if ok2 then refresh_btn = b end
    end
    if refresh_btn then
        try_skin(refresh_btn, 'dtc_button')
        if refresh_btn.setText then pcall(refresh_btn.setText, refresh_btn, 'Refresh') end
        if refresh_btn.setBounds then pcall(refresh_btn.setBounds, refresh_btn, 800, 4, 90, 28) end
        if refresh_btn.addMouseDownCallback then
            pcall(refresh_btn.addMouseDownCallback, refresh_btn, on_refresh_clicked)
        end
        pcall(raw.insertWidget, raw, refresh_btn)
        W.widgets.refresh_btn = refresh_btn
    end

    -- ----- treeview + filters (left half) -------------------------------
    local ok_eb, EditBox = pcall(require, 'EditBox')
    local ok_cb, ComboBox = pcall(require, 'ComboBox')
    if ok_eb and EditBox and EditBox.new then
        local ok2, name_filter = pcall(EditBox.new)
        if ok2 and name_filter then
            try_skin(name_filter, 'editBoxSkin_ME')
            if name_filter.setBounds then pcall(name_filter.setBounds, name_filter, 8, 40, 200, 24) end
            if name_filter.addChangeCallback then
                pcall(name_filter.addChangeCallback, name_filter, function(ed)
                    local txt = ed.getText and ed:getText() or ''
                    W.filters[W.scope].name_substr = txt
                    M.rebuild_treeview()
                    recompute_plan(); M.rebuild_preview()
                end)
            end
            pcall(raw.insertWidget, raw, name_filter)
            W.widgets.name_filter = name_filter
        end
    end

    -- Treeview surface: a real multi-column Grid (built lazily per scope by
    -- build_tree_widget so the column set tracks the active scope). The
    -- first build happens in M.show() after _built is flipped true.
    local ok_lb, ListBox = pcall(require, 'ListBox')  -- still required below for the preview list

    -- ----- right panel handles (filled in by task 13) -------------------
    if ok_cb and ComboBox and ComboBox.new then
        local ok2, property_sel = pcall(ComboBox.new)
        if ok2 and property_sel then
            try_skin(property_sel, 'comboListSkinNew_')
            if property_sel.setBounds then pcall(property_sel.setBounds, property_sel, 450, 40, 240, 24) end
            pcall(raw.insertWidget, raw, property_sel)
            W.widgets.property_sel = property_sel
        end
        local ok3, operation_sel = pcall(ComboBox.new)
        if ok3 and operation_sel then
            try_skin(operation_sel, 'comboListSkinNew_')
            if operation_sel.setBounds then pcall(operation_sel.setBounds, operation_sel, 700, 40, 190, 24) end
            pcall(raw.insertWidget, raw, operation_sel)
            W.widgets.operation_sel = operation_sel
        end
    end

    if Static and Static.new then
        local ok2, args_panel = pcall(Static.new)
        if ok2 and args_panel then
            try_skin(args_panel, 'staticSkin_ME')
            if args_panel.setBounds then pcall(args_panel.setBounds, args_panel, 450, 72, 440, 100) end
            pcall(raw.insertWidget, raw, args_panel)
            W.widgets.args_panel = args_panel
        end
    end

    if ok_lb and ListBox and ListBox.new then
        local ok2, preview = pcall(ListBox.new)
        if ok2 and preview then
            try_skin(preview, 'listBoxSkin_ME')
            if preview.setBounds then pcall(preview.setBounds, preview, 450, 180, 440, 320) end
            pcall(raw.insertWidget, raw, preview)
            W.widgets.preview_grid = preview
        end
    end

    if ok_btn and Button and Button.new then
        local ok2, cancel = pcall(Button.new)
        if ok2 and cancel then
            try_skin(cancel, 'dtc_button')
            if cancel.setText then pcall(cancel.setText, cancel, 'Cancel') end
            if cancel.setBounds then pcall(cancel.setBounds, cancel, 720, 510, 80, 26) end
            if cancel.addMouseDownCallback then
                pcall(cancel.addMouseDownCallback, cancel, function() M.hide() end)
            end
            pcall(raw.insertWidget, raw, cancel)
            W.widgets.cancel_btn = cancel
        end

        local ok3, apply = pcall(Button.new)
        if ok3 and apply then
            try_skin(apply, 'dtc_button')
            if apply.setText then pcall(apply.setText, apply, 'Apply') end
            if apply.setBounds then pcall(apply.setBounds, apply, 810, 510, 80, 26) end
            if apply.addMouseDownCallback then
                pcall(apply.addMouseDownCallback, apply, function() M.on_apply_clicked() end)
            end
            pcall(raw.insertWidget, raw, apply)
            W.widgets.apply_btn = apply
        end
    end

    W._built = true

    -- Initial layout pass — all child widgets have been inserted with
    -- placeholder bounds above; this is where they get their real positions.
    pcall(function()
        local cw, ch = W.sms_window:raw():getSize()
        relayout(cw, ch)
    end)
end

function M.show()
    build_window()
    if not W.sms_window then return end
    -- Build the Grid for the active scope on first show. on_scope_changed
    -- rebuilds it on subsequent scope switches.
    if not W.widgets.tree then M._build_tree_widget() end
    rebuild_pool()
    M.update_scope_counts()
    M.rebuild_treeview()
    M.rebuild_property_panel()
    recompute_plan()
    M.rebuild_preview()
    -- The Grid is rebuilt by _build_tree_widget which set its own bounds;
    -- re-relayout so it picks up the current dimensions instead.
    pcall(function()
        local cw, ch = W.sms_window:raw():getSize()
        relayout(cw, ch)
    end)
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
M._W = W
M._scope_pool_counts = scope_pool_counts
M._recompute_plan    = recompute_plan
M._rebuild_pool      = rebuild_pool
M._on_scope_changed  = on_scope_changed
M._on_refresh_clicked = on_refresh_clicked

return M
