-- init.lua — loaded by the require() line patched into MissionEditor.lua.
--
-- Sub-project 3: registers a Tools-menu entry instead of auto-showing
-- the Prefab Manager window. The window is constructed lazily on first
-- toggle.
--
-- Outer pcall is the last-line defense: even if our require chain
-- breaks, the ME continues loading normally.

local ok, err = pcall(function()
    local version = require('dcs_sms_me.version')
    log.write('sms.me', log.INFO, 'bootstrap (version ' .. tostring(version) .. ')')

    -- Wire the bundled LuaSec payload onto package.cpath/path so the
    -- community library can require('ssl.https'). The payload lives under
    -- <Saved Games>/DCS/dcs-sms/lib/ (user-supplied; see README). Safe no-op
    -- when the dir/binaries are absent — require simply fails later and the
    -- Community tab degrades to "secure networking unavailable".
    pcall(function() require('dcs_sms_me.lib_path').apply() end)

    local menu = require('dcs_sms_me.menu')
    menu.install()

    -- Install the marquee hook eagerly on bootstrap so a rect drawn before the
    -- prefab manager window opens still gets remembered. Subscribers attach
    -- later (window.lua attaches on its first show).
    local marquee_hook = require('dcs_sms_me.marquee_hook')
    marquee_hook.install()

    -- Install the File > New hook eagerly too, so the wrapper is in place
    -- before the prefab manager window first opens. Subscribers attach
    -- from window.lua on its first show.
    local new_mission_hook = require('dcs_sms_me.new_mission_hook')
    new_mission_hook.install()

    -- Install the ME-side execution bridge: registers an UpdateManager poll
    -- of <SavedGames>/DCS/dcs-sms/inbox for target=gui requests. Gated by
    -- the External-execution toggle in menu.lua. Independent of the Prefab
    -- Manager window — runs from the moment the ME starts.
    local bridge = require('dcs_sms_me.bridge')
    bridge.install()

    -- Install custom ME hotkeys: load saved overrides, attach bindings to the
    -- toolbar window. Independent of any tool window.
    local me_hotkeys = require('dcs_sms_me.me_hotkeys')
    me_hotkeys.install()
end)
if not ok then
    log.write('sms.me', log.ERROR, 'init failed: ' .. tostring(err))
end
