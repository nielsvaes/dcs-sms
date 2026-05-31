-- mass_edit_forms/set_skill_unit.lua -- Mass Edit form: set the skill of
-- every checked unit via verbs.unit_set_skill.
--
-- Two skill universes (matches ED's stock dialogs in me_aircraft.lua /
-- me_vehicle.lua / me_ship.lua):
--   * Aircraft (plane + helicopter): 7 IDs — Average / Good / High /
--     Excellent / Random / Client / Player. ED renders these as Rookie /
--     Trained / Veteran / Ace / Random / Client / Player.
--   * Ground (vehicle + ship): 5 IDs — Average / Good / High / Excellent
--     / Random. ED uses the IDs as labels.
--   * Static: no skill field — form stays disabled for any static in
--     the selection.
--
-- The combo holds ED's per-category LABELS but each item carries the
-- canonical ID on _skill_id. set_enabled() repopulates the combo when
-- the checked set's category mix changes (aircraft-only ↔ ground-only),
-- preserving the user's pick by ID across the swap. Mixed selections
-- (aircraft + ground, or anything with a static) disable the whole
-- form — there's no single skill list valid for both sides.
--
-- Pre-checks each unit's current skill against the picked ID so
-- "already-at-target" rows count as `unchanged` without spending a
-- verb call.
--
-- Public:
--   M.scope   : 'unit'
--   M.title   : 'Set skill'
--   M.new(parent_raw, get_checked, on_after_apply, get_categories)
--   M._apply(entities, skill, categories)
--             -> { changed, failed, unchanged, changed_rows,
--                  nothing_selected?, toast, sev }

local M = {}

M.scope = 'unit'
M.title = 'Set skill'
-- No M.applies_to -- universal across plane / helicopter / vehicle / ship / static.

local undo        = require('dcs_sms_me.undo')
local skin_helper = require('dcs_sms_me.skin_helper')

local Static;       do local ok, m = pcall(require, 'Static');       if ok then Static       = m end end
local Button;       do local ok, m = pcall(require, 'Button');       if ok then Button       = m end end
local ComboList;    do local ok, m = pcall(require, 'ComboList');    if ok then ComboList    = m end end
local ListBoxItem;  do local ok, m = pcall(require, 'ListBoxItem');  if ok then ListBoxItem  = m end end

local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.mass_edit.set_skill_unit', _G.log.WARNING or 2, msg) end)
end

-- Two parallel arrays per category — same length, item i in LABELS pairs
-- with item i in IDS. The label is what the user sees in the combo;
-- the ID is what gets written to u.skill.
local AIRCRAFT = {
    labels = { 'Rookie',  'Trained', 'Veteran', 'Ace',       'Random', 'Client', 'Player' },
    ids    = { 'Average', 'Good',    'High',    'Excellent', 'Random', 'Client', 'Player' },
}
local GROUND = {
    labels = { 'Average', 'Good', 'High', 'Excellent', 'Random' },
    ids    = { 'Average', 'Good', 'High', 'Excellent', 'Random' },
}

-- Inspect the checked set's categories and return either 'aircraft',
-- 'ground', or nil (nil ⇒ mixed / contains static / empty ⇒ form is
-- disabled, no valid single skill list).
local function classify_selection(entities, categories)
    if type(entities) ~= 'table' or #entities == 0 then return nil end
    categories = categories or {}
    local has_air, has_ground = false, false
    for _, e in ipairs(entities) do
        local cat = categories[e] or 'unknown'
        if cat == 'plane' or cat == 'helicopter' then
            has_air = true
        elseif cat == 'vehicle' or cat == 'ship' then
            has_ground = true
        else
            -- static / unknown / anything else — can't be skill-edited.
            return nil
        end
    end
    if has_air and has_ground then return nil end  -- mixed
    if has_air then return 'aircraft' end
    if has_ground then return 'ground' end
    return nil
end

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------

