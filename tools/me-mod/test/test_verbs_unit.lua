-- test_verbs_unit.lua — Lua-side unit tests for verbs/unit_verbs.lua and
-- unit_set_parking (which lives in route_verbs.lua but is dispatched as a
-- unit verb).

local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path

local mock = require('mock_me_mission')
package.preload['me_mission']    = function() return mock end
package.preload['me_map_window'] = function() return mock end

-- me_db_api stub. Defines Pylons + Launchers for a couple of airframes so
-- unit_payload_set / unit_payload_clear can validate against them. Also
-- supplies the templates table used by group_set_formation (not exercised
-- here but the shared mock loads it).
package.preload['me_db_api'] = function()
    return {
        templates = {},
        unit_by_type = {
            ['F-16C_50'] = {
                Pylons = {
                    { Number = 1, Launchers = {
                        { CLSID = '{AIM-9X}', obsolete = false },
                        { CLSID = '{AIM-9M}', obsolete = false },
                        { CLSID = '{AIM-9P}', obsolete = true },
                    } },
                    { Number = 2, Launchers = {
                        { CLSID = '{AIM-120}', obsolete = false },
                    } },
                    { Number = 3, Launchers = {
                        { CLSID = '{Mk82AIR}',  obsolete = false },
                    } },
                },
            },
            ['UH-1H'] = { Pylons = {} },
        },
    }
end

-- me_loadoututils stub. Returns canned pylon assignments per (type, loadout).
package.preload['me_loadoututils'] = function()
    return {
        getUnitPylons = function(unit_type, loadout_name)
            if unit_type == 'F-16C_50' and loadout_name == 'CAP' then
                return {
                    [1] = { CLSID = '{AIM-9X}' },
                    [2] = { CLSID = '{AIM-120}' },
                }
            end
            if unit_type == 'F-16C_50' and loadout_name == 'Empty' then
                return {}
            end
            return nil
        end,
    }
end

-- Global helper get_weapon_display_name_by_clsid (used by _resolve_weapon
-- for display-name lookups). Map a small set of CLSIDs to friendly names.
local clsid_display = {
    ['{AIM-9X}']    = 'AIM-9X Sidewinder',
    ['{AIM-9M}']    = 'AIM-9M Sidewinder',
    ['{AIM-120}']   = 'AIM-120C AMRAAM',
    ['{Mk82AIR}']   = 'Mk-82 (AIR)',
}
_G.get_weapon_display_name_by_clsid = function(clsid) return clsid_display[clsid] end

-- Mission.AirdromeController + me_parking stubs for unit_set_parking.
local roadnet_stub = { _id = 'roadnet-anapa' }
local airdromes = {
    {
        x = 12345, y = 67890,
        _roadnet = roadnet_stub,
        getName = function(self) return 'Anapa-Vityazevo' end,
        getAirdromeNumber = function(self) return 12 end,
        getRoadnet = function(self) return self._roadnet end,
    },
}
package.preload['Mission.AirdromeController'] = function()
    return { getAirdromes = function() return airdromes end }
end

local me_parking_stub = {}
-- Real ME keys stands by crossroad_index. The verb relies on this when it
-- checks `filtered[match.crossroad_index]` after the size-filter pass.
me_parking_stub.stands = {
    [101] = { name = '08', crossroad_index = 101, x = 5000, y = 6000,
              params = { FOR_AIRPLANES = 1, FOR_HELICOPTERS = 0,
                         WIDTH = 30, LENGTH = 60 } },
    [102] = { name = 'H1', crossroad_index = 102, x = 5100, y = 6100,
              params = { FOR_AIRPLANES = 0, FOR_HELICOPTERS = 1,
                         WIDTH = 15, LENGTH = 15 } },
    [103] = { name = 'tiny', crossroad_index = 103, x = 5200, y = 6200,
              params = { FOR_AIRPLANES = 1, FOR_HELICOPTERS = 0,
                         WIDTH = 5, LENGTH = 5 } },
}
function me_parking_stub.setAirGroupOnAirport(g, x, y)
    me_parking_stub.setAirGroupOnAirport_calls = (me_parking_stub.setAirGroupOnAirport_calls or 0) + 1
    -- Move every unit to (x, y) to mimic the real ME's parking placement.
    for _, u in ipairs(g.units or {}) do u.x = x; u.y = y end
    return true
end
function me_parking_stub.setAirGroupOnAirportRunway(g, x, y)
    me_parking_stub.setAirGroupOnAirportRunway_calls =
        (me_parking_stub.setAirGroupOnAirportRunway_calls or 0) + 1
    for _, u in ipairs(g.units or {}) do u.x = x; u.y = y end
    return true
end
function me_parking_stub.getStandList(_roadnet) return me_parking_stub.stands end
function me_parking_stub.getRightParkingAirport(stands, _g)
    -- Simulate ME's size filter: drop 'tiny'.
    local out = {}
    for k, v in pairs(stands) do
        if v.name ~= 'tiny' then out[k] = v end
    end
    return out
end
package.preload['me_parking'] = function() return me_parking_stub end

-- group_verbs require utils_common / me_payload / me_route; we don't
-- exercise them here but they're loaded by the shared verbs aggregator.
package.preload['utils_common'] = function()
    return { actions = {} }
