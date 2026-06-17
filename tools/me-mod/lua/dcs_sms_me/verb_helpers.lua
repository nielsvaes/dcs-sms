-- dcs_sms_me/verb_helpers.lua — shared helpers used by multiple verb files.
--
-- Verbs themselves live in `dcs_sms_me/verbs/<noun>_verbs.lua`. This module
-- exposes the helpers those files need in common: coalition-tree walking,
-- entity lookup, the group-injection sequence, and the map-objects refresh
-- dance after a mutation. Noun-local helpers (e.g. `_trigger_*`,
-- `_resources_*`) stay private inside their respective verb files.
--
-- See dcs_sms_me/verbs.lua for the aggregator and the verb-naming convention.

local H = {}

-- ============================================================
-- Coordinate convention for placement verbs
-- ============================================================
--
-- All public verbs that take a map position use the flag triplet:
--   north  meters north of theatre origin (positive = north)
--   east   meters east  of theatre origin (positive = east)
--   alt    altitude in meters above sea level (where applicable)
--
-- DCS internally exposes positions in two contradictory forms — both
-- abbreviate to "x/y/z" but with different meanings — and our --north/--east
-- semantic naming hides the trap:
--
--   1. Mission table (the .miz file format, what the ME persists):
--        { x = north_south, y = east_west }            -- no z, alt is separate
--      "y" means east–west on the ground here.
--
--   2. Runtime 3D engine (vec3 in mission-env scripting, terrain.* APIs):
--        { x = north_south, y = altitude, z = east_west }
--      "y" means altitude here, "z" means east–west.
--
-- "y" thus means two completely different things depending on which DCS API
-- you're holding. Rather than picking one and confusing users of the other,
-- our public surface is north / east / alt — semantically unambiguous, and
-- we translate to whatever the underlying API needs (here we write
-- `g.x = args.north`, `g.y = args.east`, since we're storing into the
-- mission table).
--
-- See research/me-bridge-discovery-2026-05-08.md
--   → "DCS ME coordinate axes (critical correction)"
-- for the gotcha that motivated this.

-- walk_groups — yields every group in the mission with its country and side.
-- Iterator-friendly via a callback so callers can short-circuit (return
-- false from the callback to stop walking).
function H.walk_groups(callback)
    local module_mission = require('me_mission')
    local mission = module_mission.mission
    if type(mission) ~= 'table' or type(mission.coalition) ~= 'table' then
        return
    end
    local cats = { 'plane', 'helicopter', 'vehicle', 'ship', 'static' }
    for side_name, side in pairs(mission.coalition) do
        if type(side) == 'table' and type(side.country) == 'table' then
            for _, country in ipairs(side.country) do
                for _, cat in ipairs(cats) do
                    if country[cat] and type(country[cat].group) == 'table' then
                        for _, g in ipairs(country[cat].group) do
                            if callback(g, country, side_name, cat) == false then
                                return
                            end
                        end
                    end
                end
            end
        end
    end
end

