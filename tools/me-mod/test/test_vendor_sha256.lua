-- test_vendor_sha256.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local sha256 = require('dcs_sms_me.vendor.sha256')
local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

check('empty', sha256.hex('') == 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', sha256.hex(''))
check('abc', sha256.hex('abc') == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', sha256.hex('abc'))
check('two-block',
    sha256.hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')
      == '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    sha256.hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))
check('return shape', #sha256.hex('x') == 64)

if failures > 0 then os.exit(1) end
print('All vendor sha256 tests passed.')
