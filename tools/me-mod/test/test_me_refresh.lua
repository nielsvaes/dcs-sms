-- Standalone test for me_refresh.lua. Stubs me_mission's
-- create_group_map_objects / update_group_map_objects and asserts the
-- helper calls them in the right combinations.
-- Run via: lua test_me_refresh.lua  (cwd: tools/me-mod/test/)

package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

local create_calls, update_calls = 0, 0
local last_create_force = nil
package.preload['me_mission'] = function()
    return {
        create_group_map_objects = function(g, force)
            create_calls = create_calls + 1
            last_create_force = force
        end,
        update_group_map_objects = function(g) update_calls = update_calls + 1 end,
    }
end

local me_refresh = require('dcs_sms_me.me_refresh')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Case 1: mapObjects = nil → both create and update fire.
do
    create_calls, update_calls = 0, 0
    me_refresh.refresh_group_view({ mapObjects = nil })
    check('mapObjects=nil triggers create', create_calls == 1)
    check('mapObjects=nil triggers update', update_calls == 1)
end

-- Case 2: mapObjects present → only update fires.
do
    create_calls, update_calls = 0, 0
    me_refresh.refresh_group_view({ mapObjects = {} })
    check('mapObjects=present skips create', create_calls == 0)
    check('mapObjects=present triggers update', update_calls == 1)
end

-- Case 3: me_mission missing the create/update functions → no throw.
do
    package.loaded['me_mission'] = { }  -- nothing exported
    local ok = pcall(me_refresh.refresh_group_view, { mapObjects = nil })
    check('refresh tolerates missing me_mission helpers', ok == true)
end

-- Case 4: recreate_group_view forces a full re-render (create with force=true).
do
    package.loaded['me_mission'] = {
        create_group_map_objects = function(g, force)
            create_calls = create_calls + 1
            last_create_force = force
        end,
        update_group_map_objects = function(g) update_calls = update_calls + 1 end,
    }
    create_calls, update_calls, last_create_force = 0, 0, nil
    me_refresh.recreate_group_view({ mapObjects = {} })
    check('recreate calls create unconditionally', create_calls == 1)
    check('recreate passes force=true',           last_create_force == true)
    check('recreate also calls update',           update_calls == 1)
end

-- Case 5: recreate tolerates a me_mission missing create_group_map_objects.
do
    package.loaded['me_mission'] = { }
    local ok = pcall(me_refresh.recreate_group_view, { mapObjects = nil })
    check('recreate tolerates missing me_mission helpers', ok == true)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All me_refresh tests passed.')
