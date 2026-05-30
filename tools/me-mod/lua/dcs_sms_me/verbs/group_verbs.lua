-- dcs_sms_me/verbs/group_verbs.lua — group lifecycle + setters + list/get.
--
-- Verbs: group_remove, group_create_<plane|helicopter|vehicle|ship|static>,
-- group_add_unit, group_remove_unit, group_set_<name|task|hidden|late_activation|
-- uncontrolled|frequency|pos|formation|country>, group_list, group_get.
-- See dcs_sms_me/verbs.lua for the aggregator and the verb-naming convention.

local M = {}

local H = require('dcs_sms_me.verb_helpers')
local walk_groups           = H.walk_groups
local strip_back_refs       = H.strip_back_refs
local refresh_group_view    = H.refresh_group_view
local find_unit_in_mission  = H.find_unit_in_mission
local find_group_in_mission = H.find_group_in_mission
local find_country_by_name  = H.find_country_by_name
local inject_group          = H.inject_group
local compute_lat_lon       = H.compute_lat_lon

-- _check_unit_type — guard against bad type strings reaching the .miz.
-- DCS's save serializer (me_mission.lua:setRequiredModules) derefs
-- me_db.unit_by_type[type]._origin without nil-checking, so an unknown
-- type that the ME accepted at create-time silently produces a group
-- that crashes File→Save with a Lua traceback the user can't undo.
-- We reject up front instead.
--
-- Returns nil on success, { ok=false, error=... } on rejection. Returns
-- nil (accept) when me_db_api isn't loadable — that happens in the Lua
-- mock test harness, which would otherwise reject every test type.
-- Production DCS always has me_db_api by the time the bridge dispatches.
local function _check_unit_type(verb_name, type_id)
    local ok_db, DB = pcall(require, 'me_db_api')
    if not ok_db or type(DB) ~= 'table' or type(DB.unit_by_type) ~= 'table' then
        return nil
    end
    if DB.unit_by_type[type_id] == nil then
        return { ok = false,
                 error = verb_name .. ': unknown unit type "' .. type_id ..
                         '" — not in me_db_api.unit_by_type. Creating it would '
                         .. 'crash File→Save (me_mission.lua:setRequiredModules '
                         .. 'derefs unitDef._origin without a nil-check). '
                         .. 'Check the spelling against the canonical DCS unit DB '
                         .. '(e.g. framework/constants/units.lua).' }
    end
    return nil
end

-- ============================================================
-- Group lifecycle verbs
-- ============================================================

