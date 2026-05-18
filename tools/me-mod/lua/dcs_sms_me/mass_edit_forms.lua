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
local set_country             = require('dcs_sms_me.mass_edit_forms.set_country')

M.by_scope = {
    -- rename on top (most active), find/replace in the middle, set_country at the bottom.
    group    = { rename_group, find_replace_group_name, set_country },
    unit     = {},
    waypoint = {},
    zone     = {},
    drawing  = {},
}

function M.forms_for(scope)
    return M.by_scope[scope] or {}
end

return M
