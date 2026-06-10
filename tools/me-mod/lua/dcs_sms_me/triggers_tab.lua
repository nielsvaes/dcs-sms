-- triggers_tab.lua — the Prefab Manager 'Triggers' tab (spec §2 Flow A).
-- Master–detail over mission.trigrules: checkable grid left, resolved
-- detail + portability report right, save form bottom. Saved output is a
-- normal .prefab (triggers-only) via prefab_ops.save_trigger_prefab.
--
-- Pure helpers (refs_summary / detail_text) are standalone-testable; all
-- dxgui work is pcall-guarded and follows mass_edit.lua's grid pattern
-- (grid build: mass_edit ~643-684; row rebuild: ~763-901; checkbox +
-- shift range fill: ~73-80 + ~808-851; bulk buttons: ~1192-1237) and
-- community_tab.lua's detail TextBox (~587-601).

local schema_mod = require('dcs_sms_me.trigger_schema')
local export     = require('dcs_sms_me.trigger_export')
local prefab_ops = require('dcs_sms_me.prefab_ops')

local M = {}

-- Walk one trigrules entry's structured fields; call fn(kind_badge) for
-- each portability-relevant ref ('group'/'unit'/'zone'/'airdrome'),
-- 'media' for ResKey values, 'text' for DictKey values.
local function walk_badges(t, schema, fn)
    for _, list in ipairs({ t.rules or {}, t.actions or {} }) do
        for _, entry in ipairs(list) do
            local _, _, descr = schema:resolve(schema.predicate_name(entry.predicate))
            for k, v in pairs(entry) do
                if k ~= 'predicate' then
                    if type(v) == 'string' and v:sub(1, 7) == 'ResKey_' then
                        fn('media')
                    elseif type(v) == 'number' then
                        local fd = schema.field_descr(descr, k)
                        local kind = fd and schema:field_kind(fd)
                        if kind == 'group' or kind == 'unit' or kind == 'zone'
                                or kind == 'airdrome' then
                            fn(kind)
                        end
                    end
                end
            end
        end
    end
end

