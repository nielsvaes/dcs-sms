-- Standalone test for prefab_naming pipeline.
-- Tests apply() + _compute_targets() pure functions.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end
package.preload['dcs_sms_me.verbs'] = function() return {} end
package.preload['me_mission'] = function() return require('mock_me_mission') end

local naming = require('dcs_sms_me.prefab_naming')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Case A1: apply() with no opts -> no-op result.
do
    local rec = { groups = {}, zones = {}, drawings = {}, errors = {} }
    local result = naming.apply(rec, nil)
    check('A1: result is table', type(result) == 'table')
    check('A1: renamed_groups = 0', result.renamed_groups == 0)
    check('A1: renamed_units = 0', result.renamed_units == 0)
    check('A1: failed = 0', result.failed == 0)
    check('A1: toast = nil', result.toast == nil)
    check('A1: sev = nil', result.sev == nil)
end

-- Case A2: apply() with empty string opts -> no-op result.
do
    local rec = { groups = {}, zones = {}, drawings = {}, errors = {} }
    local result = naming.apply(rec, { name = '', prefix = '', suffix = '' })
    check('A2: renamed_groups = 0', result.renamed_groups == 0)
    check('A2: toast = nil', result.toast == nil)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All prefab_naming tests passed.')
