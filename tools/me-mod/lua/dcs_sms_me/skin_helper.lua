-- skin_helper.lua — shared "apply this skin by name" helper.
--
-- Resolves in this order:
--   1. dtc_button / dtc_grid / dtc_grid_header / dtc_separator → DTC-style
--      skins built at runtime in dtc_skins.lua (the navy theme used by
--      Prefab Manager).
--   2. anything else → Skin.<name>() — auto-generated wrappers around
--      dxgui/skins/skinME/skin_names.lua (staticSkin_ME, editBoxSkin_ME, etc.).
--
-- Failures (missing dtc_skins entry, widget without setSkin, runtime error
-- during skin construction) degrade silently so the widget keeps its
-- default skin — matching the existing try_skin behavior in mass_edit.lua
-- and prefab_manager.lua.

local M = {}

local dtc_skins;  do local ok, m = pcall(require, 'dcs_sms_me.dtc_skins'); if ok then dtc_skins = m end end
local Skin;       do local ok, m = pcall(require, 'Skin');                 if ok then Skin       = m end end

function M.apply(widget, skin_name)
    pcall(function()
        if not (widget and widget.setSkin) then return end
        local s
        if     skin_name == 'dtc_grid'        and dtc_skins then s = dtc_skins.grid()
        elseif skin_name == 'dtc_grid_header' and dtc_skins then s = dtc_skins.grid_header()
        elseif skin_name == 'dtc_button'      and dtc_skins then s = dtc_skins.button()
        elseif skin_name == 'dtc_button_on'   and dtc_skins then s = dtc_skins.button_on()
        elseif skin_name == 'dtc_button_off'  and dtc_skins then s = dtc_skins.button_off()
        elseif skin_name == 'dtc_button_translucent' and dtc_skins then s = dtc_skins.button_translucent()
        elseif skin_name == 'dtc_separator'   and dtc_skins then s = dtc_skins.separator()
        elseif skin_name == 'dtc_splitter'    and dtc_skins then s = dtc_skins.splitter()
        elseif skin_name == 'dtc_scroll_pane' and dtc_skins then s = dtc_skins.scroll_pane()
        elseif skin_name == 'dtc_coal_red'     and dtc_skins then s = dtc_skins.coal_red()
        elseif skin_name == 'dtc_coal_blue'    and dtc_skins then s = dtc_skins.coal_blue()
        elseif skin_name == 'dtc_coal_neutral' and dtc_skins then s = dtc_skins.coal_neutral()
        else
            local fn = Skin and Skin[skin_name]
            if not fn then return end
            s = fn()
        end
        if s then widget:setSkin(s) end
    end)
end

return M
