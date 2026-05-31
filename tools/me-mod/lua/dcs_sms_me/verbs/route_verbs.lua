-- dcs_sms_me/verbs/route_verbs.lua — route + waypoint verbs, plus unit_set_parking.
--
-- Verbs: route_list, route_get, route_clear, waypoint_add, waypoint_insert,
-- waypoint_remove, waypoint_get, waypoint_set_<pos|alt|speed|type|action|name|
-- eta|speed_locked|eta_locked|mode|formation>, waypoint_link_airbase,
-- unit_set_parking.
--
-- See dcs_sms_me/verbs.lua for the aggregator and the verb-naming convention.
--
-- unit_set_parking is included here (rather than in unit_verbs.lua) because
-- it reaches into the route-block locals AIRFIELD_TYPES, ensure_map_objects,
-- and refresh_route_panel plus the airbase-by-name lookup — co-locating it
-- here keeps the dependency graph local rather than threading the helpers
-- through verb_helpers.lua. Same trade-off the original verbs.lua made when
-- it placed `unit_set_parking` after the route block.

local M = {}

local H = require('dcs_sms_me.verb_helpers')
local strip_back_refs       = H.strip_back_refs
local refresh_group_view    = H.refresh_group_view
local find_unit_in_mission  = H.find_unit_in_mission
local find_group_in_mission = H.find_group_in_mission
local find_airbase_by_name  = H.find_airbase_by_name
local new_combo_task        = H.new_combo_task

local task_db = require('dcs_sms_me.task_db')

-- ============================================================
-- Route / waypoint geometry verbs
-- ============================================================
--
-- Verb surface (18 total):
--   route_list / route_get / route_clear              -- whole-route
--   waypoint_add / waypoint_insert / waypoint_remove  -- array shape
--   waypoint_get                                       -- single read
--   waypoint_set_pos / set_alt / set_speed / set_type
--   waypoint_set_action / set_name / set_eta
--   waypoint_set_speed_locked / set_eta_locked
--   waypoint_set_formation                             -- per-field
--
-- Index convention: 0-based on the wire (matches ME UI display);
-- 1-based in Lua (native ipairs). Translation happens in find_waypoint.
--
-- Task preservation: every write verb leaves per-WP `task` tables
-- untouched. Inheritance never copies tasks — new WPs always get
-- new_combo_task().
--
-- Spec: docs/superpowers/specs/2026-05-11-me-route-geometry.md

local CATEGORY_DEFAULTS = {
    plane =      { alt = 8000, alt_type = 'BARO', speed = 220, type = 'Turning Point', action = 'Turning Point' },
    helicopter = { alt = 500,  alt_type = 'BARO', speed = 50,  type = 'Turning Point', action = 'Turning Point' },
    vehicle =    { alt = 0,    alt_type = 'BARO', speed = 8,   type = 'Turning Point', action = 'Off Road' },
    ship =       { alt = 0,    alt_type = 'BARO', speed = 5,   type = 'Turning Point', action = 'Turning Point' },
    train =      { alt = 0,    alt_type = 'BARO', speed = 14,  type = 'Turning Point', action = 'On Road' },
    static =     { alt = 0,    alt_type = 'BARO', speed = 0,   type = 'Turning Point', action = 'Off Road' },
}

-- Enum validation tables. Mirror framework/constants/waypoint.lua +
-- framework/alt_type.lua. The duplication is intentional: bridge runs in
-- ME's Lua state, framework in mission env — no shared runtime.
--
-- Canonical reference: DCS's own actions table at
-- Scripts/utils_common.lua, where each ME UI mode declares its
-- (type, action) pair. Notable: ground/ship formations (Cone, Vee,
-- Diamond, Rank, Echelon*, Custom, Off Road, On Road) all live in
-- ACTION, with TYPE always "Turning Point". The ME UI mis-labels its
-- column as "TYPE" for these, but the .miz stores them in action.
local WAYPOINT_TYPES = {
    ['Turning Point'] = true,    -- turning-point + every ground-formation mode
    ['TakeOff'] = true,          -- runway takeoff
    ['TakeOffParking'] = true,   -- cold parking-spot takeoff
    ['TakeOffParkingHot'] = true,
    ['TakeOffGround'] = true,    -- ground (FOB) takeoff, cold
    ['TakeOffGroundHot'] = true,
    ['Land'] = true,             -- landing
    ['LandingReFuAr'] = true,    -- landing → refuel/rearm → continue
    ['On Railroads'] = true,     -- trains
}

-- Airfield-linked types — these store an airdromeId / helipadId /
-- grassAirfieldId on the waypoint. Changing AWAY from one of these
-- requires clearing those fields, mirroring setWPTppmDefault in
-- me_route.lua (line 721-734); leaving them set would conflict with
-- the new type at mission load.
local AIRFIELD_TYPES = {
    ['TakeOff'] = true,            ['TakeOffParking'] = true,
    ['TakeOffParkingHot'] = true,  ['TakeOffGround'] = true,
    ['TakeOffGroundHot'] = true,   ['Land'] = true,
    ['LandingReFuAr'] = true,
}

local WAYPOINT_ACTIONS = {
    -- Air actions
    ['Turning Point'] = true,        ['Fly Over Point'] = true,
    ['From Parking Area'] = true,    ['From Parking Area Hot'] = true,
    ['From Ground Area'] = true,     ['From Ground Area Hot'] = true,
    ['From Runway'] = true,          ['Landing'] = true,
    ['LandingReFuAr'] = true,
    -- Ground/ship traversal + formations
    ['Off Road'] = true,             ['On Road'] = true,
    ['Rank'] = true,                 ['Cone'] = true,
    ['Vee'] = true,                  ['Diamond'] = true,
    ['EchelonL'] = true,             ['EchelonR'] = true,
    ['Custom'] = true,               -- references wpt.formation_template by name
    ['On Railroads'] = true,         -- trains
}

local ALT_TYPES = { BARO = true, RADIO = true }

-- WAYPOINT_MODES — maps ME UI picker labels (lowercased) to the canonical
-- (type, action) pair the .miz format stores PLUS the panel_route.actions
-- table key. At runtime the route panel keeps wpt.type as a TABLE
-- reference into panel_route.actions (e.g. actions.takeoffRunway), not a
-- string — its setTypeWpt iterates combo items comparing item:getText()
-- to wpt.type.name, so a bare string assignment causes the panel to
-- silently fall back to actions.turningPoint on its next refresh.
-- set-mode looks up the matching actions table entry by key and uses
-- that reference for wpt.type, with a string fallback for standalone /
-- test contexts where panel_route isn't loaded. Source: DCS's own
-- Scripts/utils_common.lua actions table.
local WAYPOINT_MODES = {
    ['turning point']            = { key = 'turningPoint',     type = 'Turning Point',     action = 'Turning Point' },
    ['fly over point']           = { key = 'flyOverPoint',     type = 'Turning Point',     action = 'Fly Over Point' },
    ['takeoff from runway']      = { key = 'takeoffRunway',    type = 'TakeOff',           action = 'From Runway' },
    ['takeoff from parking']     = { key = 'takeoffParking',   type = 'TakeOffParking',    action = 'From Parking Area' },
    ['takeoff from parking hot'] = { key = 'takeoffParkingHot',type = 'TakeOffParkingHot', action = 'From Parking Area Hot' },
    ['takeoff from ground']      = { key = 'takeoffGround',    type = 'TakeOffGround',     action = 'From Ground Area' },
    ['takeoff from ground hot']  = { key = 'takeoffGroundHot', type = 'TakeOffGroundHot',  action = 'From Ground Area Hot' },
    ['landing']                  = { key = 'landing',          type = 'Land',              action = 'Landing' },
    ['landingrefuar']            = { key = 'LandingReFuAr',    type = 'LandingReFuAr',     action = 'LandingReFuAr' },
    ['offroad']                  = { key = 'offRoad',          type = 'Turning Point',     action = 'Off Road' },
    ['off road']                 = { key = 'offRoad',          type = 'Turning Point',     action = 'Off Road' },
    ['on road']                  = { key = 'onRoad',           type = 'Turning Point',     action = 'On Road' },
    ['rank']                     = { key = 'rank',             type = 'Turning Point',     action = 'Rank' },
    ['line abreast']             = { key = 'rank',             type = 'Turning Point',     action = 'Rank' },
    ['cone']                     = { key = 'cone',             type = 'Turning Point',     action = 'Cone' },
    ['vee']                      = { key = 'vee',              type = 'Turning Point',     action = 'Vee' },
    ['diamond']                  = { key = 'diamond',          type = 'Turning Point',     action = 'Diamond' },
    ['echelon left']             = { key = 'echelonL',         type = 'Turning Point',     action = 'EchelonL' },
    ['echelon right']            = { key = 'echelonR',         type = 'Turning Point',     action = 'EchelonR' },
    ['custom']                   = { key = 'customForm',       type = 'Turning Point',     action = 'Custom' },
    ['on railroads']             = { key = 'onRailroads',      type = 'On Railroads',      action = 'On Railroads' },
}

