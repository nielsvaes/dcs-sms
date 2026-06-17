-- test_verbs_route.lua — Lua-side unit tests for verbs.lua route/waypoint
-- verbs. Uses mock_me_mission.lua for a synthetic mission table.
--
-- Run via:
--   cd tools/me-mod/test && lua test_verbs_route.lua
-- Or through the harness:
--   pwsh tools/me-mod/test/run-tests.ps1

-- Adjust package.path so require('mock_me_mission') works regardless of
-- which directory we run from (tools/me-mod/test or anywhere else).
local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path

-- Inject the mock BEFORE requiring verbs.lua so the verbs' calls to
-- require('me_mission') / require('me_map_window') return our mock.
-- The same table services both: me_mission methods (insert_waypoint,
-- remove_waypoint, update_group_map_objects, …) and me_map_window
-- methods (move_waypoint) coexist as fields on the mock module.
local mock = require('mock_me_mission')
package.preload['me_mission']    = function() return mock end
package.preload['me_map_window'] = function() return mock end

-- verbs.lua lives under tools/me-mod/lua/dcs_sms_me/. Adjust path so its
-- 'dcs_sms_me.*' requires resolve. The bridge installer copies these
-- under the ME's package.path; here we have to point at the source tree.
package.path = here .. '../lua/?.lua;' .. here .. '../lua/?/init.lua;' .. package.path

local verbs = require('dcs_sms_me.verbs')

-- ============================================================
-- Test helpers
-- ============================================================

local passed, failed, errors = 0, 0, {}

local function assert_eq(actual, expected, name)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(errors, string.format(
            "%s: expected %s, got %s",
            name, tostring(expected), tostring(actual)))
    end
end

local function assert_true(cond, name)
    assert_eq(cond and true or false, true, name)
end

local function assert_false(cond, name)
    assert_eq(cond and true or false, false, name)
end

local function assert_contains(haystack, needle, name)
    if type(haystack) == 'string' and haystack:find(needle, 1, true) then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(errors, string.format(
            "%s: expected string containing %q, got %s",
            name, needle, tostring(haystack)))
    end
end

local function deep_eq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
    for k, v in pairs(b) do if not deep_eq(v, a[k]) then return false end end
    return true
end

local function assert_deep_eq(actual, expected, name)
    if deep_eq(actual, expected) then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(errors, string.format(
            "%s: deep_eq failed", name))
    end
end

-- ============================================================
-- Smoke test — verify mock + verbs module both load cleanly
-- ============================================================

