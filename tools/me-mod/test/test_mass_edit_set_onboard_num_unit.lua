-- Standalone test for mass_edit_forms.set_onboard_num_unit.
-- Tests M._apply_sequential + M._apply_random + the shared undo handler.
-- The verb is stubbed -- we test the form's counting / snapshot / toast /
-- undo-dispatch logic, not the verb's internals.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')

-- Stub me_mission for transitive requires.
package.preload['me_mission'] = function() return mock end

-- Stub the verb. unit_set_onboard_num records every call and consults a
-- per-test queue of result tables so we can simulate ok / failure without
-- touching real DCS.
local verb_calls, verb_responses = {}, {}
local verbs_stub = {}
function verbs_stub.unit_set_onboard_num(args)
    verb_calls[#verb_calls + 1] = { id = args.id, onboard_num = args.onboard_num }
    local r = table.remove(verb_responses, 1)
    if r == nil then return { ok = false, error = 'no stubbed response' } end
    return r
end
package.preload['dcs_sms_me.verbs'] = function() return verbs_stub end

-- Stub selection for undo.lua's transitive prefab_ops requires.
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end

local form = require('dcs_sms_me.mass_edit_forms.set_onboard_num_unit')
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

-- Helper: build a synthetic unit (we don't need the full mock for the
-- form's logic -- the verb is stubbed, so unitId / type / onboard_num are
-- all the fields it inspects).
local function make_unit(opts)
    opts = opts or {}
    return {
        unitId = opts.unitId or 1,
        name = opts.name or 'u',
        type = opts.type or 'F-16C_50',
        onboard_num = opts.onboard_num,
    }
end

-- Helper: build a categories map { entity = category_string }.
local function cats_map(pairs_list)
    local out = {}
    for _, p in ipairs(pairs_list) do out[p[1]] = p[2] end
    return out
end

-- ---------------------------------------------------------------------------
-- Case 1: module exports.
-- ---------------------------------------------------------------------------
do
    check('scope=unit',                form.scope == 'unit')
    check('title is nonempty string',  type(form.title) == 'string' and #form.title > 0)
    check('_apply_sequential is fn',   type(form._apply_sequential) == 'function')
    check('_apply_random is fn',       type(form._apply_random) == 'function')
    check('new is fn',                 type(form.new) == 'function')
    check('applies_to = {plane=true}', form.applies_to and form.applies_to.plane == true)
    check('applies_to has no helicopter', not (form.applies_to and form.applies_to.helicopter))
    check('applies_to has no vehicle',    not (form.applies_to and form.applies_to.vehicle))
end

-- ---------------------------------------------------------------------------
-- Case 2: _apply_sequential -- empty selection -> nothing_selected.
-- ---------------------------------------------------------------------------
do
    reset()
    local result = form._apply_sequential({}, '010', {})
    check('empty: changed=0',                  result.changed == 0)
    check('empty: nothing_selected',           result.nothing_selected == true)
    check('empty: toast = Nothing selected',   result.toast == 'Nothing selected')
    check('empty: sev = warning',              result.sev == 'warning')
    check('empty: 0 verb calls',               #verb_calls == 0)
    check('empty: no undo recorded',           undo.has_record() == false)
end

-- ---------------------------------------------------------------------------
-- Case 3: _apply_sequential -- invalid start string -> guard toast.
-- ---------------------------------------------------------------------------
do
    reset()
    local u = make_unit({ unitId = 1 })
    local cats = cats_map({ { u, 'plane' } })

    local r1 = form._apply_sequential({ u }, nil, cats)
    check('nil start: toast = Enter a number', r1.toast == 'Enter a number')
    check('nil start: sev = warning',           r1.sev == 'warning')
    check('nil start: 0 verb calls',            #verb_calls == 0)

    local r2 = form._apply_sequential({ u }, '', cats)
    check('empty start: toast = Enter a number', r2.toast == 'Enter a number')
    check('empty start: 0 verb calls',            #verb_calls == 0)

    local r3 = form._apply_sequential({ u }, 'abc', cats)
    check('non-numeric: toast = Enter a number', r3.toast == 'Enter a number')
    check('non-numeric: 0 verb calls',            #verb_calls == 0)
end

-- ---------------------------------------------------------------------------
-- Case 4: _apply_sequential -- 3 planes, start_str='010' -> '010','011','012'.
-- ---------------------------------------------------------------------------
do
    reset()
    local u1 = make_unit({ unitId = 11, onboard_num = '001' })
    local u2 = make_unit({ unitId = 12, onboard_num = '002' })
    local u3 = make_unit({ unitId = 13, onboard_num = '003' })
    local cats = cats_map({ { u1, 'plane' }, { u2, 'plane' }, { u3, 'plane' } })

    verb_responses[1] = { ok = true, id = 11, onboard_num = '010' }
    verb_responses[2] = { ok = true, id = 12, onboard_num = '011' }
    verb_responses[3] = { ok = true, id = 13, onboard_num = '012' }

    local result = form._apply_sequential({ u1, u2, u3 }, '010', cats)
    check('seq010: changed=3',            result.changed == 3)
    check('seq010: failed=0',             result.failed == 0)
    check('seq010: not_applicable=0',     result.not_applicable == 0)
    check('seq010: 3 verb calls',         #verb_calls == 3)
    check('seq010: call1 id=11',          verb_calls[1].id == 11)
    check('seq010: call1 onboard=010',    verb_calls[1].onboard_num == '010')
    check('seq010: call2 onboard=011',    verb_calls[2].onboard_num == '011')
    check('seq010: call3 onboard=012',    verb_calls[3].onboard_num == '012')
    check('seq010: toast contains "3"',   result.toast:find('3') ~= nil,
          'got ' .. tostring(result.toast))
    check('seq010: toast contains "set"', result.toast:find('set') ~= nil,
          'got ' .. tostring(result.toast))
    check('seq010: sev = success',        result.sev == 'success')
    check('seq010: undo recorded',        undo.has_record() == true)
end

-- ---------------------------------------------------------------------------
-- Case 5: _apply_sequential -- 3 planes, start_str='5' -> '5','6','7'.
-- (Padding inferred from input width: '5' is 1 char, no leading zeros.)
-- ---------------------------------------------------------------------------
do
    reset()
    local u1 = make_unit({ unitId = 21 })
    local u2 = make_unit({ unitId = 22 })
    local u3 = make_unit({ unitId = 23 })
    local cats = cats_map({ { u1, 'plane' }, { u2, 'plane' }, { u3, 'plane' } })

    verb_responses[1] = { ok = true, id = 21, onboard_num = '5' }
    verb_responses[2] = { ok = true, id = 22, onboard_num = '6' }
    verb_responses[3] = { ok = true, id = 23, onboard_num = '7' }

    local result = form._apply_sequential({ u1, u2, u3 }, '5', cats)
    check('seq5: changed=3',           result.changed == 3)
    check('seq5: 3 verb calls',        #verb_calls == 3)
    check('seq5: call1 onboard=5',     verb_calls[1].onboard_num == '5')
    check('seq5: call2 onboard=6',     verb_calls[2].onboard_num == '6')
    check('seq5: call3 onboard=7',     verb_calls[3].onboard_num == '7')
end

-- ---------------------------------------------------------------------------
-- Case 6: _apply_sequential -- 2 planes + 1 tank. Tank is inapplicable;
-- planes get '010', '011'; not_applicable=1; toast contains "not applicable".
-- ---------------------------------------------------------------------------
do
    reset()
    local p1 = make_unit({ unitId = 31, type = 'F-16C_50' })
    local tank = make_unit({ unitId = 32, type = 'T-90' })
    local p2 = make_unit({ unitId = 33, type = 'F-16C_50' })
    -- Note: order in entities matters for "applicable-only" indexing.
    local cats = cats_map({ { p1, 'plane' }, { tank, 'vehicle' }, { p2, 'plane' } })

    verb_responses[1] = { ok = true, id = 31, onboard_num = '010' }
    verb_responses[2] = { ok = true, id = 33, onboard_num = '011' }

    local result = form._apply_sequential({ p1, tank, p2 }, '010', cats)
    check('mixed: changed=2',         result.changed == 2)
    check('mixed: not_applicable=1',  result.not_applicable == 1)
    check('mixed: failed=0',          result.failed == 0)
    check('mixed: 2 verb calls (tank skipped)', #verb_calls == 2)
    check('mixed: call1 id=31 (plane)',         verb_calls[1].id == 31)
    check('mixed: call1 onboard=010',           verb_calls[1].onboard_num == '010')
    check('mixed: call2 id=33 (plane)',         verb_calls[2].id == 33)
    check('mixed: call2 onboard=011 (applicable-only index)',
          verb_calls[2].onboard_num == '011')
    check('mixed: toast contains "not applicable"',
          result.toast:find('not applicable') ~= nil,
          'got ' .. tostring(result.toast))
end

-- ---------------------------------------------------------------------------
-- Case 7: _apply_random -- 5 planes -> all 5 verb calls, each a 3-char
-- digit string, all values distinct.
-- ---------------------------------------------------------------------------
do
    reset()
    local units = {}
    local cats_list = {}
    for i = 1, 5 do
        local u = make_unit({ unitId = 100 + i })
        units[i] = u
        cats_list[i] = { u, 'plane' }
        verb_responses[i] = { ok = true, id = 100 + i, onboard_num = '???' }
    end
    local cats = cats_map(cats_list)

    local result = form._apply_random(units, cats)
    check('rand: changed=5',          result.changed == 5)
    check('rand: not_applicable=0',   result.not_applicable == 0)
    check('rand: 5 verb calls',       #verb_calls == 5)

    local seen = {}
    local all_3_digits = true
    local all_distinct = true
    for i = 1, 5 do
        local s = verb_calls[i].onboard_num
        if type(s) ~= 'string' or #s ~= 3 or not s:match('^%d%d%d$') then
            all_3_digits = false
        end
        if seen[s] then all_distinct = false end
        seen[s] = true
    end
    check('rand: every onboard_num is a 3-char digit string', all_3_digits)
    check('rand: all 5 values distinct',                       all_distinct)
end

-- ---------------------------------------------------------------------------
-- Case 8: undo restores via verb with the old onboard_num string.
-- ---------------------------------------------------------------------------
do
    reset()
    local u1 = make_unit({ unitId = 41, onboard_num = '777' })
    local u2 = make_unit({ unitId = 42, onboard_num = '888' })
    local cats = cats_map({ { u1, 'plane' }, { u2, 'plane' } })

    verb_responses[1] = { ok = true, id = 41, onboard_num = '010' }
    verb_responses[2] = { ok = true, id = 42, onboard_num = '011' }
    form._apply_sequential({ u1, u2 }, '010', cats)
    check('undo-setup: undo recorded', undo.has_record() == true)
    check('undo-setup: 2 verb calls',  #verb_calls == 2)

    -- Now undo. The handler should call the verb twice more, restoring the
    -- old onboard_num values.
    verb_responses[1] = { ok = true, id = 41, onboard_num = '777' }
    verb_responses[2] = { ok = true, id = 42, onboard_num = '888' }
    local ok = undo.undo()
    check('undo: ok=true',                   ok == true)
    check('undo: 4 verb calls total',        #verb_calls == 4)
    check('undo: call3 id=41',               verb_calls[3].id == 41)
    check('undo: call3 onboard=777 (old)',   verb_calls[3].onboard_num == '777')
    check('undo: call4 id=42',               verb_calls[4].id == 42)
    check('undo: call4 onboard=888 (old)',   verb_calls[4].onboard_num == '888')
end

-- ---------------------------------------------------------------------------
-- Case 9: undo with nil/empty old value -> restored as '0' (verb rejects '').
-- ---------------------------------------------------------------------------
do
    reset()
    local u = make_unit({ unitId = 51, onboard_num = nil })  -- no initial onboard_num
    local cats = cats_map({ { u, 'plane' } })

    verb_responses[1] = { ok = true, id = 51, onboard_num = '010' }
    form._apply_sequential({ u }, '010', cats)
    check('undo-nil: undo recorded', undo.has_record() == true)

    verb_responses[1] = { ok = true, id = 51, onboard_num = '0' }
    local ok = undo.undo()
    check('undo-nil: ok=true',          ok == true)
    check('undo-nil: 2 verb calls total', #verb_calls == 2)
    check('undo-nil: call2 onboard="0" (verb rejects empty)',
          verb_calls[2].onboard_num == '0')
end

-- ---------------------------------------------------------------------------
-- Case 10: _apply_sequential -- all rows inapplicable -> Nothing applicable.
-- ---------------------------------------------------------------------------
do
    reset()
    local t1 = make_unit({ unitId = 61, type = 'T-90' })
    local t2 = make_unit({ unitId = 62, type = 'T-72' })
    local cats = cats_map({ { t1, 'vehicle' }, { t2, 'vehicle' } })

    local result = form._apply_sequential({ t1, t2 }, '010', cats)
    check('all-inappl: changed=0',         result.changed == 0)
    check('all-inappl: not_applicable=2',  result.not_applicable == 2)
    check('all-inappl: 0 verb calls',      #verb_calls == 0)
    check('all-inappl: toast = "Nothing applicable"',
          result.toast == 'Nothing applicable',
          'got ' .. tostring(result.toast))
    check('all-inappl: sev = warning',     result.sev == 'warning')
end

-- ---------------------------------------------------------------------------
-- Case 11: _apply_random -- empty selection -> nothing_selected.
-- ---------------------------------------------------------------------------
do
    reset()
    local result = form._apply_random({}, {})
    check('rand-empty: changed=0',                  result.changed == 0)
    check('rand-empty: nothing_selected',           result.nothing_selected == true)
    check('rand-empty: toast = Nothing selected',   result.toast == 'Nothing selected')
    check('rand-empty: 0 verb calls',               #verb_calls == 0)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All set_onboard_num_unit tests passed.')
