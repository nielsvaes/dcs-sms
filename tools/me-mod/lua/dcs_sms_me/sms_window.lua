-- sms_window.lua — Reusable window factory for ME-mod tool windows.
--
-- Owns the shared chrome that every ME-mod tool window needs:
--   * Branded title bar     ('Coconut Cockpit · DCS-SMS — <title> v<version>')
--   * Footer separator + colored status Static, with set_status (sticky)
--     and flash_status (auto-revert) semantics.
--   * Close button → :hide() (idempotent).
--   * File > New / File > Open closes the window (additive subscriber).
--   * Ctrl+Z hotkey → opts.on_undo callback (or default undo.undo + flash).
--   * Resize clamp + footer reposition + dispatch to opts.on_resize.
--
-- This is a lightweight handle/factory — call sms_window.new(opts) and you
-- get back a handle with methods. No inheritance, no class-extension; tool
-- windows hold the handle on their own state (e.g. W.sms_window) and pass
-- opts callbacks to override behaviors. Same idiom prefab_manager.lua uses.
--
-- Public module API:
--   sms_window.new(opts) → handle | nil
--   sms_window.compose_title(title, version) → string
--   sms_window.default_on_undo(handle)  -- compose with this from your opts.on_undo
--
-- Handle methods:
--   handle:show() / :hide() / :toggle()           — idempotent lifecycle
--   handle:get_content_bounds() → x, y, w, h      — usable area inside chrome
--   handle:set_status(text, severity)              — sticky footer status
--   handle:flash_status(text, severity, [timeout]) — flash, auto-revert in N sec
--   handle:raw() → underlying dxgui Window         — escape hatch
--
-- Opt callbacks (all optional):
--   opts.on_undo(handle)               — Ctrl+Z handler; falls back to default_on_undo
--   opts.on_resize(handle, x, y, w, h) — called on every resize with the content rect
--   opts.on_close(handle)              — called when handle:hide() runs

-- Pure helpers exposed for testing. Underscore-prefixed names (_validate_severity,
-- _new_flash_state, _on_set_status, _on_flash_status, _on_tick) are test-internal;
-- compose_title and default_on_undo are public module API.
local M = {}

-- Severity → skin name. Centralised; replaces the SEVERITY_SKIN tables
-- previously duplicated in window.lua and group_tools.lua.
local SEVERITY_SKIN = {
    info     = 'staticSkin_ME',
    success  = 'sms_status_green',
    warning  = 'sms_status_yellow',
    error    = 'sms_status_red',
}

-- Map a severity string to its skin name. Unknown / nil severities fall
-- back to 'info'. Returned skin name is consumed by try_skin (live
-- module) or the test (pure assertion).
function M._validate_severity(severity)
    return SEVERITY_SKIN[severity] or SEVERITY_SKIN.info
end

-- Compose the branded title string. Single source of truth so every
-- window's title bar reads the same.
function M.compose_title(title, version)
    return 'Coconut Cockpit · DCS-SMS — ' .. tostring(title) .. ' v' .. tostring(version)
end

-- ---------- Flash state machine ----------
--
-- Pure helpers that the live class uses by composition. Decoupling the
-- state machine from the dxgui Static lets us unit-test the transitions
-- without a real window.
--
-- State shape:
--   sticky_text      : string  -- last set_status text (rendered when flash expires)
--   sticky_severity  : string  -- last set_status severity
--   flash_expires_at : number  -- os.time when an active flash should revert; nil = no flash

function M._new_flash_state()
    return {
        sticky_text      = nil,
        sticky_severity  = nil,
        flash_expires_at = nil,
    }
end

-- Record a sticky status update + cancel any in-flight flash. Returns the
-- (text, severity) that should be rendered now.
function M._on_set_status(state, text, severity)
    state.sticky_text      = text
    state.sticky_severity  = severity
    state.flash_expires_at = nil
    return text, severity
end

-- Start a flash. Sticky baseline is left untouched; the flash overlays for
-- `timeout` seconds (default 5) starting from `now`. Returns the (text,
-- severity) that should be rendered now.
function M._on_flash_status(state, text, severity, timeout, now)
    state.flash_expires_at = now + (timeout or 5)
    return text, severity
end

-- Per-frame tick. If a flash has expired, returns the (text, severity) we
-- should revert to (the sticky baseline, defaulting to empty/info if none
-- was set). If no flash or not yet expired, returns nil.
function M._on_tick(state, now)
    if state.flash_expires_at == nil then return nil end
    if now < state.flash_expires_at then return nil end
    state.flash_expires_at = nil
    local text = state.sticky_text or ''
    local sev  = state.sticky_severity or 'info'
    return text, sev
