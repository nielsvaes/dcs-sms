-- Standalone test for mass_edit_forms.rename_group.
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

-- Stubs needed because undo.lua transitively requires prefab_ops → selection / warehouse.
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end
package.preload['dcs_sms_me.verbs'] = function() return {} end

local form = require('dcs_sms_me.mass_edit_forms.rename_group')
local undo = require('dcs_sms_me.undo')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Case 1: empty selection → nothing_selected, no undo, with toast.
do
    undo.clear()
    local result = form._apply({}, 'Foo-{n}')
    check('empty selection: changed=0',           result.changed == 0)
    check('empty selection: nothing_selected',    result.nothing_selected == true)
    check('empty selection: toast = Nothing selected', result.toast == 'Nothing selected')
    check('empty selection: sev = warning',       result.sev == 'warning')
    check('empty selection: no undo recorded',    undo.has_record() == false)
end

-- Case 2: empty pattern → no mutation, no undo, with toast.
do
    undo.clear()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    local result = form._apply({ g }, '')
    check('empty pattern: changed=0',  result.changed == 0)
    check('empty pattern: failed=0',   result.failed == 0)
    check('empty pattern: g unchanged', g.name == 'A')
    check('empty pattern: toast = Name is empty', result.toast == 'Name is empty')
    check('empty pattern: sev = warning', result.sev == 'warning')
    check('empty pattern: no undo recorded',  undo.has_record() == false)
end

-- Case 3: pattern with {n}, 3 groups, name_asc → numbered 01..03 in alphabetical order.
do
    undo.clear()
    mock.new_mission()
    renames = {}
    local g1 = mock.add_plane({ name = 'Charlie' })
    local g2 = mock.add_plane({ name = 'Alpha' })
    local g3 = mock.add_plane({ name = 'Bravo' })
    -- Pass in non-alphabetical order; apply must sort by current name first.
    local result = form._apply({ g1, g2, g3 }, 'X-{n}')
    check('{n}: changed=3',  result.changed == 3)
    check('{n}: failed=0',   result.failed == 0)
    check('{n}: Alpha → X-01',   g2.name == 'X-01')
    check('{n}: Bravo → X-02',   g3.name == 'X-02')
    check('{n}: Charlie → X-03', g1.name == 'X-03')
    check('{n}: renameGroup called 3 times', #renames == 3)
    check('{n}: toast = "3 renamed"', result.toast == '3 renamed', 'got ' .. tostring(result.toast))
    check('{n}: sev = success', result.sev == 'success')
    check('{n}: undo recorded', undo.has_record() == true)
end

-- Case 4: undo restores prior names (continues from Case 3 state).
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
    check('undo: Alpha restored', set['Alpha'] == true)
    check('undo: Bravo restored', set['Bravo'] == true)
    check('undo: Charlie restored', set['Charlie'] == true)
end

-- Case 5: pattern without {n} (set_all semantics) — all groups get same name.
do
    undo.clear()
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'A' })
    local g2 = mock.add_plane({ name = 'B' })
    local result = form._apply({ g1, g2 }, 'Foo')
    check('no-{n}: changed=2', result.changed == 2)
    check('no-{n}: g1 = Foo', g1.name == 'Foo')
    check('no-{n}: g2 = Foo', g2.name == 'Foo')
    check('no-{n}: toast = "2 renamed"', result.toast == '2 renamed')
    check('no-{n}: sev = success', result.sev == 'success')
end

-- Case 5b: one row already at target name → toast splits "1 renamed · 1 unchanged".
do
    undo.clear()
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'Foo' })  -- already named Foo
    local g2 = mock.add_plane({ name = 'B' })
    local result = form._apply({ g1, g2 }, 'Foo')
    check('mixed-unchanged: changed=1', result.changed == 1)
    check('mixed-unchanged: unchanged=1', result.unchanged == 1)
    check('mixed-unchanged: failed=0',    result.failed == 0)
    check('mixed-unchanged: g1 unchanged', g1.name == 'Foo')
    -- g2 was renamed to 'Foo' but 'Foo' is taken by g1, so check_group_name
    -- auto-disambiguates to 'Foo #2' (mock collision suffix; real DCS uses
    -- 'Foo-1'). The form still counts this as a rename — that's the
    -- documented ME-panel behaviour the writer mirrors.
    check('mixed-unchanged: g2 renamed',   g2.name == 'Foo #2', 'got ' .. tostring(g2.name))
    check('mixed-unchanged: toast contains "1 renamed"',
          result.toast:find('1 renamed') ~= nil, 'got ' .. tostring(result.toast))
    check('mixed-unchanged: toast contains "1 unchanged"',
          result.toast:find('1 unchanged') ~= nil, 'got ' .. tostring(result.toast))
    check('mixed-unchanged: sev = success', result.sev == 'success')
end

-- Case 5c: all rows already at target → "Already named that (N unchanged)" info toast.
do
    undo.clear()
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'Foo' })
    local g2 = mock.add_plane({ name = 'Foo' })  -- duplicate names; mock allows it
    local result = form._apply({ g1, g2 }, 'Foo')
    check('all-unchanged: changed=0', result.changed == 0)
    check('all-unchanged: unchanged=2', result.unchanged == 2)
    check('all-unchanged: failed=0',    result.failed == 0)
    check('all-unchanged: toast = "Already named that (2 unchanged)"',
          result.toast == 'Already named that (2 unchanged)', 'got ' .. tostring(result.toast))
    check('all-unchanged: sev = info', result.sev == 'info')
    check('all-unchanged: no undo recorded', undo.has_record() == false)
end

-- Case 6: writer rejection → row counted as failed.
do
    undo.clear()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    local orig_rename = mission_module.renameGroup
    mission_module.renameGroup = function() return false end
    local result = form._apply({ g }, 'X-{n}')
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
    local result = form._apply({ g }, 'X-{n}')
    mission_module.renameGroup = orig_rename
    check('writer throws: failed=1', result.failed == 1)
    check('writer throws: changed=0', result.changed == 0)
end

-- Case 8: module exports the expected metadata.
do
    check('form.scope = group', form.scope == 'group')
    check('form.title is a string', type(form.title) == 'string' and #form.title > 0)
    check('form.new is a function', type(form.new) == 'function')
    check('form._apply is a function', type(form._apply) == 'function')
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All rename_group tests passed.')
