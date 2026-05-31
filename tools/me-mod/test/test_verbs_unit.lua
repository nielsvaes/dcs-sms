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

-- me_loadoututils stub. Returns canned pylon assignments per (type, loadout)
-- plus a descriptor-driven settings schema for the fuze verbs (gh #68 item 1).
-- The '{Mk82AIR}' descriptor mimics the real WWII-bomb shape: two fuze-well
-- comboLists (nose/tail), each gating a "Function Delay" comboList (so the
-- label "Function Delay" collides — exercising the ambiguity path) and a
-- read-only "Arming Vane Revs. Required" spinbox.
local fuze_descr = {
    ['{Mk82AIR}'] = {
        { id = 'NFP_fuze_type_nose', label = 'Nose Fuze Well', control = 'comboList', defValue = 1,
          values = { { id = 1, dispName = 'Nose Pistol' }, { id = 'EMPTY_NOSE', dispName = 'Plugged' } } },
        { id = '00_prfx_function_delay_ctrl_X', label = 'Function Delay', control = 'comboList', defValue = 0,
          VisibilityCondition = { { id = 'NFP_fuze_type_nose', value = 1 } },
          values = { { id = 0, dispName = '0' }, { id = 11, dispName = '11' } } },
        { id = '00_prfx_vane_rev_threshold_ctrl_X', label = 'Arming Vane Revs. Required',
          control = 'spinbox', defValue = 7, min = 0, max = 100, readOnly = true },
        { id = 'NFP_fuze_type_tail', label = 'Tail Fuze Well', control = 'comboList', defValue = 1,
          values = { { id = 1, dispName = 'Tail Pistol' }, { id = 'EMPTY_TAIL', dispName = 'Plugged' } } },
        { id = '01_prfx_function_delay_ctrl_Y', label = 'Function Delay', control = 'comboList', defValue = 0,
          VisibilityCondition = { { id = 'NFP_fuze_type_tail', value = 1 } },
          values = { { id = 0, dispName = '0' }, { id = 11, dispName = '11' } } },
    },
}
local fuze_defs = {
    ['{Mk82AIR}'] = {
        NFP_fuze_type_nose = 1, NFP_fuze_type_tail = 1,
        ['00_prfx_function_delay_ctrl_X'] = 0, ['01_prfx_function_delay_ctrl_Y'] = 0,
        ['00_prfx_vane_rev_threshold_ctrl_X'] = 7,
        NFP_PRESID = 'TEST_PRESET', NFP_PRESVER = 2,
    },
}
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
        getLauncherSettings = function(clsid) return fuze_descr[clsid] end,
        getLauncherSettingsDefaultValues = function(clsid) return fuze_defs[clsid] end,
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

local function test_get_visited_set_breaks_arbitrary_cycle()
    -- Defense-in-depth: strip_back_refs must also break cycles via keys NOT
    -- on the drop list (boss / mapObjects / userObject), in case a future
    -- DCS build introduces another back-pointer. We construct a self-cycle
    -- on `zones[1].self_ref` and assert the helper terminates and elides
    -- the cyclic key without losing surrounding fields. The visited-set is
    -- what catches this; the drop list won't.
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'CycleG' })
    local u = g.units[1]
    local zone = { id = 9, radius = 800 }
    zone.self_ref = zone
    u.zones = { zone }
    local r = verbs.unit_get({ name = u.name })
    assert_true(r.ok, 'get with non-dropped cycle: ok')
    assert_eq(r.unit.zones[1].self_ref, nil, 'get: visited-set elided self_ref cycle')
    assert_eq(r.unit.zones[1].radius, 800, 'get: surrounding zone fields kept')
end

local function test_get_by_id()
    mock.new_mission()
    local g = mock.add_plane({ name = 'G3' })
    local r = verbs.unit_get({ id = g.units[1].unitId })
    assert_true(r.ok, 'get by id: ok')
end

local function test_get_by_group_name()
    -- group_name selector returns the first unit of the named group.
    mock.new_mission()
    local g = mock.add_plane({ name = 'GByName' })
    local r = verbs.unit_get({ group_name = 'GByName' })
    assert_true(r.ok, 'get by group_name: ok')
    assert_eq(r.unit.name, g.units[1].name, 'get by group_name: first unit returned')
    assert_eq(r.unit._group_name, 'GByName', 'get by group_name: _group_name set')
end

local function test_get_by_group_id()
    mock.new_mission()
    local g = mock.add_plane({ name = 'GByID' })
    local r = verbs.unit_get({ group_id = g.groupId })
    assert_true(r.ok, 'get by group_id: ok')
    assert_eq(r.unit.unitId, g.units[1].unitId, 'get by group_id: first unit returned')
    assert_eq(r.unit._group_id, g.groupId, 'get by group_id: _group_id matches')
end

