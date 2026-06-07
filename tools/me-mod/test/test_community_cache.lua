-- test_community_cache.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
-- Redirect the cache file to a temp path under %TEMP% (os.tmpname is unsafe on
-- the Windows LuaBinaries build — see test/AGENTS.md).
local tmp = (os.getenv('TEMP') or '.') .. '\\sms_cache_test_' .. tostring(os.time()) .. '.json'
package.preload['lfs'] = function() return { writedir=function() return '' end, mkdir=function() return true end } end
local paths = require('dcs_sms_me.paths')
paths.COMMUNITY_CACHE_FILE = tmp
local cache = require('dcs_sms_me.community_cache')

local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

check('load empty → nil', cache.load() == nil)
local ok = cache.save('{"schema":1,"prefabs":[]}')
check('save ok', ok == true)
check('round-trip', cache.load() == '{"schema":1,"prefabs":[]}', tostring(cache.load()))
os.remove(tmp)

if failures > 0 then os.exit(1) end
print('All community_cache tests passed.')
