-- selection.lua — ME selection-state lookup.
--
-- This is the only file that touches ME-internal globals. Every external
-- call is wrapped in pcall so a DCS patch breaking these APIs degrades to
-- {ok=false, error=...} instead of crashing the user's editor session.
--
-- Public:
--   M.snapshot() → {
--     ok            = boolean,
--     error         = string?,
--     timestamp_utc = string,
--     selection_mode = "multi"|"single",
--     groups        = table[],
--     zones         = table[],
--     drawings      = table[],
--     nav_points    = table[],
--     raw           = table,                -- everything ME handed us, verbatim
--   }

local M = {}

-- Lazy requires inside helpers so a missing module fails gracefully via the
-- outer pcall rather than at module-load time.

local function utc_now()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

local function safe_call(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil, result
end

local function empty_snap()
    return {
        groups        = {},
        zones         = {},
        drawings      = {},
        nav_points    = {},
        raw           = {},
    }
end

local function collect_multi()
    local snap = empty_snap()
    snap.selection_mode = 'multi'

    local multiSelection = require('me_multiSelection')
    local Mission        = require('me_mission')

    local objects, err = safe_call(multiSelection.getSelectedObjects)
    if not objects then
        snap.raw.multi_get_objects_error = tostring(err)
        return snap
    end
    snap.raw.multi_get_objects = objects

    -- objects.selectGroups: table keyed by group id → group descriptor (already
    -- a DCS-shaped or ME-shaped table; we pass it through as-is, then also
    -- attempt Mission.getGroup(id) for the canonical raw form).
    if type(objects.selectGroups) == 'table' then
        for id, desc in pairs(objects.selectGroups) do
            local raw_group = safe_call(Mission.getGroup, id)
            snap.groups[#snap.groups + 1] = raw_group or desc
        end
    end
    if type(objects.selectTriggerZones) == 'table' then
        for _, zone in pairs(objects.selectTriggerZones) do
            snap.zones[#snap.zones + 1] = zone
        end
    end
    if type(objects.selectDrawObjects) == 'table' then
        for _, drw in pairs(objects.selectDrawObjects) do
            snap.drawings[#snap.drawings + 1] = drw
        end
    end
    return snap
end

local function collect_single()
    local snap = empty_snap()
    snap.selection_mode = 'single'

    local MapWindow                = require('me_map_window')
    local Mission                  = require('me_mission')
    local MapController            = require('Mission.MapController')
    local MissionData              = require('Mission.Data')
    local TriggerZoneController    = require('Mission.TriggerZoneController')
    local NavigationPointController = require('Mission.NavigationPointController')

    -- Groups (and statics, which the ME models as single-unit groups).
    local groups = safe_call(MapWindow.getSelectedGroups)
    snap.raw.single_get_groups = groups
    if type(groups) == 'table' then
        for id, _ in pairs(groups) do
            local raw_group = safe_call(Mission.getGroup, id)
            if raw_group then snap.groups[#snap.groups + 1] = raw_group end
        end
    end

    -- Single non-group selection (zone, nav point) via MapController.
    local objectId = safe_call(MapController.getSelectedObjectId)
    snap.raw.single_object_id = objectId
    if objectId then
        local kind = safe_call(MissionData.getObjectType, objectId)
        if kind == safe_call(MissionData.triggerZoneType) then
            local zone = safe_call(TriggerZoneController.getTriggerZone, objectId)
            if zone then snap.zones[#snap.zones + 1] = zone end
        elseif kind == safe_call(MissionData.navigationPointType) then
            local np = safe_call(NavigationPointController.getNavigationPoint, objectId)
            if np then snap.nav_points[#snap.nav_points + 1] = np end
        end
    end

    -- Current draw object (panel_draw module).
    local panel_draw = safe_call(require, 'me_draw_panel')
    if panel_draw and panel_draw.getCurrObject then
        local drawObj = safe_call(panel_draw.getCurrObject)
        snap.raw.single_draw_object = drawObj
        if drawObj then snap.drawings[#snap.drawings + 1] = drawObj end
    end

    return snap
end

function M.snapshot()
    local ok, result = pcall(function()
        local multiSelection = require('me_multiSelection')
        if multiSelection.isVisible and multiSelection.isVisible() then
            return collect_multi()
        end
        return collect_single()
    end)
    if not ok then
        local snap = empty_snap()
        snap.ok = false
        snap.error = tostring(result)
        snap.timestamp_utc = utc_now()
        snap.selection_mode = 'unknown'
        return snap
    end
    result.ok = true
    result.timestamp_utc = utc_now()
    return result
end

-- ---------------------------------------------------------------------------
-- snapshot_drilled — Mass Edit's scope-aware entry point.
--
-- Builds an entity pool for the requested scope, drilled from the current
-- marquee. When the marquee is empty, falls back to walking the whole
-- mission table so the user can still use the Mass Edit window.
--
-- Returns {
--   ok           = bool,
--   error?       = string,
--   scope        = '<scope>',
--   source       = 'marquee' | 'mission',
--   pool         = [entity_ref, ...],
--   parent_map   = { [entity_ref] = group_ref }  -- identity for group scope
-- }
-- ---------------------------------------------------------------------------

local VALID_SCOPES = { group = true, unit = true, waypoint = true, zone = true, drawing = true }

local function walk_mission_groups(callback)
    local Mission = require('me_mission')
    local mission = Mission and Mission.mission
    if not mission or type(mission.coalition) ~= 'table' then return end
    for _, side in pairs(mission.coalition) do
        if type(side) == 'table' and type(side.country) == 'table' then
            for _, country in ipairs(side.country) do
                for _, cat in ipairs({ 'plane', 'helicopter', 'vehicle', 'ship', 'static' }) do
                    local bucket = country[cat]
                    if type(bucket) == 'table' and type(bucket.group) == 'table' then
                        for _, g in ipairs(bucket.group) do
                            callback(g, cat)
                        end
                    end
                end
            end
        end
    end
end

-- Build a {group_ref -> category} index by walking the whole mission once.
-- snapshot_drilled uses this so both the marquee path (group refs from
-- M.snapshot) and the mission-walk path (no surrounding container in scope)
-- can attach the right category to each entity. Marquee groups come from
-- Mission.getGroup(id) which returns the same ref the mission tree stores,
-- so identity-keying works for both paths.
local function build_category_index()
    local index = {}
    walk_mission_groups(function(g, cat) index[g] = cat end)
    return index
end

function M.snapshot_drilled(scope)
    if not VALID_SCOPES[scope] then
        return { ok = false, error = 'unknown scope: ' .. tostring(scope),
                 scope = tostring(scope), source = 'marquee',
                 pool = {}, parent_map = {} }
    end

    local marquee = M.snapshot()
    local out = {
        ok = true, scope = scope, source = 'marquee',
        pool = {}, parent_map = {}, categories = {},
    }

    -- Source: marquee groups if any; otherwise the whole mission tree.
    local groups = {}
    if marquee.ok and type(marquee.groups) == 'table' and #marquee.groups > 0 then
        for _, g in ipairs(marquee.groups) do groups[#groups + 1] = g end
    else
        out.source = 'mission'
        walk_mission_groups(function(g) groups[#groups + 1] = g end)
    end

    -- One mission walk for category resolution — keyed by group identity.
    -- Both the marquee path (Mission.getGroup returns the canonical ref)
    -- and the mission-walk path will find their groups here.
    local cat_by_group = build_category_index()
    local function cat_of(g) return cat_by_group[g] or 'unknown' end

    if scope == 'group' then
        for _, g in ipairs(groups) do
            out.pool[#out.pool + 1] = g
            out.parent_map[g] = g
            out.categories[g] = cat_of(g)
        end
        return out
    end

    if scope == 'unit' then
        for _, g in ipairs(groups) do
            if type(g.units) == 'table' then
                local cat = cat_of(g)
                for _, u in ipairs(g.units) do
                    out.pool[#out.pool + 1] = u
                    out.parent_map[u] = g
                    out.categories[u] = cat
                end
            end
        end
        return out
    end

    if scope == 'waypoint' then
        for _, g in ipairs(groups) do
            if type(g.route) == 'table' and type(g.route.points) == 'table' then
                local cat = cat_of(g)
                for _, wp in ipairs(g.route.points) do
                    out.pool[#out.pool + 1] = wp
                    out.parent_map[wp] = g
                    out.categories[wp] = cat
                end
            end
        end
        return out
    end

    if scope == 'zone' then
        if marquee.ok and type(marquee.zones) == 'table' and #marquee.zones > 0 then
            for _, z in ipairs(marquee.zones) do
                out.pool[#out.pool + 1] = z
                out.parent_map[z] = z
            end
        else
            out.source = 'mission'
            local Mission = require('me_mission')
            local mission = Mission and Mission.mission
            local zones = mission and mission.triggers and mission.triggers.zones
            if type(zones) == 'table' then
                for _, z in ipairs(zones) do
                    out.pool[#out.pool + 1] = z
                    out.parent_map[z] = z
                end
            end
        end
        return out
    end

    if scope == 'drawing' then
        if marquee.ok and type(marquee.drawings) == 'table' and #marquee.drawings > 0 then
            for _, d in ipairs(marquee.drawings) do
                out.pool[#out.pool + 1] = d
                out.parent_map[d] = d
            end
        else
            out.source = 'mission'
            local Mission = require('me_mission')
            local mission = Mission and Mission.mission
            local layers = mission and mission.drawings and mission.drawings.layers
            if type(layers) == 'table' then
                for _, layer in ipairs(layers) do
                    if type(layer.objects) == 'table' then
                        for _, d in ipairs(layer.objects) do
                            out.pool[#out.pool + 1] = d
                            out.parent_map[d] = d
                        end
                    end
                end
            end
        end
        return out
    end

    return out  -- unreachable
end

-- ---------------------------------------------------------------------------
-- snapshot_mission — like snapshot_drilled but always walks the full mission
-- tree (no marquee dependency, no fallback path). Used by Mass Edit, which
-- selects entities via in-window checkboxes rather than the ME's marquee.
--
-- Returns the same shape as snapshot_drilled (ok, scope, source, pool,
-- parent_map, categories). source is always 'mission'.
-- ---------------------------------------------------------------------------

function M.snapshot_mission(scope)
    if not VALID_SCOPES[scope] then
        return { ok = false, error = 'unknown scope: ' .. tostring(scope),
                 scope = tostring(scope), source = 'mission',
                 pool = {}, parent_map = {}, categories = {} }
    end

    local out = {
        ok = true, scope = scope, source = 'mission',
        pool = {}, parent_map = {}, categories = {},
    }

    local cat_by_group = build_category_index()
    local function cat_of(g) return cat_by_group[g] or 'unknown' end

    if scope == 'group' then
        walk_mission_groups(function(g)
            out.pool[#out.pool + 1] = g
            out.parent_map[g] = g
            out.categories[g] = cat_of(g)
        end)
        return out
    end

    if scope == 'unit' then
        walk_mission_groups(function(g)
            if type(g.units) == 'table' then
                local cat = cat_of(g)
                for _, u in ipairs(g.units) do
                    out.pool[#out.pool + 1] = u
                    out.parent_map[u] = g
                    out.categories[u] = cat
                end
            end
        end)
        return out
    end

    if scope == 'waypoint' then
        walk_mission_groups(function(g)
            if type(g.route) == 'table' and type(g.route.points) == 'table' then
                local cat = cat_of(g)
                for _, wp in ipairs(g.route.points) do
                    out.pool[#out.pool + 1] = wp
                    out.parent_map[wp] = g
                    out.categories[wp] = cat
                end
            end
        end)
        return out
    end

    if scope == 'zone' then
        local Mission = require('me_mission')
        local mission = Mission and Mission.mission
        local zones = mission and mission.triggers and mission.triggers.zones
        if type(zones) == 'table' then
            for _, z in ipairs(zones) do
                out.pool[#out.pool + 1] = z
                out.parent_map[z] = z
            end
        end
        return out
    end

    if scope == 'drawing' then
        local Mission = require('me_mission')
        local mission = Mission and Mission.mission
        local layers = mission and mission.drawings and mission.drawings.layers
        if type(layers) == 'table' then
            for _, layer in ipairs(layers) do
                if type(layer.objects) == 'table' then
                    for _, d in ipairs(layer.objects) do
                        out.pool[#out.pool + 1] = d
                        out.parent_map[d] = d
                    end
                end
            end
        end
        return out
    end

    return out
end

return M
