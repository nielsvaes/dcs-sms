-- test_prefab_ops_triggers.lua — place record exposes id maps + trigger row counts.
-- Run via: lua test_prefab_ops_triggers.lua  (cwd: tools/me-mod/test/)
--
-- Mock preamble mirrors test_prefab_ops_place.lua exactly.

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end

-- TriggerZoneController stub — addTriggerZone returns a synthetic runtime id.
local _next_zone_id = 1
package.preload['Mission.TriggerZoneController'] = function()
    return {
        addTriggerZone = function(name, x, y, radius, props, color, ztype, points)
            local id = _next_zone_id
            _next_zone_id = _next_zone_id + 1
            return id
        end,
    }
end

-- Wire mock_me_mission as me_mission so prefab_ops.place can use the
-- full inject_group / id-allocation API.
package.preload['me_mission'] = function() return require('mock_me_mission') end

package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

local mock = require('mock_me_mission')
local prefab_ops = require('dcs_sms_me.prefab_ops')

local passed, failed, errors = 0, 0, {}
local function check(cond, name)
    if cond then passed = passed + 1
    else failed = failed + 1; errors[#errors + 1] = name end
end

-- A) place() exposes gid_map/uid_map + zone name pairs on the record.
mock.new_mission()
local prefab = {
    meta = { name = 'p', sms_prefab_version = '0.4.0', world_anchor = { x = 0, y = 0 } },
    groups = { { name = 'Convoy', type = 'vehicle', country = 2, country_name = 'USA',
                 x = 0, y = 0,
                 units = { { name = 'Convoy-1', type = 'BTR-80', unitId = 34,
                             x = 0, y = 0, heading = 0 } },
                 route = { points = {} } } },
    statics = {}, drawings = {},
    zones = { { name = 'Ambush Zone', x = 10, y = 10, radius = 500 } },
}
-- Note: the prefab has groupId=12 on the template so the gid_map key must be 12.
-- mock_me_mission auto-assigns groupId in add_group; here we set it in the prefab
-- so Pass B sees g.groupId = 12 (the ORIGINAL template id).
prefab.groups[1].groupId = 12

local rec = prefab_ops.place(prefab, { anchor = { x = 1000, y = 1000 }, rotation = 0 })
check(rec ~= nil, 'place returns record')
check(type(rec.gid_map) == 'table' and rec.gid_map[12] ~= nil, 'rec.gid_map old→new')
check(type(rec.uid_map) == 'table' and rec.uid_map[34] ~= nil, 'rec.uid_map old→new')
check(rec.zones[1] and rec.zones[1].orig_name == 'Ambush Zone'
      and rec.zones[1].runtime_id ~= nil, 'zone record pairs orig_name → runtime_id')

-- A2) a group whose injection FAILS is pruned from the exposed maps —
-- a trigger rebound through a stale entry would point at a never-created
-- id. The 'Atlantis' country resolves nowhere in the mock.
mock.new_mission()
local prefab_bad = {
    meta = { name = 'pb', world_anchor = { x = 0, y = 0 } },
    groups = {
        { name = 'Good', type = 'vehicle', country = 2, country_name = 'USA', groupId = 50,
          x = 0, y = 0,
          units = { { name = 'Good-1', type = 'BTR-80', unitId = 60, x = 0, y = 0, heading = 0 } },
          route = { points = {} } },
        { name = 'Bad', type = 'vehicle', country = 999, country_name = 'Atlantis', groupId = 51,
          x = 0, y = 0,
          units = { { name = 'Bad-1', type = 'BTR-80', unitId = 61, x = 0, y = 0, heading = 0 } },
          route = { points = {} } },
    },
    statics = {}, drawings = {}, zones = {},
}
local rec2 = prefab_ops.place(prefab_bad, { anchor = { x = 0, y = 0 }, rotation = 0 })
check(rec2 ~= nil and #rec2.errors >= 1, 'partial place returns record with errors')
check(rec2.gid_map[50] ~= nil and rec2.uid_map[60] ~= nil, 'successful group keeps map entries')
check(rec2.gid_map[51] == nil and rec2.uid_map[61] == nil,
      'failed group pruned from gid/uid maps')

-- B) row_from_prefab counts triggers (exposed for scan rows).
local row = prefab_ops._row_from_prefab('x', 'c:/x.prefab', {
    meta = { name = 'x' }, groups = {}, zones = {}, drawings = {},
    triggers = { { name = 'a' }, { name = 'b' } },
})
check(row.trigger_count == 2, 'row trigger_count')
local row0 = prefab_ops._row_from_prefab('y', 'c:/y.prefab',
    { meta = { name = 'y' }, groups = {} })
check(row0.trigger_count == 0, 'row trigger_count default 0')

print(string.format('test_prefab_ops_triggers: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL ' .. e) end
os.exit(failed == 0 and 0 or 1)
