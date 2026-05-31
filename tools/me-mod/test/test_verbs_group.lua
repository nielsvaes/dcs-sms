-- test_verbs_group.lua — Lua-side unit tests for verbs/group_verbs.lua.
--
-- Covers: group_create_<plane|helicopter|vehicle|ship|static>, group_remove,
-- group_add_unit, group_remove_unit, group_set_*, group_list, group_get.
--
-- Run via:
--   cd tools/me-mod/test && lua5.1 test_verbs_group.lua
-- Or through the harness:
--   pwsh tools/me-mod/test/run-tests.ps1

local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path

local mock = require('mock_me_mission')
package.preload['me_mission']    = function() return mock end
package.preload['me_map_window'] = function() return mock end

-- terrain stub for group_create_ship water-surface check. Returns 'sea'
-- for any pos by default; tests that need a land surface override _surface.
local terrain_stub = { _surface = 'sea' }
function terrain_stub.GetSurfaceType(_x, _y) return terrain_stub._surface end
package.preload['terrain'] = function() return terrain_stub end

-- utils_common stub for group_set_formation. Mirrors the actions table the
-- real ME exposes (one numeric/string identifier per built-in formation).
package.preload['utils_common'] = function()
    return {
        actions = {
            offRoad    = 'OffRoad',
            onRoad     = 'OnRoad',
            rank       = 'Rank',
            cone       = 'Cone',
            vee        = 'Vee',
            diamond    = 'Diamond',
            echelonL   = 'EchelonL',
            echelonR   = 'EchelonR',
            customForm = 'CustomForm',
        },
    }
end

-- me_db_api stub.
--   templates    — used by group_set_formation's custom-template path.
--   unit_by_type — used by group_create_*'s type-existence guard against
--                  save-time crashes (me_mission.lua:setRequiredModules
--                  derefs unitDef._origin on nil for unknown types).
local me_db_api_stub = {
    templates = {
        ['Hawk SAM Battery'] = { name = 'Hawk SAM Battery', units = {} },
        ['SA-2 Battery']     = { name = 'SA-2 Battery',     units = {} },
    },
    unit_by_type = {
        ['F-16C_50']    = { _origin = '_core_' },
        ['F-14B']       = { _origin = '_core_' },
        ['UH-1H']       = { _origin = '_core_' },
        ['Hummer']      = { _origin = '_core_' },
        ['CVN_71']      = { _origin = '_core_' },
        ['Watchtower']  = { _origin = '_core_' },
        ['Hawk pcp']    = { _origin = '_core_' },
        ['Hawk sr']     = { _origin = '_core_' },
        ['cargo_crate'] = { _origin = '_core_' },
    },
}
package.preload['me_db_api'] = function() return me_db_api_stub end

-- me_payload + me_route stubs for group_set_country (livery fixup + airfield
-- re-attract). Track invocations so tests can assert they ran.
local me_payload_stub = { setDefaultLivery_calls = 0 }
function me_payload_stub.setDefaultLivery(u)
    me_payload_stub.setDefaultLivery_calls = me_payload_stub.setDefaultLivery_calls + 1
    -- Mimic real behavior: clear livery_id if country has no livery for u.type.
end
package.preload['me_payload'] = function() return me_payload_stub end

local me_route_stub = { attract_calls = 0 }
function me_route_stub.isAirfieldWaypoint(t)
    return t == 'TakeOff' or t == 'TakeOffParking' or t == 'TakeOffParkingHot'
            or t == 'Land' or t == 'LandingReFuAr'
end
function me_route_stub.attractToAirfield(_wp, _g)
    me_route_stub.attract_calls = me_route_stub.attract_calls + 1
end
package.preload['me_route'] = function() return me_route_stub end

package.path = here .. '../lua/?.lua;' .. here .. '../lua/?/init.lua;' .. package.path

local verbs = require('dcs_sms_me.verbs')

-- ============================================================
-- Test harness
-- ============================================================

local passed, failed, errors = 0, 0, {}

local function assert_eq(actual, expected, name)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(errors, string.format('%s: expected %s, got %s',
            name, tostring(expected), tostring(actual)))
    end
end

local function assert_true(cond, name)  assert_eq(cond and true or false, true,  name) end
local function assert_false(cond, name) assert_eq(cond and true or false, false, name) end

local function assert_contains(haystack, needle, name)
    if type(haystack) == 'string' and haystack:find(needle, 1, true) then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(errors, string.format('%s: expected string containing %q, got %s',
            name, needle, tostring(haystack)))
    end
end

-- ============================================================
-- group_create_plane
-- ============================================================

