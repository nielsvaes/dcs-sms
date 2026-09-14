-- mass_edit_forms/randomize_unit_positions.lua
-- Randomly distribute the checked units inside a circular radius around
-- the FIRST checked unit. The first checked unit is the anchor and is not
-- moved. Radius can be entered in kilometres or miles.
--
-- Positions in the DCS mission table are metres:
--   u.x = northing
--   u.y = easting
--
-- The radius is sampled uniformly over the AREA of the circle, rather than
-- uniformly over its distance from the centre:
--   r = sqrt(random()) * radius
-- This avoids over-populating the centre of the circle.

local M = {}

M.scope = 'unit'
M.title = 'Randomize positions'

local undo        = require('dcs_sms_me.undo')
local skin_helper = require('dcs_sms_me.skin_helper')

local Static;    do local ok, m = pcall(require, 'Static');    if ok then Static    = m end end
local EditBox;   do local ok, m = pcall(require, 'EditBox');  if ok then EditBox  = m end end
local Button;    do local ok, m = pcall(require, 'Button');   if ok then Button   = m end end
local ComboList; do local ok, m = pcall(require, 'ComboList');if ok then ComboList = m end end
local ListBoxItem; do local ok, m = pcall(require, 'ListBoxItem'); if ok then ListBoxItem = m end end

-- Seed once so repeated DCS sessions do not produce the same sequence.
math.randomseed(os.time())

local KM_TO_M = 1000
local MI_TO_M = 1609.344

local function log_warn(msg)
    pcall(function()
        _G.log.write('sms.me.mass_edit.randomize_unit_positions',
                     _G.log.WARNING or 2, msg)
    end)
end

local function radius_to_meters(radius, unit)
    if unit == 'mi' then
        return radius * MI_TO_M
    end
    return radius * KM_TO_M
end

