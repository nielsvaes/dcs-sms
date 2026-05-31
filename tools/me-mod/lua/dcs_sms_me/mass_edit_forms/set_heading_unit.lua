-- mass_edit_forms/set_heading_unit.lua -- Mass Edit form: set unit
-- heading. Two-row layout with independent Absolute and Delta rows,
-- each with its own Apply button. Universal applicability (any unit
-- category can be re-headed).
--
-- Absolute row: normalizes the input to [0, 360) and forwards to
-- verbs.unit_set_heading (which converts deg -> rad and writes
-- u.heading and u.psi).
--
-- Delta row: reads each unit's current u.heading (radians), converts
-- to degrees, adds the delta, normalizes, then forwards to the same
-- verb.
--
-- Undo: per-row snapshot captures the old u.heading (radians) BEFORE
-- the verb call. The handler converts old_rad -> deg, normalizes, and
-- re-applies via verbs.unit_set_heading so any side-effects of the
-- verb (e.g. psi sync) re-run on undo too.

local M = {}

M.scope = 'unit'
M.title = 'Set heading'
-- Universal: any unit category (plane / heli / vehicle / ship / static)
-- has a heading. No M.applies_to.

local undo        = require('dcs_sms_me.undo')
local skin_helper = require('dcs_sms_me.skin_helper')

local Static;   do local ok, m = pcall(require, 'Static');   if ok then Static   = m end end
local EditBox;  do local ok, m = pcall(require, 'EditBox');  if ok then EditBox  = m end end
local Button;   do local ok, m = pcall(require, 'Button');   if ok then Button   = m end end

local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.mass_edit.set_heading_unit', _G.log.WARNING or 2, msg) end)
end

-- Normalize degrees into [0, 360). Lua's `%` on negatives returns a
-- non-negative remainder for positive divisor, but we apply the
-- "+360 then %360" idiom for clarity and parity with the spec text.
local function norm_deg(deg)
    return ((deg % 360) + 360) % 360
end

-- Seed once at module load so the Random button doesn't return the
-- same sequence each DCS session. math.random in PUC Lua 5.1 is
-- deterministic without an explicit seed.
math.randomseed(os.time())

-- ---------------------------------------------------------------------------
-- Apply: Absolute (testable; no dxgui access).
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

    for _, u in ipairs(entities) do
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

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.set_heading_unit', { rows = changed_rows })
    end

    local result = {
        changed      = #changed_rows,
        failed       = failed,
        changed_rows = changed_rows,
    }
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
-- Apply: Delta (testable; no dxgui access). Same shape as _apply_absolute
-- but the target heading is per-row: current u.heading (rad) -> deg, plus
-- the user-supplied delta, normalized into [0, 360).
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

    for _, u in ipairs(entities) do
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

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.set_heading_unit', { rows = changed_rows })
    end

    local result = {
        changed      = #changed_rows,
        failed       = failed,
        changed_rows = changed_rows,
    }
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
-- Apply: Random. Each entity gets its OWN random heading in [0, 360);
-- intentional — the typical use case is randomising a cluster's
-- orientation, where applying the same heading to all would just match
-- the Absolute path. Same row schema as Absolute/Delta so the existing
-- undo handler restores correctly.
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

    for _, u in ipairs(entities) do
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

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.set_heading_unit', { rows = changed_rows })
    end

    local result = {
        changed      = #changed_rows,
        failed       = failed,
        changed_rows = changed_rows,
    }
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

-- ---------------------------------------------------------------------------
-- Undo handler -- shared between Absolute, Delta, and Random. Each row
-- carries the old heading in RADIANS (captured before mutation); we
-- convert to degrees and re-apply via the same verb so its side effects
-- (psi sync, map redraw) fire on undo too.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.set_heading_unit', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.set_heading_unit undo snapshot'
    end
    local verbs = require('dcs_sms_me.verbs')
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        if r.unit and type(r.old_rad) == 'number' then
            local deg = math.deg(r.old_rad)
            local norm = norm_deg(deg)
            local p_ok, res = pcall(verbs.unit_set_heading,
                                    { id = r.unit.unitId, heading_deg = norm })
            if not (p_ok and type(res) == 'table' and res.ok) then errors = errors + 1 end
        else
            errors = errors + 1
        end
    end
    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

-- ---------------------------------------------------------------------------
-- Widget construction.
-- ---------------------------------------------------------------------------

local LAYOUT = {
    PAD_X      = 8,
    LABEL_W    = 56,
    UNIT_W     = 14,   -- width of the trailing "°" static
    ROW_H      = 24,
    BTN_W      = 90,
    GAP_X      = 6,
    GAP_Y      = 4,
    FOOTER_PAD = 6,
}

local function form_height()
    local L = LAYOUT
    -- Absolute row + Delta row + Random row.
    return 3 * L.ROW_H + 2 * L.GAP_Y + L.FOOTER_PAD
end

function M.new(parent_raw, get_checked, on_after_apply, get_categories)
    if not parent_raw then return nil end

    local owned = {}
    local function add(widget)
        if widget then owned[#owned + 1] = widget; pcall(parent_raw.insertWidget, parent_raw, widget) end
        return widget
    end

    local abs_lbl, abs_box, abs_unit, abs_btn
    local del_lbl, del_box, del_unit, del_btn
    local rnd_lbl, rnd_btn

    -- Row 1: Absolute
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
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Set Heading') end
            abs_btn = add(b)
        end
    end

    -- Row 2: Delta
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
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Set Heading') end
            del_btn = add(b)
        end
    end

    -- Row 3: Random — no EditBox, per-entity randomisation in [0, 360).
    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Random:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); rnd_lbl = add(s) end
    end
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Random') end
            if b.setTooltipText then
                pcall(b.setTooltipText, b, 'Each checked unit gets its own random heading (0–360°)')
            end
            rnd_btn = add(b)
        end
    end

    -- Apply (Absolute): read abs_box, tonumber, dispatch.
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

    -- Apply (Delta): read del_box, tonumber, dispatch.
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

    -- Apply (Random): no input — dispatch immediately.
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

        -- Right-anchored Apply column. Each row: label | input | ° | Apply.
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

        -- Row 3: Random — label left, button right-anchored. No input.
        local row_y_3 = row_y_2 + L.ROW_H + L.GAP_Y
        set(rnd_lbl, x + L.PAD_X, row_y_3, L.LABEL_W, L.ROW_H)
        set(rnd_btn, apply_x,     row_y_3, L.BTN_W,   L.ROW_H)
    end

    return panel
end

return M
