-- mass_edit_forms/rename_group.lua — Mass Edit form: rename groups via a
-- pattern (with optional {n} token for sequence numbering).
--
-- Self-contained, same contract as find_replace_group_name.lua. Single
-- text input + button. Uses mass_edit_transforms.auto_number with hardcoded
-- {start=1, step=1, pad=2, order=name_asc}. Entities are sorted by current
-- name before the transform is applied so numbering is deterministic.
--
-- Public:
--   M.scope     : 'group'
--   M.title     : 'Rename groups'
--   M.new(parent_raw, get_checked, on_after_apply)
--   M._apply(entities, pattern)
--               → { changed, failed, changed_rows, nothing_selected?, toast, sev }

local M = {}

M.scope = 'group'
M.title = 'Rename groups'

local transforms  = require('dcs_sms_me.mass_edit_transforms')
local undo        = require('dcs_sms_me.undo')
local skin_helper = require('dcs_sms_me.skin_helper')
local name_writer = require('dcs_sms_me.group_name_writer')

local Static;   do local ok, m = pcall(require, 'Static');   if ok then Static   = m end end
local EditBox;  do local ok, m = pcall(require, 'EditBox');  if ok then EditBox  = m end end
local Button;   do local ok, m = pcall(require, 'Button');   if ok then Button   = m end end

local function log_warn(msg) pcall(function() _G.log.write('sms.me.mass_edit.rename_group', _G.log.WARNING or 2, msg) end) end

function M._apply(entities, pattern)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, failed = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end
    if type(pattern) ~= 'string' or pattern == '' then
        return {
            changed = 0, failed = 0, changed_rows = {},
            toast = 'Name is empty', sev = 'warning',
        }
    end

    -- Sort entities by current name (name_asc) so numbering is deterministic
    -- regardless of the left pane's current sort or the check order.
    local sorted = {}
    for _, e in ipairs(entities) do sorted[#sorted + 1] = e end
    table.sort(sorted, function(a, b)
        return tostring(a.name or '') < tostring(b.name or '')
    end)

    local args = { pattern = pattern, start = 1, step = 1, pad = 2, order = 'name_asc' }
    local changed_rows, failed, unchanged = {}, 0, 0
    for idx, e in ipairs(sorted) do
        local old = e.name
        local new = transforms.auto_number(old, args, idx)
        if new ~= old then
            local p_ok, w_ok, _actual, w_err = pcall(name_writer.write, e, new)
            if p_ok and w_ok then
                changed_rows[#changed_rows + 1] = { entity = e, old = old }
            else
                failed = failed + 1
                log_warn('name_writer.write failed: ' .. tostring(p_ok and w_err or w_ok))
            end
        else
            -- Row already matched the target name — no work to do but also
            -- not a "no changes" situation when other rows are mutating.
            unchanged = unchanged + 1
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.rename_group', { rows = changed_rows })
    end

    local result = {
        changed      = #changed_rows,
        failed       = failed,
        unchanged    = unchanged,
        changed_rows = changed_rows,
    }
    if #changed_rows == 0 and failed == 0 and unchanged == 0 then
        result.toast = 'No changes'
        result.sev   = 'warning'
    elseif #changed_rows == 0 and failed == 0 then
        -- All rows already at the target name.
        result.toast = string.format('Already named that (%d unchanged)', unchanged)
        result.sev   = 'info'
    else
        local toast = string.format('%d renamed', #changed_rows)
        if unchanged > 0 then toast = toast .. string.format(' · %d unchanged', unchanged) end
        if failed > 0    then toast = toast .. string.format(' · %d failed',    failed)    end
        local sev = (failed == 0 and 'success') or (#changed_rows == 0 and 'error') or 'warning'
        result.toast = toast
        result.sev   = sev
    end
    return result
end

undo.register_handler('mass_edit.rename_group', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.rename_group undo snapshot'
    end
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        local p_ok, w_ok = pcall(name_writer.write, r.entity, r.old, { literal = true })
        if not (p_ok and w_ok) then errors = errors + 1 end
    end
    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

local LAYOUT = {
    PAD_X      = 8,
    -- Matches find_replace / add_prefix / add_suffix so the input
    -- column lines up across all four single-input forms.
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

    local pat_lbl, pat_box, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Name:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); pat_lbl = add(s) end
    end
    if EditBox and EditBox.new then
        local ok, e = pcall(EditBox.new)
        if ok and e then skin_helper.apply(e, 'editBoxSkin_ME'); pat_box = add(e) end
    end

    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Rename') end
            if b.setTooltipText then
                pcall(b.setTooltipText, b, 'Use {n} for sequence, e.g. "Foo-{n}"')
            end
            apply_btn = add(b)
        end
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local pattern  = (pat_box and pat_box.getText and pat_box:getText()) or ''
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local result = M._apply(entities, pattern)
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

    function panel:set_bounds(x, y, w, h)
        local L = LAYOUT
        local function set(widget, px, py, pw, ph)
            if widget and widget.setBounds then pcall(widget.setBounds, widget, px, py, pw, ph) end
        end

        local row_y = y
        local input_x = x + L.PAD_X + L.LABEL_W + L.GAP_X
        local input_w = w - L.PAD_X * 2 - L.LABEL_W - L.GAP_X - L.BTN_W - L.GAP_X
        if input_w < 80 then input_w = 80 end
        set(pat_lbl, x + L.PAD_X, row_y, L.LABEL_W, L.ROW_H)
        set(pat_box, input_x,      row_y, input_w,  L.ROW_H)

        local btn_x = x + w - L.PAD_X - L.BTN_W
        set(apply_btn, btn_x, row_y, L.BTN_W, L.ROW_H)
    end

    return panel
end

return M