local function test_smoke()
    mock.new_mission()
    local g = mock.add_plane({ name = 'smoke-1' })
    assert_true(g ~= nil, 'smoke: add_plane returns a group')
    assert_eq(g.name, 'smoke-1', 'smoke: group name set')
    assert_true(#g.route.points == 1, 'smoke: group has a default waypoint')
end

-- ============================================================
-- Helper tests — exercised through public verbs but with focused
-- assertions on inheritance / range-checking behaviour.
-- ============================================================

local function test_find_route_happy()
    mock.new_mission()
    local g = mock.add_plane({ name = 'h1' })
    local res = verbs.route_list({ name = 'h1' })
    assert_true(res.ok, 'find_route: by name → ok')
    assert_eq(res.group, 'h1', 'find_route: returns group name')
    assert_eq(#res.points, 1, 'find_route: default route has 1 wp')
end

local function test_find_route_not_found()
    mock.new_mission()
    local res = verbs.route_list({ name = 'nope' })
    assert_false(res.ok, 'find_route: missing group → not ok')
    assert_contains(res.error, 'group not found', 'find_route: error message')
end

local function test_find_route_args_mutex()
    mock.new_mission()
    local r1 = verbs.route_list({ name = 'a', id = 1 })
    assert_false(r1.ok, 'find_route: both name and id rejected')
    local r2 = verbs.route_list({})
    assert_false(r2.ok, 'find_route: neither name nor id rejected')
end

local function test_find_waypoint_range()
    mock.new_mission()
    local g = mock.add_plane({ name = 'wp1' })
    -- add two more WPs to make the route 3 deep
    table.insert(g.route.points, mock.make_waypoint('plane', { x = 1000, y = 2000 }))
    table.insert(g.route.points, mock.make_waypoint('plane', { x = 2000, y = 3000 }))
    local r_ok = verbs.waypoint_get({ name = 'wp1', index = 2 })
    assert_true(r_ok.ok, 'find_waypoint: index 2 of 3 → ok')
    local r_oob = verbs.waypoint_get({ name = 'wp1', index = 3 })
    assert_false(r_oob.ok, 'find_waypoint: index 3 of 3 → out of range')
    assert_contains(r_oob.error, 'out of range', 'find_waypoint: out-of-range message')
    local r_neg = verbs.waypoint_get({ name = 'wp1', index = -1 })
    assert_false(r_neg.ok, 'find_waypoint: negative index rejected')
end

local function test_inherit_waypoint_empty_route_uses_category_defaults()
    mock.new_mission()
    local g = mock.add_plane({ name = 'inh1' })
    g.route.points = {}  -- empty route
    local r = verbs.waypoint_add({ name = 'inh1', north = 100, east = 200 })
    assert_true(r.ok, 'inherit (plane, empty): add → ok')
    local wp = g.route.points[1]
    assert_eq(wp.alt, 8000, 'inherit (plane, empty): alt = 8000')
    assert_eq(wp.alt_type, 'BARO', 'inherit (plane, empty): alt_type = BARO')
    assert_eq(wp.speed, 220, 'inherit (plane, empty): speed = 220')
    assert_eq(wp.type, 'Turning Point', 'inherit (plane, empty): type')
    assert_eq(wp.action, 'Turning Point', 'inherit (plane, empty): action')
end

local function test_inherit_waypoint_from_source()
    mock.new_mission()
    local g = mock.add_helicopter({ name = 'inh2' })
    -- mutate the existing WP so we can verify inheritance differs from defaults
    g.route.points[1].alt = 1234
    g.route.points[1].speed = 77
    g.route.points[1].formation_template = 'Diamond'
    -- add a WP with task non-empty on source so we can verify task is wiped
    g.route.points[1].task.params.tasks = { { id = 'Orbit', params = {} } }
    local r = verbs.waypoint_add({ name = 'inh2', north = 500, east = 600 })
    assert_true(r.ok, 'inherit (helo, from source): add → ok')
    local wp = g.route.points[2]
    assert_eq(wp.alt, 1234, 'inherit: alt from source')
    assert_eq(wp.speed, 77, 'inherit: speed from source')
    assert_eq(wp.formation_template, 'Diamond', 'inherit: formation from source')
    assert_eq(wp.name, '', 'inherit: name NOT inherited (empty)')
    assert_eq(wp.ETA, 0, 'inherit: ETA NOT inherited (0)')
    assert_deep_eq(wp.task,
        { id = 'ComboTask', params = { tasks = {} } },
        'inherit: task is empty ComboTask regardless of source')
end

local function test_inherit_overrides_win()
    mock.new_mission()
    local g = mock.add_plane({ name = 'inh3' })
    local r = verbs.waypoint_add({
        name = 'inh3', north = 100, east = 200,
        alt = 5000, speed = 180, alt_type = 'RADIO',
        type = 'Land', action = 'Landing',
    })
    assert_true(r.ok, 'inherit (overrides win): ok')
    local wp = g.route.points[2]
    assert_eq(wp.alt, 5000, 'override: alt')
    assert_eq(wp.speed, 180, 'override: speed')
    assert_eq(wp.alt_type, 'RADIO', 'override: alt_type')
    assert_eq(wp.type, 'Land', 'override: type')
    assert_eq(wp.action, 'Landing', 'override: action')
end

local function test_route_list_summary_fields()
    mock.new_mission()
    local g = mock.add_plane({ name = 'rl1', x = 100, y = 200 })
    g.route.points[1].name = 'WP0'
    g.route.points[1].task.params.tasks = { { id = 'Orbit', params = {} } }
    table.insert(g.route.points, mock.make_waypoint('plane', { x = 1000, y = 2000, name = 'WP1' }))
    local r = verbs.route_list({ name = 'rl1' })
    assert_true(r.ok, 'route_list: ok')
    assert_eq(#r.points, 2, 'route_list: 2 points')
    assert_eq(r.points[1].index, 0, 'route_list: index 0 first')
    assert_eq(r.points[1].name, 'WP0', 'route_list: name preserved')
    assert_eq(r.points[1].north, 100, 'route_list: north mapping')
    assert_eq(r.points[1].east, 200, 'route_list: east mapping')
    assert_true(r.points[1].has_task, 'route_list: has_task true when tasks present')
    assert_false(r.points[2].has_task, 'route_list: has_task false when empty')
end

local function test_route_get_preserves_task()
    mock.new_mission()
    local g = mock.add_helicopter({ name = 'rg1' })
    g.route.points[1].task.params.tasks = {
        { id = 'Orbit', params = { altitude = 500, pattern = 'Circle' } }
    }
    local r = verbs.route_get({ name = 'rg1' })
    assert_true(r.ok, 'route_get: ok')
    assert_eq(#r.route.points, 1, 'route_get: 1 point')
    assert_eq(r.route.points[1].task.params.tasks[1].id, 'Orbit',
              'route_get: task subtree preserved verbatim')
    assert_eq(r.route.points[1].task.params.tasks[1].params.altitude, 500,
              'route_get: task params preserved')
end

local function test_route_clear_ground()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'rc1' })
    -- 3 points
    table.insert(g.route.points, mock.make_waypoint('vehicle'))
    table.insert(g.route.points, mock.make_waypoint('vehicle'))
    assert_eq(#g.route.points, 3, 'route_clear-setup: 3 pts')
    local r = verbs.route_clear({ name = 'rc1' })
    assert_true(r.ok, 'route_clear (ground): ok')
    assert_eq(r.points_removed, 3, 'route_clear: returns count')
    assert_eq(#g.route.points, 0, 'route_clear: route is empty')
end

local function test_route_clear_air_refused()
    mock.new_mission()
    local g = mock.add_plane({ name = 'rc2' })
    local r = verbs.route_clear({ name = 'rc2' })
    assert_false(r.ok, 'route_clear (air): refused')
    assert_contains(r.error, 'air group', 'route_clear (air): air-group error message')
    assert_eq(#g.route.points, 1, 'route_clear (air): route untouched')
end

local function test_waypoint_get_full_fields()
    mock.new_mission()
    local g = mock.add_plane({ name = 'wg1', x = 50, y = 60 })
    g.route.points[1].name = 'IP'
    g.route.points[1].alt = 6000
    g.route.points[1].speed = 250
    local r = verbs.waypoint_get({ name = 'wg1', index = 0 })
    assert_true(r.ok, 'waypoint_get: ok')
    assert_eq(r.waypoint.name, 'IP', 'waypoint_get: name')
    assert_eq(r.waypoint.alt, 6000, 'waypoint_get: alt')
    assert_eq(r.waypoint.speed, 250, 'waypoint_get: speed')
    assert_eq(r.waypoint.task.id, 'ComboTask', 'waypoint_get: task field present')
end

-- strip_back_refs (used by waypoint_get/route_get) re-clones shared sub-tables
-- per reference path, so a deeply *nested* shared structure expands
-- exponentially and used to blow past the bridge's exec timeout on some
-- red-side AI groups (GH#73, request 6). A node budget caps the expansion.
-- We lower the budget and feed a diamond DAG to prove it terminates with a
-- truncation marker instead of running away.
local function test_strip_back_refs_budget_caps_diamond()
    local H = require('dcs_sms_me.verb_helpers')
    local saved = H.STRIP_NODE_BUDGET
    H.STRIP_NODE_BUDGET = 100
    -- Each level shares one child between two keys → 2^depth expansion if
    -- unbounded; depth 30 would be ~1e9 nodes without the cap.
    local function build(d)
        if d == 0 then return { leaf = true } end
        local c = build(d - 1)
        return { a = c, b = c }
    end
    local out = H.strip_back_refs(build(30))
    H.STRIP_NODE_BUDGET = saved

    local function has_truncation(t, seen)
        seen = seen or {}
        if type(t) ~= 'table' or seen[t] then return false end
        seen[t] = true
        if t.__truncated__ ~= nil then return true end
        for _, v in pairs(t) do
            if has_truncation(v, seen) then return true end
        end
        return false
    end
    assert_true(type(out) == 'table', 'strip budget: returns a table')
    assert_true(has_truncation(out), 'strip budget: marks truncation instead of hanging')
end

local function test_refresh_called_on_clear()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'rf1' })
    mock.reset_refresh_counters()
    verbs.route_clear({ name = 'rf1' })
    assert_eq(mock.refresh_calls.update, 1, 'route_clear: update_group_map_objects called once')
end

-- ============================================================
-- Task 4: waypoint_add / waypoint_insert / waypoint_remove tests
-- ============================================================

local function test_waypoint_add_appends()
    mock.new_mission()
    local g = mock.add_plane({ name = 'wa1' })
    local r = verbs.waypoint_add({ name = 'wa1', north = 1000, east = 2000 })
    assert_true(r.ok, 'waypoint_add: ok')
    assert_eq(r.index, 1, 'waypoint_add: appended at index 1')
    assert_eq(#g.route.points, 2, 'waypoint_add: route now has 2 pts')
    assert_eq(g.route.points[2].x, 1000, 'waypoint_add: north → x')
    assert_eq(g.route.points[2].y, 2000, 'waypoint_add: east → y')
end

local function test_waypoint_add_enum_validation()
    mock.new_mission()
    local g = mock.add_plane({ name = 'wa2' })
    local r1 = verbs.waypoint_add({ name = 'wa2', north = 1, east = 2, type = 'WrongType' })
    assert_false(r1.ok, 'waypoint_add: bad type rejected')
    assert_contains(r1.error, 'unknown waypoint type', 'bad-type error msg')
    local r2 = verbs.waypoint_add({ name = 'wa2', north = 1, east = 2, action = 'WrongAction' })
    assert_false(r2.ok, 'waypoint_add: bad action rejected')
    local r3 = verbs.waypoint_add({ name = 'wa2', north = 1, east = 2, alt_type = 'X' })
    assert_false(r3.ok, 'waypoint_add: bad alt_type rejected')
    local r4 = verbs.waypoint_add({ name = 'wa2', north = 1, east = 2, speed = 0 })
    assert_false(r4.ok, 'waypoint_add: speed=0 rejected')
end

local function test_waypoint_insert_shifts_indices()
    mock.new_mission()
    local g = mock.add_plane({ name = 'wi1' })
    table.insert(g.route.points, mock.make_waypoint('plane', { x = 1000, y = 1000 }))
    table.insert(g.route.points, mock.make_waypoint('plane', { x = 2000, y = 2000 }))
    -- route: [0]=spawn, [1]=1000/1000, [2]=2000/2000
    local r = verbs.waypoint_insert({ name = 'wi1', before = 1, north = 500, east = 500 })
    assert_true(r.ok, 'waypoint_insert: ok')
    assert_eq(r.index, 1, 'waypoint_insert: inserted at index 1')
    assert_eq(#g.route.points, 4, 'waypoint_insert: route grew to 4')
    assert_eq(g.route.points[2].x, 500, 'waypoint_insert: new WP at Lua idx 2')
    assert_eq(g.route.points[3].x, 1000, 'waypoint_insert: old idx 1 shifted to idx 2 (Lua) / wire 2')
end

local function test_waypoint_insert_before_zero()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'wi2' })
    g.route.points[1].x = 999
    local r = verbs.waypoint_insert({ name = 'wi2', before = 0, north = 1, east = 2 })
    assert_true(r.ok, 'waypoint_insert before 0: ok')
    assert_eq(r.index, 0, 'waypoint_insert before 0: index 0')
    assert_eq(g.route.points[1].x, 1, 'waypoint_insert before 0: new WP first')
    assert_eq(g.route.points[2].x, 999, 'waypoint_insert before 0: old first shifted')
end

local function test_waypoint_insert_at_end_equivalent_to_add()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'wi3' })
    -- route has 1 point; --before 1 appends
    local r = verbs.waypoint_insert({ name = 'wi3', before = 1, north = 10, east = 20 })
    assert_true(r.ok, 'waypoint_insert at end: ok')
    assert_eq(r.index, 1, 'waypoint_insert at end: index 1')
    assert_eq(#g.route.points, 2, 'waypoint_insert at end: route grew')
end

local function test_waypoint_insert_oob()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'wi4' })
    -- route has 1 point; --before 5 is out of range
    local r = verbs.waypoint_insert({ name = 'wi4', before = 5, north = 1, east = 2 })
    assert_false(r.ok, 'waypoint_insert oob: rejected')
    assert_contains(r.error, 'out of range', 'oob error')
end

local function test_waypoint_remove_middle()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'wr1' })
    g.route.points[1].x = 100
    table.insert(g.route.points, mock.make_waypoint('vehicle', { x = 200, y = 0 }))
    table.insert(g.route.points, mock.make_waypoint('vehicle', { x = 300, y = 0 }))
    local r = verbs.waypoint_remove({ name = 'wr1', index = 1 })
    assert_true(r.ok, 'waypoint_remove middle: ok')
    assert_eq(#g.route.points, 2, 'waypoint_remove: route shrunk')
    assert_eq(g.route.points[1].x, 100, 'waypoint_remove: WP 0 untouched')
    assert_eq(g.route.points[2].x, 300, 'waypoint_remove: WP 2 shifted to 1')
end

local function test_waypoint_remove_air_last_refused()
    mock.new_mission()
    local g = mock.add_plane({ name = 'wr2' })
    local r = verbs.waypoint_remove({ name = 'wr2', index = 0 })
    assert_false(r.ok, 'waypoint_remove air-last: refused')
    assert_contains(r.error, 'air group', 'air-last error')
    assert_eq(#g.route.points, 1, 'waypoint_remove air-last: route untouched')
end

local function test_waypoint_remove_air_not_last_allowed()
    mock.new_mission()
    local g = mock.add_plane({ name = 'wr3' })
    table.insert(g.route.points, mock.make_waypoint('plane'))
    local r = verbs.waypoint_remove({ name = 'wr3', index = 0 })
    assert_true(r.ok, 'waypoint_remove air-not-last: ok')
    assert_eq(#g.route.points, 1, 'waypoint_remove: 1 WP remains')
end

local function test_waypoint_remove_ground_last_allowed()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'wr4' })
    local r = verbs.waypoint_remove({ name = 'wr4', index = 0 })
    assert_true(r.ok, 'waypoint_remove ground-last: ok')
    assert_eq(#g.route.points, 0, 'waypoint_remove ground-last: empty')
end

local function test_task_preservation_on_neighbor_after_add()
    mock.new_mission()
    local g = mock.add_plane({ name = 'tp1' })
    g.route.points[1].task.params.tasks = { { id = 'Orbit', params = { altitude = 500 } } }
    verbs.waypoint_add({ name = 'tp1', north = 1, east = 1 })
    assert_eq(g.route.points[1].task.params.tasks[1].id, 'Orbit',
              'task preservation: neighbor WP task untouched')
    assert_eq(#g.route.points[2].task.params.tasks, 0,
              'task preservation: new WP has empty task')
end

local function _setup_plane_route(name)
    mock.new_mission()
    local g = mock.add_plane({ name = name })
    table.insert(g.route.points, mock.make_waypoint('plane',
        { x = 1000, y = 2000, name = 'WP1', alt = 5000, speed = 200 }))
    return g
end

local function test_set_pos()
    local g = _setup_plane_route('sp1')
    local r = verbs.waypoint_set_pos({ name = 'sp1', index = 1, north = 9999, east = 8888 })
    assert_true(r.ok, 'set_pos: ok')
    assert_eq(g.route.points[2].x, 9999, 'set_pos: x updated')
    assert_eq(g.route.points[2].y, 8888, 'set_pos: y updated')
    local r2 = verbs.waypoint_set_pos({ name = 'sp1', index = 5, north = 1, east = 1 })
    assert_false(r2.ok, 'set_pos: oob rejected')
end

local function test_set_alt()
    local g = _setup_plane_route('sa1')
    local r = verbs.waypoint_set_alt({ name = 'sa1', index = 1, alt = 7500, alt_type = 'RADIO' })
    assert_true(r.ok, 'set_alt: ok')
    assert_eq(g.route.points[2].alt, 7500, 'set_alt: alt')
    assert_eq(g.route.points[2].alt_type, 'RADIO', 'set_alt: alt_type')
    local r2 = verbs.waypoint_set_alt({ name = 'sa1', index = 1, alt = -1 })
    assert_false(r2.ok, 'set_alt: negative alt rejected')
    local r3 = verbs.waypoint_set_alt({ name = 'sa1', index = 1, alt = 5000, alt_type = 'X' })
    assert_false(r3.ok, 'set_alt: bad alt_type rejected')
end

local function test_set_speed()
    local g = _setup_plane_route('ss1')
    local r = verbs.waypoint_set_speed({ name = 'ss1', index = 1, speed = 250 })
    assert_true(r.ok, 'set_speed: ok')
    assert_eq(g.route.points[2].speed, 250, 'set_speed: applied')
    local r2 = verbs.waypoint_set_speed({ name = 'ss1', index = 1, speed = 0 })
    assert_false(r2.ok, 'set_speed: zero rejected')
end

local function test_set_type()
    local g = _setup_plane_route('st1')
    local r = verbs.waypoint_set_type({ name = 'st1', index = 1, wp_type = 'Land' })
    assert_true(r.ok, 'set_type: ok')
    assert_eq(g.route.points[2].type, 'Land', 'set_type: applied')
    local r2 = verbs.waypoint_set_type({ name = 'st1', index = 1, wp_type = 'Bogus' })
    assert_false(r2.ok, 'set_type: bad enum rejected')
end

local function test_set_action()
    local g = _setup_plane_route('act1')
    local r = verbs.waypoint_set_action({ name = 'act1', index = 1, action = 'Fly Over Point' })
    assert_true(r.ok, 'set_action: ok')
    assert_eq(g.route.points[2].action, 'Fly Over Point', 'set_action: applied')
    -- Non-airfield action on a non-airfield type leaves the type alone.
    assert_eq(g.route.points[2].type, 'Turning Point', 'set_action: type unchanged for plain action')
    assert_eq(r.type, 'Turning Point', 'set_action: returns type')
end

-- gh #68 item 4: an airfield action pairs the waypoint type with it.
local function test_set_action_pairs_airfield_type()
    local g = _setup_plane_route('act2')
    local r = verbs.waypoint_set_action({ name = 'act2', index = 1, action = 'From Parking Area' })
    assert_true(r.ok, 'set_action parking: ok')
    assert_eq(g.route.points[2].action, 'From Parking Area', 'set_action parking: action')
    assert_eq(g.route.points[2].type, 'TakeOffParking', 'set_action parking: type paired')
    assert_eq(r.type, 'TakeOffParking', 'set_action parking: returns paired type')

    local r2 = verbs.waypoint_set_action({ name = 'act2', index = 1, action = 'Landing' })
    assert_eq(g.route.points[2].type, 'Land', 'set_action landing: type paired')
end

-- Switching from an airfield action to a plain one reverts the type and
-- clears the airfield linkage fields.
local function test_set_action_reverts_type_and_clears_linkage()
    local g = _setup_plane_route('act3')
    g.route.points[2].type = 'TakeOffParking'
    g.route.points[2].airdromeId = 12
    local r = verbs.waypoint_set_action({ name = 'act3', index = 1, action = 'Turning Point' })
    assert_true(r.ok, 'set_action revert: ok')
    assert_eq(g.route.points[2].type, 'Turning Point', 'set_action revert: type reset')
    assert_eq(g.route.points[2].airdromeId, nil, 'set_action revert: airdromeId cleared')
end

local function test_set_name()
    local g = _setup_plane_route('sn1')
    local r = verbs.waypoint_set_name({ name = 'sn1', index = 1, name_text = 'IP-North' })
    assert_true(r.ok, 'set_name: ok')
    assert_eq(g.route.points[2].name, 'IP-North', 'set_name: applied')
    local r2 = verbs.waypoint_set_name({ name = 'sn1', index = 1, name_text = '' })
    assert_true(r2.ok, 'set_name: empty is legal')
    assert_eq(g.route.points[2].name, '', 'set_name: empty applied')
end

local function test_set_eta()
    local g = _setup_plane_route('se1')
    local r = verbs.waypoint_set_eta({ name = 'se1', index = 1, eta = 600 })
    assert_true(r.ok, 'set_eta: ok')
    assert_eq(g.route.points[2].ETA, 600, 'set_eta: applied')
    local r2 = verbs.waypoint_set_eta({ name = 'se1', index = 1, eta = -1 })
    assert_false(r2.ok, 'set_eta: negative rejected')
end

local function test_set_speed_locked()
    local g = _setup_plane_route('sl1')
    g.route.points[2].speed_locked = false
    local r = verbs.waypoint_set_speed_locked({ name = 'sl1', index = 1, locked = true })
    assert_true(r.ok, 'set_speed_locked: ok')
    assert_eq(g.route.points[2].speed_locked, true, 'set_speed_locked: applied')
end

local function test_set_eta_locked()
    local g = _setup_plane_route('el1')
    g.route.points[2].ETA_locked = true
    local r = verbs.waypoint_set_eta_locked({ name = 'el1', index = 1, locked = false })
    assert_true(r.ok, 'set_eta_locked: ok')
    assert_eq(g.route.points[2].ETA_locked, false, 'set_eta_locked: applied')
end

local function test_set_formation()
    local g = _setup_plane_route('sf1')
    local r = verbs.waypoint_set_formation({
        name = 'sf1', index = 1, formation_template = 'Diamond' })
    assert_true(r.ok, 'set_formation: ok')
    assert_eq(g.route.points[2].formation_template, 'Diamond', 'set_formation: applied')
end

local function test_set_mode_landing()
    local g = _setup_plane_route('sm1')
    local r = verbs.waypoint_set_mode({ name = 'sm1', index = 1, mode = 'Landing' })
    assert_true(r.ok, 'set_mode Landing: ok')
    assert_eq(g.route.points[2].type, 'Land', 'set_mode Landing: wpt.type = Land')
    assert_eq(g.route.points[2].action, 'Landing', 'set_mode Landing: wpt.action = Landing')
end

local function test_set_mode_case_insensitive()
    local g = _setup_plane_route('sm2')
    local r = verbs.waypoint_set_mode({ name = 'sm2', index = 1, mode = 'TAKEOFF FROM PARKING' })
    assert_true(r.ok, 'set_mode case-insensitive: ok')
    assert_eq(g.route.points[2].type, 'TakeOffParking', 'set_mode TFP: wpt.type')
    assert_eq(g.route.points[2].action, 'From Parking Area', 'set_mode TFP: wpt.action')
end

local function test_set_mode_ground_formation()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'sm3' })
    table.insert(g.route.points, mock.make_waypoint('vehicle', { x = 1000, y = 0 }))
    local r = verbs.waypoint_set_mode({ name = 'sm3', index = 1, mode = 'Cone' })
    assert_true(r.ok, 'set_mode Cone: ok')
    assert_eq(g.route.points[2].type, 'Turning Point', 'set_mode Cone: wpt.type = Turning Point')
    assert_eq(g.route.points[2].action, 'Cone', 'set_mode Cone: wpt.action = Cone')
