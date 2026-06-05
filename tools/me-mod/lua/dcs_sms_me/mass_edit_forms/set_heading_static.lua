-- mass_edit_forms/set_heading_static.lua -- static-scope mirror of
-- set_heading_unit. Statics are single-unit groups, so the checked
-- entities are GROUP refs but the verb that actually moves the icon
-- (verbs.unit_set_heading) targets the underlying unit. This form
-- walks each checked group's units[1] and forwards to the same verb.
--
-- Undo: re-uses the 'mass_edit.set_heading_unit' namespace registered
-- by set_heading_unit.lua. The row schema is identical
-- ({ unit, old_rad }) and the verb's side effects (psi sync, picModel
-- redraw) are the same for static and non-static units.

local M = {}

M.scope = 'static'
M.title = 'Set heading'

local undo        = require('dcs_sms_me.undo')
local skin_helper = require('dcs_sms_me.skin_helper')

local Static;   do local ok, m = pcall(require, 'Static');   if ok then Static   = m end end
local EditBox;  do local ok, m = pcall(require, 'EditBox');  if ok then EditBox  = m end end
local Button;   do local ok, m = pcall(require, 'Button');   if ok then Button   = m end end

local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.mass_edit.set_heading_static', _G.log.WARNING or 2, msg) end)
end

local function norm_deg(deg)
    return ((deg % 360) + 360) % 360
end

-- Resolve checked group → its single unit. Static groups always carry
-- exactly one unit; if a malformed entity has none, skip it (counted
-- toward `failed`).
local function unit_of(g)
    return type(g) == 'table' and type(g.units) == 'table' and g.units[1] or nil
end

-- ---------------------------------------------------------------------------
-- Apply: Absolute.
-- ---------------------------------------------------------------------------

