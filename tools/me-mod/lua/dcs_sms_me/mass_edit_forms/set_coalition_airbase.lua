-- mass_edit_forms/set_coalition_airbase.lua -- Mass Edit form: set the
-- coalition of every checked airbase via verbs.airbase_set_coalition.
--
-- Layout: 'Coalition:' label + ComboList (Red/Blue/Neutral) + Set button.
-- Apply iterates checked airbase entries, captures each prior coalition
-- for undo, then calls the verb (which does the warehouse splice + live-
-- map refresh via AirdromeController.setAirdromeCoalition). Undo is a
-- single batched record that re-calls the verb with each prior value.

local M = {}

M.scope = 'airbase'
M.title = 'Set coalition'

local undo        = require('dcs_sms_me.undo')
local verbs       = require('dcs_sms_me.verbs')
local skin_helper = require('dcs_sms_me.skin_helper')

local Static       do local ok, m = pcall(require, 'Static');      if ok then Static       = m end end
local ComboList;   do local ok, m = pcall(require, 'ComboList');   if ok then ComboList   = m end end
local ListBoxItem; do local ok, m = pcall(require, 'ListBoxItem'); if ok then ListBoxItem = m end end
local Button;      do local ok, m = pcall(require, 'Button');      if ok then Button      = m end end

local COALITION_ITEMS = {
    { value = 'red',      label = 'Red',     skin = 'listBoxItemCoalRedSkin'     },
    { value = 'blue',     label = 'Blue',    skin = 'listBoxItemCoalBlueSkin'    },
    { value = 'neutrals', label = 'Neutral', skin = 'listBoxItemCoalNeutralSkin' },
}

-- ---------------------------------------------------------------------------
-- Apply logic (extracted from the click handler so it's testable).
-- ---------------------------------------------------------------------------

function M._apply(entities, coalition)
    if type(entities) ~= 'table' or #entities == 0 then
        return { ok = false, toast = 'no airbases checked', sev = 'warning' }
    end
    if type(coalition) ~= 'string' or coalition == '' then
        return { ok = false, toast = 'no coalition picked', sev = 'warning' }
    end

    local rows = {}   -- one snapshot per airbase, used as the undo payload
    local errors = 0
    for _, e in ipairs(entities) do
        local prev = e.coalition  -- capture from the pool row, not from the verb
        local res  = verbs.airbase_set_coalition({ name = e.name, coalition = coalition })
        if res and res.ok then
            rows[#rows + 1] = { name = e.name, prev_coalition = prev }
        else
            errors = errors + 1
        end
    end

    if #rows > 0 then
        undo.record_generic('mass_edit.set_coalition_airbase', { rows = rows })
    end

    local toast
    if errors == 0 then
        toast = string.format('%d airbase%s set to %s', #rows,
                              #rows == 1 and '' or 's', coalition)
    else
        toast = string.format('%d ok, %d failed (set to %s)', #rows, errors, coalition)
    end
    return { ok = errors == 0, toast = toast, sev = errors == 0 and 'info' or 'warning' }
end

-- ---------------------------------------------------------------------------
-- Undo handler — re-issue the verb per row with the captured prior value.
-- Registered once at module load. Idempotent.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.set_coalition_airbase', function(payload)
    if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then
        return nil, 'invalid payload'
    end
    local errors = 0
    for i = 1, #payload.rows do
        local row = payload.rows[i]
        if row and row.name and row.prev_coalition then
            local res = verbs.airbase_set_coalition({ name = row.name, coalition = row.prev_coalition })
            if not (res and res.ok) then errors = errors + 1 end
        end
    end
    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

-- ---------------------------------------------------------------------------
-- Mount: builds widgets in the supplied parent. Mounted by mass_edit.lua's
-- form host loop. Wires the Apply button to call M._apply via get_checked.
-- ---------------------------------------------------------------------------

function M.new(parent_raw, get_checked, on_after_apply, _get_categories)
    get_checked = get_checked or function() return {} end

    local owned = {}
    local function add(w) owned[#owned + 1] = w; pcall(parent_raw.insertWidget, parent_raw, w); return w end

    local label, combo, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new)
        if ok and s then
            if s.setText then pcall(s.setText, s, 'Coalition:') end
            skin_helper.apply(s, 'staticSkin_ME')
            label = add(s)
        end
    end

    if ComboList and ComboList.new and ListBoxItem and ListBoxItem.new then
        local ok, c = pcall(ComboList.new)
        if ok and c then
            skin_helper.apply(c, 'comboListSkinNew_')
            for _, item in ipairs(COALITION_ITEMS) do
                local ok_i, lbi = pcall(ListBoxItem.new, item.label)
                if ok_i and lbi then
                    skin_helper.apply(lbi, item.skin)
                    if c.insertItem then pcall(c.insertItem, c, lbi) end
                    -- Stash the value on the item so the apply handler can read it.
                    lbi._coalition_value = item.value
                end
            end
            combo = add(c)
        end
    end

    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Set') end
            apply_btn = add(b)
        end
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local picked = nil
                if combo and combo.getSelectedItem then
                    local item = combo:getSelectedItem()
                    if item and item._coalition_value then picked = item._coalition_value end
                end
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local result = M._apply(entities, picked)
                if type(on_after_apply) == 'function' then on_after_apply(result) end
            end)
        end)
    end

    -- Layout: 'Coalition:' (90px) + combo (filling middle) + Set (90px right).
    local LABEL_W = 90
    local BTN_W   = 90
    local PAD     = 4

    local panel = {
        widgets = owned,
        get_height = function() return 28 end,
        set_bounds = function(_, x, y, w, h)
            local label_x  = x
            local combo_x  = x + LABEL_W + PAD
            local btn_x    = x + w - BTN_W
            local combo_w  = math.max(40, (btn_x - combo_x) - PAD)
            local row_y    = y + math.floor((h - 24) / 2)
            if label     and label.setBounds     then pcall(label.setBounds,     label,     label_x,  row_y, LABEL_W, 24) end
            if combo     and combo.setBounds     then pcall(combo.setBounds,     combo,     combo_x,  row_y, combo_w, 24) end
            if apply_btn and apply_btn.setBounds then pcall(apply_btn.setBounds, apply_btn, btn_x,    row_y, BTN_W,   24) end
        end,
        show = function() for _, w in ipairs(owned) do if w.setVisible then pcall(w.setVisible, w, true) end end end,
        hide = function() for _, w in ipairs(owned) do if w.setVisible then pcall(w.setVisible, w, false) end end end,
        set_enabled = function(_, flag)
            local en = flag and true or false
            for _, w in ipairs(owned) do
                if w.setEnabled then pcall(w.setEnabled, w, en) end
            end
        end,
    }
    return panel
end

return M
