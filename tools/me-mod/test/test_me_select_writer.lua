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

if failures > 0 then
    print(string.format('%d failure(s)', failures))
    os.exit(1)
end
print('All me_select_writer tests passed.')
