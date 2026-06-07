-- test_lib_path.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
package.preload['lfs'] = function() return { writedir=function() return 'C:\\SG\\DCS\\' end, mkdir=function() return true end } end
local lp = require('dcs_sms_me.lib_path')
local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

local cpath, ppath = lp.build('A;B', 'C;D')
check('cpath has lib dll glob', cpath:find('C:\\SG\\DCS\\dcs-sms\\lib\\?.dll', 1, true) ~= nil, cpath)
check('cpath preserves existing', cpath:sub(-3) == 'A;B', cpath)
check('ppath has lib lua glob', ppath:find('dcs-sms\\lib\\?.lua', 1, true) ~= nil, ppath)
check('idempotent', select(1, lp.build(cpath, ppath)) == cpath, 'double-applied')

if failures > 0 then os.exit(1) end
print('All lib_path tests passed.')
