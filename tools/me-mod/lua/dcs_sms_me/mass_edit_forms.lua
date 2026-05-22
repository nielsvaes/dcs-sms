-- mass_edit_forms.lua — Mass Edit form loader.
--
-- Maps each scope to an ordered array of form modules. mass_edit.lua
-- iterates this list to mount the right pane's forms when the user
-- switches scope.
--
-- Adding a new form is one new file under mass_edit_forms/ plus one new
-- entry here. Order matters — forms render top-to-bottom in the right
-- pane in the order listed.

local M = {}

local find_replace_group_name = require('dcs_sms_me.mass_edit_forms.find_replace_group_name')
local rename_group            = require('dcs_sms_me.mass_edit_forms.rename_group')
local add_prefix_group_name   = require('dcs_sms_me.mass_edit_forms.add_prefix_group_name')
local add_suffix_group_name   = require('dcs_sms_me.mass_edit_forms.add_suffix_group_name')
local auto_name_units_group   = require('dcs_sms_me.mass_edit_forms.auto_name_units_group')
local set_country             = require('dcs_sms_me.mass_edit_forms.set_country')
local toggle_group_flags      = require('dcs_sms_me.mass_edit_forms.toggle_group_flags')
local set_coalition_airbase             = require('dcs_sms_me.mass_edit_forms.set_coalition_airbase')
local set_warehouse_airbase             = require('dcs_sms_me.mass_edit_forms.set_warehouse_airbase')
local export_import_warehouse_airbase   = require('dcs_sms_me.mass_edit_forms.export_import_warehouse_airbase')

M.by_scope = {
    -- Name-mutating forms first. rename_group + auto_name_units sit next
    -- to each other since "rename the group" and "now sync the unit
    -- names" is a common one-two flow. Then the rest of the name forms
    -- (find/replace → add prefix → add suffix), then side-effecting
    -- forms (set_country flips coalition; toggle_group_flags writes
    -- visibility / control fields).
    group    = {
        rename_group,
        auto_name_units_group,
        find_replace_group_name,
        add_prefix_group_name,
        add_suffix_group_name,
        set_country,
        toggle_group_flags,
    },
    unit     = {},
    waypoint = {},
    zone     = {},
    drawing  = {},
    airbase  = {
        set_coalition_airbase,
        set_warehouse_airbase,
        export_import_warehouse_airbase,
    },
}

function M.forms_for(scope)
    return M.by_scope[scope] or {}
end

return M
