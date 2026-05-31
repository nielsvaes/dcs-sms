-- mass_edit_forms/add_prefix_unit_name.lua — Mass Edit form: prepend a
-- literal string to every checked unit's name via verbs.unit_set_name.
--
-- Self-contained, mirrors add_prefix_group_name's widget layout but
-- operates on units (u.unitId / u.name) rather than groups. Uses
-- mass_edit_transforms.add_prefix (plain concatenation; no {n} token
-- support). Verb collisions (Mission.renameUnit refusal) are counted as
-- failed.
--
-- Public:
--   M.scope   : 'unit'
--   M.title   : 'Add prefix to unit names'
--   M.new(parent_raw, get_checked, on_after_apply, get_categories)
--   M._apply(entities, args, categories)
--             → { changed, failed, not_applicable, changed_rows,
--                 nothing_selected?, toast, sev }

local M = {}

M.scope = 'unit'
M.title = 'Add prefix to unit names'
-- No M.applies_to → universal (every unit category).

local undo         = require('dcs_sms_me.undo')
local skin_helper  = require('dcs_sms_me.skin_helper')
local transforms   = require('dcs_sms_me.mass_edit_transforms')

local Static;        do local ok, m = pcall(require, 'Static');        if ok then Static        = m end end
local Button;        do local ok, m = pcall(require, 'Button');        if ok then Button        = m end end
local clearable_edit = require('dcs_sms_me.clearable_edit')

local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.mass_edit.add_prefix_unit_name', _G.log.WARNING or 2, msg) end)
end

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------

function M._apply(entities, args, categories)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, failed = 0, not_applicable = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end
    if type(args) ~= 'table' or type(args.text) ~= 'string' or args.text == '' then
        return {
            changed = 0, failed = 0, not_applicable = 0, changed_rows = {},
            toast = 'Enter a prefix', sev = 'warning',
        }
    end

    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed, not_applicable = {}, 0, 0

    for idx, u in ipairs(entities) do
        local old = u.name
        local new = transforms.add_prefix(old, { text = args.text }, idx)
        if new == old then
            -- silent skip (no count)
        else
            local p_ok, res = pcall(verbs.unit_set_name, { id = u.unitId, new_name = new })
            if not p_ok then
                failed = failed + 1
                log_warn('unit_set_name threw: ' .. tostring(res))
            elseif type(res) ~= 'table' or not res.ok then
                failed = failed + 1
                log_warn('unit_set_name failed: ' .. tostring(res and res.error or '?'))
            else
                changed_rows[#changed_rows + 1] = { unit = u, old = old }
            end
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.add_prefix_unit_name', { rows = changed_rows })
    end

    local result = {
        changed        = #changed_rows,
        failed         = failed,
        not_applicable = not_applicable,
        changed_rows   = changed_rows,
    }

    if #changed_rows == 0 and failed == 0 then
        result.toast = 'No changes'
        result.sev   = 'warning'
    else
        local toast = string.format('%d renamed', #changed_rows)
        if failed > 0 then toast = toast .. string.format(' · %d failed', failed) end
        local sev
        if failed == 0 then sev = 'success'
        elseif #changed_rows == 0 then sev = 'error'
        else sev = 'warning' end
        result.toast = toast
        result.sev   = sev
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Undo handler — restores each unit's old name via verbs.unit_set_name
-- with the OLD value. Partial failures (e.g. fresh collision) are counted
-- but don't abort the rest of the undo.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.add_prefix_unit_name', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.add_prefix_unit_name undo snapshot'
    end
    local verbs = require('dcs_sms_me.verbs')
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        local p_ok, res = pcall(verbs.unit_set_name, { id = r.unit.unitId, new_name = r.old })
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

    local txt_lbl, txt_box, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Prefix:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); txt_lbl = add(s) end
    end
    txt_box = clearable_edit.new(parent_raw, {})
    if txt_box then owned[#owned + 1] = txt_box end

    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Add') end
            apply_btn = add(b)
        end
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local text     = (txt_box and txt_box.getText and txt_box:getText()) or ''
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local cats     = (type(get_categories) == 'function') and get_categories() or {}
                local result   = M._apply(entities, { text = text }, cats)
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

        local row_y = y
        local input_x = x + L.PAD_X + L.LABEL_W + L.GAP_X
        local input_w = w - L.PAD_X * 2 - L.LABEL_W - L.GAP_X - L.BTN_W - L.GAP_X
        if input_w < 80 then input_w = 80 end
        set(txt_lbl, x + L.PAD_X, row_y, L.LABEL_W, L.ROW_H)
        set(txt_box, input_x,      row_y, input_w,  L.ROW_H)

        local btn_x = x + w - L.PAD_X - L.BTN_W
        set(apply_btn, btn_x, row_y, L.BTN_W, L.ROW_H)
    end

    return panel
end

return M
