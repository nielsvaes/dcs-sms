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

-- is_community_path: Community folder + its subtree (any case / separator).
local ic = cfg.is_community_path
check('Community matches',            ic('Community') == true, 'Community')
check('Community/sub matches',        ic('Community/CAP') == true, 'Community/CAP')
check('Community backslash matches',  ic('Community\\CAP') == true, 'Community\\CAP')
check('lowercase community matches',  ic('community') == true, 'community')
check('root does not match',          ic('') == false, "''")
check('nil does not match',           ic(nil) == false, 'nil')
check('normal folder no match',       ic('CAP') == false, 'CAP')
check('CommunityCenter no match',     ic('CommunityCenter') == false, 'CommunityCenter')
check('MANAGED_MSG non-empty',        type(cfg.MANAGED_MSG) == 'string' and #cfg.MANAGED_MSG > 0, cfg.MANAGED_MSG)

-- meta_url: prefab path -> sibling .meta.json under RAW_BASE.
check('meta_url swaps .prefab for .meta.json',
      cfg.meta_url('prefabs/snow-city.prefab') == cfg.RAW_BASE .. 'prefabs/snow-city.meta.json',
      cfg.meta_url('prefabs/snow-city.prefab'))
check('meta_url tolerates no .prefab suffix',
      cfg.meta_url('prefabs/x') == cfg.RAW_BASE .. 'prefabs/x.meta.json',
      cfg.meta_url('prefabs/x'))
-- image_url: repo-relative screenshot path under images/.
check('image_url joins raw base + images/ + rel',
      cfg.image_url('123/1.png') == cfg.RAW_BASE .. 'images/123/1.png',
      cfg.image_url('123/1.png'))

if failures > 0 then os.exit(1) end
print('All community_config tests passed.')
