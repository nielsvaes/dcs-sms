-- test_paths_image.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local mkdirs = {}
package.preload['lfs'] = function()
    return {
        writedir = function() return 'C:\\Users\\X\\Saved Games\\DCS\\' end,
        mkdir = function(p) mkdirs[#mkdirs + 1] = p; return true end,
    }
end
local paths = require('dcs_sms_me.paths')
local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

check('COMMUNITY_IMAGES_DIR under root',
      paths.COMMUNITY_IMAGES_DIR == 'C:\\Users\\X\\Saved Games\\DCS\\dcs-sms\\community-images\\',
      paths.COMMUNITY_IMAGES_DIR)

local p = paths.community_image_path('1514902424664539257/1.png')
check('image path joins dir + rel (backslashes)',
      p == 'C:\\Users\\X\\Saved Games\\DCS\\dcs-sms\\community-images\\1514902424664539257\\1.png', p)

local made_thread = false
for _, d in ipairs(mkdirs) do
    if d == 'C:\\Users\\X\\Saved Games\\DCS\\dcs-sms\\community-images\\1514902424664539257\\' then made_thread = true end
end
check('per-thread subdir created', made_thread, table.concat(mkdirs, ' | '))

local p2 = paths.community_image_path('flat.png')  -- no subdir
check('flat name maps under images dir',
      p2 == 'C:\\Users\\X\\Saved Games\\DCS\\dcs-sms\\community-images\\flat.png', p2)

check('nil rel is safe',
      paths.community_image_path(nil) == 'C:\\Users\\X\\Saved Games\\DCS\\dcs-sms\\community-images\\',
      paths.community_image_path(nil))

if failures > 0 then os.exit(1) end
print('All paths image tests passed.')