end
package.preload['me_payload'] = function()
    return { setDefaultLivery = function() end }
end
package.preload['me_route'] = function()
    return { isAirfieldWaypoint = function() return false end,
             attractToAirfield = function() end,
             update = function() end }
end

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
-- unit_set_name
-- ============================================================

local function test_set_name_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'sn1' })
    local r = verbs.unit_set_name({ name = g.units[1].name, new_name = 'sn1-renamed' })
    assert_true(r.ok, 'set_name: ok')
    assert_eq(g.units[1].name, 'sn1-renamed', 'set_name: applied')
end

local function test_set_name_by_id()
    mock.new_mission()
    local g = mock.add_plane({ name = 'sn1b' })
    local r = verbs.unit_set_name({ id = g.units[1].unitId, new_name = 'sn1b-renamed' })
    assert_true(r.ok, 'set_name by id: ok')
end

local function test_set_name_collision()
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'sn2a' })
    local g2 = mock.add_plane({ name = 'sn2b' })
    local r = verbs.unit_set_name({
        name = g1.units[1].name, new_name = g2.units[1].name })
    assert_false(r.ok, 'set_name collision: refused')
    assert_contains(r.error, 'in use', 'set_name collision: error msg')
end

local function test_set_name_not_found()
    mock.new_mission()
    local r = verbs.unit_set_name({ name = 'ghost', new_name = 'x' })
    assert_false(r.ok, 'set_name not found')
end

local function test_set_name_arg_validation()
    mock.new_mission()
    assert_false(verbs.unit_set_name(nil).ok, 'set_name: nil')
    assert_false(verbs.unit_set_name({}).ok, 'set_name: empty')
    assert_false(verbs.unit_set_name({ name = 'x', id = 1, new_name = 'y' }).ok,
                 'set_name: both selectors')
    assert_false(verbs.unit_set_name({ name = 'x' }).ok, 'set_name: missing new_name')
    assert_false(verbs.unit_set_name({ name = 'x', new_name = '' }).ok,
                 'set_name: empty new_name')
end

-- ============================================================
-- unit_set_skill / set_livery
-- ============================================================

local function test_set_skill_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'sk1' })
    local r = verbs.unit_set_skill({ name = g.units[1].name, skill = 'Excellent' })
    assert_true(r.ok, 'set_skill: ok')
    assert_eq(g.units[1].skill, 'Excellent', 'set_skill: applied')
end

local function test_set_skill_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'sk2' })
    assert_false(verbs.unit_set_skill({}).ok, 'set_skill: empty')
    assert_false(verbs.unit_set_skill({ name = 'sk2' }).ok, 'set_skill: missing skill')
    assert_false(verbs.unit_set_skill({ name = 'sk2', skill = '' }).ok,
                 'set_skill: empty skill')
end

local function test_set_livery_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'lv1' })
    local r = verbs.unit_set_livery({ name = g.units[1].name, livery = 'Aggressors' })
    assert_true(r.ok, 'set_livery: ok')
    assert_eq(g.units[1].livery_id, 'Aggressors', 'set_livery: applied')
end

local function test_set_livery_empty_string_allowed()
    mock.new_mission()
    local g = mock.add_plane({ name = 'lv2' })
    local r = verbs.unit_set_livery({ name = g.units[1].name, livery = '' })
    assert_true(r.ok, 'set_livery empty: ok (means default)')
    assert_eq(g.units[1].livery_id, '', 'set_livery empty: applied')
end

local function test_set_livery_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'lv3' })
    assert_false(verbs.unit_set_livery({ name = 'lv3' }).ok,
                 'set_livery: missing livery')
end

-- ============================================================
-- unit_set_pos
-- ============================================================

local function test_set_pos_happy()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'pos1', x = 0, y = 0 })
    local u = g.units[1]
    mock.reset_refresh_counters()
    local r = verbs.unit_set_pos({ name = u.name, north = 1000, east = 2000 })
    assert_true(r.ok, 'set_pos: ok')
    assert_eq(u.x, 1000, 'set_pos: u.x updated')
    assert_eq(u.y, 2000, 'set_pos: u.y updated')
    assert_eq(mock.refresh_calls.update, 1, 'set_pos: refresh called')
end

local function test_set_pos_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'pos2' })
    assert_false(verbs.unit_set_pos({}).ok, 'set_pos: empty')
    assert_false(verbs.unit_set_pos({ name = 'x', north = 1 }).ok, 'set_pos: missing east')
    assert_false(verbs.unit_set_pos({ name = 'x', north = '1', east = 1 }).ok,
                 'set_pos: string north')
end

-- ============================================================
-- unit_set_heading
-- ============================================================

local function test_set_heading_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'hd1' })
    local u = g.units[1]
    local r = verbs.unit_set_heading({ name = u.name, heading_deg = 90 })
    assert_true(r.ok, 'set_heading: ok')
    -- 90° = π/2 rad
    local expected = math.rad(90)
    local diff = math.abs(u.heading - expected)
    assert_true(diff < 1e-9, 'set_heading: u.heading correct')
    assert_eq(u.psi, u.heading, 'set_heading: u.psi = u.heading')
end