local function test_create_plane_happy()
    mock.new_mission()
    local r = verbs.group_create_plane({
        country = 'USA', type = 'F-16C_50',
        north = 1000, east = 2000,
        name = 'Hornet-1',
    })
    assert_true(r.ok, 'create_plane: ok')
    assert_eq(r.name, 'Hornet-1', 'create_plane: returns group name')
    assert_eq(r.country, 'USA', 'create_plane: returns country')
    assert_eq(r.side, 'blue', 'create_plane: returns side')
    assert_true(type(r.groupId) == 'number', 'create_plane: groupId number')
    assert_true(type(r.unitId) == 'number', 'create_plane: unitId number')
    -- Group landed in USA.plane.group
    local list = mock.mission.coalition.blue.country[1].plane.group
    assert_eq(#list, 1, 'create_plane: group appended to USA.plane.group')
    local g = list[1]
    assert_eq(g.x, 1000, 'create_plane: g.x = north')
    assert_eq(g.y, 2000, 'create_plane: g.y = east')
    assert_eq(g.units[1].alt, 8000, 'create_plane: default alt')
    assert_eq(g.units[1].alt_type, 'BARO', 'create_plane: default alt_type')
    assert_eq(g.units[1].speed, 220, 'create_plane: default speed')
    assert_eq(g.frequency, 251, 'create_plane: default frequency')
end

local function test_create_plane_default_name()
    mock.new_mission()
    local r = verbs.group_create_plane({
        country = 'USA', type = 'F-16C_50', north = 0, east = 0,
    })
    assert_true(r.ok, 'create_plane default name: ok')
    assert_eq(r.name, 'F-16C_50 #001', 'create_plane default name: <type> #001')
end

local function test_create_plane_name_collision_uniquifies()
    mock.new_mission()
    verbs.group_create_plane({ country = 'USA', type = 'F-16C_50',
        north = 0, east = 0, name = 'Hornet-1' })
    local r2 = verbs.group_create_plane({ country = 'USA', type = 'F-16C_50',
        north = 0, east = 0, name = 'Hornet-1' })
    assert_true(r2.ok, 'create_plane collision: ok')
    assert_eq(r2.name, 'Hornet-1 #2', 'create_plane collision: name uniquified')
end

local function test_create_plane_overrides()
    mock.new_mission()
    local r = verbs.group_create_plane({
        country = 'USA', type = 'F-16C_50', north = 0, east = 0,
        alt = 5000, alt_type = 'RADIO', speed = 180, frequency = 305,
        skill = 'Excellent', livery = 'Aggressors', onboard_num = '042',
    })
    assert_true(r.ok, 'create_plane overrides: ok')
    local g = mock.mission.coalition.blue.country[1].plane.group[1]
    assert_eq(g.units[1].alt, 5000, 'override: alt')
    assert_eq(g.units[1].alt_type, 'RADIO', 'override: alt_type')
    assert_eq(g.units[1].speed, 180, 'override: speed')
    assert_eq(g.frequency, 305, 'override: frequency')
    assert_eq(g.units[1].skill, 'Excellent', 'override: skill')
    assert_eq(g.units[1].livery_id, 'Aggressors', 'override: livery')
    assert_eq(g.units[1].onboard_num, '042', 'override: onboard_num')
end

-- gh #68 item 3: --task overrides the default group task at create-time.
local function test_create_plane_task_default_and_override()
    mock.new_mission()
    verbs.group_create_plane({ country = 'USA', type = 'F-16C_50', north = 0, east = 0, name = 'T1' })
    assert_eq(mock.mission.coalition.blue.country[1].plane.group[1].task, 'Nothing',
              'create_plane: default task Nothing')

    mock.new_mission()
    verbs.group_create_plane({ country = 'USA', type = 'F-16C_50', north = 0, east = 0,
        name = 'T2', task = 'CAS' })
    assert_eq(mock.mission.coalition.blue.country[1].plane.group[1].task, 'CAS',
              'create_plane: task overridden')
end

local function test_create_vehicle_task_override()
    mock.new_mission()
    verbs.group_create_vehicle({ country = 'USA', type = 'Hummer', north = 0, east = 0,
        name = 'V1', task = 'Ground Attack' })
    assert_eq(mock.mission.coalition.blue.country[1].vehicle.group[1].task, 'Ground Attack',
              'create_vehicle: task overridden')
end

local function test_create_plane_arg_validation()
    mock.new_mission()
    assert_false(verbs.group_create_plane(nil).ok, 'create_plane: nil args rejected')
    assert_false(verbs.group_create_plane('s').ok, 'create_plane: string args rejected')
    assert_false(verbs.group_create_plane({}).ok, 'create_plane: empty args rejected')
    local r1 = verbs.group_create_plane({ type = 'F-16C_50', north = 0, east = 0 })
    assert_contains(r1.error, 'country', 'create_plane: missing country')
    local r2 = verbs.group_create_plane({ country = 'USA', north = 0, east = 0 })
    assert_contains(r2.error, 'type', 'create_plane: missing type')
    local r3 = verbs.group_create_plane({ country = 'USA', type = 'F-16C_50', east = 0 })
    assert_contains(r3.error, 'north', 'create_plane: missing north')
    local r4 = verbs.group_create_plane({ country = 'USA', type = 'F-16C_50', north = 0 })
    assert_contains(r4.error, 'east', 'create_plane: missing east')
    local r5 = verbs.group_create_plane({ country = '', type = 'F-16C_50', north = 0, east = 0 })
    assert_contains(r5.error, 'country', 'create_plane: empty country rejected')
    local r6 = verbs.group_create_plane({ country = 'USA', type = 'F-16C_50',
        north = '0', east = 0 })
    assert_contains(r6.error, 'north', 'create_plane: string north rejected')
end

local function test_create_plane_country_not_in_tree()
    mock.new_mission()
    local r = verbs.group_create_plane({
        country = 'Atlantis', type = 'F-16C_50', north = 0, east = 0 })
    assert_false(r.ok, 'create_plane: missing country fails')
    assert_contains(r.error, 'Atlantis', 'create_plane: error names country')
end

-- ============================================================
-- Unit-type-existence guard (the save-crash class)
--
-- DCS's save serializer at me_mission.lua:setRequiredModules derefs
-- unitDef._origin on a nil unitDef when a unit's type isn't in
-- me_db.unit_by_type, which freezes File→Save. Every create-* verb +
-- group_add_unit refuse unknown types up front rather than producing a
-- save-crashing group.
-- ============================================================

local function test_create_plane_unknown_type_rejected()
    mock.new_mission()
    local r = verbs.group_create_plane({
        country = 'USA', type = 'F-99 Imaginary', north = 0, east = 0 })
    assert_false(r.ok, 'unknown plane type: rejected')
    assert_contains(r.error, 'unknown unit type', 'unknown plane type: error message')
    assert_contains(r.error, 'F-99 Imaginary', 'unknown plane type: names the type')
end

local function test_create_helicopter_unknown_type_rejected()
    mock.new_mission()
    local r = verbs.group_create_helicopter({
        country = 'USA', type = 'Helo-Of-The-Imagination', north = 0, east = 0 })
    assert_false(r.ok, 'unknown helo type: rejected')
    assert_contains(r.error, 'unknown unit type', 'unknown helo type: error message')
end

local function test_create_vehicle_unknown_type_rejected()
    mock.new_mission()
    -- This is the exact bug pattern that triggered the work: 'M2A2 Bradley'
    -- looks plausible (real DCS uses 'M-2 Bradley') but is missing from
    -- me_db.unit_by_type, so save would crash.
    local r = verbs.group_create_vehicle({
        country = 'USA', type = 'M2A2 Bradley', north = 0, east = 0 })
    assert_false(r.ok, 'M2A2 Bradley typo: rejected')
    assert_contains(r.error, 'M2A2 Bradley', 'M2A2 Bradley typo: names the type')
    assert_contains(r.error, 'crash File', 'M2A2 Bradley typo: warns about save crash')
end

local function test_create_ship_unknown_type_rejected()
    mock.new_mission()
    local r = verbs.group_create_ship({
        country = 'USA', type = 'SS Imaginary', north = 0, east = 0 })
    assert_false(r.ok, 'unknown ship type: rejected')
    assert_contains(r.error, 'unknown unit type', 'unknown ship type: error message')
end

local function test_create_static_unknown_type_rejected()
    mock.new_mission()
    local r = verbs.group_create_static({
        country = 'USA', type = 'Fictional Bunker', north = 0, east = 0 })
    assert_false(r.ok, 'unknown static type: rejected')
    assert_contains(r.error, 'Fictional Bunker', 'unknown static type: names the type')
end

local function test_add_unit_unknown_type_rejected()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'Convoy', unit_type = 'Hawk pcp' })
    local r = verbs.group_add_unit({ name = 'Convoy', type = 'Nonexistent Tank' })
    assert_false(r.ok, 'add_unit unknown type: rejected')
    assert_contains(r.error, 'Nonexistent Tank', 'add_unit unknown type: names the type')
