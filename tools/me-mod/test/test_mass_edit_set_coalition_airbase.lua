-- Standalone test for set_coalition_airbase._apply and undo handler.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Track calls to verbs.airbase_set_coalition
local verb_calls = {}
local airbases_coalition_state = {
    ['Anapa']     = 'red',
    ['Krasnodar'] = 'blue',
    ['Sukhumi']   = 'neutrals',
}

package.preload['dcs_sms_me.verbs'] = function()
    return {
        airbase_set_coalition = function(args)
            verb_calls[#verb_calls + 1] = { name = args.name, coalition = args.coalition }
            local prev = airbases_coalition_state[args.name]
            airbases_coalition_state[args.name] = args.coalition
            return { ok = true, previous_coalition = prev, name = args.name, coalition = args.coalition }
        end,
    }
end

-- Stub undo as a passthrough recorder.
local undo_records = {}
package.preload['dcs_sms_me.undo'] = function()
    local handlers = {}
    return {
        register_handler = function(name, fn) handlers[name] = fn end,
        record_generic   = function(name, payload) undo_records[#undo_records + 1] = { name = name, payload = payload } end,
        _trigger         = function(name, payload) return handlers[name] and handlers[name](payload) end,
    }
end

local form = require('dcs_sms_me.mass_edit_forms.set_coalition_airbase')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local entities = {
    { id = 12, name = 'Anapa',     coalition = 'red',      north = 1, east = 2 },
    { id = 27, name = 'Krasnodar', coalition = 'blue',     north = 3, east = 4 },
    { id = 88, name = 'Sukhumi',   coalition = 'neutrals', north = 5, east = 6 },
}

-- Apply Blue to all three.
local result = form._apply(entities, 'blue')

check('result.ok',           result and result.ok == true)
check('three verb calls',    #verb_calls == 3)
check('Anapa was set to blue',     verb_calls[1].coalition == 'blue' and verb_calls[1].name == 'Anapa')
check('Krasnodar was set to blue', verb_calls[2].coalition == 'blue' and verb_calls[2].name == 'Krasnodar')
check('Sukhumi was set to blue',   verb_calls[3].coalition == 'blue' and verb_calls[3].name == 'Sukhumi')
check('toast mentions 3 airbases', result.toast and result.toast:find('3') ~= nil,
      'got toast: ' .. tostring(result.toast))

check('exactly one undo record', #undo_records == 1)
check('undo handler is mass_edit.set_coalition_airbase',
      undo_records[1].name == 'mass_edit.set_coalition_airbase')

-- Trigger the undo handler — should restore each airbase's prior coalition.
verb_calls = {}
local undo_mod = require('dcs_sms_me.undo')
undo_mod._trigger('mass_edit.set_coalition_airbase', undo_records[1].payload)
check('undo issued three verb calls', #verb_calls == 3)
check('Anapa was restored to red',          verb_calls[1].coalition == 'red')
check('Krasnodar was restored to blue',     verb_calls[2].coalition == 'blue')
check('Sukhumi was restored to neutrals',   verb_calls[3].coalition == 'neutrals')

if failures > 0 then
    print('FAILED: ' .. failures .. ' failures')
    os.exit(1)
end
print('All set_coalition_airbase tests passed.')
