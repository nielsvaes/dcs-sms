-- test_verbs_coords.lua — Lua-side unit tests for verbs/coords_verbs.lua.

local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path

local mock = require('mock_me_mission')
package.preload['me_mission']    = function() return mock end
package.preload['me_map_window'] = function() return mock end

-- ============================================================
-- _G.Terrain stub — fake but invertible conversion so we can
-- assert round-trips without depending on a real theatre.
-- ============================================================

_G.Terrain = {}
function _G.Terrain.convertMetersToLatLon(x, y)
    return x / 111000, y / 85000
end
function _G.Terrain.convertLatLonToMeters(lat, lon)
    return lat * 111000, lon * 85000
end

-- magvar stub — get_mag_decl returns its lat argument verbatim (as pseudo-
-- radians) so tests can verify both the radian→degree conversion and that the
-- north/east path feeds the Terrain-converted lat through to magvar.
package.preload['magvar'] = function()
    return { get_mag_decl = function(lat, lon) return lat end }
end

-- Stubs for sibling verb modules pulled in by the aggregator. The aggregator
-- requires every noun file at load time, so anything those files require has
-- to be on the package.preload path before we require('dcs_sms_me.verbs').
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

local function assert_near(actual, expected, eps, name)
    if type(actual) == 'number' and math.abs(actual - expected) <= eps then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(errors, string.format('%s: expected %s ±%s, got %s',
            name, tostring(expected), tostring(eps), tostring(actual)))
    end
end

-- ============================================================
-- coords_to_geo
-- ============================================================

local function test_to_geo_happy()
    local r = verbs.coords_to_geo({ north = 155314, east = -37598.8 })
    assert_true(r.ok, 'to_geo: ok')
    assert_eq(r.lat, 155314 / 111000, 'to_geo: lat from stub')
    assert_eq(r.lon, -37598.8 / 85000, 'to_geo: lon from stub')
    -- Echoes input.
    assert_eq(r.north, 155314, 'to_geo: north echoed')
    assert_eq(r.east, -37598.8, 'to_geo: east echoed')
    -- No alt in → no alt out.
    assert_eq(r.alt, nil, 'to_geo: alt omitted when not given')
end

local function test_to_geo_with_alt()
    local r = verbs.coords_to_geo({ north = 0, east = 0, alt = 194 })
    assert_true(r.ok, 'to_geo with alt: ok')
    assert_eq(r.alt, 194, 'to_geo: alt passed through unchanged')
end

local function test_to_geo_origin()
    -- (0, 0) is the theatre origin — should round-trip to lat=0, lon=0
    -- with our stub. Catches sign-flip / arg-swap bugs.
    local r = verbs.coords_to_geo({ north = 0, east = 0 })
    assert_true(r.ok, 'to_geo origin: ok')
    assert_eq(r.lat, 0, 'to_geo origin: lat=0')
    assert_eq(r.lon, 0, 'to_geo origin: lon=0')
end

local function test_to_geo_missing_north()
    local r = verbs.coords_to_geo({ east = 0 })
    assert_false(r.ok, 'to_geo no north: refused')
    assert_contains(r.error, '--north', 'to_geo: error names --north')
end

local function test_to_geo_missing_east()
    local r = verbs.coords_to_geo({ north = 0 })
    assert_false(r.ok, 'to_geo no east: refused')
    assert_contains(r.error, '--east', 'to_geo: error names --east')
end

local function test_to_geo_bad_alt()
    local r = verbs.coords_to_geo({ north = 0, east = 0, alt = 'banana' })
    assert_false(r.ok, 'to_geo bad alt: refused')
end

local function test_to_geo_no_terrain()
    -- Theatre-not-loaded fallback. Save / restore so other tests keep working.
    local saved = _G.Terrain
    _G.Terrain = nil
    local r = verbs.coords_to_geo({ north = 0, east = 0 })
    _G.Terrain = saved
    assert_false(r.ok, 'to_geo no terrain: refused')
    assert_contains(r.error, 'theatre not loaded', 'to_geo: error mentions theatre')
end

local function test_to_geo_bad_args_table()
    local r = verbs.coords_to_geo('not a table')
    assert_false(r.ok, 'to_geo bad args: refused')
end

-- ============================================================
-- coords_to_local
-- ============================================================

local function test_to_local_happy()
    local r = verbs.coords_to_local({ lat = 50.891186, lon = -0.754503 })
    assert_true(r.ok, 'to_local: ok')
    assert_eq(r.north, 50.891186 * 111000, 'to_local: north from stub')
    assert_eq(r.east, -0.754503 * 85000, 'to_local: east from stub')
    assert_eq(r.lat, 50.891186, 'to_local: lat echoed')
    assert_eq(r.lon, -0.754503, 'to_local: lon echoed')
    assert_eq(r.alt, nil, 'to_local: alt omitted when not given')
end

