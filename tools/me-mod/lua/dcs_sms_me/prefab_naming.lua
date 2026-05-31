-- prefab_naming.lua — placement-time naming pipeline for Prefab Manager.
--
-- Pure logic, no dxgui. Composes Mass Edit's existing form _apply
-- functions to rename freshly-placed entities (groups + statics) per
-- the user's Name / Prefix / Suffix form inputs, then auto-name units
-- inside each renamed group. Zones + drawings get their own internal
-- prefix/suffix walk (name_writer is group-only).
--
-- See: docs/superpowers/specs/2026-05-31-prefab-manager-naming-forms.md
--
-- Public:
--   M.apply(rec, opts) -> {
--     renamed_groups, renamed_statics, renamed_zones, renamed_drawings,
--     renamed_units, failed, toast, sev
--   }
--   M._compute_targets(rec, opts) -> list of {scope, entity, old, new}
--                                   (test-only dry-run; no writes)

local M = {}

-- has_any: true if any of opts.name / opts.prefix / opts.suffix is a
-- non-empty string. Single source of truth for "is there work to do".
local function has_any(opts)
    if type(opts) ~= 'table' then return false end
    local function nz(s) return type(s) == 'string' and s ~= '' end
    return nz(opts.name) or nz(opts.prefix) or nz(opts.suffix)
end

-- Extract the live entity table from a placement-record entry. rec.groups
-- entries are {orig_name, runtime_id, group_obj}; we want the group_obj
-- to hand to Mass Edit's _apply functions (which read .name + .units).
local function entities_from_groups(rec)
    local out = {}
    if type(rec) == 'table' and type(rec.groups) == 'table' then
        for _, e in ipairs(rec.groups) do
            if type(e) == 'table' and type(e.group_obj) == 'table' then
                out[#out + 1] = e.group_obj
            end
        end
    end
    return out
end

function M.apply(rec, opts)
    opts = opts or {}
    local result = {
        renamed_groups   = 0,
        renamed_statics  = 0,
        renamed_zones    = 0,
        renamed_drawings = 0,
        renamed_units    = 0,
        failed           = 0,
        toast            = nil,
        sev              = nil,
    }
    if not has_any(opts) then return result end

    local group_entities = entities_from_groups(rec)

    -- Pass 1: Name (groups + statics together — both live in rec.groups).
    if type(opts.name) == 'string' and opts.name ~= '' then
        local rename_group = require('dcs_sms_me.mass_edit_forms.rename_group')
        local r = rename_group._apply(group_entities, opts.name)
        result.renamed_groups = result.renamed_groups + (r.changed or 0)
        result.failed = result.failed + (r.failed or 0)
    end

    -- Pass 2: Prefix (groups + statics — zones + drawings added in Task 6).
    if type(opts.prefix) == 'string' and opts.prefix ~= '' then
        local add_prefix = require('dcs_sms_me.mass_edit_forms.add_prefix_group_name')
        local r = add_prefix._apply(group_entities, opts.prefix)
        result.renamed_groups = result.renamed_groups + (r.changed or 0)
        result.failed = result.failed + (r.failed or 0)
    end

    -- Composition / aggregate sev set in Task 7. For now, report success
    -- when any rename landed and no failures occurred.
    if result.renamed_groups > 0 and result.failed == 0 then
        result.sev = 'success'
    end

    return result
end

function M._compute_targets(rec, opts)
    -- Filled out in Task 7.
    return {}
end

return M
