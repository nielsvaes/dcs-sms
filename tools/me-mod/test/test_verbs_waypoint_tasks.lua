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
-- `{ desc, displayName, task = { id, key?, params }, type }` where
-- type = 1 (waypoint task), 2 (enroute task), 3 (command), or
-- 4 (option). task_db.lua walks this array AND walks
-- `me_action_db.availableActions[group_type][type_num][group_task]`
-- (an array of integer indexes INTO actionsData) to build the
-- legal-tasks gate. The add-task verb refuses entries not in that
-- gate's list — mirrors what ED's UI filters out of its listbox.
--
-- The fake below mirrors that shape. Indexes are load-bearing —
-- availableActions references them by position.
local fake_db = {
    actionsData = {
        -- [1] waypoint task: Bombing (legal for CAS plane waypoint)
        { type = 1, displayName = 'Bombing', desc = 'Drop bombs',
          task = { id = 'Bombing',
                   params = { altitude = 2000, expend = 'All', weaponType = 2048 } } },
        -- [2] waypoint task: AttackGroup (legal for CAS plane waypoint)
        { type = 1, displayName = 'Attack Group', desc = 'Attack a group',
          task = { id = 'AttackGroup',
                   params = { expend = 'Auto', weaponType = 2048 } } },
        -- [3] waypoint task: NoTask (NOT legal for CAS plane — used for
        -- the gate-rejection assertion). Includes one numeric param and
        -- one boolean param so coercion can be exercised against it.
        { type = 1, displayName = 'No Task', desc = 'Do nothing',
          task = { id = 'NoTask',
                   params = { someNum = 7, someBool = false } } },
        -- [4] enroute task: EngageTargets (legal for CAS plane enroute)
        { type = 2, displayName = 'Engage Targets', desc = 'Engage enemy targets',
          task = { id = 'EngageTargets',
                   params = { targetTypes = { 'Air' } } } },
        -- [5] enroute task: CAP (legal for CAS plane enroute)
        { type = 2, displayName = 'CAP', desc = 'Combat Air Patrol',
          task = { id = 'CAP',
                   params = { targetTypes = { 'Air' } } } },
        -- [6] command (type=3) — must be ignored by the walker
        { type = 3, displayName = 'Option', desc = 'Set option',
          task = { id = 'WrappedAction', params = {} } },
        -- [7] waypoint task: Orbit (legal for CAS plane waypoint;
        -- carries pattern-conditional variants via task_extras)
        { type = 1, displayName = 'Orbit', desc = 'Orbit pattern',
          task = { id = 'Orbit',
                   params = { pattern = 'Race-Track', altitude = 2000 } } },
    },
    -- availableActions[group_type][action_type_num][group_task_or_Default]
    --   = { action_id_int, ... }
    -- action_type_num: 1 = waypoint task, 2 = enroute task
    -- action_id_int: 1-based index into actionsData above.
    availableActions = {
        plane = {
            [1] = {  -- waypoint tasks
                CAS     = { 1, 2, 7 },        -- Bombing, AttackGroup, Orbit
                Default = { 1, 2, 3, 7 },     -- everything except enroute
            },
            [2] = {  -- enroute tasks
                CAS     = { 4, 5 },           -- EngageTargets, CAP
                Default = { 4, 5 },
            },
        },
    },
}
package.preload['me_action_db'] = function() return fake_db end