local function test_set_heading_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'hd2' })
    assert_false(verbs.unit_set_heading({ name = 'hd2' }).ok,
                 'set_heading: missing heading_deg')
    assert_false(verbs.unit_set_heading({ name = 'hd2', heading_deg = '90' }).ok,
                 'set_heading: string heading_deg')
end

-- ============================================================
-- unit_set_alt
-- ============================================================

local function test_set_alt_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'al1' })
    local u = g.units[1]
    local r = verbs.unit_set_alt({ name = u.name, alt = 6000, alt_type = 'RADIO' })
    assert_true(r.ok, 'set_alt: ok')
    assert_eq(u.alt, 6000, 'set_alt: applied')
    assert_eq(u.alt_type, 'RADIO', 'set_alt: alt_type applied')
end

local function test_set_alt_default_alt_type()
    mock.new_mission()
    local g = mock.add_plane({ name = 'al2' })
    local u = g.units[1]
    local r = verbs.unit_set_alt({ name = u.name, alt = 5000 })
    assert_true(r.ok, 'set_alt default alt_type: ok')
    assert_eq(u.alt_type, 'BARO', 'set_alt: default alt_type = BARO')
end

local function test_set_alt_bad_alt_type()
    mock.new_mission()
    local g = mock.add_plane({ name = 'al3' })
    local u = g.units[1]
    local r = verbs.unit_set_alt({ name = u.name, alt = 5000, alt_type = 'WTF' })
    assert_false(r.ok, 'set_alt bad alt_type: rejected')
    assert_contains(r.error, 'BARO', 'set_alt bad alt_type: error mentions BARO')
end

local function test_set_alt_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'al4' })
    assert_false(verbs.unit_set_alt({ name = 'al4' }).ok, 'set_alt: missing alt')
    assert_false(verbs.unit_set_alt({ name = 'al4', alt = '1000' }).ok,
                 'set_alt: string alt')
end

-- ============================================================
-- unit_set_onboard_num / set_callsign
-- ============================================================

local function test_set_onboard_num_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'ob1' })
    local u = g.units[1]
    local r = verbs.unit_set_onboard_num({ name = u.name, onboard_num = '042' })
    assert_true(r.ok, 'set_onboard_num: ok')
    assert_eq(u.onboard_num, '042', 'set_onboard_num: applied')
end

local function test_set_onboard_num_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'ob2' })
    assert_false(verbs.unit_set_onboard_num({ name = 'ob2' }).ok,
                 'set_onboard_num: missing onboard_num')
    assert_false(verbs.unit_set_onboard_num({ name = 'ob2', onboard_num = '' }).ok,
                 'set_onboard_num: empty')
end

local function test_set_callsign_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'cs1' })
    local u = g.units[1]
    u.callsign = { 2, 3, 4, name = 'Old' }
    local r = verbs.unit_set_callsign({ name = u.name, callsign = 'Uzi11' })
    assert_true(r.ok, 'set_callsign: ok')
    -- numeric prefix preserved (args.squadron etc not passed)
    assert_eq(u.callsign[1], 2, 'set_callsign: squadron preserved')
    assert_eq(u.callsign[2], 3, 'set_callsign: flight preserved')
    assert_eq(u.callsign[3], 4, 'set_callsign: plane preserved')
    assert_eq(u.callsign.name, 'Uzi11', 'set_callsign: name applied')
end

local function test_set_callsign_overrides_numeric()
    mock.new_mission()
    local g = mock.add_plane({ name = 'cs2' })
    local u = g.units[1]
    local r = verbs.unit_set_callsign({
        name = u.name, callsign = 'Enfield', squadron = 5, flight = 1, plane = 1 })
    assert_true(r.ok, 'set_callsign override: ok')
    assert_eq(u.callsign[1], 5, 'set_callsign: squadron applied')
end

local function test_set_callsign_arg_validation()
    mock.new_mission()
    mock.add_plane({ name = 'cs3' })
    assert_false(verbs.unit_set_callsign({ name = 'cs3' }).ok,
                 'set_callsign: missing callsign')
    assert_false(verbs.unit_set_callsign({ name = 'cs3', callsign = '' }).ok,
                 'set_callsign: empty callsign')
end

-- ============================================================
-- unit_payload_set / clear
-- ============================================================

local function _setup_f16(name)
    mock.new_mission()
    local g = mock.add_plane({ name = name, unit_type = 'F-16C_50' })
    g.units[1].type = 'F-16C_50'
    return g
end

local function test_payload_set_by_clsid()
    local g = _setup_f16('py1')
    local u = g.units[1]
    local r = verbs.unit_payload_set({
        name = u.name, pylon = 1, weapon = '{AIM-9X}' })
    assert_true(r.ok, 'payload_set CLSID: ok')
    assert_eq(r.clsid, '{AIM-9X}', 'payload_set: returns CLSID')
    assert_eq(u.payload.pylons[1].CLSID, '{AIM-9X}', 'payload_set: pylon updated')
end

local function test_payload_set_by_display_name()
    local g = _setup_f16('py2')
    local u = g.units[1]
    local r = verbs.unit_payload_set({
        name = u.name, pylon = 1, weapon = 'AIM-9M Sidewinder' })
    assert_true(r.ok, 'payload_set display name: ok')
    assert_eq(r.clsid, '{AIM-9M}', 'payload_set display name: resolves to CLSID')
