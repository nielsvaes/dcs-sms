-- Standalone test for selection.snapshot_drilled. Stubs M.snapshot to feed
-- a marquee, and uses mock_me_mission for the mission-wide fallback path.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Stub lfs (selection.lua doesn't use it, but its requires might).
package.preload['lfs'] = function()
    return { writedir = function() return '' end }
end

-- Bring in the mock mission for the mission-wide fallback path.
local mock = require('mock_me_mission')
package.preload['me_mission'] = function() return mock end

-- Stub the ME-internal modules selection.lua requires defensively. We
-- never exercise the actual ME selection paths in this test — instead we
-- replace M.snapshot with our own fixture between cases.
package.preload['me_multiSelection']            = function() return { isVisible = function() return false end } end
package.preload['me_map_window']                = function() return {} end
package.preload['Mission.MapController']        = function() return {} end
package.preload['Mission.Data']                 = function() return {} end
package.preload['Mission.TriggerZoneController'] = function() return {} end
package.preload['Mission.NavigationPointController'] = function() return {} end
package.preload['me_draw_panel']                = function() return {} end

local selection = require('dcs_sms_me.selection')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Helper: patch selection.snapshot to return a fixed marquee.
local function with_snapshot(value, fn)
    local original = selection.snapshot
    selection.snapshot = function() return value end
    local ok, err = pcall(fn)
    selection.snapshot = original
    if not ok then error(err) end
end

-- Case 1: scope='group' from marquee returns the marqueed groups.
do
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'A' })
    local g2 = mock.add_vehicle({ name = 'V' })
    with_snapshot({ ok = true, groups = { g1, g2 }, zones = {}, drawings = {} }, function()
        local snap = selection.snapshot_drilled('group')
        check('group scope ok',          snap.ok == true)
        check('group scope source=marquee', snap.source == 'marquee')
        check('group scope pool=2',      #snap.pool == 2)
        check('group scope parent_map identity',
              snap.parent_map[g1] == g1 and snap.parent_map[g2] == g2)
        check('group scope categories.plane',   snap.categories[g1] == 'plane')
        check('group scope categories.vehicle', snap.categories[g2] == 'vehicle')
    end)
end

-- Case 2: scope='unit' drills into units across the marqueed groups.
do
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'A',
        units = { { unitId = 11, name = 'A-1', type = 'F/A-18C' }, { unitId = 12, name = 'A-2', type = 'F/A-18C' } }})
    local g2 = mock.add_plane({ name = 'B',
        units = { { unitId = 21, name = 'B-1', type = 'F/A-18C' } }})
    with_snapshot({ ok = true, groups = { g1, g2 }, zones = {}, drawings = {} }, function()
        local snap = selection.snapshot_drilled('unit')
        check('unit scope pool=3',     #snap.pool == 3)
        check('unit parent g1 -> g1',  snap.parent_map[g1.units[1]] == g1)
        check('unit parent g1.u2 -> g1', snap.parent_map[g1.units[2]] == g1)
        check('unit parent g2.u1 -> g2', snap.parent_map[g2.units[1]] == g2)
        check('unit categories inherit from group',
              snap.categories[g1.units[1]] == 'plane'
              and snap.categories[g2.units[1]] == 'plane')
    end)
end

-- Case 3: scope='waypoint' drills into route.points across the marqueed groups.
do
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'A' })
    -- add_plane creates a 1-WP route; splice a 2nd WP in to test multi-WP drill.
    mock.insert_waypoint(g1, 2, 'Turning Point', 100, 200, 5000, 250, 'WP2', '')
    with_snapshot({ ok = true, groups = { g1 }, zones = {}, drawings = {} }, function()
        local snap = selection.snapshot_drilled('waypoint')
        check('waypoint scope pool=2', #snap.pool == 2)
        check('waypoint parent_map maps both WPs to g1',
              snap.parent_map[g1.route.points[1]] == g1
              and snap.parent_map[g1.route.points[2]] == g1)
    end)
end

-- Case 4: empty marquee falls back to mission-wide pool.
do
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'A' })
    local g2 = mock.add_vehicle({ name = 'V' })
    with_snapshot({ ok = true, groups = {}, zones = {}, drawings = {} }, function()
        local snap = selection.snapshot_drilled('group')
        check('empty marquee → source=mission', snap.source == 'mission')
        check('empty marquee → pool from mission', #snap.pool >= 2)
    end)
end

-- Case 5: scope='zone' passes through zones from snapshot.
do
    local z1 = { name = 'Z1' }
    local z2 = { name = 'Z2' }
    with_snapshot({ ok = true, groups = {}, zones = { z1, z2 }, drawings = {} }, function()
        local snap = selection.snapshot_drilled('zone')
        check('zone scope pool=2',         #snap.pool == 2)
    end)
end

-- Case 6: scope='drawing' passes through drawings from snapshot.
do
    local d1 = { name = 'D1' }
    with_snapshot({ ok = true, groups = {}, zones = {}, drawings = { d1 } }, function()
        local snap = selection.snapshot_drilled('drawing')
        check('drawing scope pool=1', #snap.pool == 1)
        check('drawing scope first item is d1', snap.pool[1] == d1)
    end)
end

-- Case 7: unknown scope is rejected with ok=false.
do
    with_snapshot({ ok = true, groups = {}, zones = {}, drawings = {} }, function()
        local snap = selection.snapshot_drilled('garbage')
        check('unknown scope returns ok=false', snap.ok == false)
    end)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All selection_drilled tests passed.')