end

local function test_set_mode_unknown_rejected()
    local g = _setup_plane_route('sm4')
    local r = verbs.waypoint_set_mode({ name = 'sm4', index = 1, mode = 'Bogus' })
    assert_false(r.ok, 'set_mode unknown: rejected')
    assert_contains(r.error, 'unknown waypoint mode', 'set_mode unknown: error msg')
end

local function test_set_mode_alias_line_abreast()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'sm5' })
    table.insert(g.route.points, mock.make_waypoint('vehicle', { x = 1000, y = 0 }))
    local r = verbs.waypoint_set_mode({ name = 'sm5', index = 1, mode = 'Line abreast' })
    assert_true(r.ok, 'set_mode Line abreast: ok')
    assert_eq(g.route.points[2].action, 'Rank', 'set_mode Line abreast: alias maps to Rank')
end

local function test_set_mode_landing_clears_timerefuar()
    -- Going FROM LandingReFuAr (with timeReFuAr=10) TO plain Landing
    -- must clear timeReFuAr; otherwise panel_route re-derives the type
    -- as LandingReFuAr regardless of the wpt.type string we set.
    local g = _setup_plane_route('rfa1')
    g.route.points[2].type = 'LandingReFuAr'
    g.route.points[2].action = 'LandingReFuAr'
    g.route.points[2].timeReFuAr = 10
    local r = verbs.waypoint_set_mode({ name = 'rfa1', index = 1, mode = 'Landing' })
    assert_true(r.ok, 'set_mode LRF→L: ok')
    assert_eq(g.route.points[2].type, 'Land', 'set_mode LRF→L: type = Land')
    assert_eq(g.route.points[2].action, 'Landing', 'set_mode LRF→L: action = Landing')
    assert_eq(g.route.points[2].timeReFuAr, nil, 'set_mode LRF→L: timeReFuAr cleared')