end

local function test_payload_set_display_name_case_insensitive()
    local g = _setup_f16('py2b')
    local u = g.units[1]
    local r = verbs.unit_payload_set({
        name = u.name, pylon = 1, weapon = 'aim-9m sidewinder' })
    assert_true(r.ok, 'payload_set display name lower: ok')
    assert_eq(r.clsid, '{AIM-9M}', 'payload_set: case-insensitive name match')
end

local function test_payload_set_obsolete_refused()
    local g = _setup_f16('py3')
    local u = g.units[1]
    local r = verbs.unit_payload_set({
        name = u.name, pylon = 1, weapon = '{AIM-9P}' })
    assert_false(r.ok, 'payload_set obsolete: refused')
    assert_contains(r.error, 'not valid', 'payload_set obsolete: error msg')
end

local function test_payload_set_wrong_pylon_for_weapon()
    local g = _setup_f16('py4')
    local u = g.units[1]
    local r = verbs.unit_payload_set({
        name = u.name, pylon = 2, weapon = '{AIM-9X}' })  -- AIM-9X is pylon 1
    assert_false(r.ok, 'payload_set wrong pylon: refused')
    assert_contains(r.error, 'not valid', 'payload_set wrong pylon: error msg')
end

local function test_payload_set_unknown_pylon_number()
    local g = _setup_f16('py5')
    local u = g.units[1]
    local r = verbs.unit_payload_set({
        name = u.name, pylon = 99, weapon = '{AIM-9X}' })
    assert_false(r.ok, 'payload_set unknown pylon: refused')
    assert_contains(r.error, 'pylon 99', 'payload_set unknown pylon: error msg')
end

local function test_payload_set_air_only()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'py6', unit_type = 'Hummer' })
    local u = g.units[1]
    local r = verbs.unit_payload_set({
        name = u.name, pylon = 1, weapon = '{AIM-9X}' })
    assert_false(r.ok, 'payload_set ground: refused')
    assert_contains(r.error, 'plane / helicopter', 'payload_set ground: air-only error')
end

local function test_payload_set_arg_validation()
    local g = _setup_f16('py7')
    local u = g.units[1]
    assert_false(verbs.unit_payload_set({ name = u.name, weapon = 'x' }).ok,
                 'payload_set: missing pylon')
    assert_false(verbs.unit_payload_set({ name = u.name, pylon = 1 }).ok,
                 'payload_set: missing weapon')
    assert_false(verbs.unit_payload_set({ name = u.name, pylon = 0, weapon = 'x' }).ok,
                 'payload_set: pylon=0 rejected')
    assert_false(verbs.unit_payload_set({ name = u.name, pylon = -1, weapon = 'x' }).ok,
                 'payload_set: negative pylon')
end

local function test_payload_clear_happy()
    local g = _setup_f16('pc1')
    local u = g.units[1]
    -- Pre-populate pylon 1
    u.payload = { pylons = { [1] = { CLSID = '{AIM-9X}' } } }
    local r = verbs.unit_payload_clear({ name = u.name, pylon = 1 })
    assert_true(r.ok, 'payload_clear: ok')
    assert_eq(r.had_weapon, true, 'payload_clear: had_weapon = true')
    assert_eq(u.payload.pylons[1], nil, 'payload_clear: pylon entry removed')
end

local function test_payload_clear_empty_pylon()
    local g = _setup_f16('pc2')
    local u = g.units[1]
    local r = verbs.unit_payload_clear({ name = u.name, pylon = 1 })
    assert_true(r.ok, 'payload_clear empty: ok')
    assert_eq(r.had_weapon, false, 'payload_clear empty: had_weapon = false')
end

local function test_payload_clear_unknown_pylon()
    local g = _setup_f16('pc3')
    local u = g.units[1]
    local r = verbs.unit_payload_clear({ name = u.name, pylon = 99 })
    assert_false(r.ok, 'payload_clear unknown pylon: refused')
end

-- ============================================================
-- unit_set_loadout
-- ============================================================

local function test_set_loadout_happy()
    local g = _setup_f16('ld1')
    local u = g.units[1]
    local r = verbs.unit_set_loadout({ name = u.name, loadout = 'CAP' })
    assert_true(r.ok, 'set_loadout CAP: ok')
    assert_eq(r.loadout, 'CAP', 'set_loadout: returns loadout name')
    assert_eq(r.pylon_count, 2, 'set_loadout CAP: 2 pylons')
    assert_eq(u.payload.name, 'CAP', 'set_loadout: payload.name set')
    assert_eq(u.payload.pylons[1].CLSID, '{AIM-9X}', 'set_loadout: pylon 1 set')
end

local function test_set_loadout_empty()
    local g = _setup_f16('ld2')
    local u = g.units[1]
    local r = verbs.unit_set_loadout({ name = u.name, loadout = 'Empty' })
    assert_true(r.ok, 'set_loadout Empty: ok')
    assert_eq(r.pylon_count, 0, 'set_loadout Empty: 0 pylons')
end

