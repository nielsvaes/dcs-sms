-- dcs_sms_me/verbs/resources_verbs.lua — airbase/unit warehouse resource verbs.
--
-- Verbs: resources_get, resources_set.
-- See dcs_sms_me/verbs.lua for the aggregator and the verb-naming convention.

local M = {}

local H = require('dcs_sms_me.verb_helpers')
local find_airbase_by_name = H.find_airbase_by_name

-- Resources verbs route through dcs_sms_me.warehouse_ops and the shared
-- airbase resolver in verb_helpers.lua for the --airbase target.

local function _resolve_unit_id(name_or_id)
    if type(name_or_id) == 'number' then return name_or_id end
    if type(name_or_id) ~= 'string' or name_or_id == '' then return nil end
    -- Try numeric string first
    local n = tonumber(name_or_id)
    if n then return n end
    local mm = require('me_mission')
    if not mm or not mm.unit_by_name then return nil end
    local u = mm.unit_by_name[name_or_id]
    if u and type(u.unitId) == 'number' then return u.unitId end
    return nil
end

function M.resources_get(args)
    args = args or {}
    local has_airbase = type(args.airbase) == 'string' and args.airbase ~= ''
    local has_unit = args.unit ~= nil and args.unit ~= ''
    if has_airbase == has_unit then
        return { ok = false, error = "exactly one of --airbase or --unit is required" }
    end

    local mm = require('me_mission')
    if not mm or not mm.mission or not mm.mission.AirportsEquipment then
        return { ok = false, error = "mission not loaded — open one in the Mission Editor first" }
    end

    if has_airbase then
        local ad = find_airbase_by_name(args.airbase)
        if not ad then
            return { ok = false, error = string.format("no airbase matching %q", args.airbase) }
        end
        local airdrome_number = ad.getAirdromeNumber and ad:getAirdromeNumber() or nil
        if not airdrome_number then
            return { ok = false, error = "airbase has no airdrome_number" }
        end
        local wo = require('dcs_sms_me.warehouse_ops')
        local entry = wo.extract(airdrome_number)
        if not entry then
            return { ok = false, error = "no warehouse entry for airdrome " .. airdrome_number }
        end
        return {
            ok = true,
            target = 'airbase',
            name = ad:getName(),
            airdrome_number = airdrome_number,
            warehouse = entry,
        }
    end

    local unit_id = _resolve_unit_id(args.unit)
    if not unit_id then
        return { ok = false, error = string.format("no unit matching %q", tostring(args.unit)) }
    end
    local warehouses = mm.mission.AirportsEquipment.warehouses or {}
    local entry = warehouses[unit_id]
    local unit_name
    if mm.unit_by_id and mm.unit_by_id[unit_id] then unit_name = mm.unit_by_id[unit_id].name end
    if not entry then
        return { ok = false, error = string.format("no warehouse entry for unit %s (id=%d) — only ships/structures with cargo carry warehouses", unit_name or '?', unit_id) }
    end
    -- Deep-copy via warehouse_ops helper
    local wo = require('dcs_sms_me.warehouse_ops')
    return {
        ok = true,
        target = 'unit',
        name = unit_name,
        unit_id = unit_id,
        warehouse = wo._deep_copy(entry),
    }
end

local function _resources_resolve_target(args)
    local has_airbase = type(args.airbase) == 'string' and args.airbase ~= ''
    local has_unit = args.unit ~= nil and args.unit ~= ''
    if has_airbase == has_unit then
        return nil, "exactly one of --airbase or --unit is required"
    end
    local mm = require('me_mission')
    if not mm or not mm.mission or not mm.mission.AirportsEquipment then
        return nil, "mission not loaded — open one in the Mission Editor first"
    end
    if has_airbase then
        local ad = find_airbase_by_name(args.airbase)
        if not ad then
            return nil, string.format("no airbase matching %q", args.airbase)
        end
        local airdrome_number = ad.getAirdromeNumber and ad:getAirdromeNumber() or nil
        if not airdrome_number then
            return nil, "airbase has no airdrome_number"
        end
        return { kind = 'airbase', airdrome = ad, airdrome_number = airdrome_number, mm = mm }
    end
    local unit_id = _resolve_unit_id(args.unit)
    if not unit_id then
        return nil, string.format("no unit matching %q", tostring(args.unit))
    end
    local warehouses = mm.mission.AirportsEquipment.warehouses or {}
    if not warehouses[unit_id] then
        local nm = mm.unit_by_id and mm.unit_by_id[unit_id] and mm.unit_by_id[unit_id].name
        return nil, string.format("no warehouse entry for unit %s (id=%d) — only ships/structures with cargo carry warehouses", nm or '?', unit_id)
    end
    local unit_name = mm.unit_by_id and mm.unit_by_id[unit_id] and mm.unit_by_id[unit_id].name or nil
    return { kind = 'unit', unit_id = unit_id, unit_name = unit_name, mm = mm }