-- Inject task_extras BEFORE the first task_db load so describe-task
-- can surface the Orbit `variants` field. task_db._load_extras
-- pcalls require('dcs_sms_me.task_extras') each call, so a preload
-- here is the cleanest stub.
local fake_extras = {
    Orbit = {
        always = {
            { id = 'altitude',        type = 'number',  default = 2000 },
            { id = 'altitudeEnabled', type = 'boolean', default = true },
        },
        selector = {
            id = 'pattern',
            type = 'enum',
            options = { 'Circle', 'Race-Track', 'Anchored' },
        },
        variants = {
            { value = 'Circle',     fields = {} },
            { value = 'Race-Track', fields = {} },
            { value = 'Anchored',   fields = {
                { id = 'hotLegDir', type = 'number', default = 0 },
                { id = 'legLength', type = 'number', default = 92500 },
            } },
        },
    },
}
package.preload['dcs_sms_me.task_extras'] = function() return fake_extras end

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
-- index=1 is a valid mid-route waypoint. Sets g.type='plane' and
-- g.task='CAS' because the add-task gate (task_db.resolve via
-- me_action_db.availableActions[g.type][kind][g.task]) needs both.
local function fresh_group()
    mock.new_mission()
    local g = mock.add_plane({ name = 'CAS-1', x = 0, y = 0 })
    g.type = 'plane'
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
-- waypoint_add_task — happy path (legal CAS waypoint task)
-- ============================================================

local g = fresh_group()
local r = verbs.waypoint_add_task({ name = 'CAS-1', index = 1, task = 'AttackGroup',
                                     fields = { expend = 'Half' } })
