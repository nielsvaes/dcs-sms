-- dcs_sms_me/verbs/camera_verbs.lua — ME map-view camera control.
--
-- Verbs: camera_focus, camera_get.
-- See dcs_sms_me/verbs.lua for the aggregator and the verb-naming convention.

local M = {}

local H = require('dcs_sms_me.verb_helpers')
local find_airbase_by_name = H.find_airbase_by_name

-- =============================================================================
-- Camera (ME map view)
--
-- ED's camera lives in MapWindow. setCamera takes 2D world meters (x = north,
-- y = east) — same units as Terrain.convertLatLonToMeters returns and the
-- same field names as Mission.AirdromeController exposes on each airdrome.
-- setScale takes meters-per-screen-unit; lower = more zoomed in. Order
-- matters: when changing scale and panning at once, set scale first or the
-- camera position snaps oddly at the old scale.

function M.camera_focus(args)
    args = args or {}
    if not _G.MapWindow or not _G.Terrain then
        return { ok = false, error = "ME map view not initialized (open the Mission Editor first)" }
    end
    -- ED's setCamera writes the new center back to module_mission.mission.map.
    -- That subtable doesn't exist on the menu / MP browser / startup screen,
    -- and ED doesn't null-check it — a bare setCamera call there throws.
    local mm_ok, mm = pcall(require, 'me_mission')
    if not mm_ok or not mm or type(mm.mission) ~= 'table' or type(mm.mission.map) ~= 'table' then
        return { ok = false, error = "no mission open in the Mission Editor (load a mission first)" }
    end

    local x, y, lat, lon, name
    if args.name ~= nil then
        local ad = find_airbase_by_name(args.name)
        if not ad then
            return { ok = false, error = string.format("no airdrome found matching %q", tostring(args.name)) }
        end
        name = ad:getName()
        x, y = ad.x, ad.y
        lat, lon = Terrain.convertMetersToLatLon(x, y)
    elseif args.lat ~= nil and args.lon ~= nil then
        lat, lon = args.lat, args.lon
        x, y = Terrain.convertLatLonToMeters(lat, lon)
    elseif args.x ~= nil and args.y ~= nil then
        x, y = args.x, args.y
        lat, lon = Terrain.convertMetersToLatLon(x, y)
    else
        return { ok = false, error = "must provide --name, --lat/--lon, or --x/--y" }
    end

    if args.scale ~= nil then
        MapWindow.setScale(args.scale)
    end
    MapWindow.setCamera(x, y)

    local result = {
        ok = true,
        x = x, y = y,
        lat = lat, lon = lon,
        scale = MapWindow.getScale(),
    }
    if name then result.name = name end
    return result
end

function M.camera_get(args)
    if not _G.MapWindow or not _G.Terrain then
        return { ok = false, error = "ME map view not initialized" }
    end
    local x, y = MapWindow.getCenterMap(0, 0)
    local lat, lon = Terrain.convertMetersToLatLon(x, y)
    return {
        ok = true,
        x = x, y = y,
        lat = lat, lon = lon,
        scale = MapWindow.getScale(),
    }
end

return M
