-- me_refresh.lua — defensive map-objects refresh after a group-level mutation.
--
-- Extracted from verbs.lua's local refresh_group_view so it can be shared
-- with the Mass Edit form modules without duplicating the Mission API
-- knowledge.
-- Disk-loaded groups have mapObjects=nil until selected; the
-- create_group_map_objects + update_group_map_objects pair handles both
-- the never-rendered and already-rendered cases. Each ME call is pcall'd
-- so missing/changed ED internals degrade to a no-op.

local M = {}

-- Lightweight refresh: rebuilds the data layer (update_group_map_objects).
-- Use this after name / payload / route mutations where the visual symbol
-- on the map doesn't need to change appearance — only its underlying
-- data.
function M.refresh_group_view(g)
    local Mission = require('me_mission')
    if g.mapObjects == nil and type(Mission.create_group_map_objects) == 'function' then
        pcall(Mission.create_group_map_objects, g)
    end
    if type(Mission.update_group_map_objects) == 'function' then
        pcall(Mission.update_group_map_objects, g)
    end
end

-- Heavyweight refresh: cleanly remove the group's existing map symbols
-- and rebuild them from scratch. Use this after mutations that change
-- the symbol's APPEARANCE (coalition tint, unit rotation, etc.) —
-- update_group_map_objects alone refreshes the data layer but not the
-- rendered symbol's appearance, so the old icon / orientation lingers
-- until the user clicks the group and forces an ME-internal redraw.
--
-- The remove step is essential. create_group_map_objects(g, true) by
-- itself leaves the previous render in MapWindow's internal scene
-- cache (the new objects coexist with the old ones), so each call
-- accumulates a ghost on the map — observable after repeated rotation
-- edits. ED's own remove_unit_symbol uses MapWindow.removeUserObjects
-- to avoid this; remove_group_map_objects wraps that cleanup for the
-- whole group. noUpdateHeading=true on create keeps the just-set
-- u.heading instead of letting ED's updateHeading() override aircraft
-- heading from waypoint geometry.
function M.recreate_group_view(g)
    local Mission = require('me_mission')
    if g.mapObjects ~= nil and type(Mission.remove_group_map_objects) == 'function' then
        pcall(Mission.remove_group_map_objects, g)
    end
    if type(Mission.create_group_map_objects) == 'function' then
        pcall(Mission.create_group_map_objects, g, true)
    end
    if type(Mission.update_group_map_objects) == 'function' then
        pcall(Mission.update_group_map_objects, g)
    end
end

-- Visibility refresh: remove the existing map symbol and only recreate it
-- if the group is currently visible (i.e. g.hidden ~= true and any
-- relevant toolbar/coalition toggles don't suppress it). Mirrors the
-- behavior of MapWindow.updateHiddenGroup -- the function ED's own
-- "HIDDEN ON MAP" checkbox handler calls. Necessary because
-- update_group_map_objects alone keeps the symbol drawn even after the
-- hidden flag flips to true (the data layer updates but the renderer
-- doesn't drop the icon); recreate_group_view re-renders it but also
-- can't hide it.
function M.update_hidden_group(g)
    local ok_mw, MapWindow = pcall(require, 'me_map_window')
    if ok_mw and MapWindow and type(MapWindow.updateHiddenGroup) == 'function' then
        pcall(MapWindow.updateHiddenGroup, g)
        return
    end
    -- Fallback when me_map_window isn't reachable (unit-test VMs etc.):
    -- mirror the show/hide flow against me_mission directly.
    local Mission = require('me_mission')
    if type(Mission.remove_group_map_objects) == 'function' then
        pcall(Mission.remove_group_map_objects, g)
    end
    if g.hidden ~= true and type(Mission.create_group_map_objects) == 'function' then
        pcall(Mission.create_group_map_objects, g)
    end
end

-- In-place unit-heading refresh: rotate the unit's existing map
-- symbol via picModel:setOrientationEuler instead of tearing the
-- whole group's render down and rebuilding it. Mirrors what ED's own
-- sp_heading:onChange handler does (me_aircraft.lua:275 →
-- updateHeading at me_aircraft.lua:2640-2642):
--
--     unitObj.picModel:setOrientationEuler(
--         MapWindow.headingToAngle(group.units[k].heading), 0, 0)
--
-- followed by Mission.update_group_map_objects(g) for the route /
-- label / waypoint refresh. The picModel is a persistent scene
-- object; rotating it in place is smooth, no flicker.
--
-- Falls back to refresh_group_view (which will create the picModel
-- if it's missing) for disk-loaded groups that have never been
-- rendered yet. Unit index in mapObjects.units mirrors the position
-- in g.units (ED indexes them in lockstep — see remove_unit_symbol /
-- insert_unit_symbol in me_mission.lua).
function M.update_unit_heading_view(g, u)
    if not (g and u) then return end
    if not (g.mapObjects and type(g.mapObjects.units) == 'table' and type(g.units) == 'table') then
        M.refresh_group_view(g)
        return
    end

    local unit_index
    for i, gu in ipairs(g.units) do
        if gu == u then unit_index = i; break end
    end
    if not unit_index then
        M.refresh_group_view(g)
        return
    end

    local mo = g.mapObjects.units[unit_index]
    if not (mo and mo.picModel and type(mo.picModel.setOrientationEuler) == 'function') then
        M.refresh_group_view(g)
        return
    end

    local ok_mw, MapWindow = pcall(require, 'me_map_window')
    if not (ok_mw and MapWindow and type(MapWindow.headingToAngle) == 'function') then
        M.refresh_group_view(g)
        return
    end

    pcall(mo.picModel.setOrientationEuler, mo.picModel,
          MapWindow.headingToAngle(u.heading or 0), 0, 0)

    local Mission = require('me_mission')
    if type(Mission.update_group_map_objects) == 'function' then
        pcall(Mission.update_group_map_objects, g)
    end
end

-- Group-panel refresh: re-read the currently-selected group's data
-- back into the ME's right-side panel widgets, so checkboxes / combos
-- / fields reflect any external mutation (e.g. one we just made via a
-- mass-edit form). Each ME category module (me_aircraft / me_vehicle
-- / me_ship / me_static) has its own global update() function that
-- reads from its own vdata.group. Only the panel actually mounted in
-- the right pane will produce visible changes; the rest are best-
-- effort no-ops or harmless throws (caught by pcall).
function M.refresh_group_panels()
    local categories = { 'me_aircraft', 'me_vehicle', 'me_ship', 'me_static' }
    for _, name in ipairs(categories) do
        local ok, mod = pcall(require, name)
        if ok and mod and type(mod.update) == 'function' then
            pcall(mod.update)
        end
    end
end

return M
