-- Standalone test for mass_edit_forms.set_fuel_pct_unit.
-- Tests M._apply + the registered undo handler. verbs.unit_set_fuel is
-- stubbed, and the per-airframe max_fuel resolver is injected per test
-- via form._set_max_fuel_resolver so we exercise both the "known max"
-- and the current-fuel fallback paths deterministically.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')

package.preload['me_mission'] = function() return mock end

-- Stub the verbs module. unit_set_fuel records every call and consults
-- a per-test queue of result tables so we can simulate ok / failure paths.
local verb_calls = {}
local verb_responses = {}
local verb_throws = nil
local verbs_stub = {}
function verbs_stub.unit_set_fuel(args)
    verb_calls[#verb_calls + 1] = { id = args.id, fuel = args.fuel }
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

package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end

local form = require('dcs_sms_me.mass_edit_forms.set_fuel_pct_unit')
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
    -- Default resolver returns a fixed max for deterministic numeric assertions.
    form._set_max_fuel_resolver(function(u) return 5000 end)
end

-- Tiny helpers to fabricate unit-like rows. The form reads u.unitId,
-- u.type, u.payload.fuel; everything else is irrelevant to _apply.
local function plane(unitId, opts)
    opts = opts or {}
    local u = { unitId = unitId, name = opts.name or ('p-' .. unitId), type = opts.type or 'F-15C' }
    if opts.fuel ~= nil then u.payload = { fuel = opts.fuel } end
    return u
end
local function helo(unitId, opts)
    opts = opts or {}
    local u = { unitId = unitId, name = opts.name or ('h-' .. unitId), type = opts.type or 'Ka-50' }
    if opts.fuel ~= nil then u.payload = { fuel = opts.fuel } end
    return u
end
local function tank(unitId, opts)
    opts = opts or {}
    return { unitId = unitId, name = opts.name or ('t-' .. unitId), type = opts.type or 'M-1 Abrams' }
end

-- Case 1: module exports the expected metadata.
do
    check('scope=unit', form.scope == 'unit')
    check('title is nonempty string', type(form.title) == 'string' and #form.title > 0)
    check('_apply is fn', type(form._apply) == 'function')
    check('new is fn', type(form.new) == 'function')
    check('applies_to.plane=true', form.applies_to and form.applies_to.plane == true)
    check('applies_to.helicopter=true', form.applies_to and form.applies_to.helicopter == true)
    check('_set_max_fuel_resolver is fn', type(form._set_max_fuel_resolver) == 'function')
end

-- Case 2: empty selection → nothing_selected, no verb calls.
do
    reset()
    local result = form._apply({}, 50, {})
    check('empty: changed=0',          result.changed == 0)
    check('empty: nothing_selected',   result.nothing_selected == true)
    check('empty: toast=Nothing selected', result.toast == 'Nothing selected')
    check('empty: sev=warning',        result.sev == 'warning')
    check('empty: 0 verb calls',       #verb_calls == 0)
    check('empty: no undo recorded',   undo.has_record() == false)
end

-- Case 3: invalid pct (nil / -1 / 101) → guard toast, no verb calls.
do
    reset()
    local u = plane(101)
    local r1 = form._apply({ u }, nil, { [u] = 'plane' })
    check('nil pct: toast=Enter 0-100%', r1.toast == 'Enter 0-100%')
    check('nil pct: sev=warning',        r1.sev == 'warning')
    check('nil pct: 0 verb calls',       #verb_calls == 0)
    check('nil pct: no undo recorded',   undo.has_record() == false)

    reset()
    local r2 = form._apply({ u }, -1, { [u] = 'plane' })
    check('-1 pct: toast=Enter 0-100%', r2.toast == 'Enter 0-100%')
    check('-1 pct: 0 verb calls',       #verb_calls == 0)

    reset()
    local r3 = form._apply({ u }, 101, { [u] = 'plane' })
    check('101 pct: toast=Enter 0-100%', r3.toast == 'Enter 0-100%')
    check('101 pct: 0 verb calls',       #verb_calls == 0)
end

-- Case 4: 2 planes with stubbed resolver returning 5000 kg, pct=50 → verb calls with fuel=2500.
do
    reset()
    local u1 = plane(11)
    local u2 = plane(12)
    verb_responses[1] = { ok = true, id = 11, fuel = 2500 }
    verb_responses[2] = { ok = true, id = 12, fuel = 2500 }
    local cats = { [u1] = 'plane', [u2] = 'plane' }
    local result = form._apply({ u1, u2 }, 50, cats)
    check('2 planes: changed=2', result.changed == 2)
    check('2 planes: failed=0',  result.failed == 0)
    check('2 planes: not_applicable=0', result.not_applicable == 0)
    check('2 planes: unresolved=0',     result.unresolved == 0)
    check('2 planes: 2 verb calls', #verb_calls == 2)
    check('2 planes: verb call 1 id=11',  verb_calls[1].id == 11)
    check('2 planes: verb call 1 fuel=2500', verb_calls[1].fuel == 2500,
          'got ' .. tostring(verb_calls[1].fuel))
    check('2 planes: verb call 2 id=12',  verb_calls[2].id == 12)
    check('2 planes: verb call 2 fuel=2500', verb_calls[2].fuel == 2500)
    check('2 planes: toast = "2 fuel set"', result.toast == '2 fuel set',
          'got ' .. tostring(result.toast))
    check('2 planes: sev=success', result.sev == 'success')
    check('2 planes: undo recorded', undo.has_record() == true)
end

-- Case 5: 1 plane + 1 tank with cats → tank not_applicable, plane gets verb call.
do
    reset()
    local p1 = plane(21)
    local t1 = tank(22)
    verb_responses[1] = { ok = true, id = 21, fuel = 1250 }
    local cats = { [p1] = 'plane', [t1] = 'vehicle' }
    local result = form._apply({ p1, t1 }, 25, cats)
    check('mixed: changed=1', result.changed == 1)
    check('mixed: not_applicable=1', result.not_applicable == 1)
    check('mixed: failed=0', result.failed == 0)
    check('mixed: 1 verb call (tank skipped)', #verb_calls == 1)
    check('mixed: verb call id=21', verb_calls[1].id == 21)
    check('mixed: verb call fuel=1250', verb_calls[1].fuel == 1250)
    check('mixed: toast contains "1 fuel set"',
          result.toast:find('1 fuel set') ~= nil, 'got ' .. tostring(result.toast))
    check('mixed: toast contains "1 not applicable"',
          result.toast:find('1 not applicable') ~= nil, 'got ' .. tostring(result.toast))
    check('mixed: sev=success', result.sev == 'success')
end

-- Case 5b: ONLY non-applicable rows → "Nothing applicable".
do
    reset()
    local t1 = tank(31)
    local t2 = tank(32)
    local cats = { [t1] = 'vehicle', [t2] = 'vehicle' }
    local result = form._apply({ t1, t2 }, 50, cats)
    check('only-inapplicable: changed=0', result.changed == 0)
    check('only-inapplicable: not_applicable=2', result.not_applicable == 2)
    check('only-inapplicable: 0 verb calls', #verb_calls == 0)
    check('only-inapplicable: toast=Nothing applicable',
          result.toast == 'Nothing applicable', 'got ' .. tostring(result.toast))
    check('only-inapplicable: sev=warning', result.sev == 'warning')
end

-- Case 6: resolver returns nil → fallback path: verb call uses (pct/100) * u.payload.fuel.
do
    reset()
    form._set_max_fuel_resolver(function(u) return nil end)
    local u = plane(41, { type = 'ModAircraftXYZ', fuel = 3000 })
    verb_responses[1] = { ok = true, id = 41, fuel = 1500 }
    local cats = { [u] = 'plane' }
    local result = form._apply({ u }, 50, cats)
    check('fallback: changed=1', result.changed == 1)
    check('fallback: unresolved=1', result.unresolved == 1,
          'got unresolved=' .. tostring(result.unresolved))
    check('fallback: verb fuel = 50% of u.payload.fuel (1500)',
          verb_calls[1].fuel == 1500, 'got ' .. tostring(verb_calls[1].fuel))
    check('fallback: toast includes "used current-fuel fallback"',
          result.toast:find('used current%-fuel fallback') ~= nil,
          'got ' .. tostring(result.toast))
    check('fallback: sev=success', result.sev == 'success')
end

-- Case 6b: resolver returns nil + no u.payload → fallback uses 0 → verb gets fuel=0.
do
    reset()
    form._set_max_fuel_resolver(function(u) return nil end)
    local u = plane(42, { type = 'ModAircraftXYZ' })  -- no payload
    verb_responses[1] = { ok = true, id = 42, fuel = 0 }
    local cats = { [u] = 'plane' }
    local result = form._apply({ u }, 75, cats)
    check('fallback-nopayload: changed=1', result.changed == 1)
    check('fallback-nopayload: unresolved=1', result.unresolved == 1)
    check('fallback-nopayload: verb fuel=0', verb_calls[1].fuel == 0,
          'got ' .. tostring(verb_calls[1].fuel))
end

-- Case 7: verb rejection (ok=false) → counted as failed, sev='error' when all fail.
do
    reset()
    local u = plane(51)
    verb_responses[1] = { ok = false, error = 'bad' }
    local cats = { [u] = 'plane' }
    local result = form._apply({ u }, 50, cats)
    check('verb-reject: changed=0', result.changed == 0)
    check('verb-reject: failed=1',  result.failed == 1)
    check('verb-reject: toast contains "0 fuel set"',
          result.toast:find('0 fuel set') ~= nil, 'got ' .. tostring(result.toast))
    check('verb-reject: toast contains "1 failed"',
          result.toast:find('1 failed') ~= nil, 'got ' .. tostring(result.toast))
    check('verb-reject: sev=error', result.sev == 'error')
    check('verb-reject: no undo recorded', undo.has_record() == false)
end

-- Case 7b: helicopter is applicable too.
do
    reset()
    local h = helo(61)
    verb_responses[1] = { ok = true, id = 61, fuel = 2500 }
    local cats = { [h] = 'helicopter' }
    local result = form._apply({ h }, 50, cats)
    check('helo: changed=1', result.changed == 1)
    check('helo: verb call id=61', verb_calls[1].id == 61)
    check('helo: verb call fuel=2500', verb_calls[1].fuel == 2500)
end

-- Case 8: undo restores via verb with OLD value.
do
    reset()
    local u1 = plane(71, { fuel = 4000 })  -- old payload.fuel = 4000
    local u2 = plane(72, { fuel = 1000 })  -- old payload.fuel = 1000
    verb_responses[1] = { ok = true, id = 71, fuel = 2500 }
    verb_responses[2] = { ok = true, id = 72, fuel = 2500 }
    local cats = { [u1] = 'plane', [u2] = 'plane' }
    form._apply({ u1, u2 }, 50, cats)
    check('undo-setup: 2 forward verb calls', #verb_calls == 2)
    check('undo-setup: undo recorded', undo.has_record() == true)

    verb_responses[1] = { ok = true, id = 71, fuel = 4000 }
    verb_responses[2] = { ok = true, id = 72, fuel = 1000 }
    local ok = undo.undo()
    check('undo: ok=true', ok == true)
    check('undo: 2 more verb calls (4 total)', #verb_calls == 4)
    check('undo: verb 3 restores u1 to 4000',
          verb_calls[3].id == 71 and verb_calls[3].fuel == 4000,
          'got id=' .. tostring(verb_calls[3].id) .. ', fuel=' .. tostring(verb_calls[3].fuel))
    check('undo: verb 4 restores u2 to 1000',
          verb_calls[4].id == 72 and verb_calls[4].fuel == 1000,
          'got id=' .. tostring(verb_calls[4].id) .. ', fuel=' .. tostring(verb_calls[4].fuel))
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All set_fuel_pct_unit tests passed.')