end

-- ---------- Live class (dxgui-bound) ----------
--
-- Below this point the module talks to the dxgui module-table widgets
-- (Window, Static, Skin, UpdateManager) and the project's hooks
-- (new_mission_hook, undo). These are pcall-guarded so the module still
-- loads in environments missing them (test VMs, older dxgui builds).

local Window;        do local ok, mod = pcall(require, 'Window');        if ok then Window        = mod end end
local Static;        do local ok, mod = pcall(require, 'Static');        if ok then Static        = mod end end
local Skin;          do local ok, mod = pcall(require, 'Skin');          if ok then Skin          = mod end end
local Gui;           do local ok, mod = pcall(require, 'dxgui');         if ok then Gui           = mod end end
local UpdateManager; do local ok, mod = pcall(require, 'UpdateManager'); if ok then UpdateManager = mod end end

local sms_skins;        do local ok, mod = pcall(require, 'dcs_sms_me.sms_skins');        if ok then sms_skins        = mod end end
local version          = require('dcs_sms_me.version')
local undo;             do local ok, mod = pcall(require, 'dcs_sms_me.undo');             if ok then undo             = mod end end
local new_mission_hook; do local ok, mod = pcall(require, 'dcs_sms_me.new_mission_hook'); if ok then new_mission_hook = mod end end

-- Layout constants (see spec — Layout model section).
--
-- dxgui Window has implicit ~50px of bottom chrome (window border / shadow)
-- that isn't queryable. Children rendered past `h - ~50` are clipped. The
-- original Prefab Manager (pre-refactor) placed its status static at
-- y = h - 73 (which clears the chrome with a 1px breathing margin) — these
-- constants match those numbers so the footer renders in the same place
-- it always has.
local TOP_PAD              = 8    -- breathing room at the top of the content area
local STATUS_H             = 22   -- height of the status Static
local STATUS_OFFSET_BOTTOM = 73   -- status Static top y = h - STATUS_OFFSET_BOTTOM
local SEP_OFFSET_BOTTOM    = 76   -- separator y     = h - SEP_OFFSET_BOTTOM (3px above status)
local EDGE_PAD             = 8    -- left/right gap between window edge and content rect

-- Resolve a skin by short name. Handles only the four severity skins +
-- the footer separator — every other skin name is delegated to the Skin
-- module's auto-generated factories (Skin.staticSkin_ME, etc).
local function try_skin(widget, skin_name)
    pcall(function()
        if not (widget and widget.setSkin) then return end
        local s
        if     skin_name == 'sms_status_green'  then s = sms_skins.static_green()
        elseif skin_name == 'sms_status_yellow' then s = sms_skins.static_yellow()
        elseif skin_name == 'sms_status_red'    then s = sms_skins.static_red()
        elseif skin_name == 'sms_separator'     then s = sms_skins.separator()
        else
            local fn = Skin and Skin[skin_name]
            if not fn then return end
            s = fn()
        end
        if s then widget:setSkin(s) end
    end)
end

local SMSWindow = {}
SMSWindow.__index = SMSWindow

-- Default position: top-right of the screen, 20px in from the right edge,
-- 80px down from the top. Falls back to 1920px screen width if dxgui
-- doesn't expose Gui.GetWindowSize.
local function default_position(w)
    local screen_w = 1920
    pcall(function()
        if Gui and Gui.GetWindowSize then
            local sw = Gui.GetWindowSize()
            if type(sw) == 'number' and sw > 0 then screen_w = sw end
        end
    end)
    return math.max(20, screen_w - w - 20), 80
end

