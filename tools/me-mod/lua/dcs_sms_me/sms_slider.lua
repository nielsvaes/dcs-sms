-- sms_slider.lua — a horizontal slider for the DCS-SMS tool windows: a track
-- + a draggable handle + an editable numeric value box, kept two-way in sync
-- (drag the handle / click the track, OR type a number — they stay equal).
--
-- DELIBERATELY HAND-ROLLED rather than using dxgui's native `Slider`.
-- Nothing else in this mod uses ED's Slider; every house widget (sms_window,
-- sms_scrollbars, splitter, tri_state_button, clearable_edit) is hand-rolled
-- from Static/EditBox/Button. We do the same here for full control over the
-- look (house skins), explicit step/range/decimals semantics, a single clean
-- on_change callback, and a pure, unit-testable value<->pixel core. The
-- splitter is the drag-handle template; clearable_edit is the composite
-- (several sibling raw widgets parented to one container) template.
--
-- Composite — three sibling widgets parented to the caller's container:
--   * track     — a thin Static groove (inserted first).
--   * handle    — a small Static knob (inserted AFTER the track → renders on
--                 top); the dragged element, captures the mouse.
--   * value box — an EditBox at the right edge showing/accepting the value.
--
-- Coordinates: like splitter.lua, the x passed to addMouseMoveCallback is
-- ALREADY window-coords. We map it against the track's stored window-x to a
-- fraction along the track. captureMouse/releaseMouse keep the drag alive
-- when the cursor leaves the handle. dxgui has no setCursor, so the visible
-- handle is the only affordance (same as splitter).
--
-- Public:
--   M.new(parent_raw, opts) -> panel | nil   (nil if Static/EditBox absent)
--   opts: initial, min, max, step, decimals, value_w, tooltip, on_change(value)
--   panel: set_bounds, get_value, set_value, set_range, set_enabled,
--          set_visible/show/hide, widget, is_dragging
--          + camelCase aliases setBounds/setVisible/setEnabled/getValue/setValue
--   M._math: clamp, quantize, value_to_frac, handle_x, x_to_value (pure; tested)

local skin_helper = require('dcs_sms_me.skin_helper')

local Static;  do local ok, m = pcall(require, 'Static');  if ok then Static  = m end end
local EditBox; do local ok, m = pcall(require, 'EditBox'); if ok then EditBox = m end end

local HANDLE_W = 10
local TRACK_H  = 4
local GAP      = 6

local M = {}

-- ---------------------------------------------------------------------------
-- Pure math (no dxgui) — exposed for tests.
-- ---------------------------------------------------------------------------
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Snap v to the nearest (min + k*step) grid point. step <= 0 → no snapping.
local function quantize(v, min, step)
    if not step or step <= 0 then return v end
    local k = math.floor((v - min) / step + 0.5)
    return min + k * step
end

-- Fraction [0,1] of value along [min,max]. Zero/negative range → 0.
local function value_to_frac(value, min, max)
    if max <= min then return 0 end
    return clamp((value - min) / (max - min), 0, 1)
end

-- Left pixel of the handle so its centre tracks the value and it stays fully
-- inside the track.
local function handle_x(value, min, max, track_x, track_w, handle_w)
    local frac   = value_to_frac(value, min, max)
    local centre = track_x + frac * track_w
    local left   = centre - handle_w / 2
    return clamp(left, track_x, track_x + math.max(0, track_w - handle_w))
end

-- Map a window mouse-x to a value: fraction along the track, scaled to
-- [min,max], quantized to step, clamped to range.
local function x_to_value(mouse_x, min, max, track_x, track_w, step)
    local w    = math.max(1, track_w)
    local frac = clamp((mouse_x - track_x) / w, 0, 1)
    local v    = min + frac * (max - min)
    return clamp(quantize(v, min, step), min, max)
end

M._math = {
    clamp = clamp, quantize = quantize, value_to_frac = value_to_frac,
    handle_x = handle_x, x_to_value = x_to_value,
}