local function test_set_loadout_unknown()
    local g = _setup_f16('ld3')
    local u = g.units[1]
    local r = verbs.unit_set_loadout({ name = u.name, loadout = 'Bogus' })
    assert_false(r.ok, 'set_loadout unknown: refused')
    assert_contains(r.error, 'not found', 'set_loadout unknown: error msg')
end

local function test_set_loadout_air_only()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'ld4' })
    local u = g.units[1]
    local r = verbs.unit_set_loadout({ name = u.name, loadout = 'CAP' })
    assert_false(r.ok, 'set_loadout vehicle: refused')
end

local function test_set_loadout_arg_validation()
    local g = _setup_f16('ld5')
    local u = g.units[1]
    assert_false(verbs.unit_set_loadout({ name = u.name }).ok,
                 'set_loadout: missing loadout')
    assert_false(verbs.unit_set_loadout({ name = u.name, loadout = '' }).ok,
                 'set_loadout: empty loadout')
end

-- ============================================================
-- unit_set_chaff / flare / fuel / gun
-- ============================================================

local function test_set_chaff_happy()
    local g = _setup_f16('cf1')
    local r = verbs.unit_set_chaff({ name = g.units[1].name, count = 120 })
    assert_true(r.ok, 'set_chaff: ok')
    assert_eq(g.units[1].payload.chaff, 120, 'set_chaff: applied')
end

local function test_set_chaff_negative_refused()
    local g = _setup_f16('cf2')
    local r = verbs.unit_set_chaff({ name = g.units[1].name, count = -1 })
    assert_false(r.ok, 'set_chaff negative: refused')
end

local function test_set_flare_happy()
    local g = _setup_f16('fl1')
    local r = verbs.unit_set_flare({ name = g.units[1].name, count = 60 })
    assert_true(r.ok, 'set_flare: ok')
    assert_eq(g.units[1].payload.flare, 60, 'set_flare: applied')
end

local function test_set_fuel_happy()
    local g = _setup_f16('fu1')
    local r = verbs.unit_set_fuel({ name = g.units[1].name, fuel = 5000 })
    assert_true(r.ok, 'set_fuel: ok')
    assert_eq(g.units[1].payload.fuel, 5000, 'set_fuel: applied')
end

local function test_set_fuel_negative_refused()
    local g = _setup_f16('fu2')
    local r = verbs.unit_set_fuel({ name = g.units[1].name, fuel = -1 })
    assert_false(r.ok, 'set_fuel negative: refused')
end

local function test_set_gun_happy()
    local g = _setup_f16('gn1')
    local r = verbs.unit_set_gun({ name = g.units[1].name, percent = 50 })
    assert_true(r.ok, 'set_gun: ok')
    assert_eq(g.units[1].payload.gun, 50, 'set_gun: applied')
end

local function test_set_gun_out_of_range()
    local g = _setup_f16('gn2')
    local r1 = verbs.unit_set_gun({ name = g.units[1].name, percent = -1 })
    assert_false(r1.ok, 'set_gun -1: refused')
    local r2 = verbs.unit_set_gun({ name = g.units[1].name, percent = 101 })
    assert_false(r2.ok, 'set_gun 101: refused')
end

-- ============================================================
-- unit_list
-- ============================================================

local function test_list_all()
    mock.new_mission()
    mock.add_plane({ name = 'L1' })
    mock.add_vehicle({ name = 'L2' })
    local r = verbs.unit_list({})
    assert_true(r.ok, 'list: ok')
    assert_eq(r.count, 2, 'list: count = 2')
end

local function test_list_filter_group()
    mock.new_mission()
    mock.add_plane({ name = 'L3' })
    mock.add_plane({ name = 'L4' })
    local r = verbs.unit_list({ group = 'L3' })
    assert_eq(r.count, 1, 'list group=L3: count = 1')
end

local function test_list_filter_type_string()
    mock.new_mission()
    mock.add_plane({ name = 'L5', unit_type = 'F-16C_50' })
    mock.add_plane({ name = 'L6', unit_type = 'F-14B' })
    local r = verbs.unit_list({ type = 'F-16C_50' })
    assert_eq(r.count, 1, 'list type=F-16: count = 1')
end

local function test_list_filter_type_list()
    mock.new_mission()
    mock.add_plane({ name = 'L7', unit_type = 'F-16C_50' })
    mock.add_plane({ name = 'L8', unit_type = 'F-14B' })
    mock.add_plane({ name = 'L9', unit_type = 'Su-27' })
    local r = verbs.unit_list({ type = { 'F-16C_50', 'F-14B' } })
    assert_eq(r.count, 2, 'list type=[F-16,F-14]: count = 2')
end

local function test_list_filter_name_substring()
    mock.new_mission()
    mock.add_plane({ name = 'Hornet-1' })
    mock.add_plane({ name = 'Tomcat-1' })
    local r = verbs.unit_list({ name = 'hornet' })
    assert_eq(r.count, 1, 'list name=hornet (case insensitive): count = 1')
end

