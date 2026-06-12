-- community_image_window.lua — a singleton, resizable image viewer built on
-- sms_window. Shows one community screenshot scaled to fit the window body,
-- with ◀ ▶ navigation that calls back into the Community tab. Display-only:
-- it never downloads — the Community tab's media controller produces cached
-- file paths and pushes them here via set_image / set_loading.
--
-- Public API:
--   M.show(opts)  opts = { path, native_w, native_h, count_text, has_nav,
--                          on_prev, on_next } — build/reuse the window + display
--   M.set_image(path, count_text, has_nav)    — swap the displayed image
--   M.set_loading(count_text, has_nav)         — show a "loading…" state
--   M.hide()                                   — hide the window
--   M.is_open() -> boolean
--
-- All dxgui access is pcall-guarded so the module loads in the bare test VM,
-- where sms_window can't build a Window → every call no-ops.

local sms_window; do local ok, m = pcall(require, 'dcs_sms_me.sms_window');         if ok then sms_window = m end end
local Static;     do local ok, m = pcall(require, 'Static');                         if ok then Static     = m end end
local Button;     do local ok, m = pcall(require, 'Button');                         if ok then Button     = m end end
local SkinUtils;  do local ok, m = pcall(require, 'SkinUtils');                      if ok then SkinUtils  = m end end
local Skin;       do local ok, m = pcall(require, 'Skin');                           if ok then Skin       = m end end
local image_fit;  do local ok, m = pcall(require, 'dcs_sms_me.community_image_fit'); if ok then image_fit  = m end end

local M = {}

-- Singleton viewer state — one window, reused across opens.
local V = {
    win = nil, image = nil, probe = nil, count = nil, prev = nil, next = nil,
    path = nil, native_w = nil, native_h = nil,
    has_nav = false, loading = false, on_prev = nil, on_next = nil,
}

local CTRL_H = 26   -- nav row height
local BTN_W  = 30   -- ◀ / ▶ button width
local GAP    = 6

local function set_text(widget, txt)
    pcall(function() if widget and widget.setText then widget:setText(tostring(txt or '')) end end)
end

local function set_visible(widget, on)
    pcall(function()
        if not widget then return end
        if widget.set_visible then widget:set_visible(on)
        elseif widget.setVisible then widget:setVisible(on) end
    end)
end

local function static_skin(widget)
    pcall(function()
        if widget and widget.setSkin and Skin and Skin.staticSkin_ME then
            widget:setSkin(Skin.staticSkin_ME())
        end
    end)
end

-- Native image size via the hidden probe Static. (w, h) or (0, 0).
local function probe(path)
    if not (V.probe and SkinUtils and SkinUtils.setStaticPicture) then return 0, 0 end
    local w, h = 0, 0
    pcall(function()
        V.probe:setSkin(SkinUtils.setStaticPicture(path, V.probe:getSkin()))
        local cw, ch = V.probe:calcSize()
        w, h = tonumber(cw) or 0, tonumber(ch) or 0
    end)
    return w, h
end

-- Lay the image + nav row into the content rect (x, y, w, h).
local function layout(x, y, w, h)
    if not V.win then return end
    local ctrl_y    = y + h - CTRL_H
    local img_box_h = math.max(0, h - CTRL_H - GAP)

    local disp_w, disp_h = 0, 0
    if (not V.loading) and V.path and V.native_w and V.native_w > 0
       and V.native_h and V.native_h > 0 and image_fit and image_fit.fit then
        disp_w, disp_h = image_fit.fit(V.native_w, V.native_h, w, img_box_h)
    end
    if disp_w > 0 and disp_h > 0 then
        set_visible(V.image, true)
        pcall(function()
            if V.image and V.image.setBounds then
                V.image:setBounds(x + math.floor((w - disp_w) / 2),
                                  y + math.floor((img_box_h - disp_h) / 2), disp_w, disp_h)
            end
        end)
        pcall(function()
            if V.image and SkinUtils and SkinUtils.setStaticPicture and V.path then
                local skin = SkinUtils.setStaticPicture(V.path, V.image:getSkin())
                if SkinUtils.setStaticPictureSize then
                    skin = SkinUtils.setStaticPictureSize(disp_w, disp_h, skin)
                end
                V.image:setSkin(skin)
            end
        end)
    else
        set_visible(V.image, false)
    end

    pcall(function() if V.count and V.count.setBounds then
        V.count:setBounds(x + BTN_W + 4, ctrl_y, math.max(0, w - 2 * (BTN_W + 4)), CTRL_H) end end)
    set_visible(V.count, true)
    if V.has_nav then
        set_visible(V.prev, true); set_visible(V.next, true)
        pcall(function() if V.prev and V.prev.setBounds then V.prev:setBounds(x, ctrl_y, BTN_W, CTRL_H) end end)
        pcall(function() if V.next and V.next.setBounds then V.next:setBounds(x + w - BTN_W, ctrl_y, BTN_W, CTRL_H) end end)
    else
        set_visible(V.prev, false); set_visible(V.next, false)
    end
