-- test_verbs_resources.lua — Lua-side unit tests for verbs/resources_verbs.lua.

local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path

local mock = require('mock_me_mission')
package.preload['me_mission']    = function() return mock end
package.preload['me_map_window'] = function() return mock end

-- ============================================================
-- AirdromeController stub (shared with airbase tests pattern)
-- ============================================================

local airdromes = {
    {
        x = 100, y = 200,
        getName = function(self) return 'Anapa' end,
        getCoalitionName = function(self) return 'blue' end,
        getAirdromeNumber = function(self) return 12 end,
        getRoadnet = function(self) return {} end,
    },
}
package.preload['Mission.AirdromeController'] = function()
    return { getAirdromes = function() return airdromes end }
end

-- ============================================================
-- warehouse_ops stub
-- ============================================================

local wh_storage = {}

local function deep_copy(t)
    if type(t) ~= 'table' then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deep_copy(v) end
    return out
end

local function default_airbase_warehouse()
    return {
        unlimitedFuel = false,
        unlimitedAircrafts = false,
        unlimitedMunitions = false,
        OperatingLevel_Air = 10,
        OperatingLevel_Fuel = 10,
        OperatingLevel_Eqp = 10,
        jet_fuel  = { InitFuel = 100 },
        gasoline  = { InitFuel = 50 },
        diesel    = { InitFuel = 50 },
        methanol_mixture = { InitFuel = 25 },
        aircrafts = {
            planes = {
                ['F-16C_50'] = { initialAmount = 10 },
                ['F-15C']    = { initialAmount = 5 },
            },
            helicopters = {
                ['UH-1H'] = { initialAmount = 3 },
            },
        },
        weapons = {
            { wsType = { 4, 4, 7, 39 }, initialAmount = 100 },  -- placeholder
        },
    }
end

local function reset_warehouses()
    wh_storage = { [12] = default_airbase_warehouse() }
end

package.preload['dcs_sms_me.warehouse_ops'] = function()
    return {
        extract = function(airdrome_number) return deep_copy(wh_storage[airdrome_number]) end,
        is_default = function(_e) return false end,
        apply = function(airdrome_number, entry)
            if not wh_storage[airdrome_number] then
                return false, 'no warehouse for ' .. airdrome_number
            end
            wh_storage[airdrome_number] = deep_copy(entry)
            return true, nil
        end,
        _deep_copy = deep_copy,
    }
end

-- ============================================================
-- weapons_db stub
-- ============================================================

local weapons_index = {
    ['AIM-9X']      = { ws_type = { 4, 4, 7, 39 }, display_name = 'AIM-9X Sidewinder' },
    ['AIM-120']     = { ws_type = { 4, 4, 7, 138 }, display_name = 'AIM-120C AMRAAM' },
    ['CBU-87']      = { ws_type = { 4, 5, 38, 142 }, display_name = 'CBU-87' },
    ['AIM-9']       = nil,  -- ambiguous marker handled in find_by_name
}

package.preload['dcs_sms_me.weapons_db'] = function()
    return {
        find_by_name = function(name)
            if name == 'AIM-9' then
                return { ambiguous = true, candidates = { 'AIM-9X', 'AIM-9M' } }
            end
            local entry = weapons_index[name]
            if not entry then
                return { found = false }
            end
            return { found = true, entry = entry }
        end,
    }
end

-- Stubs for sibling verb modules.
package.preload['terrain']      = function()
    return { GetSurfaceType = function() return 'sea' end }
end
package.preload['utils_common'] = function() return { actions = {} } end
package.preload['me_db_api']    = function() return { templates = {}, unit_by_type = {} } end
package.preload['me_payload']   = function() return { setDefaultLivery = function() end } end
package.preload['me_route']     = function()
    return { isAirfieldWaypoint = function() return false end,
             attractToAirfield = function() end,
             update = function() end }
end
package.preload['me_parking']   = function()
    return { getStandList = function() return {} end,
             getRightParkingAirport = function(s) return s end }
