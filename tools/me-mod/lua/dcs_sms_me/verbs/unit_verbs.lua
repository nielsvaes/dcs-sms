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

-- ============================================================
-- Per-pylon weapon SETTINGS (fuzes, presets, jammer modes, …)
-- ============================================================
--
-- DCS stores a freeform `settings` table per pylon entry alongside the
-- CLSID, e.g. for a WWII bomb:
--   pylons[1] = { CLSID = "{British_GP_500LB_Bomb_Mk4}", settings = {
--       NFP_fuze_type_nose = 1, NFP_fuze_type_tail = 1,
--       ["00_prfx_function_delay_ctrl_NP27MkII"] = 11,
--       ["01_prfx_function_delay_ctrl_TP30MkIII"] = 11,
--       NFP_PRESID = "WWII_B_B_GPMkIV", NFP_PRESVER = 2, ... } }
--
-- The legal keys/values are weapon-specific and descriptor-driven: the ME
-- exposes them via me_loadoututils.getLauncherSettings(clsid) (the schema:
-- id, label, control 'comboList'/'spinbox', combo `values`, min/max,
-- readOnly, VisibilityCondition) and getLauncherSettingsDefaultValues(clsid)
-- (a flat key→value map of defaults, including the NFP_PRESID / NFP_PRESVER
-- preset metadata DCS needs at load). We validate against that descriptor
-- rather than hardcoding any weapon's fields. gh #68 item 1.

-- _load_loadoututils — fetch me_loadoututils with the settings API present.
local function _load_loadoututils()
    local ok, LU = pcall(require, 'me_loadoututils')
    if not ok or type(LU) ~= 'table'
            or type(LU.getLauncherSettings) ~= 'function' then
        return nil, 'me_loadoututils.getLauncherSettings unavailable'
    end
    return LU, nil
end

-- _resolve_settings_clsid — determine which weapon's settings we're editing.
-- Prefers an explicit args.weapon (validated against the pylon's Launchers,
-- and written onto the pylon), else falls back to the weapon already on the
-- pylon. Returns (clsid, pylon_entry, weapon_changed, err).
local function _resolve_settings_clsid(unit, pylon_num, weapon_arg)
    unit.payload = unit.payload or {}
    unit.payload.pylons = unit.payload.pylons or {}
    local pylon = unit.payload.pylons[pylon_num]
    local prev_clsid = pylon and pylon.CLSID
    if type(weapon_arg) == 'string' and weapon_arg ~= '' then
        local pylon_def, perr = _find_pylon_def(unit.type, pylon_num)
        if not pylon_def then return nil, nil, false, perr end
        local clsid, werr = _resolve_weapon(pylon_def, weapon_arg)
        if not clsid then return nil, nil, false, werr end
        local changed = clsid ~= prev_clsid
        -- Drop stale settings when the weapon actually changes.
        pylon = { CLSID = clsid, settings = (not changed) and pylon and pylon.settings or nil }
        unit.payload.pylons[pylon_num] = pylon
        return clsid, pylon, changed, nil
    end
    if not (pylon and pylon.CLSID) then
        return nil, nil, false,
            'pylon ' .. pylon_num .. ' has no weapon; set one first with '
            .. '`me unit payload set` or pass --weapon'
    end
    return pylon.CLSID, pylon, false, nil
end

