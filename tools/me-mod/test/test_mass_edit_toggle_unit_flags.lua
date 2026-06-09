-- Standalone test for mass_edit_forms.toggle_unit_flags.
-- Tests M._apply (with an injected per-unit-type capability resolver),
-- the DB-backed default resolver, and the registered undo handler.
--
-- The form writes per-unit fields directly (playerCanDrive / coldAtStart),
-- gated by category ('vehicle') and per-unit-type capability (drivable /
-- non-infantry). These tests verify field state on unit dicts directly.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')

-- Stub me_mission for transitive requires.
package.preload['me_mission'] = function() return mock end

-- Stub selection for undo.lua's transitive prefab_ops requires.
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end

-- Stub me_refresh so the form's refresh calls are recorded but no-op'd.
local panel_refresh_calls = 0
package.preload['dcs_sms_me.me_refresh'] = function()
    return {
        refresh_group_panels = function() panel_refresh_calls = panel_refresh_calls + 1 end,
    }
end

local form = require('dcs_sms_me.mass_edit_forms.toggle_unit_flags')
local undo = require('dcs_sms_me.undo')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function reset()
    panel_refresh_calls = 0
    undo.clear()
    form._set_caps_resolver(nil)  -- restore default between cases
end

-- Helper: build a categories map from a list of (entity, category) pairs.
local function categories_map(pairs_list)
    local out = {}
    for _, p in ipairs(pairs_list) do out[p[1]] = p[2] end
    return out
end

-- Helper: first unit of a freshly-added vehicle group.
local function veh_unit(name, utype)
    local g = mock.add_vehicle({ name = name, unit_type = utype })
    return g.units[1]
end

-- A capability resolver keyed on unit type, for the injected-resolver cases.
-- 'tank'    -> drivable, non-infantry
-- 'truck'   -> not drivable, non-infantry
-- 'soldier' -> not drivable, infantry
local CAPS = {
    tank    = { playerCanDrive = true,  coldAtStart = true  },
    truck   = { playerCanDrive = false, coldAtStart = true  },
    soldier = { playerCanDrive = false, coldAtStart = false },
}
local function inject_type_caps()
    form._set_caps_resolver(function(u)
        return CAPS[u.type] or { playerCanDrive = false, coldAtStart = false }
    end)
end

