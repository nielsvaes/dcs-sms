-- mass_edit_forms/toggle_static_flags.lua -- Mass Edit form for the
-- 'static' scope: flip up to five static-relevant boolean properties on
-- every checked static group.
--
-- Properties (3 of the 5 mirror toggle_group_flags but written here as a
-- separate form so static scope can have its own field set without
-- branching the existing group form):
--   * hidden          (group.hidden)          — visibility on map
--   * hiddenOnPlanner (group.hiddenOnPlanner) — visibility on mission planner
--   * hiddenOnMFD     (group.hiddenOnMFD)     — visibility on F10 MFD overlay
--   * dead            (group.dead)            — render as wreckage on start
--   * canCargo        (group.units[1].canCargo) — sling-loadable; ONLY
--                                                applicable when the unit's
--                                                category is 'Cargos'.
--
-- The first four target the group dict; canCargo targets the single
-- unit (statics are single-unit groups in the ME data model). The PROPS
-- entries carry a `target` flag so _apply and undo know where each
-- field lives.
--
-- Per-row applicability:
--   * hidden / HOP / HOM / dead → every static
--   * canCargo → only when units[1].category == 'Cargos'. Non-cargo
--     statics with canCargo set ON get counted as 'not applicable',
--     same skip-and-count flow toggle_group_flags uses for category-
--     restricted fields.
--
-- Each property has its own tri-state control (LEAVE / ON / OFF).
-- LEAVE means "skip this field in this batch"; ON/OFF write true/false
-- respectively. The toggle fields have no side effects beyond their own
-- value, so the form writes fields directly rather than routing through
-- verbs (same approach as toggle_group_flags). Undo also writes
-- directly.

local M = {}

M.scope = 'static'
M.title = 'Visibility & state'

local undo             = require('dcs_sms_me.undo')
local skin_helper      = require('dcs_sms_me.skin_helper')
local tri_state_button = require('dcs_sms_me.tri_state_button')
local me_refresh;   do local ok, m = pcall(require, 'dcs_sms_me.me_refresh'); if ok then me_refresh = m end end

local Static; do local ok, m = pcall(require, 'Static'); if ok then Static = m end end
local Button; do local ok, m = pcall(require, 'Button'); if ok then Button = m end end

-- ---------------------------------------------------------------------------
-- Property metadata
-- ---------------------------------------------------------------------------

-- target='group' fields are written to the entity (a static group);
-- target='unit' fields are written to entity.units[1] (the single
-- static unit). cargo_only=true gates the field to Cargos-category
-- statics — non-cargo statics get skip-and-count.
local PROPS = {
    { field = 'hidden',          label = 'Hidden on map',     target = 'group' },
    { field = 'hiddenOnPlanner', label = 'Hidden on planner', target = 'group' },
    { field = 'hiddenOnMFD',     label = 'Hidden on MFD',     target = 'group' },
    { field = 'dead',            label = 'Dead',              target = 'group' },
    { field = 'canCargo',        label = 'Can be cargo',      target = 'unit', cargo_only = true },
}

local PROP_BY_FIELD = {}
for _, p in ipairs(PROPS) do PROP_BY_FIELD[p.field] = p end

-- canCargo gating. ED's me_static panel reads the type DB to decide
-- whether to show the canCargo control (udb.category == 'Cargo'); the
-- per-unit field in the .miz uses 'Cargos' (plural). Prefer the unit's
-- own category field — it's already on the entity and matches what
-- DCS persists — and fall back to the DB only if absent.
local function unit_is_cargo(u)
    if type(u) ~= 'table' then return false end
    if u.category == 'Cargos' then return true end
    local ok, DB = pcall(require, 'me_db_api')
    if ok and DB and DB.unit_by_type and type(u.type) == 'string' then
        local udb = DB.unit_by_type[u.type]
        if udb then return udb.category == 'Cargo' end
    end
    return false
end

-- Per-entity per-field applicability. Returns the row target table
-- (either the group itself or its first unit) when applicable, else nil.
local function applies_to_entity(prop, entity)
    if prop.target == 'group' then return entity end
    if prop.target == 'unit' then
        local u = type(entity.units) == 'table' and entity.units[1] or nil
        if not u then return nil end
        if prop.cargo_only and not unit_is_cargo(u) then return nil end
        return u
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------