local function test_get_by_group_returns_first_unit()
    -- For multi-unit groups, group_name/group_id pin to units[1] (the
    -- mission-table order), not an arbitrary one.
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'GMulti' })
    -- mock.add_vehicle creates a 1-unit group; bolt on extras directly.
    table.insert(g.units, { unitId = 9001, name = 'GMulti-2', type = g.units[1].type,
                            x = 0, y = 0, heading = 0, skill = 'Average', index = 2 })
    table.insert(g.units, { unitId = 9002, name = 'GMulti-3', type = g.units[1].type,
                            x = 0, y = 0, heading = 0, skill = 'Average', index = 3 })
    local r = verbs.unit_get({ group_name = 'GMulti' })
    assert_true(r.ok, 'get multi by group_name: ok')
    assert_eq(r.unit.name, g.units[1].name, 'get multi by group_name: first unit')
end

local function test_get_group_not_found()
    mock.new_mission()
    local r = verbs.unit_get({ group_name = 'nope' })
    assert_false(r.ok, 'get group not found: error')
    assert_contains(r.error, 'group not found', 'get: error message')
end

local function test_get_not_found()
    mock.new_mission()
    local r = verbs.unit_get({ name = 'ghost' })
    assert_false(r.ok, 'get not found: error')
end

local function test_get_arg_validation()
    mock.new_mission()
    assert_false(verbs.unit_get({}).ok, 'get: empty')
    assert_false(verbs.unit_get({ name = 'x', id = 1 }).ok, 'get: name + id')
    assert_false(verbs.unit_get({ name = 'x', group_name = 'y' }).ok, 'get: name + group_name')
    assert_false(verbs.unit_get({ id = 1, group_id = 2 }).ok, 'get: id + group_id')
    assert_false(verbs.unit_get({ group_name = 'x', group_id = 1 }).ok, 'get: group_name + group_id')
    assert_false(verbs.unit_get({ group_name = '' }).ok, 'get: empty group_name')
end

