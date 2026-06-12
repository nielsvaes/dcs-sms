-- mass_edit_map_sync.lua — pure logic for the From map buttons (group +
-- unit scope). The mass_edit.lua handler (on_fetch_from_map) is a thin
-- shim around these functions. Extracting the logic here keeps the
-- handlers testable without dxgui — same pattern as
-- mass_edit_transforms.lua.
--
-- Both functions take the host's W table (mass_edit.lua's per-window
-- state) and mutate W.checked / W.anchor in place. They return a result
-- table for the host to surface as a toast.

local M = {}

-- compute_fetch(W, snap[, scope])
--   W    : { scope, pool, checked = { [scope] = { [g] = true } },
--            anchor = { [scope] = g | nil } }
--   snap : result of selection.snapshot() — { ok, error?, groups = [g...], ... }
--   scope: 'group' (default) | 'static'. Statics are single-unit groups and
--          the marquee returns them as groups exactly like real groups, so the
--          fetch logic is identical — only the check-bucket and the success
--          noun differ. Omitting scope preserves the original group behavior.
--
-- Side effects on success:
--   W.checked[scope] is replaced with { [g] = true } for each snap group
--     also found in W.pool (identity match).
--   W.anchor[scope] is cleared (the prior anchor pointed into old state).
--
-- Returns:
--   { ok = bool,
--     empty? = bool, count? = N, missed? = N,
--     toast = string, sev = 'info' | 'warn' | 'err' }
function M.compute_fetch(W, snap, scope)
    scope = scope or 'group'
    if not snap or not snap.ok then
        return {
            ok    = false,
            toast = 'Failed to read map: ' .. tostring(snap and snap.error or 'unknown'),
            sev   = 'err',
        }
    end

    local groups = snap.groups
    if type(groups) ~= 'table' or #groups == 0 then
        return {
            ok    = true,
            empty = true,
            toast = 'Map selection empty',
            sev   = 'warn',
        }
    end

    -- Build identity set of the current pool.
    local in_pool = {}
    for _, e in ipairs(W.pool or {}) do in_pool[e] = true end

    local new_checked = {}
    local missed = 0
    local count = 0
    for _, g in ipairs(groups) do
        if in_pool[g] then
            new_checked[g] = true
            count = count + 1
        else
            missed = missed + 1
        end
    end

    W.checked[scope] = new_checked
    W.anchor[scope]  = nil

    -- Missed items are groups selected on the map that aren't in THIS scope's
    -- pool (e.g. a vehicle selected while on the static scope) — so the missed
    -- wording stays the generic "groups" regardless of scope.
    if missed > 0 then
        return {
            ok = true, count = count, missed = missed,
            toast = string.format('Fetched %d; %d map groups not in current pool', count, missed),
            sev   = 'warn',
        }
    end

    local noun = (scope == 'static') and 'statics' or 'groups'
    return {
        ok = true, count = count, missed = 0,
        toast = string.format('Fetched %d %s from map', count, noun),
        sev   = 'info',
    }
end

-- compute_fetch_units(W, snap)
--   Unit-scope analog of compute_fetch. Map marquee only exposes groups
--   (ME has no per-unit selection API), so "From map" for unit scope
--   means: take every selected group and check ALL its units in the
--   unit-scope pool. Useful when the user has marqueed a few groups on
--   the map and wants their units pre-checked in the form panel.
--
--   Side effects on success:
--     W.checked.unit is replaced with { [u] = true } for every unit
--       of every map-selected group that's present in W.pool.
--     W.anchor.unit is cleared.
function M.compute_fetch_units(W, snap)
    if not snap or not snap.ok then
        return {
            ok    = false,
            toast = 'Failed to read map: ' .. tostring(snap and snap.error or 'unknown'),
            sev   = 'err',
        }
    end

    local groups = snap.groups
    if type(groups) ~= 'table' or #groups == 0 then
        return {
            ok    = true,
            empty = true,
            toast = 'Map selection empty',
            sev   = 'warn',
        }
    end

    -- Build group -> [units] index from the current unit pool. Uses
    -- W.parent_map (entity_ref -> group_ref) so identity matches the
    -- group refs the marquee returns from Mission.getGroup(id).
    local pool_units_by_group = {}
    for _, u in ipairs(W.pool or {}) do
        local g = (W.parent_map or {})[u]
        if g then
            local bucket = pool_units_by_group[g] or {}
            bucket[#bucket + 1] = u
            pool_units_by_group[g] = bucket
        end
    end

    local new_checked = {}
    local count = 0
    local missed_groups = 0
    for _, g in ipairs(groups) do
        local bucket = pool_units_by_group[g]
        if bucket then
            for _, u in ipairs(bucket) do
                new_checked[u] = true
                count = count + 1
            end
        else
            missed_groups = missed_groups + 1
        end
    end

    W.checked.unit = new_checked
    W.anchor.unit  = nil

    if missed_groups > 0 then
        return {
            ok = true, count = count, missed = missed_groups,
            toast = string.format('Fetched %d units; %d map groups not in current pool', count, missed_groups),
            sev   = 'warn',
        }
    end

    return {
        ok = true, count = count, missed = 0,
        toast = string.format('Fetched %d units from map', count),
        sev   = 'info',
    }
end

return M
