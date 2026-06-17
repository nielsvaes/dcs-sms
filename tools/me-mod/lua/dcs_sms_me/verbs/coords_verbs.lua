-- dcs_sms_me/verbs/coords_verbs.lua — coordinate conversion verbs.
--
-- Verbs: coords_to_geo, coords_to_local, coords_magvar.
-- See dcs_sms_me/verbs.lua for the aggregator and the verb-naming convention.

local M = {}

-- =============================================================================
-- Coordinate conversion
--
-- The ME exposes Terrain.convertMetersToLatLon(x, y) and the inverse
-- Terrain.convertLatLonToMeters(lat, lon). Both speak in the project's
-- standard "x = north, y = east" 2D world-meters convention (same units as
-- the .miz mission table). The mission-env `coord.LOtoLL` is not available
-- in the GUI exec context, which is what tripped up the original caller
-- (GH#66, request 3); these verbs surface the right ME-side API directly so
-- callers don't have to know that quirk.
--
-- Altitude is a separate, conversion-free field. Both verbs accept it
-- optionally and echo it back unchanged when given, so a single call can
-- produce a complete `{lat, lon, alt}` or `{north, east, alt}` record.

local function _theatre_loaded()
    return _G.Terrain
       and type(_G.Terrain.convertMetersToLatLon) == 'function'
       and type(_G.Terrain.convertLatLonToMeters) == 'function'
end

function M.coords_to_geo(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'coords_to_geo requires args (table)' }
    end
    if type(args.north) ~= 'number' then
        return { ok = false, error = '--north is required (meters north of theatre origin)' }
    end
    if type(args.east) ~= 'number' then
        return { ok = false, error = '--east is required (meters east of theatre origin)' }
    end
    if args.alt ~= nil and type(args.alt) ~= 'number' then
        return { ok = false, error = '--alt must be a number (meters) if given' }
    end
    if not _theatre_loaded() then
        return { ok = false, error = 'theatre not loaded — open or create a mission first' }
    end

    local ok, lat, lon = pcall(Terrain.convertMetersToLatLon, args.north, args.east)
    if not ok then
        return { ok = false, error = 'Terrain.convertMetersToLatLon failed: ' .. tostring(lat) }
    end
    if type(lat) ~= 'number' or type(lon) ~= 'number' then
        return { ok = false, error = 'Terrain.convertMetersToLatLon returned non-numeric result' }
    end

    local out = { ok = true, lat = lat, lon = lon, north = args.north, east = args.east }
    if args.alt ~= nil then out.alt = args.alt end
    return out
end

function M.coords_to_local(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'coords_to_local requires args (table)' }
    end
    if type(args.lat) ~= 'number' then
        return { ok = false, error = '--lat is required (degrees)' }
    end
    if type(args.lon) ~= 'number' then
        return { ok = false, error = '--lon is required (degrees)' }
    end
    if args.alt ~= nil and type(args.alt) ~= 'number' then
        return { ok = false, error = '--alt must be a number (meters) if given' }
    end
    if not _theatre_loaded() then
        return { ok = false, error = 'theatre not loaded — open or create a mission first' }
    end

    local ok, x, y = pcall(Terrain.convertLatLonToMeters, args.lat, args.lon)
    if not ok then
        return { ok = false, error = 'Terrain.convertLatLonToMeters failed: ' .. tostring(x) }
    end
    if type(x) ~= 'number' or type(y) ~= 'number' then
        return { ok = false, error = 'Terrain.convertLatLonToMeters returned non-numeric result' }
    end

    local out = { ok = true, north = x, east = y, lat = args.lat, lon = args.lon }
    if args.alt ~= nil then out.alt = args.alt end
    return out
end

-- coords_magvar — magnetic declination (variation) at a point.
--
-- The ME exposes DCS's `magvar` module; the same one the waypoint panel uses
-- to show each leg's magnetic heading. `magvar.get_mag_decl(lat, lon)` returns
-- the declination in RADIANS (verified against me_statusbar.lua, which wraps it
-- in toDegrees) — we convert to degrees here so callers don't have to know that.
-- East is positive, West negative (e.g. 1944 London ≈ -10°).
--
-- The value is date-dependent: magvar runs an IGRF model against the *open
-- mission's date*, so the same coordinate yields different declination in a
-- 1944 mission vs a present-day one. Open the intended mission first.
--
-- Accepts either world-meters (--north/--east, converted via Terrain) or
-- geographic (--lat/--lon) input — exactly one pair. Mirrors what the reporter
-- needed for flight-plan overlays without an external IGRF implementation
-- (GH#73, request 1).
function M.coords_magvar(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'coords_magvar requires args (table)' }
    end
    local has_ne = type(args.north) == 'number' and type(args.east) == 'number'
    local has_ll = type(args.lat) == 'number' and type(args.lon) == 'number'
    if has_ne == has_ll then
        return { ok = false,
                 error = 'coords_magvar requires exactly one of --north/--east or --lat/--lon' }
    end

    local ok_mv, mv = pcall(require, 'magvar')
    if not ok_mv or type(mv) ~= 'table' or type(mv.get_mag_decl) ~= 'function' then
        return { ok = false, error = 'magvar module unavailable' }
    end

    local lat, lon, north, east
    if has_ne then
        if not _theatre_loaded() then
            return { ok = false, error = 'theatre not loaded — open or create a mission first' }
        end
        north, east = args.north, args.east
        local ok, la, lo = pcall(Terrain.convertMetersToLatLon, north, east)
        if not ok or type(la) ~= 'number' or type(lo) ~= 'number' then
            return { ok = false, error = 'Terrain.convertMetersToLatLon failed: ' .. tostring(la) }
        end
        lat, lon = la, lo
    else
        lat, lon = args.lat, args.lon
    end

    local ok, decl = pcall(mv.get_mag_decl, lat, lon)
    if not ok or type(decl) ~= 'number' then
        return { ok = false, error = 'magvar.get_mag_decl failed: ' .. tostring(decl) }
    end

    local out = { ok = true, decl_deg = math.deg(decl), decl_rad = decl, lat = lat, lon = lon }
    if north then out.north = north; out.east = east end
    return out
end

return M
