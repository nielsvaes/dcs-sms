-- Standalone test for set_warehouse_airbase._apply.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- In-memory warehouse store.
local warehouse_state = {}

package.preload['dcs_sms_me.warehouse_ops'] = function()
    return {
        extract = function(id)
            local e = warehouse_state[id]
            if not e then return nil end
            -- Shallow clone good enough for the test.
            local out = {}
            for k, v in pairs(e) do
                if type(v) == 'table' then
                    local nested = {}
                    for k2, v2 in pairs(v) do nested[k2] = v2 end
                    out[k] = nested
                else
                    out[k] = v
                end
            end
            return out
        end,
        apply = function(id, entry)
            warehouse_state[id] = entry
            return true
        end,
    }
end

local undo_records = {}
package.preload['dcs_sms_me.undo'] = function()
    local handlers = {}
    return {
        register_handler = function(name, fn) handlers[name] = fn end,
        record_generic   = function(name, payload) undo_records[#undo_records + 1] = { name = name, payload = payload } end,
        _trigger         = function(name, payload) return handlers[name] and handlers[name](payload) end,
    }
end

local form = require('dcs_sms_me.mass_edit_forms.set_warehouse_airbase')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Reset and seed warehouse for two airbases.
warehouse_state = {
    [12] = {
        unlimitedAircrafts = false, unlimitedMunitions = false,
        unlimitedFuel = false, unlimitedAviationFuel = false,
        aircrafts  = { ['F-16C_50'] = { count = 20 } },
        weapons    = { ['AIM-120C']  = { count = 300 } },
        gasoline   = 999,
        jet_fuel   = 999,
    },
    [27] = {
        unlimitedAircrafts = false, unlimitedMunitions = false,
        unlimitedFuel = false, unlimitedAviationFuel = false,
        aircrafts  = { ['Su-27'] = { count = 10 } },
        weapons    = { ['R-77']  = { count = 100 } },
        gasoline   = 500,
    },
}

-- Reference the tri-state constants the same way the form does.
local tsb = require('dcs_sms_me.tri_state_button')
local LEAVE = tsb.STATE_LEAVE
local ON    = tsb.STATE_ON
local OFF   = tsb.STATE_OFF

-- LEAVE on all three → no mutation, no undo record.
local entities = {
    { id = 12, name = 'Anapa' },
    { id = 27, name = 'Krasnodar' },
}
local res = form._apply(entities, { aircraft = LEAVE, liquids = LEAVE, equipment = LEAVE })
check('LEAVE/LEAVE/LEAVE is no-op (ok=false)', res and res.ok == false)
check('LEAVE no undo record produced', #undo_records == 0)
check('warehouse untouched',
      warehouse_state[12].aircrafts['F-16C_50'].count == 20 and
      warehouse_state[12].weapons['AIM-120C'].count    == 300)

-- Aircraft=ON (unlimited), others LEAVE: just flip the flag, counts untouched.
form._apply(entities, { aircraft = ON, liquids = LEAVE, equipment = LEAVE })
check('Anapa unlimitedAircrafts true after ON',
      warehouse_state[12].unlimitedAircrafts == true)
check('Anapa aircraft counts NOT zeroed on ON',
      warehouse_state[12].aircrafts['F-16C_50'].count == 20)
check('Krasnodar unlimitedAircrafts true', warehouse_state[27].unlimitedAircrafts == true)
check('one undo record', #undo_records == 1)

-- Aircraft=OFF (empty), Equipment=OFF, Liquids=OFF: zero everything.
undo_records = {}
form._apply(entities, { aircraft = OFF, liquids = OFF, equipment = OFF })
check('Anapa aircraft counts zeroed', warehouse_state[12].aircrafts['F-16C_50'].count == 0)
check('Anapa weapons counts zeroed',  warehouse_state[12].weapons['AIM-120C'].count   == 0)
check('Anapa gasoline zeroed',        warehouse_state[12].gasoline == 0)
check('Anapa jet_fuel zeroed',        warehouse_state[12].jet_fuel == 0)
check('Anapa unlimitedAircrafts false after OFF', warehouse_state[12].unlimitedAircrafts == false)
check('Anapa unlimitedMunitions false',           warehouse_state[12].unlimitedMunitions == false)
check('Anapa unlimitedFuel false',                warehouse_state[12].unlimitedFuel      == false)

-- Undo restores prior state — including the unlimited flag flipped in the
-- ON test above.
local undo_mod = require('dcs_sms_me.undo')
undo_mod._trigger('mass_edit.set_warehouse_airbase', undo_records[1].payload)
check('undo restores Anapa aircraft count',  warehouse_state[12].aircrafts['F-16C_50'].count == 20)
check('undo restores Anapa gasoline',        warehouse_state[12].gasoline == 999)
check('undo restores Anapa unlimitedAircrafts true', warehouse_state[12].unlimitedAircrafts == true)

if failures > 0 then
    print('FAILED: ' .. failures .. ' failures')
    os.exit(1)
end
print('All set_warehouse_airbase tests passed.')
