-- me_units_list_hook.lua -- monkey-patch ED's me_units_list dispatch
-- functions so Mass Edit (or any other consumer) can react to live
-- property changes made through ED's stock Group / Aircraft / Ship /
-- Vehicle / Static panels.
--
-- Why monkey-patch instead of wiring into each panel? ED has no event
-- bus. Every editor panel knows me_units_list by name and calls one
-- of update / updateRow / updateGroup directly after mutating a unit
-- table. That makes me_units_list the single chokepoint where every
-- ED-side change passes through — wrap those 3 functions and we
-- catch every panel's edits with one intercept.
--
-- Re-install safety: dev-reload clears this module but does NOT
-- reload ED's me_units_list (it lives outside dcs_sms_me's package
-- tree). We therefore stash each original on the Hook module under a
-- _dcs_sms_orig_ prefix on first wrap; subsequent installs reuse
-- those references instead of re-wrapping wraps (which would call
-- stale handlers and skip the real ED implementation).
--
-- Public:
--   M.install(on_change)
--       on_change(kind, group, unit)
--           kind   = 'full' | 'group' | 'unit'
--           group  = mission group table (nil for kind='full')
--           unit   = mission unit table  (nil unless kind='unit')
--       Idempotent. Returns true on success, (false, reason) if ED's
--       module isn't reachable (test VMs).
--   M.uninstall()
--       Clears the handler; the wraps stay installed and become
--       harmless pass-throughs. Used mostly for tests.

local M = {}

local function get_hook_module()
    local ok, mod = pcall(require, 'me_units_list')
    if ok and type(mod) == 'table' then return mod end
    return nil
end

local _on_change = nil

function M.install(on_change)
    local Hook = get_hook_module()
    if not Hook then return false, 'me_units_list not available' end

    _on_change = on_change

    if Hook._dcs_sms_orig_update == nil and type(Hook.update) == 'function' then
        Hook._dcs_sms_orig_update = Hook.update
        Hook.update = function(...)
            if Hook._dcs_sms_orig_update then
                pcall(Hook._dcs_sms_orig_update, ...)
            end
            if _on_change then pcall(_on_change, 'full') end
        end
    end

    if Hook._dcs_sms_orig_updateRow == nil and type(Hook.updateRow) == 'function' then
        Hook._dcs_sms_orig_updateRow = Hook.updateRow
        Hook.updateRow = function(group, unit, ...)
            if Hook._dcs_sms_orig_updateRow then
                pcall(Hook._dcs_sms_orig_updateRow, group, unit, ...)
            end
            if _on_change then pcall(_on_change, 'unit', group, unit) end
        end
    end

    if Hook._dcs_sms_orig_updateGroup == nil and type(Hook.updateGroup) == 'function' then
        Hook._dcs_sms_orig_updateGroup = Hook.updateGroup
        Hook.updateGroup = function(group, ...)
            if Hook._dcs_sms_orig_updateGroup then
                pcall(Hook._dcs_sms_orig_updateGroup, group, ...)
            end
            if _on_change then pcall(_on_change, 'group', group) end
        end
    end

    pcall(M.try_wrap_skill_handlers)

    return true
end

-- Skill changes are not routed through me_units_list — each panel's
-- skill ComboList commits via vdata.group.units[i].skill = ... and
-- never calls updateRow/updateGroup. To catch skill edits we have to
-- wrap each panel's c_skill widget onChange directly.
--
-- The widget is created on first Group-panel open, so we cannot wrap
-- at install time alone — try_wrap_skill_handlers is also invoked from
-- Mass Edit's show path and from each on_change firing, opportunistically
-- wrapping any panel that's just been initialized. The _dcs_sms_orig_
-- key on the WIDGET (not the module) prevents double-wrap.
local SKILL_PANELS = {
    { module = 'me_aircraft' },
    { module = 'me_vehicle'  },
    { module = 'me_ship'     },
}

local function wrap_widget_onchange(panel_mod, panel_name)
    local widget = panel_mod and panel_mod.c_skill
    if not widget or type(widget) ~= 'table' then return end
    if widget._dcs_sms_orig_onChange ~= nil then return end  -- already wrapped
    local orig = widget.onChange
    if type(orig) ~= 'function' then return end
    widget._dcs_sms_orig_onChange = orig
    widget.onChange = function(self, ...)
        local ok, err = pcall(orig, self, ...)
        if not ok then
            pcall(function()
                _G.log.write('sms.me.me_units_list_hook', _G.log.WARNING or 2,
                    panel_name .. '.c_skill orig onChange threw: ' .. tostring(err))
            end)
        end
        if _on_change then
            local vdata = panel_mod.vdata
            local group = vdata and vdata.group
            local unit  = group and vdata.unit and group.units
                          and group.units[vdata.unit.cur or vdata.unit]
            pcall(_on_change, 'unit', group, unit)
        end
    end
end

function M.try_wrap_skill_handlers()
    for _, p in ipairs(SKILL_PANELS) do
        local ok, mod = pcall(require, p.module)
        if ok and type(mod) == 'table' then
            wrap_widget_onchange(mod, p.module)
        end
    end
end

function M.uninstall()
    _on_change = nil
end

return M
