-- mass_edit_forms/set_country.lua -- Mass Edit form: set the country of
-- every checked group via verbs.group_set_country.
--
-- Self-contained. ComboList populated from Mission.missionCountry (the
-- same source prefab_manager uses). Per-item skins coalition-tint each
-- entry (red / blue / neutral) -- also serves as the closed-display skin
-- so the selected country's name remains visible after picking.
--
-- Apply wraps the existing verb so we inherit its side-effect handling
-- (coalition flip, livery fixup, color update). The verb's result table
-- carries `previous_country`, which the form uses to build the undo
-- snapshot -- no pre-verb mission walk needed.

local M = {}

M.scope = 'group'
M.title = 'Set country'

local undo        = require('dcs_sms_me.undo')
local skin_helper = require('dcs_sms_me.skin_helper')

local Static;        do local ok, m = pcall(require, 'Static');        if ok then Static        = m end end
local ComboList;     do local ok, m = pcall(require, 'ComboList');     if ok then ComboList     = m end end
local ListBoxItem;   do local ok, m = pcall(require, 'ListBoxItem');   if ok then ListBoxItem   = m end end
local Button;        do local ok, m = pcall(require, 'Button');        if ok then Button        = m end end

local function log_warn(msg) pcall(function() _G.log.write('sms.me.mass_edit.set_country', _G.log.WARNING or 2, msg) end) end

-- Internal: lookup a country's coalition by walking the mission tree.
-- Returns 'red' / 'blue' / 'neutral' (or 'neutral' as a safe default).
local function country_coalition_of(Mission, country_name)
    local mission = Mission and Mission.mission
    if type(mission) ~= 'table' or type(mission.coalition) ~= 'table' then return 'neutral' end
    for side_name, side in pairs(mission.coalition) do
        if type(side) == 'table' and type(side.country) == 'table' then
            for _, c in ipairs(side.country) do
                if type(c.name) == 'string' and c.name == country_name then
                    if side_name == 'red' then return 'red'
                    elseif side_name == 'blue' then return 'blue'
                    else return 'neutral' end
                end
            end
        end
    end
    return 'neutral'
end

local COALITION_SKIN = {
    red     = 'listBoxItemCoalRedSkin',
    blue    = 'listBoxItemCoalBlueSkin',
    neutral = 'listBoxItemCoalNeutralSkin',
}

