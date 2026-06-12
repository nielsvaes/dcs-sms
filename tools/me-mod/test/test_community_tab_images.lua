-- test_community_tab_images.lua
-- Drives the Community-tab media flow: a completed 'meta' fetch must parse the
-- sidecar's images, memoise them on the entry, and (while still selected) make
-- them the current image list. Widgets are nil in the test VM (pcall-guarded);
-- the meta/parse/state wiring under test is pure Lua.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             attributes = function() return nil end }
end
local importer = require('dcs_sms_me.community_import')
importer.is_imported = function() return false end
local tab = require('dcs_sms_me.community_tab')

local failures = 0
local function check(n, ok, msg)
    if ok then print('PASS ' .. n) else print('FAIL ' .. n .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local handle = tab.build(nil, {})
local W = handle._W
check('build returns a handle with _W', type(handle) == 'table' and type(W) == 'table')

-- Select an entry (selected_entry() reads W.visible[W.selected_idx]).
local entry = { name = 'Snow City', path = 'prefabs/snow-city.prefab', tags = {} }
W.visible = { entry }
W.selected_idx = 1

-- Simulate a completed 'meta' media fetch carrying the sidecar JSON.
W.media_token = 1
W.media_job = { file_body = '{"images":["123/1.png","123/2.png","123/3.png"],"author":"x"}',
                step = function() return 'done' end }
W.media_kind = 'meta'
W.media_pending = { token = 1, entry = entry }

handle:tick()

check('images memoised on entry', type(entry._images) == 'table' and #entry._images == 3,
      entry._images and #entry._images)
check('cur_images populated', #W.cur_images == 3, #W.cur_images)
check('first image is current', W.cur_img_idx == 1, W.cur_img_idx)
check('media job cleared after completion', W.media_job == nil and W.media_kind == nil)

if failures > 0 then os.exit(1) end
print('All community_tab image tests passed.')