-- Construct an SMSWindow. Returns nil (logged) if the dxgui Window can't
-- be created. Builds the title bar, footer separator + status Static.
-- The body (content area) is left empty — subclass populates via
-- :build_body() or the consumer inserts widgets imperatively after .new
-- returns.
--
-- opts (see spec for the full table):
--   title      string  required — branded with version
--   size       {w,h}   required — initial size in pixels
--   min_size   {w,h}   optional — defaults to opts.size
--   position   {x,y}   optional — defaults to top-right
--   persist_across_new_mission  boolean (default false)
--   disable_undo_hotkey         boolean (default false)
--   on_undo    function(self)                  optional override
--   on_resize  function(self, x, y, w, h)      optional override
--   on_close   function(self)                  optional cleanup hook
function SMSWindow.new(opts)
    if type(opts) ~= 'table' then
        log.write('sms.me', log.ERROR, 'SMSWindow.new: opts must be a table')
        return nil
    end
    if type(opts.title) ~= 'string' or opts.title == '' then
        log.write('sms.me', log.ERROR, 'SMSWindow.new: opts.title is required')
        return nil
    end
    if type(opts.size) ~= 'table' or type(opts.size.w) ~= 'number' or type(opts.size.h) ~= 'number' then
        log.write('sms.me', log.ERROR, 'SMSWindow.new: opts.size = {w, h} is required')
        return nil
    end

    local self = setmetatable({}, SMSWindow)
    self._opts        = opts
    self._size        = { w = opts.size.w, h = opts.size.h }
    self._min_size    = { w = (opts.min_size and opts.min_size.w) or opts.size.w,
                          h = (opts.min_size and opts.min_size.h) or opts.size.h }
    self._flash_state = M._new_flash_state()
    self._tick_registered          = false
    self._new_mission_subscribed   = false

    -- Construct the dxgui Window.
    if not Window or not Static then
        log.write('sms.me', log.ERROR, 'SMSWindow.new: Window/Static module unavailable')
        return nil
    end

    local x, y
    if opts.position and type(opts.position.x) == 'number' and type(opts.position.y) == 'number' then
        x, y = opts.position.x, opts.position.y
    else
        x, y = default_position(self._size.w)
    end

    -- branded_title = false → use opts.title verbatim (no "Coconut Cockpit · …"
    -- prefix, no version suffix). Modals / secondary dialogs typically don't
    -- want the full branding wrapper.
    local title_string = (opts.branded_title == false) and opts.title or M.compose_title(opts.title, version)
    local win
    local ok, err = pcall(function()
        win = Window.new(x, y, self._size.w, self._size.h, title_string)
    end)
    if not ok or not win then
        log.write('sms.me', log.ERROR, 'SMSWindow.new: Window.new failed: ' .. tostring(err))
        return nil
    end
    self.window = win

    -- Apply the native ME chrome.
    pcall(function()
        win:setSkin((Skin and Skin.windowSkinME and Skin.windowSkinME()) or (Skin and Skin.windowSkin and Skin.windowSkin()) or nil)
    end)
    -- Force-set bounds AFTER setSkin to override any dxgui-restored
    -- persisted size from a prior session — the bulk-rename branch
    -- needed this fix; centralising it here means every window gets it.
    pcall(function() if win.setBounds then win:setBounds(x, y, self._size.w, self._size.h) end end)
    pcall(function() if win.setDraggable then win:setDraggable(true) end end)
    -- resizable defaults to true; pass resizable = false for fixed-size dialogs.
    local resizable = (opts.resizable ~= false)
    self._resizable = resizable
    pcall(function() if win.setResizable then win:setResizable(resizable) end end)
    -- Modal-style windows sit above the default 190 so the dialog never gets
    -- buried under its parent.
    local z = (opts.modal_parent ~= nil) and 250 or 190
    pcall(function() if win.setZOrder    then win:setZOrder(z)      end end)

    -- Footer band: separator + status Static. Geometry is set by relayout
    -- in Task 4. Both inserted into the window before the body so the
    -- subclass's widgets render on top in case of overlap (defensive;
    -- the layout doesn't actually overlap).
    local sep = Static.new()
    pcall(function() if win.insertWidget then win:insertWidget(sep) end end)
    try_skin(sep, 'sms_separator')
    self._sep = sep

    local status = Static.new('')
    pcall(function() if win.insertWidget then win:insertWidget(status) end end)
    try_skin(status, 'staticSkin_ME')
    self._status = status

    pcall(function() if win.setVisible then win:setVisible(true) end end)

    -- Route the dxgui-default close X through our :hide() so all dismissal
    -- paths run the same teardown (modal_parent re-enable, on_close hook,
    -- new_mission_hook subscription consistency). dxgui's default onClose
    -- just does setVisible(false), which bypasses our state cleanup —
    -- without this override, closing a modal via the X would leave its
    -- parent permanently disabled.
    local self_ref = self
    pcall(function()
        win.onClose = function() self_ref:hide() end
    end)

    -- Initial layout pass + resize callback. _install_resize_callback uses
    -- get_content_bounds and relayout, both defined later — Lua resolves
    -- method lookups at call time, so the forward reference is fine.
    self:_initial_layout()
    self:_install_resize_callback()
    self:_install_undo_hotkey()
    self:_install_new_mission_subscription()

    return self
end

-- ---------- Lifecycle ----------

