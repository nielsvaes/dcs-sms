-- test_vendor_bit.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local b = require('dcs_sms_me.vendor.bit_compat')
local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

check('band',  b.band(0xF0F0F0F0, 0x0FF00FF0) == 0x00F000F0, string.format('%08X', b.band(0xF0F0F0F0,0x0FF00FF0)))
check('bor',   b.bor(0x0000FFFF, 0xFFFF0000) == 0xFFFFFFFF)
check('bxor',  b.bxor(0xFFFFFFFF, 0x0F0F0F0F) == 0xF0F0F0F0)
check('bnot',  b.band(b.bnot(0x00000000), 0xFFFFFFFF) == 0xFFFFFFFF)
check('lshift',b.lshift(1, 4) == 16)
check('lshift wrap', b.band(b.lshift(0x10000000, 4), 0xFFFFFFFF) == 0x00000000)
check('rshift',b.rshift(0xF0, 4) == 0x0F)
check('rrotate', b.rrotate(0x00000001, 1) == 0x80000000, string.format('%08X', b.rrotate(0x00000001,1)))
check('rrotate2', b.rrotate(0x12345678, 8) == 0x78123456, string.format('%08X', b.rrotate(0x12345678,8)))

if failures > 0 then os.exit(1) end
print('All vendor bit tests passed.')
