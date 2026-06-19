-- Standalone test for skin_helper.apply.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Stub sms_skins (the sms_* branch resolver target).
local sms_calls = { button = 0, grid = 0, grid_header = 0, separator = 0,
                    tab = 0, coal_red = 0, coal_blue = 0, coal_neutral = 0 }
package.preload['dcs_sms_me.sms_skins'] = function()
    return {
        button       = function() sms_calls.button       = sms_calls.button       + 1; return { __skin = 'sms_button' } end,
        grid         = function() sms_calls.grid         = sms_calls.grid         + 1; return { __skin = 'sms_grid' } end,
        grid_header  = function() sms_calls.grid_header  = sms_calls.grid_header  + 1; return { __skin = 'sms_grid_header' } end,
        separator    = function() sms_calls.separator    = sms_calls.separator    + 1; return { __skin = 'sms_separator' } end,
        tab          = function() sms_calls.tab          = sms_calls.tab          + 1; return { __skin = 'sms_tab' } end,
        coal_red     = function() sms_calls.coal_red     = sms_calls.coal_red     + 1; return { __skin = 'sms_coal_red' } end,
        coal_blue    = function() sms_calls.coal_blue    = sms_calls.coal_blue    + 1; return { __skin = 'sms_coal_blue' } end,
        coal_neutral = function() sms_calls.coal_neutral = sms_calls.coal_neutral + 1; return { __skin = 'sms_coal_neutral' } end,
        slider_track  = function() return { __skin = 'sms_slider_track' } end,
        slider_handle = function() return { __skin = 'sms_slider_handle' } end,
    }
end

-- Stub Skin (the fallback branch resolver target). Plain table with only
-- known stock-skin names so that lookups for unknown names return nil —
-- matching the production Skin module shape (auto-generated from a fixed
-- name list, so unknown names really do come back nil).
local stock_calls = {}
package.preload['Skin'] = function()
    return {
        staticSkin_ME = function() stock_calls.staticSkin_ME = (stock_calls.staticSkin_ME or 0) + 1; return { __skin = 'staticSkin_ME' } end,
    }
end

local skin_helper = require('dcs_sms_me.skin_helper')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function make_widget()
    local w = { _applied = nil }
    function w:setSkin(s) self._applied = s end
    return w
end

-- Case 1: nil widget doesn't throw.
do
    local ok = pcall(skin_helper.apply, nil, 'sms_button')
    check('apply(nil, ...) does not throw', ok)
end

-- Case 2: widget without setSkin doesn't throw.
do
    local ok = pcall(skin_helper.apply, {}, 'sms_button')
    check('apply(widget-without-setSkin, ...) does not throw', ok)
end

-- Case 3: unknown skin name → no setSkin call, no throw.
do
    local w = make_widget()
    skin_helper.apply(w, 'totally_made_up_skin_name')
    check('unknown skin name: no setSkin', w._applied == nil)
end

-- Case 4: sms_button routes to sms_skins.button().
do
    local w = make_widget()
    skin_helper.apply(w, 'sms_button')
    check('sms_button: setSkin called with sms_skins.button() result',
          type(w._applied) == 'table' and w._applied.__skin == 'sms_button')
end

-- Case 5: sms_grid routes to sms_skins.grid().
do
    local w = make_widget()
    skin_helper.apply(w, 'sms_grid')
    check('sms_grid: setSkin applied', w._applied and w._applied.__skin == 'sms_grid')
end

-- Case 6: sms_grid_header routes to sms_skins.grid_header().
do
    local w = make_widget()
    skin_helper.apply(w, 'sms_grid_header')
    check('sms_grid_header: setSkin applied', w._applied and w._applied.__skin == 'sms_grid_header')
end

-- Case 7: sms_separator routes to sms_skins.separator().
do
    local w = make_widget()
    skin_helper.apply(w, 'sms_separator')
    check('sms_separator: setSkin applied', w._applied and w._applied.__skin == 'sms_separator')
end

-- Case 7a: sms_tab routes to sms_skins.tab().
do
    local w = make_widget()
    skin_helper.apply(w, 'sms_tab')
    check('sms_tab: setSkin applied', w._applied and w._applied.__skin == 'sms_tab')
end

-- Case 7c: sms_coal_red routes to sms_skins.coal_red().
do
    local w = make_widget()
    skin_helper.apply(w, 'sms_coal_red')
    check('sms_coal_red: setSkin applied', w._applied and w._applied.__skin == 'sms_coal_red')
end

-- Case 7d: sms_coal_blue routes to sms_skins.coal_blue().
do
    local w = make_widget()
    skin_helper.apply(w, 'sms_coal_blue')
    check('sms_coal_blue: setSkin applied', w._applied and w._applied.__skin == 'sms_coal_blue')
end

-- Case 7e: sms_coal_neutral routes to sms_skins.coal_neutral().
do
    local w = make_widget()
    skin_helper.apply(w, 'sms_coal_neutral')
    check('sms_coal_neutral: setSkin applied', w._applied and w._applied.__skin == 'sms_coal_neutral')
end

-- Case 8: stock skin name routes to Skin.<name>().
do
    local w = make_widget()
    skin_helper.apply(w, 'staticSkin_ME')
    check('stock skin: setSkin applied',
          w._applied and w._applied.__skin == 'staticSkin_ME')
end

-- Case 9: sms_slider_track routes to sms_skins.slider_track().
do
    local w = make_widget()
    skin_helper.apply(w, 'sms_slider_track')
    check('sms_slider_track: setSkin applied',
          w._applied and w._applied.__skin == 'sms_slider_track')
end

-- Case 10: sms_slider_handle routes to sms_skins.slider_handle().
do
    local w = make_widget()
    skin_helper.apply(w, 'sms_slider_handle')
    check('sms_slider_handle: setSkin applied',
          w._applied and w._applied.__skin == 'sms_slider_handle')
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All skin_helper tests passed.')