end
package.preload['me_predicates'] = function() return { rulesDescr = {} } end
package.preload['me_trigrules']  = function() return { actionsDescr = {}, triggersDescr = {} } end
package.preload['dictionary']    = function() return { fixDict = function() end, getValueDict = function() end } end
package.preload['Mission.TriggerZoneData'] = function() return { getTriggerZoneIds = function() return {} end, getTriggerZoneName = function() end } end
package.preload['me_draw_panel'] = function() return { saveToMission = function() return { layers = {} } end, loadFromMission = function() end, getObjects = function() return {} end, objectDelete = function() end } end

_G.Terrain = { convertMetersToLatLon = function(x, y) return x/1000, y/1000 end,
               getRunwayList = function() return {} end }

package.path = here .. '../lua/?.lua;' .. here .. '../lua/?/init.lua;' .. package.path

local verbs = require('dcs_sms_me.verbs')

-- ============================================================
-- Test harness
-- ============================================================

local passed, failed, errors = 0, 0, {}

local function assert_eq(actual, expected, name)
    if actual == expected then passed = passed + 1
    else failed = failed + 1
        table.insert(errors, string.format('%s: expected %s, got %s',
            name, tostring(expected), tostring(actual)))
    end
end

local function assert_true(cond, name)  assert_eq(cond and true or false, true, name) end
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

local function reset()
    mock.new_mission()
    -- Add the AirportsEquipment.warehouses field that resources verbs expect.
    mock.mission.AirportsEquipment = { warehouses = {} }
    reset_warehouses()
end

-- ============================================================
-- resources_get
-- ============================================================

local function test_get_airbase_happy()
    reset()
    local r = verbs.resources_get({ airbase = 'Anapa' })
    assert_true(r.ok, 'get airbase: ok')
    assert_eq(r.target, 'airbase', 'get: target=airbase')
    assert_eq(r.name, 'Anapa', 'get: name')
    assert_eq(r.airdrome_number, 12, 'get: airdrome_number')
    assert_eq(r.warehouse.unlimitedFuel, false, 'get: warehouse field exposed')
    assert_eq(r.warehouse.jet_fuel.InitFuel, 100, 'get: fuel field exposed')
end

local function test_get_unit_happy()
    reset()
    local g = mock.add_ship({ name = 'CG-1' })
    local u = g.units[1]
    -- Add warehouse entry keyed by unit id
    mock.mission.AirportsEquipment.warehouses[u.unitId] = {
        coalition = 'blue',
        gasoline = { InitFuel = 50 },
    }
    local r = verbs.resources_get({ unit = u.name })
    assert_true(r.ok, 'get unit by name: ok')
    assert_eq(r.target, 'unit', 'get unit: target')
    assert_eq(r.unit_id, u.unitId, 'get unit: unit_id')
end

local function test_get_unit_by_id()
    reset()
    local g = mock.add_ship({ name = 'CG-2' })
    local u = g.units[1]
    mock.mission.AirportsEquipment.warehouses[u.unitId] = { gasoline = { InitFuel = 0 } }
    local r = verbs.resources_get({ unit = u.unitId })
    assert_true(r.ok, 'get unit by id: ok')
end

local function test_get_unit_no_warehouse()
    reset()
    local g = mock.add_plane({ name = 'P1' })
    local r = verbs.resources_get({ unit = g.units[1].name })
    assert_false(r.ok, 'get unit no warehouse: refused')
    assert_contains(r.error, 'no warehouse', 'get unit: error msg')
end

local function test_get_airbase_not_found()
    reset()
    local r = verbs.resources_get({ airbase = 'Nowhere' })
    assert_false(r.ok, 'get airbase not found: refused')
end

local function test_get_arg_validation()
    reset()
    assert_false(verbs.resources_get({}).ok, 'get: no target')
    assert_false(verbs.resources_get({ airbase = 'x', unit = 'y' }).ok,
                 'get: both targets')
end

local function test_get_mission_not_loaded()
    -- AirportsEquipment is required to be present
    mock.new_mission()
    mock.mission.AirportsEquipment = nil
    local r = verbs.resources_get({ airbase = 'Anapa' })
    assert_false(r.ok, 'get no mission: refused')
    assert_contains(r.error, 'not loaded', 'get no mission: error msg')
