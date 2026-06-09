-- mass_edit_forms/toggle_unit_flags.lua -- Mass Edit (Unit scope) form:
-- flip the per-UNIT boolean properties that DCS stores on individual
-- vehicle units -- playerCanDrive and coldAtStart -- on every checked
-- unit.
--
-- These live on the unit, not the group (me_vehicle.lua writes
-- vdata.group.units[cur].playerCanDrive / .coldAtStart, lines 519 / 528),
-- which is why they get their own Unit-scope form instead of riding in
-- toggle_group_flags. They are ground-vehicle only -- aircraft, ships
-- and statics have no such checkbox.
--
-- Per-unit-TYPE gating mirrors ED's checkbox-enable logic
-- (me_vehicle.lua:checkPlayerCanDrive):
--   * playerCanDrive  -- only unit types whose db def has
--                        enablePlayerCanDrive == true. ED disables (and
--                        force-clears) the checkbox otherwise.
--   * coldAtStart     -- every vehicle EXCEPT Infantry (ED disables it
--                        for the Infantry category).
-- Units a field can't apply to are skipped and counted toward
-- not_applicable, the same way toggle_group_flags treats off-category
-- fields.
--
-- Each property has its own tri-state control (LEAVE / ON / OFF). LEAVE
-- skips the property; ON/OFF write true/false. Like toggle_group_flags
-- the writes have no side effects beyond their own value, so the form
-- mutates unit fields directly (no verb roundtrip) and undo restores them
-- directly too.

local M = {}

M.scope = 'unit'
M.title = 'Driver & start state'
-- Category gray-out gate (mass_edit.lua reads form_module.applies_to).
-- Ground vehicles only; the finer per-unit-type gating happens in _apply.
M.applies_to = { vehicle = true }

local undo             = require('dcs_sms_me.undo')
local skin_helper      = require('dcs_sms_me.skin_helper')
local applicability    = require('dcs_sms_me.applicability')
local tri_state_button = require('dcs_sms_me.tri_state_button')
local me_refresh;   do local ok, m = pcall(require, 'dcs_sms_me.me_refresh'); if ok then me_refresh = m end end

local Button; do local ok, m = pcall(require, 'Button'); if ok then Button = m end end

-- ---------------------------------------------------------------------------
-- Property metadata
-- ---------------------------------------------------------------------------

local PROPS = {
    { field = 'playerCanDrive', label = 'Player can drive' },
    { field = 'coldAtStart',    label = 'Cold at start'    },
}

local PROP_BY_FIELD = {}
for _, p in ipairs(PROPS) do PROP_BY_FIELD[p.field] = p end

-- ---------------------------------------------------------------------------
-- Per-unit-type capability resolver (injectable for tests).
-- ---------------------------------------------------------------------------
--
-- caps_for(u) -> { playerCanDrive = bool, coldAtStart = bool } -- whether
-- each FIELD is settable for that unit's type. Mirrors ED's
-- checkPlayerCanDrive enable logic. Default reads me_db_api; tests inject
-- a stub so they don't need a real ME db.
local function _default_caps(u)
    local utype = u and u.type
    if type(utype) ~= 'string' or utype == '' then
        return { playerCanDrive = false, coldAtStart = false }
    end
    local ok, DB = pcall(require, 'me_db_api')
    if not (ok and type(DB) == 'table' and type(DB.unit_by_type) == 'table') then
        -- db unavailable (bare test VM): can't confirm drivability, but
        -- cold-at-start is valid for ~every non-Infantry vehicle, which we
        -- also can't disprove here -- leave it enabled so the control isn't
        -- silently useless if the db ever fails to load in production.
        return { playerCanDrive = false, coldAtStart = true }
    end
    local def = DB.unit_by_type[utype]
    if type(def) ~= 'table' then
        return { playerCanDrive = false, coldAtStart = true }
    end
    -- Infantry detection mirrors me_vehicle.lua:updateCategory -- the
    -- 'Infantry' tag on the unit def (or the legacy .category string on
    -- tagless defs).
    local infantry = false
    if type(def.tags) == 'table' then
        for _, t in pairs(def.tags) do
            if t == 'Infantry' then infantry = true; break end
        end
    elseif def.category == 'Infantry' then
        infantry = true
    end
    return {
        playerCanDrive = def.enablePlayerCanDrive == true,
        coldAtStart    = not infantry,
    }
end

local _caps_resolver = _default_caps

