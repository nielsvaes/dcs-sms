-- Standalone test for mass_edit_forms.add_suffix_unit_name.
-- Tests M._apply pure function + registered undo handler. The verb is
-- stubbed -- we test the form's counting/snapshot/toast/undo-dispatch
-- logic, not the verb's internals.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')
package.preload['me_mission'] = function() return mock end

-- Stub verbs.unit_set_name. Records every call and consults a per-test
-- queue of result tables so we can simulate ok / failure / throw paths
-- without touching real DCS.
local verb_calls = {}
local verb_responses = {}
local verb_throws = nil
local verbs_stub = {}
function verbs_stub.unit_set_name(args)
    verb_calls[#verb_calls + 1] = { id = args.id, new_name = args.new_name, name = args.name }
    if verb_throws then
        local msg = verb_throws
        verb_throws = nil
        error(msg)
    end
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

local form = require('dcs_sms_me.mass_edit_forms.add_suffix_unit_name')
local undo = require('dcs_sms_me.undo')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function reset()
    verb_calls = {}
    verb_responses = {}
    verb_throws = nil
    undo.clear()
end

-- Case 1: module exports the expected metadata.
do
    check('scope = unit', form.scope == 'unit')
    check('title is nonempty string', type(form.title) == 'string' and #form.title > 0)
    check('_apply is fn', type(form._apply) == 'function')
    check('new is fn', type(form.new) == 'function')
    check('applies_to is nil (universal)', form.applies_to == nil)
end

-- Case 2: empty selection -> nothing_selected, no verb call, no undo.
do
    reset()
    local result = form._apply({}, { text = 'X' })
    check('empty selection: changed=0',                result.changed == 0)
    check('empty selection: nothing_selected',         result.nothing_selected == true)
    check('empty selection: toast = Nothing selected', result.toast == 'Nothing selected')
    check('empty selection: sev = warning',            result.sev == 'warning')
    check('empty selection: 0 verb calls',             #verb_calls == 0)
    check('empty selection: no undo recorded',         undo.has_record() == false)
end

-- Case 3: empty suffix (missing args, missing text, empty text) -> guard.
do
    reset()
    local u = { unitId = 1, name = 'Foo' }
    -- args nil
    local r1 = form._apply({ u }, nil)
    check('nil args: toast = Enter a suffix', r1.toast == 'Enter a suffix',
          'got ' .. tostring(r1.toast))
    check('nil args: sev = warning', r1.sev == 'warning')
    check('nil args: 0 verb calls', #verb_calls == 0)
    -- text missing
    local r2 = form._apply({ u }, {})
    check('no text: toast = Enter a suffix', r2.toast == 'Enter a suffix')
    check('no text: 0 verb calls', #verb_calls == 0)
    -- text empty
    local r3 = form._apply({ u }, { text = '' })
    check('empty text: toast = Enter a suffix', r3.toast == 'Enter a suffix')
    check('empty text: 0 verb calls', #verb_calls == 0)
end

-- Case 4: multi success with keep_num=false -> 2 changed, undo recorded,
-- verb called with new_name (NOT name).
do
    reset()
    local u1 = { unitId = 10, name = 'Alpha' }
    local u2 = { unitId = 11, name = 'Bravo' }
    verb_responses[1] = { ok = true, id = 10, name = 'AlphaX' }
    verb_responses[2] = { ok = true, id = 11, name = 'BravoX' }
    local result = form._apply({ u1, u2 }, { text = 'X', keep_num = false })
    check('multi: changed=2', result.changed == 2)
    check('multi: failed=0', result.failed == 0)
    check('multi: 2 verb calls', #verb_calls == 2)
    check('multi: verb arg id 10', verb_calls[1].id == 10)
    check('multi: verb arg new_name = AlphaX', verb_calls[1].new_name == 'AlphaX',
          'got ' .. tostring(verb_calls[1].new_name))
    check('multi: verb arg id 11', verb_calls[2].id == 11)
    check('multi: verb arg new_name = BravoX', verb_calls[2].new_name == 'BravoX')
    check('multi: undo recorded', undo.has_record() == true)
end

-- Case 5: keep_num=true on "Viper-1" -> "ViperX-1".
do
    reset()
    local u = { unitId = 20, name = 'Viper-1' }
    verb_responses[1] = { ok = true, id = 20, name = 'ViperX-1' }
    local result = form._apply({ u }, { text = 'X', keep_num = true })
    check('keep_num: changed=1', result.changed == 1)
    check('keep_num: 1 verb call', #verb_calls == 1)
    check('keep_num: verb arg new_name = ViperX-1', verb_calls[1].new_name == 'ViperX-1',
          'got ' .. tostring(verb_calls[1].new_name))
end

-- Case 6: verb rejection (collision) -> failed=1, no undo.
do
    reset()
    local u = { unitId = 30, name = 'Foo' }
    verb_responses[1] = { ok = false, error = 'name "FooX" already in use' }
    local result = form._apply({ u }, { text = 'X' })
    check('collision: failed=1', result.failed == 1)
    check('collision: changed=0', result.changed == 0)
    check('collision: no undo recorded', undo.has_record() == false)
end

-- Case 7: undo restores via verb with OLD name.
do
    reset()
    local u1 = { unitId = 40, name = 'Cat' }
    local u2 = { unitId = 41, name = 'Dog' }
    verb_responses[1] = { ok = true, id = 40, name = 'CatX' }
    verb_responses[2] = { ok = true, id = 41, name = 'DogX' }
    local result = form._apply({ u1, u2 }, { text = 'X' })
    check('undo setup: changed=2', result.changed == 2)
    check('undo setup: undo recorded', undo.has_record() == true)

    -- Queue responses for the undo restoration calls.
    verb_responses[1] = { ok = true, id = 40, name = 'Cat' }
    verb_responses[2] = { ok = true, id = 41, name = 'Dog' }
    local ok = undo.undo()
    check('undo: ok=true', ok == true)
    check('undo: verb called 4 times total', #verb_calls == 4)
    check('undo: verb arg new_name = Cat (the old)', verb_calls[3].new_name == 'Cat',
          'got ' .. tostring(verb_calls[3].new_name))
    check('undo: verb arg new_name = Dog (the old)', verb_calls[4].new_name == 'Dog',
          'got ' .. tostring(verb_calls[4].new_name))
    check('undo: verb arg id 40', verb_calls[3].id == 40)
    check('undo: verb arg id 41', verb_calls[4].id == 41)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All add_suffix_unit_name tests passed.')