end

-- ============================================================
-- resources_set — airbase target, simple cases
-- ============================================================

local function test_set_clear_zeros_everything()
    reset()
    local r = verbs.resources_set({ airbase = 'Anapa', clear = true })
    assert_true(r.ok, 'set clear: ok')
    -- Aircraft amounts zeroed
    assert_eq(wh_storage[12].aircrafts.planes['F-16C_50'].initialAmount, 0,
              'set clear: F-16 zeroed')
    assert_eq(wh_storage[12].aircrafts.helicopters['UH-1H'].initialAmount, 0,
              'set clear: UH-1H zeroed')
    -- Fuel zeroed
    assert_eq(wh_storage[12].jet_fuel.InitFuel, 0, 'set clear: jet_fuel zeroed')
    assert_eq(wh_storage[12].gasoline.InitFuel, 0, 'set clear: gasoline zeroed')
    -- Weapons zeroed
    assert_eq(wh_storage[12].weapons[1].initialAmount, 0, 'set clear: weapons zeroed')
    -- Unlimited flipped false
    assert_eq(wh_storage[12].unlimitedFuel, false, 'set clear: unlimitedFuel false')
end

local function test_set_unlimited_true()
    reset()
    local r = verbs.resources_set({ airbase = 'Anapa', unlimited = true })
    assert_true(r.ok, 'set unlimited: ok')
    assert_eq(wh_storage[12].unlimitedFuel, true, 'unlimitedFuel true')
    assert_eq(wh_storage[12].unlimitedAircrafts, true, 'unlimitedAircrafts true')
    assert_eq(wh_storage[12].unlimitedMunitions, true, 'unlimitedMunitions true')
end

local function test_set_unlimited_false()
    reset()
    wh_storage[12].unlimitedFuel = true
    local r = verbs.resources_set({ airbase = 'Anapa', unlimited = false })
    assert_true(r.ok, 'set unlimited=false: ok')
    assert_eq(wh_storage[12].unlimitedFuel, false, 'unlimitedFuel false')
end

local function test_set_clear_aircrafts_only()
    reset()
    local r = verbs.resources_set({ airbase = 'Anapa', clear_aircrafts = true })
    assert_true(r.ok, 'set clear_aircrafts: ok')
    assert_eq(wh_storage[12].aircrafts.planes['F-16C_50'].initialAmount, 0,
              'clear_aircrafts: F-16 zeroed')
    -- Fuel should NOT be touched
    assert_eq(wh_storage[12].jet_fuel.InitFuel, 100, 'clear_aircrafts: fuel preserved')
end

local function test_set_clear_fuel_only()
    reset()
    verbs.resources_set({ airbase = 'Anapa', clear_fuel = true })
    assert_eq(wh_storage[12].jet_fuel.InitFuel, 0, 'clear_fuel: jet_fuel zeroed')
    assert_eq(wh_storage[12].aircrafts.planes['F-16C_50'].initialAmount, 10,
              'clear_fuel: aircraft preserved')
end

local function test_set_clear_munitions_only()
    reset()
    verbs.resources_set({ airbase = 'Anapa', clear_munitions = true })
    assert_eq(wh_storage[12].weapons[1].initialAmount, 0, 'clear_munitions: zeroed')
    assert_eq(wh_storage[12].jet_fuel.InitFuel, 100, 'clear_munitions: fuel preserved')
end

local function test_set_unlimited_per_category()
    reset()
    verbs.resources_set({ airbase = 'Anapa', unlimited_fuel = true })
    assert_eq(wh_storage[12].unlimitedFuel, true, 'unlimited_fuel: true')
    assert_eq(wh_storage[12].unlimitedAircrafts, false,
              'unlimited_fuel: aircrafts unchanged')
end