-- strip_back_refs — deep clone of a mission-table fragment, safe to JSON-encode.
-- Drops keys that are pure back-pointers (boss = group/country,
-- mapObjects = render-side cache, userObject = ME widget back-ref) and
-- breaks cycles by tracking the current ancestor chain in `visited`. When
-- we hit a table that is already an ancestor we return nil rather than the
-- live ref, so the returned tree is guaranteed acyclic.
--
-- The cycle path that motivated the visited-set: beacon-style units own a
-- zone with `zone.userObject == unit` (and `zone.userObject.zones[1] == zone`).
-- The previous depth-32 fallback returned the live `v`, leaving the cycle in
-- the clone and hanging the bridge's JSON encoder. See GH#66.
-- Cap on the number of nodes a single strip_back_refs call will clone. The
-- output is a tree (shared sub-tables are re-cloned per reference path), so a
-- deeply *nested* shared structure expands exponentially — and the JSON encoder
-- re-traverses it the same way, so bounding the clone count bounds both stripping
-- and encoding. Normal data is tiny (a recon group's whole route is ~1.6k nodes);
-- some red-side AI groups have task trees with deeply nested shared sub-tables
-- that ballooned past the bridge's exec timeout (GH#73, `waypoint get` hangs).
-- Past the cap we stop expanding and leave a marker instead of hanging. At the
-- observed ~200k clones/sec this finishes in well under a second.
H.STRIP_NODE_BUDGET = 150000

function H.strip_back_refs(v, visited, budget)
    if type(v) ~= 'table' then return v end
    visited = visited or {}
    budget = budget or { n = 0 }
    if visited[v] then return nil end
    if budget.n >= H.STRIP_NODE_BUDGET then
        return { __truncated__ = 'strip_back_refs node budget exceeded' }
    end
    budget.n = budget.n + 1
    visited[v] = true
    local out = {}
    for k, vv in pairs(v) do
        if k ~= 'boss' and k ~= 'mapObjects' and k ~= 'userObject' then
            out[k] = H.strip_back_refs(vv, visited, budget)
        end
    end
    visited[v] = nil
    return out
end

-- compute_lat_lon — convert a theatre-local (north, east) pair to (lat, lon)
-- in degrees, using ED's Terrain.convertMetersToLatLon. Returns nil, nil
-- when Terrain isn't available (no theatre loaded, called from the menu /
-- MP browser, etc.) so list/get verbs can include lat/lon best-effort
-- without crashing. Callers should drop the fields from the response when
-- both come back nil. See GH#66 (request 4).
function H.compute_lat_lon(north, east)
    if type(north) ~= 'number' or type(east) ~= 'number' then return nil, nil end
    if not _G.Terrain or type(_G.Terrain.convertMetersToLatLon) ~= 'function' then
        return nil, nil
    end
    local ok, lat, lon = pcall(_G.Terrain.convertMetersToLatLon, north, east)
    if not ok or type(lat) ~= 'number' or type(lon) ~= 'number' then
        return nil, nil
    end
    return lat, lon
end

-- refresh_group_view — defensive map-objects refresh after a unit-level
-- mutation. Disk-loaded groups have mapObjects=nil until selected; the
-- create_group_map_objects + update_group_map_objects pair handles both
-- the never-rendered and already-rendered cases. Shared by group_set_pos,
-- group_add_unit, and every unit-level setter that moves something.
function H.refresh_group_view(g)
    local Mission = require('me_mission')
    if g.mapObjects == nil and type(Mission.create_group_map_objects) == 'function' then
        pcall(Mission.create_group_map_objects, g)
    end
    if type(Mission.update_group_map_objects) == 'function' then
        pcall(Mission.update_group_map_objects, g)
    end
end

-- find_unit_in_mission — locate a unit by name or id, returning
-- (unit, group, country, side, category) or nil. Walks the coalition
-- tree via walk_groups. Shared by every unit_set_* verb plus
-- group_remove_unit.
function H.find_unit_in_mission(by_name, by_id)
    local found_unit, found_group, found_country, found_side, found_cat
    H.walk_groups(function(g, country, side_name, cat)
        for _, u in ipairs(g.units or {}) do
            if (by_name and u.name == by_name) or (by_id and u.unitId == by_id) then
                found_unit, found_group, found_country = u, g, country
                found_side, found_cat = side_name, cat
                return false
            end
        end
    end)
    return found_unit, found_group, found_country, found_side, found_cat
end

