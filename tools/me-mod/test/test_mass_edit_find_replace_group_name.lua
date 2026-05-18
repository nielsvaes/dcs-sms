-- Standalone test for mass_edit_forms.find_replace_group_name.
-- Tests the _apply pure function + the registered undo handler.

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

-- Stubs needed because undo.lua transitively requires prefab_ops which
-- requires selection / warehouse / lfs.
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end
package.preload['dcs_sms_me.verbs'] = function() return {} end

local form = require('dcs_sms_me.mass_edit_forms.find_replace_group_name')
local undo = require('dcs_sms_me.undo')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Case 1: empty selection → nothing_selected, no undo recorded.
do
    undo.clear()
    local result = form._apply({}, 'foo', 'bar')
    check('empty selection: changed=0',           result.changed == 0)
    check('empty selection: nothing_selected',    result.nothing_selected == true)
    check('empty selection: no undo recorded',    undo.has_record() == false)
end

-- Case 2: find substring not present in any name → no changes, no undo.
do
    undo.clear()
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'Alpha' })
    local g2 = mock.add_plane({ name = 'Bravo' })
    local result = form._apply({ g1, g2 }, 'XYZ', 'ZZZ')
    check('no match: changed=0', result.changed == 0)
    check('no match: failed=0',  result.failed == 0)
    check('no match: name unchanged g1', g1.name == 'Alpha')
    check('no match: name unchanged g2', g2.name == 'Bravo')
    check('no match: no undo recorded',  undo.has_record() == false)
end

-- Case 3: find substring matches 2 of 3 entities → 2 changed, 1 untouched, undo recorded.
do
    undo.clear()
    mock.new_mission()
    renames = {}
    local g1 = mock.add_plane({ name = 'CAP-Foo-1' })
    local g2 = mock.add_plane({ name = 'CAP-Foo-2' })
    local g3 = mock.add_plane({ name = 'Other' })
    local result = form._apply({ g1, g2, g3 }, 'Foo', 'Bar')
    check('match: changed=2',  result.changed == 2)
    check('match: failed=0',   result.failed == 0)
    check('match: g1 renamed', g1.name == 'CAP-Bar-1')
    check('match: g2 renamed', g2.name == 'CAP-Bar-2')
    check('match: g3 untouched', g3.name == 'Other')
    check('match: renameGroup called for both', #renames == 2)
    check('match: undo recorded', undo.has_record() == true)
end

-- Case 4: undo restores prior names (continues from case 3 state).
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
    table.sort(restored)
    -- restored should contain CAP-Foo-1, CAP-Foo-2, Other (in some order).
    check('undo: 3 group names', #restored == 3, 'got ' .. tostring(#restored))
    local set = {}
    for _, n in ipairs(restored) do set[n] = true end
    check('undo: CAP-Foo-1 restored', set['CAP-Foo-1'] == true)
    check('undo: CAP-Foo-2 restored', set['CAP-Foo-2'] == true)
    check('undo: Other still present', set['Other'] == true)
end

-- Case 5: writer rejection (Mission.renameGroup returns false) → row counted as failed.
do
    undo.clear()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    local orig_rename = mission_module.renameGroup
    mission_module.renameGroup = function() return false end
    local result = form._apply({ g }, 'A', 'B')
    mission_module.renameGroup = orig_rename
    check('writer reject: failed=1', result.failed == 1)
    check('writer reject: changed=0', result.changed == 0)
    check('writer reject: no undo recorded', undo.has_record() == false)
end

-- Case 6: writer throws → row counted as failed (pcall catches it).
do
    undo.clear()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    local orig_rename = mission_module.renameGroup
    mission_module.renameGroup = function() error('boom') end
    local result = form._apply({ g }, 'A', 'B')
    mission_module.renameGroup = orig_rename
    check('writer throws: failed=1', result.failed == 1)
    check('writer throws: changed=0', result.changed == 0)
end

-- Case 7: module exports the expected metadata.
do
    check('form.scope = group', form.scope == 'group')
    check('form.title is a string', type(form.title) == 'string' and #form.title > 0)
    check('form.new is a function', type(form.new) == 'function')
    check('form._apply is a function', type(form._apply) == 'function')
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All find_replace_group_name tests passed.')
