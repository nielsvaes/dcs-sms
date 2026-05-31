-- Standalone test for mass_edit_forms.set_heading_unit.
-- Two-mode form (Absolute + Delta). Tests both _apply_* functions and the
-- shared undo handler. The unit_set_heading verb is stubbed -- we test
-- the form's normalization/snapshot/dispatch logic, not the verb's
-- internals.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')
package.preload['me_mission'] = function() return mock end

-- Stub verbs.unit_set_heading. Records each call and pops a queued result.
local verb_calls = {}
local verb_responses = {}
local verbs_stub = {}
function verbs_stub.unit_set_heading(args)
    verb_calls[#verb_calls + 1] = { id = args.id, name = args.name, heading_deg = args.heading_deg }
    local r = table.remove(verb_responses, 1)
    if r == nil then return { ok = false, error = 'no stubbed response' } end
    return r
end
package.preload['dcs_sms_me.verbs'] = function() return verbs_stub end

-- Stub selection for undo.lua's transitive prefab_ops requires.
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end

local form = require('dcs_sms_me.mass_edit_forms.set_heading_unit')
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

-- Build a synthetic unit row (heading in radians, mirroring the real ME tree).
local _unit_id = 0
local function make_unit(heading_rad)
    _unit_id = _unit_id + 1
    return { unitId = _unit_id, name = 'unit-' .. _unit_id, heading = heading_rad or 0 }
end

-- Case 1: module exports.
do
    check('scope=unit',                  form.scope == 'unit')
    check('title is nonempty string',    type(form.title) == 'string' and #form.title > 0)
    check('applies_to is nil (universal)', form.applies_to == nil)
    check('_apply_absolute is fn',       type(form._apply_absolute) == 'function')
    check('_apply_delta is fn',          type(form._apply_delta) == 'function')
    check('new is fn',                   type(form.new) == 'function')
end

-- Case 2: _apply_absolute -- empty selection.
do
    reset()
    local result = form._apply_absolute({}, 90)
    check('abs empty: changed=0',           result.changed == 0)
    check('abs empty: nothing_selected',    result.nothing_selected == true)
    check('abs empty: toast = Nothing selected', result.toast == 'Nothing selected')
    check('abs empty: sev = warning',       result.sev == 'warning')
    check('abs empty: 0 verb calls',        #verb_calls == 0)
    check('abs empty: no undo',             undo.has_record() == false)
end

-- Case 3: _apply_absolute -- missing / non-number deg.
do
    reset()
    local u = make_unit(0)
    local r1 = form._apply_absolute({ u }, nil)
    check('abs guard (nil): toast = Enter heading (°)', r1.toast == 'Enter heading (°)')
    check('abs guard (nil): sev = warning',  r1.sev == 'warning')
    check('abs guard (nil): 0 verb calls',   #verb_calls == 0)
    local r2 = form._apply_absolute({ u }, 'oops')
    check('abs guard (str): toast = Enter heading (°)', r2.toast == 'Enter heading (°)')
    check('abs guard (str): 0 verb calls',   #verb_calls == 0)
end

-- Case 4: _apply_absolute -- 3 units, success, normalize 450 -> 90.
do
    reset()
    local u1, u2, u3 = make_unit(0), make_unit(math.rad(10)), make_unit(math.rad(20))
    verb_responses[1] = { ok = true }
    verb_responses[2] = { ok = true }
    verb_responses[3] = { ok = true }
    local result = form._apply_absolute({ u1, u2, u3 }, 450)
    check('abs 3-units: changed=3',          result.changed == 3)
    check('abs 3-units: failed=0',           result.failed == 0)
    check('abs 3-units: 3 verb calls',       #verb_calls == 3)
    check('abs 3-units: verb[1].id matches', verb_calls[1].id == u1.unitId)
    check('abs 3-units: verb[1].heading_deg = 90 (normalized from 450)',
          verb_calls[1].heading_deg == 90, 'got ' .. tostring(verb_calls[1].heading_deg))
    check('abs 3-units: verb[2].heading_deg = 90',
          verb_calls[2].heading_deg == 90, 'got ' .. tostring(verb_calls[2].heading_deg))
    check('abs 3-units: verb[3].heading_deg = 90',
          verb_calls[3].heading_deg == 90, 'got ' .. tostring(verb_calls[3].heading_deg))
    check('abs 3-units: toast contains "3 heading set"',
          result.toast and result.toast:find('3 heading set') ~= nil,
          'got ' .. tostring(result.toast))
    check('abs 3-units: sev = success',      result.sev == 'success')
    check('abs 3-units: undo recorded',      undo.has_record() == true)
end

-- Case 5: _apply_absolute -- negative input normalizes (-30 -> 330).
do
    reset()
    local u = make_unit(0)
    verb_responses[1] = { ok = true }
    local result = form._apply_absolute({ u }, -30)
    check('abs negative: changed=1',          result.changed == 1)
    check('abs negative: verb.heading_deg = 330',
          verb_calls[1].heading_deg == 330, 'got ' .. tostring(verb_calls[1].heading_deg))
end

-- Case 6: _apply_delta -- unit at 0 rad, delta=+90 -> verb gets 90.
do
    reset()
    local u = make_unit(0)
    verb_responses[1] = { ok = true }
    local result = form._apply_delta({ u }, 90)
    check('delta 0+90: changed=1',          result.changed == 1)
    check('delta 0+90: verb.heading_deg = 90',
          verb_calls[1].heading_deg == 90, 'got ' .. tostring(verb_calls[1].heading_deg))
end

-- Case 7: _apply_delta -- unit at 350°, delta=+45 -> verb gets 35 (wrap).
do
    reset()
    local u = make_unit(math.rad(350))
    verb_responses[1] = { ok = true }
    local result = form._apply_delta({ u }, 45)
    check('delta 350+45: changed=1',         result.changed == 1)
    -- Float-math tolerant compare.
    local got = verb_calls[1].heading_deg
    check('delta 350+45: verb.heading_deg ≈ 35',
          type(got) == 'number' and math.abs(got - 35) < 1e-6,
          'got ' .. tostring(got))
end

-- Case 8: _apply_delta -- unit at 10°, delta=-30 -> verb gets 340 (wrap).
do
    reset()
    local u = make_unit(math.rad(10))
    verb_responses[1] = { ok = true }
    local result = form._apply_delta({ u }, -30)
    check('delta 10-30: changed=1',          result.changed == 1)
    local got = verb_calls[1].heading_deg
    check('delta 10-30: verb.heading_deg ≈ 340',
          type(got) == 'number' and math.abs(got - 340) < 1e-6,
          'got ' .. tostring(got))
end

-- Case 9: Undo restores via verb with old rad → deg conversion.
-- Seed via _apply_absolute on a unit whose original heading=math.rad(120).
do
    reset()
    local u = make_unit(math.rad(120))
    verb_responses[1] = { ok = true }
    local result = form._apply_absolute({ u }, 270)
    check('undo seed: applied (changed=1)',  result.changed == 1)
    check('undo seed: verb.heading_deg = 270', verb_calls[1].heading_deg == 270)
    check('undo seed: undo has record',      undo.has_record() == true)

    -- Now undo: should call the verb again with heading_deg ≈ 120.
    verb_responses[1] = { ok = true }
    local ok = undo.undo()
    check('undo: ok=true',                   ok == true)
    check('undo: verb called once more',     #verb_calls == 2)
    local got = verb_calls[2].heading_deg
    check('undo: verb.heading_deg ≈ 120',
          type(got) == 'number' and math.abs(got - 120) < 1e-6,
          'got ' .. tostring(got))
end

-- Case 10: _apply_delta -- empty selection guard.
do
    reset()
    local r = form._apply_delta({}, 45)
    check('delta empty: nothing_selected',   r.nothing_selected == true)
    check('delta empty: 0 verb calls',       #verb_calls == 0)
end

-- Case 11: _apply_delta -- non-number guard.
do
    reset()
    local u = make_unit(0)
    local r = form._apply_delta({ u }, nil)
    check('delta guard: toast = Enter delta (°)', r.toast == 'Enter delta (°)')
    check('delta guard: sev = warning',      r.sev == 'warning')
    check('delta guard: 0 verb calls',       #verb_calls == 0)
end

-- Case 12: _apply_absolute -- verb rejection (ok=false) counts as failed.
do
    reset()
    local u = make_unit(0)
    verb_responses[1] = { ok = false, error = 'unit not found' }
    local result = form._apply_absolute({ u }, 90)
    check('abs reject: failed=1',            result.failed == 1)
    check('abs reject: changed=0',           result.changed == 0)
    check('abs reject: sev = error',         result.sev == 'error')
    check('abs reject: no undo recorded',    undo.has_record() == false)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All set_heading_unit tests passed.')