local function test_list_summary_fields()
    mock.new_mission()
    local g = mock.add_plane({ name = 'L10' })
    g.units[1].alt = 8000
    g.units[1].heading = 1.5
    g.units[1].skill = 'Excellent'
    local r = verbs.unit_list({ group = 'L10' })
    local s = r.units[1]
    assert_eq(s.group_name, 'L10', 'summary: group_name')
    assert_eq(s.group_id, g.groupId, 'summary: group_id')
    assert_eq(s.category, 'plane', 'summary: category')
    assert_eq(s.alt, 8000, 'summary: alt')
    assert_eq(s.heading, 1.5, 'summary: heading')
    assert_eq(s.skill, 'Excellent', 'summary: skill')
end

-- ============================================================
-- unit_get
-- ============================================================

local function test_get_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'G1' })
    local r = verbs.unit_get({ name = g.units[1].name })
    assert_true(r.ok, 'get: ok')
    assert_eq(r.unit._group_name, 'G1', 'get: _group_name')
    assert_eq(r.unit._side, 'blue', 'get: _side')
    assert_eq(r.unit._category, 'plane', 'get: _category')
end

local function test_get_strips_boss()
    mock.new_mission()
    local g = mock.add_plane({ name = 'G2' })
    local r = verbs.unit_get({ name = g.units[1].name })
    assert_eq(r.unit.boss, nil, 'get: boss stripped')
end

local function test_get_strips_userobject_cycle()
    -- Beacon-style units own a zone whose .userObject points back at the
    -- unit (and zone.userObject.zones[1] == zone again). Before GH#66 the
    -- depth-32 fallback returned the live cyclic table into the clone and
    -- jval hung. Now strip_back_refs tracks ancestors and breaks the cycle.
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'BeaconG' })
    local u = g.units[1]
    u.zones = { { id = 7, radius = 1200, userObject = u } }
    local r = verbs.unit_get({ name = u.name })
    assert_true(r.ok, 'get with userObject cycle: ok')
    assert_eq(r.unit.zones[1].userObject, nil, 'get: userObject stripped')
    assert_eq(r.unit.zones[1].radius, 1200, 'get: surrounding zone fields kept')
end

local function test_get_by_id()
    mock.new_mission()
    local g = mock.add_plane({ name = 'G3' })
    local r = verbs.unit_get({ id = g.units[1].unitId })
    assert_true(r.ok, 'get by id: ok')
end

local function test_get_not_found()
    mock.new_mission()
    local r = verbs.unit_get({ name = 'ghost' })
    assert_false(r.ok, 'get not found: error')
end

local function test_get_arg_validation()
    mock.new_mission()
    assert_false(verbs.unit_get({}).ok, 'get: empty')
    assert_false(verbs.unit_get({ name = 'x', id = 1 }).ok, 'get: both')
end

-- ============================================================
-- unit_set_parking (lives in route_verbs.lua)
-- ============================================================

local function _setup_plane_with_takeoff_wp(name)
    mock.new_mission()
    local g = mock.add_plane({ name = name, unit_type = 'F-16C_50' })
    g.units[1].type = 'F-16C_50'
    -- WP 0 as a takeoff-from-parking type so the verb wires airdromeId.
    g.route.points[1].type = 'TakeOffParking'
    g.route.points[1].action = 'From Parking Area'
    return g
end

local function test_parking_happy()
    local g = _setup_plane_with_takeoff_wp('pk1')
    local u = g.units[1]
    local r = verbs.unit_set_parking({
        name = u.name, airbase = 'Anapa-Vityazevo', stand = '08' })
    assert_true(r.ok, 'parking: ok')
    assert_eq(r.airbase, 'Anapa-Vityazevo', 'parking: returns airbase')
    assert_eq(r.stand, '08', 'parking: returns stand')
    assert_eq(r.crossroad_index, 101, 'parking: returns crossroad_index')
    assert_eq(u.parking, 101, 'parking: u.parking set')
    assert_eq(u.parking_id, '08', 'parking: u.parking_id set')
    assert_eq(u.x, 5000, 'parking: u.x updated to stand')
    assert_eq(u.y, 6000, 'parking: u.y updated to stand')
    -- WP 0 should track the stand position too (lead + takeoff WP)
    assert_eq(g.route.points[1].x, 5000, 'parking: WP 0 x synced')
    assert_eq(g.route.points[1].airdromeId, 12, 'parking: WP 0 airdromeId set')
end

local function test_parking_no_wp_sync_when_not_takeoff()
    mock.new_mission()
    local g = mock.add_plane({ name = 'pk1b', unit_type = 'F-16C_50' })
    g.units[1].type = 'F-16C_50'
    g.route.points[1].type = 'Turning Point'  -- not a takeoff type
    local original_x = g.route.points[1].x
    verbs.unit_set_parking({ name = g.units[1].name, airbase = 'Anapa-Vityazevo', stand = '08' })
    assert_eq(g.route.points[1].x, original_x, 'parking non-TO: WP 0 untouched')
end

local function test_parking_substring_match()
    local g = _setup_plane_with_takeoff_wp('pk2')
    local r = verbs.unit_set_parking({
        name = g.units[1].name, airbase = 'Anapa', stand = '08' })
    assert_true(r.ok, 'parking substring match: ok')
    assert_eq(r.airbase, 'Anapa-Vityazevo', 'parking substring: full name returned')
end