end

local function test_add_unit_inherits_type_no_validation()
    -- When --type is omitted, group_add_unit inherits the last unit's type.
    -- Validating an already-existing type here would be useless (the group
    -- is already in the mission), so we explicitly DON'T validate that path.
    mock.new_mission()
    -- Seed the group with a type that's NOT in the unit_by_type stub.
    -- (In practice the group would only exist if it was created back when
    -- the verb's validation didn't reject it — e.g. a loaded older .miz.)
    local g = mock.add_vehicle({ name = 'Legacy', unit_type = 'Hawk pcp' })
    -- Mutate post-creation to simulate a type that wouldn't pass validation.
    g.units[1].type = 'Some Pre-Existing Type'
    local r = verbs.group_add_unit({ name = 'Legacy' })  -- no type arg
    assert_true(r.ok, 'add_unit inheriting type: not rejected')
end

-- ============================================================
-- group_create_helicopter
-- ============================================================

local function test_create_helicopter_happy()
    mock.new_mission()
    local r = verbs.group_create_helicopter({
        country = 'USA', type = 'UH-1H', north = 100, east = 200, name = 'Huey-1' })
    assert_true(r.ok, 'create_helo: ok')
    assert_eq(r.name, 'Huey-1', 'create_helo: name')
    local g = mock.mission.coalition.blue.country[1].helicopter.group[1]
    assert_eq(g.units[1].alt, 1000, 'create_helo: default alt')
    assert_eq(g.units[1].speed, 50, 'create_helo: default speed')
    assert_eq(g.frequency, 127.5, 'create_helo: default frequency')
    assert_eq(g.task, 'Transport', 'create_helo: task = Transport')
end

local function test_create_helicopter_arg_validation()
    mock.new_mission()
    assert_false(verbs.group_create_helicopter({}).ok, 'create_helo: empty')
    local r = verbs.group_create_helicopter({
        country = 'Atlantis', type = 'UH-1H', north = 0, east = 0 })
    assert_false(r.ok, 'create_helo: bad country')
end

-- ============================================================
-- group_create_vehicle
-- ============================================================

local function test_create_vehicle_happy()
    mock.new_mission()
    local r = verbs.group_create_vehicle({
        country = 'USA', type = 'Hummer', north = 500, east = 600, name = 'HV-1' })
    assert_true(r.ok, 'create_vehicle: ok')
    local g = mock.mission.coalition.blue.country[1].vehicle.group[1]
    assert_eq(g.task, 'Ground Nothing', 'create_vehicle: task = Ground Nothing')
    assert_eq(g.route.points[1].action, 'Off Road', 'create_vehicle: action = Off Road')
    assert_eq(g.route.points[1].speed, 0, 'create_vehicle: speed = 0')
    assert_eq(g.route.points[1].speed_locked, true, 'create_vehicle: speed_locked')
end

local function test_create_vehicle_arg_validation()
    mock.new_mission()
    local r = verbs.group_create_vehicle({ country = 'USA', north = 0, east = 0 })
    assert_false(r.ok, 'create_vehicle: missing type')
    assert_contains(r.error, 'type', 'create_vehicle: type error')
end

-- ============================================================
-- group_create_ship
-- ============================================================

local function test_create_ship_happy_over_water()
    mock.new_mission()
    terrain_stub._surface = 'sea'
    local r = verbs.group_create_ship({
        country = 'USA', type = 'CVN_71', north = 0, east = 0, name = 'CV-1' })
    assert_true(r.ok, 'create_ship: ok over sea')
    local g = mock.mission.coalition.blue.country[1].ship.group[1]
    assert_eq(g.route.points[1].depth, 0, 'create_ship: depth field present')
end

local function test_create_ship_refused_on_land()
    mock.new_mission()
    terrain_stub._surface = 'land'
    local r = verbs.group_create_ship({
        country = 'USA', type = 'CVN_71', north = 0, east = 0 })
    assert_false(r.ok, 'create_ship: refused on land')
    assert_contains(r.error, 'water', 'create_ship: land error mentions water')
    assert_contains(r.error, 'force=true', 'create_ship: error suggests force=true')
end

local function test_create_ship_force_bypasses_surface()
    mock.new_mission()
    terrain_stub._surface = 'land'
    local r = verbs.group_create_ship({
        country = 'USA', type = 'CVN_71', north = 0, east = 0, force = true })
    assert_true(r.ok, 'create_ship: force=true bypasses')
    terrain_stub._surface = 'sea'  -- reset
end

local function test_create_ship_shallow_water_ok()
    mock.new_mission()
    terrain_stub._surface = 'shallow_water'
    local r = verbs.group_create_ship({
        country = 'USA', type = 'CVN_71', north = 0, east = 0 })
    assert_true(r.ok, 'create_ship: shallow_water OK')
    terrain_stub._surface = 'sea'
end

-- ============================================================
-- group_create_static
-- ============================================================

