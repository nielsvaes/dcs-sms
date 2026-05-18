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

return M
