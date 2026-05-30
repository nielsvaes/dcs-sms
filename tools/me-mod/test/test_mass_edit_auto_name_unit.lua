-- Standalone test for mass_edit_forms.auto_name_unit.
-- Tests M._apply + the registered undo handler. The verb is stubbed --
-- we test the form's counting/snapshot/toast/undo-dispatch logic, not
-- the verb's internals.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')

-- Stub me_mission for transitive requires.
package.preload['me_mission'] = function() return mock end

-- Stub verbs.unit_set_name. Each call is recorded; per-test
-- verb_responses queue controls success/failure ordering.
local verb_calls = {}
local verb_responses = {}  -- queue of result tables (popped in order)
local verbs_stub = {}
function verbs_stub.unit_set_name(args)
    verb_calls[#verb_calls + 1] = { id = args.id, new_name = args.new_name }
    local r = table.remove(verb_responses, 1)
    if r == nil then return { ok = false, error = 'no stubbed response' } end
    return r
end
package.preload['dcs_sms_me.verbs'] = function() return verbs_stub end

-- Stub selection for undo.lua's transitive prefab_ops requires.
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end

local form = require('dcs_sms_me.mass_edit_forms.auto_name_unit')
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

-- A unit is just a table with `unitId` and `name` for the form's purposes.
local function mk_unit(id, name)
    return { unitId = id, name = name }
end

-- Case 1: module exports.
do
    check('form.scope = unit', form.scope == 'unit')
    check('form.title is a non-empty string', type(form.title) == 'string' and #form.title > 0)
    check('form.new is a function', type(form.new) == 'function')
    check('form._apply is a function', type(form._apply) == 'function')
    check('form.applies_to is nil (universal)', form.applies_to == nil)
end

-- Case 2: empty selection -> nothing_selected, no verb call.
do
    reset()
    local result = form._apply({}, { base = 'Falcon', start = 1 }, {})
    check('empty: changed=0',           result.changed == 0)
    check('empty: nothing_selected',    result.nothing_selected == true)
    check('empty: toast = Nothing selected', result.toast == 'Nothing selected')
    check('empty: sev = warning',       result.sev == 'warning')
    check('empty: 0 verb calls',        #verb_calls == 0)
    check('empty: no undo recorded',    undo.has_record() == false)
end

-- Case 3a: missing args -> guard, no verb call.
do
    reset()
    local u = mk_unit(1, 'Foo')
    local r = form._apply({ u }, nil, {})
    check('nil args: toast = Enter a base name', r.toast == 'Enter a base name')
    check('nil args: sev = warning', r.sev == 'warning')
    check('nil args: 0 verb calls', #verb_calls == 0)
end

-- Case 3b: empty base -> guard, no verb call.
do
    reset()
    local u = mk_unit(1, 'Foo')
    local r1 = form._apply({ u }, { base = '', start = 1 }, {})
    check('empty base: toast = Enter a base name', r1.toast == 'Enter a base name')
    check('empty base: 0 verb calls', #verb_calls == 0)

    local r2 = form._apply({ u }, { base = nil, start = 1 }, {})
    check('nil base: toast = Enter a base name', r2.toast == 'Enter a base name')
    check('nil base: 0 verb calls', #verb_calls == 0)
end

-- Case 4: success on 3 units -> Base-1, Base-2, Base-3.
do
    reset()
    local u1 = mk_unit(101, 'old-a')
    local u2 = mk_unit(102, 'old-b')
    local u3 = mk_unit(103, 'old-c')
    verb_responses[1] = { ok = true }
    verb_responses[2] = { ok = true }
    verb_responses[3] = { ok = true }
    local result = form._apply({ u1, u2, u3 }, { base = 'Viper', start = 1 }, {})
    check('3-units: changed=3', result.changed == 3)
    check('3-units: failed=0', result.failed == 0)
    check('3-units: 3 verb calls', #verb_calls == 3)
    check('3-units: new_name[1] = Viper-1', verb_calls[1].new_name == 'Viper-1',
          'got ' .. tostring(verb_calls[1].new_name))
    check('3-units: new_name[2] = Viper-2', verb_calls[2].new_name == 'Viper-2',
          'got ' .. tostring(verb_calls[2].new_name))
    check('3-units: new_name[3] = Viper-3', verb_calls[3].new_name == 'Viper-3',
          'got ' .. tostring(verb_calls[3].new_name))
    check('3-units: verb id[1] = 101', verb_calls[1].id == 101)
    check('3-units: toast contains "3 renamed"',
          result.toast and result.toast:find('3 renamed') ~= nil,
          'got ' .. tostring(result.toast))
    check('3-units: sev = success', result.sev == 'success')
    check('3-units: undo recorded', undo.has_record() == true)
end

-- Case 5: start=5, 3 units -> Falcon-5, Falcon-6, Falcon-7.
do
    reset()
    local u1 = mk_unit(201, 'x')
    local u2 = mk_unit(202, 'y')
    local u3 = mk_unit(203, 'z')
    verb_responses[1] = { ok = true }
    verb_responses[2] = { ok = true }
    verb_responses[3] = { ok = true }
    local result = form._apply({ u1, u2, u3 }, { base = 'Falcon', start = 5 }, {})
    check('start=5: changed=3', result.changed == 3)
    check('start=5: new_name[1] = Falcon-5', verb_calls[1].new_name == 'Falcon-5',
          'got ' .. tostring(verb_calls[1].new_name))
    check('start=5: new_name[2] = Falcon-6', verb_calls[2].new_name == 'Falcon-6',
          'got ' .. tostring(verb_calls[2].new_name))
    check('start=5: new_name[3] = Falcon-7', verb_calls[3].new_name == 'Falcon-7',
          'got ' .. tostring(verb_calls[3].new_name))
end

-- Case 5b: non-numeric start defaults to 1.
do
    reset()
    local u1 = mk_unit(301, 'a')
    verb_responses[1] = { ok = true }
    local result = form._apply({ u1 }, { base = 'Bee', start = 'nope' }, {})
    check('bad start: changed=1', result.changed == 1)
    check('bad start: new_name = Bee-1', verb_calls[1].new_name == 'Bee-1',
          'got ' .. tostring(verb_calls[1].new_name))
end

-- Case 6: verb collision on row 2 -> failed=1, others succeed.
do
    reset()
    local u1 = mk_unit(401, 'a')
    local u2 = mk_unit(402, 'b')
    local u3 = mk_unit(403, 'c')
    verb_responses[1] = { ok = true }
    verb_responses[2] = { ok = false, error = 'name in use' }
    verb_responses[3] = { ok = true }
    local result = form._apply({ u1, u2, u3 }, { base = 'Tiger', start = 1 }, {})
    check('collision: changed=2', result.changed == 2)
    check('collision: failed=1', result.failed == 1)
    check('collision: 3 verb calls', #verb_calls == 3)
    check('collision: toast contains "2 renamed"',
          result.toast and result.toast:find('2 renamed') ~= nil,
          'got ' .. tostring(result.toast))
    check('collision: toast contains "1 failed"',
          result.toast and result.toast:find('1 failed') ~= nil,
          'got ' .. tostring(result.toast))
    check('collision: sev = warning', result.sev == 'warning')
    check('collision: undo recorded (2 successes)', undo.has_record() == true)
end

-- Case 6b: all rows fail -> sev=error, toast mentions failed.
do
    reset()
    local u1 = mk_unit(501, 'a')
    verb_responses[1] = { ok = false, error = 'name in use' }
    local result = form._apply({ u1 }, { base = 'Whiskey', start = 1 }, {})
    check('all-fail: changed=0', result.changed == 0)
    check('all-fail: failed=1', result.failed == 1)
    check('all-fail: sev = error', result.sev == 'error')
end

-- Case 6c: row already matches auto-generated name -> silent skip (no count).
do
    reset()
    local u1 = mk_unit(601, 'Alpha-1')  -- already matches base=Alpha,start=1,idx=1
    local u2 = mk_unit(602, 'old')
    verb_responses[1] = { ok = true }   -- only u2 should produce a verb call
    local result = form._apply({ u1, u2 }, { base = 'Alpha', start = 1 }, {})
    check('skip: changed=1', result.changed == 1)
    check('skip: failed=0', result.failed == 0)
    check('skip: 1 verb call (u1 skipped silently)', #verb_calls == 1)
    check('skip: verb call is for u2', verb_calls[1].id == 602)
    check('skip: verb new_name = Alpha-2', verb_calls[1].new_name == 'Alpha-2',
          'got ' .. tostring(verb_calls[1].new_name))
end

-- Case 7: all rows silently skipped (already named) -> 'No changes' warning.
do
    reset()
    local u1 = mk_unit(701, 'Bravo-1')
    local u2 = mk_unit(702, 'Bravo-2')
    local result = form._apply({ u1, u2 }, { base = 'Bravo', start = 1 }, {})
    check('no-changes: changed=0', result.changed == 0)
    check('no-changes: failed=0', result.failed == 0)
    check('no-changes: 0 verb calls', #verb_calls == 0)
    check('no-changes: toast = No changes', result.toast == 'No changes',
          'got ' .. tostring(result.toast))
    check('no-changes: sev = warning', result.sev == 'warning')
end

-- Case 8: undo restores old names via verb.unit_set_name with new_name = old.
do
    reset()
    local u1 = mk_unit(801, 'oldA')
    local u2 = mk_unit(802, 'oldB')
    verb_responses[1] = { ok = true }
    verb_responses[2] = { ok = true }
    form._apply({ u1, u2 }, { base = 'Echo', start = 1 }, {})
    check('undo-setup: undo recorded', undo.has_record() == true)
    check('undo-setup: 2 verb calls so far', #verb_calls == 2)

    -- Undo calls verb once per row with the OLD name.
    verb_responses[1] = { ok = true }
    verb_responses[2] = { ok = true }
    local ok = undo.undo()
    check('undo: ok=true', ok == true)
    check('undo: 2 more verb calls (total 4)', #verb_calls == 4)
    check('undo: verb[3].new_name = oldA', verb_calls[3].new_name == 'oldA',
          'got ' .. tostring(verb_calls[3].new_name))
    check('undo: verb[3].id = 801', verb_calls[3].id == 801)
    check('undo: verb[4].new_name = oldB', verb_calls[4].new_name == 'oldB',
          'got ' .. tostring(verb_calls[4].new_name))
    check('undo: verb[4].id = 802', verb_calls[4].id == 802)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All auto_name_unit tests passed.')