-- refs_summary(trigger, schema) → '✓' | 'group zone media' (sorted unique)
function M.refs_summary(t, schema)
    local seen, badges = {}, {}
    walk_badges(t, schema, function(b)
        if not seen[b] then seen[b] = true; badges[#badges + 1] = b end
    end)
    if #badges == 0 then return '\xE2\x9C\x93' end  -- ✓
    table.sort(badges)
    return table.concat(badges, ' ')
end

-- detail_text(trigger, schema, env) → multiline string for the detail
-- pane. env = { schema not needed here, dict_get, entity_name,
-- media_short = fn(ResKey) → short|nil }.
function M.detail_text(t, schema, env)
    local lines = {}
    lines[#lines + 1] = (t.comment or '?') .. '  (' .. schema.make_alias(t.predicate) .. ')'
    if (t.eventlist or '') ~= '' then
        lines[#lines + 1] = 'event: ' .. tostring(t.eventlist)
    end
    local refs, media, flags = {}, {}, {}

    local function render_list(label, list)
        lines[#lines + 1] = ''
        lines[#lines + 1] = label
        if not list or #list == 0 then
            lines[#lines + 1] = '  (none)'
            return
        end
        for _, entry in ipairs(list) do
            local pname = schema.predicate_name(entry.predicate)
            local _, _, descr = schema:resolve(pname)
            lines[#lines + 1] = '  - ' .. schema.make_alias(pname)
            for k, v in pairs(entry) do
                if k ~= 'predicate' and type(k) == 'string'
                        and k:sub(1, 8) ~= 'KeyDict_' then
                    local fd = schema.field_descr(descr, k)
                    local kind = fd and schema:field_kind(fd)
                    local shown
                    if type(v) == 'string' and v:sub(1, 8) == 'DictKey_' then
                        shown = (env.dict_get and env.dict_get(v)) or v
                    elseif type(v) == 'string' and v:sub(1, 7) == 'ResKey_' then
                        local short = env.media_short and env.media_short(v)
                        shown = short or v
                        media[shown] = true
                    elseif (kind == 'group' or kind == 'unit' or kind == 'zone'
                            or kind == 'airdrome') and type(v) == 'number' then
                        local nm = env.entity_name and env.entity_name(kind, v)
                        shown = (nm or '?') .. ' (' .. kind .. ' ' .. tostring(v) .. ')'
                        refs[shown] = true
                    elseif type(v) == 'table' then
                        shown = '<table>'
                    else
                        shown = tostring(v)
                    end
                    if k:match('^flag%d*$')
                            and (type(v) == 'number' or type(v) == 'string') then
                        flags[tostring(v)] = true
                    end
                    if #shown > 70 then shown = shown:sub(1, 67) .. '...' end
                    lines[#lines + 1] = '      ' .. k .. ' = ' .. shown
                end
            end
        end
    end
    render_list('Conditions', t.rules)
    render_list('Actions', t.actions)

    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Portability'
    local function set_to_line(prefix, set)
        local arr = {}
        for k in pairs(set) do arr[#arr + 1] = k end
        if #arr > 0 then
            table.sort(arr)
            lines[#lines + 1] = '  ' .. prefix .. table.concat(arr, ', ')
        end
    end
    set_to_line('entity refs: ', refs)
    set_to_line('media: ', media)
    set_to_line('flags: ', flags)
    if not (next(refs) or next(media)) then
        lines[#lines + 1] = '  \xE2\x9C\x93 no entity refs, no media'
    end
    return table.concat(lines, '\n')
end

-- ------------------------------------------------------------------
-- Widget half — M.build(host). pcall-guarded throughout; returns nil
-- when dxgui classes are unavailable (test VM).
-- ------------------------------------------------------------------

-- dxgui modules. pcall-required so the file still loads in test VMs
-- (same shape as mass_edit.lua's preamble).
local Static;         do local ok, m = pcall(require, 'Static');         if ok then Static         = m end end
local Grid;           do local ok, m = pcall(require, 'Grid');           if ok then Grid           = m end end
local GridHeaderCell; do local ok, m = pcall(require, 'GridHeaderCell'); if ok then GridHeaderCell = m end end
local CheckBox;       do local ok, m = pcall(require, 'CheckBox');       if ok then CheckBox       = m end end
local Button;         do local ok, m = pcall(require, 'Button');         if ok then Button         = m end end

-- Text-input class: EditBox is canonical, TextBox an older alias. Mirrors
-- prefab_manager.lua's resolution so the form inputs work on either build.
local TextBox
do
    local ok, mod = pcall(require, 'EditBox')
    if ok then TextBox = mod
    else
        local ok2, mod2 = pcall(require, 'TextBox')
        if ok2 then TextBox = mod2 end
    end
end

-- dxgui module: live keyboard state during a click handler, so shift-click
-- can extend a checkbox range (mass_edit.lua's shift_held, copied).
local dxgui;          do local ok, m = pcall(require, 'dxgui');          if ok then dxgui          = m end end

local function shift_held()
    if not (dxgui and dxgui.GetKeyboardButtonPressed) then return false end
    local ok_l, l = pcall(dxgui.GetKeyboardButtonPressed, 'left shift')
    if ok_l and l then return true end
    local ok_r, r = pcall(dxgui.GetKeyboardButtonPressed, 'right shift')
    return ok_r and r == true
end

-- House helpers, all guarded so the module loads headless.
local skin_helper;    do local ok, m = pcall(require, 'dcs_sms_me.skin_helper');    if ok then skin_helper    = m end end
local clearable_edit; do local ok, m = pcall(require, 'dcs_sms_me.clearable_edit'); if ok then clearable_edit = m end end
local sms_scrollbars; do local ok, m = pcall(require, 'dcs_sms_me.sms_scrollbars'); if ok then sms_scrollbars = m end end
local trigger_media;  do local ok, m = pcall(require, 'dcs_sms_me.trigger_media');  if ok then trigger_media  = m end end

local function try_skin(widget, name)
    if skin_helper then pcall(skin_helper.apply, widget, name) end
end

local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.prefab', _G.log.WARNING or 2, msg) end)
end

local function trim(s)
    return (tostring(s or ''):match('^%s*(.-)%s*$')) or ''
end

-- Grid columns (plan Task 10 spec): check / name / type / C / A / refs.
-- Every non-check column is header-click sortable.
local COLUMNS = {
    { key = 'check', label = '',     width = 26  },
    { key = 'name',  label = 'Name', width = 190 },
    { key = 'type',  label = 'Type', width = 70  },
    { key = 'c',     label = 'C',    width = 30  },
    { key = 'a',     label = 'A',    width = 30  },
    { key = 'refs',  label = 'Refs', width = 110 },
}
local NUMERIC_COLS = { c = true, a = true }

-- Build the live-editor env handed to detail_text / export.to_portable.
-- Everything resolves lazily and pcall-guarded: outside the editor this
-- returns an env with schema = nil, which callers treat as "no data".
local function live_env()
    local env = {}
    env.schema = schema_mod.from_editor()

    -- DictKey → literal text via the editor dictionary.
    pcall(function()
        local dict = require('dictionary')
        if type(dict.getValueDict) == 'function' then
            env.dict_get = function(key)
                local ok, v = pcall(dict.getValueDict, key)
                if ok and type(v) == 'string' then return v end
                return nil
            end
        end
    end)

    -- group/unit names via me_mission's by-id maps; zone names via the
    -- TriggerZoneData controller (zones don't live in the mission table —
    -- same indirection zone_verbs.lua uses); airdromes show their raw id.
    env.entity_name = function(kind, id)
        local name
        pcall(function()
            if kind == 'group' or kind == 'unit' then
                local Mission = require('me_mission')
                local map = (kind == 'group') and Mission.group_by_id or Mission.unit_by_id
                local e = type(map) == 'table' and map[id]
                if type(e) == 'table' and e.name ~= nil then name = tostring(e.name) end
            elseif kind == 'zone' then
                local TZD = require('Mission.TriggerZoneData')
                if type(TZD.getTriggerZoneName) == 'function' then
                    local n = TZD.getTriggerZoneName(id)
                    if type(n) == 'string' then name = n end
                end
            elseif kind == 'airdrome' then
                name = tostring(id)
            end
        end)
        return name
    end

    -- ResKey → embedded resource bytes (export) / short filename (detail).
    env.media_read = function(res_key)
        if not (trigger_media and trigger_media.read) then return nil, 'media module unavailable' end
        return trigger_media.read(res_key)
    end
    env.media_short = function(res_key)
        local short = env.media_read(res_key)
        if type(short) == 'string' then return short end
        return nil
    end
    return env
end

-- build(host) → panel | nil
--   host  = { raw = <sms_window raw Window>, set_status = fn(msg, sev),
--             refresh_library = fn() }
--   panel = { show = fn, hide = fn, relayout = fn(w, h), refresh = fn }
function M.build(host)
    host = host or {}
    local raw = host.raw
    -- Headless / degraded dxgui: no grid means no usable tab — bail so the
    -- manager falls back to the My Prefabs tab (Task 12's ensure_triggers).
    if not (raw and raw.insertWidget and Grid and Grid.new
            and GridHeaderCell and GridHeaderCell.new
            and Static and Static.new and Button and Button.new) then
        return nil
    end

    local function set_status(msg, sev)
        if type(host.set_status) == 'function' then
            pcall(host.set_status, tostring(msg or ''), sev)
        end
    end

    -- Instance state (community_tab's W pattern — one table per build).
    local W = {
        widgets     = {},      -- every top-level widget, for show/hide en masse
        all         = {},      -- every trigrules row {entity, values, checked}
        rows        = {},      -- filtered + sorted subset currently in the grid
        checked     = {},      -- trigrules ENTRY TABLE (identity) → true
        anchor      = nil,     -- entry the next shift-click extends FROM
        filter_text = '',
        sort        = { key = nil, dir = 'asc' },  -- nil key = mission order
        headers     = {},      -- GridHeaderCell per column, for sort arrows
        env         = nil,     -- live_env() of the latest refresh
        cw = 920, ch = 612,    -- last relayout size
    }

    local function track(widget)
        if not widget then return widget end
        W.widgets[#W.widgets + 1] = widget
        pcall(function() raw:insertWidget(widget) end)
        return widget
    end

    local function bounds(widget, x, y, w, h)
        if not widget then return end
        pcall(function() if widget.setBounds then widget:setBounds(x, y, w, h) end end)
    end

    local function make_cell(text, tooltip)
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

    -- Forward decls (callbacks below reference these before assignment).
    local rebuild_rows, refresh, relayout

    -- -------------------------------------------------------------------
    -- Detail pane plumbing.
    -- -------------------------------------------------------------------
    local DETAIL_PLACEHOLDER = 'Click a trigger row to see its details.'

    local function show_detail(entry)
        pcall(function()
            if not (W.detail and W.detail.setText) then return end
            local env = W.env
            if not (entry and env and env.schema) then
                W.detail:setText(DETAIL_PLACEHOLDER)
                return
            end
            local ok, text = pcall(M.detail_text, entry, env.schema, env)
            W.detail:setText(ok and text or DETAIL_PLACEHOLDER)
        end)
    end

    -- -------------------------------------------------------------------
    -- Sort (mass_edit sort_rows + update_sort_indicators, instance-local).
    -- -------------------------------------------------------------------
    local function update_sort_indicators()
        for i, c in ipairs(COLUMNS) do
            local hc = W.headers[i]
            if hc and hc.setText then
                local label = c.label
                if W.sort.key == c.key and c.key ~= 'check' then
                    label = label .. (W.sort.dir == 'desc' and ' \226\150\188' or ' \226\150\178')
                end
                pcall(hc.setText, hc, label)
            end
        end
    end

    local function sort_rows(rows)
        local key = W.sort.key
        if not key or key == 'check' then return end  -- mission order
        local asc, numeric = W.sort.dir ~= 'desc', NUMERIC_COLS[key] == true
        for i, r in ipairs(rows) do r._idx = i end
        table.sort(rows, function(a, b)
            local av, bv = a.values[key], b.values[key]
            if numeric then av, bv = tonumber(av) or 0, tonumber(bv) or 0
            else            av, bv = tostring(av or ''):lower(), tostring(bv or ''):lower() end
            if av == bv then return a._idx < b._idx end
            if asc then return av < bv else return av > bv end
        end)
        for _, r in ipairs(rows) do r._idx = nil end
    end

    -- -------------------------------------------------------------------
    -- Grid construction (mass_edit build_tree_widget shape; built once —
    -- the column set never changes, unlike mass_edit's per-scope rebuild).
    -- -------------------------------------------------------------------
    do
        local ok_grid, grid = pcall(Grid.new)
        if not (ok_grid and grid) then
            log_warn('triggers_tab: Grid.new failed')
            return nil
        end
        try_skin(grid, 'sms_grid')
        for i, c in ipairs(COLUMNS) do
            local ok_hc, hc = pcall(GridHeaderCell.new)
            if ok_hc and hc then
                try_skin(hc, 'sms_grid_header')
                if hc.setText then pcall(hc.setText, hc, c.label) end
                if c.key ~= 'check' and hc.addChangeCallback then
                    local key = c.key
                    pcall(hc.addChangeCallback, hc, function()
                        pcall(function()
                            if W.sort.key == key then
                                W.sort.dir = (W.sort.dir == 'asc') and 'desc' or 'asc'
                            else
                                W.sort.key = key; W.sort.dir = 'asc'
                            end
                            rebuild_rows()
                        end)
                    end)
                end
                W.headers[i] = hc
                pcall(grid.insertColumn, grid, c.width, hc)
            end
        end

        -- Row-body click: shift extends the checkbox range from the anchor
        -- (mass_edit ~705-720); plain click renders the detail pane and
        -- re-anchors. col 0 is the checkbox cell — its own callback handles it.
        grid.onMouseDown = function(self, x, y, button)
            if button ~= 1 then return end
            pcall(function()
                local col_idx, row_idx = self:getMouseCursorColumnRow(x, y)
                if not (row_idx and row_idx >= 0) then return end
                if col_idx == 0 then return end
                local rows = W.rows
                local r = rows and rows[row_idx + 1]
                if not r then return end

                local anchor_idx
                if W.anchor then
                    for i, rr in ipairs(rows) do
                        if rr.entity == W.anchor then anchor_idx = i; break end
                    end
                end

                if shift_held() and anchor_idx then
                    -- Range fill: every row from anchor to clicked row,
                    -- inclusive, gets the anchor's checked state. Anchor is
                    -- NOT updated so repeated shift-clicks extend from the
                    -- same origin (Explorer / GTK style — mass_edit verbatim).
                    local clicked_idx  = row_idx + 1
                    local from         = math.min(anchor_idx, clicked_idx)
                    local to           = math.max(anchor_idx, clicked_idx)
                    local target_state = W.checked[W.anchor] == true
                    for i = from, to do
                        local e = rows[i] and rows[i].entity
                        if e then W.checked[e] = target_state or nil end
                    end
                    rebuild_rows()
                else
                    show_detail(r.entity)
                    W.anchor = r.entity
                end
            end)
        end

        track(grid)
        W.grid = grid
        update_sort_indicators()
    end

    -- -------------------------------------------------------------------
    -- Row rebuild with scroll preservation (mass_edit rebuild_treeview).
    -- -------------------------------------------------------------------
    rebuild_rows = function()
        local rows = {}
        local needle = W.filter_text:lower()
        for _, r in ipairs(W.all) do
            if needle == '' or tostring(r.values.name or ''):lower():find(needle, 1, true) then
                r.checked = W.checked[r.entity] == true
                rows[#rows + 1] = r
            end
        end
        sort_rows(rows)
        W.rows = rows
        update_sort_indicators()

        local grid = W.grid
        if not grid then return end

        -- Capture scroll position so the rebuild doesn't jump the view back
        -- to the top after every checkbox click / range fill / bulk button.
        local saved_v, saved_h
        if grid.getVertScrollPosition then
            local ok_v, v = pcall(grid.getVertScrollPosition, grid); if ok_v then saved_v = v end
        end
        if grid.getHorzScrollPosition then
            local ok_h, hp = pcall(grid.getHorzScrollPosition, grid); if ok_h then saved_h = hp end
        end

        pcall(grid.removeAllRows, grid)

        for i, r in ipairs(rows) do
            pcall(grid.insertRow, grid, nil)
            local row_idx = i - 1
            for col_idx, c in ipairs(COLUMNS) do
                if c.key == 'check' then
                    local cb = make_checkbox(r.checked)
                    if cb then
                        if cb.addChangeCallback then
                            local entity = r.entity
                            pcall(cb.addChangeCallback, cb, function(box)
                                pcall(function()
                                    local state = box.getState and box:getState() == true
                                    local cur_rows = W.rows or {}
                                    local anchor_entity = W.anchor

                                    -- Shift-click on a checkbox: same range-fill
                                    -- semantics as the row body. dxgui has already
                                    -- toggled the box visually, so find anchor +
                                    -- clicked indices in visible-row order, fill
                                    -- the range with the anchor's state, and
                                    -- rebuild so the display matches W.checked.
                                    -- Anchor stays put (mass_edit ~808-851).
                                    if shift_held() and anchor_entity and anchor_entity ~= entity then
                                        local anchor_idx, clicked_idx
                                        for i2, rr in ipairs(cur_rows) do
                                            if rr.entity == anchor_entity then anchor_idx  = i2 end
                                            if rr.entity == entity        then clicked_idx = i2 end
                                        end
                                        if anchor_idx and clicked_idx then
                                            local from = math.min(anchor_idx, clicked_idx)
                                            local to   = math.max(anchor_idx, clicked_idx)
                                            local target_state = W.checked[anchor_entity] == true
                                            for i2 = from, to do
                                                local e = cur_rows[i2] and cur_rows[i2].entity
                                                if e then W.checked[e] = target_state or nil end
                                            end
                                            rebuild_rows()
                                            return
                                        end
                                    end

                                    -- Plain click: record the toggle and update
                                    -- the anchor so a follow-up shift-click
                                    -- extends from here.
                                    W.checked[entity] = state or nil
                                    W.anchor = entity
                                end)
                            end)
                        end
                        pcall(grid.setCell, grid, col_idx - 1, row_idx, cb)
                    end
                else
                    local v = r.values[c.key]
                    local cell = make_cell((v == nil) and '' or tostring(v), tostring(v or ''))
                    if cell then pcall(grid.setCell, grid, col_idx - 1, row_idx, cell) end
                end
            end
        end

        -- Restore the pre-rebuild scroll position; must run after every
        -- insertRow so the grid knows its max scroll extent.
        if saved_v and grid.setVertScrollPosition then
            pcall(grid.setVertScrollPosition, grid, saved_v)
        end
        if saved_h and grid.setHorzScrollPosition then
            pcall(grid.setHorzScrollPosition, grid, saved_h)
        end
    end

    -- -------------------------------------------------------------------
    -- refresh — re-read mission.trigrules and rebuild everything. Called
    -- from show() so the list is fresh per spec, and exposed on the panel.
    -- -------------------------------------------------------------------
    refresh = function()
        pcall(function()
            W.env = live_env()
            local schema = W.env.schema
            local trigrules
            local ok_m, Mission = pcall(require, 'me_mission')
            if ok_m and type(Mission) == 'table' and type(Mission.mission) == 'table' then
                trigrules = Mission.mission.trigrules
            end

            W.all = {}
            local live = {}
            if type(trigrules) == 'table' and schema then
                for _, t in ipairs(trigrules) do
                    if type(t) == 'table' then
                        live[t] = true
                        local ok_refs, refs = pcall(M.refs_summary, t, schema)
                        W.all[#W.all + 1] = {
                            entity  = t,
                            values  = {
                                name = tostring(t.comment or ''),
                                type = schema.make_alias(t.predicate),
                                c    = #(t.rules or {}),
                                a    = #(t.actions or {}),
                                refs = ok_refs and refs or '?',
                            },
                            checked = W.checked[t] == true,
                        }
                    end
                end
            end
            -- Prune check/anchor state for entries that left the mission
            -- (deleted triggers, File > New): identity keys would otherwise
            -- pin dead trigger tables forever.
            for e in pairs(W.checked) do
                if not live[e] then W.checked[e] = nil end
            end
            if W.anchor and not live[W.anchor] then W.anchor = nil end

            rebuild_rows()
            show_detail(nil)
        end)
    end

    -- -------------------------------------------------------------------
    -- Filter row (clearable_edit preferred, plain EditBox fallback —
    -- community_tab's search-box resolution).
    -- -------------------------------------------------------------------
    do
        local function on_filter_change(txt)
            pcall(function()
                txt = tostring(txt or '')
                if txt == W.filter_text then return end
                W.filter_text = txt
                rebuild_rows()
            end)
        end
        local ce = clearable_edit and clearable_edit.new(raw, { on_change = on_filter_change })
        if ce then
            -- clearable_edit parents its own children; just track for show/hide.
            W.filter = ce
            W.widgets[#W.widgets + 1] = ce
            pcall(function()
                local target = (ce.widget and ce:widget()) or ce
                if target and target.setHintText then target:setHintText('Filter triggers by name') end
            end)
        elseif TextBox and TextBox.new then
            W.filter = track(TextBox.new())
            try_skin(W.filter, 'editBoxSkin_ME')
            if W.filter.addChangeCallback then
                pcall(W.filter.addChangeCallback, W.filter, function(box)
                    local txt = (box and box.getText and box:getText()) or ''
                    on_filter_change(txt)
                end)
            end
        end
    end

    -- -------------------------------------------------------------------
    -- Detail pane: READ-ONLY multiline EditBox (community_tab W.detail —
    -- a Static renders only the first line). setMultiline must run BEFORE
    -- setSkin (it rebuilds the scrollbar widgets).
    -- -------------------------------------------------------------------
    W.detail = track(TextBox and TextBox.new and TextBox.new())
    if W.detail then
        pcall(function() if W.detail.setMultiline then W.detail:setMultiline(true) end end)
        pcall(function() if W.detail.setTextWrapping then W.detail:setTextWrapping(true) end end)
        local skinned = false
        pcall(function()
            if sms_scrollbars and sms_scrollbars.themed_editbox_skin and W.detail.setSkin then
                W.detail:setSkin(sms_scrollbars.themed_editbox_skin({ mono = false }))
                skinned = true
            end
        end)
        if not skinned then try_skin(W.detail, 'editBoxSkin_ME') end
        pcall(function() if W.detail.setReadOnly then W.detail:setReadOnly(true) end end)
        pcall(function() if W.detail.setText then W.detail:setText(DETAIL_PLACEHOLDER) end end)
    end

    -- -------------------------------------------------------------------
    -- Bottom form row: [Select all][Clear] [Name][Folder] [Save].
    -- -------------------------------------------------------------------
    local function make_button(label, cb)
        local ok, b = pcall(Button.new)
        if not (ok and b) then return nil end
        try_skin(b, 'sms_button')
        if b.setText then pcall(b.setText, b, label) end
        if b.addMouseDownCallback then pcall(b.addMouseDownCallback, b, cb) end
        return track(b)
    end

    -- Select all acts on the VISIBLE (post-filter) rows; Clear wipes the
    -- whole selection regardless of filter (mass_edit bulk-button semantics).
    W.sel_all_btn = make_button('Select all', function()
        pcall(function()
            for _, r in ipairs(W.rows or {}) do W.checked[r.entity] = true end
            rebuild_rows()
        end)
    end)
    W.sel_clr_btn = make_button('Clear', function()
        pcall(function()
            W.checked = {}
            W.anchor = nil
            rebuild_rows()
        end)
    end)

    local function make_label(text)
        local s = track(Static.new(tostring(text)))
        try_skin(s, 'staticSkin_ME')
        return s
    end
    local function make_input(initial)
        if not (TextBox and TextBox.new) then return nil end
        local ok, eb = pcall(TextBox.new)
        if not (ok and eb) then return nil end
        try_skin(eb, 'editBoxSkin_ME')
        if eb.setText then pcall(eb.setText, eb, tostring(initial or '')) end
        return track(eb)
    end
    local function input_text(eb)
        if not eb then return '' end
        local txt = ''
        pcall(function() if eb.getText then txt = eb:getText() or '' end end)
        return txt
    end

    W.name_lbl     = make_label('Name')
    W.name_input   = make_input('')
    W.folder_lbl   = make_label('Folder')
    W.folder_input = make_input('Triggers')

    -- Save handler (plan Task 10): checked entries in trigrules ORDER →
    -- export.to_portable → prefab_ops.save_trigger_prefab. No overwrite
    -- dialog in v1 — a name collision is an error status and the user
    -- renames.
    local function on_save_click()
        pcall(function()
            local ok_m, Mission = pcall(require, 'me_mission')
            local trigrules = ok_m and type(Mission) == 'table'
                and type(Mission.mission) == 'table' and Mission.mission.trigrules
            if type(trigrules) ~= 'table' then
                set_status('No mission open — nothing to save.', 'warning')
                return
            end

            -- Walk trigrules (not the sorted/filtered view) so the saved
            -- prefab keeps mission order regardless of grid sort.
            local entries = {}
            for _, t in ipairs(trigrules) do
                if W.checked[t] then entries[#entries + 1] = t end
            end
            if #entries == 0 then
                set_status('Check at least one trigger first.', 'warning')
                return
            end

            local name = trim(input_text(W.name_input))
            if name == '' then
                set_status('Enter a prefab name.', 'warning')
                return
            end

            local folder = trim(input_text(W.folder_input))
            if folder == '' then folder = 'Triggers' end
            local fvalid, fwhy = prefab_ops._validate_folder_path(folder)
            if not fvalid then
                set_status('Invalid folder: ' .. tostring(fwhy), 'error')
                return
            end

            local env = live_env()
            if not env.schema then
                set_status('Trigger descriptors unavailable — is a mission open?', 'error')
                return
            end
            local payload, perr = export.to_portable(entries, env)
            if not payload then
                set_status('Export failed: ' .. tostring(perr), 'error')
                return
            end
            local nwarn = (type(payload.warnings) == 'table') and #payload.warnings or 0
            if nwarn > 0 then
                set_status(tostring(payload.warnings[1]), 'warning')
                log_warn('triggers_tab: ' .. nwarn .. ' export warning(s); first: '
                         .. tostring(payload.warnings[1]))
            end

            if prefab_ops.exists(name) then
                set_status('A prefab named "' .. name .. '" already exists — pick another name.', 'error')
                return
            end

            local ok_s, path_or_err = prefab_ops.save_trigger_prefab(name, folder, payload)
            if not ok_s then
                set_status('Save failed: ' .. tostring(path_or_err), 'error')
                return
            end
            -- Keep export warnings visible in the success line instead of
            -- silently overwriting the warning status set above.
            local suffix = (nwarn > 0)
                and (' (' .. nwarn .. ' warning' .. (nwarn == 1 and '' or 's') .. ' — see log)')
                or ''
            set_status('Saved ' .. #entries .. ' triggers \226\134\146 '
                       .. tostring(path_or_err) .. suffix, 'success')
            if type(host.refresh_library) == 'function' then
                pcall(host.refresh_library)
            end
        end)
    end

    W.save_btn = make_button('Save checked \226\134\146 prefab', on_save_click)

    -- -------------------------------------------------------------------
    -- Responsive layout. Receives the manager window's content size (same
    -- contract as community_tab): TOP clears the manager's tab strip,
    -- FOOTER reserves the sms_window status band, and the form row is
    -- pinned to the bottom of the usable area. Grid takes ~58% of the
    -- width on the left; the detail pane fills the rest.
    -- -------------------------------------------------------------------
    local PAD    = 12
    local ROW_H  = 24
    local TOP    = 44
    local GAP    = 6
    local FOOTER = 82

    relayout = function(w, h)
        w = tonumber(w) or W.cw
        h = tonumber(h) or W.ch
        W.cw, W.ch = w, h

        local grid_w   = math.max(220, math.floor((w - 2 * PAD - GAP) * 0.58))
        local detail_x = PAD + grid_w + GAP
        local detail_w = math.max(120, w - PAD - detail_x)

        -- Bottom form row, pinned just above the sms_window footer band.
        local form_y = math.max(TOP + 2 * ROW_H, h - FOOTER - ROW_H)

        -- Filter row top (over the grid column only).
        if W.filter and W.filter.set_bounds then
            pcall(function() W.filter:set_bounds(PAD, TOP, grid_w, ROW_H) end)
        else
            bounds(W.filter, PAD, TOP, grid_w, ROW_H)
        end

        -- Grid left (~58%), detail right, both down to the form row.
        local row2   = TOP + ROW_H + GAP
        local body_h = math.max(80, form_y - GAP - row2)
        bounds(W.grid, PAD, row2, grid_w, body_h)
        bounds(W.detail, detail_x, TOP, detail_w, form_y - GAP - TOP)

        -- Form row: bulk buttons left, save pinned right, name input takes
        -- the slack between the labels.
        local x = PAD
        bounds(W.sel_all_btn, x, form_y, 90, ROW_H); x = x + 90 + GAP
        bounds(W.sel_clr_btn, x, form_y, 70, ROW_H); x = x + 70 + 2 * GAP

        local save_w  = 170
        local save_x  = w - PAD - save_w
        local fold_w  = 130
        local fold_lw = 48
        local name_lw = 44
        local fold_x  = save_x - GAP - fold_w
        local name_w  = math.max(80, fold_x - GAP - fold_lw - GAP - (x + name_lw + GAP))

        bounds(W.name_lbl,     x, form_y, name_lw, ROW_H); x = x + name_lw + GAP
        bounds(W.name_input,   x, form_y, name_w, ROW_H);  x = x + name_w + GAP
        bounds(W.folder_lbl,   x, form_y, fold_lw, ROW_H)
        bounds(W.folder_input, fold_x, form_y, fold_w, ROW_H)
        bounds(W.save_btn,     save_x, form_y, save_w, ROW_H)
    end

    -- -------------------------------------------------------------------
    -- panel handle (interface to prefab_manager, Task 12).
    -- -------------------------------------------------------------------
    local panel = {}

    function panel:show()
        pcall(function()
            for _, wdg in ipairs(W.widgets) do
                if wdg.set_visible then pcall(function() wdg:set_visible(true) end)
                elseif wdg.setVisible then pcall(function() wdg:setVisible(true) end) end
            end
        end)
        refresh()  -- the list is re-read from trigrules on every show (spec)
    end

    function panel:hide()
        pcall(function()
            for _, wdg in ipairs(W.widgets) do
                if wdg.set_visible then pcall(function() wdg:set_visible(false) end)
                elseif wdg.setVisible then pcall(function() wdg:setVisible(false) end) end
            end
        end)
    end

    function panel:relayout(w, h)
        pcall(function() relayout(w, h) end)
    end

    function panel:refresh()
        refresh()
    end

    -- Internals for tests / the manager (prefab_manager's M._foo convention).
    panel._W = W

    -- Initial layout at the default size (the manager re-lays-out at the
    -- real content size right after build) + first data load.
    relayout()
    refresh()

    return panel
end

return M