local function test_parking_unknown_airbase()
    local g = _setup_plane_with_takeoff_wp('pk3')
    local r = verbs.unit_set_parking({
        name = g.units[1].name, airbase = 'Nowhere', stand = '08' })
    assert_false(r.ok, 'parking unknown airbase: refused')
    assert_contains(r.error, 'no airbase', 'parking: error msg')
end

local function test_parking_unknown_stand()
    local g = _setup_plane_with_takeoff_wp('pk4')
    local r = verbs.unit_set_parking({
        name = g.units[1].name, airbase = 'Anapa', stand = '99' })
    assert_false(r.ok, 'parking unknown stand: refused')
    assert_contains(r.error, 'no stand', 'parking: error msg')
end

local function test_parking_wrong_category_plane_on_helo_stand()
    local g = _setup_plane_with_takeoff_wp('pk5')
    local r = verbs.unit_set_parking({
        name = g.units[1].name, airbase = 'Anapa', stand = 'H1' })
    assert_false(r.ok, 'parking plane on helo stand: refused')
    assert_contains(r.error, 'not plane-capable', 'parking: error msg')
end

local function test_parking_wrong_category_helo_on_plane_stand()
    mock.new_mission()
    local g = mock.add_helicopter({ name = 'pk6', unit_type = 'UH-1H' })
    g.units[1].type = 'UH-1H'
    g.route.points[1].type = 'TakeOffParking'
    local r = verbs.unit_set_parking({
        name = g.units[1].name, airbase = 'Anapa', stand = '08' })
    assert_false(r.ok, 'parking helo on plane stand: refused')
    assert_contains(r.error, 'not helicopter-capable', 'parking: error msg')
end

local function test_parking_too_small()
    local g = _setup_plane_with_takeoff_wp('pk7')
    local r = verbs.unit_set_parking({
        name = g.units[1].name, airbase = 'Anapa', stand = 'tiny' })
    assert_false(r.ok, 'parking too-small stand: refused')
    assert_contains(r.error, 'too small', 'parking too-small: error msg')
end

local function test_parking_arg_validation()
    mock.new_mission()
    assert_false(verbs.unit_set_parking(nil).ok, 'parking: nil')
    assert_false(verbs.unit_set_parking({}).ok, 'parking: empty')
    assert_false(verbs.unit_set_parking({ name = 'x' }).ok, 'parking: missing airbase')
    assert_false(verbs.unit_set_parking({ name = 'x', airbase = 'A' }).ok,
                 'parking: missing stand')
    assert_false(verbs.unit_set_parking({ name = 'x', airbase = '', stand = '8' }).ok,
                 'parking: empty airbase')
end

-- ============================================================
-- waypoint_link_airbase (lives in route_verbs.lua, tested here
-- because the airbase + parking stubs are already wired up)
-- ============================================================

local function _setup_plane_with_route(name, wp_type)
    mock.new_mission()
    local g = mock.add_plane({ name = name, unit_type = 'F-16C_50' })
    g.units[1].type = 'F-16C_50'
    g.route.points[1].type = wp_type or 'Turning Point'
    return g
end

local function test_link_airbase_happy_turning_point()
    local g = _setup_plane_with_route('LA1', 'Turning Point')
    local r = verbs.waypoint_link_airbase({
        name = g.name, index = 0, airbase = 'Anapa' })
    assert_true(r.ok, 'link_airbase TP: ok')
    assert_eq(r.airbase, 'Anapa-Vityazevo', 'link_airbase: full airbase name')
    assert_eq(r.airdromeId, 12, 'link_airbase: airdromeId set')
    assert_eq(g.route.points[1].airdromeId, 12, 'link_airbase: stored on WP')
    assert_eq(g.route.points[1].x, 12345, 'link_airbase: WP x = airdrome.x')
    assert_eq(g.route.points[1].y, 67890, 'link_airbase: WP y = airdrome.y')
    -- Turning Point: no parking-positioning call
    assert_eq(r.units_positioned, false, 'link_airbase TP: units NOT positioned')
end

local function test_link_airbase_takeoff_parking()
    me_parking_stub.setAirGroupOnAirport_calls = 0
    local g = _setup_plane_with_route('LA2', 'TakeOffParking')
    local r = verbs.waypoint_link_airbase({
        name = g.name, index = 0, airbase = 'Anapa' })
    assert_true(r.ok, 'link_airbase TakeOffParking: ok')
    assert_eq(r.units_positioned, true, 'link_airbase TakeOffParking: positioned')
    assert_eq(me_parking_stub.setAirGroupOnAirport_calls, 1,
              'link_airbase: setAirGroupOnAirport called')
end

local function test_link_airbase_takeoff_runway()
    me_parking_stub.setAirGroupOnAirportRunway_calls = 0
    local g = _setup_plane_with_route('LA3', 'TakeOff')
    local r = verbs.waypoint_link_airbase({
        name = g.name, index = 0, airbase = 'Anapa' })
    assert_true(r.ok, 'link_airbase TakeOff: ok')
    assert_eq(me_parking_stub.setAirGroupOnAirportRunway_calls, 1,
              'link_airbase TakeOff: runway-positioning called')
end

