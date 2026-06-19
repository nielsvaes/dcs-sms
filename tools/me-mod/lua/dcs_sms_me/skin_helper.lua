-- skin_helper.lua — shared "apply this skin by name" helper.
--
-- Resolves in this order:
--   1. sms_button / sms_grid / sms_grid_header / sms_separator → the DCS-SMS
--      house skins built at runtime in sms_skins.lua (the native editor look
--      the tool windows use throughout).
--   2. anything else → Skin.<name>() — auto-generated wrappers around
--      dxgui/skins/skinME/skin_names.lua (staticSkin_ME, editBoxSkin_ME, etc.).
--
-- Failures (missing sms_skins entry, widget without setSkin, runtime error
-- during skin construction) degrade silently so the widget keeps its
-- default skin — matching the existing try_skin behavior in mass_edit.lua
-- and prefab_manager.lua.

local M = {}

local sms_skins;  do local ok, m = pcall(require, 'dcs_sms_me.sms_skins'); if ok then sms_skins = m end end
local Skin;       do local ok, m = pcall(require, 'Skin');                 if ok then Skin       = m end end

function M.apply(widget, skin_name)
    pcall(function()
        if not (widget and widget.setSkin) then return end
        local s
        if     skin_name == 'sms_grid'        and sms_skins then s = sms_skins.grid()
        elseif skin_name == 'sms_grid_header' and sms_skins then s = sms_skins.grid_header()
        elseif skin_name == 'sms_button'      and sms_skins then s = sms_skins.button()
        elseif skin_name == 'sms_button_on'   and sms_skins then s = sms_skins.button_on()
        elseif skin_name == 'sms_button_off'  and sms_skins then s = sms_skins.button_off()
        elseif skin_name == 'sms_button_translucent' and sms_skins then s = sms_skins.button_translucent()
        elseif skin_name == 'sms_separator'   and sms_skins then s = sms_skins.separator()
        elseif skin_name == 'sms_splitter'    and sms_skins then s = sms_skins.splitter()
        elseif skin_name == 'sms_slider_track'  and sms_skins then s = sms_skins.slider_track()
        elseif skin_name == 'sms_slider_handle' and sms_skins then s = sms_skins.slider_handle()
        elseif skin_name == 'sms_tab'         and sms_skins then s = sms_skins.tab()
        elseif skin_name == 'sms_tab_off'     and sms_skins then s = sms_skins.tab_off()
        elseif skin_name == 'sms_scroll_pane' and sms_skins then s = sms_skins.scroll_pane()
        elseif skin_name == 'sms_coal_red'     and sms_skins then s = sms_skins.coal_red()
        elseif skin_name == 'sms_coal_blue'    and sms_skins then s = sms_skins.coal_blue()
        elseif skin_name == 'sms_coal_neutral' and sms_skins then s = sms_skins.coal_neutral()
        else
            local fn = Skin and Skin[skin_name]
            if not fn then return end
            s = fn()
        end
        if s then widget:setSkin(s) end
    end)
end

return M
