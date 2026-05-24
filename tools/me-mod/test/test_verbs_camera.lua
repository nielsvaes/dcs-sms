-- test_verbs_camera.lua — Lua-side unit tests for verbs/camera_verbs.lua.

local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path

local mock = require('mock_me_mission')
package.preload['me_mission']    = function() return mock end
package.preload['me_map_window'] = function() return mock end

-- ============================================================
-- _G.MapWindow + _G.Terrain stubs
-- ============================================================

local map_state = { x = 0, y = 0, scale = 100 }

_G.MapWindow = {}
function _G.MapWindow.setCamera(x, y)
    map_state.x, map_state.y = x, y
end
function _G.MapWindow.setScale(s) map_state.scale = s end
function _G.MapWindow.getScale() return map_state.scale end
function _G.MapWindow.getCenterMap(_a, _b) return map_state.x, map_state.y end

_G.Terrain = {}
function _G.Terrain.convertMetersToLatLon(x, y)
    return x / 111000, y / 85000
end
function _G.Terrain.convertLatLonToMeters(lat, lon)
    return lat * 111000, lon * 85000
end
function _G.Terrain.getRunwayList() return {} end

-- Mission.AirdromeController stub.
local airdromes = {
    {
        x = 12345, y = 67890,
        getName = function(self) return 'Anapa-Vityazevo' end,
        getCoalitionName = function(self) return 'blue' end,
        getAirdromeNumber = function(self) return 12 end,
        getRoadnet = function(self) return {} end,
    },
}
package.preload['Mission.AirdromeController'] = function()
    return { getAirdromes = function() return airdromes end }
end

-- Stubs for sibling verb modules pulled in by the aggregator.
package.preload['terrain']      = function() return { GetSurfaceType = function() return 'sea' end } end
package.preload['utils_common'] = function() return { actions = {} } end
package.preload['me_db_api']    = function() return { templates = {}, unit_by_type = {} } end
package.preload['me_payload']   = function() return { setDefaultLivery = function() end } end
package.preload['me_route']     = function()
    return { isAirfieldWaypoint = function() return false end,
             attractToAirfield = function() end, update = function() end }
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
package.preload['dcs_sms_me.warehouse_ops'] = function() return { extract = function() end, apply = function() end, _deep_copy = function(t) return t end } end

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
    -- camera_focus refuses if mission.map subtable is absent — populate it.
    mock.mission.map = { centerX = 0, centerY = 0, zoom = 100 }
    map_state.x, map_state.y, map_state.scale = 0, 0, 100
end

-- ============================================================
-- camera_focus
-- ============================================================

local function test_focus_by_name()
    reset()
    local r = verbs.camera_focus({ name = 'Anapa' })
    assert_true(r.ok, 'focus by name: ok')
    assert_eq(r.name, 'Anapa-Vityazevo', 'focus: returns full name')
    assert_eq(r.x, 12345, 'focus: x = airdrome.x')
    assert_eq(r.y, 67890, 'focus: y = airdrome.y')
    assert_eq(map_state.x, 12345, 'focus: MapWindow.x updated')
    assert_eq(map_state.y, 67890, 'focus: MapWindow.y updated')
end

local function test_focus_by_lat_lon()
    reset()
    local r = verbs.camera_focus({ lat = 45.0, lon = 36.0 })
    assert_true(r.ok, 'focus by lat/lon: ok')
    assert_eq(r.lat, 45.0, 'focus: lat preserved')
    assert_eq(r.lon, 36.0, 'focus: lon preserved')
    assert_eq(r.x, 45.0 * 111000, 'focus: x = lat*111k')
end

local function test_focus_by_xy()
    reset()
    local r = verbs.camera_focus({ x = 5000, y = 6000 })
    assert_true(r.ok, 'focus by x/y: ok')
    assert_eq(map_state.x, 5000, 'focus: x applied')
    assert_eq(map_state.y, 6000, 'focus: y applied')
end

local function test_focus_with_scale()
    reset()
    local r = verbs.camera_focus({ x = 1000, y = 2000, scale = 250 })
    assert_true(r.ok, 'focus with scale: ok')
    assert_eq(r.scale, 250, 'focus: scale returned')
    assert_eq(map_state.scale, 250, 'focus: scale applied')
end

local function test_focus_no_target()
    reset()
    local r = verbs.camera_focus({})
    assert_false(r.ok, 'focus no target: refused')
    assert_contains(r.error, '--name', 'focus: error msg')
end

local function test_focus_unknown_airbase()
    reset()
    local r = verbs.camera_focus({ name = 'Atlantis' })
    assert_false(r.ok, 'focus unknown airbase: refused')
    assert_contains(r.error, 'no airdrome', 'focus: error msg')
end

local function test_focus_no_mission_loaded()
    -- mission.map subtable missing → refuse
    mock.new_mission()
    mock.mission.map = nil
    local r = verbs.camera_focus({ x = 0, y = 0 })
    assert_false(r.ok, 'focus no mission: refused')
    assert_contains(r.error, 'no mission open', 'focus: error msg')
end

local function test_focus_no_mapwindow()
    reset()
    local saved = _G.MapWindow
    _G.MapWindow = nil
    local r = verbs.camera_focus({ x = 0, y = 0 })
    assert_false(r.ok, 'focus no MapWindow: refused')
    _G.MapWindow = saved
end

local function test_focus_lat_only_refused()
    reset()
    -- Only lat passed, no lon → falls through to no-target error
    local r = verbs.camera_focus({ lat = 45 })
    assert_false(r.ok, 'focus lat only: refused')
end

-- ============================================================
-- camera_get
-- ============================================================

local function test_get_happy()
    reset()
    map_state.x = 5000
    map_state.y = 7000
    map_state.scale = 150
    local r = verbs.camera_get({})
    assert_true(r.ok, 'get: ok')
    assert_eq(r.x, 5000, 'get: x')
    assert_eq(r.y, 7000, 'get: y')
    assert_eq(r.scale, 150, 'get: scale')
    assert_true(type(r.lat) == 'number', 'get: lat number')
end

local function test_get_no_mapwindow()
    reset()
    local saved = _G.MapWindow
    _G.MapWindow = nil
    local r = verbs.camera_get({})
    assert_false(r.ok, 'get no MapWindow: refused')
    _G.MapWindow = saved
end

-- ============================================================
-- Test runner
-- ============================================================

local tests = {
    test_focus_by_name,
    test_focus_by_lat_lon,
    test_focus_by_xy,
    test_focus_with_scale,
    test_focus_no_target,
    test_focus_unknown_airbase,
    test_focus_no_mission_loaded,
    test_focus_no_mapwindow,
    test_focus_lat_only_refused,
    test_get_happy,
    test_get_no_mapwindow,
}

for _, t in ipairs(tests) do t() end

print(string.format('test_verbs_camera: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