end

local function test_set_mode_landingrefuar_sets_default_timerefuar()
    local g = _setup_plane_route('rfa2')
    local r = verbs.waypoint_set_mode({ name = 'rfa2', index = 1, mode = 'LandingReFuAr' })
    assert_true(r.ok, 'set_mode L→LRF: ok')
    assert_eq(g.route.points[2].type, 'LandingReFuAr', 'set_mode L→LRF: type = LandingReFuAr')
    assert_eq(g.route.points[2].timeReFuAr, 10, 'set_mode L→LRF: timeReFuAr = 10 default')
end

local function test_set_mode_preserves_existing_timerefuar()
    -- If timeReFuAr was already set to a non-default, set-mode LandingReFuAr
    -- should NOT overwrite it (user may have a custom duration).
    local g = _setup_plane_route('rfa3')
    g.route.points[2].timeReFuAr = 300
    local r = verbs.waypoint_set_mode({ name = 'rfa3', index = 1, mode = 'LandingReFuAr' })
    assert_true(r.ok, 'set_mode preserves: ok')
    assert_eq(g.route.points[2].timeReFuAr, 300, 'set_mode preserves: existing timeReFuAr kept')
end

local function test_set_type_clears_timerefuar_on_transition_away()
    local g = _setup_plane_route('rfa4')
    g.route.points[2].type = 'LandingReFuAr'
    g.route.points[2].timeReFuAr = 10
    local r = verbs.waypoint_set_type({ name = 'rfa4', index = 1, wp_type = 'Turning Point' })
    assert_true(r.ok, 'set_type LRF→TP: ok')
    assert_eq(g.route.points[2].timeReFuAr, nil, 'set_type LRF→TP: timeReFuAr cleared')
