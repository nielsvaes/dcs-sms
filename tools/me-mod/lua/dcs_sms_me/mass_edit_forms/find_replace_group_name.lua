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

local transforms  = require('dcs_sms_me.mass_edit_transforms')
local undo        = require('dcs_sms_me.undo')
local skin_helper = require('dcs_sms_me.skin_helper')

-- dxgui modules (pcall-guarded so the module loads in the test VM).
local Static;   do local ok, m = pcall(require, 'Static');   if ok then Static   = m end end
local EditBox;  do local ok, m = pcall(require, 'EditBox');  if ok then EditBox  = m end end
local Button;   do local ok, m = pcall(require, 'Button');   if ok then Button   = m end end

local function log_warn(msg) pcall(function() _G.log.write('sms.me.mass_edit.find_replace_group_name', _G.log.WARNING or 2, msg) end) end

-- Internal writer. Mirrors the deleted group_name registry entry's logic.
local function write_group_name(g, value)
    local Mission = require('me_mission')
    if type(Mission.renameGroup) ~= 'function' then
        g.name = value
        return true
    end
    local ok = Mission.renameGroup(g, value)
    if not ok then return false, 'rename rejected by Mission.renameGroup' end
    return true
end

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------

function M._apply(entities, find, replace)
    if type(entities) ~= 'table' or #entities == 0 then
        return { changed = 0, failed = 0, changed_rows = {}, nothing_selected = true }
    end

    local changed_rows, failed = {}, 0
    for _, e in ipairs(entities) do
        local old = e.name
        local new = transforms.find_replace(old, { find = find or '', replace = replace or '' })
        if new ~= old then
            local p_ok, w_ok, w_err = pcall(write_group_name, e, new)
            if p_ok and w_ok then
                changed_rows[#changed_rows + 1] = { entity = e, old = old }
            else
                failed = failed + 1
                log_warn('write_group_name failed: ' .. tostring(p_ok and w_err or w_ok))
            end
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.find_replace_group_name', { rows = changed_rows })
    end

    return { changed = #changed_rows, failed = failed, changed_rows = changed_rows }
end

-- ---------------------------------------------------------------------------
-- Undo handler — registered once at module load. Re-registers after hot
-- reload (the undo bus replaces the handler under the same id). Restores
-- names via the same write_group_name path used at apply time, so
-- Mission.renameGroup side effects (ME group panel refresh, etc.) fire
-- on undo too.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.find_replace_group_name', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.find_replace_group_name undo snapshot'
    end
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        local p_ok, w_ok = pcall(write_group_name, r.entity, r.old)
        if not (p_ok and w_ok) then errors = errors + 1 end
    end
    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

-- ---------------------------------------------------------------------------
-- Widget construction (not under unit test; exercised by manual smoke).
-- ---------------------------------------------------------------------------

local LAYOUT = {
    PAD_X      = 8,
    PAD_Y      = 6,
    LABEL_W    = 56,
    ROW_H      = 24,
    BTN_W      = 90,
    GAP_X      = 6,
    GAP_Y      = 4,
    TITLE_H    = 22,
    FOOTER_PAD = 6,
}

local function form_height()
    local L = LAYOUT
    return L.TITLE_H + L.GAP_Y + L.ROW_H + L.GAP_Y + L.ROW_H + L.FOOTER_PAD
end

function M.new(parent_raw, get_checked, on_after_apply)
    if not parent_raw then return nil end

    local owned = {}
    local function add(widget)
        if widget then owned[#owned + 1] = widget; pcall(parent_raw.insertWidget, parent_raw, widget) end
        return widget
    end

    local title_lbl, find_lbl, find_box, repl_lbl, repl_box, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, M.title)
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); title_lbl = add(s) end
    end

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Find:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); find_lbl = add(s) end
    end
    if EditBox and EditBox.new then
        local ok, e = pcall(EditBox.new)
        if ok and e then skin_helper.apply(e, 'editBoxSkin_ME'); find_box = add(e) end
    end

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Replace:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); repl_lbl = add(s) end
    end
    if EditBox and EditBox.new then
        local ok, e = pcall(EditBox.new)
        if ok and e then skin_helper.apply(e, 'editBoxSkin_ME'); repl_box = add(e) end
    end

    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Replace') end
            apply_btn = add(b)
        end
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

    function panel:set_bounds(x, y, w, h)
        local L = LAYOUT
        local function set(widget, px, py, pw, ph)
            if widget and widget.setBounds then pcall(widget.setBounds, widget, px, py, pw, ph) end
        end

        set(title_lbl, x + L.PAD_X, y, w - 2 * L.PAD_X, L.TITLE_H)

        local row_y_1 = y + L.TITLE_H + L.GAP_Y
        local input_x = x + L.PAD_X + L.LABEL_W + L.GAP_X
        local input_w = w - L.PAD_X * 2 - L.LABEL_W - L.GAP_X - L.BTN_W - L.GAP_X
        if input_w < 80 then input_w = 80 end
        set(find_lbl, x + L.PAD_X, row_y_1, L.LABEL_W, L.ROW_H)
        set(find_box, input_x,      row_y_1, input_w,  L.ROW_H)

        local row_y_2 = row_y_1 + L.ROW_H + L.GAP_Y
        set(repl_lbl, x + L.PAD_X, row_y_2, L.LABEL_W, L.ROW_H)
        set(repl_box, input_x,      row_y_2, input_w,  L.ROW_H)

        local btn_x = x + w - L.PAD_X - L.BTN_W
        local btn_y = row_y_1 + (L.ROW_H + L.GAP_Y) / 2
        set(apply_btn, btn_x, btn_y, L.BTN_W, L.ROW_H)
    end

    return panel
end

return M