function M._apply(entities, settings, _categories)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, not_applicable = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end
    if type(settings) ~= 'table' or next(settings) == nil then
        return {
            changed = 0, not_applicable = 0, changed_rows = {},
            nothing_to_apply = true,
            toast = 'Nothing to apply', sev = 'warning',
        }
    end

    local changed_rows = {}
    local not_applicable_entities = 0
    local refreshed = {}

    for _, e in ipairs(entities) do
        local entity_had_inapplicable = false
        for field, target_value in pairs(settings) do
            local prop = PROP_BY_FIELD[field]
            local write_target = prop and applies_to_entity(prop, e) or nil
            if write_target then
                local old_value = write_target[field]
                if type(old_value) ~= 'boolean' then old_value = false end

                write_target[field] = target_value and true or false

                changed_rows[#changed_rows + 1] = {
                    entity = e,
                    write_target = write_target,
                    field = field,
                    old = old_value,
                }
                refreshed[e] = true
            else
                entity_had_inapplicable = true
            end
        end
        if entity_had_inapplicable then
            not_applicable_entities = not_applicable_entities + 1
        end
    end

    -- Visibility refresh — same hidden-flip handling as toggle_group_flags.
    -- `dead` and `canCargo` don't need a redraw at the ME map level.
    if me_refresh and type(me_refresh.update_hidden_group) == 'function' then
        for e in pairs(refreshed) do pcall(me_refresh.update_hidden_group, e) end
    end
    if me_refresh and type(me_refresh.refresh_group_panels) == 'function' and #changed_rows > 0 then
        pcall(me_refresh.refresh_group_panels)
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.toggle_static_flags', { rows = changed_rows })
    end

    local changed = #changed_rows
    local result = {
        changed        = changed,
        not_applicable = not_applicable_entities,
        changed_rows   = changed_rows,
    }

    if changed == 0 and not_applicable_entities > 0 then
        result.toast = 'Nothing applicable'
        result.sev   = 'warning'
    else
        local toast = (changed == 1) and '1 flag change' or string.format('%d flag changes', changed)
        if not_applicable_entities > 0 then
            toast = toast .. string.format(' · %d not applicable', not_applicable_entities)
        end
        result.toast = toast
        result.sev   = 'success'
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Undo handler — restore each row's old value to its write_target (the
-- group OR the unit, depending on the field). Reverse-iterate so a
-- multi-field change on one entity unwinds in opposite-of-apply order.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.toggle_static_flags', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.toggle_static_flags undo snapshot'
    end
    local refreshed = {}
    for i = #snapshot.rows, 1, -1 do
        local r = snapshot.rows[i]
        if r and r.write_target and r.field then
            r.write_target[r.field] = r.old and true or false
            if r.entity then refreshed[r.entity] = true end
        end
    end
    if me_refresh and type(me_refresh.update_hidden_group) == 'function' then
        for e in pairs(refreshed) do pcall(me_refresh.update_hidden_group, e) end
    end
    if me_refresh and type(me_refresh.refresh_group_panels) == 'function' then
        pcall(me_refresh.refresh_group_panels)
    end
    return true
end)

-- ---------------------------------------------------------------------------
-- Widget construction
-- ---------------------------------------------------------------------------

local STATE_LEAVE = tri_state_button.STATE_LEAVE
local STATE_ON    = tri_state_button.STATE_ON
local STATE_OFF   = tri_state_button.STATE_OFF

local LAYOUT = {
    PAD_X     = 8,
    GAP_X     = 6,
    GAP_Y     = 4,
    ROW_H     = 24,
    APPLY_W   = 90,
    FOOTER_PAD = 6,
}

local function form_height()
    local L = LAYOUT
    -- 5 props on a 3-col grid = 2 rows (cell 6 empty), + Apply row + footer.
    return L.ROW_H + L.GAP_Y + L.ROW_H + L.GAP_Y + L.ROW_H + L.FOOTER_PAD
end

