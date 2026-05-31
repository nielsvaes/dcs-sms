-- Standalone test for mass_edit_forms.add_prefix_group_name.
-- Tests M._apply pure function + registered undo handler.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')

-- me_mission with renameGroup → exercises the verbed write path.
local renames = {}
local mission_module = setmetatable({}, { __index = mock })
function mission_module.renameGroup(g, new_name)
    renames[#renames + 1] = { group = g, name = new_name }
    g.name = new_name
    return true
end
package.preload['me_mission'] = function() return mission_module end

-- Stubs needed because undo.lua transitively requires prefab_ops → selection / verbs.
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end
package.preload['dcs_sms_me.verbs'] = function() return {} end

local form = require('dcs_sms_me.mass_edit_forms.add_prefix_group_name')
local undo = require('dcs_sms_me.undo')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Case 1: empty selection → nothing_selected, no undo, with toast.
do
    undo.clear()
    local result = form._apply({}, 'X-')
    check('empty selection: changed=0',           result.changed == 0)
    check('empty selection: nothing_selected',    result.nothing_selected == true)
    check('empty selection: toast = Nothing selected', result.toast == 'Nothing selected')
    check('empty selection: sev = warning',       result.sev == 'warning')
    check('empty selection: no undo recorded',    undo.has_record() == false)
end

-- Case 2: empty text → no mutation, no undo, with toast.
do
    undo.clear()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    local result = form._apply({ g }, '')
    check('empty text: changed=0',  result.changed == 0)
    check('empty text: failed=0',   result.failed == 0)
    check('empty text: g unchanged', g.name == 'A')
    check('empty text: toast = Text is empty', result.toast == 'Text is empty')
    check('empty text: sev = warning', result.sev == 'warning')
    check('empty text: no undo recorded',  undo.has_record() == false)
end

-- Case 3: single happy. Foo + "X-" → "X-Foo".
do
    undo.clear()
    mock.new_mission()
    renames = {}
    local g = mock.add_plane({ name = 'Foo' })
    local result = form._apply({ g }, 'X-')
    check('single happy: changed=1', result.changed == 1)
    check('single happy: failed=0',  result.failed == 0)
    check('single happy: g.name = X-Foo', g.name == 'X-Foo')
    check('single happy: renameGroup called once', #renames == 1)
    check('single happy: toast = "1 prefixed"',
          result.toast == '1 prefixed', 'got ' .. tostring(result.toast))
    check('single happy: sev = success', result.sev == 'success')
    check('single happy: undo recorded', undo.has_record() == true)
end

-- Case 4: multi happy. 3 groups, prefix all.
do
    undo.clear()
    mock.new_mission()
    renames = {}
    local g1 = mock.add_plane({ name = 'Alpha' })
    local g2 = mock.add_plane({ name = 'Bravo' })
    local g3 = mock.add_plane({ name = 'Charlie' })
    local result = form._apply({ g1, g2, g3 }, 'TEST-')
    check('multi: changed=3', result.changed == 3)
    check('multi: g1 = TEST-Alpha',   g1.name == 'TEST-Alpha')
    check('multi: g2 = TEST-Bravo',   g2.name == 'TEST-Bravo')
    check('multi: g3 = TEST-Charlie', g3.name == 'TEST-Charlie')
    check('multi: toast = "3 prefixed"', result.toast == '3 prefixed')
    check('multi: sev = success', result.sev == 'success')
    check('multi: undo recorded', undo.has_record() == true)
end

-- Case 5: undo restores prior names (continues from Case 4 state).
do
    local ok = undo.undo()
    check('undo: ok=true', ok == true)
    local restored = {}
    for _, side in pairs(mock.mission.coalition) do
        for _, country in ipairs(side.country) do
            for _, cat in ipairs({ 'plane','helicopter','vehicle','ship','static' }) do
                for _, g in ipairs(country[cat] and country[cat].group or {}) do
                    restored[#restored + 1] = g.name
                end
            end
        end
    end
    local set = {}
    for _, n in ipairs(restored) do set[n] = true end
    check('undo: 3 group names', #restored == 3)
    check('undo: Alpha restored',   set['Alpha']   == true)
    check('undo: Bravo restored',   set['Bravo']   == true)
    check('undo: Charlie restored', set['Charlie'] == true)
end

-- Case 6: writer rejection → row counted as failed.
do
    undo.clear()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    local orig_rename = mission_module.renameGroup
    mission_module.renameGroup = function() return false end
    local result = form._apply({ g }, 'X-')
    mission_module.renameGroup = orig_rename
    check('writer reject: failed=1', result.failed == 1)
    check('writer reject: changed=0', result.changed == 0)
    check('writer reject: no undo recorded', undo.has_record() == false)
end

-- Case 7: writer throws → row counted as failed.
do
    undo.clear()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    local orig_rename = mission_module.renameGroup
    mission_module.renameGroup = function() error('boom') end
    local result = form._apply({ g }, 'X-')
    mission_module.renameGroup = orig_rename
    check('writer throws: failed=1', result.failed == 1)
    check('writer throws: changed=0', result.changed == 0)
end

-- Case 8: module exports the expected metadata.
do
    check('form.scope = group', form.scope == 'group')
    check('form.title = Add prefix to group names',
          form.title == 'Add prefix to group names')
    check('form.new is a function', type(form.new) == 'function')
    check('form._apply is a function', type(form._apply) == 'function')
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All add_prefix_group_name tests passed.')