local function test_create_static_happy()
    mock.new_mission()
    local r = verbs.group_create_static({
        country = 'USA', type = 'Watchtower', north = 0, east = 0,
        name = 'WT-1', category = 'Fortifications' })
    assert_true(r.ok, 'create_static: ok')
    local g = mock.mission.coalition.blue.country[1].static.group[1]
    assert_eq(g.units[1].name, 'WT-1', 'create_static: unit name = group name')
    assert_eq(g.units[1].category, 'Fortifications', 'create_static: category')
    assert_eq(g.dead, false, 'create_static: dead default false')
end

local function test_create_static_dead_can_cargo()
    mock.new_mission()
    local r = verbs.group_create_static({
        country = 'USA', type = 'cargo_crate', north = 0, east = 0,
        dead = true, can_cargo = true, mass = 500, category = 'Cargos' })
    assert_true(r.ok, 'create_static dead+cargo: ok')
    local g = mock.mission.coalition.blue.country[1].static.group[1]
    assert_eq(g.dead, true, 'create_static: dead applied')
    assert_eq(g.units[1].canCargo, true, 'create_static: canCargo applied')
    assert_eq(g.units[1].mass, 500, 'create_static: mass applied')
end

-- ============================================================
-- group_remove
-- ============================================================

local function test_remove_by_name()
    mock.new_mission()
    mock.add_plane({ name = 'rm1' })
    local r = verbs.group_remove({ name = 'rm1' })
    assert_true(r.ok, 'remove by name: ok')
    assert_eq(r.name, 'rm1', 'remove: returns name')
    assert_eq(r.category, 'plane', 'remove: returns category')
    assert_eq(#mock.mission.coalition.blue.country[1].plane.group, 0,
              'remove: group gone from list')
end

local function test_remove_by_id()
    mock.new_mission()
    local g = mock.add_plane({ name = 'rm2' })
    local r = verbs.group_remove({ id = g.groupId })
    assert_true(r.ok, 'remove by id: ok')
    assert_eq(r.id, g.groupId, 'remove: returns id')
end

local function test_remove_not_found()
    mock.new_mission()
    local r = verbs.group_remove({ name = 'ghost' })
    assert_false(r.ok, 'remove: not found')
    assert_contains(r.error, 'not found', 'remove: error msg')
end

local function test_remove_arg_validation()
    mock.new_mission()
    assert_false(verbs.group_remove(nil).ok, 'remove: nil args')
    assert_false(verbs.group_remove('s').ok, 'remove: string args')
    assert_false(verbs.group_remove({}).ok, 'remove: empty args')
    assert_false(verbs.group_remove({ name = 'x', id = 1 }).ok,
                 'remove: both name and id rejected')
    assert_false(verbs.group_remove({ name = '' }).ok, 'remove: empty name rejected')
    assert_false(verbs.group_remove({ id = '1' }).ok, 'remove: string id rejected')
end

-- ============================================================
-- group_add_unit
-- ============================================================

local function test_add_unit_happy()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'av1' })
    local r = verbs.group_add_unit({ name = 'av1' })
    assert_true(r.ok, 'add_unit: ok')
    assert_eq(#g.units, 2, 'add_unit: group has 2 units')
    assert_eq(r.unit_count, 2, 'add_unit: returns unit_count')
    assert_eq(r.group, 'av1', 'add_unit: returns group name')
end

local function test_add_unit_air_refuses_heterogeneous()
    mock.new_mission()
    local g = mock.add_plane({ name = 'av2', unit_type = 'F-16C_50' })
    local r = verbs.group_add_unit({ name = 'av2', type = 'F-14B' })
    assert_false(r.ok, 'add_unit air heterogeneous: rejected')
    assert_contains(r.error, 'one airframe', 'add_unit: error mentions one airframe')
end

local function test_add_unit_vehicle_heterogeneous_ok()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'av3', unit_type = 'Hawk pcp' })
    local r = verbs.group_add_unit({ name = 'av3', type = 'Hawk sr' })
    assert_true(r.ok, 'add_unit vehicle heterogeneous: ok')
    assert_eq(g.units[2].type, 'Hawk sr', 'add_unit: requested type applied')
end

local function test_add_unit_offset()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'av4', x = 100, y = 200 })
    local r = verbs.group_add_unit({ name = 'av4', offset_north = 50, offset_east = -25 })
    assert_true(r.ok, 'add_unit offset: ok')
    assert_eq(g.units[2].x, 150, 'add_unit offset: x = g.x + offset_north')
    assert_eq(g.units[2].y, 175, 'add_unit offset: y = g.y + offset_east')
end

local function test_add_unit_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'av5' })
    assert_false(verbs.group_add_unit(nil).ok, 'add_unit: nil args')
    assert_false(verbs.group_add_unit({}).ok, 'add_unit: empty args')
    assert_false(verbs.group_add_unit({ name = 'av5', id = 1 }).ok, 'add_unit: both')
    local r = verbs.group_add_unit({ name = 'ghost' })
    assert_false(r.ok, 'add_unit: group not found')
end

-- ============================================================
-- group_remove_unit
-- ============================================================

local function test_remove_unit_happy()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'ru1' })
    -- add a second unit so removing isn't the-last-unit
    verbs.group_add_unit({ name = 'ru1' })
    local second_name = g.units[2].name
    local r = verbs.group_remove_unit({ name = second_name })
    assert_true(r.ok, 'remove_unit: ok')
    assert_eq(#g.units, 1, 'remove_unit: g.units shrunk to 1')
end

local function test_remove_unit_last_refused()
    mock.new_mission()
    local g = mock.add_plane({ name = 'ru2' })
    local r = verbs.group_remove_unit({ name = g.units[1].name })
    assert_false(r.ok, 'remove_unit last: refused')
    assert_contains(r.error, 'last unit', 'remove_unit last: error msg')
end

local function test_remove_unit_not_found()
    mock.new_mission()
    local r = verbs.group_remove_unit({ name = 'ghost-unit' })
    assert_false(r.ok, 'remove_unit: not found')
    assert_contains(r.error, 'not found', 'remove_unit: error msg')
end

local function test_remove_unit_arg_validation()
    mock.new_mission()
    assert_false(verbs.group_remove_unit(nil).ok, 'remove_unit: nil')
    assert_false(verbs.group_remove_unit({}).ok, 'remove_unit: empty')
    assert_false(verbs.group_remove_unit({ name = 'x', id = 1 }).ok, 'remove_unit: both')
end

-- ============================================================
-- group_set_name
-- ============================================================

local function test_set_name_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'sn1' })
    local r = verbs.group_set_name({ name = 'sn1', new_name = 'sn1-renamed' })
    assert_true(r.ok, 'set_name: ok')
    assert_eq(r.name, 'sn1-renamed', 'set_name: returns new name')
    assert_eq(g.name, 'sn1-renamed', 'set_name: mutation applied')