end

local function test_set_mode_clears_airdrome_on_transition()
    local g = _setup_plane_route('sm6')
    g.route.points[2].type = 'TakeOffParkingHot'
    g.route.points[2].airdromeId = 42
    g.route.points[2].helipadId = 7
    local r = verbs.waypoint_set_mode({ name = 'sm6', index = 1, mode = 'Turning point' })
    assert_true(r.ok, 'set_mode airfield→turning: ok')
    assert_eq(g.route.points[2].type, 'Turning Point', 'airfield→turning: type set')
    assert_eq(g.route.points[2].airdromeId, nil, 'airfield→turning: airdromeId cleared')
    assert_eq(g.route.points[2].helipadId, nil, 'airfield→turning: helipadId cleared')
end

local function test_set_pos_vehicle_first_wp_updates_span()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'vh1' })
    g.route.points[1].x = 0
    g.route.points[1].y = 0
    table.insert(g.route.points, mock.make_waypoint('vehicle', { x = 1000, y = 0 }))
    g.route.spans = {
        { { x = 0, y = 0 }, { x = 1000, y = 0 } },
        { { x = 1000, y = 0 }, { x = 1000, y = 0 } },
    }
    local r = verbs.waypoint_set_pos({ name = 'vh1', index = 0, north = 500, east = 500 })
    assert_true(r.ok, 'set_pos vehicle WP 0: ok')
    assert_eq(g.route.points[1].x, 500, 'set_pos vehicle WP 0: wpt.x updated')
    assert_eq(g.route.spans[1][1].x, 500, 'set_pos vehicle WP 0: spans[1] start x updated')
    assert_eq(g.route.spans[1][1].y, 500, 'set_pos vehicle WP 0: spans[1] start y updated')
    assert_eq(g.route.spans[1][2].x, 1000, 'set_pos vehicle WP 0: spans[1] end x preserved')
