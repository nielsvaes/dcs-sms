-- mass_edit_forms/add_prefix_group_name.lua — Mass Edit form: prepend
-- a literal string to every selected group's name.
--
-- Self-contained, mirrors rename_group / find_replace_group_name. Single
-- text input + Add prefix button. Uses mass_edit_transforms.add_prefix
-- (plain concatenation, no {n} token support — use rename_group for
-- numbered patterns). Writes through group_name_writer.write so DCS's
-- check_group_name handles collisions (Foo + Foo → Foo, Foo-1).
--
-- Public:
--   M.scope   : 'group'
--   M.title   : 'Add prefix to group names'
--   M.new(parent_raw, get_checked, on_after_apply)
--   M._apply(entities, text)
--             → { changed, failed, changed_rows, nothing_selected?,
--                 nothing_to_apply?, toast, sev }

local M = {}

M.scope = 'group'
M.title = 'Add prefix to group names'

local transforms     = require('dcs_sms_me.mass_edit_transforms')
local undo           = require('dcs_sms_me.undo')
local skin_helper    = require('dcs_sms_me.skin_helper')
local name_writer    = require('dcs_sms_me.group_name_writer')
local clearable_edit = require('dcs_sms_me.clearable_edit')

local Static;   do local ok, m = pcall(require, 'Static');   if ok then Static   = m end end
local Button;   do local ok, m = pcall(require, 'Button');   if ok then Button   = m end end

local function log_warn(msg) pcall(function() _G.log.write('sms.me.mass_edit.add_prefix_group_name', _G.log.WARNING or 2, msg) end) end

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------

function M._apply(entities, text)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, failed = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end
    if type(text) ~= 'string' or text == '' then
        return {
            changed = 0, failed = 0, changed_rows = {},
            nothing_to_apply = true,
            toast = 'Text is empty', sev = 'warning',
        }
    end

    local changed_rows, failed = {}, 0
    for _, e in ipairs(entities) do
        local old = e.name
        local new = transforms.add_prefix(old, { text = text })
        if new ~= old then
            local p_ok, w_ok, _actual, w_err = pcall(name_writer.write, e, new)
            if p_ok and w_ok then
                changed_rows[#changed_rows + 1] = { entity = e, old = old }
            else
                failed = failed + 1
                log_warn('name_writer.write failed: ' .. tostring(p_ok and w_err or w_ok))
            end
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.add_prefix_group_name', { rows = changed_rows })
    end

    local result = {
        changed      = #changed_rows,
        failed       = failed,
        changed_rows = changed_rows,
    }

    if #changed_rows == 0 and failed == 0 then
        result.toast = 'No changes'
        result.sev   = 'warning'
    else
        local toast = string.format('%d prefixed', #changed_rows)
        if failed > 0 then toast = toast .. string.format(' · %d failed', failed) end
        local sev = (failed == 0 and 'success') or (#changed_rows == 0 and 'error') or 'warning'
        result.toast = toast
        result.sev   = sev
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Undo handler — restores names via name_writer with {literal=true} so
-- the restore doesn't itself collide and produce Foo-1 when the user is
-- owed Foo.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.add_prefix_group_name', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.add_prefix_group_name undo snapshot'
    end
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        local p_ok, w_ok = pcall(name_writer.write, r.entity, r.old, { literal = true })
        if not (p_ok and w_ok) then errors = errors + 1 end
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

function M.new(parent_raw, get_checked, on_after_apply)
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
            skin_helper.apply(b, 'sms_button')
            if b.setText then pcall(b.setText, b, 'Add') end
            apply_btn = add(b)
        end
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local text     = (txt_box and txt_box.getText and txt_box:getText()) or ''
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local result = M._apply(entities, text)
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
