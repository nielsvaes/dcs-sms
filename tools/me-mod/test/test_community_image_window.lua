-- test_community_image_window.lua
-- Headless smoke: the module must load and every public call must be a safe
-- no-op when there's no real dxgui window (sms_window can't build one in the
-- test VM). We assert "doesn't throw" + is_open() stays false.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
-- Stub the DCS global logger so sms_window.new can log+return nil cleanly.
log = { write = function() end, INFO = 0, WARNING = 1, ERROR = 2, ALERT = 3 }

local win = require('dcs_sms_me.community_image_window')
local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

check('is_open false before any show', win.is_open() == false)

local prevs, nexts = 0, 0
local ok = pcall(function()
    win.show({ path = 'C:\\fake\\1.png', native_w = 1920, native_h = 1080,
               count_text = '1 / 3', has_nav = true,
               on_prev = function() prevs = prevs + 1 end,
               on_next = function() nexts = nexts + 1 end })
end)
check('show does not throw without a real window', ok, ok)
check('is_open still false (no window built in test VM)', win.is_open() == false)

check('set_image no-throw', pcall(function() win.set_image('C:\\fake\\2.png', '2 / 3', true) end))
check('set_loading no-throw', pcall(function() win.set_loading('loading...', true) end))
check('hide no-throw', pcall(function() win.hide() end))

if failures > 0 then os.exit(1) end
print('All community_image_window tests passed.')
