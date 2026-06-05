-- mass_edit_forms/find_replace_unit_name.lua — Mass Edit form: find &
-- replace inside unit names.
--
-- Self-contained:
--   * builds its own dxgui widgets (Find / Replace EditBoxes + Replace
--     Button + labels), inserts them into the host window
--   * owns its internal layout (set_bounds positions everything)
--   * runs its own apply loop on button click (no central dispatcher)
--   * registers its own undo handler at module load
--
-- Universal applicability: applies to every checked unit regardless of
-- category (no M.applies_to map). Per-row "no match" rows are silent
-- (don't count toward changed/failed) -- matches the group-scope
-- find_replace_group_name precedent.
--
-- Public:
--   M.scope     : 'unit'
--   M.title     : human-readable form title
--   M.new(parent_raw, get_checked, on_after_apply, get_categories)
--               → panel { show, hide, set_bounds, get_height, set_enabled }
--   M._apply(entities, args, categories)
--               args = { find=string, replace=string }
--               → { changed, failed, not_applicable, changed_rows,
--                   nothing_selected?, toast, sev }
--               Pure-ish: mutates the undo bus + invokes verbs but takes
--               no widget refs. Exists so tests don't need a dxgui mock.

local M = {}

M.scope = 'unit'
M.title = 'Find & replace in unit names'

local undo         = require('dcs_sms_me.undo')
local skin_helper  = require('dcs_sms_me.skin_helper')
local transforms   = require('dcs_sms_me.mass_edit_transforms')

-- dxgui modules (pcall-guarded so the module loads in the test VM).
local Static;  do local ok, m = pcall(require, 'Static');  if ok then Static  = m end end
local Button;  do local ok, m = pcall(require, 'Button');  if ok then Button  = m end end

-- clearable_edit -- mirror find_replace_group_name's widget choice so the
-- two forms look identical. pcall-guarded for the test VM where the
-- module's dxgui deps would otherwise fail to load.
local clearable_edit
do local ok, m = pcall(require, 'dcs_sms_me.clearable_edit'); if ok then clearable_edit = m end end

local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.mass_edit.find_replace_unit_name', _G.log.WARNING or 2, msg) end)
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

    -- ARG-GUARD: args must be a table with a non-empty find. Match the
    -- group-scope precedent which surfaces "No matches" for the empty-find
    -- case (rather than e.g. "Enter a search term") so the warning text is
    -- consistent with the "find string yielded zero changes" outcome.
    if type(args) ~= 'table' or type(args.find) ~= 'string' or args.find == '' then
        return {
            changed = 0, failed = 0, not_applicable = 0, changed_rows = {},
            toast = 'No matches', sev = 'warning',
        }
    end

    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed, not_applicable = {}, 0, 0

    for idx, u in ipairs(entities) do
        local old = u.name
        local new = transforms.find_replace(old, { find = args.find, replace = args.replace or '' }, idx)
        if new == old then
            -- silent skip (no count) — matches group-scope find_replace which
            -- only counts changed/failed; "no match" rows are invisible to
            -- the counters.
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
        undo.record_generic('mass_edit.find_replace_unit_name', { rows = changed_rows })
    end

    local result = {
        changed        = #changed_rows,
        failed         = failed,
        not_applicable = not_applicable,
        changed_rows   = changed_rows,
    }

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
-- Undo handler — registered at module load. Restores via the same verb
-- (reverse direction) so Mission.renameUnit's side effects (ME unit panel
-- refresh, etc.) fire on undo too.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.find_replace_unit_name', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.find_replace_unit_name undo snapshot'
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
-- Widget construction (not under unit test; exercised by manual smoke).
-- ---------------------------------------------------------------------------

local LAYOUT = {
    PAD_X      = 8,
    LABEL_W    = 56,
    ROW_H      = 24,
    BTN_W      = 90,
    SWAP_W     = 28,  -- '< >' swap button between the two inputs
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

    local find_lbl, find_box, swap_btn, repl_box, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Find:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); find_lbl = add(s) end
    end
    if clearable_edit and clearable_edit.new then
        find_box = clearable_edit.new(parent_raw, {})
        if find_box then owned[#owned + 1] = find_box end
    end

    -- Swap button between the two inputs — same widget the group-scope
    -- find/replace exposes. Lets the user invert a rename in one click
    -- after applying it (e.g. find "Viper" replace "Eagle", then swap
    -- to put it back).
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'sms_button')
            if b.setText then pcall(b.setText, b, '< >') end
            if b.setTooltipText then
                pcall(b.setTooltipText, b, 'Swap Find and Replace text')
            end
            swap_btn = add(b)
        end
    end

    if clearable_edit and clearable_edit.new then
        repl_box = clearable_edit.new(parent_raw, {})
        if repl_box then owned[#owned + 1] = repl_box end
    end

    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'sms_button')
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
                local args     = { find = find, replace = replace }
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local cats     = (type(get_categories) == 'function') and get_categories() or {}
                local result   = M._apply(entities, args, cats)
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

        -- Single-row layout:
        --   [Find:][find_box] [< >] [repl_box] [Replace]
        -- The Replace button text identifies the second input; no
        -- "Replace:" label needed. Replace button is right-anchored;
        -- the two EditBoxes share remaining space equally with the swap
        -- button between them.
        local apply_x = x + w - L.PAD_X - L.BTN_W

        local find_lbl_x = x + L.PAD_X
        local find_box_x = find_lbl_x + L.LABEL_W + L.GAP_X
        local remaining  = apply_x - L.GAP_X - find_box_x
        -- Split remaining horizontal space between the two input columns,
        -- accounting for the swap button + the 3 gaps between the four
        -- elements (find_box | swap | repl_box | apply).
        local each_input = math.floor(
            (remaining - L.SWAP_W - 3 * L.GAP_X) / 2)
        if each_input < 60 then each_input = 60 end

        local swap_x     = find_box_x + each_input + L.GAP_X
        local repl_box_x = swap_x + L.SWAP_W + L.GAP_X

        set(find_lbl,  find_lbl_x, row_y, L.LABEL_W,    L.ROW_H)
        set(find_box,  find_box_x, row_y, each_input,   L.ROW_H)
        set(swap_btn,  swap_x,     row_y, L.SWAP_W,     L.ROW_H)
        set(repl_box,  repl_box_x, row_y, each_input,   L.ROW_H)
        set(apply_btn, apply_x,    row_y, L.BTN_W,      L.ROW_H)
    end

    return panel
end

return M
