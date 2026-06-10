-- mock_me_mission.lua — synthetic stand-in for the ME's `me_mission` module.
-- Used by test_verbs_route.lua (and future verb test files per issue #55).
--
-- Usage in a test file:
--   package.preload['me_mission'] = function() return require('mock_me_mission') end
--   local mock = require('mock_me_mission')
--   mock.new_mission()
--   local g = mock.add_plane({ name = 'strike-1', country = 'USA' })
--
-- The module mutates its own `mission` field; verbs.lua's calls to
-- require('me_mission') will return THIS module, so `Mission.mission` is
-- our synthetic table.

local M = {}

-- Counters for recording verb-induced refresh calls. Tests reset these
-- via M.reset_refresh_counters().
M.refresh_calls = { create = 0, update = 0 }

function M.reset_refresh_counters()
    M.refresh_calls.create = 0
    M.refresh_calls.update = 0
end

function M.create_group_map_objects(g)
    M.refresh_calls.create = M.refresh_calls.create + 1
end

function M.update_group_map_objects(g)
    M.refresh_calls.update = M.refresh_calls.update + 1
end

-- new_mission — reset the synthetic mission table and the refresh counters.
-- Returns the freshly-built mission table for direct inspection.
function M.new_mission()
    M.reset_refresh_counters()
    M.mission = {
        coalition = {
            blue = {
                country = {
                    { id = 2, name = 'USA',
                      plane = { group = {} },
                      helicopter = { group = {} },
                      vehicle = { group = {} },
                      ship = { group = {} },
                      static = { group = {} } },
                    { id = 1, name = 'Germany',
                      plane = { group = {} },
                      helicopter = { group = {} },
                      vehicle = { group = {} },
                      ship = { group = {} },
                      static = { group = {} } },
                },
            },
            red = {
                country = {
                    { id = 0, name = 'Russia',
                      plane = { group = {} },
                      helicopter = { group = {} },
                      vehicle = { group = {} },
                      ship = { group = {} },
                      static = { group = {} } },
                    { id = 4, name = 'Iran',
                      plane = { group = {} },
                      helicopter = { group = {} },
                      vehicle = { group = {} },
                      ship = { group = {} },
                      static = { group = {} } },
                },
            },
            neutrals = {
                country = {
                    { id = 70, name = 'Switzerland',
                      plane = { group = {} },
                      helicopter = { group = {} },
                      vehicle = { group = {} },
                      ship = { group = {} },
                      static = { group = {} } },
                },
            },
        },
        triggers = { zones = {} },
        drawings = { layers = {} },
        trig = { actions = {}, conditions = {}, events = {}, custom = {},
                 flag = {}, func = {} },
        trigrules = {},
        groundControl = { passwords = {}, roles = {} },
        weather = {},
        date = { Day = 1, Month = 1, Year = 2025 },
        forcedOptions = {},
    }
    M._next_group_id = 1
    M._next_unit_id = 1000
    M.group_by_name = {}
    M.group_by_id = {}
    M.unit_by_name = {}
    M.unit_by_id = {}
    M.countryCoalition = {
        USA         = { color = { 0, 0, 1, 1 } },
        Germany     = { color = { 0, 0, 1, 1 } },
        Russia      = { color = { 1, 0, 0, 1 } },
        Iran        = { color = { 1, 0, 0, 1 } },
        Switzerland = { color = { 0.5, 0.5, 0.5, 1 } },
    }
    -- Mirror the real ME's Mission.missionCountry: country NAME → the same
    -- country table that lives under mission.coalition.<side>.country.
    -- resolve_country in prefab_ops walks this to inject groups.
    M.missionCountry = {}
    for _, side in pairs(M.mission.coalition) do
        for _, c in ipairs(side.country) do
            M.missionCountry[c.name] = c
        end
    end
    M.create_group_objects_calls = 0
    M.fixWaypointForGroup_calls = 0
    M.fixAddPropAircraft_calls = 0
    M.remove_group_calls = 0
    M.remove_unit_calls = 0
    return M.mission
end

local function next_group_id()
    local id = M._next_group_id
    M._next_group_id = (M._next_group_id or 1) + 1
    return id
end

-- Build the default waypoint for a category. Mirrors the
-- CATEGORY_DEFAULTS that verbs.lua uses, kept in sync by design.
local function default_wp(category, x, y)
    local profiles = {
        plane =      { alt = 8000, alt_type = 'BARO', speed = 220, action = 'Turning Point' },
        helicopter = { alt = 500,  alt_type = 'BARO', speed = 50,  action = 'Turning Point' },
        vehicle =    { alt = 0,    alt_type = 'BARO', speed = 8,   action = 'Off Road' },
        ship =       { alt = 0,    alt_type = 'BARO', speed = 5,   action = 'Turning Point' },
        static =     { alt = 0,    alt_type = 'BARO', speed = 0,   action = 'Off Road' },
    }
    local p = profiles[category] or profiles.vehicle
    return {
        x = x, y = y,
        alt = p.alt, alt_type = p.alt_type,
        speed = p.speed,
        action = p.action, type = 'Turning Point',
        ETA = 0, ETA_locked = true, speed_locked = true,
        formation_template = '', name = '',
        task = { id = 'ComboTask', params = { tasks = {} } },
    }
end

local function add_group(category, side, country_name, opts)
    opts = opts or {}
    local country
    for _, c in ipairs(M.mission.coalition[side].country) do
        if c.name == country_name then country = c; break end
    end
    assert(country, 'mock: country not found: ' .. tostring(country_name))
    local g = {
        name = opts.name or (category .. '-' .. next_group_id()),
        groupId = opts.groupId or next_group_id(),
        x = opts.x or 0, y = opts.y or 0,
        units = opts.units or {
            -- Use the unit-ID counter (separate from group-ID per real ME).
            -- Mixing them was a latent mock fidelity gap caught in review.
            { unitId = (M._next_unit_id and (function()
                  local id = M._next_unit_id; M._next_unit_id = id + 1; return id
              end)()) or next_group_id(),
              name = (opts.name or category) .. '-1',
              type = opts.unit_type or category, x = opts.x or 0, y = opts.y or 0 },
        },
        route = opts.route or {
            points = { default_wp(category, opts.x or 0, opts.y or 0) },
            routeRelativeTOT = false,
        },
        mapObjects = nil,
    }
    g.boss = country
    if not country.boss then country.boss = M.mission.coalition[side] end
    table.insert(country[category].group, g)
    -- Register in lookup tables so collision checks and rename/remove work.
    if M.group_by_name then M.group_by_name[g.name] = g end
    if M.group_by_id then M.group_by_id[g.groupId] = g end
    for i, u in ipairs(g.units) do
        u.boss = g
        u.index = i
        if M.unit_by_name then M.unit_by_name[u.name] = u end
        if M.unit_by_id then M.unit_by_id[u.unitId] = u end
    end
    return g
end

function M.add_plane(opts)      return add_group('plane',      opts and opts.side or 'blue', opts and opts.country or 'USA', opts) end
function M.add_helicopter(opts) return add_group('helicopter', opts and opts.side or 'blue', opts and opts.country or 'USA', opts) end
function M.add_vehicle(opts)    return add_group('vehicle',    opts and opts.side or 'blue', opts and opts.country or 'USA', opts) end
function M.add_ship(opts)       return add_group('ship',       opts and opts.side or 'blue', opts and opts.country or 'USA', opts) end
function M.add_static(opts)     return add_group('static',     opts and opts.side or 'blue', opts and opts.country or 'USA', opts) end

-- Build a single waypoint table suitable for splicing into a route's
-- points array. Used by tests that need multi-WP routes.
function M.make_waypoint(category, opts)
    opts = opts or {}
    local wp = default_wp(category, opts.x or 0, opts.y or 0)
    for k, v in pairs(opts) do
        if k ~= 'category' then wp[k] = v end
    end
    return wp
end

-- insert_waypoint — mock stand-in for me_mission.insert_waypoint. Mirrors the
-- data-side behavior of the real function (alt_type inherited from previous
-- WP, default locks per index, wpt.index assigned, route renumbered) without
-- the mapObjects manipulation the real ME does. Tests don't need symbol
-- creation; they assert against route.points directly.
function M.insert_waypoint(group, index, type, x, y, alt, speed, name, formation_template)
    local alt_type = 'BARO'
    if group.route.points[index - 1] then
        alt_type = group.route.points[index - 1].alt_type or 'BARO'
    end
    local speed_locked = true
    local ETA_locked = (index == 1) and true or false
    local ETA = (index == 1) and 0.0 or 0
    local wpt = {
        boss = group,
        index = index,
        type = type,
        x = x, y = y,
        alt = alt or 0,
        alt_type = alt_type,
        speed = speed or 0,
        speed_locked = speed_locked,
        ETA = ETA,
        ETA_locked = ETA_locked,
        targets = {},
        formation_template = formation_template or '',
        name = name or '',
    }
    table.insert(group.route.points, index, wpt)
    for i = index + 1, #group.route.points do
        group.route.points[i].index = i
    end
    return wpt
end

-- remove_waypoint — mock stand-in for me_mission.remove_waypoint. Removes
-- from route.points and renumbers. Skips the symbol/task-back-reference
-- cleanup the real ME does.
function M.remove_waypoint(group, index)
    table.remove(group.route.points, index)
    for i = 1, #group.route.points do
        group.route.points[i].index = i
    end
end

-- move_waypoint — mock stand-in for MapWindow.move_waypoint. Updates the
-- data side: wpt.x/wpt.y and vehicle route.spans. Real ME also moves map
-- symbols, number labels, child units, etc. — tests only care about data.
-- Same module is registered as both 'me_mission' and 'me_map_window' via
-- package.preload in test_verbs_route.lua, so require('me_map_window')
-- inside verbs.lua resolves to this table.
-- ============================================================
-- inject_group / group-create plumbing
-- ============================================================

function M.getNewGroupId()
    M._next_group_id = (M._next_group_id or 1) + 1
    return M._next_group_id - 1
end

function M.getNewUnitId()
    M._next_unit_id = (M._next_unit_id or 1000) + 1
    return M._next_unit_id - 1
end

-- check_group_name — return the input name unless taken, in which case
-- append " #2" / " #3" / ... until a free slot is found.
function M.check_group_name(name)
    if not M.group_by_name or not M.group_by_name[name] then return name end
    local i = 2
    while M.group_by_name[name .. ' #' .. i] do i = i + 1 end
    return name .. ' #' .. i
end

-- getUnitName — return a free unit name derived from `seed`. The real ME
-- returns `seed` itself when free, and uniquifies via the "<base>-<N>" suffix
-- pattern only on collision. Mock mirrors that: free seed → returned as-is;
-- taken seed with "-N" tail → increment N; otherwise append "-2/-3/...".
function M.getUnitName(seed)
    M.unit_by_name = M.unit_by_name or {}
    if seed and not M.unit_by_name[seed] then return seed end
    local base, n = string.match(seed or '', '^(.-)-(%d+)$')
    if base then
        local i = tonumber(n) + 1
        while M.unit_by_name[base .. '-' .. i] do i = i + 1 end
        return base .. '-' .. i
    end
    local i = 2
    while M.unit_by_name[(seed or 'unit') .. '-' .. i] do i = i + 1 end
    return (seed or 'unit') .. '-' .. i
end

function M.create_group_objects(g)
    M.create_group_objects_calls = (M.create_group_objects_calls or 0) + 1
    g.mapObjects = g.mapObjects or { units = {}, zones = {}, route = {} }
end

function M.fixAddPropAircraft()
    M.fixAddPropAircraft_calls = (M.fixAddPropAircraft_calls or 0) + 1
end

function M.fixWaypointForGroup(g)
    M.fixWaypointForGroup_calls = (M.fixWaypointForGroup_calls or 0) + 1
end

-- insert_unit(group, utype, skill, index, seed_name, x, y, heading, _, livery)
-- Creates a fresh unit table, inserts it at g.units[index], returns the unit.
-- Mirrors Mission.insert_unit's data-side behavior (the real impl also draws
-- the symbol, allocates a callsign, etc. — the mock skips those).
function M.insert_unit(group, utype, skill, index, seed_name, x, y, heading_rad, _arg9, livery)
    local name = M.getUnitName(seed_name or group.name)
    -- Default offset matches the real ME's 40m spread when x/y are nil.
    local cum_x, cum_y = nil, nil
    if x == nil or y == nil then
        cum_x = group.x + ((index - 1) * 40)
        cum_y = group.y + ((index - 1) * 40)
    end
    local u = {
        unitId = M.getNewUnitId(),
        name = name,
        type = utype,
        skill = skill or 'Average',
        livery_id = livery or '',
        x = x or cum_x,
        y = y or cum_y,
        heading = heading_rad or 0,
        psi = 0,
        index = index,
        boss = group,
    }
    table.insert(group.units, u)
    -- Re-index any subsequent units (insert_unit is always-append in the
    -- ME so this is a no-op in practice, but kept defensive).
    for i, gu in ipairs(group.units) do gu.index = i end
    if M.unit_by_name then M.unit_by_name[u.name] = u end
    if M.unit_by_id then M.unit_by_id[u.unitId] = u end
    return u
