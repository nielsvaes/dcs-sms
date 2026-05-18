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

    -- Lightweight per-entity view refresh once (data-side only -- these
    -- flags don't change icon appearance, only visibility state). One
    -- refresh per entity, regardless of how many fields it had touched.
    if me_refresh and type(me_refresh.refresh_group_view) == 'function' then
        for e in pairs(refreshed) do pcall(me_refresh.refresh_group_view, e) end
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
        local toast = string.format('%d flag changes', changed)
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
    if me_refresh and type(me_refresh.refresh_group_view) == 'function' then
        for e in pairs(refreshed) do pcall(me_refresh.refresh_group_view, e) end
    end
    return true
end)

-- ---------------------------------------------------------------------------
-- Widget construction -- stub for now. Real implementation lands in
-- Task 3 of the plan. Returning nil here matches the contract used
-- elsewhere when dxgui requires fail to resolve (e.g. under test).
-- ---------------------------------------------------------------------------

function M.new(parent_raw, get_checked, on_after_apply, get_categories)
    -- Task 3 will replace this stub with the real 2×3 button grid.
    return nil
end

return M
