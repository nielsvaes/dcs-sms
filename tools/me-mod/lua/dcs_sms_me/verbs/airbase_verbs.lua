-- dcs_sms_me/verbs/airbase_verbs.lua — read-only airbase queries + coalition flip.
--
-- Verbs: airbase_list, airbase_get, airbase_set_coalition.
-- See dcs_sms_me/verbs.lua for the aggregator and the verb-naming convention.

local M = {}

local H = require('dcs_sms_me.verb_helpers')
local find_airbase_by_name = H.find_airbase_by_name

-- =============================================================================
-- Airbases
--
-- Three verbs:
--   * airbase_list — lightweight summary, one row per airdrome (no parking).
--   * airbase_get  — deep info for one airdrome, including parking stands and
--                    runways. Used by agents to plan spawns / answer "what
--                    stands does Hama have for an F-16?".
--   * airbase_set_coalition — flip an airbase's coalition via warehouse_ops.
--
-- Read paths are theatre-level, no mission needs to be open; the coalition
-- write path needs a loaded mission for its warehouse entry.

local function _airbase_freqs(ad)
    local out = {}
    local fl = ad.getFrequencyList and ad:getFrequencyList()
    if type(fl) ~= 'table' then return out end
    for _, f in ipairs(fl) do
        local hz = f and f[1]
        if type(hz) == 'number' and hz > 0 then
            out[#out + 1] = { hz = hz, mhz = hz / 1e6 }
        end
    end
    return out
end

local function _airbase_stands(ad, filter)
    local out = {}
    if not ad.getRoadnet then return out end
    local rn_ok, rn = pcall(function() return ad:getRoadnet() end)
    if not rn_ok or not rn then return out end
    local mp_ok, mp = pcall(require, 'me_parking')
    if not mp_ok or not mp or type(mp.getStandList) ~= 'function' then return out end
    local sl_ok, stands = pcall(mp.getStandList, rn)
    if not sl_ok or type(stands) ~= 'table' then return out end
    for _, s in pairs(stands) do
        local p = s.params or {}
        local for_planes = (tonumber(p.FOR_AIRPLANES) or 0) ~= 0
        local for_helicopters = (tonumber(p.FOR_HELICOPTERS) or 0) ~= 0
        local include = true
        if filter == 'plane' then include = for_planes
        elseif filter == 'helicopter' then include = for_helicopters end
        if include then
            local lat, lon
            if type(s.x) == 'number' and type(s.y) == 'number' then
                lat, lon = Terrain.convertMetersToLatLon(s.x, s.y)
            end
            out[#out + 1] = {
                name             = s.name,
                crossroad_index  = s.crossroad_index,
                x                = s.x, y = s.y,
                lat              = lat, lon = lon,
                for_planes       = for_planes,
                for_helicopters  = for_helicopters,
                shelter          = (tonumber(p.SHELTER) or 0) ~= 0,
                width_m          = tonumber(p.WIDTH),
                length_m         = tonumber(p.LENGTH),
                height_m         = tonumber(p.HEIGHT),
            }
        end
    end
    table.sort(out, function(a, b)
        return (a.name or '') < (b.name or '')
    end)
    return out
end

local function _airbase_runways(ad)
    local out = {}
    if not ad.getRoadnet or type(Terrain.getRunwayList) ~= 'function' then return out end
    local rn_ok, rn = pcall(function() return ad:getRoadnet() end)
    if not rn_ok or not rn then return out end
    local rl_ok, rwys = pcall(Terrain.getRunwayList, rn)
    if not rl_ok or type(rwys) ~= 'table' then return out end
    for _, r in ipairs(rwys) do
        local course_rad = tonumber(r.course)
        out[#out + 1] = {
            course_rad = course_rad,
            course_deg = course_rad and (course_rad * 180 / math.pi) or nil,
            edge1 = { name = r.edge1name, x = r.edge1x, y = r.edge1y },
            edge2 = { name = r.edge2name, x = r.edge2x, y = r.edge2y },
        }
    end
    return out
end

function M.airbase_list(args)
    args = args or {}
    if not _G.Terrain then
        return { ok = false, error = "Terrain module not available" }
    end
    local AC_ok, AC = pcall(require, 'Mission.AirdromeController')
    if not AC_ok or not AC or type(AC.getAirdromes) ~= 'function' then
        return { ok = false, error = "Mission.AirdromeController not available" }
    end
    local got_ok, airdromes = pcall(AC.getAirdromes)
    if not got_ok or not airdromes then
        return { ok = false, error = "getAirdromes() failed" }
    end
    local filter = args.coalition
    if filter == 'all' or filter == '' then filter = nil end

    local rows = {}
    for _, ad in ipairs(airdromes) do
        if ad.getName then
            local coal = ad.getCoalitionName and ad:getCoalitionName() or nil
            if filter == nil or coal == filter then
                local x, y = ad.x, ad.y
                local lat, lon
                if type(x) == 'number' and type(y) == 'number' then
                    lat, lon = Terrain.convertMetersToLatLon(x, y)
                end
                rows[#rows + 1] = {
                    name             = ad:getName(),
                    airdrome_number  = ad.getAirdromeNumber and ad:getAirdromeNumber() or nil,
                    coalition        = coal,
                    x = x, y = y,
                    lat = lat, lon = lon,
                }
            end
        end
    end
    table.sort(rows, function(a, b) return (a.name or '') < (b.name or '') end)
    return { ok = true, count = #rows, airbases = rows }
end

-- ED's coalition strings are lowercase, with "neutrals" plural:
--   CoalitionController.blueCoalitionName()    -> "blue"
--   CoalitionController.redCoalitionName()     -> "red"
--   CoalitionController.neutralCoalitionName() -> "neutrals"
-- We normalise user input ("red"/"blue"/"neutral"/"neutrals") to that form.
local function _coalition_canonical(input)
    if type(input) ~= 'string' then return nil end
    local s = input:lower()
    if s == 'red' then return 'red' end
    if s == 'blue' then return 'blue' end
    if s == 'neutral' or s == 'neutrals' then return 'neutrals' end
    return nil
end

function M.airbase_set_coalition(args)
    args = args or {}
    if type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = "--name is required" }
    end
    local coal = _coalition_canonical(args.coalition)
    if not coal then
        return { ok = false, error = "--coalition must be red, blue, or neutral" }
    end
    local ad = find_airbase_by_name(args.name)
    if not ad then
        return { ok = false, error = string.format("no airbase matching %q", args.name) }
    end
    local airdrome_number = ad.getAirdromeNumber and ad:getAirdromeNumber() or nil
    if not airdrome_number then
        return { ok = false, error = "airbase has no airdrome_number — cannot set coalition" }
    end

    local wo = require('dcs_sms_me.warehouse_ops')
    local entry = wo.extract(airdrome_number)
    if not entry then
        return { ok = false, error = "no warehouse entry for airdrome " .. airdrome_number .. " (mission may not be loaded)" }
    end
    entry.coalition = coal
    local ok, err = wo.apply(airdrome_number, entry)
    if not ok then
        return { ok = false, error = err or "warehouse_ops.apply failed" }
    end

    return {
        ok = true,
        name = ad:getName(),
        airdrome_number = airdrome_number,
        coalition = coal,
    }
end

function M.airbase_get(args)
    args = args or {}
    if type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = "--name is required" }
    end
    if not _G.Terrain then
        return { ok = false, error = "Terrain module not available" }
    end
    local ad = find_airbase_by_name(args.name)
    if not ad then
        return { ok = false, error = string.format("no airbase matching %q", args.name) }
    end

    local x, y = ad.x, ad.y
    local lat, lon
    if type(x) == 'number' and type(y) == 'number' then
        lat, lon = Terrain.convertMetersToLatLon(x, y)
    end

    local result = {
        ok               = true,
        name             = ad:getName(),
        airdrome_number  = ad.getAirdromeNumber and ad:getAirdromeNumber() or nil,
        coalition        = ad.getCoalitionName and ad:getCoalitionName() or nil,
        x = x, y = y,
        lat = lat, lon = lon,
        height_m         = ad.getHeight and ad:getHeight() or nil,
        heading_deg      = ad.getAngle and ad:getAngle() or nil,
        frequencies      = _airbase_freqs(ad),
        stands           = _airbase_stands(ad, args.filter),
        runways          = _airbase_runways(ad),
    }
    local wh_ok, wh = pcall(function() return ad.getWarehouses and ad:getWarehouses() end)
    local fd_ok, fd = pcall(function() return ad.getFueldepots and ad:getFueldepots() end)
    if wh_ok and type(wh) == 'table' then result.warehouses_count = #wh end
    if fd_ok and type(fd) == 'table' then result.fueldepots_count = #fd end
    return result
end

return M
