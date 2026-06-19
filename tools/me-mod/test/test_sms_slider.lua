-- Standalone test for sms_slider.lua.
-- Stubs Static + EditBox so M.new returns a real panel, then exercises the
-- pure math (M._math) directly and drives the drag/typing state machine via
-- the exposed _begin_drag / _drag_to / _end_drag and the value-box change
-- callback (the dxgui-callback wiring is a thin wrapper around these).

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

local statics = {}
local function new_static_stub()
    local s = {
        _bounds = nil, _skin = nil, _visible = nil, _enabled = nil,
        _md = {}, _mm = {}, _mu = {}, _captured = false, _released = false,
    }
    function s:setBounds(x, y, w, h) self._bounds = { x = x, y = y, w = w, h = h } end
    function s:setSkin(sk)        self._skin = sk end
    function s:setVisible(v)      self._visible = v end
    function s:setEnabled(v)      self._enabled = v end
    function s:setTooltipText(_t) end
    function s:addMouseDownCallback(cb) self._md[#self._md + 1] = cb end
    function s:addMouseMoveCallback(cb) self._mm[#self._mm + 1] = cb end
    function s:addMouseUpCallback(cb)   self._mu[#self._mu + 1] = cb end
    function s:captureMouse() self._captured = true end
    function s:releaseMouse() self._released = true end
    statics[#statics + 1] = s
    return s
end

local last_box
local function new_editbox_stub()
    local b = {
        _text = '', _bounds = nil, _skin = nil, _visible = nil,
        _enabled = nil, _change = {},
    }
    function b:setText(t) self._text = tostring(t) end
    function b:getText() return self._text end
    function b:setBounds(x, y, w, h) self._bounds = { x = x, y = y, w = w, h = h } end
    function b:setSkin(sk) self._skin = sk end
    function b:setVisible(v) self._visible = v end
    function b:setEnabled(v) self._enabled = v end
    function b:setTooltipText(_t) end
    function b:addChangeCallback(cb) self._change[#self._change + 1] = cb end
    last_box = b
    return b
end

package.preload['Static']  = function() return { new = new_static_stub } end
package.preload['EditBox'] = function() return { new = new_editbox_stub } end
package.preload['Skin']    = function() return setmetatable({}, { __index = function() return function() return {} end end }) end
package.preload['dcs_sms_me.sms_skins'] = function()
    return { slider_track = function() return {} end, slider_handle = function() return {} end }
end

local slider = require('dcs_sms_me.sms_slider')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end
local function approx(a, b) return math.abs(a - b) < 1e-9 end

-- Reset the captured-widget list before each construction so statics[1..2]
-- are this slider's track + handle.
local function fresh() statics = {}; last_box = nil end

local function new_parent()
    local p = { _inserted = 0 }
    function p:insertWidget(_w) self._inserted = self._inserted + 1 end
    return p
end

-- ---------------------------------------------------------------------------
-- Pure math (M._math)
-- ---------------------------------------------------------------------------
do
    local m = slider._math
    check('clamp below', m.clamp(-5, 0, 10) == 0)
    check('clamp above', m.clamp(99, 0, 10) == 10)
    check('clamp inside', m.clamp(5, 0, 10) == 5)

    check('quantize snaps to grid', m.quantize(53, 0, 5) == 55)
    check('quantize from offset min', approx(m.quantize(0.24, 0.01, 0.1), 0.21))
    check('quantize step<=0 = identity', m.quantize(3.7, 0, 0) == 3.7)

    check('value_to_frac mid', approx(m.value_to_frac(50, 0, 100), 0.5))
    check('value_to_frac zero range', m.value_to_frac(5, 5, 5) == 0)
    check('value_to_frac clamps', m.value_to_frac(150, 0, 100) == 1)

    -- track_x=0 track_w=100 handle_w=10 → travel center math
    check('handle_x at min', m.handle_x(0, 0, 100, 0, 100, 10) == 0)
    check('handle_x at max clamps inside', m.handle_x(100, 0, 100, 0, 100, 10) == 90)
    check('handle_x mid centers', m.handle_x(50, 0, 100, 0, 100, 10) == 45)

    -- x_to_value: track_x=0 track_w=100 step=1
    check('x_to_value left = min', m.x_to_value(0, 0, 100, 0, 100, 1) == 0)
    check('x_to_value right = max', m.x_to_value(100, 0, 100, 0, 100, 1) == 100)
    check('x_to_value mid = 50', m.x_to_value(50, 0, 100, 0, 100, 1) == 50)
    check('x_to_value past right clamps', m.x_to_value(9999, 0, 100, 0, 100, 1) == 100)
    check('x_to_value quantizes', m.x_to_value(53, 0, 100, 0, 100, 5) == 55)
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------
do
    fresh()
    local parent = new_parent()
    local s = slider.new(parent, { initial = 25, min = 1, max = 2000, step = 5 })
    check('new returns panel', type(s) == 'table')
    check('parent.insertWidget called 3x (track+handle+box)', parent._inserted == 3)
    check('initial value quantized/clamped', s:get_value() == 26)  -- quantize(25,1,5)=26
    check('is_dragging false initially', s:is_dragging() == false)
    check('widget() returns the value box', s:widget() == last_box)
    check('value box initial text set', last_box._text == '26')
end

-- ---------------------------------------------------------------------------
-- set_value clamps + quantizes, does NOT fire on_change
-- ---------------------------------------------------------------------------
do
    fresh()
    local fired = 0
    local s = slider.new(new_parent(), {
        initial = 0, min = 0, max = 100, step = 1,
        on_change = function() fired = fired + 1 end,
    })
    s:set_value(50)
    check('set_value in range', s:get_value() == 50)
    s:set_value(-10)
    check('set_value below min clamps', s:get_value() == 0)
    s:set_value(9999)
    check('set_value above max clamps', s:get_value() == 100)
    check('set_value never fires on_change', fired == 0)
end

-- ---------------------------------------------------------------------------
-- Drag maps mouse-x → value, fires on_change, rewrites the box
-- ---------------------------------------------------------------------------
do
    fresh()
    local calls = {}
    local s = slider.new(new_parent(), {
        initial = 0, min = 0, max = 100, step = 1,
        value_w = 52,
        on_change = function(v) calls[#calls + 1] = v end,
    })
    -- w=152 → track_w = 152-52-6 = 94, track_x = 0
    s:set_bounds(0, 0, 152, 22)
    s:_begin_drag(47)            -- ~middle of the 94px track
    check('begin_drag sets dragging', s:is_dragging() == true)
    check('drag to mid ≈ 50', s:get_value() == 50)
    check('drag fired on_change with 50', calls[#calls] == 50)
    check('drag rewrote the value box', last_box._text == '50')
    s:_drag_to(0)
    check('drag to left = min', s:get_value() == 0)
    s:_drag_to(9999)
    check('drag past right = max', s:get_value() == 100)
    s:_end_drag()
    check('end_drag clears dragging', s:is_dragging() == false)
end

-- ---------------------------------------------------------------------------
-- Typing in the value box: clamp to range, NOT step-snapped; fires on_change
-- ---------------------------------------------------------------------------
do
    fresh()
    local calls = {}
    local s = slider.new(new_parent(), {
        initial = 0, min = 0.01, max = 50, step = 0.1, decimals = 2,
        on_change = function(v) calls[#calls + 1] = v end,
    })
    s:set_bounds(0, 0, 152, 22)
    local box = last_box
    -- Simulate the user typing "1.0".
    box._text = '1.0'
    for _, cb in ipairs(box._change) do cb(box) end
    check('typed value applied (not step-snapped)', approx(s:get_value(), 1.0))
    check('typed value fired on_change', approx(calls[#calls], 1.0))
    -- Garbage mid-type is ignored, not zeroed.
    box._text = 'abc'
    for _, cb in ipairs(box._change) do cb(box) end
    check('garbage text keeps prior value', approx(s:get_value(), 1.0))
    -- Out-of-range typing clamps.
    box._text = '999'
    for _, cb in ipairs(box._change) do cb(box) end
    check('typed above max clamps', s:get_value() == 50)
end

-- ---------------------------------------------------------------------------
-- set_range re-clamps the current value
-- ---------------------------------------------------------------------------
do
    fresh()
    local s = slider.new(new_parent(), { initial = 0, min = 0, max = 500, step = 1 })
    s:set_value(450)
    s:set_range(0, 300)
    check('set_range shrinks max: value pulled in', s:get_value() == 300)
end

-- ---------------------------------------------------------------------------
-- set_bounds lays out track + box; handle sits over the track
-- ---------------------------------------------------------------------------
do
    fresh()
    local s = slider.new(new_parent(), { initial = 0, min = 0, max = 100, step = 1, value_w = 52 })
    local track, handle = statics[1], statics[2]
    s:set_bounds(10, 20, 152, 22)
    check('track bounds set (x,w)', track._bounds.x == 10 and track._bounds.w == 94)
    check('value box pinned right', last_box._bounds.x == 10 + 94 + 6 and last_box._bounds.w == 52)
    check('handle within track at min', handle._bounds.x == 10)
end

-- ---------------------------------------------------------------------------
-- dxgui wiring: mouse-down on the handle captures + drags; up releases
-- ---------------------------------------------------------------------------
do
    fresh()
    local s = slider.new(new_parent(), { initial = 0, min = 0, max = 100, step = 1, value_w = 52 })
    local handle = statics[2]
    s:set_bounds(0, 0, 152, 22)
    for _, cb in ipairs(handle._md) do cb(handle, 47, 0, 1) end
    check('mouse-down captures', handle._captured == true)
    check('mouse-down drags to ≈50', s:get_value() == 50)
    for _, cb in ipairs(handle._mu) do cb(handle, 47, 0, 1) end
    check('mouse-up releases', handle._released == true)
    check('mouse-up not dragging', s:is_dragging() == false)
end

-- ---------------------------------------------------------------------------
-- Disabled slider ignores track/handle clicks; re-enabling restores dragging
-- ---------------------------------------------------------------------------
do
    fresh()
    local calls = {}
    local s = slider.new(new_parent(), {
        initial = 0, min = 0, max = 100, step = 1, value_w = 52,
        on_change = function(v) calls[#calls + 1] = v end,
    })
    local track = statics[1]
    s:set_bounds(0, 0, 152, 22)
    s:set_enabled(false)
    check('set_enabled(false) disables the track', track._enabled == false)
    for _, cb in ipairs(track._md) do cb(track, 47, 0, 1) end
    check('disabled: track click does not change value', s:get_value() == 0)
    check('disabled: track click did not capture', track._captured == false)
    check('disabled: on_change not fired', #calls == 0)
    s:set_enabled(true)
    for _, cb in ipairs(track._md) do cb(track, 47, 0, 1) end
    check('re-enabled: track click changes value', s:get_value() == 50)
end

-- ---------------------------------------------------------------------------
-- set_visible / show / hide propagate to all three children (truthy semantics)
-- ---------------------------------------------------------------------------
do
    fresh()
    local s = slider.new(new_parent(), { initial = 0, min = 0, max = 100, step = 1 })
    local track, handle = statics[1], statics[2]
    s:hide()
    check('hide: track hidden',  track._visible == false)
    check('hide: handle hidden', handle._visible == false)
    check('hide: box hidden',    last_box._visible == false)
    s:show()
    check('show: track visible', track._visible == true)
    s:set_visible(1)  -- truthy non-boolean must still show (consistency with set_enabled)
    check('set_visible(1) shows (truthy)', track._visible == true)
end

-- ---------------------------------------------------------------------------
-- camelCase aliases delegate to the snake_case methods
-- ---------------------------------------------------------------------------
do
    fresh()
    local s = slider.new(new_parent(), { initial = 0, min = 0, max = 100, step = 1 })
    s:setValue(40)
    check('setValue/getValue aliases', s:getValue() == 40)
    s:setBounds(0, 0, 152, 22)
    check('setBounds alias laid out the track', statics[1]._bounds ~= nil)
    s:setEnabled(false)
    check('setEnabled alias disables', statics[1]._enabled == false)
end

-- ---------------------------------------------------------------------------
-- dxgui wiring on the TRACK (click-on-track jumps + captures)
-- ---------------------------------------------------------------------------
do
    fresh()
    local s = slider.new(new_parent(), { initial = 0, min = 0, max = 100, step = 1, value_w = 52 })
    local track = statics[1]
    s:set_bounds(0, 0, 152, 22)
    for _, cb in ipairs(track._md) do cb(track, 47, 0, 1) end
    check('track mouse-down captures', track._captured == true)
    check('track mouse-down jumps to ≈50', s:get_value() == 50)
    for _, cb in ipairs(track._mu) do cb(track, 47, 0, 1) end
    check('track mouse-up releases', track._released == true)
end

print('')
if failures == 0 then
    print('All sms_slider tests passed.')
    os.exit(0)
else
    print(failures .. ' sms_slider tests FAILED.')
    os.exit(1)
end
