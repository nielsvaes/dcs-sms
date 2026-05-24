-- dcs_sms_me/verbs/unit_verbs.lua — per-field unit setters, payload, list/get.
--
-- Verbs: unit_set_<name|skill|livery|pos|heading|alt|onboard_num|callsign|
-- loadout|chaff|flare|fuel|gun>, unit_payload_<set|clear>, unit_list, unit_get.
-- See dcs_sms_me/verbs.lua for the aggregator and the verb-naming convention.
--
-- NOTE: unit_set_parking lives in route_verbs.lua, not here. It depends on
-- route-block helpers (AIRFIELD_TYPES, ensure_map_objects, refresh_route_panel)
-- plus the airbase locator — co-located with the verbs whose helpers it needs.

local M = {}

local H = require('dcs_sms_me.verb_helpers')
local walk_groups          = H.walk_groups
local strip_back_refs      = H.strip_back_refs
local refresh_group_view   = H.refresh_group_view
local find_unit_in_mission = H.find_unit_in_mission
local compute_lat_lon      = H.compute_lat_lon

-- ============================================================
-- Unit setters (per-field)
-- ============================================================

-- unit_set_name — rename via Mission.renameUnit. Refuses on collision.
function M.unit_set_name(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'unit_set_name requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'unit_set_name requires exactly one of args.name or args.id' }
    end
    if type(args.new_name) ~= 'string' or args.new_name == '' then
        return { ok = false, error = 'unit_set_name requires args.new_name (non-empty string)' }
    end
    local u = find_unit_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not u then
        return { ok = false, error = 'unit not found' }
    end
    local Mission = require('me_mission')
    local ok = Mission.renameUnit(u, args.new_name)
    if not ok then
        return { ok = false, error = 'name "' .. args.new_name .. '" already in use' }
    end
    return { ok = true, id = u.unitId, name = args.new_name }
end

-- unit_set_skill — set u.skill (Average / Good / High / Excellent / Random / Player / Client).
function M.unit_set_skill(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'unit_set_skill requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'unit_set_skill requires exactly one of args.name or args.id' }
    end
    if type(args.skill) ~= 'string' or args.skill == '' then
        return { ok = false, error = 'unit_set_skill requires args.skill (non-empty string)' }
    end
    local u = find_unit_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not u then
        return { ok = false, error = 'unit not found' }
    end
    u.skill = args.skill
    return { ok = true, id = u.unitId, name = u.name, skill = u.skill }
end

-- unit_set_livery — set u.livery_id (string, airframe-specific).
function M.unit_set_livery(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'unit_set_livery requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'unit_set_livery requires exactly one of args.name or args.id' }
    end
    if type(args.livery) ~= 'string' then
        return { ok = false, error = 'unit_set_livery requires args.livery (string; "" for default)' }
    end
    local u = find_unit_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not u then
        return { ok = false, error = 'unit not found' }
    end
    u.livery_id = args.livery
    return { ok = true, id = u.unitId, name = u.name, livery = u.livery_id }
end

-- unit_set_pos — move a single unit to (north, east). Refreshes the group's
-- map objects so the ME view updates immediately.
--
-- AIR-GROUP CAVEAT: for plane / helicopter units this only affects the
-- ME view and the saved .miz — at mission load DCS overrides every
-- wingman's position from the group's formation_template, so the new
-- (x, y) doesn't survive into runtime. Ground / ship / static units
-- honour the position verbatim.
function M.unit_set_pos(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'unit_set_pos requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'unit_set_pos requires exactly one of args.name or args.id' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'unit_set_pos requires args.north and args.east (numbers, meters)' }
    end
    local u, g = find_unit_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not u then
        return { ok = false, error = 'unit not found' }
    end
    -- mission-table fields: x = north, y = east
    u.x = args.north
    u.y = args.east
    refresh_group_view(g)
    return { ok = true, id = u.unitId, name = u.name, north = u.x, east = u.y }
end

-- unit_set_heading — set u.heading and u.psi from a degrees input.
-- DCS stores radians internally, with 0 = north and clockwise = positive.
function M.unit_set_heading(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'unit_set_heading requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'unit_set_heading requires exactly one of args.name or args.id' }
    end
    if type(args.heading_deg) ~= 'number' then
        return { ok = false, error = 'unit_set_heading requires args.heading_deg (degrees)' }
    end
    local u, g = find_unit_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not u then
        return { ok = false, error = 'unit not found' }
    end
    local rad = math.rad(args.heading_deg)
    u.heading = rad
    u.psi = rad
    refresh_group_view(g)
    return { ok = true, id = u.unitId, name = u.name,
             heading_deg = args.heading_deg, heading_rad = rad }
end

-- unit_set_alt — set u.alt and u.alt_type. Doesn't touch waypoint altitudes.
function M.unit_set_alt(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'unit_set_alt requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'unit_set_alt requires exactly one of args.name or args.id' }
    end
    if type(args.alt) ~= 'number' then
        return { ok = false, error = 'unit_set_alt requires args.alt (number, meters)' }
    end
    local alt_type = args.alt_type or 'BARO'
    if alt_type ~= 'BARO' and alt_type ~= 'RADIO' then
        return { ok = false, error = 'unit_set_alt: args.alt_type must be "BARO" or "RADIO"' }
    end
    local u = find_unit_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not u then
        return { ok = false, error = 'unit not found' }
    end
    u.alt = args.alt
    u.alt_type = alt_type
    return { ok = true, id = u.unitId, name = u.name, alt = u.alt, alt_type = u.alt_type }
end

-- unit_set_onboard_num — set u.onboard_num.
function M.unit_set_onboard_num(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'unit_set_onboard_num requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'unit_set_onboard_num requires exactly one of args.name or args.id' }
    end
    if type(args.onboard_num) ~= 'string' or args.onboard_num == '' then
        return { ok = false, error = 'unit_set_onboard_num requires args.onboard_num (non-empty string)' }
    end
    local u = find_unit_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not u then
        return { ok = false, error = 'unit not found' }
    end
    u.onboard_num = args.onboard_num
    return { ok = true, id = u.unitId, name = u.name, onboard_num = u.onboard_num }
end

-- unit_set_callsign — set u.callsign. Mandatory args.callsign (string, the
-- radio label); optional args.squadron / flight / plane integers — when 0
-- (default), preserve the existing numeric prefix value.
function M.unit_set_callsign(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'unit_set_callsign requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'unit_set_callsign requires exactly one of args.name or args.id' }
    end
    if type(args.callsign) ~= 'string' or args.callsign == '' then
        return { ok = false, error = 'unit_set_callsign requires args.callsign (non-empty string)' }
    end
    local u = find_unit_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not u then
        return { ok = false, error = 'unit not found' }
    end
    -- Preserve existing numeric prefix by default (CLI passes 0 to mean "no change").
    local existing = (type(u.callsign) == 'table') and u.callsign or {}
    local sq = (type(args.squadron) == 'number' and args.squadron > 0) and args.squadron
               or (type(existing[1]) == 'number' and existing[1]) or 1
    local fl = (type(args.flight) == 'number' and args.flight > 0) and args.flight
               or (type(existing[2]) == 'number' and existing[2]) or 1
    local pl = (type(args.plane) == 'number' and args.plane > 0) and args.plane
               or (type(existing[3]) == 'number' and existing[3]) or 1
    u.callsign = { sq, fl, pl, name = args.callsign }
    return { ok = true, id = u.unitId, name = u.name,
             callsign = { sq, fl, pl, name = args.callsign } }
end

-- ============================================================
-- Unit payload verbs (plane / helicopter only)
-- ============================================================
--
-- Payload data shape on a plane/heli unit:
--   u.payload = {
--     name   = "CAP",                       -- named loadout selector
--     pylons = {                            -- pylonNumber → weapon entry
--       [1] = { CLSID = "{...GUID...}", settings = { ... } | nil },
--       [3] = { CLSID = "ALQ_184",          settings = nil },
--       ...                                 -- non-contiguous
--     },
--     fuel  = 2500,    -- kg
--     chaff = 150,     -- count
--     flare = 120,     -- count
--     gun   = 100,     -- ammo % (0-100)
--   }
--
-- CLSID format is mixed: GUIDs ("{B6...}") and human-readable codes
-- ("ALQ_184", "{Mk82AIR}"). The pylon-specific weapon list lives at
-- DB.unit_by_type[u.type].Pylons[i].Launchers and is the source of truth
-- for what's valid where.

-- _resolve_weapon — accept either a CLSID or a display name, return the
-- CLSID. Looks up against the pylon's Launchers list. Returns nil + error
-- if no match.
local function _resolve_weapon(pylon_def, weapon_arg)
    if type(weapon_arg) ~= 'string' or weapon_arg == '' then
        return nil, 'weapon must be a non-empty string'
    end
    if type(pylon_def) ~= 'table' or type(pylon_def.Launchers) ~= 'table' then
        return nil, 'pylon has no Launchers list'
    end
    -- 1) exact CLSID match (skip obsolete launchers).
    for _, lnch in pairs(pylon_def.Launchers) do
        if type(lnch) == 'table' and lnch.CLSID == weapon_arg and not lnch.obsolete then
            return weapon_arg, nil
        end
    end
    -- 2) display-name match. base.get_weapon_display_name_by_clsid is the
    --    same lookup the ME panel uses; available globally in ME context.
    if type(get_weapon_display_name_by_clsid) == 'function' then
        local target = string.lower(weapon_arg)
        for _, lnch in pairs(pylon_def.Launchers) do
            if type(lnch) == 'table' and lnch.CLSID and not lnch.obsolete then
                local dn = get_weapon_display_name_by_clsid(lnch.CLSID)
                if type(dn) == 'string' and string.lower(dn) == target then
                    return lnch.CLSID, nil
                end
            end
        end
    end
    return nil, 'weapon "' .. weapon_arg .. '" not valid for this pylon'
end

-- _find_pylon_def — locate the pylon definition table for a given airframe
-- type and pylon number. Returns the pylon-def table or nil + error.
local function _find_pylon_def(unit_type, pylon_number)
    local ok_db, DB = pcall(require, 'me_db_api')
    if not ok_db or type(DB) ~= 'table' or type(DB.unit_by_type) ~= 'table' then
        return nil, 'me_db_api.unit_by_type unavailable'
    end
    local def = DB.unit_by_type[unit_type]
    if type(def) ~= 'table' or type(def.Pylons) ~= 'table' then
        return nil, 'unit type "' .. tostring(unit_type) .. '" has no Pylons'
    end
    for _, p in pairs(def.Pylons) do
        if type(p) == 'table' and p.Number == pylon_number then
            return p, nil
        end
    end
    return nil, 'pylon ' .. tostring(pylon_number) .. ' not valid for ' .. tostring(unit_type)
end

-- _check_air_unit — shared up-front guard. Resolves the unit and refuses
-- on non-air categories (only planes/helicopters carry payloads).
local function _check_air_unit(verb, args)
    if type(args) ~= 'table' then
        return nil, verb .. ' requires args (table)'
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return nil, verb .. ' requires exactly one of args.name or args.id'
    end
    local u, g, _, _, cat = find_unit_in_mission(
        has_name and args.name or nil, has_id and args.id or nil)
    if not u then
        return nil, 'unit not found'
    end
    if cat ~= 'plane' and cat ~= 'helicopter' then
        return nil, verb .. ' only applies to plane / helicopter units (got ' .. tostring(cat) .. ')'
    end
    return { unit = u, group = g, cat = cat }, nil
end

-- unit_set_loadout — apply a named loadout (e.g. "CAP", "CAS", "Empty").
-- Looks up the loadout via me_loadoututils.getUnitPylons, replaces
-- u.payload.pylons with its contents, and sets u.payload.name. Other
-- payload fields (chaff, flare, fuel, gun) are preserved.
function M.unit_set_loadout(args)
    local ctx, err = _check_air_unit('unit_set_loadout', args)
    if not ctx then return { ok = false, error = err } end
    if type(args.loadout) ~= 'string' or args.loadout == '' then
        return { ok = false, error = 'unit_set_loadout requires args.loadout (string)' }
    end
    local ok_lu, loadoutUtils = pcall(require, 'me_loadoututils')
    if not ok_lu or type(loadoutUtils) ~= 'table'
            or type(loadoutUtils.getUnitPylons) ~= 'function' then
        return { ok = false, error = 'me_loadoututils.getUnitPylons unavailable' }
    end
    local pylons = loadoutUtils.getUnitPylons(ctx.unit.type, args.loadout)
    if type(pylons) ~= 'table' then
        return { ok = false,
                 error = 'unit_set_loadout: loadout "' .. args.loadout
                         .. '" not found for ' .. ctx.unit.type }
    end
    local u = ctx.unit
    u.payload = u.payload or {}
    u.payload.name = args.loadout
    u.payload.pylons = {}
    local pylon_count = 0
    for pylonNumber, v in pairs(pylons) do
        if type(v) == 'table' and v.CLSID then
            u.payload.pylons[pylonNumber] = { CLSID = v.CLSID, settings = v.settings }
            pylon_count = pylon_count + 1
        end
    end
    return { ok = true, id = u.unitId, name = u.name,
             loadout = args.loadout, pylon_count = pylon_count }
end

-- unit_payload_set — set a single pylon's weapon by CLSID or display name.
-- Validates the pylon number against the airframe's Pylons table and the
-- weapon against that pylon's Launchers list. Refuses obsolete launchers.
function M.unit_payload_set(args)
    local ctx, err = _check_air_unit('unit_payload_set', args)
    if not ctx then return { ok = false, error = err } end
    if type(args.pylon) ~= 'number' or args.pylon < 1 then
        return { ok = false, error = 'unit_payload_set requires args.pylon (positive integer)' }
    end
    if type(args.weapon) ~= 'string' or args.weapon == '' then
        return { ok = false, error = 'unit_payload_set requires args.weapon (CLSID or display name)' }
    end
    local pylon_def, perr = _find_pylon_def(ctx.unit.type, args.pylon)
    if not pylon_def then
        return { ok = false, error = 'unit_payload_set: ' .. perr }
    end
    local clsid, werr = _resolve_weapon(pylon_def, args.weapon)
    if not clsid then
        return { ok = false, error = 'unit_payload_set: ' .. werr }
    end
    local u = ctx.unit
    u.payload = u.payload or {}
    u.payload.pylons = u.payload.pylons or {}
    u.payload.pylons[args.pylon] = { CLSID = clsid, settings = nil }
    return { ok = true, id = u.unitId, name = u.name,
             pylon = args.pylon, clsid = clsid }
end

-- unit_payload_clear — remove a single pylon's weapon entry.
function M.unit_payload_clear(args)
    local ctx, err = _check_air_unit('unit_payload_clear', args)
    if not ctx then return { ok = false, error = err } end
    if type(args.pylon) ~= 'number' or args.pylon < 1 then
        return { ok = false, error = 'unit_payload_clear requires args.pylon (positive integer)' }
    end
    -- Pylon-existence check (ergonomic — refuse on a pylon that's not a
    -- valid hardpoint for the airframe even though clearing nothing is
    -- a no-op data-wise).
    local _, perr = _find_pylon_def(ctx.unit.type, args.pylon)
    if perr then
        return { ok = false, error = 'unit_payload_clear: ' .. perr }
    end
    local u = ctx.unit
    local had_weapon = u.payload and u.payload.pylons and u.payload.pylons[args.pylon]
    u.payload = u.payload or {}
    u.payload.pylons = u.payload.pylons or {}
    u.payload.pylons[args.pylon] = nil
    return { ok = true, id = u.unitId, name = u.name,
             pylon = args.pylon, had_weapon = had_weapon ~= nil }
end

-- unit_set_chaff — set u.payload.chaff (count).
function M.unit_set_chaff(args)
    local ctx, err = _check_air_unit('unit_set_chaff', args)
    if not ctx then return { ok = false, error = err } end
    if type(args.count) ~= 'number' or args.count < 0 then
        return { ok = false, error = 'unit_set_chaff requires args.count (non-negative number)' }
    end
    local u = ctx.unit
    u.payload = u.payload or {}
    u.payload.chaff = args.count
    return { ok = true, id = u.unitId, name = u.name, chaff = u.payload.chaff }
end

-- unit_set_flare — set u.payload.flare (count).
function M.unit_set_flare(args)
    local ctx, err = _check_air_unit('unit_set_flare', args)
    if not ctx then return { ok = false, error = err } end
    if type(args.count) ~= 'number' or args.count < 0 then
        return { ok = false, error = 'unit_set_flare requires args.count (non-negative number)' }
    end
    local u = ctx.unit
    u.payload = u.payload or {}
    u.payload.flare = args.count
    return { ok = true, id = u.unitId, name = u.name, flare = u.payload.flare }
end

-- unit_set_fuel — set u.payload.fuel (kg). No max validation (the panel
-- clamps to airframe max; we let the user pass any non-negative number).
function M.unit_set_fuel(args)
    local ctx, err = _check_air_unit('unit_set_fuel', args)
    if not ctx then return { ok = false, error = err } end
    if type(args.fuel) ~= 'number' or args.fuel < 0 then
        return { ok = false, error = 'unit_set_fuel requires args.fuel (non-negative kg)' }
    end
    local u = ctx.unit
    u.payload = u.payload or {}
    u.payload.fuel = args.fuel
    return { ok = true, id = u.unitId, name = u.name, fuel = u.payload.fuel }
end

-- unit_set_gun — set u.payload.gun (ammo percent, 0-100).
function M.unit_set_gun(args)
    local ctx, err = _check_air_unit('unit_set_gun', args)
    if not ctx then return { ok = false, error = err } end
    if type(args.percent) ~= 'number' or args.percent < 0 or args.percent > 100 then
        return { ok = false, error = 'unit_set_gun requires args.percent (0-100)' }
    end
    local u = ctx.unit
    u.payload = u.payload or {}
    u.payload.gun = args.percent
    return { ok = true, id = u.unitId, name = u.name, gun = u.payload.gun }
end

-- ============================================================
-- Unit list / get
-- ============================================================

-- unit_list — return concise per-unit summaries from all groups, with filters.
--
-- args (all optional):
--   country, category, side — same as group_list
--   group:  group name (exact match)
--   name:   unit-name substring (case-insensitive)
--   type:   unit type (e.g. "F-16C_50") exact match
--
-- Returns { ok = true, units = [ ... ], count = N }.
function M.unit_list(args)
    args = args or {}
    local f_side = args.side and string.lower(args.side) or nil
    local f_country = args.country and string.lower(args.country) or nil
    local f_category = args.category and string.lower(args.category) or nil
    local f_group = args.group or nil
    local f_name = args.name and string.lower(args.name) or nil
    -- f_type accepts a single string (exact match) or a list of strings
    -- (any-of). The CLI passes a list when --type has commas. Internally
    -- we always normalize to a set for O(1) lookup.
    local f_type_set
    if type(args.type) == 'string' and args.type ~= '' then
        f_type_set = { [args.type] = true }
    elseif type(args.type) == 'table' then
        f_type_set = {}
        for _, t in ipairs(args.type) do
            if type(t) == 'string' and t ~= '' then f_type_set[t] = true end
        end
        if next(f_type_set) == nil then f_type_set = nil end
    end

    local out = {}
    walk_groups(function(g, country, side_name, cat)
        if f_side and string.lower(side_name) ~= f_side then return end
        if f_country and string.lower(country.name or '') ~= f_country then return end
        if f_category and cat ~= f_category then return end
        if f_group and g.name ~= f_group then return end
        for _, u in ipairs(g.units or {}) do
            if not (f_name and not string.find(string.lower(u.name or ''), f_name, 1, true)) then
                if not (f_type_set and not f_type_set[u.type]) then
                    local lat, lon = compute_lat_lon(u.x, u.y)
                    table.insert(out, {
                        id = u.unitId,
                        name = u.name,
                        type = u.type,
                        group_name = g.name,
                        group_id = g.groupId,
                        category = cat,
                        country = country.name,
                        side = side_name,
                        north = u.x,
                        east = u.y,
                        lat = lat,
                        lon = lon,
                        alt = u.alt,
                        heading = u.heading,
                        skill = u.skill,
                    })
                end
            end
        end
    end)
    return { ok = true, units = out, count = #out }
end

-- unit_get — full raw unit table (back-refs stripped). Selectable by unit
-- (name|id) or by parent group (group_name|group_id), in which case the
-- first unit of the group is returned. The group selectors exist so callers
-- working from `group list` (group id known, unit ids not yet) can skip the
-- `unit list --group` round trip. See GH#66 (request 5).
function M.unit_get(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'unit_get requires args (table)' }
    end
    local has_name       = type(args.name) == 'string'       and args.name ~= ''
    local has_id         = type(args.id) == 'number'
    local has_group_name = type(args.group_name) == 'string' and args.group_name ~= ''
    local has_group_id   = type(args.group_id) == 'number'

    local selector_count = (has_name and 1 or 0)
                         + (has_id and 1 or 0)
                         + (has_group_name and 1 or 0)
                         + (has_group_id and 1 or 0)
    if selector_count ~= 1 then
        return { ok = false, error = 'unit_get requires exactly one of args.name, args.id, args.group_name, or args.group_id' }
    end

    local found_unit, found_group, found_country, found_side, found_cat
    walk_groups(function(g, country, side_name, cat)
        if (has_group_name and g.name == args.group_name)
                or (has_group_id and g.groupId == args.group_id) then
            found_group, found_country = g, country
            found_side, found_cat = side_name, cat
            found_unit = g.units and g.units[1]
            return false
        end
        for _, u in ipairs(g.units or {}) do
            if (has_name and u.name == args.name)
                    or (has_id and u.unitId == args.id) then
                found_unit, found_group, found_country = u, g, country
                found_side, found_cat = side_name, cat
                return false
            end
        end
    end)

    if (has_group_name or has_group_id) and not found_group then
        return { ok = false, error = 'group not found' }
    end
    if (has_group_name or has_group_id) and not found_unit then
        return { ok = false, error = 'group has no units' }
    end
    if not found_unit then
        return { ok = false, error = 'unit not found' }
    end
    local snapshot = strip_back_refs(found_unit)
    snapshot._group_name = found_group.name
    snapshot._group_id = found_group.groupId
    snapshot._country = found_country.name
    snapshot._side = found_side
    snapshot._category = found_cat
    -- Mission-table position is in x/y (x=north, y=east) per ME convention.
    -- Inject computed lat/lon alongside so callers don't need a follow-up
    -- `me coords to-geo` round-trip. See GH#66 (request 4).
    local lat, lon = compute_lat_lon(found_unit.x, found_unit.y)
    if lat and lon then
        snapshot.lat = lat
        snapshot.lon = lon
    end
    return { ok = true, unit = snapshot }
end

return M
