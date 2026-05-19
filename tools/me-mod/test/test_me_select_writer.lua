-- Standalone test for me_select_writer.
-- Stubs me_multiSelection so we don't depend on the real DCS module.
-- Run via: lua test_me_select_writer.lua  (cwd: tools/me-mod/test/)

-- Track whether the ME write function was called.
local mms_called = false
local mms_last_input = nil
local stub_mms = {
    setSelectingObjectsOutside = function(a_objects)
        mms_called = true
        mms_last_input = a_objects
    end,
}
package.preload['me_multiSelection'] = function() return stub_mms end

-- log stub (some transitive requires touch it)
package.preload['log'] = function()
    return { write = function() end, INFO = 1, WARNING = 2, ERROR = 3 }
end

package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

local writer = require('dcs_sms_me.me_select_writer')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Case: empty input -> ok=true, count=0, writer not called
do
    mms_called = false
    mms_last_input = nil
    local result = writer.set_group_selection({})
    check('empty: ok=true',                       result.ok == true)
    check('empty: count=0',                       result.count == 0)
    check('empty: error is nil',                  result.error == nil)
    check('empty: setSelectingObjectsOutside NOT called',
          mms_called == false,
          'must not clear the map on empty input')
end

-- Case: 3 groups with distinct groupIds -> setSelectingObjectsOutside
-- called once with the right shape; result counts them.
do
    mms_called = false
    mms_last_input = nil
    local g1 = { groupId = 101, name = 'Alpha' }
    local g2 = { groupId = 202, name = 'Bravo' }
    local g3 = { groupId = 303, name = 'Charlie' }
    local result = writer.set_group_selection({ g1, g2, g3 })
    check('happy: ok=true',                       result.ok == true)
    check('happy: count=3',                       result.count == 3)
    check('happy: error is nil',                  result.error == nil)
    check('happy: setSelectingObjectsOutside called', mms_called == true)
    check('happy: groups_copied has g1 by id',    mms_last_input and mms_last_input.groups_copied
                                                     and mms_last_input.groups_copied[101] == g1)
    check('happy: groups_copied has g2 by id',    mms_last_input and mms_last_input.groups_copied
                                                     and mms_last_input.groups_copied[202] == g2)
    check('happy: groups_copied has g3 by id',    mms_last_input and mms_last_input.groups_copied
                                                     and mms_last_input.groups_copied[303] == g3)
    check('happy: triggerZones_copied present (empty)',
          type(mms_last_input.triggerZones_copied) == 'table' and next(mms_last_input.triggerZones_copied) == nil)
    check('happy: draw_copied present (empty)',
          type(mms_last_input.draw_copied) == 'table' and next(mms_last_input.draw_copied) == nil)
end

-- Case: group without groupId is silently dropped from the keyed map but
-- still counted toward the input length (we use the keyed-count for
-- result.count so the toast doesn't lie). count returned equals the
-- number actually keyed.
do
    mms_called = false
    mms_last_input = nil
    local g1 = { groupId = 101, name = 'Alpha' }
    local g_bad = { name = 'NoId' }  -- missing groupId
    local result = writer.set_group_selection({ g1, g_bad })
    check('drop: ok=true',                        result.ok == true)
    check('drop: count=1 (only g1 keyed)',        result.count == 1)
    check('drop: groups_copied has only one entry',
          (function()
              local n = 0; for _ in pairs(mms_last_input.groups_copied) do n = n + 1 end; return n
          end)() == 1)
end

-- Case: setSelectingObjectsOutside throws -> ok=false, error captured.
do
    -- Temporarily swap the stub to one that throws.
    local saved = stub_mms.setSelectingObjectsOutside
    stub_mms.setSelectingObjectsOutside = function(a_objects)
        error('simulated DCS internal failure')
    end

    local g1 = { groupId = 101 }
    local result = writer.set_group_selection({ g1 })

    -- Restore for any tests that come after.
    stub_mms.setSelectingObjectsOutside = saved

    check('err: ok=false',                        result.ok == false)
    check('err: error contains simulated message',
          type(result.error) == 'string' and result.error:find('simulated DCS internal failure', 1, true) ~= nil,
          'got: ' .. tostring(result.error))
    check('err: count=0',                         result.count == 0)
end

-- Case: me_multiSelection module is unavailable -> ok=false with a
-- descriptive error. We can't truly remove the preloaded stub from a
-- live require cache, but we can swap setSelectingObjectsOutside to nil
-- to simulate the API-missing condition the impl checks.
do
    local saved = stub_mms.setSelectingObjectsOutside
    stub_mms.setSelectingObjectsOutside = nil

    local g1 = { groupId = 101 }
    local result = writer.set_group_selection({ g1 })

    stub_mms.setSelectingObjectsOutside = saved

    check('missing-api: ok=false',                result.ok == false)
    check('missing-api: error mentions setSelectingObjectsOutside',
          type(result.error) == 'string' and result.error:find('setSelectingObjectsOutside', 1, true) ~= nil,
          'got: ' .. tostring(result.error))
end

if failures > 0 then
    print(string.format('%d failure(s)', failures))
    os.exit(1)
end
print('All me_select_writer tests passed.')