check(r.ok, 'add AttackGroup OK: ' .. tostring(r.error))
eq(r.task, 'AttackGroup', 'returned task id')
eq(r.kind, 'waypoint', 'returned kind')
eq(r.slot, 1, 'returned slot')
local arr = tasks_at(g, 1)
eq(#arr, 1, 'tasks count after add')
eq(arr[1].id, 'AttackGroup', 'stored id')
eq(arr[1].enabled, true, 'default enabled')
eq(arr[1].auto, false, 'default auto')
eq(arr[1].number, 1, 'default number')
eq(arr[1].params.expend, 'Half', 'override applied')
eq(arr[1].params.weaponType, 2048, 'default weaponType kept')

-- ============================================================
-- waypoint_add_task — illegal-for-group rejection (gate via
-- me_action_db.availableActions). NoTask isn't in plane/CAS's
-- waypoint list, so the add must fail with a discriminating
-- error that mentions the group type AND main task.
-- ============================================================

g = fresh_group()
r = verbs.waypoint_add_task({ name = 'CAS-1', index = 1, task = 'NoTask' })
check(not r.ok, 'add NoTask on CAS plane should fail (not in availableActions)')
check(type(r.error) == 'string'
      and r.error:find('not a legal waypoint task', 1, true) ~= nil
      and r.error:find('plane', 1, true) ~= nil
      and r.error:find('CAS', 1, true) ~= nil,
      'gate error mentions kind/group_type/group_task: ' .. tostring(r.error))

-- ============================================================
-- waypoint_add_task — wrong-kind rejection (cross-kind add)
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
-- waypoint_add_task — string→typed coercion of `fields`
-- ============================================================
-- The Go CLI ships every field arg as a string. _coerce_field_value
-- in route_verbs.lua reads the descriptor's default type and coerces
-- accordingly: NoTask's params include someNum (number) and someBool
-- (boolean). NoTask isn't legal under CAS so swap the group's task
-- temporarily to 'Default' to exercise the path.
--
-- Coercion is exercised on AttackGroup instead so we don't need to
-- bend the gate: use expend (string passthrough), weaponType
-- (number coercion from "1024"), and the structural flags
-- enabled/auto (boolean coercion from "true"/"false").
g = fresh_group()
r = verbs.waypoint_add_task({
    name = 'CAS-1', index = 1, task = 'AttackGroup',
    fields = {
        weaponType = '1024',  -- string-form number must become number
        enabled    = 'false', -- string-form boolean → boolean
        auto       = 'true',  -- string-form boolean → boolean
        number     = '3',     -- string-form number → number
    },
})
check(r.ok, 'add with string-form fields OK: ' .. tostring(r.error))
arr = tasks_at(g, 1)
eq(arr[1].params.weaponType, 1024, 'weaponType coerced "1024" -> 1024')
eq(type(arr[1].params.weaponType), 'number', 'weaponType is number')
eq(arr[1].enabled, false, 'enabled coerced "false" -> false')
eq(type(arr[1].enabled), 'boolean', 'enabled is boolean')
eq(arr[1].auto, true, 'auto coerced "true" -> true')
eq(type(arr[1].auto), 'boolean', 'auto is boolean')
-- _renumber overwrites the caller-supplied `number` to its slot
-- position, so the final stored number is the slot (1), not "3".
eq(arr[1].number, 1, 'number renumbered to slot index')

-- ============================================================
-- waypoint_add_enroute_task — happy path + wrong-kind rejection
-- ============================================================

g = fresh_group()
r = verbs.waypoint_add_enroute_task({ name = 'CAS-1', index = 1, task = 'EngageTargets' })
check(r.ok, 'add EngageTargets enroute OK: ' .. tostring(r.error))
eq(r.kind, 'enroute', 'enroute kind')

r = verbs.waypoint_add_enroute_task({ name = 'CAS-1', index = 1, task = 'AttackGroup' })
check(not r.ok, 'add AttackGroup as enroute task should fail')
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
eq(tasks_at(g, 1)[1].number, 1, 'renumbered slot 1 -> number 1')
eq(tasks_at(g, 1)[2].number, 2, 'renumbered slot 2 -> number 2')

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
-- No-args lists ALL canonical task ids by kind (no group context →
-- gate skipped). With --name, the response is filtered through the
-- availableActions index for that group's (type, main_task).

r = verbs.waypoint_list_tasks({})
check(r.ok, 'list-tasks no-args OK: ' .. tostring(r.error))
-- Global lists: Bombing, AttackGroup, NoTask, Orbit (4 waypoint),
-- EngageTargets, CAP (2 enroute).
eq(#r.waypoint_tasks, 4, 'four waypoint tasks (Bombing, AttackGroup, NoTask, Orbit)')
eq(#r.enroute_tasks, 2, 'two enroute tasks (EngageTargets, CAP)')

r = verbs.waypoint_list_tasks({ kind = 'waypoint' })
check(r.ok, 'list-tasks kind=waypoint OK: ' .. tostring(r.error))
eq(#r.waypoint_tasks, 4, 'kind=waypoint: 4 waypoint tasks')
eq(#(r.enroute_tasks or {}), 0, 'kind=waypoint: enroute list empty')

-- Group-scoped list filters by availableActions[plane][kind][CAS].
g = fresh_group()
r = verbs.waypoint_list_tasks({ name = 'CAS-1' })
check(r.ok, 'list-tasks --name CAS-1 OK: ' .. tostring(r.error))
-- availableActions.plane[1].CAS = {1, 2, 7} → Bombing, AttackGroup, Orbit
eq(#r.waypoint_tasks, 3, 'CAS plane: 3 legal waypoint tasks')
-- availableActions.plane[2].CAS = {4, 5} → EngageTargets, CAP
eq(#r.enroute_tasks, 2, 'CAS plane: 2 legal enroute tasks')

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
-- waypoint_describe_task — variants surfacing (Orbit + task_extras)
-- ============================================================
-- The describe verb pulls task_db.descr_variants(entry); when a
-- task has a task_extras entry with `variants`, the response
-- carries a `variants` array each with { value, fields }.

r = verbs.waypoint_describe_task({ task = 'Orbit' })
check(r.ok, 'describe Orbit OK: ' .. tostring(r.error))
eq(r.task, 'Orbit', 'describe Orbit echoed id')
check(type(r.variants) == 'table',
      'describe Orbit returns variants table (got ' .. type(r.variants) .. ')')
eq(#r.variants, 3, 'Orbit has 3 variants (Circle, Race-Track, Anchored)')

-- Find the Anchored variant — it should carry the extra hotLegDir/legLength fields.
local anchored
for _, v in ipairs(r.variants) do
    if v.value == 'Anchored' then anchored = v; break end
end
check(anchored ~= nil, 'Anchored variant present')
if anchored then
    eq(#anchored.fields, 2, 'Anchored variant has 2 extra fields')
end

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