-- ACTION_AIRFIELD_TYPE — the subset of WAYPOINT_ACTIONS that imply an
-- airfield-linked TYPE. Picking one of these actions in ED's route panel
-- flips the paired waypoint type (e.g. "From Parking Area" → TakeOffParking).
-- set-action consults this so the type tracks the action the way the GUI
-- does; actions absent here are non-airfield (Turning Point, Fly Over Point,
-- ground/ship traversal, formations) and leave the type alone. The
-- (action → type, panel-actions key) pairing mirrors WAYPOINT_MODES above.
-- gh #68 item 4: set-action "From Parking Area" used to leave the type at
-- "Turning Point", producing an invalid parking-start waypoint.
local ACTION_AIRFIELD_TYPE = {
    ['From Runway']           = { type = 'TakeOff',           key = 'takeoffRunway' },
    ['From Parking Area']     = { type = 'TakeOffParking',    key = 'takeoffParking' },
    ['From Parking Area Hot'] = { type = 'TakeOffParkingHot', key = 'takeoffParkingHot' },
    ['From Ground Area']      = { type = 'TakeOffGround',     key = 'takeoffGround' },
    ['From Ground Area Hot']  = { type = 'TakeOffGroundHot',  key = 'takeoffGroundHot' },
    ['Landing']               = { type = 'Land',              key = 'landing' },
    ['LandingReFuAr']         = { type = 'LandingReFuAr',     key = 'LandingReFuAr' },
}

-- resolve_action_entry — look up panel_route.actions[key] (the runtime
-- table reference the route panel uses for wpt.type). Returns nil if
-- panel_route isn't loaded — e.g. in unit tests — letting callers fall
-- back to the string type/action representation.
local function resolve_action_entry(key)
    local entry
    pcall(function()
        local panel_route = require('me_route')
        if panel_route and type(panel_route.actions) == 'table' then
            entry = panel_route.actions[key]
        end
    end)
    return entry
end

-- refresh_route_panel — re-render the right-side Route panel (waypoint
-- dropdown + selected-WP fields) AND the per-waypoint actions listbox
-- (the task list inside the panel). Required after any route mutation —
-- update_group_map_objects only repaints the map layer; the route panel
-- caches its display state separately and won't pick up new/removed/
-- renamed waypoints without an explicit panel_route.update() call, and
-- the task listbox is a sibling widget that update() doesn't cascade
-- into — without actionsListBox:update(true) a freshly added/removed
-- task stays invisible until the user clicks the WP again.
--
-- The optional `g` argument is currently unused (kept on the signature
-- for forward compatibility); the AIRPLANE GROUP / VEHICLE GROUP info
-- panel does NOT auto-raise after a route mutation. Programmatically
-- created groups (`me group create-plane`, …) never go through ED's
-- MapWindow selection path, and trying to force the aircraft panel up
-- here turned out to require setGroup + vdata.type priming + show +
-- skipping switchView when view already matches — and even then the
-- listbox state didn't survive a subsequent user click, so the user
-- still saw an empty Advanced Waypoint Actions section. Tracking that
-- separately; for now we keep refresh_route_panel narrow.
--
-- Safe no-op if me_route isn't available (defensive — same posture as
-- refresh_group_view's pcall on update_group_map_objects).
local function refresh_route_panel(g)
    pcall(function()
        local panel_route = require('me_route')
        if type(panel_route.update) == 'function' then
            panel_route.update()
        end
        if type(panel_route.actionsListBox) == 'table'
                and type(panel_route.actionsListBox.update) == 'function' then
            panel_route.actionsListBox:update(true)
        end
    end)
end

-- ensure_map_objects — guarantee g.mapObjects is populated. ME-native
-- insert_waypoint / remove_waypoint reach into g.mapObjects.route.{points,
-- numbers, targets, ...} unconditionally, so they crash if the group was
-- never visually rendered. create_group_map_objects(g, true) is idempotent
-- in the sense that calling it on a group with existing mapObjects orphans
-- the old symbols in MapWindow; we only call it when truly absent.
local function ensure_map_objects(g)
    if g.mapObjects and g.mapObjects.route then return end
    pcall(function()
        local Mission = require('me_mission')
        if type(Mission.create_group_map_objects) == 'function' then
            Mission.create_group_map_objects(g, true)
        end
    end)
end

-- find_route — locate a group by name or id, return its route table.
-- Ensures route.points exists (defensive; ME-created groups always have one).
-- Returns (route, group, category, nil) on success, (nil, nil, nil, err) otherwise.
local function find_route(by_name, by_id)
    local g, _, _, cat = find_group_in_mission(by_name, by_id)
    if not g then
        local ident = by_name and ("'" .. tostring(by_name) .. "'") or tostring(by_id)
        return nil, nil, nil, 'group not found: ' .. ident
    end
    g.route = g.route or { points = {}, routeRelativeTOT = false }
    g.route.points = g.route.points or {}
    return g.route, g, cat, nil
end