-- group_remove — remove a group from the mission by name or id.
--
-- args: { name = "<group name>" } OR { id = <groupId> }. Exactly one
-- required. Returns { ok = true, name = ..., id = ..., category = ... } on
-- success or { ok = false, error = "..." } on failure.
function M.group_remove(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_remove requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then  -- both or neither
        return { ok = false, error = 'group_remove requires exactly one of args.name (string) or args.id (number)' }
    end

    local g, country, side_name, cat = find_group_in_mission(has_name and args.name or nil,
                                                              has_id and args.id or nil)
    if not g then
        return { ok = false, error = 'group not found' }
    end

    local resolved = { name = g.name, id = g.groupId, category = cat,
                       country = country and country.name, side = side_name }

    local Mission = require('me_mission')
    -- Disk-loaded groups have mapObjects = nil until the user selects them
    -- (the ME populates it lazily). Mission.remove_group → remove_group_map_objects
    -- (me_mission.lua:7881) iterates group.mapObjects.units and crashes on nil.
    -- create_group_map_objects builds the proper structure; if it fails for
    -- any reason, fall back to a minimal stub so the remove iteration is empty.
    if g.mapObjects == nil and type(Mission.create_group_map_objects) == 'function' then
        pcall(Mission.create_group_map_objects, g)
    end
    if g.mapObjects == nil or type(g.mapObjects.units) ~= 'table' then
        g.mapObjects = g.mapObjects or {}
        g.mapObjects.units = g.mapObjects.units or {}
        g.mapObjects.zones = g.mapObjects.zones or {}
    end

    local ok_call, err = pcall(Mission.remove_group, g)
    if not ok_call then
        return { ok = false, error = 'remove_group: ' .. tostring(err), resolved = resolved }
    end

    return { ok = true, name = resolved.name, id = resolved.id,
             category = resolved.category, country = resolved.country,
             side = resolved.side }
end

-- group_create_plane — synthesize and inject a single-unit fixed-wing
-- aircraft group, single waypoint at the spawn point with an empty ComboTask.
-- Survives save (runs fixWaypointForGroup), is fully selectable in the ME,
-- and runs in mission.
--
-- args (required):
--   country: string  -- e.g. "USA", "Russia". Must already exist in the
--                       mission's coalition tree (file_new sets defaults).
--   type:    string  -- airframe id, e.g. "F-16C_50", "Su-27"
--   north:   number  -- meters north of theatre origin (north positive)
--   east:    number  -- meters east  of theatre origin (east  positive)
--                       See verb_helpers.lua for why we use north/east
--                       instead of DCS's contradictory x/y/z naming.
--
-- args (optional, with defaults):
--   name:        group name (auto-allocated if nil/empty via check_group_name)
--   alt:         8000 (meters above sea level)
--   alt_type:    'BARO'
--   speed:       220 (m/s ~ 428 kts)
--   heading:     0 (radians)
--   skill:       'Average'
--   livery:      ''
--   frequency:   251 (MHz)
--   onboard_num: '010'
--
-- Returns { ok = true, groupId, name, unitId, unitName } on success.
function M.group_create_plane(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_create_plane requires args (table)' }
    end
    if type(args.country) ~= 'string' or args.country == '' then
        return { ok = false, error = 'group_create_plane requires args.country (string)' }
    end
    if type(args.type) ~= 'string' or args.type == '' then
        return { ok = false, error = 'group_create_plane requires args.type (string, airframe id)' }
    end
    local bad = _check_unit_type('group_create_plane', args.type)
    if bad then return bad end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'group_create_plane requires args.north and args.east (numbers, meters)' }
    end

    local country, side_name = find_country_by_name(args.country)
    if not country then
        return { ok = false,
                 error = 'country "' .. args.country .. '" not in mission coalition tree; '
                         .. 'use a country active on this mission (file_new sets defaults)' }
    end

    -- Translate semantic --north / --east to mission-table fields:
    -- the .miz format stores the ground plane as (x = N–S, y = E–W).
    local x, y = args.north, args.east
    local alt = args.alt or 8000
    local alt_type = args.alt_type or 'BARO'
    local speed = args.speed or 220
    local heading = math.rad(args.heading_deg or 0)
    local skill = args.skill or 'Average'
    local livery = args.livery or ''
    local frequency = args.frequency or 251
    local onboard_num = args.onboard_num or '010'

    local group_name = (type(args.name) == 'string' and args.name ~= '') and args.name
                       or (args.type .. ' #001')

    local g = {
        name = group_name,
        x = x, y = y,
        task = 'Nothing',
        hidden = false,
        hiddenOnPlanner = false,
        hiddenOnMFD = {},
        modulation = 0,
        frequency = frequency,
        uncontrolled = false,
        start_time = 0,
        units = {
            {
                name = group_name .. '-1',  -- placeholder; getUnitName replaces
                type = args.type,
                x = x, y = y,
                alt = alt, alt_type = alt_type,
                speed = speed,
                heading = heading,
                psi = 0,
                skill = skill,
                livery_id = livery,
                onboard_num = onboard_num,
                callsign = { 1, 1, 1, name = 'Enfield11' },
                payload = {
                    pylons = {},
                    fuel = '9999',
                    flare = 0,
                    chaff = 0,
                    gun = 100,
                },
                AddPropAircraft = nil,  -- fixAddPropAircraft fills this
            },
        },
        route = {
            points = {
                {
                    x = x, y = y,
                    alt = alt, alt_type = alt_type,
                    speed = speed,
                    action = 'Turning Point',
                    type = 'Turning Point',
                    ETA = 0, ETA_locked = true,
                    formation_template = '',
                    task = { id = 'ComboTask', params = { tasks = {} } },
                },
            },
            routeRelativeTOT = false,
        },
    }

    local injected, err = inject_group(g, country, 'plane')
    if not injected then
        return { ok = false, error = err or 'inject_group failed' }
    end

    return {
        ok = true,
        groupId = injected.groupId,
        name = injected.name,
        unitId = injected.units[1].unitId,
        unitName = injected.units[1].name,
        country = country.name,
        side = side_name,
    }
end

-- group_create_helicopter — single-unit rotary-wing group with the same
-- shape as create_plane but a helo-typical default profile (lower alt,
-- slower speed). Single waypoint at the spawn point with an empty ComboTask,
-- save-survives via fixWaypointForGroup.
--
-- args (required): country, type, north, east
-- args (optional): name, alt (default 1000), alt_type (BARO), speed (50),
--                  heading (radians, 0), skill (Average), livery (''),
--                  frequency (127.5), onboard_num ('010')
function M.group_create_helicopter(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_create_helicopter requires args (table)' }
    end
    if type(args.country) ~= 'string' or args.country == '' then
        return { ok = false, error = 'group_create_helicopter requires args.country (string)' }
    end
    if type(args.type) ~= 'string' or args.type == '' then
        return { ok = false, error = 'group_create_helicopter requires args.type (string, airframe id)' }
    end
    local bad = _check_unit_type('group_create_helicopter', args.type)
    if bad then return bad end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'group_create_helicopter requires args.north and args.east (numbers, meters)' }
    end

    local country, side_name = find_country_by_name(args.country)
    if not country then
        return { ok = false,
                 error = 'country "' .. args.country .. '" not in mission coalition tree' }
    end

    local x, y = args.north, args.east
    local alt = args.alt or 1000
    local alt_type = args.alt_type or 'BARO'
    local speed = args.speed or 50
    local heading = math.rad(args.heading_deg or 0)
    local skill = args.skill or 'Average'
    local livery = args.livery or ''
    local frequency = args.frequency or 127.5
    local onboard_num = args.onboard_num or '010'

    local group_name = (type(args.name) == 'string' and args.name ~= '') and args.name
                       or (args.type .. ' #001')

    local g = {
        name = group_name,
        x = x, y = y,
        task = 'Transport',
        hidden = false,
        hiddenOnPlanner = false,
        hiddenOnMFD = {},
        modulation = 0,
        frequency = frequency,
        uncontrolled = false,
        start_time = 0,
        units = {
            {
                name = group_name .. '-1',
                type = args.type,
                x = x, y = y,
                alt = alt, alt_type = alt_type,
                speed = speed,
                heading = heading,
                psi = 0,
                skill = skill,
                livery_id = livery,
                onboard_num = onboard_num,
                callsign = { 1, 1, 1, name = 'Enfield11' },
                payload = {
                    pylons = {},
                    fuel = '1100',
                    flare = 0,
                    chaff = 0,
                    gun = 100,
                },
                AddPropAircraft = nil,
            },
        },
        route = {
            points = {
                {
                    x = x, y = y,
                    alt = alt, alt_type = alt_type,
                    speed = speed,
                    action = 'Turning Point',
                    type = 'Turning Point',
                    ETA = 0, ETA_locked = true,
                    formation_template = '',
                    task = { id = 'ComboTask', params = { tasks = {} } },
                },
            },
            routeRelativeTOT = false,
        },
    }

    local injected, err = inject_group(g, country, 'helicopter')
    if not injected then
        return { ok = false, error = err or 'inject_group failed' }
    end

    return {
        ok = true,
        groupId = injected.groupId,
        name = injected.name,
        unitId = injected.units[1].unitId,
        unitName = injected.units[1].name,
        country = country.name,
        side = side_name,
    }
end

-- group_create_vehicle — single-unit ground-vehicle group, stationary
-- (Off Road action, speed=0, speed_locked). No alt / alt_type / payload —
-- those are aircraft-only fields.
--
-- args (required): country, type, north, east
-- args (optional): name, heading (radians, 0), skill (Average)
function M.group_create_vehicle(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_create_vehicle requires args (table)' }
    end
    if type(args.country) ~= 'string' or args.country == '' then
        return { ok = false, error = 'group_create_vehicle requires args.country (string)' }
    end
    if type(args.type) ~= 'string' or args.type == '' then
        return { ok = false, error = 'group_create_vehicle requires args.type (string, vehicle id)' }
    end
    local bad = _check_unit_type('group_create_vehicle', args.type)
    if bad then return bad end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'group_create_vehicle requires args.north and args.east (numbers, meters)' }
    end

    local country, side_name = find_country_by_name(args.country)
    if not country then
        return { ok = false,
                 error = 'country "' .. args.country .. '" not in mission coalition tree' }
    end

    local x, y = args.north, args.east
    local heading = math.rad(args.heading_deg or 0)
    local skill = args.skill or 'Average'

    local group_name = (type(args.name) == 'string' and args.name ~= '') and args.name
                       or (args.type .. ' #001')

    local g = {
        name = group_name,
        x = x, y = y,
        task = 'Ground Nothing',
        hidden = false,
        hiddenOnPlanner = false,
        hiddenOnMFD = {},
        modulation = 0,
        frequency = 0,
        uncontrolled = false,
        start_time = 0,
        units = {
            {
                name = group_name .. '-1',
                type = args.type,
                x = x, y = y,
                heading = heading,
                playerCanDrive = false,
                skill = skill,
            },
        },
        route = {
            points = {
                {
                    x = x, y = y,
                    alt = 0, alt_type = 'BARO',
                    speed = 0, speed_locked = true,
                    action = 'Off Road',
                    type = 'Turning Point',
                    ETA = 0, ETA_locked = true,
                    formation_template = '',
                    task = { id = 'ComboTask', params = { tasks = {} } },
                },
            },
            routeRelativeTOT = false,
        },
    }

    local injected, err = inject_group(g, country, 'vehicle')
    if not injected then
        return { ok = false, error = err or 'inject_group failed' }
    end

    return {
        ok = true,
        groupId = injected.groupId,
        name = injected.name,
        unitId = injected.units[1].unitId,
        unitName = injected.units[1].name,
        country = country.name,
        side = side_name,
    }
end

-- group_create_ship — single-unit naval-vessel group. Same shape as vehicle
-- (stationary, ground-style waypoint), but the position MUST be over water
-- — we check terrain.GetSurfaceType to fail fast rather than letting the
-- ship spawn on a beach and look broken.
--
-- args (required): country, type, north, east
-- args (optional): name, heading (radians, 0), skill (Average)
function M.group_create_ship(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_create_ship requires args (table)' }
    end
    if type(args.country) ~= 'string' or args.country == '' then
        return { ok = false, error = 'group_create_ship requires args.country (string)' }
    end
    if type(args.type) ~= 'string' or args.type == '' then
        return { ok = false, error = 'group_create_ship requires args.type (string, ship id)' }
    end
    local bad = _check_unit_type('group_create_ship', args.type)
    if bad then return bad end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'group_create_ship requires args.north and args.east (numbers, meters)' }
    end

    local country, side_name = find_country_by_name(args.country)
    if not country then
        return { ok = false,
                 error = 'country "' .. args.country .. '" not in mission coalition tree' }
    end

    -- Water-surface check. terrain.GetSurfaceType uses mission-table coords
    -- (x = N–S, y = E–W). Returns lowercase strings; sea-ish responses are
    -- 'sea' / 'shallow_water'. force=true skips the check (escape hatch).
    if args.force ~= true then
        local ok_terr, terrain = pcall(require, 'terrain')
        if ok_terr and type(terrain) == 'table' and type(terrain.GetSurfaceType) == 'function' then
            local surf = terrain.GetSurfaceType(args.north, args.east)
            if surf ~= 'sea' and surf ~= 'shallow_water' then
                return { ok = false,
                         error = 'ship spawn at (' .. args.north .. ', ' .. args.east .. ') is over '
                                 .. tostring(surf) .. ', not water; pass force=true to override' }
            end
        end
    end

    local x, y = args.north, args.east
    local heading = math.rad(args.heading_deg or 0)
    local skill = args.skill or 'Average'

    local group_name = (type(args.name) == 'string' and args.name ~= '') and args.name
                       or (args.type .. ' #001')

    local g = {
        name = group_name,
        x = x, y = y,
        task = 'CAP',
        hidden = false,
        hiddenOnPlanner = false,
        hiddenOnMFD = {},
        modulation = 0,
        frequency = 0,
        uncontrolled = false,
        start_time = 0,
        units = {
            {
                name = group_name .. '-1',
                type = args.type,
                x = x, y = y,
                heading = heading,
                skill = skill,
                modulation = 0,
                transportable = { randomTransportable = false },
            },
        },
        route = {
            points = {
                {
                    x = x, y = y,
                    alt = 0, alt_type = 'BARO',
                    -- Ship waypoints need `depth` (positive metres). Save's
                    -- unload_ship_groups computes `pt.alt = -s.depth`
                    -- (me_mission.lua:4239) and crashes on nil here.
                    depth = 0,
                    speed = 0, speed_locked = true,
                    action = 'Turning Point',
                    type = 'Turning Point',
                    ETA = 0, ETA_locked = true,
                    formation_template = '',
                    task = { id = 'ComboTask', params = { tasks = {} } },
                },
            },
            routeRelativeTOT = false,
        },
    }

    local injected, err = inject_group(g, country, 'ship')
    if not injected then
        return { ok = false, error = err or 'inject_group failed' }
    end

    return {
        ok = true,
        groupId = injected.groupId,
        name = injected.name,
        unitId = injected.units[1].unitId,
        unitName = injected.units[1].name,
        country = country.name,
        side = side_name,
    }
end

-- group_create_static — static-object group. Statics are different:
-- one "unit" representing the object, no waypoints / route, no AI behavior.
-- They're stored under country.static.group same as vehicles, but shape is
-- minimal — a single position, heading, dead flag, category, shape_name.
--
-- args (required): country, type, north, east
-- args (optional): name, heading (radians, 0), category (Cargos / Fortifications
--                  / Warehouses / etc.), shape_name (model id), dead (false),
--                  can_cargo (false), mass (0)
function M.group_create_static(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_create_static requires args (table)' }
    end
    if type(args.country) ~= 'string' or args.country == '' then
        return { ok = false, error = 'group_create_static requires args.country (string)' }
    end
    if type(args.type) ~= 'string' or args.type == '' then
        return { ok = false, error = 'group_create_static requires args.type (string, static id)' }
    end
    local bad = _check_unit_type('group_create_static', args.type)
    if bad then return bad end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'group_create_static requires args.north and args.east (numbers, meters)' }
    end

    local country, side_name = find_country_by_name(args.country)
    if not country then
        return { ok = false,
                 error = 'country "' .. args.country .. '" not in mission coalition tree' }
    end

    local x, y = args.north, args.east
    local heading = math.rad(args.heading_deg or 0)
    local category = args.category or 'Fortifications'
    local shape_name = args.shape_name or ''
    local dead = (args.dead == true)
    local can_cargo = (args.can_cargo == true)
    local mass = args.mass or 0

    local group_name = (type(args.name) == 'string' and args.name ~= '') and args.name
                       or (args.type .. ' #001')

    -- Static groups still have a route (single point) so the canonical
    -- inject_group sequence's fixWaypointForGroup is happy.
    local g = {
        name = group_name,
        x = x, y = y,
        hidden = false,
        dead = dead,
        heading = heading,
        units = {
            {
                name = group_name,  -- statics use the group name as unit name
                type = args.type,
                x = x, y = y,
                heading = heading,
                category = category,
                shape_name = shape_name,
                rate = 100,
                canCargo = can_cargo,
                mass = mass,
                dead = dead,
            },
        },
        route = {
            points = {
                {
                    x = x, y = y,
                    action = 'Off Road',
                    type = 'Turning Point',
                    ETA = 0, ETA_locked = true,
                    formation_template = '',
                    speed = 0, speed_locked = true,
                    task = { id = 'ComboTask', params = { tasks = {} } },
                },
            },
            routeRelativeTOT = false,
        },
    }

    local injected, err = inject_group(g, country, 'static')
    if not injected then
        return { ok = false, error = err or 'inject_group failed' }
    end

    return {
        ok = true,
        groupId = injected.groupId,
        name = injected.name,
        unitId = injected.units[1].unitId,
        unitName = injected.units[1].name,
        country = country.name,
        side = side_name,
    }
end

-- group_add_unit — add a unit to an existing group, copying defaults from
-- the group's last unit (matching the ME's own "+" button behaviour).
--
-- Position semantics:
--   * --offset-north / --offset-east (either or both) → unit at
--     (g.x + offset_north, g.y + offset_east) — relative to the group
--     anchor, NOT cumulative across calls.
--   * Neither passed → let Mission.insert_unit apply its built-in index-
--     cumulative spread (40m south / 40m east per added unit), which is
--     what the ME does when you click + with nothing selected.
--
-- AIR-GROUP CAVEAT: per-unit (x, y) is decorative for plane / helicopter
-- groups. DCS overrides it at mission load and lays out the flight via
-- group.units[1].route.points[1] (or wherever the route starts) +
-- formation_template — every wingman is positioned by the formation, not
-- by their stored x/y. The offset survives in the ME view and on disk
-- but doesn't reach runtime. Ground / ship / static groups respect
-- per-unit positions verbatim. A future formation setter is the right
-- lever for air-group runtime layout.
--
-- Type rule for air groups: plane / helicopter groups can't be
-- heterogeneous (no F-16 + F-14 in one group — DCS doesn't permit it).
-- We refuse if --type is given and differs from g.units[1].type, and
-- default to g.units[1].type when --type is omitted. Vehicle / ship /
-- static groups allow mixed types (Hawk SAM site = PCP + SR + TR + LN).
--
-- Field defaults: skill / livery / heading / alt / alt_type / payload
-- copy from the LAST unit in the group, so adding a unit to a 4-ship
-- F-16 flight with one weapon load keeps the same load on #5. Any field
-- can be overridden via the matching arg.
--
-- args (required):
--   name | id   group selector (mutually exclusive)
--
-- args (optional):
--   type           string  (auto-fill from last/first unit if absent)
--   offset_north   number  (meters; nil → insert_unit default spread)
--   offset_east    number  (meters; nil → insert_unit default spread)
--   skill / livery / heading_deg / alt / alt_type
--   onboard_num / callsign / frequency  (set after insert_unit)
function M.group_add_unit(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_add_unit requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'group_add_unit requires exactly one of args.name or args.id' }
    end

    local g, country, side_name, cat = find_group_in_mission(
        has_name and args.name or nil, has_id and args.id or nil)
    if not g then
        return { ok = false, error = 'group not found' }
    end
    if type(g.units) ~= 'table' or #g.units == 0 then
        return { ok = false, error = 'group has no existing units to derive defaults from' }
    end

    local first_unit = g.units[1]
    local last_unit = g.units[#g.units]

    -- Type resolution + air-group homogeneity check.
    local utype = (type(args.type) == 'string' and args.type ~= '') and args.type or last_unit.type
    if (cat == 'plane' or cat == 'helicopter') and utype ~= first_unit.type then
        return { ok = false,
                 error = cat .. ' groups can only contain one airframe; existing="'
                         .. tostring(first_unit.type) .. '", requested="' .. utype .. '"' }
    end
    -- Only validate when --type was explicit; inheriting from last_unit means
    -- the group already lives in the mission with that type and validating now
    -- couldn't fix it.
    if type(args.type) == 'string' and args.type ~= '' then
        local bad = _check_unit_type('group_add_unit', utype)
        if bad then return bad end
    end

    -- Field defaults — explicit args win, otherwise inherit from last unit.
    local skill = (type(args.skill) == 'string' and args.skill ~= '') and args.skill
                  or last_unit.skill or 'Average'
    local livery = (type(args.livery) == 'string') and args.livery
                   or last_unit.livery_id or ''
    local heading_rad
    if type(args.heading_deg) == 'number' then
        heading_rad = math.rad(args.heading_deg)
    else
        heading_rad = last_unit.heading or 0
    end

    -- Position. Pass nil for x/y to Mission.insert_unit when no offset
    -- supplied — it then applies its index-cumulative 40m spread.
    local x, y
    if type(args.offset_north) == 'number' or type(args.offset_east) == 'number' then
        x = g.x + (args.offset_north or 0)
        y = g.y + (args.offset_east or 0)
    end

    local Mission = require('me_mission')

    -- check_unit_name (called inside insert_unit) crashes on a nil seed —
    -- it does string.reverse(seed) to find a base for suffix-uniquify.
    -- Use the LAST unit's name as the seed: it already has the
    -- "<group>-N" shape so check_unit_name picks the next free index
    -- cleanly (CAP4-1 → CAP4-2 → CAP4-3 …). Using g.name as the seed
    -- gives back g.name itself for the first add (group names live in
    -- group_by_name, unit names in unit_by_name — no collision).
    local index = #g.units + 1
    local ok_call, u_or_err = pcall(Mission.insert_unit,
        g, utype, skill, index, last_unit.name, x, y, heading_rad, nil, livery)
    if not ok_call then
        return { ok = false, error = 'insert_unit: ' .. tostring(u_or_err) }
    end
    local u = u_or_err
    if type(u) ~= 'table' then
        return { ok = false, error = 'insert_unit returned no unit table' }
    end

    -- Air-only fields. insert_unit doesn't set u.alt — copy from the last
    -- unit (or use --alt). Same for alt_type. Payload defaults from
    -- unitDef inside insert_unit; we override with last-unit's payload
    -- so #5 in a flight inherits the loadout (deep copy to avoid shared
    -- mutation). Allow explicit args.payload to skip the copy.
    if cat == 'plane' or cat == 'helicopter' then
        u.alt = (type(args.alt) == 'number') and args.alt or last_unit.alt
        u.alt_type = (type(args.alt_type) == 'string' and args.alt_type ~= '')
                     and args.alt_type or last_unit.alt_type or 'BARO'
        if last_unit.payload and not args.payload then
            local copy = {}
            for k, v in pairs(last_unit.payload) do
                if k == 'pylons' and type(v) == 'table' then
                    copy.pylons = {}
                    for pk, pv in pairs(v) do copy.pylons[pk] = pv end
                else
                    copy[k] = v
                end
            end
            u.payload = copy
        end
    end

    -- Optional explicit overrides for fields the user might want to set
    -- right at add-time without a follow-up `unit set-*` call.
    if type(args.onboard_num) == 'string' and args.onboard_num ~= '' then
        u.onboard_num = args.onboard_num
    end
    if type(args.callsign) == 'string' and args.callsign ~= '' then
        local existing = (type(u.callsign) == 'table') and u.callsign or {}
        local sq = (type(existing[1]) == 'number' and existing[1]) or 1
        local fl = (type(existing[2]) == 'number' and existing[2]) or 1
        local pl = (type(existing[3]) == 'number' and existing[3]) or 1
        u.callsign = { sq, fl, pl, name = args.callsign }
    end
    if type(args.frequency) == 'number' and args.frequency > 0 then
        u.frequency = args.frequency
    end

    -- Refresh visuals — insert_unit_symbol drew the sprite, but the rest
    -- of the group (e.g. existing units' positions if anything cares) is
    -- safe-to-update via the standard helper.
    refresh_group_view(g)

    return {
        ok = true,
        groupId = g.groupId,
        group = g.name,
        category = cat,
        country = country and country.name,
        side = side_name,
        unitId = u.unitId,
        unitName = u.name,
        type = u.type,
        north = u.x,
        east = u.y,
        unit_count = #g.units,
    }
end

-- group_remove_unit — remove a single unit from a group, mirroring the
-- ME UI's per-unit "x" button. Wraps Mission.remove_unit, which handles
-- the unlink dance (waypoints, required units, trigger zones), warehouse
-- cleanup, unit_by_name / unit_by_id deregistration, and panel refresh.
--
-- Selection is by --name or --id (mutually exclusive) — the unit's, not
-- the group's. The verb walks the coalition tree to find the unit.
--
-- Refuses to remove the last unit in a group: that would leave an empty
-- group, which the rest of the ME doesn't expect (the Unit List panel,
-- selection helpers, etc. all assume #units >= 1). To remove the whole
-- group use `me group remove`.
--
-- Mission.remove_unit reads `unit.index` (its position in g.units).
-- Units inserted via insert_unit have it set; the seed unit synthesised
-- by group_create_<cat> doesn't, so we populate it defensively here by
-- walking g.units before the call.
function M.group_remove_unit(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_remove_unit requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'group_remove_unit requires exactly one of args.name or args.id' }
    end

    local u, g, country, side_name, cat = find_unit_in_mission(
        has_name and args.name or nil, has_id and args.id or nil)
    if not u then
        return { ok = false, error = 'unit not found' }
    end
    if type(g.units) ~= 'table' or #g.units <= 1 then
        return { ok = false,
                 error = 'cannot remove the last unit in a group; use `me group remove` instead' }
    end

    -- Make sure unit.index is set; remove_unit relies on it for table.remove.
    if type(u.index) ~= 'number' then
        for i, gu in ipairs(g.units) do
            if gu == u then u.index = i; break end
        end
    end

    local resolved = {
        name = u.name, id = u.unitId, type = u.type,
        group = g.name, group_id = g.groupId,
        category = cat,
        country = country and country.name, side = side_name,
    }

    local Mission = require('me_mission')
    local ok_call, err = pcall(Mission.remove_unit, u)
    if not ok_call then
        return { ok = false, error = 'remove_unit: ' .. tostring(err), resolved = resolved }
    end

    refresh_group_view(g)

    return {
        ok = true,
        name = resolved.name,
        id = resolved.id,
        type = resolved.type,
        group = resolved.group,
        group_id = resolved.group_id,
        category = resolved.category,
        country = resolved.country,
        side = resolved.side,
        unit_count = #g.units,
    }
end

-- ============================================================
-- Group setters (per-field)
-- ============================================================

-- group_set_name — rename a group via Mission.renameGroup. Refuses on name
-- collision (returns false from renameGroup) — does NOT silently uniquify.
function M.group_set_name(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_set_name requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'group_set_name requires exactly one of args.name or args.id' }
    end
    if type(args.new_name) ~= 'string' or args.new_name == '' then
        return { ok = false, error = 'group_set_name requires args.new_name (non-empty string)' }
    end
    local g = find_group_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not g then
        return { ok = false, error = 'group not found' }
    end
    local Mission = require('me_mission')
    local ok = Mission.renameGroup(g, args.new_name)
    if not ok then
        return { ok = false, error = 'name "' .. args.new_name .. '" already in use' }
    end
    return { ok = true, id = g.groupId, name = args.new_name }
end

-- group_set_task — set the group-level task field (g.task). Doesn't touch
-- per-waypoint ComboTasks. Strings the ME accepts include CAP, CAS, Escort,
-- Nothing, etc. — no validation here, the ME stores the value verbatim.
function M.group_set_task(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_set_task requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'group_set_task requires exactly one of args.name or args.id' }
    end
    if type(args.task) ~= 'string' or args.task == '' then
        return { ok = false, error = 'group_set_task requires args.task (non-empty string)' }
    end
    local g = find_group_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not g then
        return { ok = false, error = 'group not found' }
    end
    g.task = args.task
    return { ok = true, id = g.groupId, name = g.name, task = g.task }
end

-- group_set_hidden — toggle g.hidden. Requires explicit args.hidden bool.
function M.group_set_hidden(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_set_hidden requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'group_set_hidden requires exactly one of args.name or args.id' }
    end
    if type(args.hidden) ~= 'boolean' then
        return { ok = false, error = 'group_set_hidden requires args.hidden (boolean)' }
    end
    local g = find_group_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not g then
        return { ok = false, error = 'group not found' }
    end
    g.hidden = args.hidden
    return { ok = true, id = g.groupId, name = g.name, hidden = g.hidden }
end

-- group_set_late_activation — toggle g.lateActivation. Late-activation
-- groups don't spawn at mission start; they're spawned later via a
-- trigger's GROUP ACTIVATE action (or a script's activateGroup() call).
-- The ME shows them on the planner / F10 map but renders them in a
-- distinct "deferred" style.
function M.group_set_late_activation(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_set_late_activation requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'group_set_late_activation requires exactly one of args.name or args.id' }
    end
    if type(args.enabled) ~= 'boolean' then
        return { ok = false, error = 'group_set_late_activation requires args.enabled (boolean)' }
    end
    local g = find_group_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not g then
        return { ok = false, error = 'group not found' }
    end
    g.lateActivation = args.enabled
    return { ok = true, id = g.groupId, name = g.name, late_activation = g.lateActivation }
end

-- group_set_uncontrolled — toggle g.uncontrolled. Uncontrolled groups
-- spawn but DCS gives them no AI controller: aircraft sit on the ramp
-- with engines off (for parking-spot starts) until a trigger's GROUP AI
-- ON action / script's startCommand fires. Common pattern for "ready
-- alert" CAP, scripted intercepts, or player-slot groups. The flag
-- only meaningfully affects AI-controlled groups (plane/helicopter/
-- vehicle/ship/train); statics ignore it.
function M.group_set_uncontrolled(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_set_uncontrolled requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'group_set_uncontrolled requires exactly one of args.name or args.id' }
    end
    if type(args.enabled) ~= 'boolean' then
        return { ok = false, error = 'group_set_uncontrolled requires args.enabled (boolean)' }
    end
    local g = find_group_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not g then
        return { ok = false, error = 'group not found' }
    end
    g.uncontrolled = args.enabled
    return { ok = true, id = g.groupId, name = g.name, uncontrolled = g.uncontrolled }
end

-- group_set_frequency — set g.frequency in MHz.
function M.group_set_frequency(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_set_frequency requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'group_set_frequency requires exactly one of args.name or args.id' }
    end
    if type(args.frequency) ~= 'number' or args.frequency <= 0 then
        return { ok = false, error = 'group_set_frequency requires args.frequency (positive number, MHz)' }
    end
    local g = find_group_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not g then
        return { ok = false, error = 'group not found' }
    end
    g.frequency = args.frequency
    return { ok = true, id = g.groupId, name = g.name, frequency = g.frequency }
end

-- group_set_pos — translate the entire group to a new center.
--
-- Computes delta = (north - g.x, east - g.y) and applies it to g, every
-- unit, and every waypoint. Preserves intra-group offsets (formations,
-- SAM-site geometry).
--
-- Refreshes Mission.update_group_map_objects so the ME view reflects the
-- new positions immediately (without it the sprites would lag the data
-- until the user clicked the group).
function M.group_set_pos(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_set_pos requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'group_set_pos requires exactly one of args.name or args.id' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'group_set_pos requires args.north and args.east (numbers, meters)' }
    end
    local g = find_group_in_mission(has_name and args.name or nil, has_id and args.id or nil)
    if not g then
        return { ok = false, error = 'group not found' }
    end

    -- mission-table fields: x = north, y = east
    local dx = args.north - (g.x or 0)
    local dy = args.east - (g.y or 0)

    g.x = args.north
    g.y = args.east

    for _, u in ipairs(g.units or {}) do
        u.x = (u.x or 0) + dx
        u.y = (u.y or 0) + dy
    end
    if g.route and type(g.route.points) == 'table' then
        for _, wpt in ipairs(g.route.points) do
            wpt.x = (wpt.x or 0) + dx
            wpt.y = (wpt.y or 0) + dy
        end
    end

    -- Refresh visual state so the ME view tracks the data move. Build map
    -- objects first if they're nil (disk-loaded groups have mapObjects=nil
    -- until selected; same defensive pattern as group_remove).
    local Mission = require('me_mission')
    if g.mapObjects == nil and type(Mission.create_group_map_objects) == 'function' then
        pcall(Mission.create_group_map_objects, g)
    end
    if type(Mission.update_group_map_objects) == 'function' then
        pcall(Mission.update_group_map_objects, g)
    end

    return { ok = true, id = g.groupId, name = g.name,
             north = g.x, east = g.y, delta = { north = dx, east = dy } }
