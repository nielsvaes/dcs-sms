-- Standalone test for mass_edit_ops. Uses mock_me_mission for entities;
-- compute_plan is the focus here, apply_plan is exercised in the next task.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')
package.preload['me_mission']      = function() return mock end
package.preload['me_loadoututils'] = function() return { getUnitPylons = function() return {} end } end
-- mass_edit_ops doesn't require dcs_sms_me.verbs unless writer needs it
-- (country/loadout only). compute_plan never invokes writers.
package.preload['dcs_sms_me.verbs'] = function() return {} end
-- Stubs needed when apply_plan (and the 'mass_edit' undo handler registration)
-- trigger transitive requires through undo.lua → prefab_ops → selection/warehouse.
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end

local ops = require('dcs_sms_me.mass_edit_ops')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Helper: build a checked entities + parent_map pair from a flat list of (entity, group) pairs.
local function checked(pairs_list)
    local entities, parent_map = {}, {}
    for _, p in ipairs(pairs_list) do
        entities[#entities + 1] = p[1]
        parent_map[p[1]] = p[2]
    end
    return entities, parent_map
end

-- Case 1: unit_skill on 3 air units → 3 ok rows with new=Excellent.
do
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    g.units = {
        { unitId = 1, name = 'A-1', type = 'F/A-18C', skill = 'Average' },
        { unitId = 2, name = 'A-2', type = 'F/A-18C', skill = 'High' },
        { unitId = 3, name = 'A-3', type = 'F/A-18C', skill = 'Good' },
    }
    local ents, pmap = checked({ {g.units[1], g}, {g.units[2], g}, {g.units[3], g} })
    local plan = ops.compute_plan('unit', ents, pmap, 'unit_skill', 'set_all', { value = 'Excellent' })
    check('plan.rows=3', #plan.rows == 3)
    check('all rows ok=true', plan.rows[1].ok and plan.rows[2].ok and plan.rows[3].ok)
    check('row 1 old=Average new=Excellent',
          plan.rows[1].old == 'Average' and plan.rows[1].new == 'Excellent')
end

-- Case 2: unit_skill on 3 plane + 2 static units → 3 ok + 2 category-mismatch.
do
    mock.new_mission()
    local g_plane  = mock.add_plane({ name = 'P' })
    local g_static = mock.add_static({ name = 'S' })
    g_plane.units  = { { unitId = 1, name = 'P-1', type = 'F/A-18C', skill = 'Average' },
                       { unitId = 2, name = 'P-2', type = 'F/A-18C', skill = 'Average' },
                       { unitId = 3, name = 'P-3', type = 'F/A-18C', skill = 'Average' } }
    g_static.units = { { unitId = 4, name = 'S-1', type = 'BTR-80',  skill = nil },
                       { unitId = 5, name = 'S-2', type = 'BTR-80',  skill = nil } }
    local ents, pmap = checked({
        {g_plane.units[1], g_plane}, {g_plane.units[2], g_plane}, {g_plane.units[3], g_plane},
        {g_static.units[1], g_static}, {g_static.units[2], g_static},
    })
    local plan = ops.compute_plan('unit', ents, pmap, 'unit_skill', 'set_all', { value = 'Excellent' })
    local ok_count, fail_count = 0, 0
    for _, r in ipairs(plan.rows) do
        if r.ok then ok_count = ok_count + 1 else fail_count = fail_count + 1 end
    end
    check('mixed plane+static: 3 ok',  ok_count == 3)
    check('mixed plane+static: 2 ✗', fail_count == 2)
    for _, r in ipairs(plan.rows) do
        if not r.ok then
            check('mismatch row has category reason',
                  r.error and r.error:find('category mismatch') ~= nil,
                  'got error=' .. tostring(r.error))
        end
    end
end

-- Case 3: rename collision within batch → second row ✗.
do
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    g.units = {
        { unitId = 1, name = 'A-1', type = 'F/A-18C' },
        { unitId = 2, name = 'A-2', type = 'F/A-18C' },
    }
    local ents, pmap = checked({ {g.units[1], g}, {g.units[2], g} })
    local plan = ops.compute_plan('unit', ents, pmap, 'unit_name', 'set_all', { value = 'Hornet' })
    check('first rename row ok',  plan.rows[1].ok == true)
    check('second rename row ✗ collision',
          plan.rows[2].ok == false
          and plan.rows[2].error and plan.rows[2].error:find('collision') ~= nil)
end

-- Case 4: auto_number ordering by current name asc.
do
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'Charlie' })
    local g2 = mock.add_plane({ name = 'Alpha' })
    local g3 = mock.add_plane({ name = 'Bravo' })
    local ents, pmap = checked({ {g1, g1}, {g2, g2}, {g3, g3} })
    local plan = ops.compute_plan('group', ents, pmap, 'group_name', 'auto_number',
        { pattern = 'X-{n}', start = 1, step = 1, pad = 2, order = 'name_asc' })
    -- rows should be in name-asc order: Alpha, Bravo, Charlie → X-01, X-02, X-03
    check('auto_number sorts by name',
          plan.rows[1].old == 'Alpha'  and plan.rows[1].new == 'X-01' and
          plan.rows[2].old == 'Bravo'  and plan.rows[2].new == 'X-02' and
          plan.rows[3].old == 'Charlie' and plan.rows[3].new == 'X-03')