-- find_waypoint — locate the waypoint at wire-index N (0-based) inside a
-- group's route. Returns (waypoint, route, group, category, nil) on success.
-- On failure: (nil, nil, nil, nil, err).
local function find_waypoint(by_name, by_id, wire_index)
    local route, g, cat, err = find_route(by_name, by_id)
    if not route then return nil, nil, nil, nil, err end
    if type(wire_index) ~= 'number' or wire_index < 0
            or wire_index ~= math.floor(wire_index) then
        return nil, nil, nil, nil, 'index must be an integer >= 0'
    end
    local lua_idx = wire_index + 1
    local wp = route.points[lua_idx]
    if not wp then
        return nil, nil, nil, nil, string.format(
            'waypoint index %d out of range (route has %d points)',
            wire_index, #route.points)
    end
    return wp, route, g, cat, nil
end

-- inherit_waypoint — build a new waypoint from source + overrides + category
-- defaults. source may be nil (empty-route case). Task is ALWAYS an empty
-- ComboTask; name is ALWAYS '' unless overridden; ETA is ALWAYS 0 unless
-- overridden.
local function inherit_waypoint(source, overrides, category)
    local cat_defaults = CATEGORY_DEFAULTS[category] or CATEGORY_DEFAULTS.vehicle
    local wp = {
        x = 0, y = 0,
        alt = cat_defaults.alt,
        alt_type = cat_defaults.alt_type,
        speed = cat_defaults.speed,
        type = cat_defaults.type,
        action = cat_defaults.action,
        speed_locked = true,
        ETA_locked = true,
        formation_template = '',
        ETA = 0,
        name = '',
        task = new_combo_task(),
    }
    if source then
        local inherit_fields = { 'alt', 'alt_type', 'speed', 'type', 'action',
                                 'speed_locked', 'ETA_locked', 'formation_template' }
        for _, k in ipairs(inherit_fields) do
            if source[k] ~= nil then wp[k] = source[k] end
        end
    end
    if overrides then
        for k, v in pairs(overrides) do
            if v ~= nil then wp[k] = v end
        end
    end
    -- Always-empty task, regardless of overrides.
    wp.task = new_combo_task()
    return wp
end

function M.route_list(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'route_list requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'route_list requires exactly one of args.name or args.id' }
    end
    local route, g, _, err = find_route(has_name and args.name or nil,
                                        has_id and args.id or nil)
    if not route then return { ok = false, error = err } end
    local points = {}
    for i, wp in ipairs(route.points) do
        points[i] = {
            index = i - 1, type = wp.type, action = wp.action,
            north = wp.x, east = wp.y, alt = wp.alt, alt_type = wp.alt_type,
            speed = wp.speed, name = wp.name or '', eta = wp.ETA or 0,
            has_task = (wp.task and wp.task.params and wp.task.params.tasks
                        and #wp.task.params.tasks > 0) or false,
        }
    end
    return { ok = true, group = g.name,
             route_relative_tot = route.routeRelativeTOT and true or false,
             points = points }
end

function M.waypoint_get(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'waypoint_get requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'waypoint_get requires exactly one of args.name or args.id' }
    end
    if type(args.index) ~= 'number' then
        return { ok = false, error = 'waypoint_get requires args.index (integer >= 0)' }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil,
                                           has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    return { ok = true, group = g.name, index = args.index,
             waypoint = strip_back_refs(wp) }
end

function M.waypoint_add(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'waypoint_add requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'waypoint_add requires exactly one of args.name or args.id' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'waypoint_add requires args.north and args.east (numbers, meters)' }
    end
    local route, g, cat, err = find_route(has_name and args.name or nil,
                                          has_id and args.id or nil)
    if not route then return { ok = false, error = err } end
    -- enum validations (only for fields actually passed)
    if args.type ~= nil and not WAYPOINT_TYPES[args.type] then
        return { ok = false, error = "unknown waypoint type '" .. tostring(args.type) .. "'" }
    end
    if args.action ~= nil and not WAYPOINT_ACTIONS[args.action] then
        return { ok = false, error = "unknown waypoint action '" .. tostring(args.action) .. "'" }
    end
    if args.alt_type ~= nil and not ALT_TYPES[args.alt_type] then
        return { ok = false, error = "alt_type must be 'BARO' or 'RADIO'" }
    end
    if args.alt ~= nil and (type(args.alt) ~= 'number' or args.alt < 0) then
        return { ok = false, error = 'alt must be >= 0' }
    end
    if args.speed ~= nil and (type(args.speed) ~= 'number' or args.speed <= 0) then
        return { ok = false, error = 'speed must be > 0' }
    end
    if args.eta ~= nil and (type(args.eta) ~= 'number' or args.eta < 0) then
        return { ok = false, error = 'eta must be >= 0' }
    end
    -- Inheritance source = last WP (nil if route is empty).
    local source = route.points[#route.points]
    local cat_defaults = CATEGORY_DEFAULTS[cat] or CATEGORY_DEFAULTS.vehicle
    -- Compute the parameters Mission.insert_waypoint takes. It inherits
    -- alt_type internally but takes everything else from us.
    local alt = args.alt or (source and source.alt) or cat_defaults.alt
    local speed = args.speed or (source and source.speed) or cat_defaults.speed
    local type_str = args.type or (source and source.type) or cat_defaults.type
    local name_text = args.name_text or ''
    local formation_template = args.formation_template
            or (source and source.formation_template) or ''
    -- Delegate to ME-native insert_waypoint so we get the waypoint icon,
    -- numbered label, target array slots, and label renumbering for free.
    ensure_map_objects(g)
    local Mission = require('me_mission')
    local insert_idx = #route.points + 1
    local ok, wpt_or_err = pcall(Mission.insert_waypoint, g, insert_idx,
            type_str, args.north, args.east, alt, speed, name_text, formation_template)
    if not ok or type(wpt_or_err) ~= 'table' then
        return { ok = false, error = 'insert_waypoint failed: ' .. tostring(wpt_or_err) }
    end
    local new_wp = wpt_or_err
    -- Post-process: fields insert_waypoint doesn't set + caller overrides.
    new_wp.action = args.action or (source and source.action) or cat_defaults.action
    if args.alt_type ~= nil then new_wp.alt_type = args.alt_type end
    if args.eta ~= nil then new_wp.ETA = args.eta
    elseif new_wp.ETA == nil then new_wp.ETA = 0 end
    if args.speed_locked ~= nil then new_wp.speed_locked = args.speed_locked end
    if args.eta_locked ~= nil then new_wp.ETA_locked = args.eta_locked end
    new_wp.task = new_combo_task()
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = new_wp.index - 1,
             waypoint = strip_back_refs(new_wp) }
end

function M.waypoint_insert(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'waypoint_insert requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'waypoint_insert requires exactly one of args.name or args.id' }
    end
    if type(args.before) ~= 'number' or args.before < 0
            or args.before ~= math.floor(args.before) then
        return { ok = false, error = 'waypoint_insert requires args.before (integer >= 0)' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'waypoint_insert requires args.north and args.east (numbers, meters)' }
    end
    local route, g, cat, err = find_route(has_name and args.name or nil,
                                          has_id and args.id or nil)
    if not route then return { ok = false, error = err } end
    if args.before > #route.points then
        return { ok = false, error = string.format(
            'insert index %d out of range (route has %d points; legal range 0..%d)',
            args.before, #route.points, #route.points) }
    end
    -- Enum + numeric validation (mirror waypoint_add)
    if args.type ~= nil and not WAYPOINT_TYPES[args.type] then
        return { ok = false, error = "unknown waypoint type '" .. tostring(args.type) .. "'" }
    end
    if args.action ~= nil and not WAYPOINT_ACTIONS[args.action] then
        return { ok = false, error = "unknown waypoint action '" .. tostring(args.action) .. "'" }
    end
    if args.alt_type ~= nil and not ALT_TYPES[args.alt_type] then
        return { ok = false, error = "alt_type must be 'BARO' or 'RADIO'" }
    end
    if args.alt ~= nil and (type(args.alt) ~= 'number' or args.alt < 0) then
        return { ok = false, error = 'alt must be >= 0' }
    end
    if args.speed ~= nil and (type(args.speed) ~= 'number' or args.speed <= 0) then
        return { ok = false, error = 'speed must be > 0' }
    end
    if args.eta ~= nil and (type(args.eta) ~= 'number' or args.eta < 0) then
        return { ok = false, error = 'eta must be >= 0' }
    end
    -- Inheritance source: WP at index `before-1` (Lua index `before`). For
    -- before=0 the source is the WP currently at index 0 (Lua index 1).
    local source_lua_idx = math.max(args.before, 1)
    local source = route.points[source_lua_idx]
    local cat_defaults = CATEGORY_DEFAULTS[cat] or CATEGORY_DEFAULTS.vehicle
    local alt = args.alt or (source and source.alt) or cat_defaults.alt
    local speed = args.speed or (source and source.speed) or cat_defaults.speed
    local type_str = args.type or (source and source.type) or cat_defaults.type
    local name_text = args.name_text or ''
    local formation_template = args.formation_template
            or (source and source.formation_template) or ''
    -- Delegate to ME-native insert_waypoint. Lua index for "before wire N"
    -- is N+1 (so before=0 → insert at Lua 1).
    ensure_map_objects(g)
    local Mission = require('me_mission')
    local insert_idx = args.before + 1
    local ok, wpt_or_err = pcall(Mission.insert_waypoint, g, insert_idx,
            type_str, args.north, args.east, alt, speed, name_text, formation_template)
    if not ok or type(wpt_or_err) ~= 'table' then
        return { ok = false, error = 'insert_waypoint failed: ' .. tostring(wpt_or_err) }
    end
    local new_wp = wpt_or_err
    new_wp.action = args.action or (source and source.action) or cat_defaults.action
    if args.alt_type ~= nil then new_wp.alt_type = args.alt_type end
    if args.eta ~= nil then new_wp.ETA = args.eta
    elseif new_wp.ETA == nil then new_wp.ETA = 0 end
    if args.speed_locked ~= nil then new_wp.speed_locked = args.speed_locked end
    if args.eta_locked ~= nil then new_wp.ETA_locked = args.eta_locked end
    new_wp.task = new_combo_task()
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.before,
             waypoint = strip_back_refs(new_wp) }
end

function M.waypoint_remove(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'waypoint_remove requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'waypoint_remove requires exactly one of args.name or args.id' }
    end
    if type(args.index) ~= 'number' then
        return { ok = false, error = 'waypoint_remove requires args.index (integer >= 0)' }
    end
    local wp, route, g, cat, err = find_waypoint(has_name and args.name or nil,
                                                  has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    if (cat == 'plane' or cat == 'helicopter') and #route.points == 1 then
        return { ok = false,
                 error = "cannot remove last waypoint on air group '" .. g.name
                         .. "'; use waypoint set-pos to reposition" }
    end
    -- Delegate to ME-native remove_waypoint so the map symbol, label,
    -- target arrays, task back-references on other groups, and route line
    -- all get cleaned up in lockstep with route.points.
    ensure_map_objects(g)
    local Mission = require('me_mission')
    local ok, err_rm = pcall(Mission.remove_waypoint, g, args.index + 1)
    if not ok then
        return { ok = false, error = 'remove_waypoint failed: ' .. tostring(err_rm) }
    end
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, removed_index = args.index,
             remaining = #route.points }
end

function M.waypoint_set_pos(args)
    if type(args) ~= 'table' then return { ok = false, error = 'waypoint_set_pos requires args (table)' } end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then return { ok = false, error = 'waypoint_set_pos requires exactly one of args.name or args.id' } end
    if type(args.index) ~= 'number' then return { ok = false, error = 'waypoint_set_pos requires args.index (integer >= 0)' } end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'waypoint_set_pos requires args.north and args.east (numbers, meters)' }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil, has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    -- Delegate to ME-native MapWindow.move_waypoint which handles all the
    -- side effects: updates wpt.x/y, rebuilds route.spans (vehicles),
    -- moves the map symbol + number label, updates numberFirst for WP 0,
    -- moves target lines, and (for WP 0) moves the group origin + child
    -- units. Manual wp.x/wp.y assignment leaves spans and map symbols
    -- stale — visible as a "ghost corner" in the route line until the
    -- user nudges another waypoint.
    --
    -- noCheckSurface=true: CLI/agent callers know where they want the WP;
    -- surface validation belongs in the caller, not the bridge (and would
    -- otherwise silently no-op the move).
    ensure_map_objects(g)
    pcall(function()
        local MapWindow = require('me_map_window')
        if type(MapWindow.move_waypoint) == 'function' then
            MapWindow.move_waypoint(g, args.index + 1,
                args.north, args.east, nil, nil, nil, nil, true)
        end
    end)
    -- Defense in depth: if MapWindow.move_waypoint was unavailable (rare)
    -- or returned early (linkUnit edge cases), make sure the data side is
    -- still updated so the .miz save reflects the request.
    wp.x = args.north
    wp.y = args.east
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, north = wp.x, east = wp.y }
end

function M.waypoint_set_alt(args)
    if type(args) ~= 'table' then return { ok = false, error = 'waypoint_set_alt requires args (table)' } end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then return { ok = false, error = 'waypoint_set_alt requires exactly one of args.name or args.id' } end
    if type(args.index) ~= 'number' then return { ok = false, error = 'waypoint_set_alt requires args.index (integer >= 0)' } end
    if type(args.alt) ~= 'number' or args.alt < 0 then
        return { ok = false, error = 'waypoint_set_alt requires args.alt (number >= 0)' }
    end
    if args.alt_type ~= nil and not ALT_TYPES[args.alt_type] then
        return { ok = false, error = "alt_type must be 'BARO' or 'RADIO'" }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil, has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    wp.alt = args.alt
    if args.alt_type ~= nil then wp.alt_type = args.alt_type end
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, alt = wp.alt, alt_type = wp.alt_type }
end

function M.waypoint_set_speed(args)
    if type(args) ~= 'table' then return { ok = false, error = 'waypoint_set_speed requires args (table)' } end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then return { ok = false, error = 'waypoint_set_speed requires exactly one of args.name or args.id' } end
    if type(args.index) ~= 'number' then return { ok = false, error = 'waypoint_set_speed requires args.index (integer >= 0)' } end
    if type(args.speed) ~= 'number' or args.speed <= 0 then
        return { ok = false, error = 'speed must be > 0' }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil, has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    wp.speed = args.speed
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, speed = wp.speed }
end

function M.waypoint_set_mode(args)
    if type(args) ~= 'table' then return { ok = false, error = 'waypoint_set_mode requires args (table)' } end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then return { ok = false, error = 'waypoint_set_mode requires exactly one of args.name or args.id' } end
    if type(args.index) ~= 'number' then return { ok = false, error = 'waypoint_set_mode requires args.index (integer >= 0)' } end
    if type(args.mode) ~= 'string' or args.mode == '' then
        return { ok = false, error = 'waypoint_set_mode requires args.mode (e.g. "Landing", "Takeoff from parking", "Off road", "Cone")' }
    end
    local mode = WAYPOINT_MODES[string.lower(args.mode)]
    if not mode then
        return { ok = false, error = "unknown waypoint mode '" .. tostring(args.mode) .. "'" }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil, has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    -- Airfield-linkage transition (same logic as set-type).
    local old_type = type(wp.type) == 'string' and wp.type
            or (type(wp.type) == 'table' and wp.type.type) or ''
    local old_was_airfield = AIRFIELD_TYPES[old_type] == true
    local new_is_airfield = AIRFIELD_TYPES[mode.type] == true
    -- Use the panel_route.actions table reference if available, falling
    -- back to the canonical string for standalone contexts. This is what
    -- prevents panel_route.update() from silently re-normalizing
    -- wpt.type back to actions.turningPoint when it fails to match a
    -- string against the combo items' .name fields.
    local action_entry = resolve_action_entry(mode.key)
    wp.type = action_entry or mode.type
    wp.action = mode.action
    if old_was_airfield and not new_is_airfield then
        wp.airdromeId      = nil
        wp.helipadId       = nil
        wp.grassAirfieldId = nil
        if wp.linkUnit then
            pcall(function()
                local Mission = require('me_mission')
                if type(Mission.unlinkWaypoint) == 'function' then
                    Mission.unlinkWaypoint(wp)
                end
            end)
        end
    end
    -- timeReFuAr is LandingReFuAr-specific. Going TO LandingReFuAr without a
    -- value leaves the WP ambiguous; coming FROM LandingReFuAr without
    -- clearing leaves the field stale and panel_route re-derives the type
    -- as LandingReFuAr regardless of what we set wpt.type to.
    if mode.type == 'LandingReFuAr' then
        if type(wp.timeReFuAr) ~= 'number' or wp.timeReFuAr <= 0 then
            wp.timeReFuAr = 10  -- default seconds, matches ME UI default
        end
    else
        wp.timeReFuAr = nil
    end
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, type = wp.type, action = wp.action }
end

-- waypoint_link_airbase — link a waypoint to a specific airbase by name.
-- Moves the waypoint to the airbase position, sets wpt.airdromeId, clears
-- any conflicting helipad/grass-strip/moving-unit linkage, and for
-- takeoff-type waypoints ALSO calls the ME's me_parking primitive that
-- positions each unit at a parking stand or runway threshold (without
-- which the planes spawn at their old coordinates regardless of
-- airdromeId — visible as a takeoff WP linked to an airbase but units
-- floating off the ramp).
--
-- Doesn't auto-change wpt.type — caller pairs this with set-mode Landing
-- / TakeOff* as appropriate. For helipads, FARPs, grass strips, ship
-- decks: a future link-helipad / link-ship verb will handle those.
function M.waypoint_link_airbase(args)
    if type(args) ~= 'table' then return { ok = false, error = 'waypoint_link_airbase requires args (table)' } end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then return { ok = false, error = 'waypoint_link_airbase requires exactly one of args.name or args.id' } end
    if type(args.index) ~= 'number' then return { ok = false, error = 'waypoint_link_airbase requires args.index (integer >= 0)' } end
    if type(args.airbase) ~= 'string' or args.airbase == '' then
        return { ok = false, error = 'waypoint_link_airbase requires args.airbase (string, airbase name)' }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil, has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    local ad = find_airbase_by_name(args.airbase)
    if not ad then
        return { ok = false, error = "no airbase matching '" .. tostring(args.airbase) .. "'" }
    end
    local airdrome_number = ad.getAirdromeNumber and ad:getAirdromeNumber() or nil
    if type(airdrome_number) ~= 'number' then
        return { ok = false, error = "airbase '" .. args.airbase .. "' has no airdrome number" }
    end
    local x, y = ad.x, ad.y
    if type(x) ~= 'number' or type(y) ~= 'number' then
        return { ok = false, error = "airbase '" .. args.airbase .. "' has no position" }
    end

    -- Determine waypoint type. wpt.type can be either a string (our wire
    -- shape) or a panel-normalized table — handle both.
    local wp_type_str = type(wp.type) == 'string' and wp.type
            or (type(wp.type) == 'table' and wp.type.type) or ''

    -- Parking preservation (gh #68 item 5). If this is a parking-start
    -- waypoint already linked to THIS airbase and the lead unit has an
    -- explicit stand assigned (via `me unit set-parking`), re-running
    -- link-airbase here used to drag the waypoint to the airbase centre and
    -- call setAirGroupOnAirport, which re-selects a (different) stand and
    -- loses the deliberate assignment. When that condition holds we skip the
    -- move + stand re-selection entirely and only (idempotently) re-assert
    -- airdromeId below — the unit, its stand, and WP 0 stay put. Linking to
    -- a DIFFERENT airbase (airdromeId mismatch) still reshuffles, since the
    -- old stand is meaningless at the new field.
    local lead = g.units and g.units[1]
    local lead_has_stand = lead ~= nil and type(lead.parking_id) == 'string'
            and lead.parking_id ~= ''
    local preserve_parking =
        (wp_type_str == 'TakeOffParking' or wp_type_str == 'TakeOffParkingHot')
        and lead_has_stand and (wp.airdromeId == airdrome_number)

    -- Move the waypoint to the airbase position via MapWindow.move_waypoint
    -- (handles spans, symbol, label, child units for WP 0). Done first so
    -- setAirGroupOn* in the takeoff branches see the WP at the target.
    local units_positioned = false
    if not preserve_parking then
        ensure_map_objects(g)
        pcall(function()
            local MapWindow = require('me_map_window')
            if type(MapWindow.move_waypoint) == 'function' then
                MapWindow.move_waypoint(g, args.index + 1, x, y, nil, nil, nil, nil, true)
            end
        end)
        wp.x = x
        wp.y = y

        -- For TakeOffParking / TakeOffParkingHot: position each unit at a
        -- parking stand near (x,y). For TakeOff (runway): position the group
        -- at the runway threshold. These are the same primitives the ME UI
        -- uses inside attractToAirfield — calling them directly works
        -- regardless of whether wpt.type is a string or panel-table.
        if wp_type_str == 'TakeOffParking' or wp_type_str == 'TakeOffParkingHot' then
            pcall(function()
                local mp = require('me_parking')
                if type(mp.setAirGroupOnAirport) == 'function' then
                    local res = mp.setAirGroupOnAirport(g, x, y)
                    if res ~= false then units_positioned = true end
                end
            end)
        elseif wp_type_str == 'TakeOff' then
            pcall(function()
                local mp = require('me_parking')
                if type(mp.setAirGroupOnAirportRunway) == 'function' then
                    local res = mp.setAirGroupOnAirportRunway(g, x, y)
                    if res ~= false then units_positioned = true end
                end
            end)
        end
    end

    -- Force airdromeId to our target. setAirGroupOn* may have set it
    -- already to the same value; this is idempotent. Clears conflicting
    -- linkage types.
    wp.airdromeId      = airdrome_number
    wp.helipadId       = nil
    wp.grassAirfieldId = nil
    if wp.linkUnit then
        pcall(function()
            local Mission = require('me_mission')
            if type(Mission.unlinkWaypoint) == 'function' then
                Mission.unlinkWaypoint(wp)
            end
        end)
    end
    refresh_route_panel()
    refresh_group_view(g)
    return {
        ok = true, group = g.name, index = args.index,
        airbase = ad:getName(), airdromeId = airdrome_number,
        north = wp.x, east = wp.y,
        units_positioned = units_positioned,
        parking_preserved = preserve_parking,
        wp_type = wp_type_str,
    }
end

function M.waypoint_set_type(args)
    if type(args) ~= 'table' then return { ok = false, error = 'waypoint_set_type requires args (table)' } end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then return { ok = false, error = 'waypoint_set_type requires exactly one of args.name or args.id' } end
    if type(args.index) ~= 'number' then return { ok = false, error = 'waypoint_set_type requires args.index (integer >= 0)' } end
    if type(args.wp_type) ~= 'string' or not WAYPOINT_TYPES[args.wp_type] then
        return { ok = false, error = "unknown waypoint type '" .. tostring(args.wp_type) .. "'" }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil, has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    -- Detect a transition AWAY from an airfield-linked type. The ME UI
    -- clears airdromeId / helipadId / grassAirfieldId and unlinks any
    -- bound unit in this case (me_route.lua setWPTppmDefault, ~line 721).
    -- Skipping that cleanup leaves stale linkage in the .miz that
    -- conflicts with the new type at mission load.
    local old_type = type(wp.type) == 'string' and wp.type
            or (type(wp.type) == 'table' and wp.type.type) or ''
    local old_was_airfield = AIRFIELD_TYPES[old_type] == true
    local new_is_airfield = AIRFIELD_TYPES[args.wp_type] == true
    wp.type = args.wp_type
    if old_was_airfield and not new_is_airfield then
        wp.airdromeId      = nil
        wp.helipadId       = nil
        wp.grassAirfieldId = nil
        if wp.linkUnit then
            pcall(function()
                local Mission = require('me_mission')
                if type(Mission.unlinkWaypoint) == 'function' then
                    Mission.unlinkWaypoint(wp)
                end
            end)
        end
    end
    -- LandingReFuAr-specific field cleanup (see set_mode for rationale).
    if args.wp_type == 'LandingReFuAr' then
        if type(wp.timeReFuAr) ~= 'number' or wp.timeReFuAr <= 0 then
            wp.timeReFuAr = 10
        end
    else
        wp.timeReFuAr = nil
    end
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, type = wp.type }
end

function M.waypoint_set_action(args)
    if type(args) ~= 'table' then return { ok = false, error = 'waypoint_set_action requires args (table)' } end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then return { ok = false, error = 'waypoint_set_action requires exactly one of args.name or args.id' } end
    if type(args.index) ~= 'number' then return { ok = false, error = 'waypoint_set_action requires args.index (integer >= 0)' } end
    if type(args.action) ~= 'string' or not WAYPOINT_ACTIONS[args.action] then
        return { ok = false, error = "unknown waypoint action '" .. tostring(args.action) .. "'" }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil, has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    wp.action = args.action

    -- Pair the waypoint TYPE with the action, the way ED's action combo does.
    -- An airfield/takeoff/landing action implies a specific airfield-linked
    -- type; choosing a non-airfield action while the type is currently an
    -- airfield type reverts it to "Turning Point" (and clears the linkage).
    -- All other cases (a non-airfield action on a non-airfield type, e.g.
    -- formations / ground traversal) leave wp.type untouched — those types
    -- are managed by set-mode / set-formation. gh #68 item 4.
    local old_type = type(wp.type) == 'string' and wp.type
            or (type(wp.type) == 'table' and wp.type.type) or ''
    local old_was_airfield = AIRFIELD_TYPES[old_type] == true
    local pair = ACTION_AIRFIELD_TYPE[args.action]
    local new_type_str = old_type
    local type_managed = false
    if pair then
        type_managed = true
        new_type_str = pair.type
        wp.type = resolve_action_entry(pair.key) or pair.type
    elseif old_was_airfield then
        type_managed = true
        new_type_str = 'Turning Point'
        wp.type = resolve_action_entry('turningPoint') or 'Turning Point'
    end

    if type_managed then
        local new_is_airfield = AIRFIELD_TYPES[new_type_str] == true
        -- Leaving an airfield-linked type: clear airdromeId / helipadId /
        -- grassAirfieldId and unlink any bound unit (mirrors set-type /
        -- setWPTppmDefault). Stale linkage conflicts with the new type at load.
        if old_was_airfield and not new_is_airfield then
            wp.airdromeId      = nil
            wp.helipadId       = nil
            wp.grassAirfieldId = nil
            if wp.linkUnit then
                pcall(function()
                    local Mission = require('me_mission')
                    if type(Mission.unlinkWaypoint) == 'function' then
                        Mission.unlinkWaypoint(wp)
                    end
                end)
            end
        end
        -- timeReFuAr is LandingReFuAr-specific (see set-type / set-mode).
        if new_type_str == 'LandingReFuAr' then
            if type(wp.timeReFuAr) ~= 'number' or wp.timeReFuAr <= 0 then
                wp.timeReFuAr = 10
            end
        else
            wp.timeReFuAr = nil
        end
    end

    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index,
             action = wp.action, type = new_type_str }
end

function M.waypoint_set_name(args)
    if type(args) ~= 'table' then return { ok = false, error = 'waypoint_set_name requires args (table)' } end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then return { ok = false, error = 'waypoint_set_name requires exactly one of args.name or args.id' } end
    if type(args.index) ~= 'number' then return { ok = false, error = 'waypoint_set_name requires args.index (integer >= 0)' } end
    if type(args.name_text) ~= 'string' then
        return { ok = false, error = 'waypoint_set_name requires args.name_text (string, possibly empty)' }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil, has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    wp.name = args.name_text
    -- The map's floating "<index>:<name>" label is cached on
    -- mapObjects.route.numbers[i].title and isn't recomputed from
    -- wpt.name by update_group_map_objects. Mission.updateTitleWaypoints
    -- (me_mission.lua line 9275) iterates every label, rebuilds the
    -- title string, and re-adds the user-objects to MapWindow — the
    -- ME's canonical "I renamed a WP, refresh labels" path.
    pcall(function()
        local Mission = require('me_mission')
        if type(Mission.updateTitleWaypoints) == 'function' then
            Mission.updateTitleWaypoints(g)
        end
    end)
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, name = wp.name }
end

function M.waypoint_set_eta(args)
    if type(args) ~= 'table' then return { ok = false, error = 'waypoint_set_eta requires args (table)' } end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then return { ok = false, error = 'waypoint_set_eta requires exactly one of args.name or args.id' } end
    if type(args.index) ~= 'number' then return { ok = false, error = 'waypoint_set_eta requires args.index (integer >= 0)' } end
    if type(args.eta) ~= 'number' or args.eta < 0 then
        return { ok = false, error = 'eta must be >= 0' }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil, has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    wp.ETA = args.eta
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, eta = wp.ETA }
end

function M.waypoint_set_speed_locked(args)
    if type(args) ~= 'table' then return { ok = false, error = 'waypoint_set_speed_locked requires args (table)' } end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then return { ok = false, error = 'waypoint_set_speed_locked requires exactly one of args.name or args.id' } end
    if type(args.index) ~= 'number' then return { ok = false, error = 'waypoint_set_speed_locked requires args.index (integer >= 0)' } end
    if type(args.locked) ~= 'boolean' then return { ok = false, error = 'locked must be true or false' } end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil, has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    wp.speed_locked = args.locked
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, speed_locked = wp.speed_locked }
end

