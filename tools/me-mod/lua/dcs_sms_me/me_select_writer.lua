-- me_select_writer.lua — programmatic write to the ME's multi-selection.
--
-- Pairs with selection.lua (read side). selection.snapshot() reads what's
-- currently selected on the map; this module sets the map selection from
-- outside the marquee tool.
--
-- Uses me_multiSelection.setSelectingObjectsOutside(a_objects) at
-- me_multiSelection.lua:477 — an external-caller entry point. It handles
-- deselectAll(), multi-mode activation (MapWindow.setState), per-group
-- map-symbol updates (MapWindow.addSelectedGroup / respondToSelectedUnit2 /
-- updateSelectedGroup), and the final updateMode() + update() redraw.
--
-- Input shape expected by setSelectingObjectsOutside:
--   { groups_copied      = { [groupId] = group, ... },
--     triggerZones_copied = { ... },
--     draw_copied         = { ... } }
--
-- Public:
--   M.set_group_selection(group_refs) -> { ok, count, error? }
--     group_refs: array of group dicts (same refs returned by
--                 selection.snapshot()/snapshot_mission()). Empty input
--                 is a no-op success — we never call the ME function with
--                 zero groups, because its internal deselectAll() would
--                 wipe the user's current map selection as a side effect.

local M = {}

-- Lazy require inside functions so test stubs via package.preload work
-- regardless of module-load order.

function M.set_group_selection(group_refs)
    if type(group_refs) ~= 'table' or #group_refs == 0 then
        return { ok = true, count = 0 }
    end

    local ok_mms, mms = pcall(require, 'me_multiSelection')
    if not (ok_mms and type(mms) == 'table' and type(mms.setSelectingObjectsOutside) == 'function') then
        return { ok = false, error = 'me_multiSelection.setSelectingObjectsOutside unavailable', count = 0 }
    end

    -- Build the keyed table the ME function expects. Drop entries
    -- without a groupId — they can't be addressed in selectGroups.
    local groups_copied = {}
    local count = 0
    for _, g in ipairs(group_refs) do
        if type(g) == 'table' and g.groupId then
            groups_copied[g.groupId] = g
            count = count + 1
        end
    end

    if count == 0 then
        -- All inputs were unkeyable. Treat as empty — don't call the ME
        -- function (it would clear the map).
        return { ok = true, count = 0 }
    end

    local a_objects = {
        groups_copied       = groups_copied,
        triggerZones_copied = {},
        draw_copied         = {},
    }

    local ok_call, err = pcall(mms.setSelectingObjectsOutside, a_objects)
    if not ok_call then
        return { ok = false, error = tostring(err), count = 0 }
    end

    return { ok = true, count = count }
end

return M
