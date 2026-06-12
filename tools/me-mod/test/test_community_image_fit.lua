-- test_community_image_fit.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local fit = require('dcs_sms_me.community_image_fit').fit
local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

-- Landscape image into a square box → limited by width.
local w, h = fit(1000, 500, 200, 200)
check('landscape width-limited', w == 200 and h == 100, w..'x'..h)

-- Portrait image into a square box → limited by height.
w, h = fit(500, 1000, 200, 200)
check('portrait height-limited', w == 100 and h == 200, w..'x'..h)

-- Downscale preserves aspect (2:1).
w, h = fit(1920, 1080, 480, 480)
check('16:9 into square keeps ratio', w == 480 and h == 270, w..'x'..h)

-- Upscale allowed (box bigger than native), aspect preserved.
w, h = fit(100, 50, 400, 400)
check('upscales to fit', w == 400 and h == 200, w..'x'..h)

-- Exact fit.
w, h = fit(300, 200, 300, 200)
check('exact fit', w == 300 and h == 200, w..'x'..h)

-- Non-positive / nil inputs → (0, 0).
check('zero native -> 0,0', select(1, fit(0, 100, 50, 50)) == 0)
check('nil native -> 0,0', (function() local a,b = fit(nil, nil, 50, 50); return a==0 and b==0 end)())
check('zero box -> 0,0', select(1, fit(100, 100, 0, 50)) == 0)

if failures > 0 then os.exit(1) end
print('All community_image_fit tests passed.')
