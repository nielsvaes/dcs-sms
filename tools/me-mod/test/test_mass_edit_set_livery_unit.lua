-- Standalone test for mass_edit_forms.set_livery_unit.
-- Tests M._apply + the registered undo handler. The verb is stubbed --
-- we test the form's counting/snapshot/toast/undo-dispatch logic, not
-- the verb's internals.
--
-- The UI-level airframe-uniqueness gating (distinct_airframes > 1 →
-- panel grays out) is not unit-tested -- it lives in panel:set_enabled
-- and is smoke-tested only.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')

-- Stub me_mission for transitive requires.
package.preload['me_mission'] = function() return mock end

-- Stub the verbs module. unit_set_livery records every call and consults
-- a per-test queue of result tables so we can simulate ok / failure paths
-- without touching real DCS.
local verb_calls = {}
local verb_responses = {}  -- queue of result tables (popped in order)
local verb_throws = nil    -- when set to a string, the next call raises with it
local verbs_stub = {}
function verbs_stub.unit_set_livery(args)
    verb_calls[#verb_calls + 1] = { id = args.id, livery = args.livery, name = args.name }
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

local form = require('dcs_sms_me.mass_edit_forms.set_livery_unit')
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

-- Build a synthetic unit table. The form treats unit entities as having
-- unitId + livery_id + type; mass_edit.lua passes the raw mission unit
-- table through.
local function mk_unit(id, name, livery, airframe)
    return {
        unitId    = id,
        name      = name or ('u-' .. tostring(id)),
        livery_id = livery or '',
        type      = airframe or 'F-15C',
    }
end

-- Build a categories map { [entity] = category }. The form gates on
-- applicability.is_applicable so the categories table is required for
-- mixed-category tests.
local function cats_map(pairs_list)
    local out = {}
    for _, p in ipairs(pairs_list) do out[p[1]] = p[2] end
    return out
end

-- Case 1: module exports.
do
    check('scope = unit',                form.scope == 'unit')
    check('title is nonempty string',    type(form.title) == 'string' and #form.title > 0)
    check('_apply is fn',                type(form._apply) == 'function')
    check('new is fn',                   type(form.new) == 'function')
    check('applies_to is a table',       type(form.applies_to) == 'table')
    check('applies_to.plane = true',     form.applies_to and form.applies_to.plane == true)
    check('applies_to.helicopter = true', form.applies_to and form.applies_to.helicopter == true)
end

-- Case 2: empty selection -> nothing_selected, no verb call, no undo.
do
    reset()
    local result = form._apply({}, 'F-15C_default')
    check('empty: changed=0',                result.changed == 0)
    check('empty: nothing_selected',         result.nothing_selected == true)
    check('empty: toast = Nothing selected', result.toast == 'Nothing selected')
    check('empty: sev = warning',            result.sev == 'warning')
    check('empty: 0 verb calls',             #verb_calls == 0)
    check('empty: no undo recorded',         undo.has_record() == false)
end

-- Case 3: missing livery (nil) -> guard, no verb call, no undo.
do
    reset()
    local u = mk_unit(1, 'A', '', 'F-15C')
    local r1 = form._apply({ u }, nil)
    check('no livery (nil): toast = Pick a livery', r1.toast == 'Pick a livery')
    check('no livery (nil): sev = warning',         r1.sev == 'warning')
    check('no livery (nil): 0 verb calls',          #verb_calls == 0)
    check('no livery (nil): no undo recorded',      undo.has_record() == false)

    local r2 = form._apply({ u }, 123)
    check('no livery (number): toast = Pick a livery', r2.toast == 'Pick a livery')
    check('no livery (number): 0 verb calls',          #verb_calls == 0)
end

-- Case 4: 2 planes (same airframe), success -> 2 changed, undo recorded.
do
    reset()
    local u1 = mk_unit(101, 'A', 'old1', 'F-15C')
    local u2 = mk_unit(102, 'B', 'old2', 'F-15C')
    verb_responses[1] = { ok = true, id = 101, name = 'A', livery = 'aggressors' }
    verb_responses[2] = { ok = true, id = 102, name = 'B', livery = 'aggressors' }
    local cats = cats_map({ { u1, 'plane' }, { u2, 'plane' } })
    local result = form._apply({ u1, u2 }, 'aggressors', cats)
    check('success: changed=2',            result.changed == 2)
    check('success: failed=0',             result.failed == 0)
    check('success: not_applicable=0',     result.not_applicable == 0)
    check('success: 2 verb calls',         #verb_calls == 2)
    check('success: verb 1 id=101',        verb_calls[1].id == 101)
    check('success: verb 1 livery=aggressors', verb_calls[1].livery == 'aggressors')
    check('success: verb 2 id=102',        verb_calls[2].id == 102)
    check('success: verb 2 livery=aggressors', verb_calls[2].livery == 'aggressors')
    check('success: toast = "2 livery set"', result.toast == '2 livery set',
          'got ' .. tostring(result.toast))
    check('success: sev = success',        result.sev == 'success')
    check('success: undo recorded',        undo.has_record() == true)
    check('success: changed_rows has 2 entries', #result.changed_rows == 2)
    check('success: changed_rows[1].old = old1', result.changed_rows[1].old == 'old1')
    check('success: changed_rows[2].old = old2', result.changed_rows[2].old == 'old2')
end

-- Case 5: 1 plane + 1 tank (vehicle) -> tank counted as not_applicable,
-- plane gets verb call, toast='1 livery set · 1 not applicable'.
do
    reset()
    local plane = mk_unit(201, 'P', 'old', 'F-15C')
    local tank  = mk_unit(202, 'T', '', 'M-1 Abrams')
    verb_responses[1] = { ok = true, id = 201, name = 'P', livery = 'aggressors' }
    local cats = cats_map({ { plane, 'plane' }, { tank, 'vehicle' } })
    local result = form._apply({ plane, tank }, 'aggressors', cats)
    check('mixed: changed=1',         result.changed == 1)
    check('mixed: failed=0',          result.failed == 0)
    check('mixed: not_applicable=1',  result.not_applicable == 1)
    check('mixed: 1 verb call',       #verb_calls == 1)
    check('mixed: verb arg id=201',   verb_calls[1].id == 201)
    check('mixed: toast = "1 livery set · 1 not applicable"',
          result.toast == '1 livery set · 1 not applicable',
          'got ' .. tostring(result.toast))
    check('mixed: sev = success',     result.sev == 'success')
    check('mixed: undo recorded',     undo.has_record() == true)
end

-- Case 6: already-at-target -> silent skip, no verb calls, no undo;
-- toast = 'No changes', sev='warning'.
do
    reset()
    local u = mk_unit(301, 'X', 'aggressors', 'F-15C')
    local cats = cats_map({ { u, 'plane' } })
    local result = form._apply({ u }, 'aggressors', cats)
    check('already-target: changed=0',           result.changed == 0)
    check('already-target: failed=0',            result.failed == 0)
    check('already-target: not_applicable=0',    result.not_applicable == 0)
    check('already-target: 0 verb calls',        #verb_calls == 0)
    check('already-target: toast = "No changes"', result.toast == 'No changes',
          'got ' .. tostring(result.toast))
    check('already-target: sev = warning',       result.sev == 'warning')
    check('already-target: no undo recorded',    undo.has_record() == false)
end

-- Case 6b: empty-string livery (DCS default) IS valid -- should hit verb,
-- not the guard.
do
    reset()
    local u = mk_unit(351, 'D', 'aggressors', 'F-15C')
    verb_responses[1] = { ok = true, id = 351, name = 'D', livery = '' }
    local cats = cats_map({ { u, 'plane' } })
    local result = form._apply({ u }, '', cats)
    check('empty-livery-arg: changed=1', result.changed == 1)
    check('empty-livery-arg: 1 verb call', #verb_calls == 1)
    check('empty-livery-arg: verb arg livery = ""', verb_calls[1].livery == '')
end

-- Case 7: verb rejection -> failed=1, error toast.
do
    reset()
    local u = mk_unit(401, 'Y', 'old', 'F-15C')
    verb_responses[1] = { ok = false, error = 'unit not found' }
    local cats = cats_map({ { u, 'plane' } })
    local result = form._apply({ u }, 'aggressors', cats)
    check('verb-reject: changed=0', result.changed == 0)
    check('verb-reject: failed=1',  result.failed == 1)
    check('verb-reject: 1 verb call', #verb_calls == 1)
    check('verb-reject: toast = "0 livery set · 1 failed"',
          result.toast == '0 livery set · 1 failed', 'got ' .. tostring(result.toast))
    check('verb-reject: sev = error', result.sev == 'error')
    check('verb-reject: no undo recorded', undo.has_record() == false)
end

-- Case 7b: verb throws -> failed=1 (pcall catches it).
do
    reset()
    local u = mk_unit(411, 'Z', 'old', 'F-15C')
    verb_throws = 'simulated boom'
    local cats = cats_map({ { u, 'plane' } })
    local result = form._apply({ u }, 'aggressors', cats)
    check('verb-throws: changed=0', result.changed == 0)
    check('verb-throws: failed=1',  result.failed == 1)
end

-- Case 8: undo restores via the verb with the OLD livery_id.
do
    reset()
    local u = mk_unit(601, 'Q', 'old_livery', 'F-15C')
    verb_responses[1] = { ok = true, id = 601, name = 'Q', livery = 'new_livery' }
    local cats = cats_map({ { u, 'plane' } })
    local _ = form._apply({ u }, 'new_livery', cats)
    check('undo-prep: 1 verb call', #verb_calls == 1)
    check('undo-prep: undo recorded', undo.has_record() == true)

    -- Now undo. Stub the restore call.
    verb_responses[1] = { ok = true, id = 601, name = 'Q', livery = 'old_livery' }
    local ok = undo.undo()
    check('undo: ok=true', ok == true)
    check('undo: 2 total verb calls', #verb_calls == 2)
    check('undo: restore arg id=601', verb_calls[2].id == 601)
    check('undo: restore arg livery = old_livery', verb_calls[2].livery == 'old_livery')
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All set_livery_unit tests passed.')
