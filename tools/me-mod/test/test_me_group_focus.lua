-- Standalone test for me_group_focus.lua.
-- Stubs me_map_window + me_mission so focus() exercises the happy path,
-- the auto-build-mapObjects path, and the various error / degrade-
-- gracefully paths.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Captures for assertions. Reset by each test's setup() block.
local mw_calls         -- ordered list of MapWindow API calls
local mission_calls    -- create_group_map_objects invocations
local map_window_stub  -- table that becomes _G.MapWindow / me_map_window's return

local function reset()
    mw_calls = {}
    mission_calls = {}
    map_window_stub = {
        selectedGroup    = nil,
        unselectAll      = function() mw_calls[#mw_calls + 1] = { fn = 'unselectAll' } end,
        setSelectedUnit  = function(u) mw_calls[#mw_calls + 1] = { fn = 'setSelectedUnit', unit = u } end,
        respondToSelectedUnit = function(mo, g, u)
            mw_calls[#mw_calls + 1] = { fn = 'respondToSelectedUnit', mapObject = mo, group = g, unit = u }
        end,
    }
    -- Replace the loaded modules so each test starts clean.
    package.loaded['me_map_window'] = map_window_stub
    package.loaded['me_mission'] = {
        create_group_map_objects = function(g)
            mission_calls[#mission_calls + 1] = g
            -- Mimic the ME side effect: populate mapObjects when called.
            g.mapObjects = g.mapObjects or { units = { { id = 'mo-' .. tostring(g.groupId) } } }
        end,
    }
end

-- Replace the loader for me_map_window before the SUT loads, so its
-- pcall(require, 'me_map_window') hits the table we control.
package.preload['me_map_window'] = function() return map_window_stub end
package.preload['me_mission']    = function() return package.loaded['me_mission'] end

reset()

local focus_mod = require('dcs_sms_me.me_group_focus')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function find_call(fn_name)
    for _, c in ipairs(mw_calls) do if c.fn == fn_name then return c end end
    return nil
end

-- ---------------------------------------------------------------------------
-- Happy path: group already has mapObjects + units; focus mounts the panel.
-- ---------------------------------------------------------------------------
do
    reset()
    local unit1  = { name = 'A1' }
    local group  = {
        groupId    = 7,
        units      = { unit1, { name = 'A2' } },
        mapObjects = { units = { 'mo-7-a', 'mo-7-b' } },
    }
    local r = focus_mod.focus(group)
    check('happy: ok',                            r.ok == true)
    check('happy: no create_group_map_objects',   #mission_calls == 0)
    check('happy: unselectAll fired',             find_call('unselectAll') ~= nil)
    check('happy: selectedGroup set',             map_window_stub.selectedGroup == group)
    check('happy: setSelectedUnit fired with units[1]',
          (find_call('setSelectedUnit') or {}).unit == unit1)
    local resp = find_call('respondToSelectedUnit')
    check('happy: respondToSelectedUnit fired',   resp ~= nil)
    check('happy: mapObject = group.mapObjects.units[1]',
          resp and resp.mapObject == 'mo-7-a')
    check('happy: respondToSelectedUnit group',   resp and resp.group == group)
    check('happy: respondToSelectedUnit unit',    resp and resp.unit == unit1)
end

-- ---------------------------------------------------------------------------
-- opt_unit override: panel highlights the passed unit, not units[1].
-- ---------------------------------------------------------------------------
do
    reset()
    local u1, u2 = { name = 'A1' }, { name = 'A2' }
    local group  = {
        groupId    = 11,
        units      = { u1, u2 },
        mapObjects = { units = { 'mo-11' } },
    }
    local r = focus_mod.focus(group, u2)
    check('opt_unit: ok',                          r.ok == true)
    check('opt_unit: setSelectedUnit = u2',        (find_call('setSelectedUnit') or {}).unit == u2)
    check('opt_unit: respondToSelectedUnit.unit = u2',
          (find_call('respondToSelectedUnit') or {}).unit == u2)
end

-- ---------------------------------------------------------------------------
-- opt_unit not a table → fallback to units[1].
-- ---------------------------------------------------------------------------
do
    reset()
    local u1 = { name = 'A1' }
    local group = { groupId = 12, units = { u1 }, mapObjects = { units = { 'mo' } } }
    focus_mod.focus(group, 'not a table')
    check('opt_unit non-table → fallback units[1]',
          (find_call('setSelectedUnit') or {}).unit == u1)
end

-- ---------------------------------------------------------------------------
-- Disk-loaded group (mapObjects == nil): create_group_map_objects fires
-- first, then the rest of the focus path runs.
-- ---------------------------------------------------------------------------
do
    reset()
    local u1 = { name = 'A' }
    local group = { groupId = 22, units = { u1 } }  -- no mapObjects
    local r = focus_mod.focus(group)
    check('disk-loaded: create_group_map_objects called',
          #mission_calls == 1 and mission_calls[1] == group)
    check('disk-loaded: ok',                       r.ok == true)
    check('disk-loaded: respondToSelectedUnit fired',
          find_call('respondToSelectedUnit') ~= nil)
end

-- ---------------------------------------------------------------------------
-- create_group_map_objects fails to populate mapObjects → ok=false,
-- nothing further is called.
-- ---------------------------------------------------------------------------
do
    reset()
    package.loaded['me_mission'] = {
        create_group_map_objects = function(_g) mission_calls[#mission_calls + 1] = _g end,
        -- Note: the stub here does NOT populate g.mapObjects.
    }
    local group = { groupId = 23, units = { { name = 'A' } } }
    local r = focus_mod.focus(group)
    check('build-failed: ok=false',                r.ok == false)
    check('build-failed: error mentions mapObjects',
          r.error and r.error:find('mapObjects') ~= nil)
    check('build-failed: respondToSelectedUnit NOT called',
          find_call('respondToSelectedUnit') == nil)
end

-- ---------------------------------------------------------------------------
-- Group has no units → ok=false.
-- ---------------------------------------------------------------------------
do
    reset()
    local group = { groupId = 33, units = nil, mapObjects = { units = { 'mo' } } }
    local r = focus_mod.focus(group)
    check('no units: ok=false',                    r.ok == false)
    check('no units: error mentions units',        r.error and r.error:find('units') ~= nil)
    check('no units: respondToSelectedUnit NOT called',
          find_call('respondToSelectedUnit') == nil)
end

-- ---------------------------------------------------------------------------
-- Invalid arg (nil / non-table / missing groupId).
-- ---------------------------------------------------------------------------
do
    reset()
    check('nil group: ok=false',                   focus_mod.focus(nil).ok == false)
    check('string group: ok=false',                focus_mod.focus('x').ok == false)
    check('no groupId: ok=false',                  focus_mod.focus({}).ok == false)
end

-- ---------------------------------------------------------------------------
-- respondToSelectedUnit throws → error surfaces.
-- ---------------------------------------------------------------------------
do
    reset()
    map_window_stub.respondToSelectedUnit = function() error('boom from respond') end
    package.loaded['me_map_window'] = map_window_stub
    local group = { groupId = 44, units = { { name = 'A' } }, mapObjects = { units = { 'mo' } } }
    local r = focus_mod.focus(group)
    check('respond throws: ok=false',              r.ok == false)
    check('respond throws: error mentions boom',
          r.error and r.error:find('boom') ~= nil)
end

-- ---------------------------------------------------------------------------
-- me_map_window without respondToSelectedUnit → ok=false.
-- ---------------------------------------------------------------------------
do
    reset()
    package.loaded['me_map_window'] = { unselectAll = function() end }
    local group = { groupId = 55, units = { { name = 'A' } }, mapObjects = { units = { 'mo' } } }
    local r = focus_mod.focus(group)
    check('no respondToSelectedUnit: ok=false',    r.ok == false)
    check('no respondToSelectedUnit: error mentions respond',
          r.error and r.error:find('respond') ~= nil)
end

-- ---------------------------------------------------------------------------
-- MapWindow.unselectAll / setSelectedUnit missing → still proceeds.
-- The required call is respondToSelectedUnit; the others are best-effort.
-- ---------------------------------------------------------------------------
do
    reset()
    package.loaded['me_map_window'] = {
        respondToSelectedUnit = function(mo, g, u)
            mw_calls[#mw_calls + 1] = { fn = 'respondToSelectedUnit', mapObject = mo, group = g, unit = u }
        end,
    }
    local u1 = { name = 'A' }
    local group = { groupId = 66, units = { u1 }, mapObjects = { units = { 'mo-66' } } }
    local r = focus_mod.focus(group)
    check('only respondToSelectedUnit available: ok=true', r.ok == true)
    check('respondToSelectedUnit still fires',     find_call('respondToSelectedUnit') ~= nil)
end

print('')
if failures == 0 then
    print('All me_group_focus tests passed.')
    os.exit(0)
else
    print(failures .. ' me_group_focus tests FAILED.')
    os.exit(1)
end