end

local function test_set_name_collision()
    mock.new_mission()
    mock.add_plane({ name = 'sn2' })
    mock.add_plane({ name = 'sn3' })
    local r = verbs.group_set_name({ name = 'sn2', new_name = 'sn3' })
    assert_false(r.ok, 'set_name collision: refused')
    assert_contains(r.error, 'in use', 'set_name collision: error msg')
end

local function test_set_name_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'sn4' })
    assert_false(verbs.group_set_name({ name = 'sn4' }).ok, 'set_name: missing new_name')
    assert_false(verbs.group_set_name({ name = 'sn4', new_name = '' }).ok,
                 'set_name: empty new_name')
    assert_false(verbs.group_set_name({ new_name = 'x' }).ok, 'set_name: missing selector')
    assert_false(verbs.group_set_name({ name = 'ghost', new_name = 'x' }).ok,
                 'set_name: group not found')
end

-- ============================================================
-- group_set_task
-- ============================================================

local function test_set_task_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'st1' })
    local r = verbs.group_set_task({ name = 'st1', task = 'CAP' })
    assert_true(r.ok, 'set_task: ok')
    assert_eq(g.task, 'CAP', 'set_task: mutation applied')
end

local function test_set_task_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'st2' })
    assert_false(verbs.group_set_task({ name = 'st2' }).ok, 'set_task: missing task')
    assert_false(verbs.group_set_task({ name = 'st2', task = '' }).ok, 'set_task: empty task')
    assert_false(verbs.group_set_task({ task = 'CAP' }).ok, 'set_task: missing selector')
end

-- ============================================================
-- group_set_hidden / late_activation / uncontrolled
-- ============================================================

local function test_set_hidden_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'sh1' })
    local r = verbs.group_set_hidden({ name = 'sh1', hidden = true })
    assert_true(r.ok, 'set_hidden true: ok')
    assert_eq(g.hidden, true, 'set_hidden: applied')
    verbs.group_set_hidden({ name = 'sh1', hidden = false })
    assert_eq(g.hidden, false, 'set_hidden false: applied')
end

local function test_set_hidden_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'sh2' })
    assert_false(verbs.group_set_hidden({ name = 'sh2' }).ok, 'set_hidden: missing bool')
    assert_false(verbs.group_set_hidden({ name = 'sh2', hidden = 'true' }).ok,
                 'set_hidden: string rejected')
    assert_false(verbs.group_set_hidden({ name = 'sh2', hidden = 1 }).ok,
                 'set_hidden: number rejected')
end

local function test_set_late_activation_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'la1' })
    local r = verbs.group_set_late_activation({ name = 'la1', enabled = true })
    assert_true(r.ok, 'set_late_activation: ok')
    assert_eq(g.lateActivation, true, 'set_late_activation: applied')
end

local function test_set_late_activation_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'la2' })
    assert_false(verbs.group_set_late_activation({ name = 'la2' }).ok,
                 'set_late_activation: missing bool')
end

local function test_set_uncontrolled_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'uc1' })
    local r = verbs.group_set_uncontrolled({ name = 'uc1', enabled = true })
    assert_true(r.ok, 'set_uncontrolled: ok')
    assert_eq(g.uncontrolled, true, 'set_uncontrolled: applied')
end

-- ============================================================
-- group_set_frequency
-- ============================================================

local function test_set_frequency_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'sf1' })
    local r = verbs.group_set_frequency({ name = 'sf1', frequency = 280.5 })
    assert_true(r.ok, 'set_frequency: ok')
    assert_eq(g.frequency, 280.5, 'set_frequency: applied')
end

local function test_set_frequency_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'sf2' })
    assert_false(verbs.group_set_frequency({ name = 'sf2' }).ok,
                 'set_frequency: missing freq')
    assert_false(verbs.group_set_frequency({ name = 'sf2', frequency = 0 }).ok,
                 'set_frequency: zero rejected')
    assert_false(verbs.group_set_frequency({ name = 'sf2', frequency = -10 }).ok,
                 'set_frequency: negative rejected')
    assert_false(verbs.group_set_frequency({ name = 'sf2', frequency = '251' }).ok,
                 'set_frequency: string rejected')
end

-- ============================================================
-- group_set_pos
-- ============================================================

local function test_set_pos_happy()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'sp1', x = 100, y = 200 })
    -- Add a unit and waypoint at offset to verify delta is applied to all
    g.units[1].x = 110; g.units[1].y = 210
    g.route.points[1].x = 100; g.route.points[1].y = 200
    table.insert(g.route.points, mock.make_waypoint('vehicle', { x = 150, y = 250 }))

    local r = verbs.group_set_pos({ name = 'sp1', north = 1000, east = 2000 })
    assert_true(r.ok, 'set_pos: ok')
    assert_eq(g.x, 1000, 'set_pos: g.x updated')
    assert_eq(g.y, 2000, 'set_pos: g.y updated')
    assert_eq(g.units[1].x, 1010, 'set_pos: unit shifted by dx')
    assert_eq(g.units[1].y, 2010, 'set_pos: unit shifted by dy')
    assert_eq(g.route.points[1].x, 1000, 'set_pos: WP0 shifted')
    assert_eq(g.route.points[2].x, 1050, 'set_pos: WP1 shifted preserving offset')
    assert_eq(r.delta.north, 900, 'set_pos: returns delta.north')
    assert_eq(r.delta.east, 1800, 'set_pos: returns delta.east')
