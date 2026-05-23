-- Standalone test for mass_edit_forms.set_skill_unit.
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

-- Stub the verbs module. unit_set_skill records every call and consults
-- a per-test queue of result tables so we can simulate ok / failure / throw
-- paths without touching real DCS.
local verb_calls = {}
local verb_responses = {}  -- queue of result tables (popped in order)
local verb_throws = nil    -- when set to a string, the next call raises with it
local verbs_stub = {}
function verbs_stub.unit_set_skill(args)
    verb_calls[#verb_calls + 1] = { id = args.id, skill = args.skill, name = args.name }
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

local form = require('dcs_sms_me.mass_edit_forms.set_skill_unit')
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

-- Build a synthetic unit table (the form treats unit entities as having
-- unitId + skill; mass_edit.lua passes the raw mission unit table through).
local function mk_unit(id, name, skill)
    return { unitId = id, name = name or ('u-' .. tostring(id)), skill = skill or 'Average' }
end

-- Case 1: module exports.
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
    local result = form._apply({}, 'High')
    check('empty selection: changed=0',                result.changed == 0)
    check('empty selection: nothing_selected',         result.nothing_selected == true)
    check('empty selection: toast = Nothing selected', result.toast == 'Nothing selected')
    check('empty selection: sev = warning',            result.sev == 'warning')
    check('empty selection: 0 verb calls',             #verb_calls == 0)
    check('empty selection: no undo recorded',         undo.has_record() == false)
end

-- Case 3: no skill picked (nil or '') -> guard, no verb call, no undo.
do
    reset()
    local u = mk_unit(1)
    local r1 = form._apply({ u }, nil)
    check('no skill (nil): toast = Pick a skill', r1.toast == 'Pick a skill')
    check('no skill (nil): sev = warning',         r1.sev == 'warning')
    check('no skill (nil): 0 verb calls',          #verb_calls == 0)
    check('no skill (nil): no undo recorded',      undo.has_record() == false)

    local r2 = form._apply({ u }, '')
    check('no skill (empty): toast = Pick a skill', r2.toast == 'Pick a skill')
    check('no skill (empty): 0 verb calls',         #verb_calls == 0)

    local r3 = form._apply({ u }, 123)
    check('no skill (number): toast = Pick a skill', r3.toast == 'Pick a skill')
    check('no skill (number): 0 verb calls',         #verb_calls == 0)
end

-- Case 4: success across 2 units -> 2 changed, undo recorded.
do
    reset()
    local u1 = mk_unit(101, 'A', 'Average')
    local u2 = mk_unit(102, 'B', 'Good')
    verb_responses[1] = { ok = true, id = 101, name = 'A', skill = 'High' }
    verb_responses[2] = { ok = true, id = 102, name = 'B', skill = 'High' }
    local result = form._apply({ u1, u2 }, 'High')
    check('success: changed=2',            result.changed == 2)
    check('success: failed=0',             result.failed == 0)
    check('success: unchanged=0',          (result.unchanged or 0) == 0)
    check('success: 2 verb calls',         #verb_calls == 2)
    check('success: verb 1 id=101',        verb_calls[1].id == 101)
    check('success: verb 1 skill=High',    verb_calls[1].skill == 'High')
    check('success: verb 2 id=102',        verb_calls[2].id == 102)
    check('success: verb 2 skill=High',    verb_calls[2].skill == 'High')
    check('success: toast = "2 skill set"', result.toast == '2 skill set',
          'got ' .. tostring(result.toast))
    check('success: sev = success',        result.sev == 'success')
    check('success: undo recorded',        undo.has_record() == true)
    check('success: changed_rows has 2 entries', #result.changed_rows == 2)
    check('success: changed_rows[1].old = Average', result.changed_rows[1].old == 'Average')
    check('success: changed_rows[2].old = Good',    result.changed_rows[2].old == 'Good')
end

-- Case 5: already-at-target -> unchanged=1, "Already <skill>" info toast,
-- no verb calls, no undo.
do
    reset()
    local u = mk_unit(201, 'X', 'High')
    local result = form._apply({ u }, 'High')
    check('already-target: changed=0',   result.changed == 0)
    check('already-target: failed=0',    result.failed == 0)
    check('already-target: unchanged=1', result.unchanged == 1)
    check('already-target: 0 verb calls (pre-check)', #verb_calls == 0)
    check('already-target: toast = "Already High"', result.toast == 'Already High',
          'got ' .. tostring(result.toast))
    check('already-target: sev = info',  result.sev == 'info')
    check('already-target: no undo recorded', undo.has_record() == false)
end

-- Case 6: verb rejection -> failed=1, error toast.
do
    reset()
    local u = mk_unit(301, 'Y', 'Average')
    verb_responses[1] = { ok = false, error = 'unit not found' }
    local result = form._apply({ u }, 'High')
    check('verb-reject: changed=0', result.changed == 0)
    check('verb-reject: failed=1',  result.failed == 1)
    check('verb-reject: 1 verb call', #verb_calls == 1)
    check('verb-reject: toast contains "0 skill set"',
          result.toast:find('0 skill set') ~= nil, 'got ' .. tostring(result.toast))
    check('verb-reject: toast contains "1 failed"',
          result.toast:find('1 failed') ~= nil, 'got ' .. tostring(result.toast))
    check('verb-reject: sev = error', result.sev == 'error')
    check('verb-reject: no undo recorded', undo.has_record() == false)
end

-- Case 6b: verb throws -> failed=1 (pcall catches it).
do
    reset()
    local u = mk_unit(401, 'Z', 'Average')
    verb_throws = 'simulated boom'
    local result = form._apply({ u }, 'High')
    check('verb-throws: changed=0', result.changed == 0)
    check('verb-throws: failed=1',  result.failed == 1)
end

-- Case 6c: mix of success + no-op + failure -> warning toast with breakdown.
do
    reset()
    local u1 = mk_unit(501, 'A', 'Average')   -- will change
    local u2 = mk_unit(502, 'B', 'High')      -- already at target (no verb call)
    local u3 = mk_unit(503, 'C', 'Average')   -- will fail
    verb_responses[1] = { ok = true, id = 501, name = 'A', skill = 'High' }
    -- (no entry for u2 — pre-check intercepts it)
    verb_responses[2] = { ok = false, error = 'unit not found' }
    local result = form._apply({ u1, u2, u3 }, 'High')
    check('mix: changed=1',   result.changed == 1)
    check('mix: unchanged=1', result.unchanged == 1)
    check('mix: failed=1',    result.failed == 1)
    check('mix: 2 verb calls', #verb_calls == 2)
    check('mix: toast contains "1 skill set"',
          result.toast:find('1 skill set') ~= nil, 'got ' .. tostring(result.toast))
    check('mix: toast contains "1 unchanged"',
          result.toast:find('1 unchanged') ~= nil, 'got ' .. tostring(result.toast))
    check('mix: toast contains "1 failed"',
          result.toast:find('1 failed') ~= nil, 'got ' .. tostring(result.toast))
    check('mix: sev = warning', result.sev == 'warning')
    check('mix: undo recorded (1 success exists)', undo.has_record() == true)
end

-- Case 8: undo restores via the verb with the OLD value.
do
    reset()
    local u = mk_unit(601, 'Q', 'Average')
    verb_responses[1] = { ok = true, id = 601, name = 'Q', skill = 'High' }
    local _ = form._apply({ u }, 'High')
    check('undo-prep: 1 verb call', #verb_calls == 1)
    check('undo-prep: undo recorded', undo.has_record() == true)

    -- Now undo. Stub the restore call.
    verb_responses[1] = { ok = true, id = 601, name = 'Q', skill = 'Average' }
    local ok = undo.undo()
    check('undo: ok=true', ok == true)
    check('undo: 2 total verb calls', #verb_calls == 2)
    check('undo: restore arg id=601', verb_calls[2].id == 601)
    check('undo: restore arg skill=Average (the old)', verb_calls[2].skill == 'Average')
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All set_skill_unit tests passed.')
