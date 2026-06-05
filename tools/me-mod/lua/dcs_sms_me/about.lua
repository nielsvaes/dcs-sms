-- about.lua — small "About DCS-SMS" dialog. Shows the Coconut Cockpit
-- logo, the canonical version string, and the project's GitHub + Discord
-- URLs. Opened from the Tools → DCS-SMS → About menu entry.
--
-- The dialog is a single-instance Window with a Static logo, a few Static
-- text labels, and a Close button. The logo is rendered by skinning the
-- Static with a clone of staticSkin where released[1].picture points at
-- the bundled logo.png — the same trick sms_skins.icon_static uses for
-- its warning/question glyphs (see sms_skins.lua line 64+).

local M = {}

-- Single dialog instance, reused on subsequent opens. Cleared on error
-- so a failed first open doesn't permanently wedge.
local W = nil

-- DCS runs with its install dir as CWD; this path resolves to the file
-- copied there by `dcs-sms.exe install-me-mod`.
local LOGO_FILE = './MissionEditor/modules/dcs_sms_me/logo.png'

-- Build a Static skin whose released state renders the bundled logo.png
-- at its natural 128x128 size. Pattern mirrors sms_skins.icon_static.
local function build_logo_skin()
    local Skin = require('Skin')
    local s = Skin.staticSkin and Skin.staticSkin() or nil
    if not (s and s.skinData and s.skinData.states) then return nil end
    s.skinData.states.released = s.skinData.states.released or {}
    s.skinData.states.released[1] = s.skinData.states.released[1] or {}
    s.skinData.states.released[1].picture = {
        color     = '0xffffffff',
        file      = LOGO_FILE,
        horzAlign = { type = 'middle', offset = 0 },
        vertAlign = { type = 'middle', offset = 0 },
        rect      = { x1 = 0, x2 = 0, y1 = 0, y2 = 0 },
        size      = { horz = 0, vert = 0 },
    }
    return s
end

-- Make a Static text label skinned to look native to the editor. Caller
-- positions it with setBounds and inserts it into the parent window.
local function make_label(text)
    local Static = require('Static')
    local Skin   = require('Skin')
    local lbl = Static.new()
    pcall(function()
        local s = Skin.staticSkin_ME and Skin.staticSkin_ME() or nil
        if s then lbl:setSkin(s) end
    end)
    if lbl.setText then lbl:setText(text) end
    return lbl
end

function M.show()
    if W and W.setVisible then
        W:setVisible(true)
        return
    end

    local ok, err = pcall(function()
        local Window  = require('Window')
        local Static  = require('Static')
        local Button  = require('Button')
        local Skin    = require('Skin')
        local Gui     = require('dxgui')
        local version = require('dcs_sms_me.version')

        local w, h = 360, 360
        local screen_w, screen_h = Gui.GetWindowSize()
        local x = math.floor((screen_w - w) / 2)
        local y = math.floor((screen_h - h) / 2)

        W = Window.new(x, y, w, h, 'About DCS-SMS')
        pcall(function()
            local skin = (Skin.windowSkinME and Skin.windowSkinME()) or Skin.windowSkin()
            if skin then W:setSkin(skin) end
        end)
        W:setVisible(true)
        W:setDraggable(true)
        W:setResizable(false)
        W:setZOrder(200)

        -- Logo: 128x128 centered horizontally near the top.
        local logo = Static.new()
        logo:setBounds(math.floor((w - 128) / 2), 24, 128, 128)
        pcall(function()
            local s = build_logo_skin()
            if s then logo:setSkin(s) end
        end)
        W:insertWidget(logo)

        local title = make_label('Coconut Cockpit · DCS-SMS')
        title:setBounds(20, 162, w - 40, 22)
        W:insertWidget(title)

        local ver = make_label('Mission Editor mod v' .. tostring(version))
        ver:setBounds(20, 188, w - 40, 18)
        W:insertWidget(ver)

        local gh = make_label('github.com/nielsvaes/dcs-sms')
        gh:setBounds(20, 220, w - 40, 18)
        W:insertWidget(gh)

        local dc = make_label('discord.gg/8tbdGY45hM')
        dc:setBounds(20, 244, w - 40, 18)
        W:insertWidget(dc)

        local btn = Button.new()
        btn:setBounds(math.floor((w - 80) / 2), h - 44, 80, 28)
        btn:setText('Close')
        pcall(function()
            if Skin.buttonSkin_ME then btn:setSkin(Skin.buttonSkin_ME()) end
        end)
        btn:addChangeCallback(function()
            pcall(function() if W and W.setVisible then W:setVisible(false) end end)
        end)
        W:insertWidget(btn)
    end)

    if not ok then
        log.write('sms.me', log.ERROR, 'About dialog failed to open: ' .. tostring(err))
        W = nil  -- let a retry rebuild from scratch
    end
end

return M
