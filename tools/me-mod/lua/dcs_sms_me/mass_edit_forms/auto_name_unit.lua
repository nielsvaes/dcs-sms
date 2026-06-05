-- mass_edit_forms/auto_name_unit.lua — Mass Edit form: auto-name every
-- checked unit to "<base>-<n>" using a single running counter across the
-- whole checked set, in treeview order.
--
-- One Base EditBox + one Start-at EditBox + Apply button. The counter
-- starts at args.start (default 1) and increments once per checked unit
-- regardless of group boundaries — distinct from the group-scope
-- auto_name_units_group form which resets per group.
--
-- Writes via verbs.unit_set_name. Collisions (Mission.renameUnit refusal)
-- are counted as `failed`; rows that already match the auto-generated
-- name are silently skipped (no count) to mirror the rename / find-replace
-- precedent.
--
-- Public:
--   M.scope   : 'unit'
--   M.title   : 'Auto-name units'
--   M.new(parent_raw, get_checked, on_after_apply, get_categories)
--   M._apply(entities, args, categories)
--             → { changed, failed, not_applicable, changed_rows,
--                 nothing_selected?, toast, sev }

local M = {}
M.scope = 'unit'
M.title = 'Auto-name units'
-- No M.applies_to — universal across categories.

local undo        = require('dcs_sms_me.undo')
local skin_helper = require('dcs_sms_me.skin_helper')
local transforms  = require('dcs_sms_me.mass_edit_transforms')

local Static;       do local ok, m = pcall(require, 'Static');       if ok then Static       = m end end
local EditBox;      do local ok, m = pcall(require, 'EditBox');      if ok then EditBox      = m end end
local Button;       do local ok, m = pcall(require, 'Button');       if ok then Button       = m end end

local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.mass_edit.auto_name_unit', _G.log.WARNING or 2, msg) end)
end

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------

function M._apply(entities, args, categories)
    if type(entities) ~= 'table' or #entities == 0 then
        return { changed = 0, failed = 0, not_applicable = 0, changed_rows = {},
                 nothing_selected = true,
                 toast = 'Nothing selected', sev = 'warning' }
    end
    if type(args) ~= 'table' or type(args.base) ~= 'string' or args.base == '' then
        return { changed = 0, failed = 0, not_applicable = 0, changed_rows = {},
                 toast = 'Enter a base name', sev = 'warning' }
    end

    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed = {}, 0
    local start = tonumber(args.start) or 1

    -- Single counter across the whole checked set; entities is already in
    -- treeview order from get_checked(), so the loop's `idx` is the apply
    -- order directly.
    for idx, u in ipairs(entities) do
        local old = u.name
        local new = transforms.auto_number(old,
            { pattern = args.base .. '-{n}', start = start, step = 1, pad = 1 }, idx)
        if new == old then
            -- Silent skip — already matches the auto-generated name.
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
        undo.record_generic('mass_edit.auto_name_unit', { rows = changed_rows })
    end

    local result = {
        changed        = #changed_rows,
        failed         = failed,
        not_applicable = 0,
        changed_rows   = changed_rows,
    }

    if #changed_rows == 0 and failed == 0 then
        result.toast = 'No changes'
        result.sev   = 'warning'
    else
        local toast = string.format('%d renamed', #changed_rows)
        if failed > 0 then toast = toast .. string.format(' · %d failed', failed) end
        result.toast = toast
        result.sev   = (failed == 0 and 'success')
                    or (#changed_rows == 0 and 'error')
                    or 'warning'
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Undo handler — restores each unit's old name via verbs.unit_set_name.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.auto_name_unit', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.auto_name_unit undo snapshot'
    end
    local verbs = require('dcs_sms_me.verbs')
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        if r.unit and r.old then
            local p_ok, res = pcall(verbs.unit_set_name, { id = r.unit.unitId, new_name = r.old })
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
    PAD_X       = 8,
    LABEL_W     = 56,
    START_LBL_W = 56,    -- 'Start at:' label width
    START_IN_W  = 48,    -- numeric start-at EditBox width
    ROW_H       = 24,
    BTN_W       = 90,
    GAP_X       = 6,
    GAP_Y       = 4,
    FOOTER_PAD  = 6,
}

local function form_height()
    return LAYOUT.ROW_H + LAYOUT.FOOTER_PAD
end

function M.new(parent_raw, get_checked, on_after_apply, get_categories)
    if not parent_raw then return nil end

    local owned = {}
    local function add(widget)
        if widget then owned[#owned + 1] = widget; pcall(parent_raw.insertWidget, parent_raw, widget) end
        return widget
    end

    local base_lbl, base_input, start_lbl, start_input, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Base:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); base_lbl = add(s) end
    end
    if EditBox and EditBox.new then
        local ok, e = pcall(EditBox.new)
        if ok and e then skin_helper.apply(e, 'editBoxSkin_ME'); base_input = add(e) end
    end
    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Start at:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); start_lbl = add(s) end
    end
    if EditBox and EditBox.new then
        local ok, e = pcall(EditBox.new)
        if ok and e then
            skin_helper.apply(e, 'editBoxSkin_ME')
            if e.setText then pcall(e.setText, e, '1') end
            start_input = add(e)
        end
    end
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'sms_button')
            if b.setText then pcall(b.setText, b, 'Auto-name') end
            apply_btn = add(b)
        end
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local base = ''
                if base_input and base_input.getText then
                    base = base_input:getText() or ''
                end
                local start_txt = ''
                if start_input and start_input.getText then
                    start_txt = start_input:getText() or ''
                end
                local start = tonumber(start_txt) or 1
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local cats     = (type(get_categories) == 'function') and get_categories() or {}
                local result = M._apply(entities, { base = base, start = start }, cats)
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
        for _, w in ipairs(owned) do if w.setEnabled then pcall(w.setEnabled, w, en) end end
    end

    function panel:set_bounds(x, y, w, h)
        local L = LAYOUT
        local function set(widget, px, py, pw, ph)
            if widget and widget.setBounds then pcall(widget.setBounds, widget, px, py, pw, ph) end
        end

        local row_y = y

        -- Right-anchored: Apply (rightmost), then Start-at EditBox + label
        -- to its left. Base EditBox fills the remaining row between the
        -- Base: label and the Start at: label.
        local apply_x   = x + w - L.PAD_X - L.BTN_W
        local start_x   = apply_x - L.GAP_X - L.START_IN_W
        local start_lx  = start_x - L.GAP_X - L.START_LBL_W
        local base_in_x = x + L.PAD_X + L.LABEL_W + L.GAP_X
        local base_in_w = start_lx - L.GAP_X - base_in_x
        if base_in_w < 80 then base_in_w = 80 end

        set(base_lbl,    x + L.PAD_X, row_y, L.LABEL_W,     L.ROW_H)
        set(base_input,  base_in_x,   row_y, base_in_w,     L.ROW_H)
        set(start_lbl,   start_lx,    row_y, L.START_LBL_W, L.ROW_H)
        set(start_input, start_x,     row_y, L.START_IN_W,  L.ROW_H)
        set(apply_btn,   apply_x,     row_y, L.BTN_W,       L.ROW_H)
    end

    return panel
end

return M