end

local function test_set_pos_vehicle_middle_wp_updates_both_spans()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'vh2' })
    g.route.points[1].x = 0
    g.route.points[1].y = 0
    table.insert(g.route.points, mock.make_waypoint('vehicle', { x = 1000, y = 0 }))
    table.insert(g.route.points, mock.make_waypoint('vehicle', { x = 2000, y = 0 }))
    g.route.spans = {
        { { x = 0, y = 0 }, { x = 1000, y = 0 } },
        { { x = 1000, y = 0 }, { x = 2000, y = 0 } },
        { { x = 2000, y = 0 }, { x = 2000, y = 0 } },
    }
    local r = verbs.waypoint_set_pos({ name = 'vh2', index = 1, north = 500, east = 500 })
    assert_true(r.ok, 'set_pos vehicle middle WP: ok')
    assert_eq(g.route.points[2].x, 500, 'set_pos vehicle middle: wpt.x updated')
    -- spans[1] endpoint (segment from WP 0 to WP 1) gets the new pos
    assert_eq(g.route.spans[1][2].x, 500, 'set_pos vehicle middle: prev-span end x updated')
    assert_eq(g.route.spans[1][2].y, 500, 'set_pos vehicle middle: prev-span end y updated')
    -- spans[2] startpoint (segment from WP 1 to WP 2) gets the new pos
    assert_eq(g.route.spans[2][1].x, 500, 'set_pos vehicle middle: next-span start x updated')
    assert_eq(g.route.spans[2][1].y, 500, 'set_pos vehicle middle: next-span start y updated')
    -- spans[2] endpoint preserved (still at WP 2)
    assert_eq(g.route.spans[2][2].x, 2000, 'set_pos vehicle middle: next-span end x preserved')