-- find_group_in_mission — walk the coalition tree and return the first group
-- matching either an exact name or a numeric groupId. Returns (group, country,
-- side, category) or nil. Walks all 5 categories (plane / helicopter /
-- vehicle / ship / static) across all 3 sides.
function H.find_group_in_mission(by_name, by_id)
    local module_mission = require('me_mission')
    local mission = module_mission.mission
    if type(mission) ~= 'table' or type(mission.coalition) ~= 'table' then
        return nil, nil, nil, nil
    end
    local cats = { 'plane', 'helicopter', 'vehicle', 'ship', 'static' }
    for side_name, side in pairs(mission.coalition) do
        if type(side) == 'table' and type(side.country) == 'table' then
            for _, country in ipairs(side.country) do
                for _, cat in ipairs(cats) do
                    if country[cat] and type(country[cat].group) == 'table' then
                        for _, g in ipairs(country[cat].group) do
                            if (by_name and g.name == by_name)
                                    or (by_id and g.groupId == by_id) then
                                return g, country, side_name, cat
                            end
                        end
                    end
                end
            end
        end
    end
    return nil, nil, nil, nil
end

-- find_airbase_by_name — look up an airdrome via Mission.AirdromeController.
-- Two-pass: exact case-insensitive name match first, then substring fallback.
-- Returns the airdrome object (with .getName / .getAirdromeNumber / .x / .y /
-- .getRoadnet methods) or nil. Used by airbase/camera/resources/route verbs.
function H.find_airbase_by_name(needle)
    if type(needle) ~= 'string' or needle == '' then return nil end
    local ok, AC = pcall(require, 'Mission.AirdromeController')
    if not ok or not AC or type(AC.getAirdromes) ~= 'function' then return nil end
    local got_ok, airdromes = pcall(AC.getAirdromes)
    if not got_ok or not airdromes then return nil end
    local n_low = needle:lower()
    for _, ad in ipairs(airdromes) do
        if ad.getName then
            local name = ad:getName()
            if name and name:lower() == n_low then return ad end
        end
    end
    for _, ad in ipairs(airdromes) do
        if ad.getName then
            local name = ad:getName()
            if name and name:lower():find(n_low, 1, true) then return ad end
        end
    end
    return nil
end

-- find_country_by_name — case-insensitive country lookup in the mission's
-- coalition tree. Returns (country_table, side_name) or nil.
function H.find_country_by_name(name)
    local module_mission = require('me_mission')
    local mission = module_mission.mission
    if type(mission) ~= 'table' or type(mission.coalition) ~= 'table' then
        return nil, nil
    end
    local target = string.lower(name)
    for side_name, side in pairs(mission.coalition) do
        if type(side) == 'table' and type(side.country) == 'table' then
            for _, country in ipairs(side.country) do
                if type(country.name) == 'string' and string.lower(country.name) == target then
                    return country, side_name
                end
            end
        end
    end
    return nil, nil
end

