-- mass_edit_forms/find_replace_group_name.lua — Mass Edit form: find &
-- replace inside group names.
--
-- Self-contained:
--   * builds its own dxgui widgets (Find / Replace EditBoxes + Replace
--     Button + heading + labels), inserts them into the host window
--   * owns its internal layout (set_bounds positions everything)
--   * runs its own apply loop on button click (no central dispatcher)
--   * registers its own undo handler at module load
--
-- Public:
--   M.scope     : 'group'
--   M.title     : human-readable form title
--   M.new(parent_raw, get_checked, on_after_apply)
--               → panel { show, hide, set_bounds, get_height }
--   M._apply(entities, find, replace)
--               → { changed, failed, changed_rows, nothing_selected? }
--               Pure-ish: mutates entities and the undo bus but takes
--               no widget refs. Exists so tests don't need a dxgui mock.

local M = {}

M.scope = 'group'
M.title = 'Find & replace in group names'

local transforms     = require('dcs_sms_me.mass_edit_transforms')
local undo           = require('dcs_sms_me.undo')
local skin_helper    = require('dcs_sms_me.skin_helper')
local name_writer    = require('dcs_sms_me.group_name_writer')
local clearable_edit = require('dcs_sms_me.clearable_edit')

-- dxgui modules (pcall-guarded so the module loads in the test VM).
local Static;   do local ok, m = pcall(require, 'Static');   if ok then Static   = m end end
local Button;   do local ok, m = pcall(require, 'Button');   if ok then Button   = m end end

local function log_warn(msg) pcall(function() _G.log.write('sms.me.mass_edit.find_replace_group_name', _G.log.WARNING or 2, msg) end) end

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------

function M._apply(entities, find, replace)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, failed = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end

    local changed_rows, failed = {}, 0
    for _, e in ipairs(entities) do
        local old = e.name
        local new = transforms.find_replace(old, { find = find or '', replace = replace or '' })
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
        undo.record_generic('mass_edit.find_replace_group_name', { rows = changed_rows })
    end

    local result = {
        changed      = #changed_rows,
        failed       = failed,
        changed_rows = changed_rows,
    }

    -- Toast text + severity. The host treats these as opaque strings and
    -- just plays them — keeps the host form-agnostic.
    if #changed_rows == 0 and failed == 0 then
        result.toast = 'No matches'
        result.sev   = 'warning'
    else
        local toast = string.format('%d renamed', #changed_rows)
        if failed > 0 then toast = toast .. string.format(' · %d failed', failed) end
        local sev = (failed == 0 and 'success') or (#changed_rows == 0 and 'error') or 'warning'
        result.toast = toast
        result.sev   = sev
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Undo handler — registered once at module load. Re-registers after hot
-- reload (the undo bus replaces the handler under the same id). Restores
-- names via the same name_writer.write path used at apply time, so
-- Mission.renameGroup side effects (ME group panel refresh, etc.) fire
-- on undo too.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.find_replace_group_name', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.find_replace_group_name undo snapshot'
    end
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        local p_ok, w_ok = pcall(name_writer.write, r.entity, r.old, { literal = true })
        if not (p_ok and w_ok) then errors = errors + 1 end
    end
    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

-- ---------------------------------------------------------------------------
-- Widget construction (not under unit test; exercised by manual smoke).
-- ---------------------------------------------------------------------------

local LAYOUT = {
    PAD_X      = 8,
    LABEL_W    = 56,
    REPL_LBL_W = 64,  -- 'Replace:' is wider than 'Find:'
    ROW_H      = 24,
    BTN_W      = 90,
    SWAP_W     = 28,  -- '⇅' swap button between the two inputs
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

    local find_lbl, find_box, swap_btn, repl_lbl, repl_box, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Find:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); find_lbl = add(s) end
    end
    find_box = clearable_edit.new(parent_raw, {})
    if find_box then owned[#owned + 1] = find_box end

    -- Swap button between the two inputs. Single click inverts a rename
    -- (e.g. after applying find "Viper" replace "Eagle", swap and re-
    -- apply to put it back).
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, '< >') end
            if b.setTooltipText then
                pcall(b.setTooltipText, b, 'Swap Find and Replace text')
            end
            swap_btn = add(b)
        end
    end

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Replace:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); repl_lbl = add(s) end
    end
    repl_box = clearable_edit.new(parent_raw, {})
    if repl_box then owned[#owned + 1] = repl_box end

    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Replace') end
            apply_btn = add(b)
        end
    end

    if swap_btn and swap_btn.addMouseDownCallback then
        pcall(swap_btn.addMouseDownCallback, swap_btn, function()
            pcall(function()
                local f = (find_box and find_box.getText and find_box:getText()) or ''
                local r = (repl_box and repl_box.getText and repl_box:getText()) or ''
                if find_box and find_box.setText then find_box:setText(r) end
                if repl_box and repl_box.setText then repl_box:setText(f) end
            end)
        end)
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local find    = (find_box and find_box.getText and find_box:getText()) or ''
                local replace = (repl_box and repl_box.getText and repl_box:getText()) or ''
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local result = M._apply(entities, find, replace)
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

        -- Single-row layout matching the unit-scope form:
        --   [Find:][find_box] [⇅] [Replace:][repl_box] [Replace]
        local apply_x = x + w - L.PAD_X - L.BTN_W

        local find_lbl_x = x + L.PAD_X
        local find_box_x = find_lbl_x + L.LABEL_W + L.GAP_X
        local remaining  = apply_x - L.GAP_X - find_box_x
        local each_input = math.floor(
            (remaining - L.SWAP_W - L.REPL_LBL_W - 4 * L.GAP_X) / 2)
        if each_input < 60 then each_input = 60 end

        local swap_x     = find_box_x + each_input + L.GAP_X
        local repl_lbl_x = swap_x + L.SWAP_W + L.GAP_X
        local repl_box_x = repl_lbl_x + L.REPL_LBL_W + L.GAP_X

        set(find_lbl,  find_lbl_x, row_y, L.LABEL_W,    L.ROW_H)
        set(find_box,  find_box_x, row_y, each_input,   L.ROW_H)
        set(swap_btn,  swap_x,     row_y, L.SWAP_W,     L.ROW_H)
        set(repl_lbl,  repl_lbl_x, row_y, L.REPL_LBL_W, L.ROW_H)
        set(repl_box,  repl_box_x, row_y, each_input,   L.ROW_H)
        set(apply_btn, apply_x,    row_y, L.BTN_W,      L.ROW_H)
    end

    return panel
end

return M
