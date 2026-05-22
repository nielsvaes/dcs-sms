-- Standalone test for selection.snapshot_mission('airbase').

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Stub me_mission with a minimal mission tree containing AirportsEquipment.
package.preload['me_mission'] = function()
    return {
        mission = {
            AirportsEquipment = {
                airports = {
                    [12] = { coalition = 'red' },
                    [27] = { coalition = 'blue' },
                    [88] = { coalition = 'neutrals' },
                },
            },
            -- Empty coalition table; snapshot_mission's category-index builder
            -- walks it but the airbase branch doesn't use the result.
            coalition = { red = { country = {} }, blue = { country = {} } },
        },
    }
end

-- Stub Mission.AirdromeController with three airdromes whose
-- airdrome_numbers match the AirportsEquipment keys above.
package.preload['Mission.AirdromeController'] = function()
    local airdromes = {
        { x = 100000, y = 200000, _name = 'Anapa-Vityazevo', _num = 12 },
        { x = 300000, y = 400000, _name = 'Krasnodar-Center', _num = 27 },
        { x = 500000, y = 600000, _name = 'Some-Strip',       _num = 88 },
    }
    for _, ad in ipairs(airdromes) do
        ad.getName            = function(self) return self._name end
        ad.getAirdromeNumber  = function(self) return self._num end
    end
    return { getAirdromes = function() return airdromes end }
end

local selection = require('dcs_sms_me.selection')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local snap = selection.snapshot_mission('airbase')
check('snapshot returns ok=true', snap.ok == true, 'got ok=' .. tostring(snap.ok) .. ' err=' .. tostring(snap.error))
check('snapshot scope is airbase', snap.scope == 'airbase')
check('pool has 3 entries', #snap.pool == 3, 'got ' .. #snap.pool)

local by_name = {}
for _, e in ipairs(snap.pool) do by_name[e.name] = e end

check('Anapa entry exists', by_name['Anapa-Vityazevo'] ~= nil)
check('Anapa.id is 12',     by_name['Anapa-Vityazevo'].id == 12)
check('Anapa.coalition red',by_name['Anapa-Vityazevo'].coalition == 'red')
check('Anapa.north is 100000', by_name['Anapa-Vityazevo'].north == 100000)
check('Anapa.east is 200000',  by_name['Anapa-Vityazevo'].east  == 200000)

check('Krasnodar.coalition blue',     by_name['Krasnodar-Center'].coalition == 'blue')
check('Some-Strip.coalition neutrals',by_name['Some-Strip'].coalition       == 'neutrals')

-- Stable-ref check: a second snapshot must return the SAME table refs per
-- airdrome_number so W.checked entries survive pool rebuilds.
local snap2 = selection.snapshot_mission('airbase')
local by_name2 = {}
for _, e in ipairs(snap2.pool) do by_name2[e.name] = e end
check('entry table refs are stable across snapshots',
      by_name['Anapa-Vityazevo'] == by_name2['Anapa-Vityazevo'],
      'cache should reuse the same row table for the same airdrome_number')

-- parent_map: airbase has no parent, so parent_map[entry] = entry.
check('parent_map[anapa] == anapa',
      snap.parent_map[by_name['Anapa-Vityazevo']] == by_name['Anapa-Vityazevo'])

if failures > 0 then
    print('FAILED: ' .. failures .. ' failures')
    os.exit(1)
end
print('All selection.snapshot_airbases tests passed.')
