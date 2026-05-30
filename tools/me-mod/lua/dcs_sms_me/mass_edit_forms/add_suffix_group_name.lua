-- mass_edit_forms/add_suffix_group_name.lua — Mass Edit form: append a
-- literal string to every selected group's name.
--
-- Mirror of add_prefix_group_name with mass_edit_transforms.add_suffix
-- (plain concatenation onto the end). See that file for the full
-- comment header — same contract, same pcall pattern, same undo
-- approach.
--
-- Public:
--   M.scope   : 'group'
--   M.title   : 'Add suffix to group names'
--   M.new(parent_raw, get_checked, on_after_apply)
--   M._apply(entities, text, opts)
--             opts.keep_num: if true, names ending in `-<digits>` or
--                            `_<digits>` get the suffix inserted BEFORE
--                            that trailing block (so `Viper-1` + `Sfx`
--                            → `ViperSfx-1`). Default: false (plain
--                            append).
--             → { changed, failed, changed_rows, nothing_selected?,
--                 nothing_to_apply?, toast, sev }

local M = {}

M.scope = 'group'
M.title = 'Add suffix to group names'

local transforms     = require('dcs_sms_me.mass_edit_transforms')
local undo           = require('dcs_sms_me.undo')
local skin_helper    = require('dcs_sms_me.skin_helper')
local name_writer    = require('dcs_sms_me.group_name_writer')
local clearable_edit = require('dcs_sms_me.clearable_edit')

local Static;       do local ok, m = pcall(require, 'Static');       if ok then Static       = m end end
local Button;       do local ok, m = pcall(require, 'Button');       if ok then Button       = m end end
local ToggleButton; do local ok, m = pcall(require, 'ToggleButton'); if ok then ToggleButton = m end end

local function log_warn(msg) pcall(function() _G.log.write('sms.me.mass_edit.add_suffix_group_name', _G.log.WARNING or 2, msg) end) end

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------

function M._apply(entities, text, opts)
    opts = opts or {}
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
            toast = 'Suffix is empty', sev = 'warning',
        }
    end

    local changed_rows, failed = {}, 0
    for _, e in ipairs(entities) do
        local old = e.name
        local new = transforms.add_suffix(old, { text = text, keep_num = opts.keep_num == true })
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
        undo.record_generic('mass_edit.add_suffix_group_name', { rows = changed_rows })
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
        local toast = string.format('%d suffixed', #changed_rows)
        if failed > 0 then toast = toast .. string.format(' · %d failed', failed) end
        local sev = (failed == 0 and 'success') or (#changed_rows == 0 and 'error') or 'warning'
        result.toast = toast
        result.sev   = sev
    end

    return result
end

undo.register_handler('mass_edit.add_suffix_group_name', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.add_suffix_group_name undo snapshot'
    end
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        local p_ok, w_ok = pcall(name_writer.write, r.entity, r.old, { literal = true })
        if not (p_ok and w_ok) then errors = errors + 1 end
    end
    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

local LAYOUT = {
    PAD_X       = 8,
    LABEL_W     = 56,
    ROW_H       = 24,
    BTN_W       = 90,
    KEEPNUM_W   = 90,
    GAP_X       = 6,
    GAP_Y       = 4,
    FOOTER_PAD  = 6,
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

    local txt_lbl, txt_box, keep_num_btn, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Suffix:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); txt_lbl = add(s) end
    end
    txt_box = clearable_edit.new(parent_raw, {})
    if txt_box then owned[#owned + 1] = txt_box end

    if ToggleButton and ToggleButton.new then
        local ok, t = pcall(ToggleButton.new)
        if ok and t then
            skin_helper.apply(t, 'dtc_button')
            if t.setText then pcall(t.setText, t, 'Keep Num') end
            if t.setTooltipText then
                pcall(t.setTooltipText, t,
                    'When ON, names ending in -<n> or _<n> get the ' ..
                    'suffix inserted BEFORE that trailing number ' ..
                    '(e.g. "Viper-1" + "Sfx" -> "ViperSfx-1").')
            end
            -- Default ON: the keep-num-aware insert is what users want
            -- almost every time on DCS-named groups (Viper-1, etc.); the
            -- plain-append behavior is rare enough to be opt-out.
            if t.setState then pcall(t.setState, t, true) end
            keep_num_btn = add(t)
        end
    end

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
                local keep_num = (keep_num_btn and keep_num_btn.getState and keep_num_btn:getState()) == true
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local result = M._apply(entities, text, { keep_num = keep_num })
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

        -- Right-anchored: Add suffix (rightmost), Keep Num toggle to its
        -- left. Input fills the remaining width after the label and the
        -- two right-side buttons.
        local row_y    = y
        local apply_x  = x + w - L.PAD_X - L.BTN_W
        local keep_x   = apply_x - L.GAP_X - L.KEEPNUM_W
        local input_x  = x + L.PAD_X + L.LABEL_W + L.GAP_X
        local input_w  = keep_x - L.GAP_X - input_x
        if input_w < 80 then input_w = 80 end

        set(txt_lbl,      x + L.PAD_X, row_y, L.LABEL_W,    L.ROW_H)
        set(txt_box,      input_x,     row_y, input_w,      L.ROW_H)
        set(keep_num_btn, keep_x,      row_y, L.KEEPNUM_W,  L.ROW_H)
        set(apply_btn,    apply_x,     row_y, L.BTN_W,      L.ROW_H)
    end

    return panel
end

return M
