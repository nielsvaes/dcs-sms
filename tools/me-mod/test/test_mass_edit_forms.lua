-- Standalone test for mass_edit_forms (the scope→forms loader).

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
package.preload['me_mission']            = function() return require('mock_me_mission') end
package.preload['dcs_sms_me.selection']  = function() return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end } end
package.preload['dcs_sms_me.verbs']      = function() return {} end

local forms = require('dcs_sms_me.mass_edit_forms')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

check('forms_for is a function', type(forms.forms_for) == 'function')

do
    local list = forms.forms_for('group')
    check('group: 2 forms',          #list == 2, 'got ' .. tostring(#list))
    -- Order matters: rename on top of find/replace in the stacked right pane.
    check('group: form[1] = rename_group', list[1] and list[1].title == 'Rename groups')
    check('group: form[2] = find_replace_group_name',
          list[2] and list[2].title == 'Find & replace in group names')
    check('group: form[1].scope = group',  list[1] and list[1].scope == 'group')
    check('group: form[2].scope = group',  list[2] and list[2].scope == 'group')
end

for _, scope in ipairs({ 'unit', 'waypoint', 'zone', 'drawing' }) do
    local list = forms.forms_for(scope)
    check(scope .. ': empty list', type(list) == 'table' and #list == 0)
end

do
    local list = forms.forms_for('nope')
    check('unknown scope: empty list', type(list) == 'table' and #list == 0)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All mass_edit_forms tests passed.')