-- inject_group — the canonical 11-step group injection sequence documented in
-- research/me-bridge-discovery-2026-05-08.md ("inject a single group
-- ME-perfect"). Takes a fully-built group table `g`, the target country
-- table, and the group_type string ('plane' / 'helicopter' / 'vehicle' /
-- 'ship' / 'static'). Mutates `g` and the mission tables in-place.
--
-- Returns g, nil on success; nil, error_string on failure.
--
-- This is shared between group_create_* verbs. Keeping it out of the public
-- M.* surface avoids leaking the injection sequence as a callable verb —
-- callers should go through group_create_<category> verbs which build the
-- right defaults and validate inputs.
function H.inject_group(g, country, group_type)
    local Mission = require('me_mission')
    g.type = group_type
    g.groupId = Mission.getNewGroupId()

    -- Reserve collision-safe group name (allocates a new name only if needed).
    if type(Mission.check_group_name) == 'function' then
        local ok, n = pcall(Mission.check_group_name, g.name)
        if ok and type(n) == 'string' and n ~= '' then g.name = n end
    end

    -- Lookup table registration BEFORE create_group_objects (Selection / Unit
    -- List / panel updates all read these).
    if type(Mission.group_by_name) == 'table' then Mission.group_by_name[g.name] = g end
    if type(Mission.group_by_id) == 'table' then Mission.group_by_id[g.groupId] = g end

    -- Boss back-references + map-objects scaffold + color.
    g.boss = country
    g.mapObjects = { units = {}, zones = {}, route = {} }
    if type(Mission.countryCoalition) == 'table'
            and Mission.countryCoalition[country.name]
            and Mission.countryCoalition[country.name].color then
        g.color = Mission.countryCoalition[country.name].color
    end

    -- Defensive country.boss = side. me_units_list.applyFilter does
    -- group.boss.boss.name; nil there crashes the Unit List window.
    if not country.boss then
        local mission = Mission.mission or {}
        for side_name, side in pairs(mission.coalition or {}) do
            if type(side) == 'table' and type(side.country) == 'table' then
                for _, c in ipairs(side.country) do
                    if c == country then country.boss = side; break end
                end
            end
            if country.boss then break end
        end
    end

    -- Per-unit work — id → name → register → boss — must be ONE loop
    -- (getUnitName reads unit_by_name to find a free slot, so prior units
    -- must be registered before the next call).
    for _, u in ipairs(g.units) do
        u.unitId = Mission.getNewUnitId()
        if type(Mission.getUnitName) == 'function' then
            local ok, nm = pcall(Mission.getUnitName, g.name)
            if ok and type(nm) == 'string' and nm ~= '' then u.name = nm end
        end
        if type(Mission.unit_by_name) == 'table' then Mission.unit_by_name[u.name] = u end
        if type(Mission.unit_by_id) == 'table' then Mission.unit_by_id[u.unitId] = u end
        u.boss = g
    end

    -- Waypoint boss back-references.
    if g.route and type(g.route.points) == 'table' then
        for _, wpt in ipairs(g.route.points) do wpt.boss = g end
    end

    -- Canonical insertion order — do not deviate.
    local ok_cgo, cgo_err = pcall(Mission.create_group_objects, g)
    if not ok_cgo then return nil, 'create_group_objects: ' .. tostring(cgo_err) end
    if type(country[group_type]) ~= 'table' then
        country[group_type] = { name = group_type, group = {} }
    end
    table.insert(country[group_type].group, g)
    local ok_cgmo, cgmo_err = pcall(Mission.create_group_map_objects, g)
    if not ok_cgmo then return g, 'create_group_map_objects: ' .. tostring(cgmo_err) end

    -- fixAddPropAircraft fills airframe-specific defaults (F-16's
    -- STN_L16/HMD/etc). fixWaypointForGroup is MANDATORY for save survival —
    -- without it, ED's save path writes nil/nil to wpt.type.type/.action and
    -- the post-save reload crashes at me_route.lua:2413, hanging DCS and
    -- corrupting the .miz.
    pcall(Mission.fixAddPropAircraft)
    pcall(Mission.fixWaypointForGroup, g)

    return g, nil
end

-- H.new_combo_task: return a fresh empty ComboTask block of the shape
--   { id = 'ComboTask', params = { tasks = {} } }
--
-- Used everywhere a waypoint or a freshly-created group's start point
-- needs an empty task slot. Centralized here because (a) the literal
-- repeats across every group-create verb and every waypoint-add path,
-- and (b) it's the canonical empty value that mirrors what ED itself
-- writes when a new waypoint is added through the GUI — keeping it in
-- one place means a future schema change (e.g. an extra ComboTask
-- field) only has to land here.
function H.new_combo_task()
    return { id = 'ComboTask', params = { tasks = {} } }
end

-- TODO(cleanup): pull `_coerce_field_value` (verbs/route_verbs.lua) and
-- `_trigger_coerce_value` (verbs/trigger_verbs.lua) into a shared
-- `H.coerce_scalar(v, descr_default)` once a third caller needs it, or
-- next time either site is changed for unrelated reasons. The two share
-- a 4-line 'true'/'false'/tonumber/fallback ladder; the wrappers differ
-- (the route side is type-hint-driven, the trigger side is descriptor-
-- field-driven with array-of-int special cases) so a clean unification
-- needs a 2-arg signature plus a descriptor-aware overload. Not blocking
-- — flagged here so the next agent touching either coercion path doesn't
-- miss the consolidation opportunity. See the gh #69 code-review report
-- (2026-05-30) for the original finding.

return H