function M._set_caps_resolver(fn) _caps_resolver = fn or _default_caps end

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------
--
-- entities: array of unit dicts (the host's get_checked() result)
-- settings: map { field = bool } -- only fields the user set ON or OFF
-- categories: map { unit = category_string }; non-'vehicle' units match
--             no field and count as not_applicable.
function M._apply(entities, settings, categories)
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

    categories = categories or {}

    local changed_rows = {}
    local not_applicable_entities = 0
    local touched = false  -- any field on any unit changed → refresh panels once

    for _, u in ipairs(entities) do
        -- Category gray-out gate (vehicle only) via the shared helper, same
        -- as set_fuel_pct_unit -- keeps the apply-gate and the host's
        -- panel-enable gate (both read M.applies_to) on one source of truth.
        -- Finer per-unit-type gating then happens through _caps_resolver.
        local caps = applicability.is_applicable(M.applies_to, u, categories)
                     and _caps_resolver(u)
                     or { playerCanDrive = false, coldAtStart = false }
        local entity_had_inapplicable = false
        for field, target_value in pairs(settings) do
            if PROP_BY_FIELD[field] and caps[field] then
                -- Capture current value BEFORE the mutation; non-boolean
                -- current values normalize to false so undo restores a
                -- boolean.
                local old_value = u[field]
                if type(old_value) ~= 'boolean' then old_value = false end

                u[field] = target_value and true or false

                changed_rows[#changed_rows + 1] = {
                    unit  = u,
                    field = field,
                    old   = old_value,
                }
                touched = true
            else
                entity_had_inapplicable = true
            end
        end
        if entity_had_inapplicable then
            not_applicable_entities = not_applicable_entities + 1
        end
    end

    -- playerCanDrive / coldAtStart don't change the F10 map symbol, but if
    -- a vehicle panel is open on one of the touched units its checkbox
    -- should reflect the new value. refresh_group_panels re-runs the open
    -- panel's update; no-op for the other categories.
    if touched and me_refresh and type(me_refresh.refresh_group_panels) == 'function' then
        pcall(me_refresh.refresh_group_panels)
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.toggle_unit_flags', { rows = changed_rows })
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
-- Undo handler -- restores each row's old value directly, reverse order.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.toggle_unit_flags', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.toggle_unit_flags undo snapshot'
    end
    local touched = false
    for i = #snapshot.rows, 1, -1 do
        local r = snapshot.rows[i]
        if r and r.unit and r.field then
            r.unit[r.field] = r.old and true or false
            touched = true
        end
    end
    if touched and me_refresh and type(me_refresh.refresh_group_panels) == 'function' then
        pcall(me_refresh.refresh_group_panels)
    end
    return true
end)

-- ---------------------------------------------------------------------------
-- Widget construction (mirrors toggle_group_flags: one tri-state button
-- per PROPS entry + an Apply button, laid out in a 3-col grid).
-- ---------------------------------------------------------------------------

local STATE_LEAVE = tri_state_button.STATE_LEAVE
local STATE_ON    = tri_state_button.STATE_ON
local STATE_OFF   = tri_state_button.STATE_OFF

local LAYOUT = {
    PAD_X      = 8,
    GAP_X      = 6,
    GAP_Y      = 4,
    ROW_H      = 24,
    APPLY_W    = 90,
    FOOTER_PAD = 6,
}

local function form_height()
    local L = LAYOUT
    local nrows = math.ceil(#PROPS / 3)
    return nrows * (L.ROW_H + L.GAP_Y) + L.ROW_H + L.FOOTER_PAD
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
            skin_helper.apply(b, 'sms_button')
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
        local en = flag and true or false
        for _, w in ipairs(owned) do
            if w.setEnabled then pcall(w.setEnabled, w, en) end
        end
    end

    function panel:set_bounds(x, y, w, h)
        local L = LAYOUT

        local function set(widget, px, py, pw, ph)
            if widget and widget.setBounds then pcall(widget.setBounds, widget, px, py, pw, ph) end
        end

        local content_w = w - 2 * L.PAD_X
        local col_w = math.floor((content_w - 2 * L.GAP_X) / 3)
        if col_w < 60 then col_w = 60 end

        for i = 1, #PROPS do
            local p = PROPS[i]
            if p then
                local tsb = tsb_by_field[p.field]
                local col = ((i - 1) % 3)
                local row = math.floor((i - 1) / 3)
                local px = x + L.PAD_X + col * (col_w + L.GAP_X)
                local py = y + row * (L.ROW_H + L.GAP_Y)
                if tsb then tsb:set_bounds(px, py, col_w, L.ROW_H) end
            end
        end

        local nrows = math.ceil(#PROPS / 3)
        local apply_y = y + nrows * (L.ROW_H + L.GAP_Y)
        set(apply_btn, x + w - L.PAD_X - L.APPLY_W, apply_y, L.APPLY_W, L.ROW_H)
    end

    return panel
end

return M