end

local function test_set_pos_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'sp2' })
    assert_false(verbs.group_set_pos({ name = 'sp2' }).ok, 'set_pos: missing coords')
    assert_false(verbs.group_set_pos({ name = 'sp2', north = 1 }).ok,
                 'set_pos: missing east')
    assert_false(verbs.group_set_pos({ name = 'sp2', north = '1', east = 2 }).ok,
                 'set_pos: string north rejected')
end

-- ============================================================
-- group_set_formation
-- ============================================================

local function test_set_formation_builtin_alias()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'gf1' })
    local r = verbs.group_set_formation({ name = 'gf1', formation = 'diamond' })
    assert_true(r.ok, 'set_formation diamond: ok')
    assert_eq(g.route.points[1].type, 'Diamond', 'set_formation: wp.type = Diamond')
    assert_eq(g.route.points[1].formation_template, '', 'set_formation: template cleared')
end

local function test_set_formation_dash_space_tolerant()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'gf2' })
    local r1 = verbs.group_set_formation({ name = 'gf2', formation = 'echelon-left' })
    assert_true(r1.ok, 'set_formation echelon-left: ok')
    assert_eq(g.route.points[1].type, 'EchelonL', 'set_formation: dash tolerated')
    local r2 = verbs.group_set_formation({ name = 'gf2', formation = 'OFF ROAD' })
    assert_true(r2.ok, 'set_formation OFF ROAD: ok')
    assert_eq(g.route.points[1].type, 'OffRoad', 'set_formation: space tolerated + case')
end

local function test_set_formation_custom_template()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'gf3' })
    local r = verbs.group_set_formation({ name = 'gf3', formation = 'Hawk SAM Battery' })
    assert_true(r.ok, 'set_formation custom: ok')
    assert_eq(g.route.points[1].type, 'CustomForm', 'set_formation: customForm action')
    assert_eq(g.route.points[1].formation_template, 'Hawk SAM Battery',
              'set_formation: template name stored')
end

local function test_set_formation_unknown_template_rejected()
    mock.new_mission()
    mock.add_vehicle({ name = 'gf4' })
    local r = verbs.group_set_formation({ name = 'gf4', formation = 'BogusFormation' })
    assert_false(r.ok, 'set_formation unknown: rejected')
    assert_contains(r.error, 'unknown formation', 'set_formation: error msg')
end

local function test_set_formation_air_refused()
    mock.new_mission()
    mock.add_plane({ name = 'gf5' })
    local r = verbs.group_set_formation({ name = 'gf5', formation = 'diamond' })
    assert_false(r.ok, 'set_formation air: refused')
    assert_contains(r.error, 'vehicle', 'set_formation air: error mentions vehicle-only')
end

local function test_set_formation_ship_refused()
    mock.new_mission()
    mock.add_ship({ name = 'gf6' })
    local r = verbs.group_set_formation({ name = 'gf6', formation = 'diamond' })
    assert_false(r.ok, 'set_formation ship: refused')
end

local function test_set_formation_static_refused()
    mock.new_mission()
    mock.add_static({ name = 'gf7' })
    local r = verbs.group_set_formation({ name = 'gf7', formation = 'diamond' })
    assert_false(r.ok, 'set_formation static: refused')
end

local function test_set_formation_waypoint_oob()
    mock.new_mission()
    mock.add_vehicle({ name = 'gf8' })
    local r = verbs.group_set_formation({
        name = 'gf8', formation = 'diamond', waypoint = 99 })
    assert_false(r.ok, 'set_formation oob waypoint: rejected')
    assert_contains(r.error, 'waypoint', 'set_formation: waypoint error')
end

local function test_set_formation_waypoint_zero_rejected()
    mock.new_mission()
    mock.add_vehicle({ name = 'gf9' })
    local r = verbs.group_set_formation({
        name = 'gf9', formation = 'diamond', waypoint = 0 })
    assert_false(r.ok, 'set_formation waypoint=0: rejected')
end

-- ============================================================
-- group_set_country
-- ============================================================

local function test_set_country_same_coalition()
    mock.new_mission()
    local g = mock.add_plane({ name = 'sc1', country = 'USA' })
    local r = verbs.group_set_country({ name = 'sc1', country = 'Germany' })
    assert_true(r.ok, 'set_country same-coal: ok')
    assert_eq(r.country, 'Germany', 'set_country: returns new country')
    assert_eq(r.coalition_changed, false, 'set_country same-coal: not flipped')
    assert_eq(#mock.mission.coalition.blue.country[1].plane.group, 0,
              'set_country: removed from USA')
    assert_eq(#mock.mission.coalition.blue.country[2].plane.group, 1,
              'set_country: added to Germany')
end

local function test_set_country_coalition_flip()
    mock.new_mission()
    local g = mock.add_plane({ name = 'sc2', country = 'USA' })
    local r = verbs.group_set_country({ name = 'sc2', country = 'Russia' })
    assert_true(r.ok, 'set_country coal-flip: ok')
    assert_eq(r.coalition_changed, true, 'set_country: coalition_changed true')
    assert_eq(r.previous_side, 'blue', 'set_country: previous_side')
    assert_eq(r.side, 'red', 'set_country: new side')
end

local function test_set_country_no_op()
    mock.new_mission()
    mock.add_plane({ name = 'sc3', country = 'USA' })
    local r = verbs.group_set_country({ name = 'sc3', country = 'USA' })
    assert_true(r.ok, 'set_country no-op: ok')
    assert_eq(r.no_op, true, 'set_country no-op flagged')
end

local function test_set_country_unknown()
    mock.new_mission()
    mock.add_plane({ name = 'sc4' })
    local r = verbs.group_set_country({ name = 'sc4', country = 'Atlantis' })
    assert_false(r.ok, 'set_country unknown: rejected')
    assert_contains(r.error, 'Atlantis', 'set_country: error names country')
end

local function test_set_country_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'sc5' })
    assert_false(verbs.group_set_country({ name = 'sc5' }).ok,
                 'set_country: missing country')
    assert_false(verbs.group_set_country({ country = 'USA' }).ok,
                 'set_country: missing selector')
    assert_false(verbs.group_set_country({ name = 'sc5', country = '' }).ok,
                 'set_country: empty country')
