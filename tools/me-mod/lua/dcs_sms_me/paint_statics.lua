-- paint_statics.lua — the "Paint Statics" tool window.
--
-- Paint static objects onto the ME map like foliage in Unreal/Unity:
-- arm the brush, hold left mouse and drag — statics scatter under a
-- circular brush per radius / density / min-spacing, with weighted type
-- selection, a country, and an indexed name. One stroke = one undo.
--
-- Architecture:
--   * paint_scatter.lua   — pure scatter core (unit-tested, no ME APIs)
--   * static_catalog.lua  — static type metadata from me_db_api
--   * this file           — sms_window UI + the me_map_window brush state
--                           machine + the commit path (verb_helpers.inject_group)
--
-- The map mouse hook mirrors prefab_manager.lua's place-pending state
-- machine, inverted for continuous painting: onMouseDown begins a stroke,
-- onMouseDrag (which DOES fire continuously during a held left-drag —
-- verified empirically in M0) extends it, onMouseUp commits one undo
-- record for the whole stroke. Right/middle events forward to the captured
-- pan state so pan/zoom keep working while armed.
--
-- Debug surface (gui-bridge driven, used by the agent verification loop):
--   M._debug_stroke(points, opts) — run a synthetic stroke through the
--     real generate → commit → name → undo pipeline, no mouse needed.
--
-- See: docs/superpowers/specs/2026-06-12-paint-statics-design.md

local M = {}

-- ---------------------------------------------------------------------------
-- dxgui modules (pcall-guarded so the module loads in test VMs)
-- ---------------------------------------------------------------------------
local Static;       do local ok, m = pcall(require, 'Static');       if ok then Static       = m end end
local Button;       do local ok, m = pcall(require, 'Button');       if ok then Button       = m end end
local EditBox;      do local ok, m = pcall(require, 'EditBox');      if ok then EditBox      = m end end
local SpinBox;      do local ok, m = pcall(require, 'SpinBox');      if ok then SpinBox      = m end end
local ComboList;    do local ok, m = pcall(require, 'ComboList');    if ok then ComboList    = m end end
local ListBoxItem;  do local ok, m = pcall(require, 'ListBoxItem');  if ok then ListBoxItem  = m end end
local ToggleButton; do local ok, m = pcall(require, 'ToggleButton'); if ok then ToggleButton = m end end
local CheckBoxModule; do local ok, m = pcall(require, 'CheckBox'); if ok then CheckBoxModule = m end end
local Skin;         do local ok, m = pcall(require, 'Skin');         if ok then Skin         = m end end

local Grid;           do local ok, m = pcall(require, 'Grid');           if ok then Grid           = m end end
local GridHeaderCell; do local ok, m = pcall(require, 'GridHeaderCell'); if ok then GridHeaderCell = m end end

local sms_window     = require('dcs_sms_me.sms_window')
local sms_skins;     do local ok, m = pcall(require, 'dcs_sms_me.sms_skins'); if ok then sms_skins = m end end
local skin_helper;   do local ok, m = pcall(require, 'dcs_sms_me.skin_helper'); if ok then skin_helper = m end end
local clearable_edit; do local ok, m = pcall(require, 'dcs_sms_me.clearable_edit'); if ok then clearable_edit = m end end
local selection;     do local ok, m = pcall(require, 'dcs_sms_me.selection'); if ok then selection = m end end
local preview_panel; do local ok, m = pcall(require, 'dcs_sms_me.static_preview_panel'); if ok then preview_panel = m end end
local version        = require('dcs_sms_me.version')
local undo           = require('dcs_sms_me.undo')
local scatter        = require('dcs_sms_me.paint_scatter')
local static_catalog = require('dcs_sms_me.static_catalog')
local H              = require('dcs_sms_me.verb_helpers')
local prefab_ops     = require('dcs_sms_me.prefab_ops')

local function log_write(level, msg)
    pcall(function() log.write('sms.me.paint', level, msg) end)
end

