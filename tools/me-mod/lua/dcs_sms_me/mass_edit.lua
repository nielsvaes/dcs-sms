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

local SCOPE_COLUMNS = {
    group    = { 'Name', 'Country', 'Type', '# Units' },
    unit     = { 'Name', 'Type', 'Skill', 'Group' },
    waypoint = { 'Group', '#', 'Type', 'Alt', 'Speed' },
    zone     = { 'Name', 'Radius' },
    drawing  = { 'Name', 'Layer' },
}

local function row_values(scope, entity, group)
    if scope == 'group' then
        return { tostring(entity.name or ''), tostring(entity.country or ''),
                 tostring(entity.category or ''), tostring(#(entity.units or {})) }
    elseif scope == 'unit' then
        return { tostring(entity.name or ''), tostring(entity.type or ''),
                 tostring(entity.skill or ''), tostring((group or {}).name or '') }
    elseif scope == 'waypoint' then
        local idx = ''
        if group and group.route and group.route.points then
            for i, p in ipairs(group.route.points) do
                if p == entity then idx = tostring(i); break end
            end
        end
        return { tostring((group or {}).name or ''), idx,
                 tostring(entity.type or ''),
                 tostring(entity.alt or ''),
                 tostring(entity.speed or '') }
    elseif scope == 'zone' then
        return { tostring(entity.name or ''), tostring(entity.radius or '') }
    elseif scope == 'drawing' then
        return { tostring(entity.name or ''),
                 tostring((entity.layer and entity.layer.name) or '') }
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

function M.rebuild_treeview()
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
    W._tree_rows = rows
    W._tree_columns = SCOPE_COLUMNS[W.scope] or {}

    if W.widgets.tree and W.widgets.tree.repaint then
        pcall(W.widgets.tree.repaint, W.widgets.tree, rows, W._tree_columns)
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
                local raw = W.sms_window and W.sms_window:raw()
                if ed.setBounds then
                    pcall(ed.setBounds, ed, 460, 110, 360, 24)
                end
                if raw then pcall(raw.insertWidget, raw, ed) end
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
function M.rebuild_preview()          W._preview_dirty = true end
function M.update_scope_counts()
    if not W.widgets.scope_counts then return end
    local counts = scope_pool_counts()
    for scope, lbl in pairs(W.widgets.scope_counts) do
        if lbl and lbl.setText then pcall(lbl.setText, lbl, tostring(counts[scope] or 0)) end
    end
end

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
        on_resize = function(handle, x, y, w, h)
            -- Future: respond to resize.
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

    -- ListBox as the treeview surface.
    local ok_lb, ListBox = pcall(require, 'ListBox')
    local tree
    if ok_lb and ListBox and ListBox.new then
        local ok2, t = pcall(ListBox.new)
        if ok2 then tree = t end
    end
    if tree then
        if tree.setBounds then pcall(tree.setBounds, tree, 8, 72, 430, 460) end
        pcall(raw.insertWidget, raw, tree)
        tree.repaint = function(self, rows, columns)
            if self.removeAllItems then pcall(self.removeAllItems, self) end
            local ok_lbi, ListBoxItem = pcall(require, 'ListBoxItem')
            if not (ok_lbi and ListBoxItem and ListBoxItem.new) then return end
            for _, r in ipairs(rows) do
                local text = ''
                for ci, v in ipairs(r.values) do
                    text = text .. (ci > 1 and '  ·  ' or '') .. v
                end
                local ok3, item = pcall(ListBoxItem.new)
                if ok3 and item then
                    if item.setText then pcall(item.setText, item, (r.checked and '[X] ' or '[ ] ') .. text) end
                    item._row = r
                    if item.addMouseDownCallback then
                        pcall(item.addMouseDownCallback, item, function()
                            W.checked[W.scope][r.entity] = not W.checked[W.scope][r.entity] or nil
                            M.rebuild_treeview()
                            recompute_plan(); M.rebuild_preview()
                        end)
                    end
                    pcall(self.insertItem, self, item)
                end
            end
        end
        W.widgets.tree = tree
    end

    -- ----- right panel handles (filled in by task 13) -------------------
    if ok_cb and ComboBox and ComboBox.new then
        local ok2, property_sel = pcall(ComboBox.new)
        if ok2 and property_sel then
            if property_sel.setBounds then pcall(property_sel.setBounds, property_sel, 450, 40, 240, 24) end
            pcall(raw.insertWidget, raw, property_sel)
            W.widgets.property_sel = property_sel
        end
        local ok3, operation_sel = pcall(ComboBox.new)
        if ok3 and operation_sel then
            if operation_sel.setBounds then pcall(operation_sel.setBounds, operation_sel, 700, 40, 190, 24) end
            pcall(raw.insertWidget, raw, operation_sel)
            W.widgets.operation_sel = operation_sel
        end
    end

    local ok_s, Static = pcall(require, 'Static')
    if ok_s and Static and Static.new then
        local ok2, args_panel = pcall(Static.new)
        if ok2 and args_panel then
            if args_panel.setBounds then pcall(args_panel.setBounds, args_panel, 450, 72, 440, 100) end
            pcall(raw.insertWidget, raw, args_panel)
            W.widgets.args_panel = args_panel
        end
    end

    if ok_lb and ListBox and ListBox.new then
        local ok2, preview = pcall(ListBox.new)
        if ok2 and preview then
            if preview.setBounds then pcall(preview.setBounds, preview, 450, 180, 440, 320) end
            pcall(raw.insertWidget, raw, preview)
            W.widgets.preview_grid = preview
        end
    end

    if ok_btn and Button and Button.new then
        local ok2, cancel = pcall(Button.new)
        if ok2 and cancel then
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
end

function M.show()
    build_window()
    if not W.sms_window then return end
    rebuild_pool()
    M.update_scope_counts()
    M.rebuild_treeview()
    M.rebuild_property_panel()
    recompute_plan()
    M.rebuild_preview()
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
