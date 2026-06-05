-- mass_edit_forms/set_onboard_num_unit.lua -- Mass Edit form: set
-- u.onboard_num on every checked plane via verbs.unit_set_onboard_num.
--
-- Planes only. Tanks / ships / static / helicopters are silently
-- skipped via M.applies_to = { plane = true }; the host's
-- recompute_form_gating grays the form when zero planes are checked,
-- and _apply counts inapplicable rows toward `not_applicable` and
-- reports them in the toast.
--
-- Two action modes share one undo handler:
--   * Apply (sequential)  -- _apply_sequential(entities, start_str, cats)
--     EditBox text is the starting number; padding inferred from input
--     width ('010' -> 3 digits, '5' -> no padding). Per applicable row
--     at the 1-based applicable-only index, n = start + (idx - 1) and
--     the verb is called with string.format('%0<pad>d', n).
--   * Random              -- _apply_random(entities, cats)
--     Generates unique 3-digit '001'..'999' values across the checked
--     applicable set (a `taken` map enforces uniqueness; if all 999
--     values are exhausted in a giant batch, the loop bails after
--     1000 attempts and falls through with a duplicate -- pragmatic).
--
-- Undo uses the verb in reverse. unit_set_onboard_num refuses empty
-- strings, so if the captured old value was nil/empty (the unit had
-- no prior onboard_num) we restore as '0' instead of crashing. This
-- is a pragmatic compromise; rare in practice.

local M = {}

M.scope = 'unit'
M.title = 'Set onboard #'
M.applies_to = { plane = true }

local undo          = require('dcs_sms_me.undo')
local skin_helper   = require('dcs_sms_me.skin_helper')
local applicability = require('dcs_sms_me.applicability')

local Static;  do local ok, m = pcall(require, 'Static');  if ok then Static  = m end end
local EditBox; do local ok, m = pcall(require, 'EditBox'); if ok then EditBox = m end end
local Button;  do local ok, m = pcall(require, 'Button');  if ok then Button  = m end end

local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.mass_edit.set_onboard_num_unit', _G.log.WARNING or 2, msg) end)
end

-- ---------------------------------------------------------------------------
-- Shared result helpers
-- ---------------------------------------------------------------------------

local function nothing_selected_result()
    return {
        changed = 0, failed = 0, not_applicable = 0, changed_rows = {},
        nothing_selected = true,
        toast = 'Nothing selected', sev = 'warning',
    }
end

local function build_toast(changed, failed, not_applicable)
    if changed == 0 and failed == 0 and not_applicable > 0 then
        return 'Nothing applicable', 'warning'
    end
    if changed == 0 and failed > 0 then
        local t = string.format('0 onboard # set · %d failed', failed)
        if not_applicable > 0 then t = t .. string.format(' · %d not applicable', not_applicable) end
        return t, 'error'
    end
    local t = string.format('%d onboard # set', changed)
    if not_applicable > 0 then t = t .. string.format(' · %d not applicable', not_applicable) end
    if failed > 0          then t = t .. string.format(' · %d failed',         failed)         end
    local sev = (failed == 0) and 'success' or 'warning'
    return t, sev
end

local function record_undo(changed_rows)
    if #changed_rows > 0 then
        undo.record_generic('mass_edit.set_onboard_num_unit', { rows = changed_rows })
    end
end

-- Classify the verb's response. Returns true on success (and appends to
-- changed_rows), or false on rejection / throw (and bumps failed).
local function call_verb_and_record(verbs, u, new_str, changed_rows)
    local p_ok, res = pcall(verbs.unit_set_onboard_num,
                            { id = u.unitId, onboard_num = new_str })
    if not p_ok then
        log_warn('unit_set_onboard_num threw: ' .. tostring(res))
        return false
    end
    if type(res) ~= 'table' or not res.ok then
        log_warn('unit_set_onboard_num failed: ' .. tostring(res and res.error or '?'))
        return false
    end
    changed_rows[#changed_rows + 1] = {
        unit = u,
        old  = u.onboard_num,  -- captured AFTER the verb -- the verb only
                               -- updates the field on success, but u was
                               -- mutated in-place; copy the value first below.
    }
    return true
end