end

local function test_task_preservation_on_setters()
    local g = _setup_plane_route('tp2')
    g.route.points[1].task.params.tasks = { { id = 'Orbit', params = { alt = 500 } } }
    g.route.points[2].task.params.tasks = { { id = 'Bombing', params = {} } }
    verbs.waypoint_set_pos({ name = 'tp2', index = 1, north = 0, east = 0 })
    assert_eq(g.route.points[1].task.params.tasks[1].id, 'Orbit', 'setter: WP0 task preserved')
    assert_eq(g.route.points[2].task.params.tasks[1].id, 'Bombing', 'setter: target WP task preserved')
end

-- ============================================================
-- Test runner
-- ============================================================

test_smoke()
test_find_route_happy()
test_find_route_not_found()
test_find_route_args_mutex()
test_find_waypoint_range()
test_inherit_waypoint_empty_route_uses_category_defaults()
test_inherit_waypoint_from_source()
test_inherit_overrides_win()
test_route_list_summary_fields()
test_route_get_preserves_task()
test_route_clear_ground()
test_route_clear_air_refused()
test_waypoint_get_full_fields()
test_strip_back_refs_budget_caps_diamond()
test_refresh_called_on_clear()
test_waypoint_add_appends()
test_waypoint_add_enum_validation()
test_waypoint_insert_shifts_indices()
test_waypoint_insert_before_zero()
test_waypoint_insert_at_end_equivalent_to_add()
test_waypoint_insert_oob()
test_waypoint_remove_middle()
test_waypoint_remove_air_last_refused()
test_waypoint_remove_air_not_last_allowed()
test_waypoint_remove_ground_last_allowed()
test_task_preservation_on_neighbor_after_add()
test_set_pos(); test_set_alt(); test_set_speed(); test_set_type(); test_set_action()
test_set_action_pairs_airfield_type()
test_set_action_reverts_type_and_clears_linkage()
test_set_name(); test_set_eta(); test_set_speed_locked(); test_set_eta_locked()
test_set_formation()
test_set_mode_landing()
test_set_mode_case_insensitive()
test_set_mode_ground_formation()
test_set_mode_unknown_rejected()
test_set_mode_alias_line_abreast()
test_set_mode_clears_airdrome_on_transition()
test_set_mode_landing_clears_timerefuar()
test_set_mode_landingrefuar_sets_default_timerefuar()
test_set_mode_preserves_existing_timerefuar()
test_set_type_clears_timerefuar_on_transition_away()
test_set_pos_vehicle_first_wp_updates_span()
test_set_pos_vehicle_middle_wp_updates_both_spans()
test_task_preservation_on_setters()

print(string.format('test_verbs_route: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
