-- tri_state_button.lua — a 3-state cycling button (LEAVE / ON / OFF).
--
-- Wraps a dxgui Button so callers don't reimplement the cycle + per-state
-- skin swap inline (toggle_group_flags was the first user; future mass-
-- edit forms that batch boolean writes can reuse this).
--
-- States:
--   STATE_LEAVE — "skip this in the batch". Label suffix `—`, neutral skin.
--   STATE_ON    — "set true". Label suffix `ON`, green skin.
--   STATE_OFF   — "set false". Label suffix `OFF`, red skin.
--
-- Each click cycles LEAVE → ON → OFF → LEAVE.
--
-- Public API:
--   M.STATE_LEAVE / M.STATE_ON / M.STATE_OFF — state constants.
--   M.new(parent_raw, label) → tsb
--   tsb:set_state(state)          -- force a state (also fires on_change)
--   tsb:get_state() → state
--   tsb:set_label(label)          -- relabel; current suffix preserved
--   tsb:on_change(cb)             -- cb(tsb, new_state) on every change
--   tsb:set_bounds(x, y, w, h)
--   tsb:set_visible(v)
--   tsb:widget() → underlying Button
--
-- The constructor returns nil if dxgui's Button is unavailable (test VMs
-- without the dxgui modules loaded) — callers should pcall through.

local skin_helper = require('dcs_sms_me.skin_helper')

local Button; do local ok, m = pcall(require, 'Button'); if ok then Button = m end end

local M = {}

M.STATE_LEAVE = 0
M.STATE_ON    = 1
M.STATE_OFF   = 2

local STATE_SUFFIX = {
    [M.STATE_LEAVE] = '—',
    [M.STATE_ON]    = 'ON',
    [M.STATE_OFF]   = 'OFF',
}

local STATE_SKIN = {
    [M.STATE_LEAVE] = 'sms_button',
    [M.STATE_ON]    = 'sms_button_on',
    [M.STATE_OFF]   = 'sms_button_off',
}

-- Exposed for tests / external callers that want to render the suffix
-- themselves without owning a widget.
M.STATE_SUFFIX = STATE_SUFFIX
M.STATE_SKIN   = STATE_SKIN

function M.compose_text(label, state)
    return tostring(label or '') .. ' ' .. (STATE_SUFFIX[state] or STATE_SUFFIX[M.STATE_LEAVE])
end

function M.next_state(state)
    local cur = (state == M.STATE_ON or state == M.STATE_OFF) and state or M.STATE_LEAVE
    return (cur + 1) % 3
end

function M.new(parent_raw, label)
    if not (Button and Button.new) then return nil end
    local ok, btn = pcall(Button.new)
    if not (ok and btn) then return nil end
    if parent_raw and parent_raw.insertWidget then
        pcall(parent_raw.insertWidget, parent_raw, btn)
    end

    local self = {
        _btn       = btn,
        _label     = tostring(label or ''),
        _state     = M.STATE_LEAVE,
        _on_change = nil,
    }

    function self:widget() return self._btn end

    function self:get_state() return self._state end

    function self:set_state(state)
        if state ~= M.STATE_LEAVE and state ~= M.STATE_ON and state ~= M.STATE_OFF then
            return
        end
        self._state = state
        if self._btn.setText then
            pcall(self._btn.setText, self._btn, M.compose_text(self._label, state))
        end
        skin_helper.apply(self._btn, STATE_SKIN[state] or 'sms_button')
        if self._on_change then pcall(self._on_change, self, state) end
    end

    function self:set_label(label)
        self._label = tostring(label or '')
        if self._btn.setText then
            pcall(self._btn.setText, self._btn, M.compose_text(self._label, self._state))
        end
    end

    function self:on_change(cb) self._on_change = cb end

    function self:set_bounds(x, y, w, h)
        if self._btn.setBounds then pcall(self._btn.setBounds, self._btn, x, y, w, h) end
    end

    function self:set_visible(v)
        if self._btn.setVisible then pcall(self._btn.setVisible, self._btn, v == true) end
    end

    -- Initialize text + skin to LEAVE.
    self:set_state(M.STATE_LEAVE)

    -- Click cycles state.
    if self._btn.addMouseDownCallback then
        pcall(self._btn.addMouseDownCallback, self._btn, function()
            pcall(function()
                self:set_state(M.next_state(self._state))
            end)
        end)
    end

    return self
end

return M
