-- mass_edit_forms/set_fuel_pct_unit.lua -- Mass Edit form: set internal
-- fuel as a percentage of the airframe's maximum. Planes + helicopters
-- only.
--
-- The UI takes a 0-100% input but the underlying verb
-- (verbs.unit_set_fuel) wants absolute kg. To bridge that we look up
-- each unit's per-airframe max fuel weight and compute
--   kg = (pct / 100) * max_fuel
--
-- The spike in /c/Program Files/Eagle Dynamics/DCS World/MissionEditor/
-- shows the ME itself sources this from `me_db_api.unit_by_type[type]
-- .MaxFuelWeight` (see me_aircraft.lua line 895-896 and me_mission.lua's
-- payload.fuel defaulting). That's the production resolver below. We
-- also keep a defensive `_G.db.Units.{Planes,Helicopters}.fuel_max`
-- attempt for forward-compat in case a future DCS build changes the
-- shape; if neither path yields a positive number, the form falls back
-- to "% of u.payload.fuel" (the unit's CURRENT fuel kg). That keeps
-- "halve current fuel" useful even on mod aircraft whose db entries we
-- can't read; the toast surfaces fallback usage as
--   "N used current-fuel fallback".
--
-- The resolver is injectable via M._set_max_fuel_resolver(fn) so unit
-- tests can drive both branches deterministically without standing up
-- a real ME db.
--
-- Public:
--   M.scope       : 'unit'
--   M.title       : 'Set fuel %'
--   M.applies_to  : { plane = true, helicopter = true }
--   M.new(parent_raw, get_checked, on_after_apply, get_categories)
--   M._apply(entities, pct, categories)
--               → { changed, failed, not_applicable, unresolved,
--                   changed_rows, nothing_selected?, toast, sev }
--   M._set_max_fuel_resolver(fn)  -- test hook

local M = {}

M.scope = 'unit'
M.title = 'Set fuel %'
M.applies_to = { plane = true, helicopter = true }

local undo          = require('dcs_sms_me.undo')
local skin_helper   = require('dcs_sms_me.skin_helper')
local applicability = require('dcs_sms_me.applicability')

local Static;  do local ok, m = pcall(require, 'Static');  if ok then Static  = m end end
local EditBox; do local ok, m = pcall(require, 'EditBox'); if ok then EditBox = m end end
local Button;  do local ok, m = pcall(require, 'Button');  if ok then Button  = m end end

local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.mass_edit.set_fuel_pct_unit', _G.log.WARNING or 2, msg) end)
end

-- ---------------------------------------------------------------------------
-- Per-airframe max-fuel resolver (injectable for tests).
-- ---------------------------------------------------------------------------
-- max_fuel_for(u) -> numeric kg, or nil if unknown.
local _max_fuel_resolver = function(u)
    local airframe = u and u.type
    if type(airframe) ~= 'string' or airframe == '' then return nil end

    -- Primary: ME's own DB (matches what me_aircraft.lua reads).
    do
        local ok, val = pcall(function()
            local DB = require('me_db_api')
            local entry = DB and DB.unit_by_type and DB.unit_by_type[airframe]
            return entry and tonumber(entry.MaxFuelWeight)
        end)
        if ok and type(val) == 'number' and val > 0 then return val end
    end

    -- Secondary defensive paths against _G.db (future-shape compat).
    do
        local ok, val = pcall(function()
            local db = _G.db
            local entry = db and db.Units and db.Units.Planes and db.Units.Planes.Plane and db.Units.Planes.Plane[airframe]
            return entry and tonumber(entry.fuel_max)
        end)
        if ok and type(val) == 'number' and val > 0 then return val end
    end
    do
        local ok, val = pcall(function()
            local db = _G.db
            local entry = db and db.Units and db.Units.Helicopters and db.Units.Helicopters.Helicopter and db.Units.Helicopters.Helicopter[airframe]
            return entry and tonumber(entry.fuel_max)
        end)
        if ok and type(val) == 'number' and val > 0 then return val end
    end
    return nil
end

function M._set_max_fuel_resolver(fn) _max_fuel_resolver = fn end

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------

function M._apply(entities, pct, categories)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, failed = 0, not_applicable = 0, unresolved = 0,
            changed_rows = {}, nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end
    if type(pct) ~= 'number' or pct < 0 or pct > 100 then
        return {
            changed = 0, failed = 0, not_applicable = 0, unresolved = 0,
            changed_rows = {},
            toast = 'Enter 0-100%', sev = 'warning',
        }
    end

    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed, not_applicable, unresolved = {}, 0, 0, 0

    for _, u in ipairs(entities) do
        if not applicability.is_applicable(M.applies_to, u, categories) then
            not_applicable = not_applicable + 1
        else
            local max_kg = _max_fuel_resolver(u)
            local kg
            if type(max_kg) == 'number' and max_kg > 0 then
                kg = (pct / 100) * max_kg
            else
                -- Fallback: % of current u.payload.fuel. Useful for
                -- "halve current fuel" workflows even when max_fuel
                -- isn't known for the airframe.
                local cur = (u.payload and tonumber(u.payload.fuel)) or 0
                kg = (pct / 100) * cur
                unresolved = unresolved + 1
            end
            local old_kg = (u.payload and tonumber(u.payload.fuel)) or 0
            local p_ok, res = pcall(verbs.unit_set_fuel, { id = u.unitId, fuel = kg })
            if not p_ok then
                failed = failed + 1
                log_warn('unit_set_fuel threw: ' .. tostring(res))
            elseif type(res) ~= 'table' or not res.ok then
                failed = failed + 1
                log_warn('unit_set_fuel failed: ' .. tostring(res and res.error or '?'))
            else
                changed_rows[#changed_rows + 1] = { unit = u, old_kg = old_kg }
            end
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.set_fuel_pct_unit', { rows = changed_rows })
    end

    local result = {
        changed        = #changed_rows,
        failed         = failed,
        not_applicable = not_applicable,
        unresolved     = unresolved,
        changed_rows   = changed_rows,
    }

    if #changed_rows == 0 and failed == 0 and not_applicable > 0 then
        result.toast = 'Nothing applicable'
        result.sev   = 'warning'
    elseif #changed_rows == 0 and failed > 0 then
        result.toast = string.format('0 fuel set · %d failed', failed)
        result.sev   = 'error'
    else
        local toast = string.format('%d fuel set', #changed_rows)
        if not_applicable > 0 then toast = toast .. string.format(' · %d not applicable', not_applicable) end
        if unresolved > 0     then toast = toast .. string.format(' · %d used current-fuel fallback', unresolved) end
        if failed > 0         then toast = toast .. string.format(' · %d failed', failed) end
        result.toast = toast
        result.sev   = (failed == 0 and 'success') or 'warning'
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Undo handler -- restores via verbs.unit_set_fuel with the OLD kg.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.set_fuel_pct_unit', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.set_fuel_pct_unit undo snapshot'
    end
    local verbs = require('dcs_sms_me.verbs')
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        local p_ok, res = pcall(verbs.unit_set_fuel, { id = r.unit.unitId, fuel = r.old_kg })
        if not (p_ok and type(res) == 'table' and res.ok) then
            errors = errors + 1
        end
    end
    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

-- ---------------------------------------------------------------------------
-- Widget construction (not unit-tested; covered by manual smoke).
-- ---------------------------------------------------------------------------

local LAYOUT = {
    PAD_X      = 8,
    LABEL_W    = 56,
    INPUT_W    = 64,
    ROW_H      = 24,
    BTN_W      = 90,
    GAP_X      = 6,
    GAP_Y      = 4,
    FOOTER_PAD = 6,
}

local function form_height()
    local L = LAYOUT
    return L.ROW_H + L.FOOTER_PAD
end

function M.new(parent_raw, get_checked, on_after_apply, get_categories)
    if not parent_raw then return nil end

    local owned = {}
    local function add(widget)
        if widget then owned[#owned + 1] = widget; pcall(parent_raw.insertWidget, parent_raw, widget) end
        return widget
    end

    local pct_lbl, pct_box, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Fuel %:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); pct_lbl = add(s) end
    end
    if EditBox and EditBox.new then
        local ok, e = pcall(EditBox.new)
        if ok and e then
            skin_helper.apply(e, 'editBoxSkin_ME')
            if e.setText then pcall(e.setText, e, '50') end
            pct_box = add(e)
        end
    end

    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Set') end
            apply_btn = add(b)
        end
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local txt = (pct_box and pct_box.getText and pct_box:getText()) or ''
                local pct = tonumber(txt)
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local cats     = (type(get_categories) == 'function') and get_categories() or {}
                local result   = M._apply(entities, pct, cats)
                if type(on_after_apply) == 'function' then on_after_apply(result) end
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

        local row_y  = y
        local btn_x  = x + w - L.PAD_X - L.BTN_W
        set(pct_lbl, x + L.PAD_X,                            row_y, L.LABEL_W, L.ROW_H)
        set(pct_box, x + L.PAD_X + L.LABEL_W + L.GAP_X,      row_y, L.INPUT_W, L.ROW_H)
        set(apply_btn, btn_x,                                row_y, L.BTN_W,   L.ROW_H)
    end

    return panel
end

return M