-- _resolve_setting_value — coerce a CLI string value against a descriptor
-- entry. comboList: match by value id (string-compared) or dispName
-- (case-insensitive), returning the canonical id (preserving its Lua type —
-- ids may be numbers like 11 or strings like "EMPTY_NOSE"). spinbox/other:
-- parse a number and range-check. Returns (value, nil) or (nil, errmsg).
local function _resolve_setting_value(entry, raw)
    local sval = tostring(raw)
    if entry.control == 'comboList' and type(entry.values) == 'table' then
        local lval = string.lower(sval)
        for _, v in ipairs(entry.values) do
            if tostring(v.id) == sval then return v.id end
            if type(v.dispName) == 'string' and string.lower(v.dispName) == lval then
                return v.id
            end
        end
        local opts = {}
        for _, v in ipairs(entry.values) do
            opts[#opts + 1] = tostring(v.id) .. ' (' .. tostring(v.dispName) .. ')'
        end
        return nil, "'" .. sval .. "' is not a legal value; options: "
                    .. table.concat(opts, ', ')
    end
    local n = tonumber(sval)
    if not n then return nil, "'" .. sval .. "' is not a number" end
    if type(entry.min) == 'number' and n < entry.min then
        return nil, n .. ' is below min ' .. entry.min
    end
    if type(entry.max) == 'number' and n > entry.max then
        return nil, n .. ' is above max ' .. entry.max
    end
    return n
end

-- unit_payload_list_settings — dump a weapon's configurable settings
-- descriptor (the discovery half, mirroring `trigger list-predicates`).
-- Resolves the weapon from args.weapon or the pylon's current loadout.
function M.unit_payload_list_settings(args)
    local ctx, err = _check_air_unit('unit_payload_list_settings', args)
    if not ctx then return { ok = false, error = err } end
    local has_weapon = type(args.weapon) == 'string' and args.weapon ~= ''
    if type(args.pylon) ~= 'number' or args.pylon < 1 then
        if not has_weapon then
            return { ok = false,
                     error = 'unit_payload_list_settings requires args.pylon (positive integer) or args.weapon' }
        end
    end
    local u = ctx.unit
    local clsid
    if args.pylon and args.pylon >= 1 then
        local c, _, _, rerr = _resolve_settings_clsid(u, args.pylon, args.weapon)
        if not c then return { ok = false, error = 'unit_payload_list_settings: ' .. rerr } end
        clsid = c
    else
        -- weapon-only discovery: dump the descriptor for the named weapon
        -- without requiring it to be mounted on any pylon.
        clsid = args.weapon
    end

    local LU, lerr = _load_loadoututils()
    if not LU then return { ok = false, error = lerr } end
    local descr = LU.getLauncherSettings(clsid)
    if type(descr) ~= 'table' then
        return { ok = false, error = 'no settings descriptor for ' .. tostring(clsid) }
    end
    local defs = (type(LU.getLauncherSettingsDefaultValues) == 'function')
                 and LU.getLauncherSettingsDefaultValues(clsid) or {}

    local settings = {}
    for _, s in ipairs(descr) do
        local values
        if type(s.values) == 'table' then
            values = {}
            for _, v in ipairs(s.values) do
                values[#values + 1] = { id = v.id, name = v.dispName }
            end
        end
        local visible_when
        if type(s.VisibilityCondition) == 'table' then
            visible_when = {}
            for _, c in ipairs(s.VisibilityCondition) do
                visible_when[#visible_when + 1] = { id = c.id, value = c.value }
            end
        end
        settings[#settings + 1] = {
            id = s.id, label = s.label, control = s.control,
            default = s.defValue, read_only = s.readOnly == true,
            min = s.min, max = s.max, step = s.step,
            dimension = s.dimension, values = values, visible_when = visible_when,
        }
    end

    return { ok = true, id = u.unitId, name = u.name,
             pylon = args.pylon, clsid = clsid,
             preset = { id = defs and defs.NFP_PRESID, version = defs and defs.NFP_PRESVER },
             settings = settings, count = #settings }
end

-- unit_payload_set_fuze — set per-pylon weapon settings (fuzes, function
-- delays, presets, …) on a plane/helicopter pylon. Each args.sets entry is
-- a { key, value } pair where key matches a descriptor `id` OR `label`
-- (case-insensitive) and value matches a combo id/dispName or a numeric
-- spinbox value. Starts from the weapon's default settings (so the preset
-- metadata + sibling keys are always present), overlays any existing pylon
-- settings, then applies the user's overrides. Writes the result to
-- pylon.settings. gh #68 item 1.
function M.unit_payload_set_fuze(args)
    local ctx, err = _check_air_unit('unit_payload_set_fuze', args)
    if not ctx then return { ok = false, error = err } end
    if type(args.pylon) ~= 'number' or args.pylon < 1 then
        return { ok = false, error = 'unit_payload_set_fuze requires args.pylon (positive integer)' }
    end
    local sets = args.sets
    if type(sets) ~= 'table' or #sets == 0 then
        return { ok = false, error = 'unit_payload_set_fuze requires at least one --set <key>=<value>' }
    end
    local u = ctx.unit
    local clsid, pylon, _, rerr = _resolve_settings_clsid(u, args.pylon, args.weapon)
    if not clsid then return { ok = false, error = 'unit_payload_set_fuze: ' .. rerr } end

    local LU, lerr = _load_loadoututils()
    if not LU then return { ok = false, error = lerr } end
    local descr = LU.getLauncherSettings(clsid)
    if type(descr) ~= 'table' or #descr == 0 then
        return { ok = false, error = 'weapon ' .. clsid .. ' has no configurable settings' }
    end
    local defs = (type(LU.getLauncherSettingsDefaultValues) == 'function')
                 and LU.getLauncherSettingsDefaultValues(clsid) or {}

    -- Index the descriptor by id and by lowercased label (labels collide —
    -- e.g. "Function Delay" exists for both nose and tail wells — so a label
    -- match is only accepted when unambiguous; otherwise the caller must use
    -- the exact id, which list-settings surfaces).
    local by_id, by_label = {}, {}
    for _, s in ipairs(descr) do
        by_id[s.id] = s
        if type(s.label) == 'string' then
            local lk = string.lower(s.label)
            by_label[lk] = by_label[lk] or {}
            table.insert(by_label[lk], s)
        end
    end

    -- Build the settings table: defaults → existing pylon settings → overrides.
    local settings = {}
    for k, v in pairs(defs or {}) do settings[k] = v end
    if type(pylon.settings) == 'table' then
        for k, v in pairs(pylon.settings) do settings[k] = v end
    end

    local applied = {}
    for _, kv in ipairs(sets) do
        local key = kv.key
        if type(key) ~= 'string' or key == '' then
            return { ok = false, error = 'unit_payload_set_fuze: each --set needs a non-empty key' }
        end
        local entry = by_id[key]
        if not entry then
            local cands = by_label[string.lower(key)]
            if cands and #cands == 1 then
                entry = cands[1]
            elseif cands and #cands > 1 then
                local ids = {}
                for _, c in ipairs(cands) do ids[#ids + 1] = c.id end
                return { ok = false, error = "setting '" .. key .. "' is ambiguous (matches "
                        .. #cands .. " fields by label: " .. table.concat(ids, ', ')
                        .. "); use the exact id" }
            else
                return { ok = false, error = "unknown setting '" .. key .. "' for " .. clsid
                        .. " — see `me unit payload list-settings`" }
            end
        end
        if entry.readOnly == true then
            return { ok = false, error = "setting '" .. entry.id .. "' ("
                    .. tostring(entry.label) .. ") is read-only/computed and cannot be set" }
        end
        local resolved, verr = _resolve_setting_value(entry, kv.value)
        if verr ~= nil and resolved == nil then
            return { ok = false, error = "setting '" .. entry.id .. "': " .. verr }
        end
        settings[entry.id] = resolved
        applied[#applied + 1] = { id = entry.id, label = entry.label, value = resolved }
    end

    pylon.settings = settings

    -- Refresh the payload panel if it's showing this unit (cosmetic).
    pcall(function()
        local pp = require('me_payload')
        if type(pp.update) == 'function' then pp.update() end
    end)

    return { ok = true, id = u.unitId, name = u.name,
             pylon = args.pylon, clsid = clsid, applied = applied,
             preset = { id = settings.NFP_PRESID, version = settings.NFP_PRESVER } }
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
