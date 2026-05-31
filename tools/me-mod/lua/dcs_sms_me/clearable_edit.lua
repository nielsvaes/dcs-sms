-- clearable_edit.lua — an EditBox with an inline "clear" button (×)
-- overlaid at its right edge. Mirrors Qt's QLineEdit.setClearButtonEnabled
-- behavior: the X only shows when the text is non-empty, and clicking
-- it wipes the text + fires the on_change callback.
--
-- Composite widget:
--   * EditBox     — the actual text input, takes the full composite bounds.
--   * Button (×)  — overlaid INSIDE the EditBox at the right edge, ~18px
--                   wide. Auto-hidden when text is empty.
--
-- Both children are parented to the same parent_raw the caller passes
-- in. Insert order matters for z-order — the button goes IN AFTER the
-- editbox so it renders on top.
--
-- Public:
--   M.new(parent_raw, opts) → panel { set_bounds, set_text, get_text,
--                                     set_visible, widget }
--     parent_raw     : a container that accepts insertWidget.
--     opts.initial_text : default ''. Initial value (and on_change fires
--                         only on user input afterwards, not on this).
--     opts.skin         : EditBox skin name. Default 'editBoxSkin_ME'.
--     opts.clear_skin   : Clear button skin. Default 'dtc_button_translucent'
--                         (75% opacity so the × sits visually softer
--                         inside the editbox instead of dominating).
--     opts.clear_glyph  : Text shown on the clear button. Default '×'.
--     opts.clear_w      : Pixel width / height of the clear button square.
--                         Default 18.
--     opts.on_change    : function(text) — fires when the EditBox text
--                         changes via user input, AND when the clear
--                         button is clicked (called with '').

local skin_helper = require('dcs_sms_me.skin_helper')

local EditBox; do local ok, m = pcall(require, 'EditBox'); if ok then EditBox = m end end
local Button;  do local ok, m = pcall(require, 'Button');  if ok then Button  = m end end

local M = {}

function M.new(parent_raw, opts)
    if not (EditBox and EditBox.new) then return nil end
    opts = opts or {}

    local ok_eb, eb = pcall(EditBox.new)
    if not (ok_eb and eb) then return nil end
    skin_helper.apply(eb, opts.skin or 'editBoxSkin_ME')
    if parent_raw and parent_raw.insertWidget then
        pcall(parent_raw.insertWidget, parent_raw, eb)
    end

    local initial = tostring(opts.initial_text or '')
    if eb.setText then pcall(eb.setText, eb, initial) end

    local clear_w = opts.clear_w or 18
    local clear_btn
    if Button and Button.new then
        local ok_b, b = pcall(Button.new)
        if ok_b and b then
            skin_helper.apply(b, opts.clear_skin or 'dtc_button_translucent')
            if b.setText then pcall(b.setText, b, opts.clear_glyph or '×') end
            if b.setTooltipText then pcall(b.setTooltipText, b, 'Clear') end
            if parent_raw and parent_raw.insertWidget then
                -- Inserted AFTER the editbox so it renders on top.
                pcall(parent_raw.insertWidget, parent_raw, b)
            end
            clear_btn = b
        end
    end

    local self = {
        _eb        = eb,
        _btn       = clear_btn,
        _clear_w   = clear_w,
        _on_change = opts.on_change,
        -- Tracks the most recently-laid-out composite bounds so the
        -- internal sync_button_visibility helper can reposition the X
        -- without the caller needing to re-issue set_bounds.
        _bounds    = nil,
    }

    -- Hide the X when text is empty; show when present. Called whenever
    -- the underlying text changes (user input or programmatic).
    local function sync_button_visibility()
        if not (self._btn and self._btn.setVisible) then return end
        local txt = (self._eb.getText and self._eb:getText()) or ''
        pcall(self._btn.setVisible, self._btn, txt ~= '')
    end

    function self:widget() return self._eb end

    function self:get_text()
        return (self._eb.getText and self._eb:getText()) or ''
    end

    function self:set_text(s)
        local v = tostring(s or '')
        if self._eb.setText then pcall(self._eb.setText, self._eb, v) end
        sync_button_visibility()
    end

    function self:set_visible(v)
        if self._eb.setVisible then pcall(self._eb.setVisible, self._eb, v == true) end
        if self._btn and self._btn.setVisible then
            -- When the composite becomes visible, only show the button if
            -- the text is non-empty. When hiding, hide both unconditionally.
            if v == true then
                sync_button_visibility()
            else
                pcall(self._btn.setVisible, self._btn, false)
            end
        end
    end

    function self:set_enabled(v)
        local en = v and true or false
        if self._eb.setEnabled then pcall(self._eb.setEnabled, self._eb, en) end
        if self._btn and self._btn.setEnabled then pcall(self._btn.setEnabled, self._btn, en) end
    end

    function self:set_bounds(x, y, w, h)
        self._bounds = { x = x, y = y, w = w, h = h }
        if self._eb.setBounds then pcall(self._eb.setBounds, self._eb, x, y, w, h) end
        if self._btn and self._btn.setBounds then
            -- Overlay INSIDE the editbox at the right edge, vertically
            -- centered with a small inset so the X visually floats inside
            -- the field rather than butting against the editbox border.
            local inset_y = math.max(0, math.floor((h - self._clear_w) / 2))
            pcall(self._btn.setBounds, self._btn,
                  x + w - self._clear_w - 3,
                  y + inset_y,
                  self._clear_w,
                  math.min(self._clear_w, h))
        end
        sync_button_visibility()
    end

    -- camelCase aliases so the panel can be dropped into existing form
    -- code that calls widget.setBounds / widget.setVisible / widget.getText
    -- on a raw EditBox without per-call branching.
    self.setBounds  = function(s, x, y, w, h) s:set_bounds(x, y, w, h) end
    self.setVisible = function(s, v) s:set_visible(v) end
    self.setEnabled = function(s, v) s:set_enabled(v) end
    self.getText    = function(s) return s:get_text() end
    self.setText    = function(s, v) s:set_text(v) end

    -- Wire EditBox change → fire on_change + update button visibility.
    if eb.addChangeCallback then
        pcall(eb.addChangeCallback, eb, function(box)
            local txt = (box.getText and box:getText()) or ''
            sync_button_visibility()
            if self._on_change then pcall(self._on_change, txt) end
        end)
    end

    -- Wire clear button → clear text + fire on_change with ''.
    if clear_btn and clear_btn.addMouseDownCallback then
        pcall(clear_btn.addMouseDownCallback, clear_btn, function()
            pcall(function()
                if self._eb.setText then self._eb:setText('') end
                sync_button_visibility()
                if self._on_change then pcall(self._on_change, '') end
            end)
        end)
    end

    -- Initial visibility sync based on initial_text.
    sync_button_visibility()

    return self
end

return M
