-- mass_edit_forms/toggle_group_flags.lua -- Mass Edit form: flip six
-- boolean group properties (hidden / hiddenOnPlanner / hiddenOnMFD /
-- uncontrollable / uncontrolled / lateActivation) on every checked
-- group.
--
-- Each property has its own tri-state control (LEAVE / ON / OFF).
-- LEAVE means "skip this property in this batch"; ON/OFF write
-- true/false respectively. Per-property applicability is hard-coded
-- in APPLIES_TO (mirrors the ME's per-category checkbox visibility) --
-- entity-field pairs that aren't applicable to the entity's category
-- are silently skipped; the entity is counted once toward
-- not_applicable if any of its requested fields was inapplicable.
--
-- The toggle fields have no side effects beyond their own value (no
-- coalition flip, no livery, no map-color shift like set_country
-- has), so the form writes fields directly rather than routing
-- through verbs. The standalone toggle verbs in verbs.lua exist for
-- CLI scripting (and are not called from here). Undo also writes
-- fields directly.

local M = {}

M.scope = 'group'
M.title = 'Visibility & control'

local undo        = require('dcs_sms_me.undo')
local skin_helper = require('dcs_sms_me.skin_helper')
local me_refresh;   do local ok, m = pcall(require, 'dcs_sms_me.me_refresh'); if ok then me_refresh = m end end

local Static; do local ok, m = pcall(require, 'Static'); if ok then Static = m end end
local Button; do local ok, m = pcall(require, 'Button'); if ok then Button = m end end

-- ---------------------------------------------------------------------------
-- Property metadata
-- ---------------------------------------------------------------------------

-- Order = display order (top-to-bottom, left-to-right in the 2×3 grid).
local PROPS = {
    { field = 'hidden',          label = 'Hidden on map'     },
    { field = 'hiddenOnPlanner', label = 'Hidden on planner' },
    { field = 'hiddenOnMFD',     label = 'Hidden on MFD'     },
    { field = 'uncontrollable',  label = 'Game Master Only'  },
    { field = 'uncontrolled',    label = 'Uncontrolled'      },
    { field = 'lateActivation',  label = 'Late activation'   },
}

local PROP_BY_FIELD = {}
for _, p in ipairs(PROPS) do PROP_BY_FIELD[p.field] = p end

-- Which categories each field is shown for in the ME GUI. Entries here
-- match me_aircraft.lua / me_vehicle.lua / me_ship.lua's per-category
-- checkbox visibility.
local APPLIES_TO = {
    hidden          = { plane = true, helicopter = true, vehicle = true, ship = true, static = true, train = true },
    hiddenOnPlanner = { plane = true, helicopter = true },
    hiddenOnMFD     = { plane = true, helicopter = true },
    uncontrollable  = { plane = true, helicopter = true, vehicle = true, ship = true },
    uncontrolled    = { plane = true, helicopter = true },
    lateActivation  = { plane = true, helicopter = true, vehicle = true, ship = true },
}

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------
--
-- entities: array of group dicts (the host's get_checked() result)
-- settings: map { field = bool } -- only fields the user explicitly set
--           ON or OFF; LEAVE-state properties are absent
-- categories: optional map { entity = category_string } for applicability
--             lookup. When nil/empty, every entity is treated as
--             category 'unknown' which matches no APPLIES_TO entry -- so
--             nothing applies. The host always passes its W.categories.
function M._apply(entities, settings, categories)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, not_applicable = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end
    if type(settings) ~= 'table' or next(settings) == nil then
        return {
            changed = 0, not_applicable = 0, changed_rows = {},
            nothing_to_apply = true,
            toast = 'Nothing to apply', sev = 'warning',
        }
    end

    categories = categories or {}

    local changed_rows = {}
    local not_applicable_entities = 0
    local refreshed = {}  -- entity -> true, so we refresh each entity once even if multiple fields changed

    for _, e in ipairs(entities) do
        local cat = categories[e] or 'unknown'
        local entity_had_inapplicable = false
        for field, target_value in pairs(settings) do
            local applies = PROP_BY_FIELD[field] and APPLIES_TO[field] and APPLIES_TO[field][cat]
            if applies then
                -- Capture current value BEFORE the mutation. Non-boolean
                -- current values (e.g. hiddenOnMFD's {} default on a
                -- freshly-created group) normalize to false in the
                -- snapshot so undo restores a boolean rather than a
                -- stale table reference.
                local old_value = e[field]
                if type(old_value) ~= 'boolean' then old_value = false end

                e[field] = target_value and true or false

                changed_rows[#changed_rows + 1] = {
                    entity = e,
                    field  = field,
                    old    = old_value,
                }
                refreshed[e] = true
            else
                entity_had_inapplicable = true
            end
        end
        if entity_had_inapplicable then
            not_applicable_entities = not_applicable_entities + 1
        end
    end

    -- Per-entity visibility refresh: mirrors what ED's own "HIDDEN ON
    -- MAP" checkbox handler does -- MapWindow.updateHiddenGroup removes
    -- the symbol and only recreates it when g.hidden is false.
    -- update_group_map_objects / recreate_group_view alone don't drop
    -- the icon when hidden flips to true. We call this for ANY touched
    -- entity (cheap; only fields we care about visually are `hidden`
    -- and possibly `lateActivation`, but the wrapper is safe to call
    -- in all cases).
    if me_refresh and type(me_refresh.update_hidden_group) == 'function' then
        for e in pairs(refreshed) do pcall(me_refresh.update_hidden_group, e) end
    end
    -- If the user has a group panel open in the right pane and one of
    -- the modified groups happens to be the actively-selected one, the
    -- panel's checkboxes will now reflect the new state. No-op for the
    -- other categories.
    if me_refresh and type(me_refresh.refresh_group_panels) == 'function' and #changed_rows > 0 then
        pcall(me_refresh.refresh_group_panels)
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.toggle_group_flags', { rows = changed_rows })
    end

    local changed = #changed_rows
    local result = {
        changed        = changed,
        not_applicable = not_applicable_entities,
        changed_rows   = changed_rows,
    }

    if changed == 0 and not_applicable_entities > 0 then
        result.toast = 'Nothing applicable'
        result.sev   = 'warning'
    else
        local toast = (changed == 1) and '1 flag change' or string.format('%d flag changes', changed)
        if not_applicable_entities > 0 then
            toast = toast .. string.format(' · %d not applicable', not_applicable_entities)
        end
        result.toast = toast
        result.sev   = 'success'
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Undo handler -- registered at module load. Restores each row's old
-- value directly. Reverse-iterates so a multi-field change on a single
-- entity unwinds in the opposite order it applied.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.toggle_group_flags', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.toggle_group_flags undo snapshot'
    end
    local refreshed = {}
    for i = #snapshot.rows, 1, -1 do
        local r = snapshot.rows[i]
        if r and r.entity and r.field then
            r.entity[r.field] = r.old and true or false
            refreshed[r.entity] = true
        end
    end
    if me_refresh and type(me_refresh.update_hidden_group) == 'function' then
        for e in pairs(refreshed) do pcall(me_refresh.update_hidden_group, e) end
    end
    if me_refresh and type(me_refresh.refresh_group_panels) == 'function' then
        pcall(me_refresh.refresh_group_panels)
    end
    return true
end)

-- ---------------------------------------------------------------------------
-- Widget construction
-- ---------------------------------------------------------------------------

-- Internal tri-state. 0 = LEAVE, 1 = ON, 2 = OFF. Cycle next = (cur+1) % 3.
local STATE_LEAVE, STATE_ON, STATE_OFF = 0, 1, 2

local STATE_SUFFIX = {
    [STATE_LEAVE] = '—',
    [STATE_ON]    = 'ON',
    [STATE_OFF]   = 'OFF',
}

local LAYOUT = {
    PAD_X     = 8,
    GAP_X     = 6,
    GAP_Y     = 4,
    TITLE_H   = 22,
    ROW_H     = 24,
    APPLY_W   = 100,
    FOOTER_PAD = 6,
}

local function form_height()
    local L = LAYOUT
    -- title + two rows of state buttons + one row for Apply + footer pad
    return L.TITLE_H + L.GAP_Y + L.ROW_H + L.GAP_Y + L.ROW_H + L.GAP_Y + L.ROW_H + L.FOOTER_PAD
end

function M.new(parent_raw, get_checked, on_after_apply, get_categories)
    if not parent_raw then return nil end

    local owned = {}
    local function add(widget)
        if widget then owned[#owned + 1] = widget; pcall(parent_raw.insertWidget, parent_raw, widget) end
        return widget
    end

    -- Title
    local title_lbl
    if Static and Static.new then
        local ok, s = pcall(Static.new, M.title)
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); title_lbl = add(s) end
    end

    -- State buttons, one per property, in PROPS order.
    -- property_state[field] = STATE_*
    local property_state = {}
    local btn_by_field   = {}

    local function set_state(field, new_state)
        property_state[field] = new_state
        local btn = btn_by_field[field]
        local label = PROP_BY_FIELD[field].label
        local suffix = STATE_SUFFIX[new_state] or STATE_SUFFIX[STATE_LEAVE]
        if btn and btn.setText then pcall(btn.setText, btn, label .. ' ' .. suffix) end
    end

    local function reset_all_states()
        for _, p in ipairs(PROPS) do set_state(p.field, STATE_LEAVE) end
    end

    for _, p in ipairs(PROPS) do
        local btn
        if Button and Button.new then
            local ok, b = pcall(Button.new)
            if ok and b then
                skin_helper.apply(b, 'dtc_button')
                btn = add(b)
            end
        end
        btn_by_field[p.field] = btn
        property_state[p.field] = STATE_LEAVE
        -- Set initial label.
        if btn and btn.setText then pcall(btn.setText, btn, p.label .. ' ' .. STATE_SUFFIX[STATE_LEAVE]) end

        if btn and btn.addMouseDownCallback then
            local field = p.field
            pcall(btn.addMouseDownCallback, btn, function()
                pcall(function()
                    local cur = property_state[field] or STATE_LEAVE
                    local next_state = (cur + 1) % 3
                    set_state(field, next_state)
                end)
            end)
        end
    end

    -- Apply button
    local apply_btn
    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Apply') end
            apply_btn = add(b)
        end
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local settings = {}
                for _, p in ipairs(PROPS) do
                    local st = property_state[p.field]
                    if st == STATE_ON then
                        settings[p.field] = true
                    elseif st == STATE_OFF then
                        settings[p.field] = false
                    end
                end
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local categories = (type(get_categories) == 'function') and get_categories() or {}
                local result = M._apply(entities, settings, categories)
                if type(on_after_apply) == 'function' then on_after_apply(result) end
                -- After any successful apply, reset all controls so the next
                -- batch starts from a clean LEAVE state.
                if result and result.changed and result.changed > 0 then
                    reset_all_states()
                end
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

        -- 3 columns of equal width across the form's content area.
        local content_w = w - 2 * L.PAD_X
        local col_w = math.floor((content_w - 2 * L.GAP_X) / 3)
        if col_w < 60 then col_w = 60 end

        local row1_y = y + L.TITLE_H + L.GAP_Y
        local row2_y = row1_y + L.ROW_H + L.GAP_Y

        -- Place the 6 state buttons: PROPS[1..3] on row 1, PROPS[4..6] on row 2.
        for i = 1, 6 do
            local p = PROPS[i]
            if p then
                local btn = btn_by_field[p.field]
                local col = ((i - 1) % 3)
                local px = x + L.PAD_X + col * (col_w + L.GAP_X)
                local py = (i <= 3) and row1_y or row2_y
                set(btn, px, py, col_w, L.ROW_H)
            end
        end

        -- Apply button: right-anchored on a third row below the grid.
        local apply_y = row2_y + L.ROW_H + L.GAP_Y
        set(apply_btn, x + w - L.PAD_X - L.APPLY_W, apply_y, L.APPLY_W, L.ROW_H)
    end

    return panel
end

return M
