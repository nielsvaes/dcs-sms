-- Standalone test for mass_edit_ops. Uses mock_me_mission for entities;
-- compute_plan is the focus here, apply_plan is exercised in the next task.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function() return {} end
local mock = require('mock_me_mission')
package.preload['me_mission']      = function() return mock end
package.preload['me_loadoututils'] = function() return { getUnitPylons = function() return {} end } end
-- mass_edit_ops doesn't require dcs_sms_me.verbs unless writer needs it
-- (country/loadout only). compute_plan never invokes writers.
package.preload['dcs_sms_me.verbs'] = function() return {} end

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

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All mass_edit_ops compute_plan tests passed.')