function M._apply_absolute(entities, deg)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, failed = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end
    if type(deg) ~= 'number' then
        return {
            changed = 0, failed = 0, changed_rows = {},
            toast = 'Enter heading (°)', sev = 'warning',
        }
    end

    local norm = norm_deg(deg)
    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed = {}, 0

    for _, g in ipairs(entities) do
        local u = unit_of(g)
        if not u then
            failed = failed + 1
        else
            local old_rad = tonumber(u.heading) or 0
            local p_ok, res = pcall(verbs.unit_set_heading, { id = u.unitId, heading_deg = norm })
            if not p_ok then
                failed = failed + 1
                log_warn('unit_set_heading threw: ' .. tostring(res))
            elseif type(res) ~= 'table' or not res.ok then
                failed = failed + 1
                log_warn('unit_set_heading failed: ' .. tostring(res and res.error or '?'))
            else
                changed_rows[#changed_rows + 1] = { unit = u, old_rad = old_rad }
            end
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.set_heading_unit', { rows = changed_rows })
    end

    local result = { changed = #changed_rows, failed = failed, changed_rows = changed_rows }
    if #changed_rows == 0 and failed > 0 then
        result.toast = string.format('0 heading set · %d failed', failed)
        result.sev   = 'error'
    elseif #changed_rows == 0 then
        result.toast = 'No changes'
        result.sev   = 'warning'
    else
        result.toast = string.format('%d heading set%s', #changed_rows,
                                     failed > 0 and (' · ' .. failed .. ' failed') or '')
        result.sev   = (failed == 0 and 'success') or 'warning'
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Apply: Delta. Per-entity old heading + user delta, normalised.
-- ---------------------------------------------------------------------------

function M._apply_delta(entities, delta_deg)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, failed = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end
    if type(delta_deg) ~= 'number' then
        return {
            changed = 0, failed = 0, changed_rows = {},
            toast = 'Enter delta (°)', sev = 'warning',
        }
    end

    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed = {}, 0

    for _, g in ipairs(entities) do
        local u = unit_of(g)
        if not u then
            failed = failed + 1
        else
            local old_rad = tonumber(u.heading) or 0
            local target_deg = math.deg(old_rad) + delta_deg
            local norm = norm_deg(target_deg)
            local p_ok, res = pcall(verbs.unit_set_heading, { id = u.unitId, heading_deg = norm })
            if not p_ok then
                failed = failed + 1
                log_warn('unit_set_heading threw: ' .. tostring(res))
            elseif type(res) ~= 'table' or not res.ok then
                failed = failed + 1
                log_warn('unit_set_heading failed: ' .. tostring(res and res.error or '?'))
            else
                changed_rows[#changed_rows + 1] = { unit = u, old_rad = old_rad }
            end
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.set_heading_unit', { rows = changed_rows })
    end

    local result = { changed = #changed_rows, failed = failed, changed_rows = changed_rows }
    if #changed_rows == 0 and failed > 0 then
        result.toast = string.format('0 heading set · %d failed', failed)
        result.sev   = 'error'
    elseif #changed_rows == 0 then
        result.toast = 'No changes'
        result.sev   = 'warning'
    else
        result.toast = string.format('%d heading set%s', #changed_rows,
                                     failed > 0 and (' · ' .. failed .. ' failed') or '')
        result.sev   = (failed == 0 and 'success') or 'warning'
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Apply: Random. Each entity gets its own value in [0, 360).
-- ---------------------------------------------------------------------------

function M._apply_random(entities)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, failed = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end

    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed = {}, 0

    for _, g in ipairs(entities) do
        local u = unit_of(g)
        if not u then
            failed = failed + 1
        else
            local old_rad = tonumber(u.heading) or 0
            local norm = math.random() * 360
            local p_ok, res = pcall(verbs.unit_set_heading, { id = u.unitId, heading_deg = norm })
            if not p_ok then
                failed = failed + 1
                log_warn('unit_set_heading threw: ' .. tostring(res))
            elseif type(res) ~= 'table' or not res.ok then
                failed = failed + 1
                log_warn('unit_set_heading failed: ' .. tostring(res and res.error or '?'))
            else
                changed_rows[#changed_rows + 1] = { unit = u, old_rad = old_rad }
            end
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.set_heading_unit', { rows = changed_rows })
    end

    local result = { changed = #changed_rows, failed = failed, changed_rows = changed_rows }
    if #changed_rows == 0 and failed > 0 then
        result.toast = string.format('0 heading set · %d failed', failed)
        result.sev   = 'error'
    elseif #changed_rows == 0 then
        result.toast = 'No changes'
        result.sev   = 'warning'
    else
        result.toast = string.format('%d randomised%s', #changed_rows,
                                     failed > 0 and (' · ' .. failed .. ' failed') or '')
        result.sev   = (failed == 0 and 'success') or 'warning'
    end
    return result
end

-- Undo handler is registered by set_heading_unit.lua under
-- 'mass_edit.set_heading_unit'. We share that namespace because the
-- row schema and the restore action (re-call verbs.unit_set_heading
-- with old_rad → deg) are identical for both forms.

-- ---------------------------------------------------------------------------
-- Widget construction.
-- ---------------------------------------------------------------------------

local LAYOUT = {
    PAD_X      = 8,
    LABEL_W    = 56,
    UNIT_W     = 14,
    ROW_H      = 24,
    BTN_W      = 90,
    GAP_X      = 6,
    GAP_Y      = 4,
    FOOTER_PAD = 6,
}

local function form_height()
    local L = LAYOUT
    return 3 * L.ROW_H + 2 * L.GAP_Y + L.FOOTER_PAD
end

function M.new(parent_raw, get_checked, on_after_apply, _get_categories)
    if not parent_raw then return nil end

    local owned = {}
    local function add(widget)
        if widget then owned[#owned + 1] = widget; pcall(parent_raw.insertWidget, parent_raw, widget) end
        return widget
    end

    local abs_lbl, abs_box, abs_unit, abs_btn
    local del_lbl, del_box, del_unit, del_btn
    local rnd_lbl, rnd_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Absolute:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); abs_lbl = add(s) end
    end
    if EditBox and EditBox.new then
        local ok, e = pcall(EditBox.new)
        if ok and e then skin_helper.apply(e, 'editBoxSkin_ME'); abs_box = add(e) end
    end
    if Static and Static.new then
        local ok, s = pcall(Static.new, '°')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); abs_unit = add(s) end
    end
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'sms_button')
            if b.setText then pcall(b.setText, b, 'Set Heading') end
            abs_btn = add(b)
        end
    end

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Delta:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); del_lbl = add(s) end
    end
    if EditBox and EditBox.new then
        local ok, e = pcall(EditBox.new)
        if ok and e then skin_helper.apply(e, 'editBoxSkin_ME'); del_box = add(e) end
    end
    if Static and Static.new then
        local ok, s = pcall(Static.new, '°')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); del_unit = add(s) end
    end
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'sms_button')
            if b.setText then pcall(b.setText, b, 'Set Heading') end
            del_btn = add(b)
        end
    end

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Random:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); rnd_lbl = add(s) end
    end
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'sms_button')
            if b.setText then pcall(b.setText, b, 'Random') end
            if b.setTooltipText then
                pcall(b.setTooltipText, b, 'Each checked static gets its own random heading (0–360°)')
            end
            rnd_btn = add(b)
        end
    end

    if abs_btn and abs_btn.addMouseDownCallback then
        pcall(abs_btn.addMouseDownCallback, abs_btn, function()
            pcall(function()
                local txt = (abs_box and abs_box.getText and abs_box:getText()) or ''
                local deg = tonumber(txt)
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local result = M._apply_absolute(entities, deg)
                if type(on_after_apply) == 'function' then on_after_apply(result) end
            end)
        end)
    end

    if del_btn and del_btn.addMouseDownCallback then
        pcall(del_btn.addMouseDownCallback, del_btn, function()
            pcall(function()
                local txt = (del_box and del_box.getText and del_box:getText()) or ''
                local delta = tonumber(txt)
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local result = M._apply_delta(entities, delta)
                if type(on_after_apply) == 'function' then on_after_apply(result) end
            end)
        end)
    end

    if rnd_btn and rnd_btn.addMouseDownCallback then
        pcall(rnd_btn.addMouseDownCallback, rnd_btn, function()
            pcall(function()
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local result = M._apply_random(entities)
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

        local apply_x = x + w - L.PAD_X - L.BTN_W
        local unit_x  = apply_x - L.GAP_X - L.UNIT_W
        local input_x = x + L.PAD_X + L.LABEL_W + L.GAP_X
        local input_w = unit_x - L.GAP_X - input_x
        if input_w < 60 then input_w = 60 end

        local row_y_1 = y
        set(abs_lbl,  x + L.PAD_X, row_y_1, L.LABEL_W, L.ROW_H)
        set(abs_box,  input_x,     row_y_1, input_w,   L.ROW_H)
        set(abs_unit, unit_x,      row_y_1, L.UNIT_W,  L.ROW_H)
        set(abs_btn,  apply_x,     row_y_1, L.BTN_W,   L.ROW_H)

        local row_y_2 = row_y_1 + L.ROW_H + L.GAP_Y
        set(del_lbl,  x + L.PAD_X, row_y_2, L.LABEL_W, L.ROW_H)
        set(del_box,  input_x,     row_y_2, input_w,   L.ROW_H)
        set(del_unit, unit_x,      row_y_2, L.UNIT_W,  L.ROW_H)
        set(del_btn,  apply_x,     row_y_2, L.BTN_W,   L.ROW_H)

        local row_y_3 = row_y_2 + L.ROW_H + L.GAP_Y
        set(rnd_lbl, x + L.PAD_X, row_y_3, L.LABEL_W, L.ROW_H)
        set(rnd_btn, apply_x,     row_y_3, L.BTN_W,   L.ROW_H)
    end

    return panel
end

return M
