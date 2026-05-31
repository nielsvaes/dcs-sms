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

-- Resolve the live zone entity from a placement-record entry. prefab_ops
-- stores {orig_name, runtime_id}; we also accept {zone_obj=...} when
-- callers (or tests) have a direct reference. Returns the live table or
-- nil if no entity can be reached.
local function resolve_zone(entry)
    if type(entry) ~= 'table' then return nil end
    if type(entry.zone_obj) == 'table' then return entry.zone_obj end
    -- Best-effort lookup via TriggerZoneController. Defensive: missing
    -- API -> return nil and let the caller log a failure. Live DCS exposes
    -- getZone(id); test VM does not.
    local ok, ctrl = pcall(require, 'Mission.TriggerZoneController')
    if not ok or type(ctrl) ~= 'table' then return nil end
    if type(ctrl.getZone) == 'function' and entry.runtime_id then
        local got_ok, zone = pcall(ctrl.getZone, entry.runtime_id)
        if got_ok and type(zone) == 'table' then return zone end
    end
    return nil
end

-- Resolve the live drawing entity from a placement-record entry. prefab_ops
-- stores {orig_name, drawing_obj}; the drawing_obj IS the live table.
local function resolve_drawing(entry)
    if type(entry) ~= 'table' then return nil end
    if type(entry.drawing_obj) == 'table' then return entry.drawing_obj end
    return nil
end

-- Apply a text transform to each zone/drawing entry's .name. Each entity
-- gets resolved via the resolver; nil-resolution counts as a failure but
-- does not abort the batch. Returns {changed, failed}. Live DCS refresh
-- hooks (panel.loadFromMission for drawings, TriggerZoneController for
-- zones) are best-effort: we pcall them; failure leaves .name written
-- but ME visual state unrefreshed until the next manual interaction.
local function apply_text_transform(entries, resolver, transform_fn)
    local changed, failed = 0, 0
    for _, entry in ipairs(entries or {}) do
        local e = resolver(entry)
        if e and type(e.name) == 'string' then
            local old = e.name
            local new = transform_fn(old)
            if new ~= old then
                e.name = new
                changed = changed + 1
            end
        else
            failed = failed + 1
        end
    end
    return changed, failed
end

-- Refresh hooks are pcall'd best-effort. Failures degrade silently.
local function refresh_drawings()
    pcall(function()
        local panel = require('me_draw_panel')
        if type(panel) == 'table' and type(panel.getObjects) == 'function' then
            -- Some panels expose loadFromMission(toData()) to round-trip
            -- the .name change through the renderer. Calling it without
            -- args is a no-op on builds that don't support it.
            if type(panel.loadFromMission) == 'function' then
                pcall(panel.loadFromMission)
            end
        end
    end)
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

    -- Pass 2: Prefix.
    if type(opts.prefix) == 'string' and opts.prefix ~= '' then
        local add_prefix = require('dcs_sms_me.mass_edit_forms.add_prefix_group_name')
        local r = add_prefix._apply(group_entities, opts.prefix)
        result.renamed_groups = result.renamed_groups + (r.changed or 0)
        result.failed = result.failed + (r.failed or 0)
        -- Zones + drawings: direct walk via internal helpers.
        local fn = function(old) return opts.prefix .. old end
        local z_changed, z_failed = apply_text_transform(rec.zones, resolve_zone, fn)
        local d_changed, d_failed = apply_text_transform(rec.drawings, resolve_drawing, fn)
        result.renamed_zones    = result.renamed_zones    + z_changed
        result.renamed_drawings = result.renamed_drawings + d_changed
        result.failed           = result.failed + z_failed + d_failed
        if d_changed > 0 then refresh_drawings() end
    end

    -- Pass 3: Suffix.
    if type(opts.suffix) == 'string' and opts.suffix ~= '' then
        local add_suffix = require('dcs_sms_me.mass_edit_forms.add_suffix_group_name')
        local r = add_suffix._apply(group_entities, opts.suffix, { keep_num = opts.keep_num == true })
        result.renamed_groups = result.renamed_groups + (r.changed or 0)
        result.failed = result.failed + (r.failed or 0)
        -- Zones + drawings: identical keep_num semantics via the shared transform.
        local transforms = require('dcs_sms_me.mass_edit_transforms')
        local fn = function(old)
            return transforms.add_suffix(old, { text = opts.suffix, keep_num = opts.keep_num == true })
        end
        local z_changed, z_failed = apply_text_transform(rec.zones, resolve_zone, fn)
        local d_changed, d_failed = apply_text_transform(rec.drawings, resolve_drawing, fn)
        result.renamed_zones    = result.renamed_zones    + z_changed
        result.renamed_drawings = result.renamed_drawings + d_changed
        result.failed           = result.failed + z_failed + d_failed
        if d_changed > 0 then refresh_drawings() end
    end

    -- Pass 4: Auto-name units (only if any of name/prefix/suffix ran). Reads
    -- each group's CURRENT name so unit names see the post-rename state.
    -- Passes all group entries — statics are 1-unit groups, so the lone unit
    -- becomes <staticname>-1 which is benign and consistent.
    local any_rename = (result.renamed_groups > 0)
                    or (result.renamed_statics > 0)
                    or (result.renamed_zones > 0)
                    or (result.renamed_drawings > 0)
    if any_rename then
        local auto_name = require('dcs_sms_me.mass_edit_forms.auto_name_units_group')
        local r = auto_name._apply(group_entities)
        result.renamed_units = result.renamed_units + (r.changed or 0)
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