end

-- group_set_formation — set the per-waypoint formation for a vehicle group.
--
-- Vehicle waypoints carry a "formation action" (wp.type, the action table
-- reference): one of Off Road / On Road / Rank / Cone / Vee / Diamond /
-- Echelon L / Echelon R / Custom. For Custom, wp.formation_template names
-- a DB.templates entry (e.g. "Hawk SAM Battery"). For built-ins, the
-- formation_template field is irrelevant and gets cleared so it doesn't
-- linger as stale state.
--
-- Vehicle groups only:
--   * plane / helicopter: formation is per-WrappedAction-task on the
--     waypoint, not via wp.type. Hidden from the route panel
--     (me_route.lua:2084: c_form_templ:setVisible(not isAirGroup)). A
--     future air-formation verb will do task surgery — out of scope here.
--   * ship: only the turningPoint action is valid (me_route.lua:204) —
--     formation actions don't apply.
--   * static: no route, no formations.
--
-- args:
--   name | id        group selector (mutually exclusive)
--   formation        formation name; built-in alias OR a DB.templates entry.
--                    Built-in aliases (case-insensitive, dash/space tolerant):
--                      off-road, on-road, rank, cone, vee, diamond,
--                      echelon-left (echelonl), echelon-right (echelonr),
--                      custom (just sets the action; no template name)
--                    Any other string is treated as a custom template name —
--                    must be a DB.templates key. Sets wp.type=actions.customForm
--                    AND wp.formation_template=<name>.
--   waypoint         1-indexed waypoint number (default 1)
function M.group_set_formation(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_set_formation requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'group_set_formation requires exactly one of args.name or args.id' }
    end
    if type(args.formation) ~= 'string' or args.formation == '' then
        return { ok = false, error = 'group_set_formation requires args.formation (non-empty string)' }
    end
    local g, _, _, cat = find_group_in_mission(has_name and args.name or nil,
                                                has_id and args.id or nil)
    if not g then
        return { ok = false, error = 'group not found' }
    end
    if cat ~= 'vehicle' then
        local why
        if cat == 'plane' or cat == 'helicopter' then
            why = ' — air-group formations are per-waypoint tasks, not yet exposed'
        elseif cat == 'ship' then
            why = ' — ship waypoints only support the turningPoint action'
        elseif cat == 'static' then
            why = ' — statics do not have a route'
        else
            why = ''
        end
        return { ok = false,
                 error = 'group_set_formation only applies to vehicle groups (got '
                         .. cat .. ')' .. why }
    end
    local wp_idx = (type(args.waypoint) == 'number') and args.waypoint or 1
    if wp_idx < 1 then
        return { ok = false, error = 'group_set_formation: args.waypoint must be >= 1' }
    end
    if not g.route or type(g.route.points) ~= 'table' or not g.route.points[wp_idx] then
        return { ok = false, error = 'group_set_formation: waypoint ' .. tostring(wp_idx) .. ' not found' }
    end

    -- Resolve formation name. Built-in aliases first; otherwise treat as a
    -- DB.templates name and require Custom action.
    local key = string.lower(args.formation):gsub('[%s_-]', '')
    local builtin_aliases = {
        offroad     = 'offRoad',
        onroad      = 'onRoad',
        rank        = 'rank',
        cone        = 'cone',
        vee         = 'vee',
        diamond     = 'diamond',
        echelonleft = 'echelonL',
        echelonl    = 'echelonL',
        echelonright= 'echelonR',
        echelonr    = 'echelonR',
        custom      = 'customForm',
        customform  = 'customForm',
    }
    local action_key = builtin_aliases[key]
    local UC = require('utils_common')
    if type(UC) ~= 'table' or type(UC.actions) ~= 'table' then
        return { ok = false, error = 'group_set_formation: utils_common.actions unavailable' }
    end
    local wp = g.route.points[wp_idx]
    local resolved_template = ''
    local resolved_action_name
    if action_key then
        wp.type = UC.actions[action_key]
        if action_key ~= 'customForm' then
            wp.formation_template = ''  -- clear stale Custom state
        else
            -- Custom alias without a template name keeps any existing template.
            resolved_template = wp.formation_template or ''
        end
        resolved_action_name = action_key
    else
        -- Treat as a DB.templates key — must exist, sets Custom + template.
        local ok_db, DB = pcall(require, 'me_db_api')
        local exists = ok_db and type(DB) == 'table' and type(DB.templates) == 'table'
                       and DB.templates[args.formation] ~= nil
        if not exists then
            return { ok = false,
                     error = 'group_set_formation: unknown formation "' .. args.formation
                             .. '" (not a built-in alias and not in DB.templates)' }
        end
        wp.type = UC.actions.customForm
        wp.formation_template = args.formation
        resolved_template = args.formation
        resolved_action_name = 'customForm'
    end

    return { ok = true, id = g.groupId, name = g.name,
             waypoint = wp_idx,
             action = resolved_action_name,
             formation_template = resolved_template }
