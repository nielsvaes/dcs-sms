-- Standalone test for the airbase-marquee integration in mass_edit.lua.
-- Exercises the callback directly (no real ME / dxgui required).

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Stub airbase_detect to return canned hits regardless of rect.
local detect_hits = {}
package.preload['dcs_sms_me.airbase_detect'] = function()
    return {
        airbases_in_rect = function(start_xy, end_xy) return detect_hits end,
    }
end

-- Stub marquee_hook with subscribe-only behavior.
local marquee_subscribers = {}
package.preload['dcs_sms_me.marquee_hook'] = function()
    return {
        install = function() end,
        subscribe = function(cb) marquee_subscribers[#marquee_subscribers + 1] = cb end,
    }
end

-- Stub selection.snapshot_mission and selection.airbase_entry_by_id.
local airbase_entries = {
    [12] = { id = 12, name = 'Anapa-Vityazevo', coalition = 'red',  north = 1, east = 2 },
    [27] = { id = 27, name = 'Krasnodar-Center', coalition = 'blue', north = 3, east = 4 },
}
package.preload['dcs_sms_me.selection'] = function()
    return {
        snapshot_mission = function(scope)
            if scope == 'airbase' then
                local pool = {}
                for _, e in pairs(airbase_entries) do pool[#pool + 1] = e end
                return { ok = true, scope = 'airbase', pool = pool, parent_map = {}, categories = {} }
            end
            return { ok = false, pool = {}, parent_map = {}, categories = {} }
        end,
        airbase_entry_by_id = function(id) return airbase_entries[id] end,
        _snapshot_airbases_now = function()
            local pool = {}
            for _, e in pairs(airbase_entries) do pool[#pool + 1] = e end
            return pool
        end,
    }
end

-- Load the function under test via mass_edit's exported test seam.
local mass_edit = require('dcs_sms_me.mass_edit')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Reset checked + install the subscription via the test seam.
mass_edit._reset_checked_airbase()
mass_edit._install_airbase_marquee_for_test()

-- Simulate a marquee that hits two airbases.
detect_hits = {
    { name = 'Anapa-Vityazevo',  airdrome_number_at_save = 12, x = 100, y = 200 },
    { name = 'Krasnodar-Center', airdrome_number_at_save = 27, x = 300, y = 400 },
}
check('one subscriber registered', #marquee_subscribers == 1)
marquee_subscribers[1]({ x = 0, y = 0 }, { x = 9999, y = 9999 })

local checked = mass_edit._get_checked_airbase()
check('Anapa entry is checked',  checked[airbase_entries[12]] == true)
check('Krasnodar entry is checked', checked[airbase_entries[27]] == true)

-- Second marquee with one new hit unions into existing checks.
detect_hits = {
    { name = 'Krasnodar-Center', airdrome_number_at_save = 27, x = 300, y = 400 },
}
marquee_subscribers[1]({ x = 0, y = 0 }, { x = 9999, y = 9999 })
checked = mass_edit._get_checked_airbase()
local n = 0; for _ in pairs(checked) do n = n + 1 end
check('union semantics keep both entries after second marquee', n == 2)

-- Subscribing twice (reload-safe guard) must not double up.
mass_edit._install_airbase_marquee_for_test()
check('reload-safe guard: still 1 subscriber after double install', #marquee_subscribers == 1)

if failures > 0 then
    print('FAILED: ' .. failures .. ' failures')
    os.exit(1)
end
print('All mass_edit airbase marquee tests passed.')