-- ---------------------------------------------------------------------------
-- Module shape
-- ---------------------------------------------------------------------------
do
    check('form.scope = unit',          form.scope == 'unit')
    check('form.applies_to vehicle',    form.applies_to and form.applies_to.vehicle == true)
    check('form.applies_to not plane',  not (form.applies_to and form.applies_to.plane))
    check('form.title non-empty',       type(form.title) == 'string' and #form.title > 0)
    check('form.new is a function',     type(form.new) == 'function')
    check('form._apply is a function',  type(form._apply) == 'function')
end

-- Case 1: empty selection -> nothing_selected.
do
    reset()
    local result = form._apply({}, { playerCanDrive = true }, {})
    check('empty: changed=0',                  result.changed == 0)
    check('empty: nothing_selected',           result.nothing_selected == true)
    check('empty: toast = "Nothing selected"', result.toast == 'Nothing selected')
end

-- Case 2: empty settings (all LEAVE) -> nothing_to_apply.
do
    reset()
    mock.new_mission()
    inject_type_caps()
    local u = veh_unit('A', 'tank')
    local result = form._apply({ u }, {}, categories_map({ { u, 'vehicle' } }))
    check('no-settings: changed=0',            result.changed == 0)
    check('no-settings: nothing_to_apply',     result.nothing_to_apply == true)
end

-- Case 3: drivable tank, playerCanDrive ON -> field flipped, changed=1.
do
    reset()
    mock.new_mission()
    inject_type_caps()
    local u = veh_unit('A', 'tank')
    u.playerCanDrive = false
    local result = form._apply({ u }, { playerCanDrive = true }, categories_map({ { u, 'vehicle' } }))
    check('drive-on: changed=1',                result.changed == 1)
    check('drive-on: not_applicable=0',         (result.not_applicable or 0) == 0)
    check('drive-on: u.playerCanDrive=true',    u.playerCanDrive == true)
    check('drive-on: toast = "1 flag change"',  result.toast == '1 flag change')
    check('drive-on: undo recorded',            undo.has_record() == true)
    check('drive-on: refresh_group_panels called', panel_refresh_calls == 1)
end

-- Case 4: coldAtStart ON on a non-infantry vehicle -> field flipped.
do
    reset()
    mock.new_mission()
    inject_type_caps()
    local u = veh_unit('A', 'truck')
    u.coldAtStart = false
    local result = form._apply({ u }, { coldAtStart = true }, categories_map({ { u, 'vehicle' } }))
    check('cold-on: changed=1',            result.changed == 1)
    check('cold-on: u.coldAtStart=true',   u.coldAtStart == true)
end

-- Case 5: Infantry unit + coldAtStart ON -> not applicable, untouched.
do
    reset()
    mock.new_mission()
    inject_type_caps()
    local u = veh_unit('A', 'soldier')
    u.coldAtStart = false
    local result = form._apply({ u }, { coldAtStart = true }, categories_map({ { u, 'vehicle' } }))
    check('infantry-cold: changed=0',           result.changed == 0)
    check('infantry-cold: not_applicable=1',    result.not_applicable == 1)
    check('infantry-cold: u.coldAtStart untouched', u.coldAtStart == false)
    check('infantry-cold: toast = "Nothing applicable"', result.toast == 'Nothing applicable')
end

-- Case 6: non-drivable unit + playerCanDrive ON -> not applicable.
do
    reset()
    mock.new_mission()
    inject_type_caps()
    local u = veh_unit('A', 'truck')  -- not drivable
    u.playerCanDrive = false
    local result = form._apply({ u }, { playerCanDrive = true }, categories_map({ { u, 'vehicle' } }))
    check('nondrive: changed=0',                result.changed == 0)
    check('nondrive: not_applicable=1',         result.not_applicable == 1)
    check('nondrive: u.playerCanDrive untouched', u.playerCanDrive == false)
end

-- Case 7: non-vehicle unit (plane) -> both fields not applicable.
do
    reset()
    mock.new_mission()
    inject_type_caps()
    local g = mock.add_plane({ name = 'P', unit_type = 'F-16C_50' })
    local u = g.units[1]
    u.playerCanDrive = false
    u.coldAtStart    = false
    local result = form._apply({ u },
        { playerCanDrive = true, coldAtStart = true },
        categories_map({ { u, 'plane' } }))
    check('plane-unit: changed=0',              result.changed == 0)
    check('plane-unit: not_applicable=1',       result.not_applicable == 1)
    check('plane-unit: playerCanDrive untouched', u.playerCanDrive == false)
    check('plane-unit: coldAtStart untouched',  u.coldAtStart == false)
end

-- Case 8: mixed batch -- tank (both apply) + soldier (cold n/a, drive n/a).
-- playerCanDrive + coldAtStart both ON.
do
    reset()
    mock.new_mission()
    inject_type_caps()
    local tank    = veh_unit('T', 'tank')
    local soldier = veh_unit('S', 'soldier')
    tank.playerCanDrive, tank.coldAtStart = false, false
    soldier.playerCanDrive, soldier.coldAtStart = false, false
    local result = form._apply({ tank, soldier },
        { playerCanDrive = true, coldAtStart = true },
        categories_map({ { tank, 'vehicle' }, { soldier, 'vehicle' } }))
    -- tank: 2 (unit,field) changes; soldier: 0 (both skipped) -> not_applicable
    check('mixed: changed=2',                   result.changed == 2)
    check('mixed: not_applicable=1',            result.not_applicable == 1)
    check('mixed: tank.playerCanDrive=true',    tank.playerCanDrive == true)
    check('mixed: tank.coldAtStart=true',       tank.coldAtStart == true)
    check('mixed: soldier.playerCanDrive untouched', soldier.playerCanDrive == false)
    check('mixed: soldier.coldAtStart untouched',    soldier.coldAtStart == false)
end

-- Case 9: undo restores fields in reverse order.
do
    reset()
    mock.new_mission()
    inject_type_caps()
    local u = veh_unit('A', 'tank')
    u.playerCanDrive = false
    u.coldAtStart    = false
    local result = form._apply({ u },
        { playerCanDrive = true, coldAtStart = true },
        categories_map({ { u, 'vehicle' } }))
    check('undo-setup: changed=2',              result.changed == 2)
    check('undo-setup: playerCanDrive=true',    u.playerCanDrive == true)
    check('undo-setup: coldAtStart=true',       u.coldAtStart == true)
    local ok = undo.undo()
    check('undo: ok=true',                      ok == true)
    check('undo: playerCanDrive restored false', u.playerCanDrive == false)
    check('undo: coldAtStart restored false',    u.coldAtStart == false)
end

-- Case 10: the DEFAULT (DB-backed) resolver. Stub me_db_api.unit_by_type
-- with a drivable tank and an Infantry-tagged soldier and verify the form
-- reads enablePlayerCanDrive + the 'Infantry' tag correctly (no injection).
do
    reset()  -- restores default resolver
    package.loaded['me_db_api'] = {
        unit_by_type = {
            ['M-1 Abrams'] = { enablePlayerCanDrive = true,  tags = { 'Vehicles', 'Tank' } },
            ['Soldier M4'] = { enablePlayerCanDrive = false, tags = { 'Infantry' } },
        },
    }
    mock.new_mission()
    local tank    = veh_unit('T', 'M-1 Abrams')
    local soldier = veh_unit('S', 'Soldier M4')
    tank.playerCanDrive, tank.coldAtStart = false, false
    soldier.playerCanDrive, soldier.coldAtStart = false, false
    local result = form._apply({ tank, soldier },
        { playerCanDrive = true, coldAtStart = true },
        categories_map({ { tank, 'vehicle' }, { soldier, 'vehicle' } }))
    -- tank: drivable + non-infantry -> both apply (2 changes).
    -- soldier: not drivable + infantry -> both skipped -> not_applicable.
    check('db-resolver: changed=2',             result.changed == 2)
    check('db-resolver: not_applicable=1',      result.not_applicable == 1)
    check('db-resolver: tank.playerCanDrive=true', tank.playerCanDrive == true)
    check('db-resolver: tank.coldAtStart=true',    tank.coldAtStart == true)
    check('db-resolver: soldier untouched (drive)', soldier.playerCanDrive == false)
    check('db-resolver: soldier untouched (cold)',  soldier.coldAtStart == false)
    package.loaded['me_db_api'] = nil
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All toggle_unit_flags tests passed.')