-- ---------------------------------------------------------------------------
-- Widget
-- ---------------------------------------------------------------------------
function M.new(parent_raw, opts)
    if not (Static and Static.new and EditBox and EditBox.new) then return nil end
    opts = opts or {}

    local ok_t, track  = pcall(Static.new, '')
    local ok_h, handle = pcall(Static.new, '')
    local ok_b, box    = pcall(EditBox.new)
    if not (ok_t and track and ok_h and handle and ok_b and box) then return nil end

    skin_helper.apply(track,  'sms_slider_track')
    skin_helper.apply(handle, 'sms_slider_handle')
    skin_helper.apply(box,    'editBoxSkin_ME')
    if opts.tooltip then
        pcall(function() handle:setTooltipText(opts.tooltip) end)
        pcall(function() box:setTooltipText(opts.tooltip) end)
    end

    -- Parent order: track first, handle after (on top), box last.
    if parent_raw and parent_raw.insertWidget then
        pcall(parent_raw.insertWidget, parent_raw, track)
        pcall(parent_raw.insertWidget, parent_raw, handle)
        pcall(parent_raw.insertWidget, parent_raw, box)
    end

    local self = {
        _track = track, _handle = handle, _box = box,
        _min       = tonumber(opts.min)  or 0,
        _max       = tonumber(opts.max)  or 1,
        _step      = tonumber(opts.step) or 1,
        _decimals  = tonumber(opts.decimals) or 0,
        _value_w   = tonumber(opts.value_w)  or 52,
        _on_change = opts.on_change,
        _value     = 0,
        _dragging  = false,
        _enabled   = true,
        _track_x   = nil, _track_w = nil, _row_y = nil, _row_h = nil,
        _suppress_box_cb = false,
    }
    self._value = clamp(quantize(tonumber(opts.initial) or self._min, self._min, self._step),
                        self._min, self._max)

    function self:_format()
        if self._decimals and self._decimals > 0 then
            return string.format('%.' .. self._decimals .. 'f', self._value)
        end
        return tostring(math.floor(self._value + 0.5))
    end

    -- Reposition the handle (if laid out) and rewrite the value box text.
    -- The box rewrite is suppressed from re-triggering the change callback.
    function self:_reflect()
        if self._track_w then
            local hx = handle_x(self._value, self._min, self._max,
                                self._track_x, self._track_w, HANDLE_W)
            pcall(function() self._handle:setBounds(math.floor(hx + 0.5),
                                                    self._row_y, HANDLE_W, self._row_h) end)
        end
        self._suppress_box_cb = true
        pcall(function() self._box:setText(self:_format()) end)
        self._suppress_box_cb = false
    end

    -- Set value from an interaction (drag/click). Fires on_change only when the
    -- value actually changed (clamp dead-zone produces no spurious callbacks).
    function self:_set_from_interaction(v)
        v = clamp(v, self._min, self._max)
        local changed = (v ~= self._value)
        self._value = v
        self:_reflect()
        if changed and self._on_change then pcall(self._on_change, v) end
    end

    function self:_apply_mouse_x(mouse_x)
        if not self._track_w then return end
        self:_set_from_interaction(
            x_to_value(mouse_x, self._min, self._max, self._track_x, self._track_w, self._step))
    end

    -- Drag state machine (exposed for tests; the dxgui callbacks below wrap it).
    function self:_begin_drag(mouse_x)
        if not self._enabled then return end
        self._dragging = true
        self:_apply_mouse_x(mouse_x)   -- jump to the cursor (click-to-position)
    end
    function self:_drag_to(mouse_x)
        if not self._dragging then return end
        self:_apply_mouse_x(mouse_x)
    end
    function self:_end_drag()
        if not self._dragging then return end
        self._dragging = false
    end

    -- Public API.
    function self:widget()      return self._box end
    function self:get_value()   return self._value end
    function self:is_dragging() return self._dragging end

    function self:set_value(v)
        self._value = clamp(quantize(tonumber(v) or self._value, self._min, self._step),
                            self._min, self._max)
        self:_reflect()
    end

    function self:set_range(min_v, max_v)
        self._min = tonumber(min_v) or self._min
        self._max = tonumber(max_v) or self._max
        self._value = clamp(self._value, self._min, self._max)
        self:_reflect()
    end

    function self:set_bounds(x, y, w, h)
        local box_w   = self._value_w
        local track_w = math.max(1, w - box_w - GAP)
        local track_y = y + math.floor((h - TRACK_H) / 2)
        self._track_x, self._track_w = x, track_w
        self._row_y,  self._row_h    = y, h
        pcall(function() self._track:setBounds(x, track_y, track_w, TRACK_H) end)
        pcall(function() self._box:setBounds(x + track_w + GAP, y, box_w, h) end)
        self:_reflect()
    end

    function self:set_enabled(v)
        local en = v and true or false
        self._enabled = en
        pcall(function() if self._box.setEnabled    then self._box:setEnabled(en)    end end)
        pcall(function() if self._handle.setEnabled then self._handle:setEnabled(en) end end)
        pcall(function() if self._track.setEnabled  then self._track:setEnabled(en)  end end)
    end

    function self:set_visible(v)
        local vis = v and true or false
        pcall(function() if self._track.setVisible  then self._track:setVisible(vis)  end end)
        pcall(function() if self._handle.setVisible then self._handle:setVisible(vis) end end)
        pcall(function() if self._box.setVisible    then self._box:setVisible(vis)    end end)
    end
    function self:show() self:set_visible(true)  end
    function self:hide() self:set_visible(false) end

    -- camelCase aliases so the panel drops into form code (and the Paint
    -- Statics readers) that call raw-widget method names.
    self.setBounds  = function(s, x, y, w, h) s:set_bounds(x, y, w, h) end
    self.setVisible = function(s, v) s:set_visible(v) end
    self.setEnabled = function(s, v) s:set_enabled(v) end
    self.getValue   = function(s) return s:get_value() end
    self.setValue   = function(s, v) s:set_value(v) end

    -- Value box typed input: clamp to range, do NOT step-snap (so an exact
    -- 1.0 survives), reposition the handle but do NOT rewrite the box (the
    -- user is typing). Ignore mid-type non-numbers.
    if box.addChangeCallback then
        pcall(box.addChangeCallback, box, function(b)
            if self._suppress_box_cb then return end
            local txt = (b.getText and b:getText()) or ''
            local n = tonumber(txt)
            if not n then return end
            local v = clamp(n, self._min, self._max)
            local changed = (v ~= self._value)
            self._value = v
            if self._track_w then
                local hx = handle_x(self._value, self._min, self._max,
                                    self._track_x, self._track_w, HANDLE_W)
                pcall(function() self._handle:setBounds(math.floor(hx + 0.5),
                                                        self._row_y, HANDLE_W, self._row_h) end)
            end
            if changed and self._on_change then pcall(self._on_change, v) end
        end)
    end

    -- Drag wiring shared by the handle and the track (click-on-track jumps,
    -- then continues as a drag). Each callback pcall'd so a stripped VM never
    -- throws at construction.
    local function wire_drag(widget)
        if widget.addMouseDownCallback then
            pcall(widget.addMouseDownCallback, widget, function(ws, mx, my, button)
                if button ~= 1 then return end
                if not self._enabled then return end
                self:_begin_drag(mx)
                if ws.captureMouse then pcall(ws.captureMouse, ws) end
            end)
        end
        if widget.addMouseMoveCallback then
            pcall(widget.addMouseMoveCallback, widget, function(ws, mx, my)
                if not self._dragging then return end
                self:_drag_to(mx)
            end)
        end
        if widget.addMouseUpCallback then
            pcall(widget.addMouseUpCallback, widget, function(ws, mx, my, button)
                if button ~= 1 then return end
                if ws.releaseMouse then pcall(ws.releaseMouse, ws) end
                self:_end_drag()
            end)
        end
    end
    wire_drag(handle)
    wire_drag(track)

    -- Initial text (handle is positioned on the first set_bounds).
    self:_reflect()

    return self
end

return M
