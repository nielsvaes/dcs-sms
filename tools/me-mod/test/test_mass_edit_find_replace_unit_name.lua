-- Standalone test for mass_edit_forms.find_replace_unit_name.
-- Tests M._apply + the registered undo handler. The verb is stubbed --
-- we test the form's counting/snapshot/toast/undo-dispatch logic, not
-- the verb's internals.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')

-- Stub me_mission for transitive requires (undo → prefab_ops → ...).
package.preload['me_mission'] = function() return mock end

-- Stub the verbs module. unit_set_name records every call and consults
-- a per-test queue of result tables so we can simulate ok / failure /
-- collision paths without touching real DCS.
local verb_calls = {}
local verb_responses = {}  -- queue of result tables (popped in order)
local verb_throws = nil    -- when set to a string, the next call raises with it
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

local form = require('dcs_sms_me.mass_edit_forms.find_replace_unit_name')
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

-- Tiny helper to fabricate a unit-like row. The form only reads u.name
-- and u.unitId; everything else is irrelevant to _apply.
local function unit(unitId, name)
    return { unitId = unitId, name = name }
end

-- Case 1: module exports the expected metadata.
do
    check('scope=unit', form.scope == 'unit')
    check('title is nonempty string', type(form.title) == 'string' and #form.title > 0)
    check('_apply is fn', type(form._apply) == 'function')
    check('new is fn', type(form.new) == 'function')
    check('applies_to is nil (universal)', form.applies_to == nil)
end

-- Case 2: empty selection → nothing_selected, no verb calls.
do
    reset()
    local result = form._apply({}, { find = 'foo', replace = 'bar' })
    check('empty selection: changed=0',           result.changed == 0)
    check('empty selection: nothing_selected',    result.nothing_selected == true)
    check('empty selection: toast = Nothing selected', result.toast == 'Nothing selected')
    check('empty selection: sev = warning',       result.sev == 'warning')
    check('empty selection: 0 verb calls',        #verb_calls == 0)
    check('empty selection: no undo recorded',    undo.has_record() == false)
end

-- Case 3: missing args / empty find → guard toast, no verb calls.
do
    reset()
    local u = unit(101, 'Hornet-1')
    local r1 = form._apply({ u }, nil)
    check('nil args: toast = No matches', r1.toast == 'No matches')
    check('nil args: sev = warning',      r1.sev == 'warning')
    check('nil args: 0 verb calls',       #verb_calls == 0)
    check('nil args: no undo recorded',   undo.has_record() == false)

    reset()
    local r2 = form._apply({ u }, { find = '', replace = 'x' })
    check('empty find: toast = No matches', r2.toast == 'No matches')
    check('empty find: 0 verb calls',       #verb_calls == 0)
    check('empty find: no undo recorded',   undo.has_record() == false)

    reset()
    local r3 = form._apply({ u }, {})  -- table with no find field
    check('no find field: toast = No matches', r3.toast == 'No matches')
    check('no find field: 0 verb calls',       #verb_calls == 0)
end

-- Case 4: success — 3 units, all match.
do
    reset()
    local u1 = unit(11, 'CAP-Foo-1')
    local u2 = unit(12, 'CAP-Foo-2')
    local u3 = unit(13, 'CAP-Foo-3')
    verb_responses[1] = { ok = true, id = 11, name = 'CAP-Bar-1' }
    verb_responses[2] = { ok = true, id = 12, name = 'CAP-Bar-2' }
    verb_responses[3] = { ok = true, id = 13, name = 'CAP-Bar-3' }
    local result = form._apply({ u1, u2, u3 }, { find = 'Foo', replace = 'Bar' })
    check('success: changed=3', result.changed == 3)
    check('success: failed=0',  result.failed == 0)
    check('success: 3 verb calls', #verb_calls == 3)
    check('success: verb arg uses new_name (NOT name)',
          verb_calls[1].new_name == 'CAP-Bar-1' and verb_calls[1].name == nil,
          'got new_name=' .. tostring(verb_calls[1].new_name) .. ', name=' .. tostring(verb_calls[1].name))
    check('success: verb arg id matches', verb_calls[1].id == 11)
    check('success: verb call 2 new_name', verb_calls[2].new_name == 'CAP-Bar-2')
    check('success: verb call 3 new_name', verb_calls[3].new_name == 'CAP-Bar-3')
    check('success: toast = "3 renamed"', result.toast == '3 renamed',
          'got ' .. tostring(result.toast))
    check('success: sev = success', result.sev == 'success')
    check('success: undo recorded', undo.has_record() == true)
end

-- Case 5: mixed — some match, some don't → only matches counted (no-match rows silent).
do
    reset()
    local u1 = unit(21, 'CAP-Foo-1')
    local u2 = unit(22, 'Other')
    local u3 = unit(23, 'CAP-Foo-2')
    verb_responses[1] = { ok = true, id = 21, name = 'CAP-Bar-1' }
    verb_responses[2] = { ok = true, id = 23, name = 'CAP-Bar-2' }
    local result = form._apply({ u1, u2, u3 }, { find = 'Foo', replace = 'Bar' })
    check('mixed: changed=2', result.changed == 2)
    check('mixed: failed=0',  result.failed == 0)
    check('mixed: only 2 verb calls (u2 silently skipped)', #verb_calls == 2)
    check('mixed: verb call 1 is u1', verb_calls[1].id == 21)
    check('mixed: verb call 2 is u3', verb_calls[2].id == 23)
    check('mixed: toast = "2 renamed"', result.toast == '2 renamed',
          'got ' .. tostring(result.toast))
    check('mixed: sev = success', result.sev == 'success')
    check('mixed: undo recorded', undo.has_record() == true)
end

-- Case 6: verb rejection (collision: ok=false) → counted as failed, sev=warning.
do
    reset()
    local u1 = unit(31, 'CAP-Foo-1')
    local u2 = unit(32, 'CAP-Foo-2')
    verb_responses[1] = { ok = true, id = 31, name = 'CAP-Bar-1' }
    verb_responses[2] = { ok = false, error = 'name "CAP-Bar-2" already in use' }
    local result = form._apply({ u1, u2 }, { find = 'Foo', replace = 'Bar' })
    check('verb reject: changed=1', result.changed == 1)
    check('verb reject: failed=1',  result.failed == 1)
    check('verb reject: 2 verb calls', #verb_calls == 2)
    check('verb reject: toast contains "1 renamed"',
          result.toast:find('1 renamed') ~= nil, 'got ' .. tostring(result.toast))
    check('verb reject: toast contains "1 failed"',
          result.toast:find('1 failed') ~= nil, 'got ' .. tostring(result.toast))
    check('verb reject: sev = warning', result.sev == 'warning')
    check('verb reject: undo recorded (1 success exists)', undo.has_record() == true)
end

-- Case 6b: all rows fail → sev=error, 0 renamed.
do
    reset()
    local u = unit(41, 'CAP-Foo-1')
    verb_responses[1] = { ok = false, error = 'name "CAP-Bar-1" already in use' }
    local result = form._apply({ u }, { find = 'Foo', replace = 'Bar' })
    check('all fail: changed=0', result.changed == 0)
    check('all fail: failed=1',  result.failed == 1)
    check('all fail: toast contains "0 renamed"',
          result.toast:find('0 renamed') ~= nil, 'got ' .. tostring(result.toast))
    check('all fail: toast contains "1 failed"',
          result.toast:find('1 failed') ~= nil, 'got ' .. tostring(result.toast))
    check('all fail: sev = error', result.sev == 'error')
    check('all fail: no undo recorded', undo.has_record() == false)
end

-- Case 6c: find string present but transform yields the same string
--   (e.g. find == replace) → silent skip (no verb call, no count).
do
    reset()
    local u = unit(51, 'Hornet')
    local result = form._apply({ u }, { find = 'Hornet', replace = 'Hornet' })
    check('no-op replace: 0 verb calls', #verb_calls == 0)
    check('no-op replace: changed=0',    result.changed == 0)
    check('no-op replace: failed=0',     result.failed == 0)
    check('no-op replace: toast = No matches', result.toast == 'No matches')
    check('no-op replace: sev = warning', result.sev == 'warning')
end

-- Case 8: undo restores via verb with OLD value (uses args.new_name).
do
    reset()
    local u1 = unit(61, 'CAP-Foo-1')
    local u2 = unit(62, 'CAP-Foo-2')
    verb_responses[1] = { ok = true, id = 61, name = 'CAP-Bar-1' }
    verb_responses[2] = { ok = true, id = 62, name = 'CAP-Bar-2' }
    form._apply({ u1, u2 }, { find = 'Foo', replace = 'Bar' })
    check('undo-setup: 2 forward verb calls', #verb_calls == 2)
    check('undo-setup: undo recorded', undo.has_record() == true)

    -- Queue undo responses (one per row).
    verb_responses[1] = { ok = true, id = 61, name = 'CAP-Foo-1' }
    verb_responses[2] = { ok = true, id = 62, name = 'CAP-Foo-2' }
    local ok = undo.undo()
    check('undo: ok=true', ok == true)
    check('undo: 2 more verb calls (4 total)', #verb_calls == 4)
    check('undo: verb call 3 restores u1 to OLD via new_name',
          verb_calls[3].id == 61 and verb_calls[3].new_name == 'CAP-Foo-1',
          'got id=' .. tostring(verb_calls[3].id) .. ', new_name=' .. tostring(verb_calls[3].new_name))
    check('undo: verb call 4 restores u2 to OLD via new_name',
          verb_calls[4].id == 62 and verb_calls[4].new_name == 'CAP-Foo-2',
          'got id=' .. tostring(verb_calls[4].id) .. ', new_name=' .. tostring(verb_calls[4].new_name))
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All find_replace_unit_name tests passed.')
