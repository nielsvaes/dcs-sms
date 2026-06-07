-- test_community_config.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
package.preload['lfs'] = function()
    return { writedir = function() return 'C:\\Users\\X\\Saved Games\\DCS\\' end, mkdir = function() return true end }
end
local paths = require('dcs_sms_me.paths')
local cfg   = require('dcs_sms_me.community_config')

local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures = failures + 1 end end

check('LIB_DIR under writedir', paths.LIB_DIR == 'C:\\Users\\X\\Saved Games\\DCS\\dcs-sms\\lib\\', paths.LIB_DIR)
check('cache file under root', paths.COMMUNITY_CACHE_FILE:sub(-#'community-cache.json') == 'community-cache.json', paths.COMMUNITY_CACHE_FILE)
check('community folder constant', cfg.COMMUNITY_FOLDER == 'Community', cfg.COMMUNITY_FOLDER)
check('manifest url ends in index.json', cfg.manifest_url():sub(-10) == 'index.json', cfg.manifest_url())
check('file url joins raw base + path', cfg.file_url('prefabs/a.prefab') == cfg.RAW_BASE .. 'prefabs/a.prefab', cfg.file_url('prefabs/a.prefab'))
check('schema version is 1', cfg.SCHEMA_VERSION == 1)

if failures > 0 then os.exit(1) end
print('All community_config tests passed.')
