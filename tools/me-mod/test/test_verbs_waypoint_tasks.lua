-- test_verbs_waypoint_tasks.lua — Lua-side unit tests for the gh #69
-- waypoint task / enroute-task verbs.
--
-- Run via:
--   cd tools/me-mod/test && lua test_verbs_waypoint_tasks.lua
-- Or through the harness:
--   pwsh tools/me-mod/test/run-tests.ps1

local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path

-- ============================================================
-- Inject a fake `me_action_db` BEFORE any task_db load.
-- ============================================================
-- The live ED probe (May 2026) showed task descriptors live in
-- `me_action_db.actionsData`, a flat array of entries shaped
-- `{ desc, displayName, task = { id, params }, type }` where
-- type = 1 (waypoint task), 2 (enroute task), 3 (command), or
-- 4 (option). task_db.lua walks this array. The fake below
-- mirrors that shape with just enough entries for these tests:
-- two waypoint tasks (Bombing, AttackGroup), two enroute tasks
-- (EngageTargets, CAP), and one command (Option, type=3) which
-- the walker MUST skip.
local fake_db = {
    actionsData = {
        -- waypoint tasks (type = 1)
        { type = 1, displayName = 'Bombing', desc = 'Drop bombs',
          task = { id = 'Bombing',
                   params = { altitude = 2000, expend = 'All', weaponType = 2048 } } },
        { type = 1, displayName = 'Attack Group', desc = 'Attack a group',
          task = { id = 'AttackGroup',
                   params = { expend = 'Auto', weaponType = 2048 } } },
        -- enroute tasks (type = 2)
        { type = 2, displayName = 'Engage Targets', desc = 'Engage enemy targets',
          task = { id = 'EngageTargets',
                   params = { targetTypes = { 'Air' } } } },
        { type = 2, displayName = 'CAP', desc = 'Combat Air Patrol',
          task = { id = 'CAP',
                   params = { targetTypes = { 'Air' } } } },
        -- command (type = 3) — should be ignored by the walker
        { type = 3, displayName = 'Option', desc = 'Set option',
          task = { id = 'WrappedAction', params = {} } },
    },
}
package.preload['me_action_db'] = function() return fake_db end

-- Mock mission state.
local mock = require('mock_me_mission')
package.preload['me_mission']    = function() return mock end
package.preload['me_map_window'] = function() return mock end

-- Adjust package.path so dcs_sms_me.* requires resolve from the source tree.
package.path = here .. '../lua/?.lua;' .. here .. '../lua/?/init.lua;' .. package.path

local verbs = require('dcs_sms_me.verbs')

