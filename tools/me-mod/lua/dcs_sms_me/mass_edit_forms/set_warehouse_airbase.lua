-- mass_edit_forms/set_warehouse_airbase.lua -- Mass Edit form: bulk-edit
-- airbase warehouse pools via three tri-state buttons (Aircraft / Liquids
-- / Equipment, each LEAVE / ON / OFF).
--
-- LEAVE skips the category. ON flips the matching unlimited* flag
-- to true (pool counts left as-is — flags override at runtime). OFF
-- flips the flag(s) to false AND zeroes the pool counts for every type
-- already present on the warehouse entry. Reuses the project's
-- tri_state_button widget verbatim — STATE_ON = "unlimited the category",
-- STATE_OFF = "empty the category". Row labels ("Aircraft" / "Liquids"
-- / "Equipment") provide context so the ON/OFF cycle reads as
-- "unlimited / empty" in this form.

local M = {}

M.scope = 'airbase'
M.title = 'Set warehouse'

local undo            = require('dcs_sms_me.undo')
local warehouse_ops   = require('dcs_sms_me.warehouse_ops')
local skin_helper     = require('dcs_sms_me.skin_helper')
local tri_state_button= require('dcs_sms_me.tri_state_button')

local Static; do local ok, m = pcall(require, 'Static'); if ok then Static = m end end
local Button; do local ok, m = pcall(require, 'Button'); if ok then Button = m end end

-- Category-to-warehouse-field mapping. OFF zeroes every key whose
-- VALUE is a numeric pool count OR every entry in a sub-table whose
-- .count field is numeric. Defensive against theatre-specific schema
-- variation: we only mutate keys that ALREADY exist on the entry.
local CATEGORY_FIELDS = {
    aircraft = {
        flags        = { 'unlimitedAircrafts' },
        scalar_keys  = {},
        nested_keys  = { 'aircrafts' },
    },
    liquids = {
        flags        = { 'unlimitedFuel', 'unlimitedAviationFuel' },
        scalar_keys  = { 'gasoline', 'diesel', 'methanol_mixture', 'jet_fuel' },
        nested_keys  = {},
    },
    equipment = {
        flags        = { 'unlimitedMunitions' },
        scalar_keys  = {},
        nested_keys  = { 'weapons' },
    },
}

local STATE_LEAVE = tri_state_button.STATE_LEAVE
local STATE_ON    = tri_state_button.STATE_ON
local STATE_OFF   = tri_state_button.STATE_OFF

-- Deep-copy helper used for undo snapshots. warehouse_ops.extract already
-- deep-copies in production, but the test harness uses a shallow mock.
-- Owning the copy here makes undo robust regardless of the extract depth.
local function deep_copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k2, v2 in pairs(v) do out[k2] = deep_copy(v2) end
    return out
end

-- Mutate `entry` per the choice (LEAVE | ON | OFF) for the given
-- category. No-op on LEAVE. Returns true if any field was changed.
-- ON  → flip unlimited* flags to true.
-- OFF → flip unlimited* flags to false AND zero the pool counts.
local function apply_category(entry, category, choice)
    if choice == STATE_LEAVE then return false end
    local mapping = CATEGORY_FIELDS[category]
    if not mapping then return false end
    local target_flag = (choice == STATE_ON)
    for _, flag in ipairs(mapping.flags) do
        if entry[flag] ~= nil then entry[flag] = target_flag end
    end
    if choice == STATE_OFF then
        for _, key in ipairs(mapping.scalar_keys) do
            if type(entry[key]) == 'number' then entry[key] = 0 end
        end
        for _, nkey in ipairs(mapping.nested_keys) do
            local nested = entry[nkey]
            if type(nested) == 'table' then
                for _, sub in pairs(nested) do
                    if type(sub) == 'table' and type(sub.count) == 'number' then
                        sub.count = 0
                    end
                end
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Apply logic (extracted for testability).
-- ---------------------------------------------------------------------------

