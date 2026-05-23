-- test_verbs_airbase.lua — Lua-side unit tests for verbs/airbase_verbs.lua.

local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path

local mock = require('mock_me_mission')
package.preload['me_mission']    = function() return mock end
package.preload['me_map_window'] = function() return mock end

-- ============================================================
-- _G.Terrain global stub
-- ============================================================
-- airbase verbs call Terrain.convertMetersToLatLon and Terrain.getRunwayList
-- directly as a global (DCS's bridge env has Terrain at _G).

_G.Terrain = {}
function _G.Terrain.convertMetersToLatLon(x, y)
    -- Trivial linear mapping, just to give the verb something to return.
    return x / 111000, y / 85000
end
function _G.Terrain.getRunwayList(roadnet)
    if not roadnet then return {} end
    return {
        {
            course = math.rad(90),  -- 90° (east) in radians
            edge1name = '09', edge1x = 100, edge1y = 200,
            edge2name = '27', edge2x = 3100, edge2y = 200,
        },
    }
end

-- ============================================================
-- Mission.AirdromeController + airdrome stub
-- ============================================================

local roadnet_stub = { _id = 'rn-1' }

local function make_airdrome(opts)
    return {
        x = opts.x, y = opts.y,
        _coalition = opts.coalition,
        _name = opts.name,
        _number = opts.number,
        _roadnet = roadnet_stub,
        _frequencies = opts.frequencies or { { 305e6 }, { 250e6 } },
        getName = function(self) return self._name end,
        getCoalitionName = function(self) return self._coalition end,
        getAirdromeNumber = function(self) return self._number end,
        getRoadnet = function(self) return self._roadnet end,
        getFrequencyList = function(self) return self._frequencies end,
        getHeight = function(self) return 100 end,
        getAngle = function(self) return math.rad(90) end,
        getWarehouses = function(self) return { 'wh1' } end,
        getFueldepots = function(self) return { 'fd1', 'fd2' } end,
    }
end

local airdromes = {
    make_airdrome({ name = 'Anapa-Vityazevo', number = 12,
                    coalition = 'blue', x = 100, y = 200 }),
    make_airdrome({ name = 'Krasnodar-Center', number = 13,
                    coalition = 'red',  x = 300, y = 400 }),
    make_airdrome({ name = 'Senaki-Kolkhi', number = 14,
                    coalition = 'neutrals', x = 500, y = 600 }),
}

package.preload['Mission.AirdromeController'] = function()
    return { getAirdromes = function() return airdromes end }
end

-- me_parking stub. Stands keyed by crossroad_index per real ME.
local stands_data = {
    [101] = { name = '08', crossroad_index = 101, x = 5000, y = 6000,
              params = { FOR_AIRPLANES = 1, FOR_HELICOPTERS = 0,
                         WIDTH = 30, LENGTH = 60, HEIGHT = 0, SHELTER = 0 } },
    [102] = { name = 'H1', crossroad_index = 102, x = 5100, y = 6100,
              params = { FOR_AIRPLANES = 0, FOR_HELICOPTERS = 1,
                         WIDTH = 15, LENGTH = 15, SHELTER = 1 } },
    [103] = { name = 'shel-01', crossroad_index = 103, x = 5200, y = 6200,
              params = { FOR_AIRPLANES = 1, FOR_HELICOPTERS = 0,
                         WIDTH = 25, LENGTH = 60, SHELTER = 1 } },
}
package.preload['me_parking'] = function()
    return {
        getStandList = function(_rn) return stands_data end,
        getRightParkingAirport = function(s, _g) return s end,
    }
end

-- warehouse_ops stub. extract returns a default entry for our 3 airdromes;
-- apply persists changes to an in-memory table tests can inspect.
local wh_storage = {
    [12] = { coalition = 'blue',     resources = { fuel = 100 } },
    [13] = { coalition = 'red',      resources = { fuel = 100 } },
    [14] = { coalition = 'neutrals', resources = { fuel = 100 } },
}
package.preload['dcs_sms_me.warehouse_ops'] = function()
    return {
        extract = function(airdrome_number)
            return wh_storage[airdrome_number]
        end,
        is_default = function(_e) return false end,
        apply = function(airdrome_number, entry)
            if not wh_storage[airdrome_number] then
                return false, 'no warehouse for ' .. airdrome_number
            end
            wh_storage[airdrome_number] = entry
            return true, nil
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
package.preload['me_predicates'] = function() return { rulesDescr = {} } end
package.preload['me_trigrules']  = function() return {
    actionsDescr = {}, triggersDescr = {} } end
package.preload['dictionary']    = function() return {
    fixDict = function() end, getValueDict = function() end } end
package.preload['Mission.TriggerZoneData'] = function() return {
    getTriggerZoneIds = function() return {} end,
    getTriggerZoneName = function() end } end
package.preload['me_draw_panel'] = function() return {
    saveToMission = function() return { layers = {} } end,
    loadFromMission = function() end,
    getObjects = function() return {} end,
    objectDelete = function() end } end

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

-- ============================================================
-- airbase_list
-- ============================================================

local function test_list_all()
    mock.new_mission()
    local r = verbs.airbase_list({})
    assert_true(r.ok, 'list: ok')
    assert_eq(r.count, 3, 'list: count = 3')
    -- Alphabetical by name
    assert_eq(r.airbases[1].name, 'Anapa-Vityazevo', 'list: sorted alpha')
    assert_eq(r.airbases[3].name, 'Senaki-Kolkhi', 'list: last entry')
end

local function test_list_summary_fields()
    local r = verbs.airbase_list({})
    local first = r.airbases[1]
    assert_eq(first.airdrome_number, 12, 'list summary: airdrome_number')
    assert_eq(first.coalition, 'blue', 'list summary: coalition')
    assert_eq(first.x, 100, 'list summary: x')
    assert_eq(first.y, 200, 'list summary: y')
    assert_true(type(first.lat) == 'number', 'list summary: lat number')
    assert_true(type(first.lon) == 'number', 'list summary: lon number')
end

local function test_list_filter_coalition()
    local r = verbs.airbase_list({ coalition = 'red' })
    assert_eq(r.count, 1, 'list coalition=red: count = 1')
    assert_eq(r.airbases[1].name, 'Krasnodar-Center', 'list red: Krasnodar')
end

local function test_list_filter_all_empty()
    local r1 = verbs.airbase_list({ coalition = 'all' })
    local r2 = verbs.airbase_list({ coalition = '' })
    assert_eq(r1.count, 3, 'list coalition=all: count = 3')
    assert_eq(r2.count, 3, 'list coalition="": count = 3')
end

-- ============================================================
-- airbase_get
-- ============================================================

local function test_get_happy()
    local r = verbs.airbase_get({ name = 'Anapa-Vityazevo' })
    assert_true(r.ok, 'get: ok')
    assert_eq(r.airdrome_number, 12, 'get: airdrome_number')
    assert_eq(r.coalition, 'blue', 'get: coalition')
    assert_eq(r.height_m, 100, 'get: height_m')
    assert_eq(r.warehouses_count, 1, 'get: warehouses_count')
    assert_eq(r.fueldepots_count, 2, 'get: fueldepots_count')
end

local function test_get_substring_match()
    local r = verbs.airbase_get({ name = 'Anapa' })
    assert_true(r.ok, 'get substring: ok')
    assert_eq(r.name, 'Anapa-Vityazevo', 'get substring: full name returned')
end

local function test_get_includes_stands_and_runways()
    local r = verbs.airbase_get({ name = 'Anapa' })
    assert_true(#r.stands >= 1, 'get: stands array non-empty')
    assert_true(#r.runways >= 1, 'get: runways array non-empty')
    assert_eq(r.runways[1].edge1.name, '09', 'get: runway edge name')
    assert_true(r.runways[1].course_deg > 89 and r.runways[1].course_deg < 91,
                'get: runway course_deg ≈ 90')
end

local function test_get_stands_filter_plane()
    local r = verbs.airbase_get({ name = 'Anapa', filter = 'plane' })
    -- We have 3 stands total; 2 plane-capable (08, shel-01), 1 helo-only (H1).
    assert_eq(#r.stands, 2, 'get filter=plane: 2 stands')
    for _, s in ipairs(r.stands) do
        assert_true(s.for_planes, 'get filter=plane: stand for_planes')
    end
end

local function test_get_stands_filter_helicopter()
    local r = verbs.airbase_get({ name = 'Anapa', filter = 'helicopter' })
    assert_eq(#r.stands, 1, 'get filter=helicopter: 1 stand')
    assert_eq(r.stands[1].name, 'H1', 'get filter=helicopter: H1')
end

local function test_get_stands_fields()
    local r = verbs.airbase_get({ name = 'Anapa', filter = 'plane' })
    local s = r.stands[1]  -- alphabetical → '08' first
    assert_eq(s.name, '08', 'get stand: name')
    assert_eq(s.crossroad_index, 101, 'get stand: crossroad_index')
    assert_eq(s.width_m, 30, 'get stand: width_m')
    assert_eq(s.length_m, 60, 'get stand: length_m')
    assert_eq(s.shelter, false, 'get stand: shelter = false')
end

local function test_get_frequencies()
    local r = verbs.airbase_get({ name = 'Anapa' })
    assert_eq(#r.frequencies, 2, 'get: 2 frequencies')
    assert_eq(r.frequencies[1].hz, 305e6, 'get freq: hz')
    assert_true(math.abs(r.frequencies[1].mhz - 305) < 0.01, 'get freq: mhz conversion')
end

local function test_get_not_found()
    local r = verbs.airbase_get({ name = 'Atlantis' })
    assert_false(r.ok, 'get not found: refused')
    assert_contains(r.error, 'no airbase', 'get: error msg')
end

local function test_get_arg_validation()
    assert_false(verbs.airbase_get({}).ok, 'get: missing name')
    assert_false(verbs.airbase_get({ name = '' }).ok, 'get: empty name')
end

-- ============================================================
-- airbase_set_coalition
-- ============================================================

local function test_set_coalition_happy()
    wh_storage[12] = { coalition = 'blue', resources = { fuel = 100 } }
    local r = verbs.airbase_set_coalition({ name = 'Anapa', coalition = 'red' })
    assert_true(r.ok, 'set_coalition: ok')
    assert_eq(r.coalition, 'red', 'set_coalition: returns new coalition')
    assert_eq(wh_storage[12].coalition, 'red', 'set_coalition: persisted')
end

local function test_set_coalition_neutral_normalized()
    wh_storage[12] = { coalition = 'blue', resources = {} }
    local r = verbs.airbase_set_coalition({ name = 'Anapa', coalition = 'neutral' })
    assert_true(r.ok, 'set_coalition neutral: ok')
    assert_eq(r.coalition, 'neutrals', 'set_coalition: singular → plural')
end

local function test_set_coalition_neutrals_plural_accepted()
    wh_storage[12] = { coalition = 'blue', resources = {} }
    local r = verbs.airbase_set_coalition({ name = 'Anapa', coalition = 'neutrals' })
    assert_true(r.ok, 'set_coalition neutrals: ok')
end

local function test_set_coalition_case_insensitive()
    wh_storage[12] = { coalition = 'blue', resources = {} }
    local r = verbs.airbase_set_coalition({ name = 'Anapa', coalition = 'RED' })
    assert_true(r.ok, 'set_coalition uppercase: ok')
    assert_eq(r.coalition, 'red', 'set_coalition: case-normalized')
end

local function test_set_coalition_unknown()
    local r = verbs.airbase_set_coalition({ name = 'Anapa', coalition = 'pirate' })
    assert_false(r.ok, 'set_coalition unknown: refused')
    assert_contains(r.error, 'must be red, blue', 'set_coalition: error msg')
end

local function test_set_coalition_missing_airbase()
    local r = verbs.airbase_set_coalition({ name = 'Atlantis', coalition = 'red' })
    assert_false(r.ok, 'set_coalition: missing airbase refused')
end

local function test_set_coalition_arg_validation()
    assert_false(verbs.airbase_set_coalition({}).ok, 'set_coalition: missing name')
    assert_false(verbs.airbase_set_coalition({ name = '' }).ok, 'set_coalition: empty name')
    assert_false(verbs.airbase_set_coalition({ name = 'Anapa' }).ok,
                 'set_coalition: missing coalition')
end

-- ============================================================
-- Test runner
-- ============================================================

local tests = {
    test_list_all,
    test_list_summary_fields,
    test_list_filter_coalition,
    test_list_filter_all_empty,
    test_get_happy,
    test_get_substring_match,
    test_get_includes_stands_and_runways,
    test_get_stands_filter_plane,
    test_get_stands_filter_helicopter,
    test_get_stands_fields,
    test_get_frequencies,
    test_get_not_found,
    test_get_arg_validation,
    test_set_coalition_happy,
    test_set_coalition_neutral_normalized,
    test_set_coalition_neutrals_plural_accepted,
    test_set_coalition_case_insensitive,
    test_set_coalition_unknown,
    test_set_coalition_missing_airbase,
    test_set_coalition_arg_validation,
}

for _, t in ipairs(tests) do t() end

print(string.format('test_verbs_airbase: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
