-- Standalone test for tri_state_button.lua.
--
-- Stubs dxgui's Button + Skin so the module loads in the test VM, then
-- verifies the public API: state cycle, compose_text, set_state /
-- get_state, set_label, on_change, and degraded behavior when Button
-- isn't available.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Capture every setSkin / setText / setBounds / addMouseDownCallback call
-- on every Button instance so tests can assert what was applied.
local last_button   -- most recently constructed Button stub
local function new_button_stub()
    local b = {
        _text       = nil,
        _skin       = nil,
        _bounds     = nil,
        _visible    = nil,
        _mouse_cbs  = {},
    }
    function b:setText(t)     self._text   = t end
    function b:setSkin(s)     self._skin   = s end
    function b:setBounds(x,y,w,h) self._bounds = { x=x, y=y, w=w, h=h } end
    function b:setVisible(v)  self._visible = v end
    function b:addMouseDownCallback(cb) self._mouse_cbs[#self._mouse_cbs + 1] = cb end
    function b:click()
        for _, cb in ipairs(self._mouse_cbs) do cb() end
    end
    last_button = b
    return b
end

package.preload['Button'] = function() return { new = new_button_stub } end

-- skin_helper.apply needs Skin to look up named skins; return a sentinel
-- table for any name so we can distinguish skin swaps without modelling
-- the full skin tree.
package.preload['Skin'] = function()
    return setmetatable({}, { __index = function(_, k) return function() return { _skin_name = k } end end })
end

-- sms_skins is consulted directly by skin_helper for sms_* names; return
-- a stub that yields { _which = name } so tests can identify which color
-- the tri-state button asked for.
package.preload['dcs_sms_me.sms_skins'] = function()
    return {
        button     = function() return { _which = 'leave' } end,
        button_on  = function() return { _which = 'on'    } end,
        button_off = function() return { _which = 'off'   } end,
    }
end

local tsb_mod = require('dcs_sms_me.tri_state_button')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- ---------------------------------------------------------------------------
-- Module shape + pure helpers
-- ---------------------------------------------------------------------------
do
    check('STATE_LEAVE = 0',                          tsb_mod.STATE_LEAVE == 0)
    check('STATE_ON = 1',                             tsb_mod.STATE_ON    == 1)
    check('STATE_OFF = 2',                            tsb_mod.STATE_OFF   == 2)
    check('M.new is a function',                      type(tsb_mod.new) == 'function')
    check('compose_text is a function',               type(tsb_mod.compose_text) == 'function')
    check('next_state is a function',                 type(tsb_mod.next_state) == 'function')
end

do
    check('compose_text LEAVE',                       tsb_mod.compose_text('Foo', tsb_mod.STATE_LEAVE) == 'Foo —')
    check('compose_text ON',                          tsb_mod.compose_text('Foo', tsb_mod.STATE_ON)    == 'Foo ON')
    check('compose_text OFF',                         tsb_mod.compose_text('Foo', tsb_mod.STATE_OFF)   == 'Foo OFF')
    check('compose_text nil label',                   tsb_mod.compose_text(nil, tsb_mod.STATE_LEAVE) == ' —')
    check('compose_text unknown state → LEAVE suffix', tsb_mod.compose_text('X', 99) == 'X —')
end

do
    check('next_state LEAVE → ON',                    tsb_mod.next_state(tsb_mod.STATE_LEAVE) == tsb_mod.STATE_ON)
    check('next_state ON → OFF',                      tsb_mod.next_state(tsb_mod.STATE_ON)    == tsb_mod.STATE_OFF)
    check('next_state OFF → LEAVE',                   tsb_mod.next_state(tsb_mod.STATE_OFF)   == tsb_mod.STATE_LEAVE)
    check('next_state nil → ON (treated as LEAVE)',   tsb_mod.next_state(nil) == tsb_mod.STATE_ON)
    check('next_state bogus → ON',                    tsb_mod.next_state(42)  == tsb_mod.STATE_ON)
end

-- ---------------------------------------------------------------------------
-- Construction + initial state
-- ---------------------------------------------------------------------------
do
    local parent = { _inserted = {} }
    function parent:insertWidget(w) self._inserted[#self._inserted + 1] = w end

    local tsb = tsb_mod.new(parent, 'Hidden on map')
    check('new returns a table',                      type(tsb) == 'table')
    check('parent.insertWidget was called',           #parent._inserted == 1)
    check('initial state = LEAVE',                    tsb:get_state() == tsb_mod.STATE_LEAVE)
    check('initial text = "Hidden on map —"',         last_button._text == 'Hidden on map —')
    check('initial skin = leave (sms_button)',        last_button._skin and last_button._skin._which == 'leave')
    check('widget() returns underlying button',       tsb:widget() == last_button)
end

-- ---------------------------------------------------------------------------
-- set_state changes text + skin + state + fires on_change
-- ---------------------------------------------------------------------------
do
    local tsb = tsb_mod.new({}, 'X')
    local btn = last_button

    local change_calls = {}
    tsb:on_change(function(self, st) change_calls[#change_calls + 1] = st end)

    tsb:set_state(tsb_mod.STATE_ON)
    check('set_state ON: get_state',                  tsb:get_state() == tsb_mod.STATE_ON)
    check('set_state ON: text suffix',                btn._text == 'X ON')
    check('set_state ON: skin = on',                  btn._skin and btn._skin._which == 'on')
    check('set_state ON: on_change fired',            #change_calls == 1 and change_calls[1] == tsb_mod.STATE_ON)

    tsb:set_state(tsb_mod.STATE_OFF)
    check('set_state OFF: get_state',                 tsb:get_state() == tsb_mod.STATE_OFF)
    check('set_state OFF: text suffix',               btn._text == 'X OFF')
    check('set_state OFF: skin = off',                btn._skin and btn._skin._which == 'off')

    tsb:set_state(tsb_mod.STATE_LEAVE)
    check('set_state LEAVE: get_state',               tsb:get_state() == tsb_mod.STATE_LEAVE)
    check('set_state LEAVE: text suffix',             btn._text == 'X —')
    check('set_state LEAVE: skin = leave',            btn._skin and btn._skin._which == 'leave')

    -- Invalid state should be a no-op.
    tsb:set_state(99)
    check('set_state(99) keeps prior state',          tsb:get_state() == tsb_mod.STATE_LEAVE)
end

-- ---------------------------------------------------------------------------
-- Click cycles state
-- ---------------------------------------------------------------------------
do
    local tsb = tsb_mod.new({}, 'C')
    local btn = last_button

    btn:click()
    check('click 1: state = ON',                      tsb:get_state() == tsb_mod.STATE_ON)
    btn:click()
    check('click 2: state = OFF',                     tsb:get_state() == tsb_mod.STATE_OFF)
    btn:click()
    check('click 3: state = LEAVE (cycle)',           tsb:get_state() == tsb_mod.STATE_LEAVE)
    btn:click()
    check('click 4: state = ON again',                tsb:get_state() == tsb_mod.STATE_ON)
end

-- ---------------------------------------------------------------------------
-- set_label preserves current state's suffix
-- ---------------------------------------------------------------------------
do
    local tsb = tsb_mod.new({}, 'Old')
    local btn = last_button
    tsb:set_state(tsb_mod.STATE_OFF)
    tsb:set_label('New')
    check('set_label: text = "New OFF"',              btn._text == 'New OFF')
    check('set_label: state preserved (OFF)',         tsb:get_state() == tsb_mod.STATE_OFF)
end

-- ---------------------------------------------------------------------------
-- set_bounds + set_visible delegate to widget
-- ---------------------------------------------------------------------------
do
    local tsb = tsb_mod.new({}, 'B')
    local btn = last_button
    tsb:set_bounds(10, 20, 100, 24)
    check('set_bounds delegates',                     btn._bounds and btn._bounds.x == 10 and btn._bounds.w == 100)
    tsb:set_visible(true)
    check('set_visible true delegates',               btn._visible == true)
    tsb:set_visible(false)
    check('set_visible false delegates',              btn._visible == false)
end

-- ---------------------------------------------------------------------------
-- Returns nil when Button.new fails
-- ---------------------------------------------------------------------------
do
    -- Replace Button with one whose .new raises.
    package.loaded['Button'] = { new = function() error('boom') end }
    -- tri_state_button captured Button at load time, so to test the
    -- pcall-failure branch we need to wipe the captured value and force
    -- a reload.
    package.loaded['dcs_sms_me.tri_state_button'] = nil
    local fresh = require('dcs_sms_me.tri_state_button')
    local out = fresh.new({}, 'Z')
    check('new returns nil when Button.new fails',    out == nil)
end

print('')
if failures == 0 then
    print('All tri_state_button tests passed.')
    os.exit(0)
else
    print(failures .. ' tri_state_button tests FAILED.')
    os.exit(1)
end
