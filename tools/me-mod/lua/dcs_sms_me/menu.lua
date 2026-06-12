-- menu.lua — Top-level "DCS-SMS" menu entry registration.
--
-- ME-API path (discovered 2026-05-03 by re-reading me_menubar.lua):
--   me_menubar's `menuBar` table IS module-public — set without `local` at
--   line 467: `menuBar = window.menuBar`. So `require('me_menubar').menuBar`
--   resolves once me_menubar.create_() has run (which it does when
--   me_menubar.show() is first called).
--
--   The MenuBar widget exposes :insertItem(MenuBarItem) for adding new
--   top-level menus at runtime. We construct a fresh Menu widget, attach
--   a "Prefab Manager" MenuItem to it, wrap it in a MenuBarItem labelled
--   "DCS-SMS", and insert at the end of the bar. Skins are copied from
--   the existing `customize` entry so visual styling matches.
--
--   Menu's onChange callback is wired the same way native ME menus do it:
--   `function menu:onChange(item) if item.func then item.func() end end`.
--
-- Strategy:
--   1. At install time, try to add the top-level entry immediately (in
--      case the menubar is already constructed).
--   2. If menuBar isn't ready yet, monkey-patch me_menubar.show so the
--      entry is added the next time ME shows the menubar.
--   3. If me_menubar is inaccessible on a future DCS build, log an
--      error and bail — the Prefab Manager will be unreachable until
--      a DCS build that exposes me_menubar is installed.

local M = {}

-- clone_item_skin / add_item — every DCS-SMS menu entry creates an item,
-- clones the native menubar's sibling-item skin onto it (so fonts/spacing
-- match the rest of the bar), wires a click handler, and logs on failure.
-- These two helpers fold that otherwise-copy-pasted boilerplate into one
-- place. The skin source is whichever stable native item the menubar
-- exposes (missionOptions / mapOptions / setPosition / logbook).
local function clone_item_skin(item, sibling_menu)
    pcall(function()
        local sibling_item = sibling_menu
            and (sibling_menu.missionOptions or sibling_menu.mapOptions
                 or sibling_menu.setPosition  or sibling_menu.logbook)
        if sibling_item and sibling_item.getSkin and item and item.setSkin then
            item:setSkin(sibling_item:getSkin())
        end
    end)
end

-- Create a skinned menu item with a click handler. Returns the item, or nil
-- (after logging) if newItem failed on this DCS build.
local function add_item(menu, sibling_menu, label, func)
    local item
    local ok, err = pcall(function() item = menu:newItem(label) end)
    if not ok or not item then
        log.write('sms.me', log.ERROR, label .. ' menu:newItem failed: ' .. tostring(err))
        return nil
    end
    clone_item_skin(item, sibling_menu)
    item.func = func
    return item
end

