-- test_base64.lua — pure encode/decode round-trips.
local here = arg and arg[0] and arg[0]:match('^(.*[\\/])') or './'
package.path = here .. '?.lua;' .. here .. '../lua/?.lua;' .. package.path

local b64 = require('dcs_sms_me.base64')

local passed, failed, errors = 0, 0, {}
local function assert_eq(actual, expected, name)
    if actual == expected then passed = passed + 1
    else
        failed = failed + 1
        errors[#errors + 1] = string.format('%s: expected %q, got %q',
            name, tostring(expected), tostring(actual))
    end
end

-- RFC 4648 vectors
assert_eq(b64.encode(''), '', 'encode empty')
assert_eq(b64.encode('f'), 'Zg==', 'encode f')
assert_eq(b64.encode('fo'), 'Zm8=', 'encode fo')
assert_eq(b64.encode('foo'), 'Zm9v', 'encode foo')
assert_eq(b64.encode('foob'), 'Zm9vYg==', 'encode foob')
assert_eq(b64.encode('fooba'), 'Zm9vYmE=', 'encode fooba')
assert_eq(b64.encode('foobar'), 'Zm9vYmFy', 'encode foobar')

assert_eq(b64.decode('Zm9vYmFy'), 'foobar', 'decode foobar')
assert_eq(b64.decode(''), '', 'decode empty')

-- Binary round-trip: all 256 byte values, awkward length.
local all = {}
for i = 0, 255 do all[#all + 1] = string.char(i) end
local bin = table.concat(all) .. string.char(7, 0, 255)
assert_eq(b64.decode(b64.encode(bin)), bin, 'binary round-trip')

-- Whitespace tolerance on decode (serialized blobs may get wrapped).
assert_eq(b64.decode('Zm9v\nYmFy'), 'foobar', 'decode with newline')

-- Invalid input → nil
assert_eq(b64.decode('!!!!'), nil, 'decode invalid returns nil')
assert_eq(b64.decode(nil), nil, 'decode nil returns nil')
assert_eq(b64.encode(nil), nil, 'encode nil returns nil')

print(string.format('test_base64: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL ' .. e) end
os.exit(failed == 0 and 0 or 1)
