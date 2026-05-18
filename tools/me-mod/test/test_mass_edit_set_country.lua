-- Standalone test for mass_edit_forms.set_country.
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

-- Stub the verbs module. group_set_country records every call and consults
-- a per-test queue of result tables so we can simulate ok / no_op / failure
-- / throw paths without touching real DCS.
local verb_calls = {}
local verb_responses = {}  -- queue of result tables (popped in order)
local verb_throws = nil    -- when set to a string, the next call raises with it
local verbs_stub = {}
function verbs_stub.group_set_country(args)
    verb_calls[#verb_calls + 1] = { id = args.id, country = args.country, name = args.name }
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

local form = require('dcs_sms_me.mass_edit_forms.set_country')
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

-- Case 1: empty selection -> nothing_selected, no verb call, no undo.
do
    reset()
    local result = form._apply({}, 'Russia')
    check('empty selection: changed=0',           result.changed == 0)
    check('empty selection: nothing_selected',    result.nothing_selected == true)
    check('empty selection: toast = Nothing selected', result.toast == 'Nothing selected')
    check('empty selection: sev = warning',       result.sev == 'warning')
    check('empty selection: 0 verb calls',        #verb_calls == 0)
    check('empty selection: no undo recorded',    undo.has_record() == false)
end

-- Case 2: no country picked (nil or '') -> guard, no verb call, no undo.
do
    reset()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    local r1 = form._apply({ g }, nil)
    check('no country (nil): toast = Pick a country', r1.toast == 'Pick a country')
    check('no country (nil): sev = warning', r1.sev == 'warning')
    check('no country (nil): 0 verb calls', #verb_calls == 0)
    local r2 = form._apply({ g }, '')
    check('no country (empty): toast = Pick a country', r2.toast == 'Pick a country')
    check('no country (empty): 0 verb calls', #verb_calls == 0)
end

-- Case 3: single-entity successful set -> 1 changed, undo recorded with previous_country.
do
    reset()
    mock.new_mission()
    local g = mock.add_plane({ name = 'Hornet', country = 'USA' })
    verb_responses[1] = { ok = true, id = g.groupId, name = 'Hornet',
                          country = 'Russia', side = 'red',
                          previous_country = 'USA', previous_side = 'blue',
                          coalition_changed = true }
    local result = form._apply({ g }, 'Russia')
    check('success: changed=1', result.changed == 1)
    check('success: failed=0', result.failed == 0)
    check('success: unchanged=0', (result.unchanged or 0) == 0)
    check('success: verb called once', #verb_calls == 1)
    check('success: verb arg id matches', verb_calls[1].id == g.groupId)
    check('success: verb arg country = Russia', verb_calls[1].country == 'Russia')
    check('success: toast = "1 country set"', result.toast == '1 country set',
          'got ' .. tostring(result.toast))
    check('success: sev = success', result.sev == 'success')
    check('success: undo recorded', undo.has_record() == true)
end

-- Case 4: undo restores via the verb with previous_country.
do
    -- Continue from Case 3 state -- undo will call the stub once more.
    verb_responses[1] = { ok = true, previous_country = 'Russia',
                          country = 'USA', coalition_changed = true }
    local ok = undo.undo()
    check('undo: ok=true', ok == true)
    check('undo: verb called once more', #verb_calls == 2)
    check('undo: verb arg country = USA (the old)', verb_calls[2].country == 'USA')
end

-- Case 5: mix -- one mutation + one no-op (already in target).
do
    reset()
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'A', country = 'USA' })
    local g2 = mock.add_plane({ name = 'B', side = 'red', country = 'Russia' })
    -- g1 will be moved USA->Russia (changed). g2 is already in Russia (no_op).
    verb_responses[1] = { ok = true, previous_country = 'USA',  country = 'Russia',
                          coalition_changed = true }
    verb_responses[2] = { ok = true, previous_country = 'Russia', country = 'Russia',
                          coalition_changed = false, no_op = true }
    local result = form._apply({ g1, g2 }, 'Russia')
    check('mix: changed=1', result.changed == 1)
    check('mix: unchanged=1', result.unchanged == 1)
    check('mix: failed=0', result.failed == 0)
    check('mix: 2 verb calls', #verb_calls == 2)
    check('mix: toast contains "1 country set"', result.toast:find('1 country set') ~= nil,
          'got ' .. tostring(result.toast))
    check('mix: toast contains "1 unchanged"', result.toast:find('1 unchanged') ~= nil,
          'got ' .. tostring(result.toast))
end

-- Case 6: all rows no-op -> "Already in <country>" info toast.
do
    reset()
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'A', side = 'red', country = 'Russia' })
    local g2 = mock.add_plane({ name = 'B', side = 'red', country = 'Russia' })
    verb_responses[1] = { ok = true, previous_country = 'Russia', country = 'Russia',
                          coalition_changed = false, no_op = true }
    verb_responses[2] = { ok = true, previous_country = 'Russia', country = 'Russia',
                          coalition_changed = false, no_op = true }
    local result = form._apply({ g1, g2 }, 'Russia')
    check('all-no-op: changed=0', result.changed == 0)
    check('all-no-op: unchanged=2', result.unchanged == 2)
    check('all-no-op: failed=0', result.failed == 0)
    check('all-no-op: toast = "Already in Russia"', result.toast == 'Already in Russia',
          'got ' .. tostring(result.toast))
    check('all-no-op: sev = info', result.sev == 'info')
    check('all-no-op: no undo recorded', undo.has_record() == false)
end

-- Case 7: verb rejection (ok=false) -> row counted as failed.
do
    reset()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    verb_responses[1] = { ok = false, error = 'group_set_country: country "Atlantis" not in mission tree' }
    local result = form._apply({ g }, 'Atlantis')
    check('verb reject: failed=1', result.failed == 1)
    check('verb reject: changed=0', result.changed == 0)
    check('verb reject: toast contains "0 country set"',
          result.toast:find('0 country set') ~= nil, 'got ' .. tostring(result.toast))
    check('verb reject: toast contains "1 failed"',
          result.toast:find('1 failed') ~= nil, 'got ' .. tostring(result.toast))
    check('verb reject: sev = error', result.sev == 'error')
    check('verb reject: no undo recorded', undo.has_record() == false)
end

-- Case 8: verb throws -> row counted as failed (pcall catches it).
do
    reset()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    verb_throws = 'simulated boom'
    local result = form._apply({ g }, 'Russia')
    check('verb throws: failed=1', result.failed == 1)
    check('verb throws: changed=0', result.changed == 0)
end

-- Case 9: mix -- one mutation + one failure -> warning sev with breakdown.
do
    reset()
    mock.new_mission()
    local g1 = mock.add_plane({ name = 'A' })
    local g2 = mock.add_plane({ name = 'B' })
    verb_responses[1] = { ok = true, previous_country = 'USA', country = 'Russia' }
    verb_responses[2] = { ok = false, error = 'group not found' }
    local result = form._apply({ g1, g2 }, 'Russia')
    check('partial-fail: changed=1', result.changed == 1)
    check('partial-fail: failed=1', result.failed == 1)
    check('partial-fail: toast contains "1 country set"', result.toast:find('1 country set') ~= nil)
    check('partial-fail: toast contains "1 failed"', result.toast:find('1 failed') ~= nil)
    check('partial-fail: sev = warning', result.sev == 'warning')
    check('partial-fail: undo recorded (1 success exists)', undo.has_record() == true)
end

-- Case 10: module exports the expected metadata.
do
    check('form.scope = group', form.scope == 'group')
    check('form.title is a non-empty string', type(form.title) == 'string' and #form.title > 0)
    check('form.new is a function', type(form.new) == 'function')
    check('form._apply is a function', type(form._apply) == 'function')
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All set_country tests passed.')