local function try_skin(widget, skin_name)
    pcall(function()
        if skin_helper and skin_helper.apply then
            skin_helper.apply(widget, skin_name)
            return
        end
        if widget and widget.setSkin and Skin and Skin[skin_name] then
            widget:setSkin(Skin[skin_name]())
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------
local W = {
    sms_window = nil,
    window     = nil,

    -- widgets — catalog browser region
    catalog_label = nil, category_combo = nil, search_edit = nil,
    catalog_grid = nil, add_btn = nil,
    preview = nil,           -- static_preview_panel handle (nil = unavailable)
    preview_fallback = nil,  -- metadata Static shown when no 3D preview
    -- widgets — palette region
    sep1 = nil, palette_label = nil, palette_grid = nil,
    weight_label = nil, weight_spin = nil, weight_set_btn = nil,
    remove_btn = nil, eyedrop_btn = nil,
    -- widgets — paint settings region
    sep2 = nil,
    country_label = nil, country_combo = nil, country_filter_btn = nil,
    name_label = nil, name_input = nil,
    radius_label = nil, radius_spin = nil,
    density_label = nil, density_spin = nil,
    spacing_label = nil, spacing_spin = nil,
    paint_btn = nil,

    -- catalog state
    catalog_rows    = {},   -- full row list for the selected country
    catalog_visible = {},   -- after category + search filter
    catalog_sel     = nil,  -- 1-based index into catalog_visible
    catalog_country = nil,  -- country the catalog was built for
    cat_filter      = nil,  -- category label, nil = all
    search_text     = '',

    -- the palette ("bucket"): rows { kind='static', type, display,
    -- shape_name, category, rate, weight }
    palette     = {},
    palette_sel = nil,

    -- settings mirror (authoritative when widgets are absent, e.g. headless)
    cfg = {
        radius      = 25,    -- meters
        density     = 1.0,   -- objects per 100 m²
        min_spacing = 4,     -- meters
        name        = '',
        mode        = 'paint',
        heading_random = true,
        heading_deg = 0,
        seed_on     = false,
        seed        = 12345,
    },
    erase_toggle = nil,
    heading_toggle = nil, heading_label = nil, heading_spin = nil,
    seed_check = nil, seed_spin = nil,

    -- paint state
    armed     = false,
    painting  = false,
    pan_state = nil,
    brush_id  = nil,
    brush_data = nil,
    session   = nil,    -- scatter session for the in-flight stroke
    stroke_groups = nil,
    stroke_failed = 0,

    -- registry of tool-placed statics: { group = group_obj, x = , y = }.
    -- Drives erase hit-testing and cross-stroke min-spacing.
    registry = {},

    -- naming
    name_seq     = 0,
    last_pattern = nil,
}

-- ---------------------------------------------------------------------------
-- Status helpers
-- ---------------------------------------------------------------------------
local function set_status(text, severity)
    pcall(function()
        if W.sms_window then W.sms_window:flash_status(text, severity) end
    end)
end

local function set_status_sticky(text, severity)
    pcall(function()
        if W.sms_window then W.sms_window:set_status(text, severity) end
    end)
end

-- ---------------------------------------------------------------------------
-- Settings readers (widget if present, cfg mirror otherwise)
-- ---------------------------------------------------------------------------
local function spin_value(widget, fallback)
    local v
    pcall(function()
        if widget and widget.getValue then v = tonumber(widget:getValue()) end
    end)
    return v or fallback
end

local function edit_text(widget, fallback)
    local t
    pcall(function()
        if widget and widget.getText then t = widget:getText() end
    end)
    if type(t) ~= 'string' then return fallback end
    return t
end

-- Current tool mode: 'paint' or 'erase'. The Erase toggle is authoritative
-- when built; cfg.mode is the headless mirror.
local function get_mode()
    local on
    pcall(function()
        if W.erase_toggle and W.erase_toggle.getState then on = W.erase_toggle:getState() == true end
    end)
    if on == nil then return W.cfg.mode or 'paint' end
    return on and 'erase' or 'paint'
end

local function get_radius()      return math.max(1, spin_value(W.radius_spin, W.cfg.radius)) end
local function get_density()     return math.max(0.01, spin_value(W.density_spin, W.cfg.density)) end
local function get_min_spacing() return math.max(0, spin_value(W.spacing_spin, W.cfg.min_spacing)) end
local function get_name_pattern()
    return edit_text(W.name_input, W.cfg.name)
end

-- Heading policy: 'random' or a fixed degrees number.
local function get_heading_policy()
    local random = W.cfg.heading_random
    pcall(function()
        if W.heading_toggle and W.heading_toggle.getState then
            -- Toggle ON = random heading (its default state).
            random = W.heading_toggle:getState() == true
        end
    end)
    if random then return 'random' end
    return spin_value(W.heading_spin, W.cfg.heading_deg) % 360
end

-- Optional reproducible-scatter seed; nil = unseeded (fresh each stroke).
local function get_seed()
    local on = W.cfg.seed_on
    pcall(function()
        if W.seed_check and W.seed_check.getState then on = W.seed_check:getState() == true end
    end)
    if not on then return nil end
    return spin_value(W.seed_spin, W.cfg.seed)
end

-- Country selection (prefab_manager pattern, without the keep-original
-- sentinel — painting always needs a concrete country).
local function get_country_name()
    local name
    pcall(function()
        if not (W.country_combo and W.country_combo.getSelectedItem) then return end
        local item = W.country_combo:getSelectedItem()
        if item and item.getText then
            local txt = item:getText()
            if type(txt) == 'string' and txt ~= '' then name = txt end
        end
    end)
    return name
end

local function country_coalition(Mission, name)
    if not (Mission and type(Mission.countryCoalition) == 'table') then return nil end
    local entry = Mission.countryCoalition[name]
    if type(entry) ~= 'table' then return nil end
    local cn = entry.name
    if cn == 'red' or cn == 'blue' then return cn end
    if cn == 'neutrals' or cn == 'neutral' then return 'neutral' end
    return nil
end

local COALITION_SKIN = {
    red     = 'listBoxItemCoalRedSkin',
    blue    = 'listBoxItemCoalBlueSkin',
    neutral = 'listBoxItemCoalNeutralSkin',
}

local function is_filter_all()
    local on = false
    pcall(function()
        if W.country_filter_btn and W.country_filter_btn.getState then
            on = W.country_filter_btn:getState() == true
        end
    end)
    return on
end

local function populate_country_combo()
    pcall(function()
        if not (W.country_combo and ListBoxItem) then return end
        local ok_req, Mission = pcall(require, 'me_mission')
        if not ok_req or type(Mission.missionCountry) ~= 'table' then
            log_write(log.WARNING, 'Mission.missionCountry unavailable — country dropdown empty')
            return
        end
        local show_all = is_filter_all()
        local prev = get_country_name()
        if W.country_combo.removeAllItems then W.country_combo:removeAllItems() end

        local names = {}
        for name in pairs(Mission.missionCountry) do
            if type(name) == 'string' then names[#names + 1] = name end
        end
        table.sort(names)

        local first_item, prev_item
        for _, name in ipairs(names) do
            local coalition = country_coalition(Mission, name)
            local include = show_all or coalition == 'red' or coalition == 'blue'
            if include then
                local item = ListBoxItem.new(name)
                local skin_name = COALITION_SKIN[coalition or 'neutral']
                if skin_name then try_skin(item, skin_name) end
                W.country_combo:insertItem(item)
                first_item = first_item or item
                if name == prev then prev_item = item end
            end
        end
        local pick = prev_item or first_item
        if pick and W.country_combo.selectItem then
            pcall(function() W.country_combo:selectItem(pick) end)
        end
    end)
end

-- First mission country (sorted) — headless fallback when no combo exists.
local function pick_default_country()
    local name
    pcall(function()
        local Mission = require('me_mission')
        if type(Mission.missionCountry) ~= 'table' then return end
        local names = {}
        for n in pairs(Mission.missionCountry) do
            if type(n) == 'string' then names[#names + 1] = n end
        end
        table.sort(names)
        name = names[1]
    end)
    return name
end

-- ---------------------------------------------------------------------------
-- Naming: expand the Name pattern for the next static.
--   ''            → the static type (ME dedupes collisions)
--   'Barrel'      → 'Barrel' (ME dedupes collisions)
--   'Barrel-{n}'  → 'Barrel-01', 'Barrel-02', … (sequence persists across
--                   strokes; resets when the pattern text changes)
-- ---------------------------------------------------------------------------
local function expand_name(pattern, type_name)
    if type(pattern) ~= 'string' or pattern:gsub('%s', '') == '' then
        return type_name
    end
    if pattern ~= W.last_pattern then
        W.last_pattern = pattern
        W.name_seq = 0
    end
    if pattern:find('{n}', 1, true) then
        W.name_seq = W.name_seq + 1
        return (pattern:gsub('%{n%}', string.format('%02d', W.name_seq)))
    end
    return pattern
end

-- ---------------------------------------------------------------------------
-- Commit path: one scatter placement → one injected static group.
-- Mirrors verbs/group_verbs.lua group_create_static, inlined so we control
-- rate (from the DB, not hardcoded) and skip per-call country lookups.
-- ---------------------------------------------------------------------------

-- Build + inject one static group with an exact name. Shared by the paint
-- commit (name from expand_name) and the erase-undo restore (original name).
local function inject_static(group_name, p, country)
    local heading = math.rad(p.heading_deg or 0)
    local g = {
        name = group_name,
        x = p.x, y = p.y,
        hidden = false,
        dead = false,
        heading = heading,
        units = {
            {
                name = group_name,
                type = p.type,
                x = p.x, y = p.y,
                heading = heading,
                category = p.category,
                shape_name = p.shape_name,
                rate = p.rate or (p.row and p.row.rate) or 100,
                canCargo = false,
                mass = 0,
                dead = false,
            },
        },
        route = {
            points = {
                {
                    x = p.x, y = p.y,
                    action = 'Off Road',
                    type = 'Turning Point',
                    ETA = 0, ETA_locked = true,
                    formation_template = '',
                    speed = 0, speed_locked = true,
                    task = H.new_combo_task(),
                },
            },
            routeRelativeTOT = false,
        },
    }
    local injected, err = H.inject_group(g, country, 'static')
    if not injected then
        return nil, err or 'inject_group failed'
    end
    return injected
end

local function commit_placement(p, country, name_pattern)
    return inject_static(expand_name(name_pattern, p.type), p, country)
end

-- ---------------------------------------------------------------------------
-- Undo handler: one stroke = one record.
--   { kind = 'paint', groups = {group_obj, …} }  → remove them
-- (M4 adds kind = 'erase' with re-inject payloads.)
-- ---------------------------------------------------------------------------
local function purge_registry(group_set)
    local kept = {}
    for _, entry in ipairs(W.registry) do
        if not group_set[entry.group] then kept[#kept + 1] = entry end
    end
    W.registry = kept
end

-- Fast batch removal for tool-placed statics. ED's Mission.remove_group
-- costs ~100 ms per group — it rescans every other group's tasks and
-- refreshes the Unit List on each call (measured: 147 statics in 16.3 s).
-- A painted static is exactly the inverse of our inject_group — single
-- unit, no tasks, no waypoint/zone links, nothing targeting it — so we
-- reverse those registrations directly and refresh the Unit List once
-- per batch. Measured: 144 groups in 3 ms. Only ever use this on groups
-- this tool created.
--
-- Returns (removed_set, errors): set keyed by group table for the ones
-- actually removed.
local function batch_remove_groups(groups)
    local removed, errors = {}, 0
    local ok_m, Mission = pcall(require, 'me_mission')
    if not ok_m then return removed, #(groups or {}) end
    local MapWindow; pcall(function() MapWindow = require('me_map_window') end)
    for _, g in ipairs(groups or {}) do
        local ok = pcall(function()
            -- Selection hygiene (mirrors Mission.remove_group): if the
            -- group is part of the live selection / mounted panel, detach
            -- it before pulling the tables out from under the ME.
            pcall(function()
                if MapWindow and MapWindow.removeSelectedGroups then MapWindow.removeSelectedGroups(g) end
                if MapWindow and MapWindow.selectedGroup == g then
                    MapWindow.selectedGroup = nil
                    if MapWindow.setSelectedUnit then MapWindow.setSelectedUnit(nil) end
                end
            end)
            pcall(Mission.remove_group_map_objects, g)
            -- Warehouse-category statics own a warehouse record.
            pcall(function()
                if type(Mission.delWarehouse) == 'function' then
                    for _, u in ipairs(g.units or {}) do Mission.delWarehouse(u.unitId) end
                end
            end)
            local arr = g.boss and g.boss.static and g.boss.static.group
            local found = false
            if arr then
                for i = #arr, 1, -1 do
                    if arr[i] == g then table.remove(arr, i); found = true; break end
                end
            end
            -- Not in the array ⇒ already deleted outside the tool (user
            -- Del-key, File>New, …). Finish the lookup-table cleanup and
            -- count it as removed — the goal state ("group gone") holds.
            if not found then
                log_write(log.INFO, 'batch remove: "' .. tostring(g.name) .. '" was already gone')
            end
            -- Identity-guarded: only clear a lookup entry that still points
            -- at OUR table, so a name/id reused after an external delete is
            -- never clobbered.
            for _, u in ipairs(g.units or {}) do
                if type(Mission.unit_by_name) == 'table' and Mission.unit_by_name[u.name] == u then
                    Mission.unit_by_name[u.name] = nil
                end
                if type(Mission.unit_by_id) == 'table' and Mission.unit_by_id[u.unitId] == u then
                    Mission.unit_by_id[u.unitId] = nil
                end
            end
            if type(Mission.group_by_name) == 'table' and Mission.group_by_name[g.name] == g then
                Mission.group_by_name[g.name] = nil
            end
            if type(Mission.group_by_id) == 'table' and Mission.group_by_id[g.groupId] == g then
                Mission.group_by_id[g.groupId] = nil
            end
        end)
        if ok then removed[g] = true else errors = errors + 1 end
    end
    pcall(function() _G.panel_units_list.update() end)
    return removed, errors
end

undo.register_handler('paint_statics', function(payload)
    if type(payload) ~= 'table' then return nil, 'bad paint undo payload' end
    if payload.kind == 'paint' then
        local removed, errors = batch_remove_groups(payload.groups)
        purge_registry(removed)
        return true, errors > 0 and (errors .. ' partial failures') or nil
    end
    if payload.kind == 'erase' then
        -- Restore every static the erase stroke deleted, with its original
        -- name (inject's check_group_name dedupes on collision).
        local errors = 0
        for _, s in ipairs(payload.snapshots or {}) do
            local country = H.find_country_by_name(s.country or '')
            local g
            if country then g = inject_static(s.name, s, country) end
            if g then
                W.registry[#W.registry + 1] = {
                    group = g, x = s.x, y = s.y,
                    type = s.type, shape_name = s.shape_name, category = s.category,
                    rate = s.rate, heading_deg = s.heading_deg,
                    name = g.name, country = s.country,
                }
            else
                errors = errors + 1
            end
        end
        return true, errors > 0 and (errors .. ' restore failures') or nil
    end
    return nil, 'unknown paint undo kind: ' .. tostring(payload.kind)
end)

-- ---------------------------------------------------------------------------
-- Brush overlay (cursor-following circle)
-- ---------------------------------------------------------------------------
local function circle_points(radius, n)
    n = n or 36
    local pts = {}
    for i = 0, n do
        local a = (i / n) * 2 * math.pi
        pts[#pts + 1] = { x = radius * math.cos(a), y = radius * math.sin(a) }
    end
    return pts
end

local function remove_brush_overlay()
    pcall(function()
        if W.brush_id then
            local MapWindow = require('me_map_window')
            if MapWindow and MapWindow.removeDrawObject then
                MapWindow.removeDrawObject(W.brush_id)
            end
        end
    end)
    W.brush_id, W.brush_data = nil, nil
end

-- Brush tint: green = paint, red = erase.
local function brush_colors()
    if get_mode() == 'erase' then
        return { 1, 0.35, 0.2, 1 }, { 1, 0.35, 0.2, 0.10 }
    end
    return { 0.2, 1, 0.4, 1 }, { 0.2, 1, 0.4, 0.08 }
end

local function create_brush_overlay()
    pcall(function()
        local MapWindow = require('me_map_window')
        if not (MapWindow and MapWindow.createDrawObject) then return end
        local line, fill = brush_colors()
        local data = {
            objectType = 'Polygon',
            points     = circle_points(get_radius()),
            thickness  = 2,
            color      = line,
            fillColor  = fill,
            file       = './MissionEditor/data/NewMap/images/draw/polyline_solid.png',
            x          = 0,
            y          = 0,
            angle      = 0,
        }
        W.brush_data = data
        W.brush_id = MapWindow.createDrawObject(data)
        if W.brush_id and MapWindow.addDrawObject then
            pcall(function() MapWindow.addDrawObject(W.brush_id) end)
        end
    end)
end

local function move_brush_overlay(wx, wy)
    pcall(function()
        if not (W.brush_id and W.brush_data) then return end
        W.brush_data.x, W.brush_data.y = wx, wy
        local MapWindow = require('me_map_window')
        if MapWindow and MapWindow.updateDrawObject then
            MapWindow.updateDrawObject(W.brush_id, W.brush_data)
        end
    end)
end

local function resize_brush_overlay()
    pcall(function()
        if not (W.brush_id and W.brush_data) then return end
        W.brush_data.points = circle_points(get_radius())
        local line, fill = brush_colors()
        W.brush_data.color, W.brush_data.fillColor = line, fill
        local MapWindow = require('me_map_window')
        if MapWindow and MapWindow.updateDrawObject then
            MapWindow.updateDrawObject(W.brush_id, W.brush_data)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Stroke machinery (shared by the live map state and _debug_stroke)
-- ---------------------------------------------------------------------------

-- The live palette. Painting needs at least one row with positive weight.
local function current_palette()
    if #W.palette == 0 then
        return nil, 'palette is empty — add static types from the catalog or "Add selected"'
    end
    local total = 0
    for _, row in ipairs(W.palette) do total = total + (tonumber(row.weight) or 0) end
    if total <= 0 then
        return nil, 'all palette weights are 0 — raise at least one weight'
    end
    return W.palette
end

-- ---------------------------------------------------------------------------
-- Catalog browser + palette list
-- ---------------------------------------------------------------------------
local function make_cell(text, tooltip)
    local s = Static.new(tostring(text or ''))
    try_skin(s, 'staticSkin_ME')
    if tooltip and s.setTooltipText then
        pcall(function() s:setTooltipText(tostring(tooltip)) end)
    end
    return s
end

local function render_catalog()
    pcall(function()
        if not (W.catalog_grid and W.catalog_grid.removeAllRows) then return end
        W.catalog_grid:removeAllRows()
        for i, r in ipairs(W.catalog_visible) do
            W.catalog_grid:insertRow(20)
            local row = i - 1
            W.catalog_grid:setCell(0, row, make_cell(r.display, r.type))
            W.catalog_grid:setCell(1, row, make_cell(r.category))
        end
        if W.catalog_sel and W.catalog_grid.selectRow then
            pcall(function() W.catalog_grid:selectRow(W.catalog_sel - 1) end)
        end
    end)
end

local function render_palette()
    pcall(function()
        if not (W.palette_grid and W.palette_grid.removeAllRows) then return end
        W.palette_grid:removeAllRows()
        for i, r in ipairs(W.palette) do
            W.palette_grid:insertRow(20)
            local row = i - 1
            W.palette_grid:setCell(0, row, make_cell(r.display, r.type))
            W.palette_grid:setCell(1, row, make_cell(r.weight))
        end
        if W.palette_sel and W.palette_grid.selectRow then
            pcall(function() W.palette_grid:selectRow(W.palette_sel - 1) end)
        end
    end)
end

-- Show the highlighted catalog type in the 3D preview viewport; degrade
-- to a text-metadata fallback when the viewport (or this model) fails.
local function update_preview()
    local r = W.catalog_sel and W.catalog_visible[W.catalog_sel]
    if not r then
        if W.preview then W.preview:set_visible(false) end
        pcall(function()
            if W.preview_fallback and W.preview_fallback.setText then W.preview_fallback:setText('') end
        end)
        return
    end
    local shown = false
    if W.preview then
        shown = W.preview:set_type(r.type) == true
        W.preview:set_visible(shown)
    end
    pcall(function()
        if not (W.preview_fallback and W.preview_fallback.setText) then return end
        if shown then
            W.preview_fallback:setText('')
        else
            W.preview_fallback:setText(('%s   [%s]   type: %s   shape: %s   rate: %s')
                :format(r.display, r.category, r.type,
                        (r.shape_name ~= '' and r.shape_name) or '?', tostring(r.rate)))
        end
    end)
end

-- Re-apply category + search filters to the catalog rows and re-render.
local function refresh_catalog_view()
    W.catalog_visible = static_catalog.filter(W.catalog_rows, {
        category = W.cat_filter,
        search   = W.search_text,
    })
    W.catalog_sel = (#W.catalog_visible > 0) and 1 or nil
    render_catalog()
    update_preview()
end

local ALL_CATEGORIES = '<all categories>'

local function populate_category_combo()
    pcall(function()
        if not (W.category_combo and W.category_combo.removeAllItems and ListBoxItem) then return end
        local prev = W.cat_filter
        W.category_combo:removeAllItems()
        local all_item = ListBoxItem.new(ALL_CATEGORIES)
        W.category_combo:insertItem(all_item)
        local pick = all_item
        for _, label in ipairs(static_catalog.categories(W.catalog_rows)) do
            local item = ListBoxItem.new(label)
            W.category_combo:insertItem(item)
            if label == prev then pick = item end
        end
        if pick == all_item then W.cat_filter = nil end
        if W.category_combo.selectItem then
            pcall(function() W.category_combo:selectItem(pick) end)
        end
    end)
end

-- Rebuild the catalog rows for the currently selected country. No-op when
-- the country didn't change (unless force).
local function populate_catalog(force)
    local country = get_country_name() or pick_default_country()
    if not country then return end
    if country == W.catalog_country and not force then return end
    W.catalog_country = country
    local rows, err = static_catalog.list(country)
    W.catalog_rows = rows
    if err then
        log_write(log.WARNING, 'catalog: ' .. tostring(err))
        set_status('Catalog: ' .. tostring(err), 'warning')
    end
    populate_category_combo()
    refresh_catalog_view()
end

local function add_palette_row(row)
    if not row then return end
    for _, existing in ipairs(W.palette) do
        if existing.type == row.type then
            set_status('"' .. row.display .. '" is already in the palette.', 'warning')
            return
        end
    end
    W.palette[#W.palette + 1] = {
        kind       = 'static',
        type       = row.type,
        display    = row.display,
        shape_name = row.shape_name,
        category   = row.category,
        rate       = row.rate,
        weight     = 1,
    }
    W.palette_sel = #W.palette
    render_palette()
    set_status('Added "' .. row.display .. '" to the palette.')
end

local function on_add_from_catalog()
    local r = W.catalog_sel and W.catalog_visible[W.catalog_sel]
    if not r then
        set_status('Select a type in the catalog first.', 'warning')
        return
    end
    add_palette_row(r)
end

-- Eyedropper: pull static types out of the current map selection.
local function on_add_from_selection()
    if not (selection and selection.snapshot) then
        set_status('Selection module unavailable.', 'error')
        return
    end
    local snap
    local ok = pcall(function() snap = selection.snapshot() end)
    if not ok or type(snap) ~= 'table' or #(snap.groups or {}) == 0 then
        set_status('Nothing selected on the map — select a static first.', 'warning')
        return
    end
    local added, skipped = 0, 0
    for _, g in ipairs(snap.groups) do
        for _, u in ipairs((type(g) == 'table' and g.units) or {}) do
            if type(u) == 'table' and type(u.type) == 'string' then
                local row = static_catalog.resolve_type(u.type)
                if row then
                    local before = #W.palette
                    add_palette_row(row)
                    if #W.palette > before then added = added + 1 end
                else
                    skipped = skipped + 1
                end
            end
        end
    end
    if added > 0 then
        set_status('Eyedropper: added ' .. added .. ' type(s)'
            .. (skipped > 0 and (', skipped ' .. skipped .. ' non-static') or '') .. '.',
            'success')
    elseif skipped > 0 then
        set_status('Eyedropper: selection has no static-placeable types.', 'warning')
    end
end

local function on_remove_palette_row()
    local i = W.palette_sel
    if not (i and W.palette[i]) then
        set_status('Select a palette row first.', 'warning')
        return
    end
    local removed = table.remove(W.palette, i)
    if W.palette_sel > #W.palette then
        W.palette_sel = (#W.palette > 0) and #W.palette or nil
    end
    render_palette()
    set_status('Removed "' .. tostring(removed.display) .. '" from the palette.')
end

local function on_set_weight()
    local i = W.palette_sel
    if not (i and W.palette[i]) then
        set_status('Select a palette row first.', 'warning')
        return
    end
    local w = math.max(0, spin_value(W.weight_spin, 1))
    W.palette[i].weight = w
    render_palette()
    set_status(('Weight of "%s" set to %g.'):format(W.palette[i].display, w))
end

local function registry_points()
    local pts = {}
    for _, e in ipairs(W.registry) do
        pts[#pts + 1] = { x = e.x, y = e.y }
    end
    return pts
end

-- Begin a stroke at world (wx, wy). Returns true, or nil + error.
local function begin_stroke(wx, wy, opts)
    opts = opts or {}
    local palette, perr = opts.palette, nil
    if not palette then palette, perr = current_palette() end
    if not palette then return nil, perr end

    local country_name = opts.country or get_country_name() or pick_default_country()
    if not country_name then return nil, 'no country available' end
    local country = H.find_country_by_name(country_name)
    if not country then return nil, 'country not in mission: ' .. country_name end

    local session, serr = scatter.new_session({
        radius          = opts.radius or get_radius(),
        density         = opts.density or get_density(),
        min_spacing     = opts.min_spacing or get_min_spacing(),
        palette         = palette,
        heading         = opts.heading or get_heading_policy(),
        seed            = opts.seed or get_seed(),
        existing_points = registry_points(),
    })
    if not session then return nil, serr end

    W.session       = session
    W.stroke_country = country
    W.stroke_name_pattern = opts.name or get_name_pattern()
    W.stroke_groups = {}
    W.stroke_failed = 0
    W.stroke_capped = false
    return true
end

-- Hard ceiling on statics committed per brush step. Commit costs ~0.5 ms
-- per static; an extreme radius × density combination can imply thousands
-- of placements in ONE drag event, which would freeze the editor mid-drag.
-- When the cap trips we drop the excess and warn once per stroke.
local MAX_COMMITS_PER_STEP = 250

-- Extend the stroke with a brush position. Generates + commits.
local function stroke_step(wx, wy)
    if not W.session then return 0 end
    local placements = W.session:step(wx, wy)
    if #placements > MAX_COMMITS_PER_STEP then
        for i = #placements, MAX_COMMITS_PER_STEP + 1, -1 do placements[i] = nil end
        if not W.stroke_capped then
            W.stroke_capped = true
            set_status(('Brush capped at %d statics per step — lower density or radius for full coverage.')
                :format(MAX_COMMITS_PER_STEP), 'warning')
        end
    end
    for _, p in ipairs(placements) do
        local g, err = commit_placement(p, W.stroke_country, W.stroke_name_pattern)
        if g then
            W.stroke_groups[#W.stroke_groups + 1] = g
            -- Registry entries carry everything needed to re-create the
            -- static, so an erase stroke's undo can restore it verbatim.
            W.registry[#W.registry + 1] = {
                group = g, x = p.x, y = p.y,
                type = p.type, shape_name = p.shape_name, category = p.category,
                rate = p.rate or (p.row and p.row.rate) or 100,
                heading_deg = p.heading_deg,
                name = g.name,
                country = W.stroke_country and W.stroke_country.name,
            }
        else
            W.stroke_failed = W.stroke_failed + 1
            log_write(log.WARNING, 'placement failed: ' .. tostring(err))
        end
    end
    return #placements
end

-- End the stroke: one undo record for everything it created.
local function end_stroke()
    local groups = W.stroke_groups or {}
    local failed = W.stroke_failed or 0
    if #groups > 0 then
        undo.record_generic('paint_statics', { kind = 'paint', groups = groups })
    end
    W.session, W.stroke_groups, W.stroke_failed = nil, nil, 0
    return #groups, failed
end

-- ---------------------------------------------------------------------------
-- Erase stroke: delete tool-placed statics under the brush. Only registry
-- entries are candidates — hand-placed objects are never touched.
-- ---------------------------------------------------------------------------
local function begin_erase_stroke()
    W.erase_snapshots = {}
end

local function erase_step(wx, wy)
    if not W.erase_snapshots then return 0 end
    local r = get_radius()
    local r2 = r * r
    local hits = {}
    for _, e in ipairs(W.registry) do
        local dx, dy = e.x - wx, e.y - wy
        if dx * dx + dy * dy <= r2 then hits[#hits + 1] = e end
    end
    if #hits == 0 then return 0 end
    local groups = {}
    for _, e in ipairs(hits) do groups[#groups + 1] = e.group end
    local removed = batch_remove_groups(groups)
    for _, e in ipairs(hits) do
        if removed[e.group] then
            W.erase_snapshots[#W.erase_snapshots + 1] = {
                x = e.x, y = e.y, type = e.type, shape_name = e.shape_name,
                category = e.category, rate = e.rate,
                heading_deg = e.heading_deg, name = e.name, country = e.country,
            }
        end
    end
    purge_registry(removed)
    return #hits
end

local function end_erase_stroke()
    local snaps = W.erase_snapshots or {}
    if #snaps > 0 then
        undo.record_generic('paint_statics', { kind = 'erase', snapshots = snaps })
    end
    W.erase_snapshots = nil
    return #snaps
end

-- ---------------------------------------------------------------------------
-- Arm / disarm the map brush state
-- ---------------------------------------------------------------------------
local disarm_paint  -- forward declaration

-- Title bar + sticky status + brush tint for the current mode. Called on
-- arm and whenever the Erase toggle flips while armed.
local function refresh_paint_affordance()
    if not W.armed then return end
    local erasing = get_mode() == 'erase'
    local verb = erasing and 'ERASING' or 'PAINTING'
    pcall(function()
        if W.window and W.window.setText then
            W.window:setText(verb .. ' — HOLD LEFT MOUSE + DRAG ON MAP (Esc stops)')
        end
    end)
    set_status_sticky(erasing
        and 'ERASING — drag over painted statics to delete them (Esc stops)'
        or  'PAINTING — hold left mouse and drag on the map (Esc stops)',
        erasing and 'warning' or 'success')
    resize_brush_overlay()
end

local function arm_paint()
    if W.armed then return end

    -- Validate inputs before grabbing the map (paint mode only — erasing
    -- needs neither palette nor country).
    if get_mode() == 'paint' then
        local palette, perr = current_palette()
        if not palette then
            set_status('Cannot paint: ' .. tostring(perr), 'error')
            return
        end
        local country_name = get_country_name() or pick_default_country()
        if not country_name then
            set_status('Cannot paint: no country available in mission', 'error')
            return
        end
    end

    local ok, err = pcall(function()
        local MapWindow = require('me_map_window')
        if not (MapWindow and MapWindow.setState and MapWindow.getPanState and MapWindow.getMapPoint) then
            error('me_map_window missing required symbols')
        end
        W.pan_state = MapWindow.getPanState()
        local function forward(method, ...)
            local ps = W.pan_state
            if not ps then return end
            local fn = ps[method]
            if type(fn) == 'function' then pcall(fn, ps, ...) end
        end

        local brush_state = {}

        function brush_state:onMouseDown(x, y, button)
            if button ~= 1 then
                forward('onMouseDown', x, y, button)
                return
            end
            pcall(function()
                if not W.armed then return end
                local wx, wy = MapWindow.getMapPoint(x, y)
                if not (wx and wy) then return end
                W.stroke_kind = get_mode()
                if W.stroke_kind == 'erase' then
                    begin_erase_stroke()
                    W.painting = true
                    erase_step(wx, wy)
                else
                    local ok_b, berr = begin_stroke(wx, wy)
                    if not ok_b then
                        set_status('Paint failed: ' .. tostring(berr), 'error')
                        disarm_paint()
                        return
                    end
                    W.painting = true
                    stroke_step(wx, wy)
                end
                move_brush_overlay(wx, wy)
            end)
        end

        function brush_state:onMouseUp(x, y, button)
            if button ~= 1 then
                forward('onMouseUp', x, y, button)
                return
            end
            pcall(function()
                if not W.painting then return end
                W.painting = false
                if W.stroke_kind == 'erase' then
                    local n = end_erase_stroke()
                    if n > 0 then
                        set_status('Erased ' .. n .. ' painted statics — Ctrl+Z restores them', 'success')
                    else
                        set_status('Erase stroke hit no painted statics.', 'info')
                    end
                else
                    local n, failed = end_stroke()
                    local msg = 'Stroke: ' .. n .. ' statics placed'
                    if failed > 0 then msg = msg .. ' (' .. failed .. ' failed)' end
                    msg = msg .. ' — Ctrl+Z undoes this stroke'
                    set_status(msg, failed > 0 and 'warning' or 'success')
                end
            end)
        end

        function brush_state:onMouseDrag(dx, dy, button, x, y)
            if button ~= 1 then
                forward('onMouseDrag', dx, dy, button, x, y)
                return
            end
            pcall(function()
                if not W.painting then return end
                local wx, wy = MapWindow.getMapPoint(x, y)
                if not (wx and wy) then return end
                if W.stroke_kind == 'erase' then
                    erase_step(wx, wy)
                else
                    stroke_step(wx, wy)
                end
                move_brush_overlay(wx, wy)
            end)
        end

        function brush_state:onMouseMove(x, y)
            forward('onMouseMove', x, y)
            pcall(function()
                local wx, wy = MapWindow.getMapPoint(x, y)
                if not (wx and wy) then return end
                move_brush_overlay(wx, wy)
            end)
        end

        function brush_state:onMouseWheel(x, y, clicks)
            forward('onMouseWheel', x, y, clicks)
        end

        create_brush_overlay()
        MapWindow.setState(brush_state)
    end)
    if not ok then
        remove_brush_overlay()
        W.pan_state = nil
        set_status('Brush unavailable: ' .. tostring(err) .. ' — see dcs.log', 'error')
        log_write(log.ERROR, 'arm_paint failed: ' .. tostring(err))
        return
    end

    W.armed = true
    pcall(function()
        if W.paint_btn and W.paint_btn.setText then W.paint_btn:setText('Stop (Esc)') end
    end)
    refresh_paint_affordance()
    log_write(log.INFO, 'paint armed (' .. get_mode() .. ')')
end

disarm_paint = function()
    if not W.armed then return end
    if W.painting then
        -- Mouse-up never arrived (e.g. Esc mid-drag): close the stroke.
        W.painting = false
        if W.stroke_kind == 'erase' then pcall(end_erase_stroke) else pcall(end_stroke) end
    end
    W.armed = false
    remove_brush_overlay()
    pcall(function()
        local MapWindow = require('me_map_window')
        if MapWindow and MapWindow.setState and MapWindow.getPanState then
            MapWindow.setState(MapWindow.getPanState())
        end
    end)
    W.pan_state = nil
    pcall(function()
        if W.window and W.window.setText then
            W.window:setText(sms_window.compose_title('Paint Statics', version))
        end
    end)
    pcall(function()
        if W.paint_btn and W.paint_btn.setText then W.paint_btn:setText('Paint on map') end
    end)
    pcall(function()
        if W.sms_window and W.sms_window.clear_sticky_status then
            W.sms_window:clear_sticky_status()
        end
    end)
    set_status('Painting stopped.')
    log_write(log.INFO, 'paint disarmed')
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
local ROW_H = 22
local ROW_PITCH = 30

local function set(widget, x, y, w, h)
    pcall(function()
        if widget and widget.setBounds then widget:setBounds(x, y, w, h) end
    end)
end

local function relayout(x, y, w, h)
    local label_w = 100
    local gap = 6
    local input_x = x + label_w + gap
    local input_w = w - label_w - gap
    local cur_y = y

    -- Catalog browser region.
    set(W.catalog_label, x, cur_y, w, ROW_H)
    cur_y = cur_y + 24

    local combo_w = math.floor(w * 0.45)
    set(W.category_combo, x, cur_y, combo_w, ROW_H)
    pcall(function()
        if W.search_edit and W.search_edit.set_bounds then
            W.search_edit:set_bounds(x + combo_w + gap, cur_y, w - combo_w - gap, ROW_H)
        end
    end)
    cur_y = cur_y + 28

    -- The catalog grid soaks up the slack when the window grows: it gets
    -- whatever height remains after the fixed-height rows below.
    local fixed_below = 32 + 8 + 24 + 126 + 30 + 8 + 30 + 30 + 30 + 30 + 30 + 30 + 30 + 36
    local catalog_h = math.max(100, h - (cur_y - y) - fixed_below)
    -- Catalog list left, 3D preview viewport right (metadata caption strip
    -- under the viewport doubles as the no-preview fallback).
    local grid_w = math.min(424, w)
    local prev_x = x + grid_w + 6
    local prev_w = math.max(0, w - grid_w - 6)
    set(W.catalog_grid, x, cur_y, grid_w, catalog_h)
    if W.preview then
        W.preview:set_bounds(prev_x, cur_y, prev_w, math.max(catalog_h - 26, 10))
    end
    set(W.preview_fallback, prev_x, cur_y + catalog_h - 22, prev_w, ROW_H)
    cur_y = cur_y + catalog_h + 6

    set(W.add_btn, x, cur_y, w, 24)
    cur_y = cur_y + 32

    set(W.sep1, x, cur_y, w, 1)
    cur_y = cur_y + 8

    -- Palette region.
    set(W.palette_label, x, cur_y, w, ROW_H)
    cur_y = cur_y + 24

    set(W.palette_grid, x, cur_y, w, 120)
    cur_y = cur_y + 126

    set(W.weight_label, x, cur_y, 55, ROW_H)
    set(W.weight_spin, x + 55, cur_y, 70, ROW_H)
    set(W.weight_set_btn, x + 131, cur_y, 50, ROW_H)
    set(W.remove_btn, x + 187, cur_y, 70, ROW_H)
    set(W.eyedrop_btn, x + 263, cur_y, w - 263, ROW_H)
    cur_y = cur_y + 30

    set(W.sep2, x, cur_y, w, 1)
    cur_y = cur_y + 8

    -- Paint settings region.
    local filter_w = 80
    set(W.country_label, x, cur_y, label_w, ROW_H)
    set(W.country_combo, input_x, cur_y,
        (W.country_filter_btn and (input_w - filter_w - gap)) or input_w, ROW_H)
    set(W.country_filter_btn, x + w - filter_w, cur_y, filter_w, ROW_H)
    cur_y = cur_y + ROW_PITCH

    set(W.name_label, x, cur_y, label_w, ROW_H)
    set(W.name_input, input_x, cur_y, input_w, ROW_H)
    cur_y = cur_y + ROW_PITCH

    set(W.radius_label, x, cur_y, label_w, ROW_H)
    set(W.radius_spin, input_x, cur_y, 90, ROW_H)
    cur_y = cur_y + ROW_PITCH

    set(W.density_label, x, cur_y, label_w, ROW_H)
    set(W.density_spin, input_x, cur_y, 90, ROW_H)
    cur_y = cur_y + ROW_PITCH

    set(W.spacing_label, x, cur_y, label_w, ROW_H)
    set(W.spacing_spin, input_x, cur_y, 90, ROW_H)
    cur_y = cur_y + ROW_PITCH

    set(W.heading_toggle, x, cur_y, 130, ROW_H)
    set(W.heading_label, x + 140, cur_y, 70, ROW_H)
    set(W.heading_spin, x + 214, cur_y, 90, ROW_H)
    cur_y = cur_y + ROW_PITCH

    set(W.seed_check, x, cur_y, 130, ROW_H)
    set(W.seed_spin, x + 140, cur_y, 110, ROW_H)
    cur_y = cur_y + ROW_PITCH + 8

    if W.erase_toggle then
        set(W.erase_toggle, x, cur_y, 120, 28)
        set(W.paint_btn, x + 126, cur_y, w - 126, 28)
    else
        set(W.paint_btn, x, cur_y, w, 28)
    end
end

-- ---------------------------------------------------------------------------
-- Window construction
-- ---------------------------------------------------------------------------
local function build_window()
    W.sms_window = sms_window.new({
        title    = 'Paint Statics',
        size     = { w = 740, h = 840 },
        min_size = { w = 640, h = 760 },
        on_resize = function(swin, x, y, w, h)
            relayout(x, y, w, h)
        end,
        on_close = function()
            disarm_paint()
        end,
    })
    if not W.sms_window then
        log_write(log.ERROR, 'sms_window.new failed')
        return false
    end
    W.window = W.sms_window:raw()

    -- Esc stops painting (same pattern as prefab place-pending).
    pcall(function()
        if W.window.addHotKeyCallback then
            W.window:addHotKeyCallback('escape', function()
                if W.armed then disarm_paint() end
            end)
        end
    end)

    local function insert(widget)
        pcall(function() W.window:insertWidget(widget) end)
    end

    local function mk_label(text)
        local s = Static.new()
        pcall(function() s:setText(text) end)
        try_skin(s, 'staticSkin_ME')
        insert(s)
        return s
    end

    local function mk_edit(initial, tooltip)
        local e
        if EditBox then e = EditBox.new() else e = Static.new() end
        pcall(function() e:setText(initial or '') end)
        try_skin(e, 'editBoxSkin_ME')
        if tooltip then pcall(function() e:setTooltipText(tooltip) end) end
        insert(e)
        return e
    end

    local function mk_spin(value, min, max, step, decimal, tooltip, on_change)
        local s
        if SpinBox then
            s = SpinBox.new()
            try_skin(s, 'spinBoxSkin_MENew')
            pcall(function() s:setRange(min, max) end)
            pcall(function() s:setStep(step) end)
            pcall(function() s:setCheckRange(true) end)
            pcall(function() s:setAcceptDecimalPoint(decimal == true) end)
            pcall(function() s:setValue(value) end)
            if tooltip then pcall(function() s:setTooltipText(tooltip) end) end
            if on_change and s.addChangeCallback then
                pcall(function() s:addChangeCallback(on_change) end)
            end
        else
            s = Static.new()
            pcall(function() s:setText(tostring(value)) end)
            try_skin(s, 'staticSkin_ME')
        end
        insert(s)
        return s
    end

    -- A selectable 2-column grid (mirrors prefab_manager's pattern: Grid's
    -- default onMouseDown doesn't select; override it, and double-click
    -- triggers on_activate).
    local function mk_grid(col_defs, on_select, on_activate)
        local g
        if Grid and GridHeaderCell then
            g = Grid.new()
            try_skin(g, 'sms_grid')
            for _, c in ipairs(col_defs) do
                local hc = GridHeaderCell.new()
                try_skin(hc, 'sms_grid_header')
                pcall(function() hc:setText(c.label) end)
                g:insertColumn(c.width, hc)
            end
            g.onMouseDown = function(self, x, y, button)
                if button ~= 1 then return end
                pcall(function()
                    local _, row = self:getMouseCursorColumnRow(x, y)
                    if row and row >= 0 then
                        self:selectRow(row)
                        on_select(row + 1)
                    end
                end)
            end
            g.onMouseDoubleClick = function(self, x, y, button)
                if button ~= 1 then return end
                pcall(function()
                    local _, row = self:getMouseCursorColumnRow(x, y)
                    if row and row >= 0 then
                        self:selectRow(row)
                        on_select(row + 1)
                        if on_activate then on_activate(row + 1) end
                    end
                end)
            end
            if g.addSelectRowCallback then
                pcall(function()
                    g:addSelectRowCallback(function(_grid, _curr, _prev)
                        pcall(function()
                            local idx = g:getSelectedRow()
                            if type(idx) == 'number' and idx >= 0 then on_select(idx + 1) end
                        end)
                    end)
                end)
            end
        else
            g = Static.new()
            pcall(function() g:setText('(Grid unavailable)') end)
            try_skin(g, 'staticSkin_ME')
        end
        insert(g)
        return g
    end

    -- --- Catalog browser region ---
    W.catalog_label = mk_label('Catalog — browse static types:')

    if ComboList then
        W.category_combo = ComboList.new()
        try_skin(W.category_combo, 'comboListSkinNew_')
        pcall(function()
            if W.category_combo.addChangeCallback then
                W.category_combo:addChangeCallback(function()
                    pcall(function()
                        local item = W.category_combo:getSelectedItem()
                        local txt = item and item.getText and item:getText()
                        W.cat_filter = (txt ~= ALL_CATEGORIES) and txt or nil
                        refresh_catalog_view()
                    end)
                end)
            end
        end)
        insert(W.category_combo)
    else
        W.category_combo = Static.new()
        try_skin(W.category_combo, 'staticSkin_ME')
        insert(W.category_combo)
    end

    if clearable_edit then
        W.search_edit = clearable_edit.new(W.window, {
            on_change = function(text)
                W.search_text = text or ''
                refresh_catalog_view()
            end,
        })
    end
    if not W.search_edit then
        local fb = mk_edit('', 'Search the catalog')
        W.search_edit = {
            set_bounds = function(_, x, y, w, h) set(fb, x, y, w, h) end,
            widget = fb,
        }
    end

    W.catalog_grid = mk_grid(
        { { label = 'Type', width = 270 }, { label = 'Category', width = 150 } },
        function(i)
            W.catalog_sel = i
            update_preview()
        end,
        function(_) on_add_from_catalog() end)

    -- 3D model preview viewport to the right of the catalog list (D10),
    -- with a one-line metadata Static as the no-preview fallback.
    if preview_panel then
        W.preview = preview_panel.create(W.window)
    end
    W.preview_fallback = Static.new()
    try_skin(W.preview_fallback, 'staticSkin_ME')
    insert(W.preview_fallback)

    if Button then
        W.add_btn = Button.new()
        pcall(function() W.add_btn:setText('Add to palette') end)
        try_skin(W.add_btn, 'sms_button')
        pcall(function() W.add_btn.onChange = on_add_from_catalog end)
        insert(W.add_btn)
    end

    -- --- Palette region ---
    W.sep1 = Static.new()
    try_skin(W.sep1, 'sms_separator')
    insert(W.sep1)

    W.palette_label = mk_label('Palette — weighted mix to paint:')

    W.palette_grid = mk_grid(
        { { label = 'Type', width = 320 }, { label = 'Weight', width = 100 } },
        function(i)
            W.palette_sel = i
            pcall(function()
                local row = W.palette[i]
                if row and W.weight_spin and W.weight_spin.setValue then
                    W.weight_spin:setValue(row.weight)
                end
            end)
        end,
        nil)

    W.weight_label = mk_label('Weight:')
    W.weight_spin  = mk_spin(1, 0, 100, 1, false,
        'Relative chance of this type per placement (0 = never)', nil)
    if Button then
        W.weight_set_btn = Button.new()
        pcall(function() W.weight_set_btn:setText('Set') end)
        try_skin(W.weight_set_btn, 'sms_button')
        pcall(function() W.weight_set_btn.onChange = on_set_weight end)
        insert(W.weight_set_btn)

        W.remove_btn = Button.new()
        pcall(function() W.remove_btn:setText('Remove') end)
        try_skin(W.remove_btn, 'sms_button')
        pcall(function() W.remove_btn.onChange = on_remove_palette_row end)
        insert(W.remove_btn)

        W.eyedrop_btn = Button.new()
        pcall(function() W.eyedrop_btn:setText('Add selected from map') end)
        try_skin(W.eyedrop_btn, 'sms_button')
        pcall(function() W.eyedrop_btn:setTooltipText('Eyedropper: add the type(s) of the statics currently selected on the map') end)
        pcall(function() W.eyedrop_btn.onChange = on_add_from_selection end)
        insert(W.eyedrop_btn)
    end

    -- --- Paint settings region ---
    W.sep2 = Static.new()
    try_skin(W.sep2, 'sms_separator')
    insert(W.sep2)

    W.country_label = mk_label('Country:')
    if ToggleButton then
        W.country_filter_btn = ToggleButton.new()
        pcall(function() W.country_filter_btn:setText('Combat') end)
        try_skin(W.country_filter_btn, 'sms_button')
        pcall(function()
            if W.country_filter_btn.addChangeCallback then
                W.country_filter_btn:addChangeCallback(function(self)
                    local on = self.getState and self:getState() or false
                    pcall(function() self:setText(on and 'All' or 'Combat') end)
                    populate_country_combo()
                end)
            end
        end)
        insert(W.country_filter_btn)
    end
    if ComboList then
        W.country_combo = ComboList.new()
        try_skin(W.country_combo, 'comboListSkinNew_')
        pcall(function()
            if W.country_combo.addChangeCallback then
                W.country_combo:addChangeCallback(function()
                    populate_catalog()
                end)
            end
        end)
        insert(W.country_combo)
    else
        W.country_combo = Static.new()
        pcall(function() W.country_combo:setText('(ComboList unavailable)') end)
        try_skin(W.country_combo, 'staticSkin_ME')
        insert(W.country_combo)
    end

    W.name_label = mk_label('Name:')
    W.name_input = mk_edit('', 'Name for painted statics. {n} = running index (Barrel-{n} → Barrel-01). Empty = type name.')

    W.radius_label  = mk_label('Brush radius (m):')
    W.radius_spin   = mk_spin(W.cfg.radius, 1, 2000, 5, false, 'Brush circle radius in meters', function(self)
        pcall(function() W.cfg.radius = math.max(1, tonumber(self:getValue()) or W.cfg.radius) end)
        if W.armed then resize_brush_overlay() end
    end)

    W.density_label = mk_label('Density /100m²:')
    W.density_spin  = mk_spin(W.cfg.density, 0.01, 50, 0.1, true, 'Target statics per 100 m² (a 10×10 m square)', function(self)
        pcall(function() W.cfg.density = math.max(0.01, tonumber(self:getValue()) or W.cfg.density) end)
    end)

    W.spacing_label = mk_label('Min spacing (m):')
    W.spacing_spin  = mk_spin(W.cfg.min_spacing, 0, 500, 1, false, 'Minimum distance between painted statics, meters', function(self)
        pcall(function() W.cfg.min_spacing = tonumber(self:getValue()) or W.cfg.min_spacing end)
    end)

    -- Heading row: random toggle (default ON) + fixed-degrees spin used
    -- when the toggle is off.
    if ToggleButton then
        W.heading_toggle = ToggleButton.new()
        pcall(function() W.heading_toggle:setText('Random heading') end)
        try_skin(W.heading_toggle, 'sms_button')
        pcall(function() W.heading_toggle:setState(true) end)
        pcall(function() W.heading_toggle:setTooltipText('ON: each static gets a random heading. OFF: the fixed value on the right.') end)
        pcall(function()
            if W.heading_toggle.addChangeCallback then
                W.heading_toggle:addChangeCallback(function(self)
                    local on = self.getState and self:getState() or false
                    W.cfg.heading_random = on
                end)
            end
        end)
        insert(W.heading_toggle)
    end
    W.heading_label = mk_label('Fixed (°):')
    W.heading_spin  = mk_spin(W.cfg.heading_deg, 0, 359, 1, false, 'Fixed heading in degrees (used when Random heading is off)', function(self)
        pcall(function() W.cfg.heading_deg = (tonumber(self:getValue()) or 0) % 360 end)
    end)

    -- Seed row: opt-in reproducible scatter.
    if CheckBoxModule then
        W.seed_check = CheckBoxModule.new('Seed')
        -- Same native ME checkbox skin the Prefab Manager's "Fixed location"
        -- box uses, so it visually matches the rest of the tool windows.
        try_skin(W.seed_check, 'checkBoxSkin_MENew')
        pcall(function() W.seed_check:setTooltipText('Seed the scatter RNG per stroke for reproducible results') end)
        pcall(function()
            if W.seed_check.addChangeCallback then
                W.seed_check:addChangeCallback(function(self)
                    pcall(function() W.cfg.seed_on = self:getState() == true end)
                end)
            end
        end)
        insert(W.seed_check)
    else
        W.seed_check = mk_label('Seed (n/a):')
    end
    W.seed_spin = mk_spin(W.cfg.seed, 0, 999999, 1, false, 'Seed value (only used when Seed is checked)', function(self)
        pcall(function() W.cfg.seed = tonumber(self:getValue()) or W.cfg.seed end)
    end)

    if ToggleButton then
        W.erase_toggle = ToggleButton.new()
        pcall(function() W.erase_toggle:setText('Erase mode') end)
        try_skin(W.erase_toggle, 'sms_button')
        pcall(function() W.erase_toggle:setTooltipText('OFF = paint statics. ON = erase tool-painted statics under the brush. Never touches hand-placed objects.') end)
        pcall(function()
            if W.erase_toggle.addChangeCallback then
                W.erase_toggle:addChangeCallback(function(self)
                    local on = self.getState and self:getState() or false
                    W.cfg.mode = on and 'erase' or 'paint'
                    refresh_paint_affordance()
                    if not W.armed then
                        set_status(on and 'Erase mode: strokes will delete tool-painted statics.'
                                       or 'Paint mode.', on and 'warning' or 'info')
                    end
                end)
            end
        end)
        insert(W.erase_toggle)
    end

    if Button then
        W.paint_btn = Button.new()
        pcall(function() W.paint_btn:setText('Paint on map') end)
        try_skin(W.paint_btn, 'sms_button')
        pcall(function()
            W.paint_btn.onChange = function()
                if W.armed then disarm_paint() else arm_paint() end
            end
        end)
        insert(W.paint_btn)
    end

    populate_country_combo()
    populate_catalog(true)
    render_palette()

    local x, y, w, h = W.sms_window:get_content_bounds()
    relayout(x, y, w, h)
    return true
end

-- ---------------------------------------------------------------------------
-- Public lifecycle
-- ---------------------------------------------------------------------------
function M.show()
    if W.sms_window then
        populate_country_combo()
        populate_catalog()
        W.sms_window:show()
        return
    end
    local ok, err = pcall(build_window)
    if not ok then
        log_write(log.ERROR, 'build_window threw: ' .. tostring(err))
        return
    end
    if W.sms_window then W.sms_window:show() end
end

function M.hide()
    disarm_paint()
    pcall(function() if W.sms_window then W.sms_window:hide() end end)
end

-- Hide the window + disarm. Dev-loop helper: call before a hot-reload so
-- no stale window widget lingers (reload-me-mod clears package.loaded but
-- can't reach this module's dxgui widgets).
function M.dispose()
    disarm_paint()
    pcall(function()
        if W.preview then W.preview:dispose(); W.preview = nil end
    end)
    pcall(function()
        if W.window and W.window.setVisible then W.window:setVisible(false) end
    end)
end

function M.toggle()
    if not W.sms_window then
        M.show()
        return
    end
    local visible = false
    pcall(function()
        local raw = W.sms_window:raw()
        if raw and raw.getVisible then visible = raw:getVisible() end
    end)
    if visible then M.hide() else M.show() end
end

-- ---------------------------------------------------------------------------
-- Debug / verification surface (gui-bridge driven, §8 of the design brief)
-- ---------------------------------------------------------------------------

-- Run a synthetic stroke through the real pipeline. points = { {x=,y=}, … }
-- (world coords). opts may override radius / density / min_spacing / type /
-- country / name / heading / seed. Returns counts + created names.
function M._debug_stroke(points, opts)
    if type(points) ~= 'table' or #points == 0 then
        return { ok = false, error = 'points must be a non-empty list' }
    end
    opts = opts or {}
    if opts.type then
        local row, err = static_catalog.resolve_type(opts.type)
        if not row then return { ok = false, error = err } end
        row.kind, row.weight = 'static', 1
        opts.palette = { row }
    end
    local first = points[1]
    local ok, err = begin_stroke(first.x, first.y, opts)
    if not ok then return { ok = false, error = err } end
    for _, p in ipairs(points) do
        stroke_step(p.x, p.y)
    end
    local n, failed = end_stroke()
    local names = {}
    for _, e in ipairs(W.registry) do
        if e.group and e.group.name then names[#names + 1] = e.group.name end
    end
    return { ok = true, placed = n, failed = failed, registry = #W.registry, names = names }
end

-- Run a synthetic erase stroke through the real pipeline (hit-test →
-- batch remove → snapshots → undo record). Set the brush radius first via
-- _debug_set_brush.
function M._debug_erase(points)
    if type(points) ~= 'table' or #points == 0 then
        return { ok = false, error = 'points must be a non-empty list' }
    end
    begin_erase_stroke()
    for _, p in ipairs(points) do
        erase_step(p.x, p.y)
    end
    local n = end_erase_stroke()
    return { ok = true, erased = n, registry = #W.registry }
end

function M._registry_size()
    return { ok = true, size = #W.registry }
end

function M._state()
    return { ok = true, armed = W.armed, painting = W.painting, registry = #W.registry,
             palette = #W.palette, catalog = #W.catalog_rows, visible = #W.catalog_visible }
end

-- Headless palette mutation for the verification loop.
function M._debug_palette_add(type_name, weight)
    local row, err = static_catalog.resolve_type(type_name)
    if not row then return { ok = false, error = err } end
    add_palette_row(row)
    if weight then
        for _, r in ipairs(W.palette) do
            if r.type == type_name then r.weight = weight end
        end
        render_palette()
    end
    return { ok = true, palette = #W.palette }
end

function M._debug_palette_clear()
    W.palette, W.palette_sel = {}, nil
    render_palette()
    return { ok = true }
end

function M._debug_set_brush(radius, density, spacing)
    if radius then
        W.cfg.radius = radius
        pcall(function() if W.radius_spin and W.radius_spin.setValue then W.radius_spin:setValue(radius) end end)
    end
    if density then
        W.cfg.density = density
        pcall(function() if W.density_spin and W.density_spin.setValue then W.density_spin:setValue(density) end end)
    end
    if spacing then
        W.cfg.min_spacing = spacing
        pcall(function() if W.spacing_spin and W.spacing_spin.setValue then W.spacing_spin:setValue(spacing) end end)
    end
    return { ok = true, radius = get_radius(), density = get_density(), spacing = get_min_spacing() }
end

-- Merge fields into cfg and mirror to widgets where they exist. Fields:
-- heading_random (bool), heading_deg, seed_on (bool), seed, mode.
function M._debug_set_cfg(tbl)
    for k, v in pairs(tbl or {}) do W.cfg[k] = v end
    pcall(function()
        if tbl.heading_random ~= nil and W.heading_toggle and W.heading_toggle.setState then
            W.heading_toggle:setState(tbl.heading_random == true)
        end
        if tbl.heading_deg and W.heading_spin and W.heading_spin.setValue then
            W.heading_spin:setValue(tbl.heading_deg)
        end
        if tbl.seed_on ~= nil and W.seed_check and W.seed_check.setState then
            W.seed_check:setState(tbl.seed_on == true)
        end
        if tbl.seed and W.seed_spin and W.seed_spin.setValue then
            W.seed_spin:setValue(tbl.seed)
        end
        if tbl.mode and W.erase_toggle and W.erase_toggle.setState then
            W.erase_toggle:setState(tbl.mode == 'erase')
        end
    end)
    return { ok = true, cfg = W.cfg }
end

-- Select a catalog row by type name (drives the 3D preview), headlessly.
function M._debug_select_catalog(type_name)
    for i, r in ipairs(W.catalog_visible) do
        if r.type == type_name then
            W.catalog_sel = i
            pcall(function()
                if W.catalog_grid and W.catalog_grid.selectRow then W.catalog_grid:selectRow(i - 1) end
            end)
            update_preview()
            return { ok = true, index = i, display = r.display,
                     preview = W.preview ~= nil }
        end
    end
    return { ok = false, error = 'type not in visible catalog: ' .. tostring(type_name) }
end

function M._debug_eyedrop()
    on_add_from_selection()
    return M._debug_palette()
end

function M._debug_palette()
    local out = {}
    for _, r in ipairs(W.palette) do
        out[#out + 1] = { type = r.type, weight = r.weight, category = r.category }
    end
    return { ok = true, rows = out }
end

return M
