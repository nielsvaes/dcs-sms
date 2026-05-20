-- mass_edit_forms/auto_name_units_group.lua — Mass Edit form: auto-
-- name every unit in each checked group, using the group's own name
-- as the prefix and a 1-based index suffix.
--
-- For a group named "Viper-1" with two units, the units become
-- "Viper-1-1" and "Viper-1-2" regardless of what they were called
-- before. Useful after a mass rename / prefix / suffix to keep unit
-- names in sync with the group name.
--
-- Writes via Mission.renameUnit (the ME's collision-checked unit
-- rename). On collision Mission.renameUnit returns false; we count
-- it as a failure but keep going so one bad rename doesn't abort the
-- batch.
--
-- Public:
--   M.scope   : 'group'
--   M.title   : 'Auto-name units'
--   M.new(parent_raw, get_checked, on_after_apply)
--   M._apply(entities)
--             → { changed, failed, changed_rows, nothing_selected?,
--                 toast, sev }

local M = {}

M.scope = 'group'
M.title = 'Auto-name units'

local undo        = require('dcs_sms_me.undo')
local skin_helper = require('dcs_sms_me.skin_helper')

local Static; do local ok, m = pcall(require, 'Static'); if ok then Static = m end end
local Button; do local ok, m = pcall(require, 'Button'); if ok then Button = m end end

local function log_warn(msg) pcall(function() _G.log.write('sms.me.mass_edit.auto_name_units_group', _G.log.WARNING or 2, msg) end) end

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------

function M._apply(entities)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, failed = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end

    local Mission = require('me_mission')
    local changed_rows, failed = {}, 0

    for _, g in ipairs(entities) do
        local base = tostring(g and g.name or '')
        if base ~= '' and type(g) == 'table' and type(g.units) == 'table' then
            for idx, u in ipairs(g.units) do
                local old = u.name
                local new = base .. '-' .. tostring(idx)
                if new ~= old then
                    local p_ok, rename_ok = pcall(Mission.renameUnit, u, new)
                    if p_ok and rename_ok then
                        changed_rows[#changed_rows + 1] = { unit = u, old = old }
                    else
                        failed = failed + 1
                        log_warn('renameUnit failed: '
                            .. tostring((not p_ok and rename_ok) or 'name "' .. new .. '" in use'))
                    end
                end
            end
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.auto_name_units_group', { rows = changed_rows })
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
        local toast = string.format('%d units renamed', #changed_rows)
        if failed > 0 then toast = toast .. string.format(' · %d failed', failed) end
        result.toast = toast
        result.sev   = (failed == 0 and 'success')
                    or (#changed_rows == 0 and 'error')
                    or 'warning'
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Undo handler — restores each unit's old name via Mission.renameUnit.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.auto_name_units_group', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.auto_name_units_group undo snapshot'
    end
    local Mission = require('me_mission')
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        local p_ok, ok = pcall(Mission.renameUnit, r.unit, r.old)
        if not (p_ok and ok) then errors = errors + 1 end
    end
    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

-- ---------------------------------------------------------------------------
-- Widget construction.
-- ---------------------------------------------------------------------------

local LAYOUT = {
    PAD_X      = 8,
    ROW_H      = 24,
    -- Wider than the standard 90 because "Auto name units" is a long
    -- label. The right edge still aligns with the other forms' Apply
    -- buttons (right-anchored via x + w - PAD_X - BTN_W).
    BTN_W      = 130,
    FOOTER_PAD = 6,
}

local function form_height()
    return LAYOUT.ROW_H + LAYOUT.FOOTER_PAD
end

function M.new(parent_raw, get_checked, on_after_apply)
    if not parent_raw then return nil end

    local owned = {}
    local function add(widget)
        if widget then owned[#owned + 1] = widget; pcall(parent_raw.insertWidget, parent_raw, widget) end
        return widget
    end

    local apply_btn
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Auto name units') end
            if b.setTooltipText then
                pcall(b.setTooltipText, b,
                    'Renames every unit in each checked group to ' ..
                    '"<groupname>-<idx>" (e.g. group "Viper-1" with two ' ..
                    'units becomes "Viper-1-1" / "Viper-1-2").')
            end
            apply_btn = add(b)
        end
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local result = M._apply(entities)
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
        local btn_x = x + w - L.PAD_X - L.BTN_W
        if apply_btn and apply_btn.setBounds then
            pcall(apply_btn.setBounds, apply_btn, btn_x, y, L.BTN_W, L.ROW_H)
        end
    end

    return panel
end

return M
