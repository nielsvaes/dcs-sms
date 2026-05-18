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

function M.refresh_group_view(g)
    local Mission = require('me_mission')
    if g.mapObjects == nil and type(Mission.create_group_map_objects) == 'function' then
        pcall(Mission.create_group_map_objects, g)
    end
    if type(Mission.update_group_map_objects) == 'function' then
        pcall(Mission.update_group_map_objects, g)
    end
end

return M