end

-- Walk the coalition tree and run callback(g, country, side, cat) for every
-- group. Internal helper for remove_*. Stops if callback returns true.
local function _walk_all_groups(callback)
    if not M.mission or not M.mission.coalition then return end
    for side_name, side in pairs(M.mission.coalition) do
        if type(side) == 'table' and type(side.country) == 'table' then
            for _, country in ipairs(side.country) do
                for _, cat in ipairs({'plane','helicopter','vehicle','ship','static'}) do
                    if country[cat] and type(country[cat].group) == 'table' then
                        for _, g in ipairs(country[cat].group) do
                            if callback(g, country, side_name, cat) then return end
                        end
                    end
                end
            end
        end
    end
end

function M.remove_unit(u)
    _walk_all_groups(function(g, country, side, cat)
        for i, gu in ipairs(g.units or {}) do
            if gu == u then
                table.remove(g.units, i)
                for j, gu2 in ipairs(g.units) do gu2.index = j end
                if M.unit_by_name then M.unit_by_name[u.name] = nil end
                if M.unit_by_id then M.unit_by_id[u.unitId] = nil end
                M.remove_unit_calls = (M.remove_unit_calls or 0) + 1
                return true
            end
        end
    end)
end

function M.remove_group(g)
    _walk_all_groups(function(gg, country, side, cat)
        if gg == g then
            for i, x in ipairs(country[cat].group) do
                if x == g then table.remove(country[cat].group, i); break end
            end
            if M.group_by_name then M.group_by_name[g.name] = nil end
            if M.group_by_id then M.group_by_id[g.groupId] = nil end
            for _, u in ipairs(g.units or {}) do
                if M.unit_by_name then M.unit_by_name[u.name] = nil end
                if M.unit_by_id then M.unit_by_id[u.unitId] = nil end
            end
            M.remove_group_calls = (M.remove_group_calls or 0) + 1
            return true
        end
    end)