local function test_set_operating_levels()
    reset()
    verbs.resources_set({
        airbase = 'Anapa',
        operating_level_air = 7,
        operating_level_fuel = 8,
        operating_level_eqp = 9,
    })
    assert_eq(wh_storage[12].OperatingLevel_Air, 7, 'op_level_air')
    assert_eq(wh_storage[12].OperatingLevel_Fuel, 8, 'op_level_fuel')
    assert_eq(wh_storage[12].OperatingLevel_Eqp, 9, 'op_level_eqp')
end

local function test_set_fuel_override()
    reset()
    verbs.resources_set({
        airbase = 'Anapa',
        fuel_overrides = { jet_fuel = 5000, gasoline = 200 },
    })
    assert_eq(wh_storage[12].jet_fuel.InitFuel, 5000, 'fuel_override: jet_fuel')
    assert_eq(wh_storage[12].gasoline.InitFuel, 200, 'fuel_override: gasoline')
    assert_eq(wh_storage[12].diesel.InitFuel, 50, 'fuel_override: diesel untouched')
end

local function test_set_fuel_override_unknown_type()
    reset()
    local r = verbs.resources_set({
        airbase = 'Anapa',
        fuel_overrides = { kerosene = 1000 },
    })
    assert_false(r.ok, 'fuel_override unknown: refused')
    assert_contains(r.error, 'unknown fuel type', 'fuel_override: error msg')
end

local function test_set_aircraft_override()
    reset()
    verbs.resources_set({
        airbase = 'Anapa',
        aircraft_overrides = { ['F-16C_50'] = 99, ['UH-1H'] = 7 },
    })
    assert_eq(wh_storage[12].aircrafts.planes['F-16C_50'].initialAmount, 99,
              'aircraft_override: F-16')
    assert_eq(wh_storage[12].aircrafts.helicopters['UH-1H'].initialAmount, 7,
              'aircraft_override: UH-1H')
end

local function test_set_aircraft_override_unknown()
    reset()
    local r = verbs.resources_set({
        airbase = 'Anapa',
        aircraft_overrides = { ['NonExistent-Type'] = 5 },
    })
    assert_false(r.ok, 'aircraft_override unknown: refused')
    assert_contains(r.error, 'no aircraft', 'aircraft_override unknown: error msg')
end

local function test_set_aircraft_override_partial_match_candidates()
    reset()
    -- Adding F-15 partial should yield F-15C as a candidate
    local r = verbs.resources_set({
        airbase = 'Anapa',
        aircraft_overrides = { ['F-15'] = 5 },
    })
    assert_false(r.ok, 'aircraft_override partial: refused')
    assert_true(type(r.candidates) == 'table' and #r.candidates >= 1,
                'aircraft_override partial: candidates surfaced')
end

local function test_set_weapon_override_by_name()
    reset()
    local r = verbs.resources_set({
        airbase = 'Anapa',
        weapon_overrides = { { name = 'AIM-9X', count = 50 } },
    })
    assert_true(r.ok, 'weapon_override: ok')
    -- Find the AIM-9X entry
    local found
    for _, w in ipairs(wh_storage[12].weapons) do
        if w.wsType[4] == 39 then found = w; break end
    end
    assert_true(found ~= nil, 'weapon_override: AIM-9X entry exists')
    assert_eq(found.initialAmount, 50, 'weapon_override: amount applied')
end

local function test_set_weapon_override_new_entry_appended()
    reset()
    -- AIM-120 (ws_type 4,4,7,138) doesn't pre-exist; should be appended.
    local prev_count = #wh_storage[12].weapons
    local r = verbs.resources_set({
        airbase = 'Anapa',
        weapon_overrides = { { name = 'AIM-120', count = 25 } },
    })
    assert_true(r.ok, 'weapon_override new: ok')
    assert_eq(#wh_storage[12].weapons, prev_count + 1,
              'weapon_override new: entry appended')
end

local function test_set_weapon_override_ambiguous()
    reset()
    local r = verbs.resources_set({
        airbase = 'Anapa',
        weapon_overrides = { { name = 'AIM-9', count = 50 } },
    })
    assert_false(r.ok, 'weapon_override ambiguous: refused')
    assert_contains(r.error, 'ambiguous', 'weapon_override ambiguous: error msg')
