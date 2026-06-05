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

-- DCS's real keyboard-callback modifier names ("left shift" / "right ctrl" /
-- "alt gr", any casing) must be recognised — the actual capture overlay sees
-- these, not the LCtrl short forms.
local st5 = B.new_chord_state()
check('"left shift" alone -> nil', B.match_chord(st5, 'left shift', 'down') == nil)
check('left shift held + m -> Shift+m', B.match_chord(st5, 'm', 'down') == 'Shift+m')
B.match_chord(st5, 'left shift', 'up')
check('left shift released, then m -> m', B.match_chord(st5, 'm', 'down') == 'm')

local st6 = B.new_chord_state()
B.match_chord(st6, 'LEFT CTRL', 'down')   -- casing-insensitive
B.match_chord(st6, 'left alt', 'down')
check('Ctrl+Alt canonical order from real names', B.match_chord(st6, 'x', 'down') == 'Ctrl+Alt+x')

local st7 = B.new_chord_state()
check('"alt gr" treated as Alt', (function()
    B.match_chord(st7, 'alt gr', 'down')
    return B.match_chord(st7, 'g', 'down') == 'Alt+g'
end)())

check('get returns a backend with attach/detach', (function()
    local be = B.get('perkey'); return type(be) == 'table' and type(be.attach) == 'function' and type(be.detach) == 'function'
end)())

-- capture_step: the press/release latch the capture overlay uses. A chord is
-- FINALIZED on the key-UP of the non-modifier key that formed it (NOT on its
-- key-down), so the assigning keypress is fully consumed — with bindings still
-- suspended — before the new binding goes live. Otherwise the editor dispatches
-- that same held key to the freshly-attached binding and fires the action you
-- were assigning.
do
    local cs = B.new_capture_state()
    check('capture: plain key DOWN does not finalize', B.capture_step(cs, 'm', 'down') == nil)
    check('capture: plain key UP finalizes the chord', B.capture_step(cs, 'm', 'up') == 'm')
end
do
    local cs = B.new_capture_state()
    check('capture: Esc down -> cancel', B.capture_step(cs, 'escape', 'down') == 'cancel')
end
do
    -- modifier chord: Ctrl held, k pressed then released -> 'Ctrl+k' on the k UP
    local cs = B.new_capture_state()
    check('capture: Ctrl down -> nil',      B.capture_step(cs, 'left ctrl', 'down') == nil)
    check('capture: k down (pending) -> nil', B.capture_step(cs, 'k', 'down') == nil)
    check('capture: k up -> Ctrl+k',        B.capture_step(cs, 'k', 'up') == 'Ctrl+k')
end
do
    -- releasing the modifier before the chord key still finalizes the latched chord
    local cs = B.new_capture_state()
    B.capture_step(cs, 'left ctrl', 'down')
    B.capture_step(cs, 'j', 'down')                 -- latches 'Ctrl+j'
    check('capture: modifier up while pending -> nil', B.capture_step(cs, 'left ctrl', 'up') == nil)
    check('capture: chord-key up finalizes latched chord', B.capture_step(cs, 'j', 'up') == 'Ctrl+j')
end
do
    -- a bare modifier never finalizes
    local cs = B.new_capture_state()
    check('capture: modifier down alone -> nil', B.capture_step(cs, 'left alt', 'down') == nil)
    check('capture: modifier up alone -> nil',   B.capture_step(cs, 'left alt', 'up') == nil)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All me_hotkey_backend tests passed.')