-- show / hide / toggle are idempotent — multiple calls are no-ops past
-- the first. setEnabled(true) on show is defensive: some dxgui builds
-- leave a hidden Window in a disabled state.
function SMSWindow:show()
    pcall(function()
        if self.window and self.window.setVisible then self.window:setVisible(true) end
        if self.window and self.window.setEnabled then self.window:setEnabled(true) end
    end)
    -- Modal-style: disable the parent window so the user can't click through
    -- to it. dxgui has no exposed setModal at the Lua level, but
    -- setEnabled(false) blocks input on the parent. hide() reverses this.
    if self._opts and self._opts.modal_parent then
        pcall(function()
            local p = self._opts.modal_parent
            if p and p.setEnabled then p:setEnabled(false) end
        end)
    end
end

function SMSWindow:hide()
    pcall(function()
        if self.window and self.window.setVisible then self.window:setVisible(false) end
    end)
    if self._opts and self._opts.modal_parent then
        pcall(function()
            local p = self._opts.modal_parent
            if p and p.setEnabled then p:setEnabled(true) end
        end)
    end
    if self._opts and type(self._opts.on_close) == 'function' then
        pcall(self._opts.on_close, self)
    end
end

function SMSWindow:toggle()
    if not self.window then return end
    local visible = false
    pcall(function()
        if self.window.getVisible then visible = self.window:getVisible() end
    end)
    if visible then self:hide() else self:show() end
end

-- Escape hatch: returns the underlying dxgui Window. Used by retrofits
-- that need to attach extra hotkeys (Escape, Ctrl+Shift+R) or callbacks
-- the base doesn't anticipate.
function SMSWindow:raw() return self.window end

-- ---------- Layout ----------

-- Returns the content rect (x, y, w, h) inside the chrome — the area
-- between the title bar (handled by dxgui Window) and the footer
-- (separator + status, owned by this class). Subclasses position their
-- own widgets within this rect.
function SMSWindow:get_content_bounds()
    local sw, sh = self._size.w, self._size.h
    pcall(function()
        if self.window and self.window.getSize then
            local cw, ch = self.window:getSize()
            if cw and ch then sw, sh = cw, ch end
        end
    end)
    return EDGE_PAD, TOP_PAD, sw - 2 * EDGE_PAD, sh - TOP_PAD - SEP_OFFSET_BOTTOM
end

-- Reposition footer widgets to the bottom of the window. Called from
-- the size callback on every resize. The y-offsets clear dxgui's implicit
-- bottom chrome (see the constants block above); the original Prefab
-- Manager used the same numbers pre-refactor.
function SMSWindow:_relayout_footer(w, h)
    local sep_y    = h - SEP_OFFSET_BOTTOM
    local status_y = h - STATUS_OFFSET_BOTTOM
    pcall(function() if self._sep    and self._sep.setBounds    then self._sep:setBounds(EDGE_PAD, sep_y, w - 2 * EDGE_PAD, 1) end end)
    pcall(function() if self._status and self._status.setBounds then self._status:setBounds(EDGE_PAD, status_y, w - 2 * EDGE_PAD, STATUS_H) end end)
end

-- Wire the dxgui resize callback. Clamps via setBounds when the user
-- shrinks past min_size (re-fires the callback at the clamped size,
-- which is fine), repositions the footer, then dispatches to the
-- subclass's relayout method or the opts.on_resize callback.
function SMSWindow:_install_resize_callback()
    if not self._resizable then return end
    if not (self.window and self.window.addSizeCallback) then return end
    local me = self
    pcall(function()
        self.window:addSizeCallback(function()
            pcall(function()
                local cw, ch = me.window:getSize()
                if cw < me._min_size.w or ch < me._min_size.h then
                    local px, py = me.window:getBounds()
                    me.window:setBounds(px, py, math.max(cw, me._min_size.w), math.max(ch, me._min_size.h))
                    return
                end
                me._size.w, me._size.h = cw, ch
                me:_relayout_footer(cw, ch)
                if me._opts and type(me._opts.on_resize) == 'function' then
                    local x, y, w, h = me:get_content_bounds()
                    pcall(me._opts.on_resize, me, x, y, w, h)
                end
            end)
        end)
    end)
end

-- Initial geometry pass — call once after construction + body build.
-- Replays exactly what the size callback does, so the first paint
-- matches subsequent resizes.
function SMSWindow:_initial_layout()
    self:_relayout_footer(self._size.w, self._size.h)
    if self._opts and type(self._opts.on_resize) == 'function' then
        local x, y, w, h = self:get_content_bounds()
        pcall(self._opts.on_resize, self, x, y, w, h)
    end
