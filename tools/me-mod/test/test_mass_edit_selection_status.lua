-- Standalone test for the "Selected: N" footer indicator in mass_edit.lua.
-- Covers the pure formatter (0 -> blank, N -> "Selected: N") and the
-- update_selection_status integration that pushes it to the window footer.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Minimal stubs so mass_edit loads outside a real ME (mirrors
-- test_mass_edit_airbase_marquee.lua).
package.preload['dcs_sms_me.airbase_detect'] = function()
    return { airbases_in_rect = function() return {} end }
end
package.preload['dcs_sms_me.marquee_hook'] = function()
    return { install = function() end, subscribe = function() end }
end
package.preload['dcs_sms_me.selection'] = function()
    return {
        snapshot_mission = function() return { ok = false, pool = {}, parent_map = {}, categories = {} } end,
        airbase_entry_by_id = function() return nil end,
        _snapshot_airbases_now = function() return {} end,
    }
end

local mass_edit = require('dcs_sms_me.mass_edit')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Pure formatter: zero is blank (so "Selected: 0" never shows and a stale
-- count is cleared), positive counts read "Selected: N".
check('text(0) is blank',     mass_edit._selection_status_text(0) == '')
check('text(nil) is blank',   mass_edit._selection_status_text(nil) == '')
check('text(1)',              mass_edit._selection_status_text(1) == 'Selected: 1')
check('text(5)',              mass_edit._selection_status_text(5) == 'Selected: 5')

-- Integration: update_selection_status reads the active scope's checked count
-- and pushes it through the window's set_status.
local captured
mass_edit._W.sms_window = {
    set_status = function(self, text, sev) captured = { text = text, sev = sev } end,
}
local e1 = { id = 1, name = 'A' }
local e2 = { id = 2, name = 'B' }
mass_edit._W.scope = 'airbase'
mass_edit._W.pool = { e1, e2 }

mass_edit._W.checked.airbase = { [e1] = true }
mass_edit._update_selection_status()
check('one checked -> "Selected: 1"', captured and captured.text == 'Selected: 1', captured and captured.text)

mass_edit._W.checked.airbase = { [e1] = true, [e2] = true }
mass_edit._update_selection_status()
check('two checked -> "Selected: 2"', captured and captured.text == 'Selected: 2', captured and captured.text)

mass_edit._W.checked.airbase = {}
mass_edit._update_selection_status()
check('zero checked -> blank footer', captured and captured.text == '', captured and captured.text)

if failures > 0 then os.exit(1) end
print('All mass_edit selection-status tests passed.')
