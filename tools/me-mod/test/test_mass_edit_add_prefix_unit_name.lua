-- Standalone test for mass_edit_forms.add_prefix_unit_name.
-- Tests M._apply pure function + registered undo handler. The verb
-- (unit_set_name) is stubbed -- we test the form's counting / snapshot /
-- toast / undo-dispatch logic, not the verb's internals.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')

-- me_mission stub for transitive requires.
package.preload['me_mission'] = function() return mock end

-- Stub the verbs module. unit_set_name records every call and consults
-- a per-test queue of result tables so we can simulate ok / failure paths
-- without touching real DCS.
local verb_calls = {}
local verb_responses = {}  -- queue of result tables (popped in order)
local verbs_stub = {}
function verbs_stub.unit_set_name(args)
    verb_calls[#verb_calls + 1] = { id = args.id, new_name = args.new_name }
    local r = table.remove(verb_responses, 1)
    if r == nil then
        return { ok = false, error = 'no stubbed response' }
    end
    return r
end
package.preload['dcs_sms_me.verbs'] = function() return verbs_stub end

-- Stub selection for undo.lua's transitive prefab_ops requires.
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end

local form = require('dcs_sms_me.mass_edit_forms.add_prefix_unit_name')
local undo = require('dcs_sms_me.undo')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function reset()
    verb_calls = {}
    verb_responses = {}
    undo.clear()
end

-- Helper: pull the first unit out of a freshly-added group (unit-scope forms
-- operate on unit tables, not group tables).
local function add_unit(opts)
    local g = mock.add_plane(opts)
    return g.units[1]
end

-- Case 1: module exports.
do
    check('scope=unit', form.scope == 'unit')
    check('title is nonempty string', type(form.title) == 'string' and #form.title > 0)
    check('title = Add prefix to unit names', form.title == 'Add prefix to unit names')
    check('_apply is fn', type(form._apply) == 'function')
    check('new is fn', type(form.new) == 'function')
    check('applies_to is nil (universal)', form.applies_to == nil)
end

-- Case 2: empty selection -> nothing_selected, no verb call, no undo.
do
    reset()
    local result = form._apply({}, { text = 'X-' })
    check('empty selection: changed=0',           result.changed == 0)
    check('empty selection: nothing_selected',    result.nothing_selected == true)
    check('empty selection: toast = Nothing selected', result.toast == 'Nothing selected')
    check('empty selection: sev = warning',       result.sev == 'warning')
    check('empty selection: 0 verb calls',        #verb_calls == 0)
    check('empty selection: no undo recorded',    undo.has_record() == false)
end

-- Case 3: missing / empty prefix -> guard, no verb call, no undo.
do
    reset()
    mock.new_mission()
    local u = add_unit({ name = 'Hornet' })
    local r1 = form._apply({ u }, nil)
    check('nil args: toast = Enter a prefix', r1.toast == 'Enter a prefix',
          'got ' .. tostring(r1.toast))
    check('nil args: sev = warning', r1.sev == 'warning')
    check('nil args: 0 verb calls', #verb_calls == 0)
    check('nil args: no undo recorded', undo.has_record() == false)

    local r2 = form._apply({ u }, { text = '' })
    check('empty text: toast = Enter a prefix', r2.toast == 'Enter a prefix')
    check('empty text: 0 verb calls', #verb_calls == 0)

    local r3 = form._apply({ u }, {})
    check('nil text field: toast = Enter a prefix', r3.toast == 'Enter a prefix')
    check('nil text field: 0 verb calls', #verb_calls == 0)
end

-- Case 4: multi happy. 2 units, prefix all -> 2 verb calls, undo recorded.
do
    reset()
    mock.new_mission()
    local u1 = add_unit({ name = 'Alpha' })
    u1.name = 'Alpha'; u1.unitId = 101
    local u2 = add_unit({ name = 'Bravo' })
    u2.name = 'Bravo'; u2.unitId = 102
    verb_responses[1] = { ok = true, id = 101, new_name = 'TEST-Alpha' }
    verb_responses[2] = { ok = true, id = 102, new_name = 'TEST-Bravo' }
    local result = form._apply({ u1, u2 }, { text = 'TEST-' })
    check('multi: changed=2', result.changed == 2)
    check('multi: failed=0', result.failed == 0)
    check('multi: 2 verb calls', #verb_calls == 2)
    check('multi: verb call 1 new_name = TEST-Alpha',
          verb_calls[1].new_name == 'TEST-Alpha', 'got ' .. tostring(verb_calls[1].new_name))
    check('multi: verb call 2 new_name = TEST-Bravo',
          verb_calls[2].new_name == 'TEST-Bravo', 'got ' .. tostring(verb_calls[2].new_name))
    check('multi: verb arg id 1 = 101', verb_calls[1].id == 101)
    check('multi: verb arg id 2 = 102', verb_calls[2].id == 102)
    check('multi: toast = "2 renamed"', result.toast == '2 renamed',
          'got ' .. tostring(result.toast))
    check('multi: sev = success', result.sev == 'success')
    check('multi: undo recorded', undo.has_record() == true)
end

-- Case 5: undo restores via verb with OLD value (continues Case 4 state).
do
    verb_responses[1] = { ok = true, id = 101, new_name = 'Alpha' }
    verb_responses[2] = { ok = true, id = 102, new_name = 'Bravo' }
    local before_calls = #verb_calls
    local ok = undo.undo()
    check('undo: ok=true', ok == true)
    check('undo: 2 more verb calls', #verb_calls == before_calls + 2)
    -- The two undo-time calls should restore Alpha/Bravo (in some order).
    local restored = {}
    for i = before_calls + 1, #verb_calls do
        restored[verb_calls[i].new_name] = true
    end
    check('undo: Alpha restored', restored['Alpha'] == true)
    check('undo: Bravo restored', restored['Bravo'] == true)
end

-- Case 6: verb rejection (ok=false, e.g. name collision) -> counted as failed.
do
    reset()
    mock.new_mission()
    local u = add_unit({ name = 'A' })
    u.unitId = 201
    verb_responses[1] = { ok = false, error = 'Mission.renameUnit refused (name in use)' }
    local result = form._apply({ u }, { text = 'X-' })
    check('verb reject: failed=1', result.failed == 1)
    check('verb reject: changed=0', result.changed == 0)
    check('verb reject: 1 verb call', #verb_calls == 1)
    check('verb reject: toast contains "0 renamed"',
          result.toast:find('0 renamed') ~= nil, 'got ' .. tostring(result.toast))
    check('verb reject: toast contains "1 failed"',
          result.toast:find('1 failed') ~= nil, 'got ' .. tostring(result.toast))
    check('verb reject: sev = error', result.sev == 'error')
    check('verb reject: no undo recorded', undo.has_record() == false)
end

-- Case 7: verb throws (pcall catches) -> counted as failed.
do
    reset()
    mock.new_mission()
    local u = add_unit({ name = 'A' })
    u.unitId = 202
    -- Replace stub temporarily to throw.
    local orig = verbs_stub.unit_set_name
    verbs_stub.unit_set_name = function() error('simulated boom') end
    local result = form._apply({ u }, { text = 'X-' })
    verbs_stub.unit_set_name = orig
    check('verb throws: failed=1', result.failed == 1)
    check('verb throws: changed=0', result.changed == 0)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All add_prefix_unit_name tests passed.')
