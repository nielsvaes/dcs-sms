-- mass_edit_map_sync.lua — pure logic for the From map / To map buttons.
--
-- The mass_edit.lua handlers (on_fetch_from_map, on_push_to_map) are
-- thin shims around these functions. Extracting the logic here keeps
-- the handlers testable without dxgui — same pattern as
-- mass_edit_transforms.lua.
--
-- Both functions take the host's W table (mass_edit.lua's per-window
-- state) and mutate W.checked / W.anchor in place. They return a result
-- table for the host to surface as a toast.

local M = {}

-- compute_fetch(W, snap)
--   W   : { scope, pool, checked = { group = { [g] = true } }, anchor = { group = g | nil } }
--   snap: result of selection.snapshot() — { ok, error?, groups = [g...], ... }
--
-- Side effects on success:
--   W.checked.group is replaced with { [g] = true } for each snap group
--     also found in W.pool (identity match).
--   W.anchor.group is cleared (the prior anchor pointed into old state).
--
-- Returns:
--   { ok = bool,
--     empty? = bool, count? = N, missed? = N,
--     toast = string, sev = 'info' | 'warn' | 'err' }
function M.compute_fetch(W, snap)
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

    W.checked.group = new_checked
    W.anchor.group  = nil

    if missed > 0 then
        return {
            ok = true, count = count, missed = missed,
            toast = string.format('Fetched %d; %d map groups not in current pool', count, missed),
            sev   = 'warn',
        }
    end

    return {
        ok = true, count = count, missed = 0,
        toast = string.format('Fetched %d groups from map', count),
        sev   = 'info',
    }
end

-- compute_push(W)
--   W: same shape as compute_fetch.
--
-- Returns:
--   { ok = true,
--     empty? = bool,
--     group_refs? = [g, g, ...]  -- pool order, only those in W.checked.group
--     toast?, sev? }
--
-- Walks W.pool (not W.checked) so the output order is deterministic and
-- matches the user's visible row order in the entity list. This makes
-- the count predictable across runs and lets the host pass group_refs
-- straight into me_select_writer.set_group_selection.
function M.compute_push(W)
    local checked = W.checked.group or {}
    local refs = {}
    for _, e in ipairs(W.pool or {}) do
        if checked[e] then refs[#refs + 1] = e end
    end

    if #refs == 0 then
        return {
            ok    = true,
            empty = true,
            toast = 'Nothing checked to push',
            sev   = 'warn',
        }
    end

    return { ok = true, group_refs = refs }
end

return M