-- Build a top-level "DCS-SMS" menu entry containing "Prefab Manager".
-- Idempotent — guarded by a flag on the me_menubar module so dev-reload
-- (Ctrl+Shift+R, which clears our package.loaded but not me_menubar) doesn't
-- add a duplicate entry. Returns true if the entry exists after this call.
local function add_top_level_menu()
    local ok, mb = pcall(require, 'me_menubar')
    if not ok or not mb or not mb.menuBar then return false end
    if mb._dcs_sms_top_added then return true end

    local menu_bar = mb.menuBar
    if type(menu_bar.insertItem) ~= 'function' then return false end

    local ok_req_menu, Menu        = pcall(require, 'Menu')
    local ok_req_item, MenuBarItem = pcall(require, 'MenuBarItem')
    if not (ok_req_menu and Menu and ok_req_item and MenuBarItem) then return false end
    -- MenuSeparatorItem is optional — older DCS builds may not ship it.
    -- When unavailable we just skip the separator and lay items out flush.
    local MenuSeparatorItem; do
        local ok, m = pcall(require, 'MenuSeparatorItem')
        if ok then MenuSeparatorItem = m end
    end
    -- MsgWindow drives the "Remember this setting?" prompt on the
    -- External execution toggle. Optional — when unavailable we just
    -- skip the prompt and treat the toggle as session-only.
    local MsgWindow; do
        local ok, m = pcall(require, 'MsgWindow')
        if ok then MsgWindow = m end
    end
    -- Persistent settings layer for the External execution remember-me
    -- prompt. Lazy require so a test VM without lfs doesn't crash menu
    -- install (load returns defaults on failure).
    local me_settings = require('dcs_sms_me.me_settings')

    -- Build the popup menu and copy the existing customize-menu skin so
    -- our menu's background, fonts, and item spacing match the rest of
    -- the menubar.
    local sibling_top  = menu_bar.customize
    local sibling_menu = sibling_top and sibling_top.menu

    local menu = Menu.new()
    pcall(function()
        if sibling_menu and sibling_menu.getSkin and menu.setSkin then
            menu:setSkin(sibling_menu:getSkin())
        end
    end)
    -- Canonical ME pattern: each menu's onChange dispatches to item.func.
    function menu:onChange(item)
        if item and item.func then item.func() end
    end

    local item = add_item(menu, sibling_menu, 'Prefab Manager', function()
        log.write('sms.me', log.INFO, 'DCS-SMS > Prefab Manager menu clicked')
        local ok_t, terr = pcall(function()
            require('dcs_sms_me.prefab_manager').toggle()
        end)
        if not ok_t then
            log.write('sms.me', log.ERROR, 'Prefab Manager toggle failed: ' .. tostring(terr))
        end
    end)
    -- Prefab Manager is the anchor entry; if even its item can't be created
    -- the menu is unusable, so bail (matches the pre-refactor behavior).
    if not item then return false end

    -- "Mass Edit" entry — opens the Mass Edit window (lazy-required so a
    -- syntax error in mass_edit.lua degrades to a logged warning instead of
    -- breaking the menu).
    add_item(menu, sibling_menu, 'Mass Edit', function()
        local ok, mod_or_err = pcall(require, 'dcs_sms_me.mass_edit')
        if ok and type(mod_or_err) == 'table' and mod_or_err.toggle then
            local ok2, err = pcall(mod_or_err.toggle)
            if not ok2 then
                pcall(function() _G.log.write('sms.me.menu', _G.log.ERROR or 1,
                    'mass_edit.toggle threw: ' .. tostring(err)) end)
            end
        end
    end)

    -- "Hotkey Manager" entry — opens the hotkey-binding window.
    add_item(menu, sibling_menu, 'Hotkey Manager', function()
        local ok2, err = pcall(function() require('dcs_sms_me.me_hotkeys').toggle_window() end)
        if not ok2 then
            log.write('sms.me', log.ERROR, 'Hotkeys toggle failed: ' .. tostring(err))
        end
    end)

    -- "Trigger Finder" entry — opens the reverse trigger-lookup window.
    add_item(menu, sibling_menu, 'Trigger Finder', function()
        local ok2, err = pcall(function() require('dcs_sms_me.trigger_finder').toggle() end)
        if not ok2 then
            log.write('sms.me', log.ERROR, 'Trigger Finder toggle failed: ' .. tostring(err))
        end
    end)

    -- Sibling "About" menu entry. Same skin-clone pattern as the Prefab
    -- Manager item; opens the about-dialog via require('dcs_sms_me.about').
    add_item(menu, sibling_menu, 'About', function()
        log.write('sms.me', log.INFO, 'DCS-SMS > About menu clicked')
        local ok_a, aerr = pcall(function()
            require('dcs_sms_me.about').show()
        end)
        if not ok_a then
            log.write('sms.me', log.ERROR, 'About dialog failed: ' .. tostring(aerr))
        end
    end)

    -- Visual separator between the action items above (Prefab Manager,
    -- Mass Edit, About) and the External-execution toggle below — the
    -- latter is a session-level setting, not a feature entry, so a
    -- divider clarifies the grouping. Skipped silently on DCS builds
    -- that don't expose MenuSeparatorItem.
    if MenuSeparatorItem and MenuSeparatorItem.new and menu.insertItem then
        pcall(function() menu:insertItem(MenuSeparatorItem.new()) end)
    end

    -- "External execution: ON/OFF" toggle — controls _G.DCS_SMS_GUI_BRIDGE_ENABLED
    -- which the dcs-sms hook checks before honoring target=gui requests.
    -- Off-by-default per DCS launch UNLESS the user previously opted into
    -- the remember-this-setting prompt (me_settings.gui_bridge == true);
    -- in that case we auto-enable here so the user doesn't have to toggle
    -- after every restart.
    local initial_remembered = false
    pcall(function()
        local s = me_settings.load()
        if s and s.gui_bridge == true then
            initial_remembered = true
            _G.DCS_SMS_GUI_BRIDGE_ENABLED = true
        end
    end)

    local exec_item
    local ok_exec, exec_err = pcall(function()
        exec_item = menu:newItem(initial_remembered
            and 'External execution: ON'
            or  'External execution: OFF')
    end)
    if ok_exec and exec_item then
        clone_item_skin(exec_item, sibling_menu)

        -- Update the item label after a toggle. Menu items expose either
        -- :setText or a `text` field across DCS versions — try both.
        local function update_label(on)
            local label = on and 'External execution: ON' or 'External execution: OFF'
            pcall(function()
                if type(exec_item.setText) == 'function' then
                    exec_item:setText(label)
                else
                    exec_item.text = label
                end
            end)
        end

        -- Ask the user after every toggle whether to persist the new
        -- state. Yes -> write the current (post-toggle) value to disk so
        -- the next DCS launch starts in that state. No -> leave the
        -- saved file untouched (the session state still reflects the
        -- toggle that just happened; only future launches are unaffected).
        local function prompt_remember(on)
            if not MsgWindow then return end
            local state_label = on and 'ON' or 'OFF'
            pcall(function()
                local handler = MsgWindow.question(
                    'Remember "External execution: ' .. state_label ..
                    '" across DCS restarts?\n\n' ..
                    'When remembered, the bridge auto-applies at startup ' ..
                    'so you don\'t need to toggle it each launch.',
                    'DCS-SMS', 'Yes', 'No')
                function handler:onChange(button_label)
                    if button_label == 'Yes' then
                        local s = me_settings.load()
                        s.gui_bridge = on
                        if me_settings.save(s) then
                            log.write('sms.me', log.INFO,
                                'External execution preference: remembered (' ..
                                state_label .. ')')
                        end
                    end
                    return false  -- MsgWindow closes after our callback
                end
                handler:show()
            end)
        end

        exec_item.func = function()
            _G.DCS_SMS_GUI_BRIDGE_ENABLED = not (_G.DCS_SMS_GUI_BRIDGE_ENABLED == true)
            local on = _G.DCS_SMS_GUI_BRIDGE_ENABLED == true
            update_label(on)
            log.write('sms.me', log.INFO, 'gui bridge ' .. (on and 'enabled' or 'disabled'))
            prompt_remember(on)
        end
    else
        log.write('sms.me', log.ERROR, 'External-execution menu:newItem failed: ' .. tostring(exec_err))
    end

    -- Wrap the menu in a MenuBarItem and insert at the end of the bar.
    local bar_item
    local ok_bar, bar_err = pcall(function() bar_item = MenuBarItem.new('DCS-SMS', menu) end)
    if not ok_bar or not bar_item then
        log.write('sms.me', log.ERROR, 'MenuBarItem.new failed: ' .. tostring(bar_err))
        return false
    end
    pcall(function()
        if sibling_top and sibling_top.getSkin and bar_item.setSkin then
            bar_item:setSkin(sibling_top:getSkin())
        end
    end)
    pcall(function() menu_bar:insertItem(bar_item) end)

    mb._dcs_sms_top_added = true
    return true
