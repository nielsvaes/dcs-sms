-- Standalone test for skin_helper.apply.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Stub dtc_skins (the dtc_* branch resolver target).
local dtc_calls = { button = 0, grid = 0, grid_header = 0, separator = 0 }
package.preload['dcs_sms_me.dtc_skins'] = function()
    return {
        button       = function() dtc_calls.button       = dtc_calls.button       + 1; return { __skin = 'dtc_button' } end,
        grid         = function() dtc_calls.grid         = dtc_calls.grid         + 1; return { __skin = 'dtc_grid' } end,
        grid_header  = function() dtc_calls.grid_header  = dtc_calls.grid_header  + 1; return { __skin = 'dtc_grid_header' } end,
        separator    = function() dtc_calls.separator    = dtc_calls.separator    + 1; return { __skin = 'dtc_separator' } end,
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
    local ok = pcall(skin_helper.apply, nil, 'dtc_button')
    check('apply(nil, ...) does not throw', ok)
end

-- Case 2: widget without setSkin doesn't throw.
do
    local ok = pcall(skin_helper.apply, {}, 'dtc_button')
    check('apply(widget-without-setSkin, ...) does not throw', ok)
end

-- Case 3: unknown skin name → no setSkin call, no throw.
do
    local w = make_widget()
    skin_helper.apply(w, 'totally_made_up_skin_name')
    check('unknown skin name: no setSkin', w._applied == nil)
end

-- Case 4: dtc_button routes to dtc_skins.button().
do
    local w = make_widget()
    skin_helper.apply(w, 'dtc_button')
    check('dtc_button: setSkin called with dtc_skins.button() result',
          type(w._applied) == 'table' and w._applied.__skin == 'dtc_button')
end

-- Case 5: dtc_grid routes to dtc_skins.grid().
do
    local w = make_widget()
    skin_helper.apply(w, 'dtc_grid')
    check('dtc_grid: setSkin applied', w._applied and w._applied.__skin == 'dtc_grid')
end

-- Case 6: dtc_grid_header routes to dtc_skins.grid_header().
do
    local w = make_widget()
    skin_helper.apply(w, 'dtc_grid_header')
    check('dtc_grid_header: setSkin applied', w._applied and w._applied.__skin == 'dtc_grid_header')
end

-- Case 7: dtc_separator routes to dtc_skins.separator().
do
    local w = make_widget()
    skin_helper.apply(w, 'dtc_separator')
    check('dtc_separator: setSkin applied', w._applied and w._applied.__skin == 'dtc_separator')
end

-- Case 8: stock skin name routes to Skin.<name>().
do
    local w = make_widget()
    skin_helper.apply(w, 'staticSkin_ME')
    check('stock skin: setSkin applied',
          w._applied and w._applied.__skin == 'staticSkin_ME')
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All skin_helper tests passed.')
