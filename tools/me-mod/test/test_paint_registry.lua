-- Regression test for the Paint Statics erase/undo stale-group guard.
--
-- Bug: painting statics, flying + exiting a mission (or File>New/Open), then
-- erasing (or undoing the paint) HARD-CRASHED DCS. The ME rebuilds every
-- mission table on reload, orphaning the group references the tool stored at
-- paint time; batch_remove_groups then called the C++ remove_group_map_objects
-- on a stale group whose map objects were freed → native fault pcall can't
-- catch. The fix: group_is_live() detects staleness in pure Lua (the running
-- mission must still index THIS exact table by name) and the removal path skips
-- stale groups entirely. This test covers that predicate.
--
-- paint_statics is heavily dxgui-coupled; the dxgui modules are pcall-guarded
-- so they degrade to nil, and we stub the bare-required dcs_sms_me siblings so
-- the module loads headless. We then exercise M._group_is_live directly.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Stub the bare-required sibling modules (paint_statics only stores references
-- at load; the functions are exercised in the live ME, not here). A catch-all
-- metatable answers any field with a no-op function.
local function stub_table()
    return setmetatable({}, { __index = function() return function() end end })
end
for _, name in ipairs({ 'sms_window', 'sms_slider', 'paint_scatter',
                        'static_catalog', 'verb_helpers', 'prefab_ops' }) do
    package.preload['dcs_sms_me.' .. name] = function() return stub_table() end
end
package.preload['dcs_sms_me.version'] = function() return '0.0.0-test' end
package.preload['dcs_sms_me.undo'] = function()
    return { register_handler = function() end, record_generic = function() end }
end
-- log.* used by log_write (not called at load, but keep it safe).
_G.log = setmetatable({ INFO = 1, WARNING = 2, ERROR = 3 }, { __index = function() return 0 end })

local ps = require('dcs_sms_me.paint_statics')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

check('M._group_is_live is exported', type(ps._group_is_live) == 'function')

local live = ps._group_is_live

-- A live group: the running mission indexes THIS exact table by its name.
do
    local g = { name = 'Barrel-01', groupId = 7 }
    local Mission = { group_by_name = { ['Barrel-01'] = g } }
    check('live group (same table indexed by name)', live(Mission, g) == true)
end

-- Stale after reload: a DIFFERENT table now owns the name (the reloaded static).
do
    local g       = { name = 'Barrel-01', groupId = 7 }
    local reloaded = { name = 'Barrel-01', groupId = 99 }
    local Mission = { group_by_name = { ['Barrel-01'] = reloaded } }
    check('stale group (name now owned by a different table)', live(Mission, g) == false)
end

-- Stale after reload: the name is simply gone from the rebuilt mission.
do
    local g = { name = 'Barrel-01', groupId = 7 }
    local Mission = { group_by_name = {} }
    check('stale group (name absent after reload)', live(Mission, g) == false)
end

-- Defensive: no group_by_name table at all.
do
    local g = { name = 'Barrel-01' }
    check('no group_by_name table → not live', live({}, g) == false)
end

-- Defensive: nil group / nil Mission never throw and are not live.
do
    check('nil group → not live', live({ group_by_name = {} }, nil) == false)
    check('nil Mission → not live', live(nil, { name = 'x' }) == false)
end

print('')
if failures == 0 then
    print('All paint_registry tests passed.')
    os.exit(0)
else
    print(failures .. ' paint_registry tests FAILED.')
    os.exit(1)
end
