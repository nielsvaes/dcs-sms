-- me_group_focus.lua — single-select a group in the ME and mount its
-- right-side properties panel.
--
-- Different from me_select_writer.lua: that module uses the multi-
-- selection API (me_multiSelection.setSelectingObjectsOutside), which
-- highlights groups on the map but does NOT mount the editable group
-- panel on the right. To open the panel we have to follow the same
-- call sequence the vanilla Unit List uses for its row-click — see
-- me_units_list.selectGroup (modules/me_units_list.lua:578).
--
-- The mount happens as a side effect of MapWindow.respondToSelectedUnit:
-- that function notifies every category panel that "this is now the
-- active unit", and the matching one (me_aircraft / me_vehicle /
-- me_ship / me_static) attaches itself to the right pane.
--
-- Public:
--   M.focus(group, opt_unit) → { ok, error? }
--     group   : a group table from the loaded mission tree (with
--               groupId; the same refs returned by selection.snapshot()).
--     opt_unit: optional specific unit inside the group to focus.
--               Used by the Mass Edit unit-scope row click so the
--               panel highlights the clicked unit, not units[1].
--
-- pcall-guarded throughout. Any missing/changed ED internal returns
-- { ok = false, error = '...' } so callers can degrade gracefully.

local M = {}

function M.focus(group, opt_unit)
    if type(group) ~= 'table' or not group.groupId then
        return { ok = false, error = 'invalid group' }
    end

    -- Disk-loaded groups have mapObjects = nil until the ME renders
    -- them. Build it before reading group.mapObjects.units[1].
    local ok_mission, Mission = pcall(require, 'me_mission')
    if ok_mission and type(Mission) == 'table'
       and type(Mission.create_group_map_objects) == 'function'
       and group.mapObjects == nil then
        pcall(Mission.create_group_map_objects, group)
    end

    if not (type(group.mapObjects) == 'table'
            and type(group.mapObjects.units) == 'table'
            and group.mapObjects.units[1]) then
        return { ok = false, error = 'group.mapObjects.units[1] unavailable' }
    end

    local unit = opt_unit
    if type(unit) ~= 'table' then
        unit = group.units and group.units[1]
    end
    if type(unit) ~= 'table' then
        return { ok = false, error = 'group has no units' }
    end

    local ok_mw, MapWindow = pcall(require, 'me_map_window')
    if not (ok_mw and type(MapWindow) == 'table'
            and type(MapWindow.respondToSelectedUnit) == 'function') then
        return { ok = false, error = 'me_map_window.respondToSelectedUnit unavailable' }
    end

    local mapObject = group.mapObjects.units[1]

    -- Mirrors me_units_list.selectGroup (visible-group branch).
    -- The order matters: unselectAll first to drop the prior panel
    -- binding, then set the new active group/unit, then
    -- respondToSelectedUnit triggers the panel mount.
    if type(MapWindow.unselectAll) == 'function' then
        pcall(MapWindow.unselectAll)
    end
    MapWindow.selectedGroup = group
    if type(MapWindow.setSelectedUnit) == 'function' then
        pcall(MapWindow.setSelectedUnit, unit)
    end

    local ok_resp, err = pcall(MapWindow.respondToSelectedUnit, mapObject, group, unit)
    if not ok_resp then
        return { ok = false, error = tostring(err) }
    end

    return { ok = true }
end

return M