end

-- Re-fit using the window's current content rect.
local function refit()
    if not (V.win and V.win.get_content_bounds) then return end
    pcall(function()
        local x, y, w, h = V.win:get_content_bounds()
        layout(x, y, w, h)
    end)
end

-- Initial window size: content fit into ~1100×750, plus sms_window chrome
-- (16px horiz, 84px vert per get_content_bounds). Falls back to 900×650.
local function initial_size(nw, nh)
    local cw, ch = 900 - 16, 650 - 84
    if image_fit and image_fit.fit and nw and nh then
        local fw, fh = image_fit.fit(nw, nh, 1100, 750)
        if fw > 0 and fh > 0 then cw, ch = fw, fh + CTRL_H + GAP end
    end
    return math.max(400, cw + 16), math.max(320, ch + 84)
end

-- Build the singleton window + widgets once. Returns true if usable.
local function build(nw, nh)
    if V.win then return true end
    if not (sms_window and sms_window.new) then return false end
    local w, h = initial_size(nw, nh)
    local win
    pcall(function()
        win = sms_window.new({
            title    = 'Image preview',
            size     = { w = w, h = h },
            min_size = { w = 400, h = 320 },
            on_resize = function(_, x, y, cw, ch) layout(x, y, cw, ch) end,
        })
    end)
    if not win then return false end
    V.win = win
    local raw = win.raw and win:raw()
    local function add(widget)
        pcall(function() if raw and raw.insertWidget and widget then raw:insertWidget(widget) end end)
        return widget
    end

    V.image = add(Static and Static.new()); static_skin(V.image)
    V.probe = Static and Static.new()   -- not added: sizing only
    V.count = add(Static and Static.new()); static_skin(V.count)

    V.prev = add(Button and Button.new())
    if V.prev then
        set_text(V.prev, '\226\151\128')  -- ◀
        if V.prev.addChangeCallback then
            pcall(function() V.prev:addChangeCallback(function() if V.on_prev then pcall(V.on_prev) end end) end)
        end
    end
    V.next = add(Button and Button.new())
    if V.next then
        set_text(V.next, '\226\150\182')  -- ▶
        if V.next.addChangeCallback then
            pcall(function() V.next:addChangeCallback(function() if V.on_next then pcall(V.on_next) end end) end)
        end
    end
    return true
end

function M.is_open()
    if not (V.win and V.win.raw) then return false end
    local visible = false
    pcall(function()
        local w = V.win:raw()
        if w and w.getVisible then visible = w:getVisible() end
    end)
    return visible == true
end

function M.show(opts)
    opts = opts or {}
    if not build(opts.native_w, opts.native_h) then return end
    V.on_prev = opts.on_prev
    V.on_next = opts.on_next
    V.has_nav = opts.has_nav and true or false
    pcall(function() if V.win.show then V.win:show() end end)
    M.set_image(opts.path, opts.count_text, V.has_nav, opts.native_w, opts.native_h)
end

function M.set_image(path, count_text, has_nav, nw, nh)
    if not V.win then return end
    if has_nav ~= nil then V.has_nav = has_nav and true or false end
    V.loading = false
    V.path = path
    -- Prefer the native size the tab already probed; fall back to a local probe.
    if nw and nh and nw > 0 and nh > 0 then
        V.native_w, V.native_h = nw, nh
    else
        V.native_w, V.native_h = probe(path)
    end
    set_text(V.count, count_text)
    refit()
end

function M.set_loading(count_text, has_nav)
    if not V.win then return end
    if has_nav ~= nil then V.has_nav = has_nav and true or false end
    V.loading = true
    set_text(V.count, count_text or 'loading\226\128\166')
    refit()
end

function M.hide()
    pcall(function() if V.win and V.win.hide then V.win:hide() end end)
end

return M