end

-- renameGroup(g, new_name) → true on success, false if name taken.
function M.renameGroup(g, new_name)
    if M.group_by_name and M.group_by_name[new_name] and M.group_by_name[new_name] ~= g then
        return false
    end
    if M.group_by_name then
        M.group_by_name[g.name] = nil
        M.group_by_name[new_name] = g
    end
    g.name = new_name
    return true
end

-- renameUnit(u, new_name) → true on success, false if name taken.
function M.renameUnit(u, new_name)
    if M.unit_by_name and M.unit_by_name[new_name] and M.unit_by_name[new_name] ~= u then
        return false
    end
    if M.unit_by_name then
        M.unit_by_name[u.name] = nil
        M.unit_by_name[new_name] = u
    end
    u.name = new_name
    return true
end

-- move_unit(group, unit, x, y, doNotRedraw, noCheckSurface) — data-side only.
function M.move_unit(group, unit, x, y, _doNotRedraw, _noCheckSurface)
    unit.x = x
    unit.y = y
end

-- ============================================================
-- Waypoint plumbing (used by route_verbs.lua tests)
-- ============================================================

function M.move_waypoint(group, index, x, y, dontMoveLinked, doNotUpdateRoute, dontMoveChild, dontRelativePos, noCheckSurface)
    local wpt = group.route.points[index]
    if not wpt then return end
    wpt.x = x
    wpt.y = y
    if group.route.spans and #group.route.spans > 0 then
        local spans = group.route.spans
        if index > 1 then
            local p = group.route.points[index - 1]
            spans[index - 1] = { { x = p.x, y = p.y }, { x = x, y = y } }
        end
        if index < #group.route.points then
            local p = group.route.points[index + 1]
            spans[index] = { { x = x, y = y }, { x = p.x, y = p.y } }
        end
        if index == #group.route.points then
            spans[index] = { { x = x, y = y }, { x = x, y = y } }
        end
    end
end

return M