local function test_link_airbase_clears_conflicting_linkage()
    local g = _setup_plane_with_route('LA4', 'TakeOff')
    g.route.points[1].helipadId = 99
    g.route.points[1].grassAirfieldId = 88
    local r = verbs.waypoint_link_airbase({
        name = g.name, index = 0, airbase = 'Anapa' })
    assert_true(r.ok, 'link_airbase clears: ok')
    assert_eq(g.route.points[1].helipadId, nil,
              'link_airbase: helipadId cleared')
    assert_eq(g.route.points[1].grassAirfieldId, nil,
              'link_airbase: grassAirfieldId cleared')
end

local function test_link_airbase_unknown_airbase()
    local g = _setup_plane_with_route('LA5')
    local r = verbs.waypoint_link_airbase({
        name = g.name, index = 0, airbase = 'Nowhere' })
    assert_false(r.ok, 'link_airbase unknown airbase: refused')
    assert_contains(r.error, 'no airbase', 'link_airbase: error msg')
end

local function test_link_airbase_unknown_group()
    mock.new_mission()
    local r = verbs.waypoint_link_airbase({
        name = 'ghost', index = 0, airbase = 'Anapa' })
    assert_false(r.ok, 'link_airbase unknown group: refused')
end

local function test_link_airbase_oob_index()
    local g = _setup_plane_with_route('LA6')
    local r = verbs.waypoint_link_airbase({
        name = g.name, index = 99, airbase = 'Anapa' })
    assert_false(r.ok, 'link_airbase oob index: refused')
end

local function test_link_airbase_arg_validation()
    mock.new_mission()
    assert_false(verbs.waypoint_link_airbase(nil).ok, 'link_airbase: nil')
    assert_false(verbs.waypoint_link_airbase({}).ok, 'link_airbase: empty')
    assert_false(verbs.waypoint_link_airbase({ name = 'x', id = 1, index = 0, airbase = 'A' }).ok,
                 'link_airbase: both selectors')
    assert_false(verbs.waypoint_link_airbase({ name = 'x', airbase = 'A' }).ok,
                 'link_airbase: missing index')
    assert_false(verbs.waypoint_link_airbase({ name = 'x', index = 0 }).ok,
                 'link_airbase: missing airbase')
    assert_false(verbs.waypoint_link_airbase({ name = 'x', index = 0, airbase = '' }).ok,
                 'link_airbase: empty airbase')
end

-- ============================================================
-- Test runner
-- ============================================================

local tests = {
    test_set_name_happy,
    test_set_name_by_id,
    test_set_name_collision,
    test_set_name_not_found,
    test_set_name_arg_validation,
    test_set_skill_happy,
    test_set_skill_arg_validation,
    test_set_livery_happy,
    test_set_livery_empty_string_allowed,
    test_set_livery_arg_validation,
    test_set_pos_happy,
    test_set_pos_arg_validation,
    test_set_heading_happy,
    test_set_heading_arg_validation,
    test_set_alt_happy,
    test_set_alt_default_alt_type,
    test_set_alt_bad_alt_type,
    test_set_alt_arg_validation,
    test_set_onboard_num_happy,
    test_set_onboard_num_arg_validation,
    test_set_callsign_happy,
    test_set_callsign_overrides_numeric,
    test_set_callsign_arg_validation,
    test_payload_set_by_clsid,
    test_payload_set_by_display_name,
    test_payload_set_display_name_case_insensitive,
    test_payload_set_obsolete_refused,
    test_payload_set_wrong_pylon_for_weapon,
    test_payload_set_unknown_pylon_number,
    test_payload_set_air_only,
    test_payload_set_arg_validation,
    test_payload_clear_happy,
    test_payload_clear_empty_pylon,
    test_payload_clear_unknown_pylon,
    test_set_loadout_happy,
    test_set_loadout_empty,
    test_set_loadout_unknown,
    test_set_loadout_air_only,
    test_set_loadout_arg_validation,
    test_set_chaff_happy,
    test_set_chaff_negative_refused,
    test_set_flare_happy,
    test_set_fuel_happy,
    test_set_fuel_negative_refused,
    test_set_gun_happy,
    test_set_gun_out_of_range,
    test_list_all,
    test_list_filter_group,
    test_list_filter_type_string,
    test_list_filter_type_list,
    test_list_filter_name_substring,
    test_list_summary_fields,
    test_get_happy,
    test_get_strips_boss,
    test_get_strips_userobject_cycle,
    test_get_by_id,
    test_get_not_found,
    test_get_arg_validation,
    test_parking_happy,
    test_parking_no_wp_sync_when_not_takeoff,
    test_parking_substring_match,
    test_parking_unknown_airbase,
    test_parking_unknown_stand,
    test_parking_wrong_category_plane_on_helo_stand,
    test_parking_wrong_category_helo_on_plane_stand,
    test_parking_too_small,
    test_parking_arg_validation,
    test_link_airbase_happy_turning_point,
    test_link_airbase_takeoff_parking,
    test_link_airbase_takeoff_runway,
    test_link_airbase_clears_conflicting_linkage,
    test_link_airbase_unknown_airbase,
    test_link_airbase_unknown_group,
    test_link_airbase_oob_index,
    test_link_airbase_arg_validation,
}

for _, t in ipairs(tests) do t() end

print(string.format('test_verbs_unit: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
