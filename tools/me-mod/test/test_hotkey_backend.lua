-- Standalone test for me_hotkey_backend.lua. Only the pure chord-matcher is
-- tested; attach/detach are dxgui-bound and verified by manual smoke. The
-- module's dxgui requires are pcall-guarded so it loads here.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
_G.log = _G.log or { write = function() end, INFO = 1, WARNING = 2, ERROR = 3 }
local B = require('dcs_sms_me.me_hotkey_backend')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- match_chord(state, keyName, keyState) tracks modifier hold-state and emits a
-- chord string on a non-modifier key DOWN. keyState: 'down' | 'up'.
local st = B.new_chord_state()
check('plain key down -> chord', B.match_chord(st, 'm', 'down') == 'm')
check('plain key up -> nil', B.match_chord(st, 'm', 'up') == nil)

-- modifier held then a letter -> Ctrl+<letter>
local st2 = B.new_chord_state()
B.match_chord(st2, 'LCtrl', 'down')
check('Ctrl held + d -> Ctrl+d', B.match_chord(st2, 'd', 'down') == 'Ctrl+d')
B.match_chord(st2, 'LCtrl', 'up')
check('Ctrl released, then d -> d', B.match_chord(st2, 'd', 'down') == 'd')

-- Ctrl+Shift order is canonical (Ctrl before Shift before Alt)
local st3 = B.new_chord_state()
B.match_chord(st3, 'LShift', 'down')
B.match_chord(st3, 'LCtrl', 'down')
check('Ctrl+Shift canonical order', B.match_chord(st3, 'r', 'down') == 'Ctrl+Shift+r')

-- a modifier key alone never produces a chord
local st4 = B.new_chord_state()
check('modifier down alone -> nil', B.match_chord(st4, 'LAlt', 'down') == nil)

check('get returns a backend with attach/detach', (function()
    local be = B.get('perkey'); return type(be) == 'table' and type(be.attach) == 'function' and type(be.detach) == 'function'
end)())

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All me_hotkey_backend tests passed.')