end

-- Case 5: offset on numeric (waypoint_alt).
do
    mock.new_mission()
    local g = mock.add_plane({ name = 'P' })
    g.route.points = {
        { alt = 1000, name = 'a' }, { alt = 2000, name = 'b' }, { alt = 3000, name = 'c' },
    }
    local ents, pmap = checked({ {g.route.points[1], g}, {g.route.points[2], g}, {g.route.points[3], g} })
    local plan = ops.compute_plan('waypoint', ents, pmap, 'waypoint_alt', 'offset', { delta = 500 })
    check('offset row 1', plan.rows[1].new == 1500)
    check('offset row 2', plan.rows[2].new == 2500)
    check('offset row 3', plan.rows[3].new == 3500)
end

-- Case 6: unknown property id returns ok=false plan.
do
    local plan = ops.compute_plan('group', {}, {}, 'nonexistent_property', 'set_all', {})
    check('unknown property: plan.error set', plan.error ~= nil)
end

-- ---------------------------------------------------------------------------
-- apply_plan
-- ---------------------------------------------------------------------------

local undo = require('dcs_sms_me.undo')

-- Helper rebuilt: checked() / pmap.
local function checked(pairs_list)
    local entities, parent_map = {}, {}
    for _, p in ipairs(pairs_list) do
        entities[#entities + 1] = p[1]
        parent_map[p[1]] = p[2]
    end
    return entities, parent_map
end

-- Case A1: apply unit_skill to 3 units; values land on the entities.
do
    undo.clear()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    g.units = {
        { unitId = 1, name = 'A-1', type = 'F/A-18C', skill = 'Average' },
        { unitId = 2, name = 'A-2', type = 'F/A-18C', skill = 'High' },
        { unitId = 3, name = 'A-3', type = 'F/A-18C', skill = 'Good' },
    }
    local ents, pmap = checked({ {g.units[1], g}, {g.units[2], g}, {g.units[3], g} })
    local plan = ops.compute_plan('unit', ents, pmap, 'unit_skill', 'set_all', { value = 'Excellent' })
    local result = ops.apply_plan(plan)
    check('apply: changed=3', result.changed == 3, 'got ' .. tostring(result.changed))
    check('apply: failed=0', result.failed == 0)
    check('apply: unit 1 skill mutated', g.units[1].skill == 'Excellent')
    check('apply: unit 2 skill mutated', g.units[2].skill == 'Excellent')
    check('apply: unit 3 skill mutated', g.units[3].skill == 'Excellent')
    check('apply: undo slot recorded', undo.has_record() == true)
end

-- Case A2: undo restores the previous values.
do
    local ok = undo.undo()
    check('undo: ok=true', ok == true)
    local restored = {}
    for _, side in pairs(mock.mission.coalition) do
        for _, country in ipairs(side.country) do
            for _, cat in ipairs({ 'plane','helicopter','vehicle','ship','static' }) do
                for _, gg in ipairs(country[cat] and country[cat].group or {}) do
                    for _, u in ipairs(gg.units or {}) do
                        restored[u.name] = u.skill
                    end
                end
            end
        end
    end
    check('undo: A-1 restored to Average', restored['A-1'] == 'Average')
    check('undo: A-2 restored to High',    restored['A-2'] == 'High')
    check('undo: A-3 restored to Good',    restored['A-3'] == 'Good')
end

-- Case A3: writer exception flips row to ok=false during apply.
do
    undo.clear()
    mock.new_mission()
    local g = mock.add_plane({ name = 'B' })
    g.units = { { unitId = 1, name = 'B-1', type = 'F/A-18C', skill = 'Average' } }
    local ents, pmap = checked({ {g.units[1], g} })
    local plan = ops.compute_plan('unit', ents, pmap, 'unit_skill', 'set_all', { value = 'Excellent' })
    -- Sabotage the writer for this property.
    local entry = ops.find('unit_skill')
    local orig_writer = entry.writer
    entry.writer = function() error('simulated writer failure') end
    local result = ops.apply_plan(plan)
    entry.writer = orig_writer
    check('apply: throwing writer flips row to fail', result.failed == 1)
    check('apply: no successful row → no undo slot',  undo.has_record() == false)
end

-- Case A4: refresh_group_view is called once per affected group, not per row.
do
    undo.clear()
    mock.new_mission()
    mock.reset_refresh_counters()
    local g = mock.add_plane({ name = 'C' })
    g.units = {
        { unitId = 1, name = 'C-1', type = 'F/A-18C', skill = 'Average' },
        { unitId = 2, name = 'C-2', type = 'F/A-18C', skill = 'Average' },
        { unitId = 3, name = 'C-3', type = 'F/A-18C', skill = 'Average' },
    }
    local ents, pmap = checked({ {g.units[1], g}, {g.units[2], g}, {g.units[3], g} })
    local plan = ops.compute_plan('unit', ents, pmap, 'unit_skill', 'set_all', { value = 'Excellent' })
    ops.apply_plan(plan)
    check('refresh: update called exactly once for the group',
          mock.refresh_calls.update == 1,
          'got update=' .. tostring(mock.refresh_calls.update))
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All mass_edit_ops compute_plan tests passed.')