end

local function test_set_country_air_triggers_livery_fixup()
    mock.new_mission()
    mock.add_plane({ name = 'sc6', country = 'USA' })
    me_payload_stub.setDefaultLivery_calls = 0
    verbs.group_set_country({ name = 'sc6', country = 'Russia' })
    assert_true(me_payload_stub.setDefaultLivery_calls >= 1,
                'set_country air: setDefaultLivery called')
end

local function test_set_country_vehicle_skips_livery_fixup()
    mock.new_mission()
    mock.add_vehicle({ name = 'sc7', country = 'USA' })
    me_payload_stub.setDefaultLivery_calls = 0
    verbs.group_set_country({ name = 'sc7', country = 'Russia' })
    assert_eq(me_payload_stub.setDefaultLivery_calls, 0,
              'set_country vehicle: setDefaultLivery skipped')
end

-- ============================================================
-- group_list
-- ============================================================

local function test_list_all()
    mock.new_mission()
    mock.add_plane({ name = 'L1', country = 'USA' })
    mock.add_helicopter({ name = 'L2', country = 'USA' })
    mock.add_vehicle({ name = 'L3', country = 'Russia', side = 'red' })
    local r = verbs.group_list({})
    assert_true(r.ok, 'list: ok')
    assert_eq(r.count, 3, 'list: count = 3')
    assert_eq(#r.groups, 3, 'list: groups array len')
end

local function test_list_filter_side()
    mock.new_mission()
    mock.add_plane({ name = 'L4', country = 'USA' })
    mock.add_vehicle({ name = 'L5', country = 'Russia', side = 'red' })
    local r = verbs.group_list({ side = 'blue' })
    assert_eq(r.count, 1, 'list side=blue: count')
    assert_eq(r.groups[1].name, 'L4', 'list side=blue: only USA group')
end

local function test_list_filter_country()
    mock.new_mission()
    mock.add_plane({ name = 'L6', country = 'USA' })
    mock.add_plane({ name = 'L7', country = 'Germany' })
    local r = verbs.group_list({ country = 'germany' })
    assert_eq(r.count, 1, 'list country=germany (lowercase): count')
    assert_eq(r.groups[1].name, 'L7', 'list country: case-insensitive match')
end

local function test_list_filter_category()
    mock.new_mission()
    mock.add_plane({ name = 'L8' })
    mock.add_helicopter({ name = 'L9' })
    local r = verbs.group_list({ category = 'helicopter' })
    assert_eq(r.count, 1, 'list category=helicopter: count')
end

local function test_list_filter_name_substring()
    mock.new_mission()
    mock.add_plane({ name = 'Hornet-1' })
    mock.add_plane({ name = 'Hornet-2' })
    mock.add_plane({ name = 'Tomcat-1' })
    local r = verbs.group_list({ name = 'hornet' })
    assert_eq(r.count, 2, 'list name=hornet (substring): count')
end

local function test_list_summary_fields()
    mock.new_mission()
    local g = mock.add_plane({ name = 'L10', country = 'USA', x = 100, y = 200 })
    g.hidden = true
    g.task = 'CAP'
    local r = verbs.group_list({ name = 'L10' })
    local s = r.groups[1]
    assert_eq(s.id, g.groupId, 'list summary: id')
    assert_eq(s.name, 'L10', 'list summary: name')
    assert_eq(s.category, 'plane', 'list summary: category')
    assert_eq(s.country, 'USA', 'list summary: country')
    assert_eq(s.side, 'blue', 'list summary: side')
    assert_eq(s.north, 100, 'list summary: north')
    assert_eq(s.east, 200, 'list summary: east')
    assert_eq(s.unit_count, 1, 'list summary: unit_count')
    assert_eq(s.hidden, true, 'list summary: hidden')
    assert_eq(s.task, 'CAP', 'list summary: task')
end

-- ============================================================
-- group_get
-- ============================================================

local function test_get_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'G1', country = 'USA' })
    local r = verbs.group_get({ name = 'G1' })
    assert_true(r.ok, 'get: ok')
    assert_eq(r.group.name, 'G1', 'get: snapshot.name')
    assert_eq(r.group._country, 'USA', 'get: _country meta')
    assert_eq(r.group._side, 'blue', 'get: _side meta')
    assert_eq(r.group._category, 'plane', 'get: _category meta')
end

local function test_get_strips_back_refs()
    mock.new_mission()
    local g = mock.add_plane({ name = 'G2' })
    g.mapObjects = { units = {}, zones = {}, route = {} }
    local r = verbs.group_get({ name = 'G2' })
    assert_true(r.ok, 'get strips: ok')
    assert_eq(r.group.boss, nil, 'get: boss stripped')
    assert_eq(r.group.mapObjects, nil, 'get: mapObjects stripped')
end

local function test_get_strips_userobject_cycle()
    -- Beacon-style units own a zone whose .userObject points back at the
    -- unit. Before GH#66 strip_back_refs's depth fallback returned the live
    -- cyclic table and hung jval. Reproduce with the cycle in place and
    -- assert group_get returns cleanly.
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'BeaconG' })
    local u = g.units[1]
    u.zones = { { id = 7, radius = 1200, userObject = u } }
    local r = verbs.group_get({ name = 'BeaconG' })
    assert_true(r.ok, 'group_get with userObject cycle: ok')
    assert_eq(r.group.units[1].zones[1].userObject, nil, 'group_get: nested userObject stripped')
    assert_eq(r.group.units[1].zones[1].radius, 1200, 'group_get: surrounding zone fields kept')
end

local function test_get_visited_set_breaks_arbitrary_cycle()
    -- Defense-in-depth: strip_back_refs must also break cycles via keys NOT
    -- on the drop list, in case a future DCS build introduces another
    -- back-pointer. Self-cycle on `zones[1].self_ref` — the visited-set is
    -- the only thing that breaks it; the drop list won't.
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'CycleG' })
    local u = g.units[1]
    local zone = { id = 9, radius = 800 }
    zone.self_ref = zone
    u.zones = { zone }
    local r = verbs.group_get({ name = 'CycleG' })
    assert_true(r.ok, 'group_get with non-dropped cycle: ok')
    assert_eq(r.group.units[1].zones[1].self_ref, nil,
        'group_get: visited-set elided self_ref cycle')
    assert_eq(r.group.units[1].zones[1].radius, 800,
        'group_get: surrounding zone fields kept')