end

-- Monkey-patch me_menubar.show so add_top_level_menu runs after the menubar
-- is constructed. Idempotent — only patches once.
local function patch_menubar_show()
    local ok, mb = pcall(require, 'me_menubar')
    if not ok or not mb or type(mb.show) ~= 'function' then return false end
    if mb._dcs_sms_show_patched then return true end

    local orig_show = mb.show
    mb.show = function(...)
        local result = orig_show(...)
        pcall(add_top_level_menu)
        return result
    end
    mb._dcs_sms_show_patched = true
    return true
end

-- Monkey-patch me_menubar.hideME so our tool windows auto-hide when the
-- user exits the ME (returns to the main menu). hideME is the canonical
-- "we're leaving the ME" point; it's called by Exit() which is called
-- from every ME exit path (menu Exit, alt-F4, etc.).
--
-- Idempotent — only patches once. Pulls each window module via
-- package.loaded so a dev-reload that swaps the module is honored (the
-- patch closure stays put but always grabs the freshly-required module),
-- and so we only touch windows the user actually opened (no require here,
-- which would needlessly construct an unopened window).
local HIDE_ON_EXIT = {
    'dcs_sms_me.prefab_manager',
    'dcs_sms_me.trigger_finder',
    'dcs_sms_me.mass_edit',
    'dcs_sms_me.me_hotkey_window',
    'dcs_sms_me.paint_statics',
}

local function patch_menubar_hideME()
    local ok, mb = pcall(require, 'me_menubar')
    if not ok or not mb or type(mb.hideME) ~= 'function' then return false end
    if mb._dcs_sms_hideME_patched then return true end

    local orig_hideME = mb.hideME
    mb.hideME = function(...)
        for _, name in ipairs(HIDE_ON_EXIT) do
            pcall(function()
                local w = package.loaded[name]
                if w and w.hide then w.hide() end
            end)
        end
        return orig_hideME(...)
    end
    mb._dcs_sms_hideME_patched = true
    return true
end

-- M.install ---------------------------------------------------------------
-- Public entry point. Returns:
--   "menu"   — added DCS-SMS top-level menu (immediately or via patch)
--   "failed" — me_menubar inaccessible; the Prefab Manager has no entry
--              point and the user will need a DCS build that exposes
--              me_menubar before the mod is reachable.
function M.install()
    -- Hook ME-exit so our window auto-hides when the user leaves the ME.
    -- Independent from the menu-entry path.
    pcall(patch_menubar_hideME)

    -- Try to add immediately. If menubar already exists we're done.
    if add_top_level_menu() then
        log.write('sms.me', log.INFO, 'DCS-SMS top-level menu added')
        return 'menu'
    end

    -- Otherwise, schedule via show-patch — entry will appear the next time
    -- the menubar is shown (usually right after init, on first ME paint).
    if patch_menubar_show() then
        log.write('sms.me', log.INFO,
            'DCS-SMS top-level menu will be added when menubar shows')
        return 'menu'
    end

    log.write('sms.me', log.ERROR,
        'me_menubar inaccessible — could not register DCS-SMS menu entry. ' ..
        'The Prefab Manager will not be reachable from the ME UI on this ' ..
        'DCS build.')
    return 'failed'
end

return M