local function test_to_local_with_alt()
    local r = verbs.coords_to_local({ lat = 0, lon = 0, alt = 194 })
    assert_true(r.ok, 'to_local with alt: ok')
    assert_eq(r.alt, 194, 'to_local: alt passed through unchanged')
end

local function test_to_local_roundtrip()
    -- to_geo → to_local round-trip should return the same north/east with
    -- our linear stub. Real-theatre conversion is non-linear so this
    -- assertion only holds for the stub; the test guards the wiring
    -- (args go in the right slot, returns are unpacked in the right order)
    -- not the underlying math.
    local g = verbs.coords_to_geo({ north = 12345, east = -6789 })
    assert_true(g.ok, 'roundtrip step 1: ok')
    local l = verbs.coords_to_local({ lat = g.lat, lon = g.lon })
    assert_true(l.ok, 'roundtrip step 2: ok')
    -- Float round-trip via division+multiplication accumulates ~1e-12 error.
    assert_near(l.north, 12345, 1e-6, 'roundtrip: north preserved')
    assert_near(l.east, -6789, 1e-6, 'roundtrip: east preserved')
end

local function test_to_local_missing_lat()
    local r = verbs.coords_to_local({ lon = 0 })
    assert_false(r.ok, 'to_local no lat: refused')
    assert_contains(r.error, '--lat', 'to_local: error names --lat')
end

local function test_to_local_missing_lon()
    local r = verbs.coords_to_local({ lat = 0 })
    assert_false(r.ok, 'to_local no lon: refused')
    assert_contains(r.error, '--lon', 'to_local: error names --lon')
end

local function test_to_local_no_terrain()
    local saved = _G.Terrain
    _G.Terrain = nil
    local r = verbs.coords_to_local({ lat = 0, lon = 0 })
    _G.Terrain = saved
    assert_false(r.ok, 'to_local no terrain: refused')
end

-- ============================================================
-- coords_magvar (GH#73, request 1)
-- ============================================================

local function test_magvar_latlon()
    -- Stub get_mag_decl returns lat as "radians"; verb converts to degrees.
    local r = verbs.coords_magvar({ lat = 0.5, lon = 1.0 })
    assert_true(r.ok, 'magvar latlon: ok')
    assert_eq(r.decl_rad, 0.5, 'magvar: decl_rad is raw stub value')
    assert_near(r.decl_deg, math.deg(0.5), 1e-9, 'magvar: decl_deg = math.deg(rad)')
    assert_eq(r.lat, 0.5, 'magvar: lat echoed')
    assert_eq(r.lon, 1.0, 'magvar: lon echoed')
    assert_eq(r.north, nil, 'magvar latlon: no north field')
end

local function test_magvar_northeast()
    -- north/east → Terrain stub (north/111000) → magvar(lat) → degrees.
    local r = verbs.coords_magvar({ north = 111000, east = 85000 })
    assert_true(r.ok, 'magvar ne: ok')
    assert_near(r.lat, 1.0, 1e-9, 'magvar ne: lat from Terrain stub')
    assert_near(r.decl_rad, 1.0, 1e-9, 'magvar ne: decl_rad = converted lat')
    assert_near(r.decl_deg, math.deg(1.0), 1e-9, 'magvar ne: decl_deg in degrees')
    assert_eq(r.north, 111000, 'magvar ne: north echoed')
    assert_eq(r.east, 85000, 'magvar ne: east echoed')
end

local function test_magvar_both_pairs_refused()
    local r = verbs.coords_magvar({ lat = 1, lon = 2, north = 3, east = 4 })
    assert_false(r.ok, 'magvar both pairs: refused')
end

local function test_magvar_no_pair_refused()
    local r = verbs.coords_magvar({})
    assert_false(r.ok, 'magvar no pair: refused')
end

local function test_magvar_no_terrain()
    local saved = _G.Terrain
    _G.Terrain = nil
    local r = verbs.coords_magvar({ north = 0, east = 0 })
    _G.Terrain = saved
    assert_false(r.ok, 'magvar ne no terrain: refused')
    assert_contains(r.error, 'theatre not loaded', 'magvar: error mentions theatre')
end

-- ============================================================
-- Test runner
-- ============================================================

local tests = {
    test_to_geo_happy,
    test_to_geo_with_alt,
    test_to_geo_origin,
    test_to_geo_missing_north,
    test_to_geo_missing_east,
    test_to_geo_bad_alt,
    test_to_geo_no_terrain,
    test_to_geo_bad_args_table,
    test_to_local_happy,
    test_to_local_with_alt,
    test_to_local_roundtrip,
    test_to_local_missing_lat,
    test_to_local_missing_lon,
    test_to_local_no_terrain,
    test_magvar_latlon,
    test_magvar_northeast,
    test_magvar_both_pairs_refused,
    test_magvar_no_pair_refused,
    test_magvar_no_terrain,
}

for _, t in ipairs(tests) do t() end

print(string.format('test_verbs_coords: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
