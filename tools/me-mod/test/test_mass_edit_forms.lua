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
    check('group: 7 forms',          #list == 7, 'got ' .. tostring(#list))
    -- Order: rename → find/replace → add_prefix → add_suffix → auto_name_units → set_country → toggle_group_flags.
    check('group: form[1] = rename_group',
          list[1] and list[1].title == 'Rename groups')
    check('group: form[2] = find_replace_group_name',
          list[2] and list[2].title == 'Find & replace in group names')
    check('group: form[3] = add_prefix_group_name',
          list[3] and list[3].title == 'Add prefix to group names')
    check('group: form[4] = add_suffix_group_name',
          list[4] and list[4].title == 'Add suffix to group names')
    check('group: form[5] = auto_name_units_group',
          list[5] and list[5].title == 'Auto-name units')
    check('group: form[6] = set_country',
          list[6] and list[6].title == 'Set country')
    check('group: form[7] = toggle_group_flags',
          list[7] and list[7].title == 'Visibility & control')
    for i = 1, 7 do
        check('group: form[' .. i .. '].scope = group',
              list[i] and list[i].scope == 'group')
    end
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
