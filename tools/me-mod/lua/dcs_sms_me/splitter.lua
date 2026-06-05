-- splitter.lua — Qt QSplitter-style drag handle for resizing two
-- horizontally-stacked panes.
--
-- The widget is a thin vertical Static parented to a host window.
-- Mouse-down captures the mouse and records start state; mouse-move
-- computes the absolute drag distance via widgetToWindow and feeds the
-- new logical "split value" to the on_drag callback. Mouse-up releases
-- the capture.
--
-- The host owns the actual layout state (e.g. `LAYOUT.FORM_PANE_W` in
-- mass_edit.lua). The splitter just translates pixel drags into a
-- clamped value and notifies. It does NOT call relayout itself — the
-- on_drag callback does that, so the splitter stays layout-agnostic.
--
-- About coordinates: the x/y passed to addMouseMoveCallback in this
-- dxgui are ALREADY in window-coords, not widget-local. (Adding
-- bounds.x to them — or going through widgetToWindow — double-counts
-- the widget's own position, which causes the splitter to run away
-- from the cursor as it moves with the drag. Empirically verified.)
--
-- So we just use mx directly as the mouse's window-x: stable across
-- frames regardless of how the splitter itself has been repositioned
-- by a previous on_drag callback.
--
-- About capture: the mouse-leave fallback that imagePreview uses works
-- when the widget stays still, but not when the widget moves with the
-- drag. captureMouse / releaseMouse is the robust pattern that's also
-- what me_encyclopedia / me_loadout use for their drag interactions.
--
-- Public:
--   M.new(parent_raw, opts) → panel { set_bounds, set_value, get_value,
--                                     widget, show, hide, is_dragging }
--     parent_raw : window or raw container that accepts insertWidget
--     opts.initial   : starting value (the value passed to on_drag if
--                      the user starts a drag with no prior set_value).
--                      Default: 0.
--     opts.min, max  : clamp range. Defaults: -math.huge / math.huge.
--     opts.invert    : when true, dragging right DECREASES the value.
--                      (Use this when the value represents the WIDTH of
--                      the pane to the RIGHT of the splitter — dragging
--                      the splitter right shrinks that pane.) Default: false.
--     opts.skin      : skin name to apply to the Static (default
--                      'sms_splitter' if available, else nil).
--     opts.on_drag   : function(new_value) called on every mouse-move
--                      while dragging. Synchronous; the callback is
--                      free to mutate layout state and call relayout.
--     opts.on_drag_end : optional. function() called on mouse-up,
--                      after releaseMouse. Useful for persisting the
--                      chosen value.

local skin_helper = require('dcs_sms_me.skin_helper')

local Static; do local ok, m = pcall(require, 'Static'); if ok then Static = m end end

local M = {}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function M.new(parent_raw, opts)
    if not (Static and Static.new) then return nil end
    opts = opts or {}

    local ok, s = pcall(Static.new, '')
    if not (ok and s) then return nil end

    local skin = opts.skin or 'sms_splitter'
    if skin then skin_helper.apply(s, skin) end

    if parent_raw and parent_raw.insertWidget then
        pcall(parent_raw.insertWidget, parent_raw, s)
    end

    local self = {
        _widget    = s,
        _value     = opts.initial or 0,
        _min       = opts.min or -math.huge,
        _max       = opts.max or  math.huge,
        _invert    = opts.invert == true,
        _on_drag   = opts.on_drag,
        _on_end    = opts.on_drag_end,
        _dragging  = false,
        _start_wx  = 0,
        _start_v   = 0,
    }

    function self:widget()       return self._widget end
    function self:get_value()    return self._value end
    function self:is_dragging()  return self._dragging end

    function self:set_value(v)
        self._value = clamp(tonumber(v) or self._value, self._min, self._max)
    end

    function self:set_range(min_v, max_v)
        self._min = tonumber(min_v) or self._min
        self._max = tonumber(max_v) or self._max
        if self._value < self._min then self._value = self._min end
        if self._value > self._max then self._value = self._max end
    end

    function self:set_bounds(x, y, w, h)
        if self._widget.setBounds then pcall(self._widget.setBounds, self._widget, x, y, w, h) end
    end

    function self:show() if self._widget.setVisible then pcall(self._widget.setVisible, self._widget, true) end end
    function self:hide() if self._widget.setVisible then pcall(self._widget.setVisible, self._widget, false) end end

    -- Drag dispatch. Exposed so tests can drive it without firing real
    -- dxgui events.
    function self:_begin_drag(window_x)
        self._dragging = true
        self._start_wx = window_x
        self._start_v  = self._value
    end

    function self:_drag_to(window_x)
        if not self._dragging then return end
        local total_dx = window_x - self._start_wx
        if self._invert then total_dx = -total_dx end
        local new_v = clamp(self._start_v + total_dx, self._min, self._max)
        if new_v ~= self._value then
            self._value = new_v
            if self._on_drag then pcall(self._on_drag, new_v) end
        end
    end

    function self:_end_drag()
        if not self._dragging then return end
        self._dragging = false
        if self._on_end then pcall(self._on_end) end
    end

    -- Wire dxgui callbacks. Each wrapped in pcall so a missing API in
    -- a stripped test VM doesn't blow up module load.
    if s.addMouseDownCallback then
        pcall(s.addMouseDownCallback, s, function(self_s, mx, my, button)
            if button ~= 1 then return end
            self:_begin_drag(mx)
            if self_s.captureMouse then pcall(self_s.captureMouse, self_s) end
        end)
    end

    if s.addMouseMoveCallback then
        pcall(s.addMouseMoveCallback, s, function(self_s, mx, my)
            if not self._dragging then return end
            self:_drag_to(mx)
        end)
    end

    if s.addMouseUpCallback then
        pcall(s.addMouseUpCallback, s, function(self_s, mx, my, button)
            if button ~= 1 then return end
            if self_s.releaseMouse then pcall(self_s.releaseMouse, self_s) end
            self:_end_drag()
        end)
    end

    return self
end

return M
