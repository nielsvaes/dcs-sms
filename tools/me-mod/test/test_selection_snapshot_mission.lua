-- Standalone test for selection.snapshot_mission. Mocks me_mission via
-- mock_me_mission and asserts the function returns the full pool
-- regardless of any marquee state.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')
package.preload['me_mission'] = function() return mock end

-- Stub me_multiSelection so selection.snapshot doesn't blow up if it gets
-- called transitively. snapshot_mission should NOT call this — that's the
-- whole point — but we stub it anyway to make the failure mode visible.
local marquee_called = false
package.preload['me_multiSelection'] = function()
    return {
        isVisible = function() marquee_called = true; return true end,
        getSelectedObjects = function() marquee_called = true; return { selectGroups = {} } end,
    }
end

local selection = require('dcs_sms_me.selection')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Case 1: snapshot_mission('group') returns every group in the mission.
do
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'Alpha' })
    local g2 = mock.add_helicopter({ name = 'Bravo' })
    local g3 = mock.add_vehicle({ name = 'Charlie' })

    local out = selection.snapshot_mission('group')
    check('ok=true', out.ok == true)
    check('scope=group', out.scope == 'group')
    check('source=mission', out.source == 'mission')
    check('pool has 3 groups', #out.pool == 3, 'got #pool=' .. tostring(#out.pool))

    -- parent_map[g] = g for group scope (entity is the group).
    check('parent_map identity for g1', out.parent_map[g1] == g1)
    check('parent_map identity for g2', out.parent_map[g2] == g2)
    check('parent_map identity for g3', out.parent_map[g3] == g3)

    -- categories propagated from the mission tree.
    check('category for g1 = plane',      out.categories[g1] == 'plane')
    check('category for g2 = helicopter', out.categories[g2] == 'helicopter')
    check('category for g3 = vehicle',    out.categories[g3] == 'vehicle')

    -- snapshot_mission must NOT have consulted the marquee at all.
    check('marquee not consulted', marquee_called == false)
end

-- Case 2: snapshot_mission('unit') returns every unit, parented to its group.
do
    mock.new_mission()
    marquee_called = false
    local g = mock.add_plane({ name = 'Group1' })
    g.units = {
        { unitId = 1, name = 'U-1', type = 'F/A-18C' },
        { unitId = 2, name = 'U-2', type = 'F/A-18C' },
    }

    local out = selection.snapshot_mission('unit')
    check('unit pool has 2 entries', #out.pool == 2)
    check('unit 1 parent = g',      out.parent_map[g.units[1]] == g)
    check('unit 1 category = plane', out.categories[g.units[1]] == 'plane')
    check('marquee not consulted (unit)', marquee_called == false)
end

-- Case 3: snapshot_mission('zone') walks mission.triggers.zones.
do
    mock.new_mission()
    marquee_called = false
    mock.mission.triggers = { zones = { { name = 'Z1', radius = 1000 }, { name = 'Z2', radius = 500 } } }

    local out = selection.snapshot_mission('zone')
    check('zone pool has 2 entries', #out.pool == 2)
    check('marquee not consulted (zone)', marquee_called == false)
end

-- Case 4: unknown scope returns ok=false.
do
    local out = selection.snapshot_mission('nope')
    check('unknown scope: ok=false', out.ok == false)
    check('unknown scope: error set', out.error ~= nil)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All selection.snapshot_mission tests passed.')