-- ---------------------------------------------------------------------------
-- _apply_sequential -- testable; no dxgui access.
-- ---------------------------------------------------------------------------

function M._apply_sequential(entities, start_str, categories)
    if type(entities) ~= 'table' or #entities == 0 then
        return nothing_selected_result()
    end
    if type(start_str) ~= 'string' or start_str == '' or tonumber(start_str) == nil then
        return {
            changed = 0, failed = 0, not_applicable = 0, changed_rows = {},
            toast = 'Enter a number', sev = 'warning',
        }
    end

    local verbs = require('dcs_sms_me.verbs')
    local start_n = tonumber(start_str)
    local pad     = #start_str
    local fmt     = '%0' .. pad .. 'd'

    local changed_rows, failed, not_applicable = {}, 0, 0
    local applicable_idx = 0

    for _, u in ipairs(entities) do
        if not applicability.is_applicable(M.applies_to, u, categories) then
            not_applicable = not_applicable + 1
        else
            applicable_idx = applicable_idx + 1
            local n = start_n + (applicable_idx - 1)
            local new_str = string.format(fmt, n)

            -- Capture old BEFORE the verb mutates u.onboard_num.
            local old_val = u.onboard_num
            local p_ok, res = pcall(verbs.unit_set_onboard_num,
                                    { id = u.unitId, onboard_num = new_str })
            if not p_ok then
                failed = failed + 1
                log_warn('unit_set_onboard_num threw: ' .. tostring(res))
            elseif type(res) ~= 'table' or not res.ok then
                failed = failed + 1
                log_warn('unit_set_onboard_num failed: ' .. tostring(res and res.error or '?'))
            else
                changed_rows[#changed_rows + 1] = { unit = u, old = old_val }
            end
        end
    end

    record_undo(changed_rows)

    local toast, sev = build_toast(#changed_rows, failed, not_applicable)
    return {
        changed        = #changed_rows,
        failed         = failed,
        not_applicable = not_applicable,
        changed_rows   = changed_rows,
        toast          = toast,
        sev            = sev,
    }
end

-- ---------------------------------------------------------------------------
-- _apply_random -- testable; no dxgui access. Generates unique 3-digit
-- random strings ('001'..'999') across the checked applicable set.
-- ---------------------------------------------------------------------------

function M._apply_random(entities, categories)
    if type(entities) ~= 'table' or #entities == 0 then
        return nothing_selected_result()
    end

    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed, not_applicable = {}, 0, 0
    local taken = {}

    -- Generate a fresh unique 3-digit string. Pragmatic cap on attempts:
    -- the universe is only 999 values, and we expect at most a handful of
    -- checked planes -- if some pathological batch exhausts the space, we
    -- bail and let the verb dedupe (or accept a collision rather than
    -- spinning forever).
    local function fresh()
        for _ = 1, 1000 do
            local n = math.random(1, 999)
            local s = string.format('%03d', n)
            if not taken[s] then
                taken[s] = true
                return s
            end
        end
        -- Fallback: scan linearly for any unused 3-digit string.
        for n = 1, 999 do
            local s = string.format('%03d', n)
            if not taken[s] then
                taken[s] = true
                return s
            end
        end
        return string.format('%03d', math.random(1, 999))  -- give up; allow duplicate
    end

    for _, u in ipairs(entities) do
        if not applicability.is_applicable(M.applies_to, u, categories) then
            not_applicable = not_applicable + 1
        else
            local new_str = fresh()
            local old_val = u.onboard_num
            local p_ok, res = pcall(verbs.unit_set_onboard_num,
                                    { id = u.unitId, onboard_num = new_str })
            if not p_ok then
                failed = failed + 1
                log_warn('unit_set_onboard_num threw: ' .. tostring(res))
            elseif type(res) ~= 'table' or not res.ok then
                failed = failed + 1
                log_warn('unit_set_onboard_num failed: ' .. tostring(res and res.error or '?'))
            else
                changed_rows[#changed_rows + 1] = { unit = u, old = old_val }
            end
        end
    end

    record_undo(changed_rows)

    local toast, sev = build_toast(#changed_rows, failed, not_applicable)
    return {
        changed        = #changed_rows,
        failed         = failed,
        not_applicable = not_applicable,
        changed_rows   = changed_rows,
        toast          = toast,
        sev            = sev,
    }
end

-- ---------------------------------------------------------------------------
-- Undo handler -- shared by both apply paths. Restores via the verb in
-- reverse direction. If the original onboard_num was nil/empty, restore
-- as '0' (the verb rejects empty strings); rare in practice.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.set_onboard_num_unit', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.set_onboard_num_unit undo snapshot'
    end
    local verbs = require('dcs_sms_me.verbs')
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        if r and r.unit and r.unit.unitId then
            local restore = r.old
            if type(restore) ~= 'string' or restore == '' then restore = '0' end
            local p_ok, res = pcall(verbs.unit_set_onboard_num,
                                    { id = r.unit.unitId, onboard_num = restore })
            if not (p_ok and type(res) == 'table' and res.ok) then errors = errors + 1 end
        else
            errors = errors + 1
        end
    end
    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

-- ---------------------------------------------------------------------------
-- Widget construction. Single row:
--   [Start at:] [EditBox '010'] ........... [Random] [Apply]
-- Apply -> _apply_sequential with EditBox text.
-- Random -> _apply_random, EditBox ignored.
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
    return LAYOUT.ROW_H + LAYOUT.FOOTER_PAD
end

function M.new(parent_raw, get_checked, on_after_apply, get_categories)
    if not parent_raw then return nil end

    local owned = {}
    local function add(widget)
        if widget then owned[#owned + 1] = widget; pcall(parent_raw.insertWidget, parent_raw, widget) end
        return widget
    end

    local start_lbl, start_edit, random_btn, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Start at:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); start_lbl = add(s) end
    end
    if EditBox and EditBox.new then
        local ok, e = pcall(EditBox.new)
        if ok and e then
            skin_helper.apply(e, 'editBoxSkin_ME')
            if e.setText then pcall(e.setText, e, '010') end
            start_edit = add(e)
        end
    end
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'sms_button')
            if b.setText then pcall(b.setText, b, 'Random') end
            random_btn = add(b)
        end
    end
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'sms_button')
            if b.setText then pcall(b.setText, b, 'Set Tail #') end
            apply_btn = add(b)
        end
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local start_str = ''
                if start_edit and start_edit.getText then start_str = start_edit:getText() or '' end
                local entities   = (type(get_checked)     == 'function') and get_checked()     or {}
                local categories = (type(get_categories)  == 'function') and get_categories()  or {}
                local result = M._apply_sequential(entities, start_str, categories)
                if type(on_after_apply) == 'function' then on_after_apply(result) end
            end)
        end)
    end

    if random_btn and random_btn.addMouseDownCallback then
        pcall(random_btn.addMouseDownCallback, random_btn, function()
            pcall(function()
                local entities   = (type(get_checked)    == 'function') and get_checked()    or {}
                local categories = (type(get_categories) == 'function') and get_categories() or {}
                local result = M._apply_random(entities, categories)
                if type(on_after_apply) == 'function' then on_after_apply(result) end
            end)
        end)
    end

    local panel = {}

    function panel:show()
        for _, w in ipairs(owned) do if w.setVisible then pcall(w.setVisible, w, true)  end end
    end

    function panel:hide()
        for _, w in ipairs(owned) do if w.setVisible then pcall(w.setVisible, w, false) end end
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

        -- Right-anchored: Apply (rightmost), then Random to its left. EditBox
        -- fills the rest of the row between the label and the Random button.
        local apply_x  = x + w - L.PAD_X - L.BTN_W
        local random_x = apply_x - L.GAP_X - L.BTN_W
        local input_x  = x + L.PAD_X + L.LABEL_W + L.GAP_X
        local input_w  = random_x - L.GAP_X - input_x
        if input_w < 60 then input_w = 60 end

        set(start_lbl,  x + L.PAD_X, row_y, L.LABEL_W, L.ROW_H)
        set(start_edit, input_x,     row_y, input_w,   L.ROW_H)
        set(random_btn, random_x,    row_y, L.BTN_W,   L.ROW_H)
        set(apply_btn,  apply_x,     row_y, L.BTN_W,   L.ROW_H)
    end

    return panel
end

return M
