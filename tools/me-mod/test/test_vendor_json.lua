-- test_vendor_json.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local json = require('dcs_sms_me.vendor.json')
local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

local t = json.decode('{"a":1,"b":"x","c":[1,2,3],"d":true,"e":null,"f":{"g":-2.5}}')
check('object', type(t)=='table')
check('number', t.a == 1)
check('string', t.b == 'x')
check('array len', #t.c == 3 and t.c[2] == 2)
check('bool', t.d == true)
check('null→nil', t.e == nil)
check('nested neg float', t.f.g == -2.5)

local esc = json.decode('"a\\nb\\t\\"c\\u0041"')
check('escapes', esc == 'a\nb\t"cA', esc)

local arr = json.decode('  [ "x" , 2 ]  ')
check('ws + array', arr[1]=='x' and arr[2]==2)

local ok, err = pcall(json.decode, '{bad}')
check('malformed rejected', not ok)

local ok2, val = pcall(json.decode, 'true')
check('top-level scalar', ok2 and val == true)

if failures > 0 then os.exit(1) end
print('All vendor json tests passed.')