-- (Re-)populate a ComboList from Mission.missionCountry, falling back to
-- a coalition-tree walk if missionCountry is absent (test VMs).
local function populate_country_combo(combo)
    if not (combo and ListBoxItem and ListBoxItem.new) then return end
    if combo.removeAllItems then pcall(combo.removeAllItems, combo) end
    local Mission = require('me_mission')
    local names = {}

    if type(Mission.missionCountry) == 'table' then
        for name in pairs(Mission.missionCountry) do
            if type(name) == 'string' then names[#names + 1] = name end
        end
    elseif type(Mission.mission) == 'table' and type(Mission.mission.coalition) == 'table' then
        local seen = {}
        for _, side in pairs(Mission.mission.coalition) do
            if type(side) == 'table' and type(side.country) == 'table' then
                for _, c in ipairs(side.country) do
                    if type(c.name) == 'string' and not seen[c.name] then
                        seen[c.name] = true
                        names[#names + 1] = c.name
                    end
                end
            end
        end
    end

    table.sort(names)
    for _, name in ipairs(names) do
        local ok, item = pcall(ListBoxItem.new, name)
        if ok and item then
            local coal = country_coalition_of(Mission, name)
            local skin_name = COALITION_SKIN[coal]
            if skin_name then skin_helper.apply(item, skin_name) end
            pcall(combo.insertItem, combo, item)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------

function M._apply(entities, country_name)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, failed = 0, unchanged = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end
    if type(country_name) ~= 'string' or country_name == '' then
        return {
            changed = 0, failed = 0, unchanged = 0, changed_rows = {},
            toast = 'Pick a country', sev = 'warning',
        }
    end

    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed, unchanged = {}, 0, 0

    for _, e in ipairs(entities) do
        local p_ok, res = pcall(verbs.group_set_country, { id = e.groupId, country = country_name })
        if not p_ok then
            failed = failed + 1
            log_warn('group_set_country threw: ' .. tostring(res))
        elseif type(res) ~= 'table' or not res.ok then
            failed = failed + 1
            log_warn('group_set_country failed: ' .. tostring(res and res.error or '?'))
        elseif res.no_op then
            unchanged = unchanged + 1
        else
            changed_rows[#changed_rows + 1] = {
                entity = e,
                old    = res.previous_country,
            }
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.set_country', { rows = changed_rows })
    end

    local result = {
        changed      = #changed_rows,
        failed       = failed,
        unchanged    = unchanged,
        changed_rows = changed_rows,
    }

    if #changed_rows == 0 and failed == 0 and unchanged > 0 then
        result.toast = 'Already in ' .. country_name
        result.sev   = 'info'
    elseif #changed_rows == 0 and failed > 0 then
        local toast = string.format('%d country set', 0)
        toast = toast .. string.format(' · %d failed', failed)
        result.toast = toast
        result.sev   = 'error'
    else
        local toast = string.format('%d country set', #changed_rows)
        if unchanged > 0 then toast = toast .. string.format(' · %d unchanged', unchanged) end
        if failed > 0    then toast = toast .. string.format(' · %d failed',    failed)    end
        result.toast = toast
        result.sev   = (failed == 0 and 'success') or 'warning'
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Undo handler -- registered at module load. Restores via the same verb
-- (reverse direction), so coalition flip / livery fixup / map color
-- update all re-run on undo too.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.set_country', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.set_country undo snapshot'
    end
    local verbs = require('dcs_sms_me.verbs')
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        if r.entity and r.old then
            local p_ok, res = pcall(verbs.group_set_country, { id = r.entity.groupId, country = r.old })
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
    PAD_X      = 8,
    LABEL_W    = 60,
    ROW_H      = 24,
    BTN_W      = 100,
    GAP_X      = 6,
    GAP_Y      = 4,
    TITLE_H    = 22,
    HINT_H     = 18,
    FOOTER_PAD = 6,
}

local function form_height()
    local L = LAYOUT
    return L.TITLE_H + L.GAP_Y + L.ROW_H + L.GAP_Y + L.HINT_H + L.FOOTER_PAD
end

function M.new(parent_raw, get_checked, on_after_apply)
    if not parent_raw then return nil end

    local owned = {}
    local function add(widget)
        if widget then owned[#owned + 1] = widget; pcall(parent_raw.insertWidget, parent_raw, widget) end
        return widget
    end

    local title_lbl, country_lbl, country_combo, hint_lbl, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, M.title)
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); title_lbl = add(s) end
    end

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Country:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); country_lbl = add(s) end
    end
    if ComboList and ComboList.new then
        local ok, c = pcall(ComboList.new)
        if ok and c then
            skin_helper.apply(c, 'comboListSkinNew_')
            country_combo = add(c)
            populate_country_combo(country_combo)
        end
    end

    if Static and Static.new then
        local ok, s = pcall(Static.new, '(coalition will change if the country switches sides)')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); hint_lbl = add(s) end
    end

    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Set country') end
            apply_btn = add(b)
        end
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local picked = ''
                if country_combo and country_combo.getSelectedItem then
                    local item = country_combo:getSelectedItem()
                    if item and item.getText then picked = item:getText() or '' end
                end
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local result = M._apply(entities, picked)
                if type(on_after_apply) == 'function' then on_after_apply(result) end
                -- Re-populate the combo after apply because moving entities
                -- across countries can drain a country bucket (= remove from
                -- Mission.missionCountry).
                populate_country_combo(country_combo)
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

        local row_y = y + L.TITLE_H + L.GAP_Y
        local input_x = x + L.PAD_X + L.LABEL_W + L.GAP_X
        local input_w = w - L.PAD_X * 2 - L.LABEL_W - L.GAP_X - L.BTN_W - L.GAP_X
        if input_w < 80 then input_w = 80 end
        set(country_lbl,   x + L.PAD_X, row_y, L.LABEL_W, L.ROW_H)
        set(country_combo, input_x,      row_y, input_w,  L.ROW_H)

        local btn_x = x + w - L.PAD_X - L.BTN_W
        set(apply_btn, btn_x, row_y, L.BTN_W, L.ROW_H)

        local hint_y = row_y + L.ROW_H + L.GAP_Y
        set(hint_lbl, x + L.PAD_X, hint_y, w - 2 * L.PAD_X, L.HINT_H)
    end

    return panel
end

return M