function M._apply(entities, skill, _categories)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, failed = 0, unchanged = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end
    if type(skill) ~= 'string' or skill == '' then
        return {
            changed = 0, failed = 0, unchanged = 0, changed_rows = {},
            toast = 'Pick a skill', sev = 'warning',
        }
    end

    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed, unchanged = {}, 0, 0

    for _, u in ipairs(entities) do
        local old = u.skill
        if old == skill then
            unchanged = unchanged + 1
        else
            local p_ok, res = pcall(verbs.unit_set_skill, { id = u.unitId, skill = skill })
            if not p_ok then
                failed = failed + 1
                log_warn('unit_set_skill threw: ' .. tostring(res))
            elseif type(res) ~= 'table' or not res.ok then
                failed = failed + 1
                log_warn('unit_set_skill failed: ' .. tostring(res and res.error or '?'))
            else
                changed_rows[#changed_rows + 1] = { unit = u, old = old }
            end
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.set_skill_unit', { rows = changed_rows })
    end

    local result = {
        changed      = #changed_rows,
        failed       = failed,
        unchanged    = unchanged,
        changed_rows = changed_rows,
    }

    if #changed_rows == 0 and failed == 0 and unchanged > 0 then
        result.toast = 'Already ' .. skill
        result.sev   = 'info'
    elseif #changed_rows == 0 and failed > 0 then
        local toast = string.format('%d skill set · %d failed', 0, failed)
        if unchanged > 0 then toast = toast .. string.format(' · %d unchanged', unchanged) end
        result.toast = toast
        result.sev   = 'error'
    else
        local toast = string.format('%d skill set', #changed_rows)
        if unchanged > 0 then toast = toast .. string.format(' · %d unchanged', unchanged) end
        if failed    > 0 then toast = toast .. string.format(' · %d failed',    failed)    end
        result.toast = toast
        result.sev   = (failed == 0 and 'success') or 'warning'
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Undo handler -- registered at module load. Restores via the same verb
-- with each row's OLD skill so the mission tree returns to its prior state.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.set_skill_unit', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.set_skill_unit undo snapshot'
    end
    local verbs = require('dcs_sms_me.verbs')
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        if r.unit and r.old then
            local p_ok, res = pcall(verbs.unit_set_skill, { id = r.unit.unitId, skill = r.old })
            if not (p_ok and type(res) == 'table' and res.ok) then errors = errors + 1 end
        else
            errors = errors + 1
        end
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

-- Populate the skill combo with the given kind's label/ID pair. Each
-- item stashes its canonical ID on _skill_id (read by the apply handler
-- — never read .getText() since the displayed label differs from the
-- stored ID for aircraft). Preserves the currently-selected ID across
-- repopulation: e.g. if the user picked "Ace" (id=Excellent) on
-- aircraft, then switches to a ground-only selection, "Excellent" stays
-- selected (now labeled "Excellent" since ground labels = IDs).
local function populate_skill_combo(combo, kind)
    if not (combo and ListBoxItem and ListBoxItem.new) then return end
    local set = (kind == 'aircraft') and AIRCRAFT or GROUND

    local prev_id
    if combo.getSelectedItem then
        local cur = combo:getSelectedItem()
        if cur and cur._skill_id then prev_id = cur._skill_id end
    end

    if combo.removeAllItems then pcall(combo.removeAllItems, combo) end

    local match_item, first_item
    for i, label in ipairs(set.labels) do
        local ok, item = pcall(ListBoxItem.new, label)
        if ok and item then
            item._skill_id = set.ids[i]
            pcall(combo.insertItem, combo, item)
            if i == 1 then first_item = item end
            if prev_id and set.ids[i] == prev_id then match_item = item end
        end
    end

    local target = match_item or first_item
    if target and combo.selectItem then
        pcall(combo.selectItem, combo, target)
    end
end

function M.new(parent_raw, get_checked, on_after_apply, get_categories)
    if not parent_raw then return nil end

    local owned = {}
    local function add(widget)
        if widget then owned[#owned + 1] = widget; pcall(parent_raw.insertWidget, parent_raw, widget) end
        return widget
    end

    local skill_lbl, skill_combo, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Skill:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); skill_lbl = add(s) end
    end
    if ComboList and ComboList.new then
        local ok, c = pcall(ComboList.new)
        if ok and c then
            skin_helper.apply(c, 'comboListSkinNew_')
            skill_combo = add(c)
            -- Seed with the ground list — populate_skill_combo will swap
            -- to aircraft on the first set_enabled() call if the active
            -- selection is aircraft. Ground is the broader-applicable
            -- default (it's a strict subset of the aircraft IDs).
            populate_skill_combo(skill_combo, 'ground')
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
                local picked = ''
                if skill_combo and skill_combo.getSelectedItem then
                    local item = skill_combo:getSelectedItem()
                    -- Always read the canonical ID off the item — the
                    -- displayed label may be 'Ace' (aircraft) while the
                    -- ID is 'Excellent', and that ID is what u.skill
                    -- expects in the .miz.
                    if item and item._skill_id then picked = item._skill_id end
                end
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local cats     = (type(get_categories) == 'function') and get_categories() or {}
                local result   = M._apply(entities, picked, cats)
                if type(on_after_apply) == 'function' then on_after_apply(result) end
            end)
        end)
    end

    -- Track the kind currently populating the combo so we only repopulate
    -- on transitions. Avoids churning the user's mid-edit selection on
    -- every check-state mutation within the same category.
    local current_kind = 'ground'

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
        -- Host's flag is "at least one checked" (universal applies_to).
        -- We refine: classify the checked set into 'aircraft' / 'ground'
        -- / nil. nil means mixed, contains static, or empty — disable
        -- the whole form. Otherwise repopulate the combo only when the
        -- kind changes (so picking a skill, then checking another unit
        -- of the same category, doesn't reset the selection).
        local entities = (type(get_checked) == 'function') and get_checked() or {}
        local cats     = (type(get_categories) == 'function') and get_categories() or {}
        local kind     = classify_selection(entities, cats)
        local en       = (flag and kind ~= nil) and true or false
        if kind and kind ~= current_kind then
            current_kind = kind
            populate_skill_combo(skill_combo, kind)
        end
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

        -- Right-anchored Set button; combo fills the rest of the row
        -- between the label and the button.
        local apply_x = x + w - L.PAD_X - L.BTN_W
        local input_x = x + L.PAD_X + L.LABEL_W + L.GAP_X
        local input_w = apply_x - L.GAP_X - input_x
        if input_w < 80 then input_w = 80 end

        set(skill_lbl,   x + L.PAD_X, row_y, L.LABEL_W, L.ROW_H)
        set(skill_combo, input_x,     row_y, input_w,   L.ROW_H)
        set(apply_btn,   apply_x,     row_y, L.BTN_W,   L.ROW_H)
    end

    return panel
end

return M
