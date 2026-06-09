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
local export_import_warehouse_airbase   = require('dcs_sms_me.mass_edit_forms.export_import_warehouse_airbase')
local toggle_static_flags               = require('dcs_sms_me.mass_edit_forms.toggle_static_flags')
local set_heading_static                = require('dcs_sms_me.mass_edit_forms.set_heading_static')

local auto_name_unit            = require('dcs_sms_me.mass_edit_forms.auto_name_unit')
local find_replace_unit_name    = require('dcs_sms_me.mass_edit_forms.find_replace_unit_name')
local add_prefix_unit_name      = require('dcs_sms_me.mass_edit_forms.add_prefix_unit_name')
local add_suffix_unit_name      = require('dcs_sms_me.mass_edit_forms.add_suffix_unit_name')
local set_skill_unit            = require('dcs_sms_me.mass_edit_forms.set_skill_unit')
local set_onboard_num_unit      = require('dcs_sms_me.mass_edit_forms.set_onboard_num_unit')
local set_livery_unit           = require('dcs_sms_me.mass_edit_forms.set_livery_unit')
local set_heading_unit          = require('dcs_sms_me.mass_edit_forms.set_heading_unit')
local set_fuel_pct_unit         = require('dcs_sms_me.mass_edit_forms.set_fuel_pct_unit')
local toggle_unit_flags         = require('dcs_sms_me.mass_edit_forms.toggle_unit_flags')

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
    -- Unit scope mirrors the group scope's name-mutating-first ordering.
    -- Find/replace + prefix + suffix first (the rename family), then
    -- identity (skill, onboard #), then pose/loadout (livery, heading,
    -- fuel %). Planes-only / planes+helos forms (set_onboard_num_unit,
    -- set_livery_unit, set_fuel_pct_unit) gray out for non-applicable
    -- selections via the applicability observer in mass_edit.lua.
    unit     = {
        auto_name_unit,
        find_replace_unit_name,
        add_prefix_unit_name,
        add_suffix_unit_name,
        set_skill_unit,
        set_onboard_num_unit,
        set_livery_unit,
        set_heading_unit,
        set_fuel_pct_unit,
        toggle_unit_flags,
    },
    -- Static scope mirrors the group scope's name-mutating + set_country
    -- forms (statics are single-unit groups so all of those reuse the
    -- same verbs). Omits auto_name_units_group (statics have no concept
    -- of synced unit names — single unit per group). The toggle form is
    -- static-specific: drops Uncontrolled / Game Master Only / Late
    -- activation (none apply to statics), adds Dead (group.dead) and
    -- Can be cargo (group.units[1].canCargo, Cargo statics only).
    static   = {
        rename_group,
        find_replace_group_name,
        add_prefix_group_name,
        add_suffix_group_name,
        set_country,
        toggle_static_flags,
        set_heading_static,
    },
    waypoint = {},
    zone     = {},
    drawing  = {},
    airbase  = {
        set_coalition_airbase,
        export_import_warehouse_airbase,
    },
}

function M.forms_for(scope)
    return M.by_scope[scope] or {}
end

return M
