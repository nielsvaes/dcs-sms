-- Standalone test for splitter.lua.
-- Stubs Static so M.new returns a real panel, then drives the drag
-- state machine via the exposed _begin_drag / _drag_to / _end_drag
-- (the dxgui-callback layer is a thin wrapper around these and is
-- exercised in the live ME, not here).

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

local last_static
local function new_static_stub(_text)
    local s = {
        _bounds    = nil,
        _skin      = nil,
        _visible   = nil,
        _mouse_d   = {}, _mouse_m = {}, _mouse_u = {},
        _captured  = false,
        _released  = false,
    }
    function s:setBounds(x,y,w,h) self._bounds = { x=x, y=y, w=w, h=h } end
    function s:setSkin(sk)        self._skin   = sk end
    function s:setVisible(v)      self._visible = v end
    function s:addMouseDownCallback(cb) self._mouse_d[#self._mouse_d+1] = cb end
    function s:addMouseMoveCallback(cb) self._mouse_m[#self._mouse_m+1] = cb end
    function s:addMouseUpCallback(cb)   self._mouse_u[#self._mouse_u+1] = cb end
    function s:captureMouse() self._captured = true end
    function s:releaseMouse() self._released = true end
    function s:getBounds()
        if self._bounds then
            return self._bounds.x, self._bounds.y, self._bounds.w, self._bounds.h
        end
        return 0, 0, 0, 0
    end
    last_static = s
    return s
end

package.preload['Static'] = function() return { new = new_static_stub } end
package.preload['Skin']   = function() return setmetatable({}, { __index = function() return function() return {} end end }) end
package.preload['dcs_sms_me.sms_skins'] = function()
    return { splitter = function() return { _which = 'splitter' } end }
end

local splitter_mod = require('dcs_sms_me.splitter')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Build a parent stub whose insertWidget just counts.
local function new_parent()
    local p = { _inserted = 0 }
    function p:insertWidget(_w) self._inserted = self._inserted + 1 end
    return p
end

-- ---------------------------------------------------------------------------
-- Construction defaults
-- ---------------------------------------------------------------------------
do
    local parent = new_parent()
    local s = splitter_mod.new(parent, { initial = 100 })
    check('new returns panel',                  type(s) == 'table')
    check('parent.insertWidget called',         parent._inserted == 1)
    check('initial value applied',              s:get_value() == 100)
    check('is_dragging false initially',        s:is_dragging() == false)
    check('widget() returns the Static stub',   s:widget() == last_static)
    check('default skin applied (sms_splitter)', last_static._skin and last_static._skin._which == 'splitter')
end

-- ---------------------------------------------------------------------------
-- set_value clamps to range
-- ---------------------------------------------------------------------------
do
    local s = splitter_mod.new(new_parent(), { initial = 100, min = 50, max = 200 })
    s:set_value(150)
    check('set_value in range',                 s:get_value() == 150)
    s:set_value(10)
    check('set_value below min clamps to min',  s:get_value() == 50)
    s:set_value(999)
    check('set_value above max clamps to max',  s:get_value() == 200)
    s:set_value('nope')
    check('set_value with non-number keeps prior', s:get_value() == 200)
end

-- ---------------------------------------------------------------------------
-- Drag without invert: dragging right INCREASES the value.
-- ---------------------------------------------------------------------------
do
    local calls = {}
    local s = splitter_mod.new(new_parent(), {
        initial = 100, min = 0, max = 500,
        on_drag = function(v) calls[#calls + 1] = v end,
    })
    s:_begin_drag(200)            -- drag started at window x=200
    check('begin: is_dragging',                 s:is_dragging() == true)

    s:_drag_to(210)               -- moved 10px right
    check('drag +10: value = 110',              s:get_value() == 110)
    check('drag +10: on_drag fired with 110',   calls[#calls] == 110)

    s:_drag_to(250)               -- cumulative +50
    check('drag +50: value = 150',              s:get_value() == 150)

    s:_drag_to(190)               -- cumulative -10
    check('drag -10: value = 90',               s:get_value() == 90)

    s:_drag_to(-500)              -- way below min
    check('drag clamped to min',                s:get_value() == 0)

    s:_drag_to(99999)             -- way above max
    check('drag clamped to max',                s:get_value() == 500)
end

-- ---------------------------------------------------------------------------
-- Drag with invert: dragging right DECREASES the value (this is what
-- the mass_edit splitter uses, since FORM_PANE_W shrinks as the splitter
-- moves right).
-- ---------------------------------------------------------------------------
do
    local s = splitter_mod.new(new_parent(), {
        initial = 440, min = 100, max = 600, invert = true,
    })
    s:_begin_drag(500)
    s:_drag_to(510)               -- +10 in window coords
    check('invert drag right: value decreases', s:get_value() == 430)
    s:_drag_to(480)               -- -20 cumulative
    check('invert drag left: value increases',  s:get_value() == 460)
end

-- ---------------------------------------------------------------------------
-- on_drag NOT fired when value doesn't actually change (clamp dead zone).
-- ---------------------------------------------------------------------------
do
    local calls = {}
    local s = splitter_mod.new(new_parent(), {
        initial = 0, min = 0, max = 100,
        on_drag = function(v) calls[#calls + 1] = v end,
    })
    s:_begin_drag(0)
    s:_drag_to(-10)   -- below min, clamps to 0 (no change from initial)
    check('clamp dead zone: on_drag not fired', #calls == 0)
    s:_drag_to(50)
    check('move past dead zone: on_drag fires', #calls == 1 and calls[1] == 50)
    s:_drag_to(50)    -- same window pos as previous frame → no value change
    check('repeat at same pos: on_drag not fired', #calls == 1)
end

-- ---------------------------------------------------------------------------
-- _drag_to is a no-op when not dragging.
-- ---------------------------------------------------------------------------
do
    local fired = false
    local s = splitter_mod.new(new_parent(), {
        initial = 100,
        on_drag = function() fired = true end,
    })
    s:_drag_to(999)               -- never called _begin_drag
    check('drag without begin: value unchanged', s:get_value() == 100)
    check('drag without begin: on_drag not fired', fired == false)
end

-- ---------------------------------------------------------------------------
-- _end_drag clears dragging + fires on_drag_end.
-- ---------------------------------------------------------------------------
do
    local end_calls = 0
    local s = splitter_mod.new(new_parent(), {
        initial      = 100,
        on_drag_end  = function() end_calls = end_calls + 1 end,
    })
    s:_begin_drag(0)
    s:_drag_to(50)
    s:_end_drag()
    check('end: is_dragging false',             s:is_dragging() == false)
    check('end: on_drag_end fired once',        end_calls == 1)
    -- A second end_drag is a no-op.
    s:_end_drag()
    check('repeated end_drag: still 1 call',    end_calls == 1)
end

-- ---------------------------------------------------------------------------
-- set_range updates clamp bounds and pulls value in if it's outside.
-- ---------------------------------------------------------------------------
do
    local s = splitter_mod.new(new_parent(), { initial = 100, min = 0, max = 500 })
    s:set_value(450)
    s:set_range(0, 300)
    check('set_range shrinks max: value pulled in', s:get_value() == 300)
    s:set_range(200, 400)
    check('set_range raises min: value pulled in', s:get_value() == 300)
end

-- ---------------------------------------------------------------------------
-- set_bounds delegates to the underlying Static widget.
-- ---------------------------------------------------------------------------
do
    local s = splitter_mod.new(new_parent(), {})
    s:set_bounds(50, 60, 6, 400)
    check('set_bounds delegates',               last_static._bounds.x == 50
        and last_static._bounds.y == 60
        and last_static._bounds.w == 6
        and last_static._bounds.h == 400)
end

-- ---------------------------------------------------------------------------
-- show/hide delegate to setVisible.
-- ---------------------------------------------------------------------------
do
    local s = splitter_mod.new(new_parent(), {})
    s:show()
    check('show → setVisible(true)',            last_static._visible == true)
    s:hide()
    check('hide → setVisible(false)',           last_static._visible == false)
end

-- ---------------------------------------------------------------------------
-- The dxgui-callback wiring: simulate a mouse-down → move → up via the
-- registered callbacks and verify captureMouse / releaseMouse fire.
-- ---------------------------------------------------------------------------
do
    local s = splitter_mod.new(new_parent(), {
        initial = 100, min = 0, max = 500,
    })
    local btn = last_static
    s:set_bounds(440, 100, 6, 400)   -- splitter at window x=440

    -- Fire each registered callback. (We don't care which one — the
    -- module registers exactly one of each.)
    for _, cb in ipairs(btn._mouse_d) do cb(btn, 0, 0, 1) end
    check('mouse-down: captureMouse fired',     btn._captured == true)
    check('mouse-down: dragging',               s:is_dragging() == true)

    -- dxgui mx is already in window-coords. begin_drag stored 0 (the
    -- mouse-down's mx). Move with mx=10 → +10 from start.
    for _, cb in ipairs(btn._mouse_m) do cb(btn, 10, 0) end
    check('mouse-move +10: value updated',      s:get_value() == 110)

    for _, cb in ipairs(btn._mouse_u) do cb(btn, 10, 0, 1) end
    check('mouse-up: releaseMouse fired',       btn._released == true)
    check('mouse-up: not dragging',             s:is_dragging() == false)
end

print('')
if failures == 0 then
    print('All splitter tests passed.')
    os.exit(0)
else
    print(failures .. ' splitter tests FAILED.')
    os.exit(1)
end