end

-- group_set_country — change a group's country (and possibly coalition).
--
-- Replicates the data-side flow of me_aircraft.lua:1460 changeCountry.
-- ED's panel function does both the data mutation AND a pile of UI refreshes
-- (combo boxes, task list, callsign refresh, panel_loadout.update). Those
-- panels read from the mutated mission state when next opened, so we skip
-- them here — the mutation alone is enough for save-survival and runtime.
--
-- Steps:
--   1. resolve target country (must already exist in mission tree)
--   2. detect coalition change (side flip)
--   3. remove group from oldCountry[cat].group
--   4. update g.boss = newCountry, defensive newCountry.boss = side
--   5. insert into newCountry[cat].group (create sub-table if missing)
--   6. update g.color = newCountry.boss.color
--   7. fixup unit liveries via panel_payload.setDefaultLivery (air groups —
--      schemes are country-keyed, defaults differ per country)
--   8. re-attract first waypoint if it's a takeoff/landing airfield action
--      (the old airfield may not exist in the new coalition)
--   9. refresh map objects (color updates immediately)
--
-- ME does NOT refuse country changes that would make unit types invalid for
-- the new country (e.g. moving an Su-27 to USA). The unit type persists; the
-- livery list goes empty. Mirror that behavior — log a warning if liveries
-- come back empty but don't refuse.
--
-- args:
--   name | id  group selector (mutually exclusive)
--   country    target country name (case-insensitive)
function M.group_set_country(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_set_country requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'group_set_country requires exactly one of args.name or args.id' }
    end
    if type(args.country) ~= 'string' or args.country == '' then
        return { ok = false, error = 'group_set_country requires args.country (string)' }
    end
    local g, oldCountry, oldSide, cat = find_group_in_mission(
        has_name and args.name or nil, has_id and args.id or nil)
    if not g then
        return { ok = false, error = 'group not found' }
    end
    local newCountry, newSide = find_country_by_name(args.country)
    if not newCountry then
        return { ok = false,
                 error = 'group_set_country: country "' .. args.country .. '" not in mission tree' }
    end
    if newCountry == oldCountry then
        return { ok = true, id = g.groupId, name = g.name,
                 country = newCountry.name, side = newSide,
                 coalition_changed = false, no_op = true }
    end
    local coalition_changed = newSide ~= oldSide

    local Mission = require('me_mission')

    -- Step 3: remove from old country list.
    if oldCountry and oldCountry[cat] and type(oldCountry[cat].group) == 'table' then
        for i, v in ipairs(oldCountry[cat].group) do
            if v == g then
                table.remove(oldCountry[cat].group, i)
                break
            end
        end
    end

    -- Step 4: update boss back-reference + defensive country.boss = side.
    g.boss = newCountry
    if not newCountry.boss then
        local mission = Mission.mission or {}
        for sn, side in pairs(mission.coalition or {}) do
            if type(side) == 'table' and type(side.country) == 'table' then
                for _, c in ipairs(side.country) do
                    if c == newCountry then newCountry.boss = side; break end
                end
            end
            if newCountry.boss then break end
        end
    end

    -- Step 5: insert into new country list (create sub-table if missing).
    if type(newCountry[cat]) ~= 'table' then
        newCountry[cat] = { name = cat, group = {} }
    end
    if type(newCountry[cat].group) ~= 'table' then
        newCountry[cat].group = {}
    end
    table.insert(newCountry[cat].group, g)

    -- Step 6: color = new coalition color (via newCountry.boss.color).
    if newCountry.boss and newCountry.boss.color then
        g.color = newCountry.boss.color
    end

    -- Step 7: livery fixup (air groups — countries with non-overlapping
    -- airframe rosters end up with empty livery lists; that's fine, ME
    -- doesn't refuse it either).
    local empty_liveries = 0
    if cat == 'plane' or cat == 'helicopter' then
        local ok_pl, panel_payload = pcall(require, 'me_payload')
        if ok_pl and type(panel_payload) == 'table' and type(panel_payload.setDefaultLivery) == 'function' then
            for _, u in ipairs(g.units or {}) do
                pcall(panel_payload.setDefaultLivery, u)
                if u.livery_id == nil or u.livery_id == '' then
                    empty_liveries = empty_liveries + 1
                end
            end
        end
    end

    -- Step 8: airfield re-attract for takeoff/landing waypoints. Only
    -- meaningful for plane/helicopter groups.
    local airfield_reattracted = false
    if (cat == 'plane' or cat == 'helicopter')
            and g.route and type(g.route.points) == 'table' and g.route.points[1] then
        local ok_pr, panel_route = pcall(require, 'me_route')
        if ok_pr and type(panel_route) == 'table'
                and type(panel_route.isAirfieldWaypoint) == 'function'
                and type(panel_route.attractToAirfield) == 'function' then
            local wpt = g.route.points[1]
            if wpt.type and panel_route.isAirfieldWaypoint(wpt.type) then
                local ok_at, _ = pcall(panel_route.attractToAirfield, wpt, g)
                airfield_reattracted = ok_at
            end
        end
    end

    -- Step 9: refresh map objects (color update reflects immediately).
    refresh_group_view(g)

    return { ok = true, id = g.groupId, name = g.name,
             country = newCountry.name, side = newSide,
             previous_country = oldCountry and oldCountry.name,
             previous_side = oldSide,
             coalition_changed = coalition_changed,
             empty_liveries = empty_liveries,
             airfield_reattracted = airfield_reattracted }
end

-- ============================================================
-- Group list / get
-- ============================================================

-- group_list — return concise summaries of all groups, with optional filters.
--
-- args (all optional):
--   side:     "red" | "blue" | "neutrals"      (the mission table's key name)
--   country:  string  -- country name (case-insensitive exact match)
--   category: "plane"|"helicopter"|"vehicle"|"ship"|"static"
--   name:     string  -- case-insensitive substring match
--
-- Returns { ok = true, groups = [ ... summaries ... ], count = N }.
function M.group_list(args)
    args = args or {}
    local f_side = args.side and string.lower(args.side) or nil
    local f_country = args.country and string.lower(args.country) or nil
    local f_category = args.category and string.lower(args.category) or nil
    local f_name = args.name and string.lower(args.name) or nil

    local out = {}
    walk_groups(function(g, country, side_name, cat)
        if f_side and string.lower(side_name) ~= f_side then return end
        if f_country and string.lower(country.name or '') ~= f_country then return end
        if f_category and cat ~= f_category then return end
        if f_name and not string.find(string.lower(g.name or ''), f_name, 1, true) then return end
        local lat, lon = compute_lat_lon(g.x, g.y)
        table.insert(out, {
            id = g.groupId,
            name = g.name,
            category = cat,
            country = country.name,
            side = side_name,
            north = g.x,
            east = g.y,
            lat = lat,
            lon = lon,
            unit_count = g.units and #g.units or 0,
            hidden = g.hidden or false,
            task = g.task,
        })
    end)
    return { ok = true, groups = out, count = #out }
end

-- group_get — full mission-table snapshot of a single group, by name or id.
-- Strips boss / mapObjects (cycle-causing).
function M.group_get(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_get requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'group_get requires exactly one of args.name or args.id' }
    end
    local g, country, side_name, cat = find_group_in_mission(has_name and args.name or nil,
                                                              has_id and args.id or nil)
    if not g then
        return { ok = false, error = 'group not found' }
    end
    local snapshot = strip_back_refs(g)
    snapshot._side = side_name
    snapshot._country = country and country.name
    snapshot._category = cat
    -- Group position is mission-table x/y (x=north, y=east). Inject lat/lon
    -- alongside so callers don't need a follow-up `me coords to-geo` call.
    -- See GH#66 (request 4).
    local lat, lon = compute_lat_lon(g.x, g.y)
    if lat and lon then
        snapshot.lat = lat
        snapshot.lon = lon
    end
    return { ok = true, group = snapshot }
end

-- group_focus — programmatically replicate "user clicks the group icon
-- on the F10 map": pop the AIRPLANE GROUP / HELICOPTER GROUP info panel
-- (me_aircraft) on top and the route panel (me_route) underneath, both
-- populated with this group's data. Required after group-create verbs
-- because ED's ME never routes them through MapWindow's click handler —
-- the underlying data is correct but both right-side panels stay hidden
-- until the user clicks. Calling `me group focus --name X` after a
-- create lands the user in the same UI state a real map click would.
--
-- Only plane and helicopter groups raise the aircraft panel; ground and
-- ship groups have separate info panels (out of scope here). The route
-- panel pops for any group type that owns a route.
--
-- The panel raise sequence has to be exact:
--   1. me_aircraft.switchView(g.type) — but only when the current view
--      doesn't already match, because switchView clears vdata.type and a
--      subsequent show() would crash inside updateModulation
--      (DB.unit_by_type[nil]).
--   2. me_aircraft.setGroup(g)
--   3. me_aircraft.vdata.type = g.units[1].type — prime the unit ref so
--      update() can find a unit definition.
--   4. me_aircraft.show(true)
--   5. me_route.show(true) — independent of the aircraft panel.
function M.group_focus(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'group_focus requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'group_focus requires exactly one of args.name or args.id' }
    end
    local g = find_group_in_mission(has_name and args.name or nil,
                                     has_id  and args.id   or nil)
    if not g then
        return { ok = false, error = 'group not found' }
    end

    local raised = { aircraft = false, route = false }

    if g.type == 'plane' or g.type == 'helicopter' then
        pcall(function()
            local panel_aircraft = require('me_aircraft')
            if type(panel_aircraft.switchView) == 'function'
                    and panel_aircraft.__view__ ~= g.type then
                panel_aircraft.switchView(g.type)
            end
            if type(panel_aircraft.setGroup) == 'function' then
                panel_aircraft.setGroup(g)
            end
            if type(panel_aircraft.vdata) == 'table'
                    and type(g.units) == 'table'
                    and type(g.units[1]) == 'table'
                    and type(g.units[1].type) == 'string' then
                panel_aircraft.vdata.type = g.units[1].type
            end
            if type(panel_aircraft.show) == 'function' then
                panel_aircraft.show(true)
                raised.aircraft = panel_aircraft.isVisible
                                  and panel_aircraft.isVisible() or true
            end
        end)
    end

    pcall(function()
        local panel_route = require('me_route')
        if type(panel_route.show) == 'function' then
            panel_route.show(true)
            raised.route = panel_route.window
                           and panel_route.window:isVisible() or true
        end
    end)

    return { ok = true, name = g.name, id = g.groupId,
             type = g.type, task = g.task or '',
             raised = raised }
end

return M
