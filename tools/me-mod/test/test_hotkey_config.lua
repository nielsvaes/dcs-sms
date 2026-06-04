-- Standalone test for me_hotkey_config.lua pure serialize/deserialize.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local C = require('dcs_sms_me.me_hotkey_config')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function same(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

-- round-trip identity
local ov = { ['object.airplane'] = 'F1', ['panel.draw'] = 'Ctrl+Shift+D', ['map.ruler'] = '' }
local s = C.serialize(ov)
check('serialize returns a string', type(s) == 'string')
check('round-trip is identity', same(C.deserialize(s), ov))

-- empty
check('serialize empty round-trips to empty', same(C.deserialize(C.serialize({})), {}))

-- malformed input
check('deserialize non-string -> {}', same(C.deserialize(nil), {}))
check('deserialize garbage -> {}', same(C.deserialize('this is not lua {{{'), {}))
check('deserialize non-table return -> {}', same(C.deserialize('return 42'), {}))

-- only string keys+values survive
check('deserialize drops non-string values', same(C.deserialize('return { x = 5, y = "ok" }'), { y = 'ok' }))

-- special characters in values survive
local ov2 = { ['k'] = 'Ctrl+Alt+Shift+["]' }
check('special chars round-trip', same(C.deserialize(C.serialize(ov2)), ov2))

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All me_hotkey_config tests passed.')