end

local function test_set_weapon_override_unknown()
    reset()
    local r = verbs.resources_set({
        airbase = 'Anapa',
        weapon_overrides = { { name = 'NonExistent', count = 50 } },
    })
    assert_false(r.ok, 'weapon_override unknown: refused')
end

local function test_set_weapon_override_bad_shape()
    reset()
    local r = verbs.resources_set({
        airbase = 'Anapa',
        weapon_overrides = { { name = 'AIM-9X' } },  -- missing count
    })
    assert_false(r.ok, 'weapon_override bad shape: refused')
    assert_contains(r.error, 'name=string, count=number', 'weapon_override: error msg')
end

local function test_set_atomic_validation_no_partial_writes()
    reset()
    -- Try a set with one valid and one invalid override. Validation should
    -- fail BEFORE any mutation lands.
    local before_fuel = wh_storage[12].jet_fuel.InitFuel
    local before_ac = wh_storage[12].aircrafts.planes['F-16C_50'].initialAmount
    local r = verbs.resources_set({
        airbase = 'Anapa',
        fuel_overrides = { jet_fuel = 5000 },  -- valid
        aircraft_overrides = { ['NonExistent'] = 5 },  -- invalid
    })
    assert_false(r.ok, 'atomic: rejected')
    assert_eq(wh_storage[12].jet_fuel.InitFuel, before_fuel,
              'atomic: fuel NOT written despite validation failure')
    assert_eq(wh_storage[12].aircrafts.planes['F-16C_50'].initialAmount, before_ac,
              'atomic: aircraft NOT written')
end

-- ============================================================
-- resources_set — unit target
-- ============================================================

local function test_set_unit_happy()
    reset()
    local g = mock.add_ship({ name = 'CG-3' })
    local u = g.units[1]
    mock.mission.AirportsEquipment.warehouses[u.unitId] = {
        gasoline = { InitFuel = 100 },
        weapons = {},
        aircrafts = {},
    }
    local r = verbs.resources_set({
        unit = u.name,
        fuel_overrides = { gasoline = 500 },
    })
    assert_true(r.ok, 'set unit: ok')
    assert_eq(mock.mission.AirportsEquipment.warehouses[u.unitId].gasoline.InitFuel, 500,
              'set unit: fuel applied')
end

local function test_set_unit_no_warehouse()
    reset()
    local g = mock.add_plane({ name = 'NW1' })
    local r = verbs.resources_set({ unit = g.units[1].name })
    assert_false(r.ok, 'set unit no warehouse: refused')
end

local function test_set_arg_validation()
    reset()
    assert_false(verbs.resources_set({}).ok, 'set: no target')
    assert_false(verbs.resources_set({ airbase = 'x', unit = 'y' }).ok,
                 'set: both targets')
end

-- ============================================================
-- Test runner
-- ============================================================

local tests = {
    test_get_airbase_happy,
    test_get_unit_happy,
    test_get_unit_by_id,
    test_get_unit_no_warehouse,
    test_get_airbase_not_found,
    test_get_arg_validation,
    test_get_mission_not_loaded,
    test_set_clear_zeros_everything,
    test_set_unlimited_true,
    test_set_unlimited_false,
    test_set_clear_aircrafts_only,
    test_set_clear_fuel_only,
    test_set_clear_munitions_only,
    test_set_unlimited_per_category,
    test_set_operating_levels,
    test_set_fuel_override,
    test_set_fuel_override_unknown_type,
    test_set_aircraft_override,
    test_set_aircraft_override_unknown,
    test_set_aircraft_override_partial_match_candidates,
    test_set_weapon_override_by_name,
    test_set_weapon_override_new_entry_appended,
    test_set_weapon_override_ambiguous,
    test_set_weapon_override_unknown,
    test_set_weapon_override_bad_shape,
    test_set_atomic_validation_no_partial_writes,
    test_set_unit_happy,
    test_set_unit_no_warehouse,
    test_set_arg_validation,
}

for _, t in ipairs(tests) do t() end

print(string.format('test_verbs_resources: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