end

local _RES_FUEL_TYPES = { 'jet_fuel', 'gasoline', 'diesel', 'methanol_mixture' }
local _RES_AC_CATEGORIES = { 'planes', 'helicopters' }

local function _resources_zero_aircrafts(entry)
    if type(entry.aircrafts) ~= 'table' then return end
    for _, sub in ipairs(_RES_AC_CATEGORIES) do
        if type(entry.aircrafts[sub]) == 'table' then
            for k, v in pairs(entry.aircrafts[sub]) do
                if type(v) == 'table' then v.initialAmount = 0 end
            end
        end
    end
end

local function _resources_zero_weapons(entry)
    if type(entry.weapons) ~= 'table' then return end
    for i = 1, #entry.weapons do
        if type(entry.weapons[i]) == 'table' then
            entry.weapons[i].initialAmount = 0
        end
    end
end

local function _resources_zero_fuel(entry)
    for _, ft in ipairs(_RES_FUEL_TYPES) do
        if type(entry[ft]) == 'table' then
            entry[ft].InitFuel = 0
        end
    end
end

function M.resources_set(args)
    args = args or {}

    -- 1. Resolve target
    local target, err = _resources_resolve_target(args)
    if not target then return { ok = false, error = err } end

    -- 2. Read warehouse entry (deep copy)
    local wo = require('dcs_sms_me.warehouse_ops')
    local entry
    if target.kind == 'airbase' then
        entry = wo.extract(target.airdrome_number)
    else
        entry = wo._deep_copy(target.mm.mission.AirportsEquipment.warehouses[target.unit_id])
    end
    if type(entry) ~= 'table' then
        return { ok = false, error = "warehouse entry could not be read" }
    end

    -- 3. Pre-validate ALL mods (atomic — no mutation until validation succeeds)

    -- 3a. Fuel overrides — type names already validated CLI-side, but defend.
    local fuel_overrides = type(args.fuel_overrides) == 'table' and args.fuel_overrides or {}
    local fuel_valid = {}
    for k, _ in pairs(fuel_overrides) do fuel_valid[k] = false end
    for _, ft in ipairs(_RES_FUEL_TYPES) do fuel_valid[ft] = true end
    for k, _ in pairs(fuel_overrides) do
        if not fuel_valid[k] then
            return { ok = false, error = string.format(
                "unknown fuel type %q (must be jet_fuel, gasoline, diesel, or methanol_mixture)", k) }
        end
    end

    -- 3b. Aircraft overrides — keys must exist in entry.aircrafts.{planes,helicopters}.
    local aircraft_overrides = type(args.aircraft_overrides) == 'table' and args.aircraft_overrides or {}
    local resolved_aircraft = {}
    for name, count in pairs(aircraft_overrides) do
        local found
        local ac = entry.aircrafts or {}
        if type(ac.planes) == 'table' and ac.planes[name] then
            found = 'planes'
        elseif type(ac.helicopters) == 'table' and ac.helicopters[name] then
            found = 'helicopters'
        end
        if not found then
            local cands = {}
            local function add_keys(t)
                if type(t) ~= 'table' then return end
                for k in pairs(t) do
                    if k:lower():find(name:lower(), 1, true) then
                        cands[#cands + 1] = k
                        if #cands >= 5 then return end
                    end
                end
            end
            add_keys(ac.planes)
            add_keys(ac.helicopters)
            return { ok = false,
                error = string.format("no aircraft %q in warehouse", name),
                candidates = cands }
        end
        resolved_aircraft[name] = { category = found, count = count }
    end

    -- 3c. Weapon overrides — resolve fragment → ws_type via weapons_db.
    local weapon_overrides = type(args.weapon_overrides) == 'table' and args.weapon_overrides or {}
    local resolved_weapons = {}
    local weapons_db = require('dcs_sms_me.weapons_db')
    for _, w in ipairs(weapon_overrides) do
        if type(w) ~= 'table' or type(w.name) ~= 'string' or type(w.count) ~= 'number' then
            return { ok = false, error = "weapon_overrides entries must be { name=string, count=number }" }
        end
        local r = weapons_db.find_by_name(w.name)
        if r.ambiguous then
            return { ok = false,
                error = string.format("weapon %q is ambiguous", w.name),
                candidates = r.candidates }
        elseif not r.found then
            return { ok = false, error = string.format("no weapon matching %q", w.name) }
        end
        resolved_weapons[#resolved_weapons + 1] = {
            ws_type      = r.entry.ws_type,
            count        = w.count,
            display_name = r.entry.display_name,
        }
    end

    -- 4. Apply mods (validated; safe to mutate the copy).

    -- 4a. Top-level resets
    if args.clear then
        entry.unlimitedFuel = false
        entry.unlimitedAircrafts = false
        entry.unlimitedMunitions = false
        _resources_zero_aircrafts(entry)
        _resources_zero_weapons(entry)
        _resources_zero_fuel(entry)
    end
    if args.unlimited == true then
        entry.unlimitedFuel = true
        entry.unlimitedAircrafts = true
        entry.unlimitedMunitions = true
    elseif args.unlimited == false then
        entry.unlimitedFuel = false
        entry.unlimitedAircrafts = false
        entry.unlimitedMunitions = false
    end

    -- 4b. Per-category resets
    if args.clear_aircrafts then _resources_zero_aircrafts(entry) end
    if args.clear_fuel then _resources_zero_fuel(entry) end
    if args.clear_munitions then _resources_zero_weapons(entry) end
    if args.unlimited_aircrafts ~= nil then entry.unlimitedAircrafts = args.unlimited_aircrafts end
    if args.unlimited_fuel ~= nil then entry.unlimitedFuel = args.unlimited_fuel end
    if args.unlimited_munitions ~= nil then entry.unlimitedMunitions = args.unlimited_munitions end

    -- 4c. Operating levels
    if args.operating_level_air ~= nil then entry.OperatingLevel_Air = args.operating_level_air end
    if args.operating_level_fuel ~= nil then entry.OperatingLevel_Fuel = args.operating_level_fuel end
    if args.operating_level_eqp ~= nil then entry.OperatingLevel_Eqp = args.operating_level_eqp end

    -- 4d. Specific values
    for ftype, value in pairs(fuel_overrides) do
        if type(entry[ftype]) ~= 'table' then entry[ftype] = {} end
        entry[ftype].InitFuel = value
    end
    for name, info in pairs(resolved_aircraft) do
        entry.aircrafts[info.category][name].initialAmount = info.count
    end
    for _, w in ipairs(resolved_weapons) do
        local found_idx
        if type(entry.weapons) == 'table' then
            for i, we in ipairs(entry.weapons) do
                if type(we) == 'table' and type(we.wsType) == 'table'
                       and we.wsType[1] == w.ws_type[1]
                       and we.wsType[2] == w.ws_type[2]
                       and we.wsType[3] == w.ws_type[3]
                       and we.wsType[4] == w.ws_type[4] then
                    found_idx = i; break
                end
            end
        end
        if found_idx then
            entry.weapons[found_idx].initialAmount = w.count
        else
            entry.weapons = entry.weapons or {}
            entry.weapons[#entry.weapons + 1] = {
                wsType = { w.ws_type[1], w.ws_type[2], w.ws_type[3], w.ws_type[4] },
                initialAmount = w.count,
            }
        end
    end

    -- 5. Write back
    if target.kind == 'airbase' then
        local ok, werr = wo.apply(target.airdrome_number, entry)
        if not ok then return { ok = false, error = werr or 'warehouse_ops.apply failed' } end
        return {
            ok = true,
            target = 'airbase',
            name = target.airdrome:getName(),
            airdrome_number = target.airdrome_number,
            warehouse = entry,
        }
    else
        target.mm.mission.AirportsEquipment.warehouses[target.unit_id] = entry
        return {
            ok = true,
            target = 'unit',
            name = target.unit_name,
            unit_id = target.unit_id,
            warehouse = entry,
        }
    end
end

return M