end

local function test_get_not_found()
    mock.new_mission()
    local r = verbs.group_get({ name = 'ghost' })
    assert_false(r.ok, 'get not found: error')
    assert_contains(r.error, 'not found', 'get: error msg')
end

local function test_get_arg_validation()
    mock.new_mission()
    assert_false(verbs.group_get({}).ok, 'get: missing selector')
    assert_false(verbs.group_get({ name = 'x', id = 1 }).ok, 'get: both selectors')
end

-- ============================================================
-- lat/lon enrichment (GH#66 request 4)
-- ============================================================

-- Stub Terrain only for the duration of one test so other tests stay on the
-- "no Terrain → no lat/lon" path.
local function with_terrain_stub(fn)
    local saved = _G.Terrain
    _G.Terrain = {
        convertMetersToLatLon = function(x, y) return x / 111000, y / 85000 end,
    }
    local ok, err = pcall(fn)
    _G.Terrain = saved
    if not ok then error(err, 0) end
end

local function test_list_includes_lat_lon_when_terrain_available()
    mock.new_mission()
    local g = mock.add_plane({ name = 'LL1' })
    g.x, g.y = 111000, 85000
    with_terrain_stub(function()
        local r = verbs.group_list({ name = 'LL1' })
        assert_true(r.ok, 'group_list w/ Terrain: ok')
        assert_eq(r.groups[1].lat, 1, 'group_list: lat from Terrain stub')
        assert_eq(r.groups[1].lon, 1, 'group_list: lon from Terrain stub')
    end)
end

local function test_list_omits_lat_lon_when_no_terrain()
    mock.new_mission()
    mock.add_plane({ name = 'LL2' })
    local r = verbs.group_list({ name = 'LL2' })
    assert_true(r.ok, 'group_list no Terrain: ok')
    assert_eq(r.groups[1].lat, nil, 'group_list: lat absent without Terrain')
    assert_eq(r.groups[1].lon, nil, 'group_list: lon absent without Terrain')
end

local function test_get_includes_lat_lon_when_terrain_available()
    mock.new_mission()
    local g = mock.add_plane({ name = 'LL3' })
    g.x, g.y = 222000, 170000
    with_terrain_stub(function()
        local r = verbs.group_get({ name = 'LL3' })
        assert_true(r.ok, 'group_get w/ Terrain: ok')
        assert_eq(r.group.lat, 2, 'group_get: lat from Terrain stub')
        assert_eq(r.group.lon, 2, 'group_get: lon from Terrain stub')
    end)
end

-- ============================================================
-- Test runner
-- ============================================================

local tests = {
    test_create_plane_happy,
    test_create_plane_default_name,
    test_create_plane_name_collision_uniquifies,
    test_create_plane_overrides,
    test_create_plane_task_default_and_override,
    test_create_vehicle_task_override,
    test_create_plane_arg_validation,
    test_create_plane_country_not_in_tree,
    test_create_plane_unknown_type_rejected,
    test_create_helicopter_happy,
    test_create_helicopter_arg_validation,
    test_create_helicopter_unknown_type_rejected,
    test_create_vehicle_happy,
    test_create_vehicle_arg_validation,
    test_create_vehicle_unknown_type_rejected,
    test_create_ship_happy_over_water,
    test_create_ship_refused_on_land,
    test_create_ship_force_bypasses_surface,
    test_create_ship_shallow_water_ok,
    test_create_ship_unknown_type_rejected,
    test_create_static_happy,
    test_create_static_dead_can_cargo,
    test_create_static_unknown_type_rejected,
    test_remove_by_name,
    test_remove_by_id,
    test_remove_not_found,
    test_remove_arg_validation,
    test_add_unit_happy,
    test_add_unit_air_refuses_heterogeneous,
    test_add_unit_vehicle_heterogeneous_ok,
    test_add_unit_offset,
    test_add_unit_arg_validation,
    test_add_unit_unknown_type_rejected,
    test_add_unit_inherits_type_no_validation,
    test_remove_unit_happy,
    test_remove_unit_last_refused,
    test_remove_unit_not_found,
    test_remove_unit_arg_validation,
    test_set_name_happy,
    test_set_name_collision,
    test_set_name_arg_validation,
    test_set_task_happy,
    test_set_task_arg_validation,
    test_set_hidden_happy,
    test_set_hidden_arg_validation,
    test_set_late_activation_happy,
    test_set_late_activation_arg_validation,
    test_set_uncontrolled_happy,
    test_set_frequency_happy,
    test_set_frequency_arg_validation,
    test_set_pos_happy,
    test_set_pos_arg_validation,
    test_set_formation_builtin_alias,
    test_set_formation_dash_space_tolerant,
    test_set_formation_custom_template,
    test_set_formation_unknown_template_rejected,
    test_set_formation_air_refused,
    test_set_formation_ship_refused,
    test_set_formation_static_refused,
    test_set_formation_waypoint_oob,
    test_set_formation_waypoint_zero_rejected,
    test_set_country_same_coalition,
    test_set_country_coalition_flip,
    test_set_country_no_op,
    test_set_country_unknown,
    test_set_country_arg_validation,
    test_set_country_air_triggers_livery_fixup,
    test_set_country_vehicle_skips_livery_fixup,
    test_list_all,
    test_list_filter_side,
    test_list_filter_country,
    test_list_filter_category,
    test_list_filter_name_substring,
    test_list_summary_fields,
    test_get_happy,
    test_get_strips_back_refs,
    test_get_strips_userobject_cycle,
    test_get_visited_set_breaks_arbitrary_cycle,
    test_get_not_found,
    test_get_arg_validation,
    test_list_includes_lat_lon_when_terrain_available,
    test_list_omits_lat_lon_when_no_terrain,
    test_get_includes_lat_lon_when_terrain_available,
}

for _, t in ipairs(tests) do t() end

print(string.format('test_verbs_group: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