-- Pure-ish operation used by the UI and useful for tests.
-- The first entity is the anchor. All remaining entities are moved.
function M._apply(entities, radius, unit)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, failed = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end

    if type(radius) ~= 'number' or radius < 0 then
        return {
            changed = 0, failed = 0, changed_rows = {},
            toast = 'Enter a radius (0 or greater)', sev = 'warning',
        }
    end

    unit = (unit == 'mi') and 'mi' or 'km'
    local radius_m = radius_to_meters(radius, unit)

    local anchor = entities[1]
    local anchor_north = tonumber(anchor.x)
    local anchor_east  = tonumber(anchor.y)
    if anchor_north == nil or anchor_east == nil then
        return {
            changed = 0, failed = 1, changed_rows = {},
            toast = 'First selected unit has no valid position',
            sev = 'error',
        }
    end

    -- With one selected unit there is nothing to distribute.
    if #entities == 1 then
        return {
            changed = 0, failed = 0, changed_rows = {},
            toast = 'Only the anchor is selected',
            sev = 'info',
        }
    end

    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed = {}, 0

    for i = 2, #entities do
        local u = entities[i]
        local old_north = tonumber(u.x) or 0
        local old_east  = tonumber(u.y) or 0

        -- Uniform distribution over a disk.
        local angle = math.random() * 2 * math.pi
        local distance = math.sqrt(math.random()) * radius_m
        local north = anchor_north + math.cos(angle) * distance
        local east  = anchor_east  + math.sin(angle) * distance

        local p_ok, res = pcall(verbs.unit_set_pos, {
            id = u.unitId,
            north = north,
            east = east,
        })

        if not p_ok then
            failed = failed + 1
            log_warn('unit_set_pos threw: ' .. tostring(res))
        elseif type(res) ~= 'table' or not res.ok then
            failed = failed + 1
            log_warn('unit_set_pos failed: ' ..
                     tostring(res and res.error or '?'))
        else
            changed_rows[#changed_rows + 1] = {
                unit = u,
                old_north = old_north,
                old_east = old_east,
            }
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.randomize_unit_positions',
                            { rows = changed_rows })
    end

    local result = {
        changed      = #changed_rows,
        failed       = failed,
        changed_rows = changed_rows,
    }

    if #changed_rows == 0 and failed > 0 then
        result.toast = string.format('0 units moved · %d failed', failed)
        result.sev = 'error'
    elseif #changed_rows == 0 then
        result.toast = 'No changes'
        result.sev = 'warning'
    else
        local radius_text = string.format('%.3g %s', radius, unit)
        result.toast = string.format('%d units randomized within %s of anchor',
                                     #changed_rows, radius_text)
        if failed > 0 then
            result.toast = result.toast .. string.format(' · %d failed', failed)
        end
        result.sev = (failed == 0) and 'success' or 'warning'
    end

    return result
end

undo.register_handler('mass_edit.randomize_unit_positions', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.randomize_unit_positions undo snapshot'
    end

    local verbs = require('dcs_sms_me.verbs')
    local errors = 0

    for _, r in ipairs(snapshot.rows) do
        if r.unit and type(r.old_north) == 'number'
                     and type(r.old_east) == 'number' then
            local p_ok, res = pcall(verbs.unit_set_pos, {
                id = r.unit.unitId,
                north = r.old_north,
                east = r.old_east,
            })
            if not (p_ok and type(res) == 'table' and res.ok) then
                errors = errors + 1
            end
        else
            errors = errors + 1
        end
    end

    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

local LAYOUT = {
    PAD_X      = 8,
    LABEL_W    = 58,
    UNIT_W     = 52,
    ROW_H      = 24,
    BTN_W      = 90,
    GAP_X      = 6,
    FOOTER_PAD = 6,
}

local function form_height()
    return LAYOUT.ROW_H + LAYOUT.FOOTER_PAD
end

function M.new(parent_raw, get_checked, on_after_apply, get_categories)
    if not parent_raw then return nil end

    local owned = {}
    local function add(widget)
        if widget then
            owned[#owned + 1] = widget
            pcall(parent_raw.insertWidget, parent_raw, widget)
        end
        return widget
    end

    local radius_lbl, radius_box, unit_combo, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Radius:')
        if ok and s then
            skin_helper.apply(s, 'staticSkin_ME')
            radius_lbl = add(s)
        end
    end

    if EditBox and EditBox.new then
        local ok, e = pcall(EditBox.new)
        if ok and e then
            skin_helper.apply(e, 'editBoxSkin_ME')
            radius_box = add(e)
        end
    end

    if ComboList and ComboList.new then
        local ok, c = pcall(ComboList.new)
        if ok and c then
            skin_helper.apply(c, 'comboListSkinNew_')
            unit_combo = add(c)
        end
    end

    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'sms_button')
            if b.setText then pcall(b.setText, b, 'Randomize') end
            if b.setTooltipText then
                pcall(b.setTooltipText, b,
                    'Keep the first selected unit as the anchor and randomly place all other selected units within the radius')
            end
            apply_btn = add(b)
        end
    end

    -- Unit selector: kilometres by default, miles as the alternative.
    if unit_combo and ListBoxItem and ListBoxItem.new then
        local ok_km, km = pcall(ListBoxItem.new, 'km')
        if ok_km and km then
            km._distance_unit = 'km'
            pcall(unit_combo.insertItem, unit_combo, km)
        end

        local ok_mi, mi = pcall(ListBoxItem.new, 'mi')
        if ok_mi and mi then
            mi._distance_unit = 'mi'
            pcall(unit_combo.insertItem, unit_combo, mi)
        end

        -- Select the first item (km) when the API supports it.
        if km and unit_combo.selectItem then
            pcall(unit_combo.selectItem, unit_combo, km)
        end
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local txt = (radius_box and radius_box.getText
                             and radius_box:getText()) or ''
                local radius = tonumber(txt)

                local unit = 'km'
                if unit_combo and unit_combo.getSelectedItem then
                    local item = unit_combo:getSelectedItem()
                    if item and item._distance_unit == 'mi' then
                        unit = 'mi'
                    end
                end

                local entities = (type(get_checked) == 'function')
                                 and get_checked() or {}
                local result = M._apply(entities, radius, unit)
                if type(on_after_apply) == 'function' then
                    on_after_apply(result)
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

    function panel:get_height()
        return form_height()
    end

    function panel:set_enabled(flag)
        local en = flag and true or false
        for _, w in ipairs(owned) do
            if w.setEnabled then pcall(w.setEnabled, w, en) end
        end
    end

    function panel:set_bounds(x, y, w, h)
        local L = LAYOUT
        local function set(widget, px, py, pw, ph)
            if widget and widget.setBounds then
                pcall(widget.setBounds, widget, px, py, pw, ph)
            end
        end

        -- Right-anchored Apply button. Layout:
        -- Radius | numeric input | unit combo | Randomize
        local apply_x = x + w - L.PAD_X - L.BTN_W
        local combo_x = apply_x - L.GAP_X - L.UNIT_W
        local input_x = x + L.PAD_X + L.LABEL_W + L.GAP_X
        local input_w = combo_x - L.GAP_X - input_x
        if input_w < 50 then input_w = 50 end

        set(radius_lbl,  x + L.PAD_X, y, L.LABEL_W, L.ROW_H)
        set(radius_box,  input_x,     y, input_w,   L.ROW_H)
        set(unit_combo,  combo_x,     y, L.UNIT_W,   L.ROW_H)
        set(apply_btn,   apply_x,    y, L.BTN_W,     L.ROW_H)
    end

    return panel
end

return M
