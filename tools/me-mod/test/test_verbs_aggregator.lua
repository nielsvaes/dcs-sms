-- test_verbs_aggregator.lua — smoke-check that dcs_sms_me.verbs exposes one
-- canonical verb from each noun module. Catches a misconfigured
-- noun_modules list in verbs.lua before the bridge fails at dispatch.
--
-- Doesn't exercise the verbs themselves (test_verbs_route.lua handles the
-- end-to-end path against the route/waypoint verbs); this test only checks
-- the aggregator surface.

local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path

-- Mock me_mission / me_map_window so noun files that touch them at require
-- time (none do today, but defensive) can load. The aggregator and its
-- noun files defer me_* / Mission.* requires into function bodies, so this
-- mock isn't strictly needed — kept for parity with test_verbs_route.lua.
local mock = require('mock_me_mission')
package.preload['me_mission']    = function() return mock end
package.preload['me_map_window'] = function() return mock end

package.path = here .. '../lua/?.lua;' .. here .. '../lua/?/init.lua;' .. package.path

local verbs = require('dcs_sms_me.verbs')

local passed, failed, errors = 0, 0, {}

local function assert_fn(verb_name, expected_noun)
    if type(verbs[verb_name]) == 'function' then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(errors, string.format(
            'verbs.%s missing or not callable (expected from %s_verbs.lua) — '
                .. 'noun_modules list in verbs.lua likely out of sync',
            verb_name, expected_noun))
    end
end

-- One canonical verb from each of the 11 noun modules. Order matches the
-- noun_modules list in verbs.lua for grep-ability.
assert_fn('airbase_list',       'airbase')
assert_fn('camera_get',         'camera')
assert_fn('coords_to_geo',      'coords')
assert_fn('drawing_list',       'drawing')
assert_fn('file_open',          'file')
assert_fn('group_list',         'group')
assert_fn('resources_get',      'resources')
assert_fn('route_list',         'route')
assert_fn('trigger_list',       'trigger')
assert_fn('unit_list',          'unit')
assert_fn('zone_list',          'zone')

-- Cross-file placement check: unit_set_parking is defined inside
-- route_verbs.lua (it depends on route-block locals), but the public
-- surface must still expose it as a unit verb. Catches an accidental
-- move that breaks `me unit set-parking`.
assert_fn('unit_set_parking',   'route (cross-file)')

io.write(string.format('test_verbs_aggregator: %d passed, %d failed\n', passed, failed))
if failed > 0 then
    for _, msg in ipairs(errors) do io.write('  FAIL ' .. msg .. '\n') end
    os.exit(1)
end