end

-- ---------- Status bar ----------

-- Apply a (text, severity) pair to the live Static. pcall-guarded so a
-- failure (e.g. status Static was nil because Window.new bailed) is a
-- silent no-op.
function SMSWindow:_render_status(text, severity)
    pcall(function()
        if self._status then
            try_skin(self._status, M._validate_severity(severity))
            if self._status.setText then self._status:setText(tostring(text or '')) end
        end
    end)
end

-- Set sticky status. Replaces footer text + skin immediately. Stays
-- until the next set_status / flash_status call. Severity defaults to
-- 'info' when nil.
function SMSWindow:set_status(text, severity)
    severity = severity or 'info'
    M._on_set_status(self._flash_state, text, severity)
    self:_render_status(text, severity)
end

-- Clear the sticky baseline that flash_status reverts to when its timeout
-- expires, WITHOUT affecting any active flash. Use this to end a previously
-- set sticky message (so the next flash reverts to empty rather than back
-- to the stale sticky text), but not to replace what's currently rendered.
--
-- Typical use: a consumer enters some "mode" via set_status('mode banner'),
-- and exits that mode via a transient flash_status('mode result'). Without
-- clear_sticky_status, the flash would auto-revert to the stale mode banner
-- after its 5-second timeout. With it, the flash reverts to an empty footer.
function SMSWindow:clear_sticky_status()
    self._flash_state.sticky_text     = nil
    self._flash_state.sticky_severity = nil
end

-- Flash a status message that auto-reverts to the last sticky baseline
-- after `timeout` seconds (default 5). Calling set_status during a flash
-- cancels it; calling flash_status during a flash replaces it.
function SMSWindow:flash_status(text, severity, timeout)
    severity = severity or 'info'
    M._on_flash_status(self._flash_state, text, severity, timeout, os.time())
    self:_render_status(text, severity)
    -- Lazy-register the revert tick on first flash.
    if not self._tick_registered and UpdateManager and UpdateManager.add then
        local me = self
        local ok = pcall(function()
            UpdateManager.add(function()
                pcall(function()
                    local rt, rs = M._on_tick(me._flash_state, os.time())
                    if rt ~= nil then me:_render_status(rt, rs) end
                end)
                return false  -- keep the tick registered for future flashes
            end)
        end)
        if ok then self._tick_registered = true
        else log.write('sms.me', log.WARNING, 'SMSWindow: flash tick registration failed; flash will behave like set_status')
        end
    end
end

-- ---------- Lifecycle hooks ----------

-- Default Ctrl+Z handler. Used as the fallback when opts.on_undo is not
-- provided. Consumers that want "default behavior + custom post-undo
-- refresh" can call sms_window.default_on_undo(self) from inside their
-- own opts.on_undo closure.
local function default_on_undo(self)
    if not undo.has_record() then
        self:flash_status('Nothing to undo.', 'warning')
        return
    end
    local ok, err = undo.undo()
    if ok then
        self:flash_status('Undo successful.' .. (err and (' (' .. err .. ')') or ''), 'success')
    else
        self:flash_status('Undo failed: ' .. tostring(err), 'error')
    end
end

-- Wire Ctrl+Z to dispatch through opts.on_undo or default_on_undo.
-- Skipped entirely if disable_undo_hotkey is set on opts.
function SMSWindow:_install_undo_hotkey()
    if self._opts and self._opts.disable_undo_hotkey then return end
    if not (self.window and self.window.addHotKeyCallback) then return end
    local me = self
    pcall(function()
        me.window:addHotKeyCallback('Ctrl+Z', function()
            local handler = (me._opts and me._opts.on_undo) or default_on_undo
            pcall(handler, me)
        end)
    end)
end

-- Subscribe to File > New / File > Open so the window auto-hides when
-- the mission is torn down. Skipped if persist_across_new_mission is set.
-- Subscription is additive (matches the bulk-rename branch's fix) — we
-- never call new_mission_hook.reset_subscribers, so multiple windows
-- coexist without clobbering each other.
function SMSWindow:_install_new_mission_subscription()
    if self._opts and self._opts.persist_across_new_mission then return end
    if self._new_mission_subscribed then return end
    local me = self
    pcall(function() new_mission_hook.subscribe(function() me:hide() end) end)
    self._new_mission_subscribed = true
end

M.new             = SMSWindow.new     -- primary entry point: sms_window.new(opts)
M.default_on_undo = default_on_undo  -- composition consumers may compose with this

return M
