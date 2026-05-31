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
    -- Passes added in subsequent tasks.
    return result
end

function M._compute_targets(rec, opts)
    -- Filled out in Task 7.
    return {}
end

return M