-- ============================================================
-- lat/lon enrichment (GH#66 request 4)
-- ============================================================

-- Stub Terrain only for the duration of one test so other tests stay on the
-- "no Terrain → no lat/lon" path. The verb is supposed to add lat/lon when
-- Terrain is present and omit them when it isn't.
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
    g.units[1].x, g.units[1].y = 111000, 85000
    with_terrain_stub(function()
        local r = verbs.unit_list({ group = 'LL1' })
        assert_true(r.ok, 'list w/ Terrain: ok')
        assert_eq(r.units[1].lat, 1, 'list: lat from Terrain stub')
        assert_eq(r.units[1].lon, 1, 'list: lon from Terrain stub')
    end)
end

local function test_list_omits_lat_lon_when_no_terrain()
    -- Without _G.Terrain, the helper returns nil/nil and the row still
    -- has the key but with a nil value (which JSON-encodes as missing).
    mock.new_mission()
    mock.add_plane({ name = 'LL2' })
    local r = verbs.unit_list({ group = 'LL2' })
    assert_true(r.ok, 'list no Terrain: ok')
    assert_eq(r.units[1].lat, nil, 'list: lat absent without Terrain')
    assert_eq(r.units[1].lon, nil, 'list: lon absent without Terrain')
end

local function test_get_includes_lat_lon_when_terrain_available()
    mock.new_mission()
    local g = mock.add_plane({ name = 'LL3' })
    g.units[1].x, g.units[1].y = 222000, 170000
    with_terrain_stub(function()
        local r = verbs.unit_get({ name = g.units[1].name })
        assert_true(r.ok, 'get w/ Terrain: ok')
        assert_eq(r.unit.lat, 2, 'get: lat from Terrain stub')
        assert_eq(r.unit.lon, 2, 'get: lon from Terrain stub')
    end)
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

-- gh #68 item 5: link-airbase preserves an explicit parking stand when the
-- waypoint is already linked to THIS airbase and the lead unit has a stand.
local function test_link_airbase_preserves_explicit_parking()
    me_parking_stub.setAirGroupOnAirport_calls = 0
    local g = _setup_plane_with_route('LA7', 'TakeOffParking')
    g.units[1].parking_id = '08'
    g.units[1].parking = 101
    g.units[1].x = 5000
    g.units[1].y = 6000
    g.route.points[1].airdromeId = 12  -- already linked to Anapa (airdrome 12)
    g.route.points[1].x = 5000
    g.route.points[1].y = 6000
    local r = verbs.waypoint_link_airbase({ name = g.name, index = 0, airbase = 'Anapa' })
    assert_true(r.ok, 'link_airbase preserve: ok')
    assert_true(r.parking_preserved, 'link_airbase preserve: flagged')
    assert_eq(r.units_positioned, false, 'link_airbase preserve: no re-positioning')
    assert_eq(me_parking_stub.setAirGroupOnAirport_calls, 0,
              'link_airbase preserve: setAirGroupOnAirport NOT called')
    assert_eq(g.units[1].parking_id, '08', 'link_airbase preserve: stand kept')
    assert_eq(g.units[1].x, 5000, 'link_airbase preserve: unit not moved')
    assert_eq(g.route.points[1].airdromeId, 12, 'link_airbase preserve: airdromeId asserted')
end

-- Linking to a DIFFERENT airbase (airdromeId mismatch) still reshuffles.
local function test_link_airbase_reassigns_when_airbase_differs()
    me_parking_stub.setAirGroupOnAirport_calls = 0
    local g = _setup_plane_with_route('LA8', 'TakeOffParking')
    g.units[1].parking_id = '08'
    g.route.points[1].airdromeId = 999  -- linked elsewhere; Anapa is 12
    local r = verbs.waypoint_link_airbase({ name = g.name, index = 0, airbase = 'Anapa' })
    assert_true(r.ok, 'link_airbase reassign: ok')
    assert_false(r.parking_preserved, 'link_airbase reassign: not preserved')
    assert_eq(me_parking_stub.setAirGroupOnAirport_calls, 1,
              'link_airbase reassign: setAirGroupOnAirport called')
end

-- ============================================================
-- unit_payload_set_fuze / list-settings (gh #68 item 1)
-- ============================================================

-- Arm pylon 3 of an F-16C with the descriptor-bearing test bomb.
local function _setup_plane_with_fuze_weapon(name)
    mock.new_mission()
    local g = mock.add_plane({ name = name, unit_type = 'F-16C_50' })
    g.units[1].type = 'F-16C_50'
    local sr = verbs.unit_payload_set({ name = g.units[1].name, pylon = 3, weapon = '{Mk82AIR}' })
    assert_true(sr.ok, name .. ': arm pylon ok')
    return g
end

local function test_list_settings_happy()
    local g = _setup_plane_with_fuze_weapon('fz_ls1')
    local r = verbs.unit_payload_list_settings({ name = g.units[1].name, pylon = 3 })
    assert_true(r.ok, 'list-settings: ok')
    assert_eq(r.clsid, '{Mk82AIR}', 'list-settings: clsid resolved from pylon')
    assert_eq(r.count, 5, 'list-settings: 5 descriptor entries')
    assert_eq(r.preset.id, 'TEST_PRESET', 'list-settings: preset id')
    assert_eq(r.preset.version, 2, 'list-settings: preset version')
    -- first entry is the nose fuze well combo with two values
    assert_eq(r.settings[1].id, 'NFP_fuze_type_nose', 'list-settings: first id')
    assert_eq(#r.settings[1].values, 2, 'list-settings: combo values present')
    assert_true(r.settings[3].read_only, 'list-settings: vane revs flagged read_only')
end

local function test_list_settings_by_weapon_flag()
    mock.new_mission()
    local g = mock.add_plane({ name = 'fz_ls2', unit_type = 'F-16C_50' })
    g.units[1].type = 'F-16C_50'
    local r = verbs.unit_payload_list_settings({ name = g.units[1].name, weapon = '{Mk82AIR}' })
    assert_true(r.ok, 'list-settings by weapon: ok')
    assert_eq(r.count, 5, 'list-settings by weapon: descriptor returned')
end

local function test_set_fuze_by_id()
    local g = _setup_plane_with_fuze_weapon('fz1')
    local r = verbs.unit_payload_set_fuze({ name = g.units[1].name, pylon = 3, sets = {
        { key = 'NFP_fuze_type_nose', value = '1' },
        { key = '01_prfx_function_delay_ctrl_Y', value = '11' },
    } })
    assert_true(r.ok, 'set-fuze by id: ok')
    local s = g.units[1].payload.pylons[3].settings
    assert_eq(s.NFP_fuze_type_nose, 1, 'set-fuze: nose fuze (number)')
    assert_eq(s['01_prfx_function_delay_ctrl_Y'], 11, 'set-fuze: tail function delay')
    -- preset metadata + sibling defaults are filled in from defaults
    assert_eq(s.NFP_PRESID, 'TEST_PRESET', 'set-fuze: preset id auto-filled')
    assert_eq(s.NFP_PRESVER, 2, 'set-fuze: preset ver auto-filled')
    assert_eq(s.NFP_fuze_type_tail, 1, 'set-fuze: untouched sibling kept at default')
    assert_eq(r.preset.id, 'TEST_PRESET', 'set-fuze: returns preset')
end

local function test_set_fuze_by_label_and_dispname()
    local g = _setup_plane_with_fuze_weapon('fz2')
    -- "Nose Fuze Well" is an unambiguous label; "Plugged" is its dispName.
    local r = verbs.unit_payload_set_fuze({ name = g.units[1].name, pylon = 3, sets = {
        { key = 'Nose Fuze Well', value = 'Plugged' },
    } })
    assert_true(r.ok, 'set-fuze by label: ok')
    assert_eq(g.units[1].payload.pylons[3].settings.NFP_fuze_type_nose, 'EMPTY_NOSE',
              'set-fuze: dispName resolved to combo id (string)')
end

local function test_set_fuze_ambiguous_label_refused()
    local g = _setup_plane_with_fuze_weapon('fz3')
    local r = verbs.unit_payload_set_fuze({ name = g.units[1].name, pylon = 3, sets = {
        { key = 'Function Delay', value = '11' },  -- collides: nose + tail
    } })
    assert_false(r.ok, 'set-fuze ambiguous label: refused')
    assert_contains(r.error, 'ambiguous', 'set-fuze: ambiguity error')
end

local function test_set_fuze_readonly_refused()
    local g = _setup_plane_with_fuze_weapon('fz4')
    local r = verbs.unit_payload_set_fuze({ name = g.units[1].name, pylon = 3, sets = {
        { key = '00_prfx_vane_rev_threshold_ctrl_X', value = '9' },
    } })
    assert_false(r.ok, 'set-fuze read-only: refused')
    assert_contains(r.error, 'read-only', 'set-fuze: read-only error')
end

local function test_set_fuze_unknown_key_refused()
    local g = _setup_plane_with_fuze_weapon('fz5')
    local r = verbs.unit_payload_set_fuze({ name = g.units[1].name, pylon = 3, sets = {
        { key = 'no_such_setting', value = '1' },
    } })
    assert_false(r.ok, 'set-fuze unknown key: refused')
    assert_contains(r.error, 'unknown setting', 'set-fuze: unknown-key error')
end

local function test_set_fuze_bad_combo_value_refused()
    local g = _setup_plane_with_fuze_weapon('fz6')
    local r = verbs.unit_payload_set_fuze({ name = g.units[1].name, pylon = 3, sets = {
        { key = 'NFP_fuze_type_nose', value = '99' },  -- not a legal combo id
    } })
    assert_false(r.ok, 'set-fuze bad combo: refused')
    assert_contains(r.error, 'not a legal value', 'set-fuze: bad-value error')
end

local function test_set_fuze_no_weapon_refused()
    mock.new_mission()
    local g = mock.add_plane({ name = 'fz7', unit_type = 'F-16C_50' })
    g.units[1].type = 'F-16C_50'
    local r = verbs.unit_payload_set_fuze({ name = g.units[1].name, pylon = 2, sets = {
        { key = 'NFP_fuze_type_nose', value = '1' },
    } })
    assert_false(r.ok, 'set-fuze no weapon: refused')
    assert_contains(r.error, 'no weapon', 'set-fuze: no-weapon error')
end

local function test_set_fuze_with_weapon_flag()
    mock.new_mission()
    local g = mock.add_plane({ name = 'fz8', unit_type = 'F-16C_50' })
    g.units[1].type = 'F-16C_50'
    -- pylon 3 empty; --weapon arms it and applies the fuze in one call.
    local r = verbs.unit_payload_set_fuze({ name = g.units[1].name, pylon = 3,
        weapon = '{Mk82AIR}', sets = { { key = 'NFP_fuze_type_nose', value = '1' } } })
    assert_true(r.ok, 'set-fuze --weapon: ok')
    assert_eq(g.units[1].payload.pylons[3].CLSID, '{Mk82AIR}', 'set-fuze --weapon: armed')
    assert_eq(g.units[1].payload.pylons[3].settings.NFP_fuze_type_nose, 1, 'set-fuze --weapon: applied')
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
    test_get_visited_set_breaks_arbitrary_cycle,
    test_get_by_id,
    test_get_by_group_name,
    test_get_by_group_id,
    test_get_by_group_returns_first_unit,
    test_get_group_not_found,
    test_get_not_found,
    test_get_arg_validation,
    test_list_includes_lat_lon_when_terrain_available,
    test_list_omits_lat_lon_when_no_terrain,
    test_get_includes_lat_lon_when_terrain_available,
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
    test_link_airbase_preserves_explicit_parking,
    test_link_airbase_reassigns_when_airbase_differs,
    test_list_settings_happy,
    test_list_settings_by_weapon_flag,
    test_set_fuze_by_id,
    test_set_fuze_by_label_and_dispname,
    test_set_fuze_ambiguous_label_refused,
    test_set_fuze_readonly_refused,
    test_set_fuze_unknown_key_refused,
    test_set_fuze_bad_combo_value_refused,
    test_set_fuze_no_weapon_refused,
    test_set_fuze_with_weapon_flag,
}

for _, t in ipairs(tests) do t() end

print(string.format('test_verbs_unit: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