function M.waypoint_set_eta_locked(args)
    if type(args) ~= 'table' then return { ok = false, error = 'waypoint_set_eta_locked requires args (table)' } end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then return { ok = false, error = 'waypoint_set_eta_locked requires exactly one of args.name or args.id' } end
    if type(args.index) ~= 'number' then return { ok = false, error = 'waypoint_set_eta_locked requires args.index (integer >= 0)' } end
    if type(args.locked) ~= 'boolean' then return { ok = false, error = 'locked must be true or false' } end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil, has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    wp.ETA_locked = args.locked
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, eta_locked = wp.ETA_locked }
end

function M.waypoint_set_formation(args)
    if type(args) ~= 'table' then return { ok = false, error = 'waypoint_set_formation requires args (table)' } end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then return { ok = false, error = 'waypoint_set_formation requires exactly one of args.name or args.id' } end
    if type(args.index) ~= 'number' then return { ok = false, error = 'waypoint_set_formation requires args.index (integer >= 0)' } end
    if type(args.formation_template) ~= 'string' then
        return { ok = false, error = 'waypoint_set_formation requires args.formation_template (string, possibly empty)' }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil, has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    wp.formation_template = args.formation_template
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, formation_template = wp.formation_template }
end

function M.route_get(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'route_get requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'route_get requires exactly one of args.name or args.id' }
    end
    local route, g, _, err = find_route(has_name and args.name or nil,
                                        has_id and args.id or nil)
    if not route then return { ok = false, error = err } end
    return { ok = true, group = g.name, route = strip_back_refs(route) }
end

function M.route_clear(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'route_clear requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'route_clear requires exactly one of args.name or args.id' }
    end
    local route, g, cat, err = find_route(has_name and args.name or nil,
                                          has_id and args.id or nil)
    if not route then return { ok = false, error = err } end
    if cat == 'plane' or cat == 'helicopter' then
        return { ok = false,
                 error = "cannot clear route on air group '" .. g.name
                         .. "'; use waypoint set-pos to reposition" }
    end
    local previous = #route.points
    -- Remove from last to first so indices stay stable during the loop.
    -- Delegate to ME-native remove_waypoint for symbol/label/task cleanup.
    ensure_map_objects(g)
    local Mission = require('me_mission')
    for i = previous, 1, -1 do
        pcall(Mission.remove_waypoint, g, i)
    end
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, points_removed = previous }
end

-- ============================================================
-- Unit ↔ airbase parking verb
-- ============================================================
--
-- Lives in this file (not unit_verbs.lua) because it reaches into the
-- airbase helpers (find_airbase_by_name) and the route-block locals
-- (AIRFIELD_TYPES, ensure_map_objects, refresh_route_panel). The original
-- verbs.lua placed it at the bottom of the file for the same forward-
-- reference reasons; the noun-split version places it here so the
-- dependencies stay local.

-- unit_set_parking — pin a unit to a specific named parking stand at an
-- airbase. Sets unit.parking (the road-network crossroad index DCS uses
-- internally) AND unit.parking_id (the human-facing stand name shown in
-- the ME, e.g. "08"), then moves the unit symbol to the stand position
-- via MapWindow.move_unit.
--
-- For the LEAD unit of an air group whose WP 0 is already a takeoff/
-- landing type, this also updates WP 0's position + airdromeId so the
-- waypoint and the unit don't drift apart at save time.
--
-- Validates that the stand's category matches the unit's group category
-- (plane stand for planes, helicopter pad for helos) — refuses with a
-- discriminating error rather than silently writing a mismatched
-- parking_id that DCS would later reject.
function M.unit_set_parking(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'unit_set_parking requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'unit_set_parking requires exactly one of args.name or args.id' }
    end
    if type(args.airbase) ~= 'string' or args.airbase == '' then
        return { ok = false, error = 'unit_set_parking requires args.airbase (string)' }
    end
    if type(args.stand) ~= 'string' or args.stand == '' then
        return { ok = false, error = 'unit_set_parking requires args.stand (string, stand name e.g. "08")' }
    end
    local u, g, _, _, cat = find_unit_in_mission(
        has_name and args.name or nil, has_id and args.id or nil)
    if not u then
        return { ok = false, error = 'unit not found' }
    end
    local ad = find_airbase_by_name(args.airbase)
    if not ad then
        return { ok = false, error = "no airbase matching '" .. tostring(args.airbase) .. "'" }
    end
    local airdrome_number = ad.getAirdromeNumber and ad:getAirdromeNumber() or nil
    if type(airdrome_number) ~= 'number' then
        return { ok = false, error = "airbase '" .. args.airbase .. "' has no airdrome number" }
    end
    local roadnet
    local rn_ok = pcall(function() roadnet = ad:getRoadnet() end)
    if not rn_ok or not roadnet then
        return { ok = false, error = "airbase '" .. args.airbase .. "' has no roadnet" }
    end
    local mp_ok, mp = pcall(require, 'me_parking')
    if not mp_ok or type(mp.getStandList) ~= 'function' then
        return { ok = false, error = 'me_parking.getStandList unavailable' }
    end
    local sl_ok, stands = pcall(mp.getStandList, roadnet)
    if not sl_ok or type(stands) ~= 'table' then
        return { ok = false, error = 'me_parking.getStandList failed' }
    end
    local match
    for _, s in pairs(stands) do
        if s.name == args.stand then match = s; break end
    end
    if not match then
        return { ok = false, error = "no stand named '" .. args.stand
                .. "' at airbase '" .. ad:getName() .. "'" }
    end
    local sp = match.params or {}
    local for_planes = (tonumber(sp.FOR_AIRPLANES) or 0) ~= 0
    local for_helicopters = (tonumber(sp.FOR_HELICOPTERS) or 0) ~= 0
    if cat == 'plane' and not for_planes then
        return { ok = false, error = "stand '" .. args.stand .. "' at "
                .. ad:getName() .. " is not plane-capable" }
    end
    if cat == 'helicopter' and not for_helicopters then
        return { ok = false, error = "stand '" .. args.stand .. "' at "
                .. ad:getName() .. " is not helicopter-capable" }
    end
    -- Size check. The ME's panel_route.updateParking() calls
    -- mp.getRightParkingAirport which removes stands too small for the
    -- group's airframe (width/length/height). If our target stand fails
    -- that check, the next panel refresh will silently reassign the
    -- unit to a different stand — visible as "I asked for stand 11 but
    -- the plane ended up on stand 27". Run the same filter ourselves
    -- and refuse upfront with a discriminating error.
    if type(mp.getRightParkingAirport) == 'function' then
        local filtered = {}
        for k, v in pairs(stands) do filtered[k] = v end
        filtered = mp.getRightParkingAirport(filtered, g) or filtered
        if filtered[match.crossroad_index] == nil then
            local sw = tonumber(sp.WIDTH) or 0
            local sl = tonumber(sp.LENGTH) or 0
            return { ok = false, error = string.format(
                "stand '%s' at %s (%dx%d m) is too small for %s — try a larger stand",
                args.stand, ad:getName(), sw, sl, g.units[1] and g.units[1].type or '?')
            }
        end
    end
    u.parking    = match.crossroad_index
    u.parking_id = match.name
    ensure_map_objects(g)
    pcall(function()
        local MapWindow = require('me_map_window')
        if type(MapWindow.move_unit) == 'function' then
            -- Args: (group, unit, x, y, doNotRedraw, noCheckSurface)
            MapWindow.move_unit(g, u, match.x, match.y, false, true)
        end
    end)
    u.x = match.x
    u.y = match.y
    -- If this is the lead of an air group with a takeoff/landing WP 0,
    -- align WP 0 to the same stand so save+reload doesn't see drift.
    local lead = g.units and g.units[1]
    if lead and lead.unitId == u.unitId and g.route and g.route.points and g.route.points[1] then
        local wp0 = g.route.points[1]
        local wp_type_str = type(wp0.type) == 'string' and wp0.type
                or (type(wp0.type) == 'table' and wp0.type.type) or ''
        if AIRFIELD_TYPES[wp_type_str] then
            wp0.x               = match.x
            wp0.y               = match.y
            wp0.airdromeId      = airdrome_number
            wp0.helipadId       = nil
            wp0.grassAirfieldId = nil
        end
    end
    refresh_route_panel()
    refresh_group_view(g)
    return {
        ok = true,
        group = g.name,
        unit = u.name,
        unit_id = u.unitId,
        airbase = ad:getName(),
        airdromeId = airdrome_number,
        stand = match.name,
        crossroad_index = match.crossroad_index,
        north = u.x, east = u.y,
    }
end


-- ============================================================
-- waypoint task / enroute-task verbs (gh #69)
-- ============================================================
--
-- Both task kinds share storage at wp.task.params.tasks; the kind is
-- defined by the entry's `type` discriminator in
-- me_action_db.actionsData (1=waypoint, 2=enroute). The `--kind`
-- discriminator is therefore not carried on the data — it's enforced
-- at verb-call time via task_db. See spec "Deviations" section for
-- the live-probe-driven pivot away from the original group-task-keyed
-- shape assumption.

-- _ensure_combo: guarantee wp.task is { id='ComboTask', params={ tasks={...} } }.
-- Returns the tasks array.
local function _ensure_combo(wp)
    if type(wp.task) ~= 'table' then
        wp.task = new_combo_task()
    end
    if type(wp.task.params) ~= 'table' then wp.task.params = {} end
    if type(wp.task.params.tasks) ~= 'table' then wp.task.params.tasks = {} end
    return wp.task.params.tasks
end

-- _renumber: rewrite ['number'] = 1..N over the tasks array.
local function _renumber(tasks)
    for i, t in ipairs(tasks) do
        if type(t) == 'table' then t.number = i end
    end
end

-- _classify_slot: return ('waypoint'|'enroute'|'unknown', canonical, err)
-- for the given 1-based slot of tasks. The stored entry may carry both
-- `id` (DCS task.id) and `key` (descriptor variant key); we look up by
-- key when present, falling back to id — same disambiguation ED does.
local function _classify_slot(tasks, slot)
    if type(slot) ~= 'number' or slot < 1 or slot > #tasks then
        return nil, nil, 'slot out of range: ' .. tostring(slot) ..
                        ' (have ' .. #tasks .. ' tasks at this waypoint)'
    end
    local entry = tasks[slot]
    if type(entry) ~= 'table' then
        return 'unknown', nil, nil
    end
    local d = task_db.describe_by_stored(entry)
    if not d then
        return 'unknown', entry.key or entry.id, nil
    end
    return d.kind, d.canonical, nil
end

-- _coerce_field_value: heuristic string → typed conversion for k=v args.
-- The Go CLI ships every field as a string (parseTriggerFieldArgs returns
-- map[string]string and buildLuaFieldsExpr quotes everything). DCS often
-- tolerates string-valued params at runtime but boolean comparisons like
-- `if altitudeEnabled == true then` fail when the value is "true". For
-- fields whose descriptor default exists, coerce to that type. Otherwise
-- fall back to:
--   "true" / "false"            → boolean
--   pure numeric (incl. "-1.5") → number
--   everything else             → string
-- Anything that's already a non-string (table, number, boolean) passes
-- through unchanged.
local function _coerce_field_value(v, descr_default)
    if type(v) ~= 'string' then return v end
    if descr_default ~= nil then
        local dt = type(descr_default)
        if dt == 'number' then
            local n = tonumber(v); if n ~= nil then return n end
        elseif dt == 'boolean' then
            if v == 'true'  then return true  end
            if v == 'false' then return false end
        end
        -- descr says string (or table/other) — fall through to heuristic
    end
    if v == 'true'  then return true  end
    if v == 'false' then return false end
    local n = tonumber(v)
    if n ~= nil then return n end
    return v
end

-- _compose_task_entry: build a fresh task entry from a task_db descriptor
-- + caller-overridden fields. Returns (entry, err).
--
-- The entry shape mirrors what ED's me_action_db.setTask_ produces when
-- a user clicks "Add task" in the GUI: copies actionData.task verbatim
-- (id + key + params) and wraps it with enabled / auto / number. If
-- descr carries a task.key (descriptor variant like CAS/CAP/SEAD
-- EngageTargets) we copy it onto the entry — without it ED can't
-- identify the descriptor variant and silently filters the task from
-- the listbox.
local function _compose_task_entry(descr, fields, tasks_len)
    local params = task_db.descr_default_params(descr)
    local enabled, auto, number = true, false, tasks_len + 1
    if type(fields) == 'table' then
        for k, raw in pairs(fields) do
            -- Structural keys keep their boolean/number contract — coerce
            -- once via the simple branch then assert the final type.
            if k == 'enabled' then
                local v = _coerce_field_value(raw, true)
                if type(v) ~= 'boolean' then
                    return nil, 'enabled must be boolean (got ' .. type(v) .. ')'
                end
                enabled = v
            elseif k == 'auto' then
                local v = _coerce_field_value(raw, true)
                if type(v) ~= 'boolean' then
                    return nil, 'auto must be boolean (got ' .. type(v) .. ')'
                end
                auto = v
            elseif k == 'number' then
                local v = _coerce_field_value(raw, 0)
                if type(v) ~= 'number' then
                    return nil, 'number must be a number (got ' .. type(v) .. ')'
                end
                number = v
            else
                params[k] = _coerce_field_value(raw, params[k])
            end
        end
    end
    local entry = {
        id      = descr.task_id,
        enabled = enabled,
        auto    = auto,
        number  = number,
        params  = params,
    }
    if descr.task_key then entry.key = descr.task_key end
    return entry, nil
end

local function _add_task_impl(args, kind)
    if type(args) ~= 'table' then
        return { ok = false, error = 'waypoint_add_' .. kind .. '_task requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'requires exactly one of args.name or args.id' }
    end
    if type(args.index) ~= 'number' then
        return { ok = false, error = 'requires args.index (integer >= 0)' }
    end
    if type(args.task) ~= 'string' or args.task == '' then
        return { ok = false, error = 'requires args.task (string)' }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil,
                                           has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    if type(g.task) ~= 'string' or g.task == '' then
        return { ok = false, error = "group's main task is not set; set it with `me group set-task` first" }
    end
    -- Gate via me_action_db.availableActions[g.type][kind][g.task]. ED's
    -- listbox uses the same index; without this gate we'd write a task
    -- entry that persists in the .miz but stays invisible in the editor.
    local canonical, entry_descr, rerr = task_db.resolve(args.task, g.type, g.task, kind)
    if not canonical then
        return { ok = false, error = rerr or 'task lookup failed' }
    end
    local tasks = _ensure_combo(wp)
    local entry, cerr = _compose_task_entry(entry_descr, args.fields, #tasks)
    if not entry then return { ok = false, error = cerr } end
    table.insert(tasks, entry)
    _renumber(tasks)
    refresh_route_panel(g)
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, task = canonical,
             kind = kind, slot = #tasks }
end

function M.waypoint_add_task(args)         return _add_task_impl(args, 'waypoint') end
function M.waypoint_add_enroute_task(args) return _add_task_impl(args, 'enroute') end

local function _remove_task_impl(args, kind)
    if type(args) ~= 'table' then
        return { ok = false, error = 'remove requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'requires exactly one of args.name or args.id' }
    end
    if type(args.index) ~= 'number' then
        return { ok = false, error = 'requires args.index (integer >= 0)' }
    end
    if type(args.slot) ~= 'number' or args.slot < 1 then
        return { ok = false, error = 'requires args.slot (integer >= 1)' }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil,
                                           has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    local tasks = _ensure_combo(wp)
    local found_kind, canonical, cerr = _classify_slot(tasks, args.slot)
    if cerr then return { ok = false, error = cerr } end
    if found_kind == 'unknown' then
        return { ok = false, error = 'slot ' .. args.slot .. ' holds task "' ..
                                     tostring(canonical or '?') ..
                                     '" which is not recognized by task_db; ' ..
                                     'cannot determine kind' }
    end
    if found_kind ~= kind then
        return { ok = false, error = 'slot ' .. args.slot ..
                                     ' holds an entry of kind ' .. tostring(found_kind) ..
                                     ' ("' .. tostring(canonical or '?') ..
                                     '"); use the ' .. tostring(found_kind) ..
                                     ' remove verb instead' }
    end
    local removed = table.remove(tasks, args.slot)
    _renumber(tasks)
    refresh_route_panel(g)
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, slot = args.slot,
             removed_task = canonical, kind = kind }
end

function M.waypoint_remove_task(args)         return _remove_task_impl(args, 'waypoint') end
function M.waypoint_remove_enroute_task(args) return _remove_task_impl(args, 'enroute') end

local function _clear_tasks_impl(args, kind)
    if type(args) ~= 'table' then
        return { ok = false, error = 'clear requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'requires exactly one of args.name or args.id' }
    end
    if type(args.index) ~= 'number' then
        return { ok = false, error = 'requires args.index (integer >= 0)' }
    end
    local wp, _, g, _, err = find_waypoint(has_name and args.name or nil,
                                           has_id and args.id or nil, args.index)
    if not wp then return { ok = false, error = err } end
    local tasks = _ensure_combo(wp)
    local kept, dropped = {}, 0
    for i = 1, #tasks do
        local k = _classify_slot(tasks, i)
        if k == kind then
            dropped = dropped + 1
        else
            table.insert(kept, tasks[i])
        end
    end
    wp.task.params.tasks = kept
    _renumber(kept)
    refresh_route_panel(g)
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, removed_count = dropped,
             kind = kind, remaining = #kept }
end

function M.waypoint_clear_tasks(args)         return _clear_tasks_impl(args, 'waypoint') end
function M.waypoint_clear_enroute_tasks(args) return _clear_tasks_impl(args, 'enroute') end

function M.waypoint_list_tasks(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'waypoint_list_tasks requires args (table)' }
    end
    local kind = nil
    if args.kind ~= nil then
        if args.kind ~= 'waypoint' and args.kind ~= 'enroute' then
            return { ok = false, error = "kind must be 'waypoint' or 'enroute'" }
        end
        kind = args.kind
    end
    -- If a group is named (or --all not requested), filter by the group's
    -- main task via me_action_db.availableActions so the response matches
    -- what ED's UI will actually render. Falls back to the global list when
    -- no group is given.
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    local group_type, group_task, group_name
    if has_name or has_id then
        local g = find_group_in_mission(has_name and args.name or nil,
                                         has_id  and args.id   or nil)
        if not g then return { ok = false, error = 'group not found' } end
        group_type = g.type; group_task = g.task or ''; group_name = g.name
    end
    local lists, err = task_db.list(group_type, group_task)
    if not lists then return { ok = false, error = err } end
    local wp_tasks = (kind == nil or kind == 'waypoint') and lists.waypoint or {}
    local en_tasks = (kind == nil or kind == 'enroute')  and lists.enroute  or {}
    local resp = { ok = true, kind = kind or 'all',
                   waypoint_tasks = wp_tasks, enroute_tasks = en_tasks }
    if group_name then
        resp.group = group_name
        resp.group_type = group_type
        resp.group_task = group_task
    end
    return resp
end

function M.waypoint_describe_task(args)
    if type(args) ~= 'table' or type(args.task) ~= 'string' or args.task == '' then
        return { ok = false, error = 'waypoint_describe_task requires args.task (string)' }
    end
    local kind = nil
    if args.kind ~= nil then
        if args.kind ~= 'waypoint' and args.kind ~= 'enroute' then
            return { ok = false, error = "kind must be 'waypoint' or 'enroute'" }
        end
        kind = args.kind
    end
    local entry, err = task_db.describe(args.task, kind)
    if not entry then return { ok = false, error = err } end
    -- Live-probe pivot: descriptors live in actionsData entries with
    -- display_name/desc/params. group_tasks is gone (no static gating
    -- index — see spec "Deviations" section).
    local fields = task_db.descr_fields(entry)
    local resp = { ok = true, task = entry.canonical, kind = entry.kind,
                   display_name = entry.display_name, desc = entry.desc,
                   fields = fields }
    -- For pattern-conditional tasks (Orbit etc.), surface the variants
    -- so callers can see which extra fields apply per selector value.
    local variants = task_db.descr_variants(entry)
    if variants then resp.variants = variants end
    return resp
end

return M