-- Force task_db cache rebuild against OUR fake_db. run-tests.ps1 runs
-- tests in alphabetical order, so test_verbs_aggregator.lua may have
-- triggered task_db lazy-load earlier in the suite. (Each test is its
-- own process so cache state shouldn't leak across files, but resetting
-- is cheap insurance and matches the plan's explicit instruction.)
require('dcs_sms_me.task_db').reset()

-- ============================================================
-- Test plumbing
-- ============================================================

local fails = 0
local passes = 0

local function check(cond, msg)
    if cond then
        passes = passes + 1
    else
        fails = fails + 1
        print('FAIL: ' .. tostring(msg))
    end
end

local function eq(actual, expected, msg)
    if actual == expected then
        passes = passes + 1
    else
        fails = fails + 1
        print(string.format('FAIL: %s (got %s, want %s)',
            tostring(msg), tostring(actual), tostring(expected)))
    end
end

-- ============================================================
-- helpers
-- ============================================================

-- fresh_group: build a CAS plane group with two waypoints so
-- index=1 is a valid mid-route waypoint.
local function fresh_group()
    mock.new_mission()
    local g = mock.add_plane({ name = 'CAS-1', x = 0, y = 0 })
    g.task = 'CAS'
    -- mock.add_plane gives us one waypoint (index 1 in route.points
    -- which is index=0 from the verb side). Insert a second one at
    -- position 2 so verb-index=1 (== route.points[2]) is real.
    mock.insert_waypoint(g, 2, 'Turning Point', 1000, 0, 5000, 220, 'WP2')
    return g
end

-- tasks_at: shorthand for the ComboTask tasks array at verb-index.
-- verbs treat index 0 as the first waypoint, so route.points[index+1].
local function tasks_at(g, index)
    return g.route.points[index + 1].task.params.tasks
end

-- ============================================================
-- waypoint_add_task — happy path
-- ============================================================

local g = fresh_group()
local r = verbs.waypoint_add_task({ name = 'CAS-1', index = 1, task = 'Bombing',
                                     fields = { altitude = 1500 } })
check(r.ok, 'add Bombing OK: ' .. tostring(r.error))
eq(r.task, 'Bombing', 'returned task id')
eq(r.kind, 'waypoint', 'returned kind')
eq(r.slot, 1, 'returned slot')
local arr = tasks_at(g, 1)
eq(#arr, 1, 'tasks count after add')
eq(arr[1].id, 'Bombing', 'stored id')
eq(arr[1].enabled, true, 'default enabled')
eq(arr[1].auto, false, 'default auto')
eq(arr[1].number, 1, 'default number')
eq(arr[1].params.altitude, 1500, 'override applied')
eq(arr[1].params.weaponType, 2048, 'default weaponType kept')

-- ============================================================
-- waypoint_add_task — wrong-kind rejection
-- ============================================================

r = verbs.waypoint_add_task({ name = 'CAS-1', index = 1, task = 'EngageTargets' })
check(not r.ok, 'add EngageTargets as waypoint task should fail')
check(type(r.error) == 'string' and r.error:find('enroute', 1, true) ~= nil,
      'error mentions enroute kind: ' .. tostring(r.error))

-- ============================================================
-- waypoint_add_task — unknown task rejection
-- ============================================================

r = verbs.waypoint_add_task({ name = 'CAS-1', index = 1, task = 'NotAReal' })
check(not r.ok, 'add NotAReal should fail')

-- ============================================================
-- waypoint_add_enroute_task — happy path + wrong-kind rejection
-- ============================================================

g = fresh_group()
r = verbs.waypoint_add_enroute_task({ name = 'CAS-1', index = 1, task = 'EngageTargets' })
check(r.ok, 'add EngageTargets enroute OK: ' .. tostring(r.error))
eq(r.kind, 'enroute', 'enroute kind')

r = verbs.waypoint_add_enroute_task({ name = 'CAS-1', index = 1, task = 'Bombing' })
check(not r.ok, 'add Bombing as enroute task should fail')
check(type(r.error) == 'string' and r.error:find('waypoint', 1, true) ~= nil,
      'wrong-kind enroute error mentions waypoint: ' .. tostring(r.error))

-- ============================================================
-- waypoint_remove_task / waypoint_remove_enroute_task
-- ============================================================
-- Build a sandwich: [waypoint, enroute, waypoint].

g = fresh_group()
verbs.waypoint_add_task        ({ name = 'CAS-1', index = 1, task = 'Bombing' })
verbs.waypoint_add_enroute_task({ name = 'CAS-1', index = 1, task = 'EngageTargets' })
verbs.waypoint_add_task        ({ name = 'CAS-1', index = 1, task = 'AttackGroup' })
eq(#tasks_at(g, 1), 3, 'three tasks before remove')

-- slot 2 is enroute — waypoint remove must reject it.
r = verbs.waypoint_remove_task({ name = 'CAS-1', index = 1, slot = 2 })
check(not r.ok, 'remove-waypoint on enroute slot should fail')
check(type(r.error) == 'string' and r.error:find('enroute', 1, true) ~= nil,
      'kind-mismatch error mentions enroute: ' .. tostring(r.error))

-- slot 2 via enroute remove succeeds.
r = verbs.waypoint_remove_enroute_task({ name = 'CAS-1', index = 1, slot = 2 })
check(r.ok, 'remove-enroute slot 2 OK: ' .. tostring(r.error))
eq(r.removed_task, 'EngageTargets', 'removed task id')
eq(#tasks_at(g, 1), 2, 'two tasks after remove')
eq(tasks_at(g, 1)[1].number, 1, 'renumbered slot 1 → number 1')
eq(tasks_at(g, 1)[2].number, 2, 'renumbered slot 2 → number 2')

-- OOR slot
r = verbs.waypoint_remove_task({ name = 'CAS-1', index = 1, slot = 99 })
check(not r.ok, 'OOR slot 99 should fail')

-- ============================================================
-- waypoint_clear_tasks / waypoint_clear_enroute_tasks
-- ============================================================

g = fresh_group()
verbs.waypoint_add_task        ({ name = 'CAS-1', index = 1, task = 'Bombing' })
verbs.waypoint_add_task        ({ name = 'CAS-1', index = 1, task = 'AttackGroup' })
verbs.waypoint_add_enroute_task({ name = 'CAS-1', index = 1, task = 'EngageTargets' })
eq(#tasks_at(g, 1), 3, 'three tasks before clear-waypoint')

r = verbs.waypoint_clear_tasks({ name = 'CAS-1', index = 1 })
check(r.ok, 'clear waypoint OK: ' .. tostring(r.error))
eq(r.removed_count, 2, 'cleared 2 waypoint tasks')
eq(#tasks_at(g, 1), 1, 'enroute task remains')
eq(tasks_at(g, 1)[1].id, 'EngageTargets', 'remaining is the enroute task')

r = verbs.waypoint_clear_enroute_tasks({ name = 'CAS-1', index = 1 })
check(r.ok, 'clear enroute OK: ' .. tostring(r.error))
eq(#tasks_at(g, 1), 0, 'tasks empty after both clears')

-- ============================================================
-- waypoint_list_tasks
-- ============================================================
-- The Lua-side surface is intentionally simplified post-pivot: no
-- --name / --id / --all args (live-probe found no static group-task
-- → legal-tasks index). Only the optional --kind filter remains.

r = verbs.waypoint_list_tasks({})
check(r.ok, 'list-tasks no-args OK: ' .. tostring(r.error))
eq(#r.waypoint_tasks, 2, 'two waypoint tasks (Bombing, AttackGroup)')
eq(#r.enroute_tasks, 2, 'two enroute tasks (EngageTargets, CAP)')

r = verbs.waypoint_list_tasks({ kind = 'waypoint' })
check(r.ok, 'list-tasks kind=waypoint OK: ' .. tostring(r.error))
eq(#r.waypoint_tasks, 2, 'kind=waypoint: 2 waypoint tasks')
eq(#(r.enroute_tasks or {}), 0, 'kind=waypoint: enroute list empty')

-- ============================================================
-- waypoint_describe_task
-- ============================================================

r = verbs.waypoint_describe_task({ task = 'Bombing' })
check(r.ok, 'describe Bombing OK: ' .. tostring(r.error))
eq(r.kind, 'waypoint', 'describe kind = waypoint')
eq(r.task, 'Bombing', 'describe echoed task id')
eq(r.display_name, 'Bombing', 'describe display_name')
eq(r.desc, 'Drop bombs', 'describe desc')
check(type(r.fields) == 'table' and #r.fields >= 1,
      'describe fields non-empty (got ' .. tostring(r.fields and #r.fields) .. ')')

-- wrong-kind filter on Bombing must fail.
r = verbs.waypoint_describe_task({ task = 'Bombing', kind = 'enroute' })
check(not r.ok, 'describe Bombing with kind=enroute should fail')

-- unknown task must fail.
r = verbs.waypoint_describe_task({ task = 'NotAReal' })
check(not r.ok, 'describe NotAReal should fail')

-- ============================================================
-- result
-- ============================================================

if fails == 0 then
    print(string.format('test_verbs_waypoint_tasks.lua: OK (%d checks)', passes))
    os.exit(0)
else
    print(string.format('test_verbs_waypoint_tasks.lua: %d FAILURES (%d passes)',
        fails, passes))
    os.exit(1)
end
