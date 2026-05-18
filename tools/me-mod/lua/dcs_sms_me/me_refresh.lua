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

-- Heavyweight refresh: forces a full symbol re-render via
-- create_group_map_objects(g, true). Use this after mutations that change
-- the symbol's APPEARANCE (color, icon coalition tint) — coalition
-- changes are the main example. update_group_map_objects alone doesn't
-- pick up appearance changes; the symbol stays the old color until the
-- user clicks the group, which forces ME-internal redraw.
--
-- Trade-off: this call orphans the previous map-object instances in
-- MapWindow's internal cache (per the comment in verbs.lua's
-- ensure_map_objects). For rare actions like a coalition change that's
-- acceptable; don't use this in hot paths.
function M.recreate_group_view(g)
    local Mission = require('me_mission')
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