function M.new(parent_raw, get_checked, on_after_apply, get_categories)
    if not parent_raw then return nil end

    local owned = {}
    local function add(widget)
        if widget then owned[#owned + 1] = widget; pcall(parent_raw.insertWidget, parent_raw, widget) end
        return widget
    end

    local tsb_by_field = {}

    local function reset_all_states()
        for _, p in ipairs(PROPS) do
            local tsb = tsb_by_field[p.field]
            if tsb then tsb:set_state(STATE_LEAVE) end
        end
    end

    for _, p in ipairs(PROPS) do
        local tsb = tri_state_button.new(parent_raw, p.label)
        if tsb then
            tsb_by_field[p.field] = tsb
            owned[#owned + 1] = tsb:widget()
        end
    end

    local apply_btn
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Apply') end
            apply_btn = add(b)
        end
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local settings = {}
                for _, p in ipairs(PROPS) do
                    local tsb = tsb_by_field[p.field]
                    local st  = tsb and tsb:get_state() or STATE_LEAVE
                    if st == STATE_ON then
                        settings[p.field] = true
                    elseif st == STATE_OFF then
                        settings[p.field] = false
                    end
                end
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local categories = (type(get_categories) == 'function') and get_categories() or {}
                local result = M._apply(entities, settings, categories)
                if type(on_after_apply) == 'function' then on_after_apply(result) end
                if result and result.changed and result.changed > 0 then
                    reset_all_states()
                end
            end)
        end)
    end

    local panel = {}

    function panel:show()
        for _, w in ipairs(owned) do
            if w.setVisible then pcall(w.setVisible, w, true) end
        end
    end

    function panel:hide()
        for _, w in ipairs(owned) do
            if w.setVisible then pcall(w.setVisible, w, false) end
        end
    end

    function panel:get_height() return form_height() end

    function panel:set_enabled(flag)
        -- The other four tsbs (hidden / HOP / HOM / dead) + Apply
        -- follow the standard >=1-checked rule. canCargo is stricter:
        -- enabled only when EVERY checked static is a Cargo-category
        -- one. A mixed selection (cargo + non-cargo) disables canCargo
        -- so the user can't accidentally apply an ON/OFF that silently
        -- skips half the rows. Pure-cargo → enabled; pure non-cargo
        -- (or empty) → disabled.
        local en_any = flag and true or false
        local en_cargo = en_any
        if en_any then
            local entities = (type(get_checked) == 'function') and get_checked() or {}
            if #entities == 0 then
                en_cargo = false
            else
                for _, e in ipairs(entities) do
                    local u = type(e.units) == 'table' and e.units[1] or nil
                    if not (u and unit_is_cargo(u)) then
                        en_cargo = false
                        break
                    end
                end
            end
        end

        local cargo_tsb = tsb_by_field['canCargo']
        local cargo_widget = cargo_tsb and cargo_tsb:widget() or nil
        for _, w in ipairs(owned) do
            if w.setEnabled then
                if w == cargo_widget then
                    pcall(w.setEnabled, w, en_cargo)
                else
                    pcall(w.setEnabled, w, en_any)
                end
            end
        end
    end

    function panel:set_bounds(x, y, w, h)
        local L = LAYOUT

        local function set(widget, px, py, pw, ph)
            if widget and widget.setBounds then pcall(widget.setBounds, widget, px, py, pw, ph) end
        end

        -- 3 columns × 2 rows; 5 fields fill cells 1..5, cell 6 left empty.
        local content_w = w - 2 * L.PAD_X
        local col_w = math.floor((content_w - 2 * L.GAP_X) / 3)
        if col_w < 60 then col_w = 60 end

        local row1_y = y
        local row2_y = row1_y + L.ROW_H + L.GAP_Y

        for i = 1, #PROPS do
            local p = PROPS[i]
            local tsb = tsb_by_field[p.field]
            local col = ((i - 1) % 3)
            local px = x + L.PAD_X + col * (col_w + L.GAP_X)
            local py = (i <= 3) and row1_y or row2_y
            if tsb then tsb:set_bounds(px, py, col_w, L.ROW_H) end
        end

        local apply_y = row2_y + L.ROW_H + L.GAP_Y
        set(apply_btn, x + w - L.PAD_X - L.APPLY_W, apply_y, L.APPLY_W, L.ROW_H)
    end

    return panel
end

return M