function M._apply(entities, choices)
    choices = choices or {}
    local any_active = false
    for _, cat in ipairs({'aircraft', 'liquids', 'equipment'}) do
        if choices[cat] and choices[cat] ~= STATE_LEAVE then any_active = true; break end
    end
    if not any_active then
        return { ok = false, toast = 'no categories selected', sev = 'warning' }
    end
    if type(entities) ~= 'table' or #entities == 0 then
        return { ok = false, toast = 'no airbases checked', sev = 'warning' }
    end

    local rows = {}
    local errors = 0
    for _, e in ipairs(entities) do
        local entry = warehouse_ops.extract(e.id)
        if entry then
            -- Capture an undo-snapshot BEFORE mutation. Deep-copy so
            -- nested sub-tables in the snapshot are fully independent
            -- of the entry we're about to mutate (guards against shallow-
            -- copy extract implementations, e.g. in the test harness).
            local snap = deep_copy(entry)
            local changed = false
            for _, cat in ipairs({'aircraft', 'liquids', 'equipment'}) do
                if apply_category(entry, cat, choices[cat] or STATE_LEAVE) then changed = true end
            end
            if changed then
                local ok = warehouse_ops.apply(e.id, entry)
                if ok then
                    rows[#rows + 1] = { id = e.id, prev_entry = snap }
                else
                    errors = errors + 1
                end
            end
        else
            errors = errors + 1
        end
    end

    if #rows > 0 then
        undo.record_generic('mass_edit.set_warehouse_airbase', { rows = rows })
    end

    local toast
    if errors == 0 then
        toast = string.format('%d airbase%s updated', #rows, #rows == 1 and '' or 's')
    else
        toast = string.format('%d ok, %d failed', #rows, errors)
    end
    return { ok = errors == 0, toast = toast, sev = errors == 0 and 'info' or 'warning' }
end

-- ---------------------------------------------------------------------------
-- Undo handler — re-apply prior entry per row, in reverse order.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.set_warehouse_airbase', function(payload)
    if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then
        return nil, 'invalid payload'
    end
    local errors = 0
    for i = #payload.rows, 1, -1 do
        local row = payload.rows[i]
        if row and row.id and row.prev_entry then
            local ok = warehouse_ops.apply(row.id, row.prev_entry)
            if not ok then errors = errors + 1 end
        end
    end
    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

-- ---------------------------------------------------------------------------
-- Mount.
-- ---------------------------------------------------------------------------

function M.mount(parent_raw, opts)
    opts = opts or {}
    local get_checked    = opts.get_checked    or function() return {} end
    local on_after_apply = opts.on_after_apply

    local owned = {}
    local function add(w) owned[#owned + 1] = w; pcall(parent_raw.insertWidget, parent_raw, w); return w end

    local function make_tri(label)
        local widget = tri_state_button.new(parent_raw, label)
        if widget then owned[#owned + 1] = widget end
        return widget
    end

    -- The tri-state buttons carry their own label text inline (e.g.
    -- "Aircraft —" / "Aircraft ON" / "Aircraft OFF"). Per-row Static
    -- labels are therefore omitted to avoid duplication.
    local aircraft_tri  = make_tri('Aircraft')
    local liquids_tri   = make_tri('Liquids')
    local equipment_tri = make_tri('Equipment')

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
                local choices = {
                    aircraft  = aircraft_tri  and aircraft_tri:get_state()  or STATE_LEAVE,
                    liquids   = liquids_tri   and liquids_tri:get_state()   or STATE_LEAVE,
                    equipment = equipment_tri and equipment_tri:get_state() or STATE_LEAVE,
                }
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local result = M._apply(entities, choices)
                if type(on_after_apply) == 'function' then on_after_apply(result) end
            end)
        end)
    end

    local TRI_W   = 160
    local BTN_W   = 90
    local ROW_H   = 24
    local PAD     = 4
    local NUM_ROWS = 3

    local panel = {
        widgets = owned,
        get_height = function() return ROW_H * NUM_ROWS + PAD * (NUM_ROWS - 1) + ROW_H + PAD end,
        set_bounds = function(_, x, y, w, _)
            local row_y = y
            local function place_row(tri)
                if tri and tri.set_bounds then pcall(tri.set_bounds, tri, x, row_y, TRI_W, ROW_H) end
                row_y = row_y + ROW_H + PAD
            end
            place_row(aircraft_tri)
            place_row(liquids_tri)
            place_row(equipment_tri)
            if apply_btn and apply_btn.setBounds then
                pcall(apply_btn.setBounds, apply_btn, x + w - BTN_W, row_y, BTN_W, ROW_H)
            end
        end,
        show = function() for _, w in ipairs(owned) do if w.setVisible then pcall(w.setVisible, w, true) end if w.show then pcall(w.show, w) end end end,
        hide = function() for _, w in ipairs(owned) do if w.setVisible then pcall(w.setVisible, w, false) end if w.hide then pcall(w.hide, w) end end end,
    }
    return panel
end

return M
