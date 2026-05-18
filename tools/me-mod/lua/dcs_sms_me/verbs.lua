-- dcs_sms_me/verbs.lua — host module for `dcs-sms me <noun> <verb>` commands.
--
-- Each verb is a Lua function that takes a single args table and returns a
-- result table (JSON-encoded by the bridge for the CLI response). Verb
-- functions live here rather than in the Go CLI because:
--   * the work happens in the ME's Lua state (we'd be string-templating Lua
--     into the bridge anyway), and
--   * keeping the logic in one Lua module makes verbs testable independently
--     of the CLI and reusable across clients (CLI today, possibly other
--     bridges or in-ME UI later).
--
-- Naming convention: verb function names use snake_case to mirror the CLI's
-- `<noun> <verb>` shape (`me file open` → `verbs.file_open(args)`).
--
-- Error handling: each verb wraps its work in pcall and returns a uniform
-- result shape:
--   { ok = true,  ... }       -- success, with verb-specific extra fields
--   { ok = false, error = "..." }  -- failure, error string
-- The CLI side checks resp.return_value.ok to decide its exit code.

local M = {}

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

-- ============================================================
-- Shared helpers (used across multiple verbs)
-- ============================================================
--
-- Defined up here so forward-references work — Lua resolves locals at the
-- point they're declared, so any helper called by a verb body must be
-- declared above the verb. Read-side and write-side verbs share these.

-- walk_groups — yields every group in the mission with its country and side.
-- Iterator-friendly via a callback so callers can short-circuit (return
-- false from the callback to stop walking).
local function walk_groups(callback)
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

-- strip_back_refs — deep clone, dropping keys that create cycles when
-- serialized (boss = group/country, mapObjects = render-side cache).
local function strip_back_refs(v, depth)
    depth = depth or 0
    if depth > 32 or type(v) ~= 'table' then return v end
    local out = {}
    for k, vv in pairs(v) do
        if k ~= 'boss' and k ~= 'mapObjects' then
            out[k] = strip_back_refs(vv, depth + 1)
        end
    end
    return out
end

-- refresh_group_view — defensive map-objects refresh after a unit-level
-- mutation. Shared with the Mass Edit form modules via
-- dcs_sms_me.me_refresh; both call sites need the same pair of
-- Mission.create/update_group_map_objects calls in the same order, so
-- the body is canonical in me_refresh.lua.
local refresh_group_view = require('dcs_sms_me.me_refresh').refresh_group_view

-- find_unit_in_mission — locate a unit by name or id, returning
-- (unit, group, country, side, category) or nil. Walks the coalition
-- tree via walk_groups. Shared by every unit_set_* verb plus
-- group_remove_unit.
local function find_unit_in_mission(by_name, by_id)
    local found_unit, found_group, found_country, found_side, found_cat
    walk_groups(function(g, country, side_name, cat)
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

-- ============================================================
-- File / mission lifecycle verbs
-- ============================================================

-- file_open — open a .miz file in the Mission Editor.
-- Wraps me_toolbar.loadMission. The actual file read is async (ED's
-- progressBar schedules it on a later UpdateManager tick), so this returns
-- as soon as the call is dispatched — not when the load has completed.
--
-- args: { path: string }     -- absolute path to .miz file (forward slashes
--                                preferred to dodge backslash-escape pain)
function M.file_open(args)
    if type(args) ~= 'table' or type(args.path) ~= 'string' or args.path == '' then
        return { ok = false, error = 'file_open requires args.path (string)' }
    end
    local ok_req, me_toolbar = pcall(require, 'me_toolbar')
    if not ok_req or type(me_toolbar) ~= 'table' or type(me_toolbar.loadMission) ~= 'function' then
        return { ok = false, error = 'me_toolbar.loadMission unavailable' }
    end
    local ok_call, err = pcall(me_toolbar.loadMission, args.path)
    if not ok_call then
        return { ok = false, error = 'loadMission: ' .. tostring(err) }
    end
    return { ok = true, path = args.path }
end

-- file_new — create a fresh empty mission on the given map, no UI dialog.
--
-- Mirrors what clicking OK on the "New Mission Settings" dialog does, by
-- replicating the body of CoalitionPanel.startME / initTerr (DCS file
-- MissionEditor/modules/Mission/CoalitionPanel.lua, ~line 313/430). The dialog
-- itself is bypassed: we set default coalitions, select the theatre, then
-- schedule MapWindow.initTerrain → module_mission.create_new_mission →
-- MapWindow.show via ProgressBarDialog (the same async dispatcher used by the
-- panel's OK handler).
--
-- The discovery-log "needs-more" note about create_new_mission crashing in
-- me_weather (SW_bound nil) was caused by skipping MapWindow.initTerrain —
-- initTerrain is what populates the map data me_weather.initModule reads. With
-- the correct order, it just works.
--
-- args:
--   map:   string            theatre name e.g. "Syria" / "Caucasus" — must
--                            match TheatreOfWarData.verifyTheatreOfWar
--   force: bool (optional)   discard unsaved changes in the current mission;
--                            if false (default) we refuse when the current
--                            mission is dirty, mirroring the DCS save-prompt
function M.file_new(args)
    if type(args) ~= 'table' or type(args.map) ~= 'string' or args.map == '' then
        return { ok = false, error = 'file_new requires args.map (string)' }
    end
    local map = args.map

    local ok_tow, TheatreOfWarData = pcall(require, 'Mission.TheatreOfWarData')
    if not ok_tow or type(TheatreOfWarData) ~= 'table' then
        return { ok = false, error = 'Mission.TheatreOfWarData unavailable' }
    end
    if type(TheatreOfWarData.verifyTheatreOfWar) ~= 'function'
            or not TheatreOfWarData.verifyTheatreOfWar(map) then
        local available = {}
        if type(TheatreOfWarData.getTheatresOfWar) == 'function' then
            for _, t in ipairs(TheatreOfWarData.getTheatresOfWar() or {}) do
                if type(t) == 'table' and t.name then
                    table.insert(available, t.name)
                end
            end
        end
        return { ok = false, error = 'unknown map: ' .. tostring(map),
                 available_maps = available }
    end

    local ok_mw, MapWindow = pcall(require, 'me_map_window')
    local ok_mm, module_mission = pcall(require, 'me_mission')
    if not ok_mw or not ok_mm then
        return { ok = false, error = 'me_map_window / me_mission unavailable' }
    end

    if args.force ~= true then
        local empty = type(MapWindow.isEmptyME) == 'function' and MapWindow.isEmptyME()
        local modified = type(module_mission.isMissionModified) == 'function'
                and module_mission.isMissionModified()
        if not empty and modified then
            return { ok = false,
                     error = 'current mission has unsaved changes; pass force=true to discard' }
        end
    end

    local ok_cc, CoalitionController = pcall(require, 'Mission.CoalitionController')
    local ok_pb, progressBar = pcall(require, 'ProgressBarDialog')
    if not ok_cc or not ok_pb then
        return { ok = false, error = 'CoalitionController / ProgressBarDialog unavailable' }
    end

    local ok_def, def_err = pcall(CoalitionController.setDefaultCoalitions)
    if not ok_def then
        return { ok = false, error = 'setDefaultCoalitions: ' .. tostring(def_err) }
    end
    local ok_sel, sel_err = pcall(CoalitionController.selectTheatreOfWar, map, true)
    if not ok_sel then
        return { ok = false, error = 'selectTheatreOfWar: ' .. tostring(sel_err) }
    end

    -- The actual terrain init + mission reset is heavy and must run on a
    -- later tick (matches what the OK button does). We can't surface its
    -- pass/fail synchronously — caller polls ME state afterwards.
    local function init_terrain_then_mission()
        MapWindow.initTerrain(false, false, 'ME', module_mission.getDefaultDate())
        module_mission.create_new_mission(true)
        MapWindow.show(true)
        return true
    end

    local ok_sched, sched_err = pcall(progressBar.setUpdateFunction, init_terrain_then_mission)
    if not ok_sched then
        return { ok = false, error = 'schedule init: ' .. tostring(sched_err) }
    end

    return { ok = true, map = map, async = true }
end

-- refresh_menubar_title — keep the ME's top-bar filename label in sync with
-- the actual saved path. DCS native flows update this via the post-save
-- reload (module_mission.load → MenuBar.setFileName at me_mission.lua:2550),
-- but in the no-reload path we have to do it ourselves.
local function refresh_menubar_title(path)
    pcall(function()
        local mb = require('me_menubar')
        local U = require('me_utilities')
        if type(mb.setFileName) == 'function' and type(U.extractFileName) == 'function' then
            mb.setFileName(U.extractFileName(path))
        end
    end)
end

-- _save_mission_with_reopen_dance — shared body for file_save / file_save_as.
--
-- module_mission.save_mission_safe(path, false, noLoad=false) writes the .miz
-- and synchronously calls module_mission.load(fName) inside save() (line
-- ~4889 in me_mission.lua). load() rebuilds the entire mission table:
-- coalition[].country[].<cat>.group lists, unit_by_name, group_by_name, and
-- the per-group/per-unit map objects. **Any reference held outside that
-- table becomes stale.**
--
-- The ME-native saveMission flow at me_toolbar.lua:769-803 mirrors this with
-- two cleanup steps that our verbs must reproduce when reopen=true:
--   1. BEFORE save: MapWindow.unselectAll() — clears MapWindow.selectedGroup
--      / selectedUnit and the selection sprites. Without this, after load()
--      rebuilds the tables those references point at orphan objects: the
--      title bar updates correctly (it's just a string) but the user can't
--      select anything new because the ME's click handlers walk the dangling
--      selection state and short-circuit on stale identity checks.
--   2. AFTER save: MapWindow.show(true) — re-creates / re-renders the map
--      against the new mission data.
--
-- When reopen=false we skip both: there's no rebuild, references stay valid.
local function _save_mission_with_reopen_dance(verb, path, reopen)
    local ok_mm, module_mission = pcall(require, 'me_mission')
    if not ok_mm or type(module_mission) ~= 'table' then
        return { ok = false, error = 'me_mission unavailable' }
    end
    if type(module_mission.save_mission_safe) ~= 'function' then
        return { ok = false, error = 'me_mission.save_mission_safe unavailable' }
    end

    -- Pre-save: clear stale selection refs so they don't survive into the
    -- post-load() ME state.
    local MapWindow
    if reopen then
        local ok_mw
        ok_mw, MapWindow = pcall(require, 'me_map_window')
        if ok_mw and type(MapWindow) == 'table' and type(MapWindow.unselectAll) == 'function' then
            pcall(MapWindow.unselectAll)
        end
    end

    local noLoad = not reopen
    local ok_call, ok_or_err = pcall(module_mission.save_mission_safe, path, false, noLoad)
    if not ok_call then
        return { ok = false,
                 error = 'save_mission_safe: ' .. tostring(ok_or_err)
                         .. ' (file written; post-save reload crashed — try --reopen=false)' }
    end
    if ok_or_err ~= true then
        return { ok = false, error = 'save failed (mission validation or I/O); enable showError to see details' }
    end

    -- Post-save: refresh the map view against the rebuilt tables. Mirrors
    -- saveMissionFileDialog at me_toolbar.lua:757.
    if reopen and MapWindow and type(MapWindow.show) == 'function' then
        pcall(MapWindow.show, true)
    end

    return { ok = true, path = path, reopen = reopen }
end

-- file_save — save the current mission to its existing path.
--
-- Wraps module_mission.save_mission_safe(path, false, noLoad).
--   showError=false: no UI popup on error (we surface it in the response)
--   noLoad:          when reopen=true (default), DCS re-loads the file we
--                    just wrote — same as clicking Ctrl+S in the ME. This
--                    refreshes the title bar, dictionary state, etc.
--                    when reopen=false, we skip the reload to avoid the
--                    F-16-waypoint reload-crash documented in the discovery
--                    log (me_route.lua:2413, post-save load() of a mission
--                    with un-fix'd waypoints corrupts the .miz and hangs
--                    DCS). We still refresh the title bar manually so the
--                    user sees the right filename.
--
-- args:
--   reopen: bool (optional, default true) — match DCS-native behavior; pass
--                false only when you've just inject'd groups but haven't run
--                Mission.fixWaypointForGroup yet
--
-- Errors if the mission has no real path yet (i.e. it's the temp/new
-- placeholder) — use file_save_as for that case.
function M.file_save(args)
    local reopen = true
    if type(args) == 'table' and args.reopen ~= nil then reopen = (args.reopen == true) end
    local ok_mm, module_mission = pcall(require, 'me_mission')
    if not ok_mm or type(module_mission) ~= 'table' then
        return { ok = false, error = 'me_mission unavailable' }
    end
    if type(module_mission.getMissionPathIsSaved) ~= 'function'
            or not module_mission.getMissionPathIsSaved() then
        return { ok = false,
                 error = 'mission has no saved path; use file save-as --path <X.miz>' }
    end
    local path = module_mission.mission and module_mission.mission.path
    if type(path) ~= 'string' or path == '' then
        return { ok = false, error = 'mission.path missing' }
    end
    local result = _save_mission_with_reopen_dance('file_save', path, reopen)
    if not result.ok then return result end
    if not reopen then refresh_menubar_title(path) end
    return result
end

-- file_save_as — save the current mission to a new path.
--
-- args:
--   path:   string  — absolute path to write (forward slashes preferred)
--   reopen: bool (optional, default true) — see file_save for semantics
--
-- Updates module_mission.mission.path and MeSettings.missionPath so the next
-- bare file_save targets the new file (matching what me_toolbar's Save-As
-- flow does after FileDialog.save returns a filename). When reopen=true the
-- post-save load() also resets mission.path internally and refreshes the
-- title bar; when reopen=false we maintain that state ourselves.
function M.file_save_as(args)
    if type(args) ~= 'table' or type(args.path) ~= 'string' or args.path == '' then
        return { ok = false, error = 'file_save_as requires args.path (string)' }
    end
    local reopen = true
    if args.reopen ~= nil then reopen = (args.reopen == true) end
    local result = _save_mission_with_reopen_dance('file_save_as', args.path, reopen)
    if not result.ok then return result end
    -- Always sync MeSettings (the DCS user-flow does this in me_toolbar; load() doesn't).
    local ok_ms, MeSettings = pcall(require, 'MeSettings')
    if ok_ms and type(MeSettings) == 'table' and type(MeSettings.setMissionPath) == 'function' then
        pcall(MeSettings.setMissionPath, args.path)
    end
    if not reopen then
        -- load() would have set these for us; in the no-reload path do it manually.
        local ok_mm, module_mission = pcall(require, 'me_mission')
        if ok_mm and module_mission.mission then module_mission.mission.path = args.path end
        refresh_menubar_title(args.path)
    end
    return result
end

-- ============================================================
-- Group lifecycle verbs (private helpers + public verbs)
-- ============================================================

-- find_group_in_mission — walk the coalition tree and return the first group
-- matching either an exact name or a numeric groupId. Returns (group, country,
-- side, category) or nil. Walks all 5 categories (plane / helicopter /
-- vehicle / ship / static) across all 3 sides.
local function find_group_in_mission(by_name, by_id)
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

-- find_country_by_name — case-insensitive country lookup in the mission's
-- coalition tree. Returns (country_table, side_name) or nil.
local function find_country_by_name(name)
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
-- This is shared between group_create_* verbs. Keeping it private (M.* not
-- exported) avoids leaking the injection sequence as public surface — callers
-- should go through group_create_<category> verbs which build the right
-- defaults and validate inputs.
local function inject_group(g, country, group_type)
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
--                       See top-of-file comment for why we use north/east
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
--
-- Note: set-country isn't here yet. Moving a group between coalition
-- branches needs custom remove + reinsert + boss/color refresh — there's no
-- Mission.* helper for it. Workaround until we ship one: capture state with
-- group_get, group_remove, then group_create_<cat> with the new country.

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

    -- Step 9: heavyweight refresh — country change flips coalition color,
    -- which the lightweight refresh path doesn't pick up. recreate_group_view
    -- forces a symbol re-render so the new color shows without waiting for
    -- the user to click the group.
    local me_refresh = require('dcs_sms_me.me_refresh')
    me_refresh.recreate_group_view(g)

    return { ok = true, id = g.groupId, name = g.name,
             country = newCountry.name, side = newSide,
             previous_country = oldCountry and oldCountry.name,
             previous_side = oldSide,
             coalition_changed = coalition_changed,
             empty_liveries = empty_liveries,
             airfield_reattracted = airfield_reattracted }
end

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
-- Trigger zone lifecycle verbs
-- ============================================================

-- DCS trigger zone types (from Mission.TriggerZone.lua line 9):
--   TYPE_CIRCLE    = 0
--   TYPE_RECTANGLE = 1   (unused at the ME UI level — quads use type 2)
--   TYPE_POLYGON   = 2   (4 vertices = "Quad-Point Zone" in the ME UI)
local ZONE_TYPE_CIRCLE = 0
local ZONE_TYPE_POLYGON = 2

-- Default color matches what TriggerZone.construct sets internally:
-- {r=1, g=1, b=1, a=0.15} — translucent white. RGBA components are floats 0..1.
local function default_zone_color() return { 1, 1, 1, 0.15 } end

-- find_zone_by_name / find_zone_by_id — TriggerZoneData doesn't expose a
-- by-name lookup directly; we iterate getTriggerZoneIds() and match.
local function find_zone(by_name, by_id)
    local TZD = require('Mission.TriggerZoneData')
    if type(TZD) ~= 'table' or type(TZD.getTriggerZoneIds) ~= 'function' then
        return nil, nil
    end
    for _, zid in ipairs(TZD.getTriggerZoneIds() or {}) do
        if by_id and zid == by_id then return zid, TZD.getTriggerZoneName(zid) end
        if by_name then
            local n = TZD.getTriggerZoneName(zid)
            if n == by_name then return zid, n end
        end
    end
    return nil, nil
end

-- zone_create_circle — circular trigger zone at (north, east) with given radius.
--
-- args (required):
--   name:   string  -- zone name (uniquified by TriggerZoneData if duplicate)
--   north:  number  -- meters north of theatre origin
--   east:   number  -- meters east of theatre origin
--   radius: number  -- meters
--
-- args (optional):
--   color:  { r, g, b, a } floats 0..1; defaults to translucent white
--   hidden: bool, default false
--   properties: table, default {}
--
-- Returns { ok = true, zoneId, name } on success.
function M.zone_create_circle(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_create_circle requires args (table)' }
    end
    if type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'zone_create_circle requires args.name (string)' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'zone_create_circle requires args.north and args.east (numbers, meters)' }
    end
    if type(args.radius) ~= 'number' or args.radius <= 0 then
        return { ok = false, error = 'zone_create_circle requires args.radius (positive number, meters)' }
    end

    local ok_tzd, TZD = pcall(require, 'Mission.TriggerZoneData')
    if not ok_tzd or type(TZD) ~= 'table' or type(TZD.addTriggerZone) ~= 'function' then
        return { ok = false, error = 'Mission.TriggerZoneData unavailable' }
    end

    local color = (type(args.color) == 'table') and args.color or default_zone_color()
    local properties = (type(args.properties) == 'table') and args.properties or {}

    -- mission-table fields: x = north, y = east
    local x, y = args.north, args.east

    -- addTriggerZone returns the allocated zoneId on success.
    local ok_call, zid_or_err = pcall(TZD.addTriggerZone, args.name, x, y, args.radius,
                                       properties, color, ZONE_TYPE_CIRCLE, nil)
    if not ok_call then
        return { ok = false, error = 'addTriggerZone: ' .. tostring(zid_or_err) }
    end
    if type(zid_or_err) ~= 'number' then
        return { ok = false, error = 'addTriggerZone returned non-number: ' .. tostring(zid_or_err) }
    end

    -- Name may have been uniquified by TZD.makeTriggerZoneNameUnique.
    local final_name = TZD.getTriggerZoneName and TZD.getTriggerZoneName(zid_or_err) or args.name

    if args.hidden == true and type(TZD.setTriggerZoneHidden) == 'function' then
        pcall(TZD.setTriggerZoneHidden, zid_or_err, true)
    end

    return { ok = true, zoneId = zid_or_err, name = final_name, type = 'circle' }
end

-- zone_create_quad — polygon trigger zone with 4 vertices (the ME's
-- "Quad-Point Zone"). Despite the name we accept any N>=3 vertex count —
-- the underlying type=2 polygon supports it.
--
-- args (required):
--   name:     string
--   vertices: list of { north = N, east = E } in absolute world meters
--             (NOT relative to center — we compute the center for you).
--
-- args (optional):
--   color, hidden, properties — see zone_create_circle
--   radius:   icon radius in meters; defaults to half the bounding-box diagonal
--             (matches what the ME would compute for a rectangular quad).
--
-- Returns { ok = true, zoneId, name, center = { north, east } } on success.
function M.zone_create_quad(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_create_quad requires args (table)' }
    end
    if type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'zone_create_quad requires args.name (string)' }
    end
    if type(args.vertices) ~= 'table' or #args.vertices < 3 then
        return { ok = false, error = 'zone_create_quad requires args.vertices (>= 3 {north,east} pairs)' }
    end

    -- Validate each vertex.
    for i, v in ipairs(args.vertices) do
        if type(v) ~= 'table' or type(v.north) ~= 'number' or type(v.east) ~= 'number' then
            return { ok = false,
                     error = 'vertex ' .. i .. ' missing/invalid {north,east} numbers' }
        end
    end

    -- Compute center as average of vertices.
    local cx, cy = 0, 0
    for _, v in ipairs(args.vertices) do
        cx = cx + v.north
        cy = cy + v.east
    end
    cx = cx / #args.vertices
    cy = cy / #args.vertices

    -- Convert absolute vertices to points relative to center
    -- (mission-table fields: x = north, y = east).
    local points = {}
    local minN, maxN, minE, maxE = math.huge, -math.huge, math.huge, -math.huge
    for _, v in ipairs(args.vertices) do
        table.insert(points, { x = v.north - cx, y = v.east - cy })
        if v.north < minN then minN = v.north end
        if v.north > maxN then maxN = v.north end
        if v.east  < minE then minE = v.east  end
        if v.east  > maxE then maxE = v.east  end
    end

    -- Default radius = half bounding-box diagonal — sized so the icon
    -- circumscribes the quad. User can override.
    local default_radius = 0.5 * math.sqrt((maxN - minN) ^ 2 + (maxE - minE) ^ 2)
    local radius = (type(args.radius) == 'number' and args.radius > 0) and args.radius
                   or math.max(default_radius, 1)

    local ok_tzd, TZD = pcall(require, 'Mission.TriggerZoneData')
    if not ok_tzd or type(TZD) ~= 'table' or type(TZD.addTriggerZone) ~= 'function' then
        return { ok = false, error = 'Mission.TriggerZoneData unavailable' }
    end

    local color = (type(args.color) == 'table') and args.color or default_zone_color()
    local properties = (type(args.properties) == 'table') and args.properties or {}

    local ok_call, zid_or_err = pcall(TZD.addTriggerZone, args.name, cx, cy, radius,
                                       properties, color, ZONE_TYPE_POLYGON, points)
    if not ok_call then
        return { ok = false, error = 'addTriggerZone: ' .. tostring(zid_or_err) }
    end
    if type(zid_or_err) ~= 'number' then
        return { ok = false, error = 'addTriggerZone returned non-number: ' .. tostring(zid_or_err) }
    end

    local final_name = TZD.getTriggerZoneName and TZD.getTriggerZoneName(zid_or_err) or args.name

    if args.hidden == true and type(TZD.setTriggerZoneHidden) == 'function' then
        pcall(TZD.setTriggerZoneHidden, zid_or_err, true)
    end

    return { ok = true, zoneId = zid_or_err, name = final_name, type = 'quad',
             center = { north = cx, east = cy }, vertex_count = #points }
end

-- ============================================================
-- Zone setters (per-field)
-- ============================================================
--
-- Each setter takes { name = "<X>" | id = <N>, <field> = <value> } and wraps
-- the matching Mission.TriggerZoneData.setTriggerZone* call. Returns the new
-- value on success so callers can confirm the write took.

-- zone_set_color — change RGBA color of a zone.
-- args: { name | id, color = { r, g, b[, a] } } floats 0..1.
-- Alpha defaults to 0.15 (DCS's translucent fill alpha) if missing.
function M.zone_set_color(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_color requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_color requires exactly one of args.name or args.id' }
    end
    if type(args.color) ~= 'table' or type(args.color[1]) ~= 'number'
            or type(args.color[2]) ~= 'number' or type(args.color[3]) ~= 'number' then
        return { ok = false, error = 'zone_set_color requires args.color = { r, g, b[, a] } floats 0..1' }
    end
    local zid, zname = find_zone(has_name and args.name or nil,
                                 has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end
    local r, g, b = args.color[1], args.color[2], args.color[3]
    local a = (type(args.color[4]) == 'number') and args.color[4] or 0.15
    local TZD = require('Mission.TriggerZoneData')
    local ok_call, err = pcall(TZD.setTriggerZoneColor, zid, r, g, b, a)
    if not ok_call then
        return { ok = false, error = 'setTriggerZoneColor: ' .. tostring(err) }
    end
    return { ok = true, id = zid, name = zname, color = { r, g, b, a } }
end

-- zone_set_name — rename a zone. ME enforces uniqueness via
-- makeTriggerZoneNameUnique, so the stored name may include a suffix.
function M.zone_set_name(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_name requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_name requires exactly one of args.name or args.id' }
    end
    if type(args.new_name) ~= 'string' or args.new_name == '' then
        return { ok = false, error = 'zone_set_name requires args.new_name (non-empty string)' }
    end
    local zid = find_zone(has_name and args.name or nil, has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end
    local TZD = require('Mission.TriggerZoneData')
    local ok_call, err = pcall(TZD.setTriggerZoneName, zid, args.new_name)
    if not ok_call then
        return { ok = false, error = 'setTriggerZoneName: ' .. tostring(err) }
    end
    -- Read back what TZD actually stored — the ME may have appended a suffix.
    local final = TZD.getTriggerZoneName(zid)
    return { ok = true, id = zid, name = final, requested_name = args.new_name }
end

-- zone_set_pos — move zone center to (north, east).
-- For circles, this just moves the center. For quads, the relative points
-- ride along (translation), but the shape doesn't reshape — use
-- zone_set_vertices for that.
function M.zone_set_pos(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_pos requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_pos requires exactly one of args.name or args.id' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'zone_set_pos requires args.north and args.east (numbers, meters)' }
    end
    local zid, zname = find_zone(has_name and args.name or nil, has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end
    local TZD = require('Mission.TriggerZoneData')
    -- mission-table fields: x = north, y = east
    local ok_call, err = pcall(TZD.setTriggerZonePosition, zid, args.north, args.east)
    if not ok_call then
        return { ok = false, error = 'setTriggerZonePosition: ' .. tostring(err) }
    end
    return { ok = true, id = zid, name = zname, north = args.north, east = args.east }
end

-- zone_set_radius — set zone radius (circle: trigger radius; quad: icon radius).
function M.zone_set_radius(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_radius requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_radius requires exactly one of args.name or args.id' }
    end
    if type(args.radius) ~= 'number' or args.radius <= 0 then
        return { ok = false, error = 'zone_set_radius requires args.radius (positive number, meters)' }
    end
    local zid, zname = find_zone(has_name and args.name or nil, has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end
    local TZD = require('Mission.TriggerZoneData')
    local ok_call, err = pcall(TZD.setTriggerZoneRadius, zid, args.radius)
    if not ok_call then
        return { ok = false, error = 'setTriggerZoneRadius: ' .. tostring(err) }
    end
    return { ok = true, id = zid, name = zname, radius = args.radius }
end

-- zone_set_hidden — toggle zone visibility in the ME view.
-- Caller must pass an explicit boolean — the CLI rejects missing --hidden.
function M.zone_set_hidden(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_hidden requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_hidden requires exactly one of args.name or args.id' }
    end
    if type(args.hidden) ~= 'boolean' then
        return { ok = false, error = 'zone_set_hidden requires args.hidden (boolean)' }
    end
    local zid, zname = find_zone(has_name and args.name or nil, has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end
    local TZD = require('Mission.TriggerZoneData')
    local ok_call, err = pcall(TZD.setTriggerZoneHidden, zid, args.hidden)
    if not ok_call then
        return { ok = false, error = 'setTriggerZoneHidden: ' .. tostring(err) }
    end
    return { ok = true, id = zid, name = zname, hidden = args.hidden }
end

-- zone_set_vertices — reshape a quad zone in absolute world coords.
-- Computes a new center (average of vertices) and stores points relative to
-- that center — same shape zone_create_quad produces, so save+reload behavior
-- is identical. Refuses on non-quad zones.
--
-- args: { name|id, vertices = { { north=N, east=E }, ... } } (>= 3)
function M.zone_set_vertices(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_vertices requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_vertices requires exactly one of args.name or args.id' }
    end
    if type(args.vertices) ~= 'table' or #args.vertices < 3 then
        return { ok = false, error = 'zone_set_vertices requires args.vertices (>= 3 {north,east} pairs)' }
    end
    for i, v in ipairs(args.vertices) do
        if type(v) ~= 'table' or type(v.north) ~= 'number' or type(v.east) ~= 'number' then
            return { ok = false, error = 'vertex ' .. i .. ' missing/invalid {north,east} numbers' }
        end
    end

    local zid, zname = find_zone(has_name and args.name or nil, has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end

    local TZD = require('Mission.TriggerZoneData')
    -- Refuse on circle zones — they have no vertices to reshape. The user
    -- almost certainly wanted set-radius / set-pos.
    if TZD.getTriggerZoneType(zid) ~= 2 then  -- 2 = polygon/quad
        return { ok = false, error = 'zone is not a quad; use set-radius/set-pos for circle zones' }
    end

    -- Average vertices for new center, then compute relative points.
    local cx, cy = 0, 0
    for _, v in ipairs(args.vertices) do
        cx = cx + v.north; cy = cy + v.east
    end
    cx = cx / #args.vertices; cy = cy / #args.vertices
    local rel = {}
    for _, v in ipairs(args.vertices) do
        table.insert(rel, { x = v.north - cx, y = v.east - cy })
    end

    local ok_pos, err_pos = pcall(TZD.setTriggerZonePosition, zid, cx, cy)
    if not ok_pos then
        return { ok = false, error = 'setTriggerZonePosition: ' .. tostring(err_pos) }
    end
    local ok_pts, err_pts = pcall(TZD.setTriggerZonePoints, zid, rel)
    if not ok_pts then
        return { ok = false, error = 'setTriggerZonePoints: ' .. tostring(err_pts) }
    end
    return { ok = true, id = zid, name = zname,
             center = { north = cx, east = cy },
             vertex_count = #rel }
end

-- zone_set_link — link a trigger zone to a unit (so the zone's center
-- follows the unit), or clear an existing link.
--
-- Wraps Mission.linkTriggerZone / Mission.unlinkTriggerZone (the
-- high-level wrappers used by the ME's panel UI), NOT the lower-level
-- TZD.linkToUnit directly. The wrappers do TWO things on link:
--   1. TriggerZoneController.linkToUnit(zid, uid) — sets the zone's
--      linkUnitId, captures local coords, captures heading.
--   2. table.insert(unit.linkChildrenTZone, zid) — back-reference on
--      the unit so the unit's drag/move handlers (in me_map_window,
--      me_aircraft, me_ship, me_vehicle, me_static) know to refresh
--      this zone's position when the unit moves.
--
-- Calling only step 1 (the bare TZD function) leaves the link visible
-- in the LINK UNIT dropdown and persisted to .miz, but the zone won't
-- move with the unit in the live ME view — save+reload "fixes" it
-- because load reconstructs linkChildrenTZone from the zone's stored
-- linkUnitId, but in-session drag is broken without the back-ref.
--
-- args (zone selector — required): name | id (mutually exclusive)
-- args (action — exactly one required):
--   unit:     string  — link to unit by name
--   unit_id:  number  — link to unit by id
--   clear:    true    — remove the link
function M.zone_set_link(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_link requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_link requires exactly one of args.name or args.id' }
    end

    local has_unit = type(args.unit) == 'string' and args.unit ~= ''
    local has_unit_id = type(args.unit_id) == 'number'
    local has_clear = (args.clear == true)
    local action_count = (has_unit and 1 or 0) + (has_unit_id and 1 or 0) + (has_clear and 1 or 0)
    if action_count ~= 1 then
        return { ok = false,
                 error = 'zone_set_link requires exactly one of args.unit, args.unit_id, or args.clear=true' }
    end

    local zid, zname = find_zone(has_name and args.name or nil, has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end

    local Mission = require('me_mission')

    if has_clear then
        if type(Mission.unlinkTriggerZone) ~= 'function' then
            return { ok = false, error = 'Mission.unlinkTriggerZone unavailable' }
        end
        local ok_call, err = pcall(Mission.unlinkTriggerZone, zid)
        if not ok_call then
            return { ok = false, error = 'unlinkTriggerZone: ' .. tostring(err) }
        end
        return { ok = true, id = zid, name = zname, cleared = true }
    end

    -- Resolve target unit.
    local u = find_unit_in_mission(has_unit and args.unit or nil,
                                   has_unit_id and args.unit_id or nil)
    if not u then
        return { ok = false, error = 'unit not found' }
    end

    if type(Mission.linkTriggerZone) ~= 'function' then
        return { ok = false, error = 'Mission.linkTriggerZone unavailable' }
    end

    -- linkTriggerZone tolerates re-linking but doesn't dedupe the
    -- linkChildrenTZone back-reference list — calling it twice on the
    -- same (zone, unit) pair would push the zoneId in twice. Defensively
    -- unlink first if the zone is currently linked.
    if type(Mission.unlinkTriggerZone) == 'function' then
        local TZD = require('Mission.TriggerZoneData')
        if type(TZD.getLinkUnitId) == 'function' and TZD.getLinkUnitId(zid) then
            pcall(Mission.unlinkTriggerZone, zid)
        end
    end

    local ok_call, err = pcall(Mission.linkTriggerZone, zid, u.unitId)
    if not ok_call then
        return { ok = false, error = 'linkTriggerZone: ' .. tostring(err) }
    end

    return {
        ok = true,
        id = zid,
        name = zname,
        unit_id = u.unitId,
        unit_name = u.name,
    }
end

-- zone_remove — remove a trigger zone by name or id (mutually exclusive).
function M.zone_remove(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_remove requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_remove requires exactly one of args.name (string) or args.id (number)' }
    end

    local zid, zname = find_zone(has_name and args.name or nil,
                                 has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end

    local TZD = require('Mission.TriggerZoneData')
    local ok_call, err = pcall(TZD.removeTriggerZone, zid)
    if not ok_call then
        return { ok = false, error = 'removeTriggerZone: ' .. tostring(err),
                 resolved = { id = zid, name = zname } }
    end

    return { ok = true, id = zid, name = zname }
end

-- ============================================================
-- Drawings — shared helpers + read-side
-- ============================================================
--
-- Drawings live in mission.drawings under a layered structure: the ME has
-- 5 layers (Red / Blue / Neutral / Common / Author) and each layer carries
-- a list of objects. Each object has a primitiveType (Line / Polygon /
-- TextBox / Icon) plus shape-specific fields. Polygon further splits into
-- 5 sub-modes (circle / oval / rect / free / arrow) — 9 distinct shapes
-- in total counting Line's segments / segment / free sub-modes.
--
-- The me_draw_panel module exposes saveToMission / loadFromMission as the
-- canonical IO pair, plus getObjects / objectDelete for read/destroy. It
-- does NOT expose objectAdd / layers_, so to inject a new drawing we go
-- through a save → modify → reload cycle:
--
--   data = panel.saveToMission()    -- current state
--   table.insert(data.layers[k].objects, new_object)
--   panel.loadFromMission(data)     -- resets and rebuilds with new state
--
-- Round-trip-tested against save+full-DCS-reload during the probe phase
-- (the injected circle survived). One-shot reset+rebuild is fine for
-- ME-time editing — drawings are at most a few dozen objects per mission.

-- mutate_drawing — modify an existing drawing in place. Routes through
-- the same saveToMission → modify → loadFromMission cycle as
-- inject_drawing because the panel doesn't expose any granular
-- mutation hook. fn is called with the on-disk shape of the matching
-- object (saveToMission's flat shape — every field is writable here)
-- and any mutation it does is persisted on the loadFromMission
-- rebuild. Returns the mutated object on success, or nil + error on
-- not-found / fn-error.
local function mutate_drawing(name, fn)
    local panel = require('me_draw_panel')
    local data = panel.saveToMission()
    local found
    for _, layer in ipairs(data.layers or {}) do
        for _, obj_save in ipairs(layer.objects or {}) do
            if obj_save.name == name then
                local ok, err = pcall(fn, obj_save)
                if not ok then return nil, 'mutate fn: ' .. tostring(err) end
                found = obj_save
                break
            end
        end
        if found then break end
    end
    if not found then return nil, 'drawing not found' end
    local ok_call, err = pcall(panel.loadFromMission, data)
    if not ok_call then return nil, 'loadFromMission: ' .. tostring(err) end
    return found, nil
end

-- inject_drawing — add a single drawing object to a named layer using
-- the panel's saveToMission/loadFromMission cycle. The new object must
-- carry all required fields for its primitiveType (lineLoad /
-- polygonCircleLoad / etc. expect specific shapes — see saveToMission's
-- per-shape savers for the exact field set).
local function inject_drawing(new_object, layer_name)
    local panel = require('me_draw_panel')
    local data = panel.saveToMission()
    layer_name = layer_name or 'Common'

    local target_layer
    for _, layer in ipairs(data.layers or {}) do
        if layer.name == layer_name then target_layer = layer; break end
    end
    if not target_layer then
        return nil, 'unknown layer: ' .. tostring(layer_name)
            .. ' (valid: Red, Blue, Neutral, Common, Author)'
    end

    new_object.layerName = layer_name
    table.insert(target_layer.objects, new_object)

    local ok_call, err = pcall(panel.loadFromMission, data)
    if not ok_call then
        return nil, 'loadFromMission: ' .. tostring(err)
    end
    return new_object, nil
end

-- find_drawing_by_name — return the live drawing object (with its
-- primitiveType, mapData, etc.) by name. Walks all layers via
-- panel.getObjects() which produces a name → object map. Returns nil if
-- not found.
local function find_drawing_by_name(name)
    local panel = require('me_draw_panel')
    local objs = panel.getObjects()
    return objs[name]
end

-- unique_drawing_name — allocate the next free name with the given
-- prefix. Walks existing drawings; if "Circle-1" through "Circle-N" are
-- in use, returns "Circle-(N+1)". Mirrors the ME's own "Line-1" /
-- "Polygon-1" / "Text Box-1" / "Icon-1" naming but lets us pick the
-- prefix per shape for clarity.
local function unique_drawing_name(prefix)
    local panel = require('me_draw_panel')
    local objs = panel.getObjects()
    local n = 0
    repeat
        n = n + 1
    until objs[prefix .. '-' .. n] == nil
    return prefix .. '-' .. n
end

-- summarize_drawing — concise list-row shape (matches the convention used
-- by group_list / zone_list — translated north / east, the underlying
-- type, and the shape-defining field where relevant).
local function summarize_drawing(obj)
    local mode = obj.polygonMode or obj.lineMode
    return {
        name = obj.name,
        type = obj.primitiveType,
        mode = mode,
        layer = obj.layerName,
        north = obj.mapData and obj.mapData.x,
        east = obj.mapData and obj.mapData.y,
        color = obj.colorString,
        fill_color = obj.fillColorString,
        visible = obj.visible,
        hidden_on_planner = obj.hiddenOnPlanner,
    }
end

-- drawing_list — concise per-drawing summaries from all layers.
--
-- args (all optional):
--   layer:  Red | Blue | Neutral | Common | Author  (exact match)
--   type:   Line | Polygon | TextBox | Icon          (exact match)
--   mode:   circle | oval | rect | free | arrow | segments | segment
--   name:   substring (case-insensitive)
function M.drawing_list(args)
    args = args or {}
    local f_layer = args.layer
    local f_type = args.type
    local f_mode = args.mode and string.lower(args.mode) or nil
    local f_name = args.name and string.lower(args.name) or nil

    local panel = require('me_draw_panel')
    local out = {}
    for name, obj in pairs(panel.getObjects()) do
        local mode = obj.polygonMode or obj.lineMode
        if not (f_layer and obj.layerName ~= f_layer)
                and not (f_type and obj.primitiveType ~= f_type)
                and not (f_mode and (not mode or string.lower(mode) ~= f_mode))
                and not (f_name and not string.find(string.lower(name), f_name, 1, true)) then
            table.insert(out, summarize_drawing(obj))
        end
    end
    -- Stable order by name so the CLI output is repeatable.
    table.sort(out, function(a, b) return (a.name or '') < (b.name or '') end)
    return { ok = true, drawings = out, count = #out }
end

-- drawing_get — full structure of a single drawing by name.
-- Returns the on-disk (saveToMission) shape rather than the runtime
-- object, because per-shape fields live in different places at runtime:
--   * Polygon shapes: radius / width / height / r1 / r2 / length live
--     at the object level (good for runtime but on-disk too).
--   * TextBox: text / fontSize / borderThickness / font / angle live in
--     mapData only — runtime object doesn't promote them.
--   * Icon: file / scale / angle live both in mapData and object.
-- The on-disk shape unifies these — saveToMission's per-shape savers
-- produce a flat object with every field needed to round-trip the
-- drawing through loadFromMission. Use that as the canonical writable
-- surface, plus translated north / east at the top level.
function M.drawing_get(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'drawing_get requires args.name (string)' }
    end
    local panel = require('me_draw_panel')
    local data = panel.saveToMission()
    for _, layer in ipairs(data.layers or {}) do
        for _, obj_save in ipairs(layer.objects or {}) do
            if obj_save.name == args.name then
                local snapshot = {}
                for k, v in pairs(obj_save) do snapshot[k] = v end
                -- Surface position in our --north/--east convention at top
                -- level (matches the get-verb shape used elsewhere).
                snapshot.north = obj_save.mapX
                snapshot.east = obj_save.mapY
                return { ok = true, drawing = snapshot }
            end
        end
    end
    return { ok = false, error = 'drawing not found' }
end

-- drawing_remove — remove a drawing by name. Wraps panel.objectDelete.
function M.drawing_remove(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'drawing_remove requires args.name (string)' }
    end
    local panel = require('me_draw_panel')
    local obj = panel.getObjects()[args.name]
    if not obj then
        return { ok = false, error = 'drawing not found' }
    end
    local ok_call, err = pcall(panel.objectDelete, obj)
    if not ok_call then
        return { ok = false, error = 'objectDelete: ' .. tostring(err) }
    end
    return { ok = true, name = args.name }
end

-- ============================================================
-- Drawings — create-* verbs
-- ============================================================
--
-- Each builds the right on-disk shape (per saveToMission's per-shape
-- savers in me_draw_panel.lua) and routes through inject_drawing.
--
-- Common fields every shape needs:
--   primitiveType  Line | Polygon | TextBox | Icon
--   name           unique across all layers (verifyName enforces)
--   colorString    '0xRRGGBBAA' (outline color)
--   mapX, mapY     world coords (mission-table x = N–S, y = E–W)
--   visible        bool
--   layerName      Red | Blue | Neutral | Common | Author
--   hiddenOnPlanner  bool
--
-- Polygon adds: polygonMode (circle/oval/rect/free/arrow), style,
-- thickness, fillColorString, plus mode-specific shape fields.
-- Line adds:    lineMode (segments/segment/free), style, thickness,
--               closed, points (relative to mapX/mapY).
-- TextBox adds: text, font, fontSize, borderThickness, angle.
-- Icon adds:    file (relative to icons folder), scale, angle.

-- DEFAULT_LINE_STYLE / DEFAULT_THICKNESS — match the panel's own
-- newPrimitiveInfo_ defaults at me_draw_panel.lua:157. lineStyles_ holds
-- per-style canonical thickness; without a panel hook we hard-code
-- 'solid' = 2 which matches ED's polyline_solid.png pixel height.
local DEFAULT_LINE_STYLE = 'solid'
local DEFAULT_THICKNESS = 2

-- drawing_create_circle — disk-shape polygon (filled disc with outline).
--
-- args (required):
--   north, east   meters; center of the circle
--   radius        meters
--
-- args (optional):
--   name             default 'Circle-N' (auto-incremented)
--   color            '0xRRGGBBAA' (outline; default red, opaque)
--   fill_color       '0xRRGGBBAA' (fill;    default red, half-alpha)
--   thickness        outline thickness in pixels (default 2)
--   style            line style: solid / dot / dash / boundry1 ... (default 'solid')
--   layer            Red | Blue | Neutral | Common | Author (default 'Common')
--   hidden_on_planner   bool (default false)
function M.drawing_create_circle(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'drawing_create_circle requires args (table)' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'drawing_create_circle requires args.north and args.east (numbers, meters)' }
    end
    if type(args.radius) ~= 'number' or args.radius <= 0 then
        return { ok = false, error = 'drawing_create_circle requires args.radius (positive number, meters)' }
    end

    local name = (type(args.name) == 'string' and args.name ~= '') and args.name
                 or unique_drawing_name('Circle')
    local obj = {
        primitiveType = 'Polygon',
        polygonMode = 'circle',
        name = name,
        colorString = args.color or '0xff0000ff',
        fillColorString = args.fill_color or '0xff000080',
        mapX = args.north, mapY = args.east,
        visible = true,
        hiddenOnPlanner = (args.hidden_on_planner == true),
        style = args.style or DEFAULT_LINE_STYLE,
        thickness = args.thickness or DEFAULT_THICKNESS,
        radius = args.radius,
    }
    local _, err = inject_drawing(obj, args.layer or 'Common')
    if err then return { ok = false, error = err } end
    return { ok = true, name = name, type = 'Polygon', mode = 'circle',
             north = args.north, east = args.east, radius = args.radius,
             layer = args.layer or 'Common' }
end

-- drawing_create_rect — axis-aligned rectangle (or rotated, via --angle).
-- args (required): north, east, width, height
-- args (optional): name, color, fill_color, thickness, style, layer,
--                  hidden_on_planner, angle (radians, default 0)
function M.drawing_create_rect(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'drawing_create_rect requires args (table)' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'drawing_create_rect requires args.north and args.east (numbers, meters)' }
    end
    if type(args.width) ~= 'number' or args.width <= 0
            or type(args.height) ~= 'number' or args.height <= 0 then
        return { ok = false, error = 'drawing_create_rect requires args.width and args.height (positive numbers, meters)' }
    end
    local name = (type(args.name) == 'string' and args.name ~= '') and args.name
                 or unique_drawing_name('Rect')
    -- IMPORTANT: drawing `angle` is stored in DEGREES, not radians. The ME's
    -- own draw panel reads/writes mapData.angle as a 0..360 integer
    -- (objectUpdateSpinBoxAngle at me_draw_panel.lua:558 clamps to that
    -- range with math.floor(angle + 0.5)) — this is opposite to unit/group
    -- heading which IS radians. Don't math.rad it.
    local angle = args.angle_deg or 0
    local obj = {
        primitiveType = 'Polygon', polygonMode = 'rect', name = name,
        colorString = args.color or '0xff0000ff',
        fillColorString = args.fill_color or '0xff000080',
        mapX = args.north, mapY = args.east,
        visible = true, hiddenOnPlanner = (args.hidden_on_planner == true),
        style = args.style or DEFAULT_LINE_STYLE,
        thickness = args.thickness or DEFAULT_THICKNESS,
        width = args.width, height = args.height,
        angle = angle,
    }
    local _, err = inject_drawing(obj, args.layer or 'Common')
    if err then return { ok = false, error = err } end
    return { ok = true, name = name, type = 'Polygon', mode = 'rect',
             north = args.north, east = args.east,
             width = args.width, height = args.height, angle = angle,
             layer = args.layer or 'Common' }
end

-- drawing_create_oval — ellipse with semi-axes r1 (along local X) and r2.
-- args (required): north, east, r1, r2
-- args (optional): name, color, fill_color, thickness, style, layer,
--                  hidden_on_planner, angle (radians, default 0)
function M.drawing_create_oval(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'drawing_create_oval requires args (table)' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'drawing_create_oval requires args.north and args.east (numbers, meters)' }
    end
    if type(args.r1) ~= 'number' or args.r1 <= 0
            or type(args.r2) ~= 'number' or args.r2 <= 0 then
        return { ok = false, error = 'drawing_create_oval requires args.r1 and args.r2 (positive numbers, meters)' }
    end
    local name = (type(args.name) == 'string' and args.name ~= '') and args.name
                 or unique_drawing_name('Oval')
    -- See drawing_create_rect for why angle is degrees, not radians.
    local angle = args.angle_deg or 0
    local obj = {
        primitiveType = 'Polygon', polygonMode = 'oval', name = name,
        colorString = args.color or '0xff0000ff',
        fillColorString = args.fill_color or '0xff000080',
        mapX = args.north, mapY = args.east,
        visible = true, hiddenOnPlanner = (args.hidden_on_planner == true),
        style = args.style or DEFAULT_LINE_STYLE,
        thickness = args.thickness or DEFAULT_THICKNESS,
        r1 = args.r1, r2 = args.r2,
        angle = angle,
    }
    local _, err = inject_drawing(obj, args.layer or 'Common')
    if err then return { ok = false, error = err } end
    return { ok = true, name = name, type = 'Polygon', mode = 'oval',
             north = args.north, east = args.east,
             r1 = args.r1, r2 = args.r2, angle = angle,
             layer = args.layer or 'Common' }
end

-- drawing_create_arrow — arrow-shape polygon. The shape's body points are
-- generated by polygonArrowMakePoints(length) at load time, so we don't
-- have to compute them — providing length + angle is enough. The
-- saveToMission output stores points (the runtime values), but they're
-- regenerated from length on load, so any value here is overwritten.
--
-- args (required): north, east, length
-- args (optional): name, color, fill_color, thickness, style, layer,
--                  hidden_on_planner, angle (radians, default 0)
function M.drawing_create_arrow(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'drawing_create_arrow requires args (table)' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'drawing_create_arrow requires args.north and args.east (numbers, meters)' }
    end
    if type(args.length) ~= 'number' or args.length <= 0 then
        return { ok = false, error = 'drawing_create_arrow requires args.length (positive number, meters)' }
    end
    local name = (type(args.name) == 'string' and args.name ~= '') and args.name
                 or unique_drawing_name('Arrow')
    -- See drawing_create_rect for why angle is degrees, not radians.
    local angle = args.angle_deg or 0
    local obj = {
        primitiveType = 'Polygon', polygonMode = 'arrow', name = name,
        colorString = args.color or '0xff0000ff',
        fillColorString = args.fill_color or '0xff000080',
        mapX = args.north, mapY = args.east,
        visible = true, hiddenOnPlanner = (args.hidden_on_planner == true),
        style = args.style or DEFAULT_LINE_STYLE,
        thickness = args.thickness or DEFAULT_THICKNESS,
        length = args.length,
        angle = angle,
        -- points field is required by saveToMission but regenerated on
        -- load via polygonArrowMakePoints(length). Empty placeholder.
        points = {},
    }
    local _, err = inject_drawing(obj, args.layer or 'Common')
    if err then return { ok = false, error = err } end
    return { ok = true, name = name, type = 'Polygon', mode = 'arrow',
             north = args.north, east = args.east, length = args.length,
             angle = angle, layer = args.layer or 'Common' }
end

-- compute_center_and_relative_points — shared helper for line and free
-- polygon. Takes a list of {north, east} absolute world coords and
-- returns center (mapX, mapY) + relative points table {{x, y}, ...}
-- where (x, y) is each vertex's offset from the center. Same convention
-- as zone_create_quad uses internally.
local function compute_center_and_relative_points(vertices)
    local cx, cy = 0, 0
    for _, v in ipairs(vertices) do
        cx = cx + v.north; cy = cy + v.east
    end
    cx = cx / #vertices; cy = cy / #vertices
    local rel = {}
    for _, v in ipairs(vertices) do
        table.insert(rel, { x = v.north - cx, y = v.east - cy })
    end
    return cx, cy, rel
end

-- drawing_create_line — multi-segment line / polyline.
--
-- args (required):
--   vertices  list of { north, east } in absolute world meters (>= 2)
--
-- args (optional):
--   name, color, thickness, style, layer, hidden_on_planner
--   closed     bool (default false; closes the polyline back to first vertex)
--   line_mode  segments | segment | free  (default 'segments')
function M.drawing_create_line(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'drawing_create_line requires args (table)' }
    end
    if type(args.vertices) ~= 'table' or #args.vertices < 2 then
        return { ok = false, error = 'drawing_create_line requires args.vertices (>= 2 {north,east} pairs)' }
    end
    for i, v in ipairs(args.vertices) do
        if type(v) ~= 'table' or type(v.north) ~= 'number' or type(v.east) ~= 'number' then
            return { ok = false, error = 'vertex ' .. i .. ' missing/invalid {north, east} numbers' }
        end
    end

    local cx, cy, rel = compute_center_and_relative_points(args.vertices)
    local name = (type(args.name) == 'string' and args.name ~= '') and args.name
                 or unique_drawing_name('Line')

    local obj = {
        primitiveType = 'Line',
        name = name,
        colorString = args.color or '0xff0000ff',
        mapX = cx, mapY = cy,
        visible = true,
        hiddenOnPlanner = (args.hidden_on_planner == true),
        lineMode = args.line_mode or 'segments',
        style = args.style or DEFAULT_LINE_STYLE,
        thickness = args.thickness or DEFAULT_THICKNESS,
        closed = (args.closed == true),
        points = rel,
    }
    local _, err = inject_drawing(obj, args.layer or 'Common')
    if err then return { ok = false, error = err } end
    return { ok = true, name = name, type = 'Line', mode = obj.lineMode,
             north = cx, east = cy, vertex_count = #rel,
             closed = obj.closed, layer = args.layer or 'Common' }
end

-- drawing_create_polygon — free-shape polygon (closed, filled).
--
-- DCS's free-polygon renderer auto-connects the last vertex back to the
-- first to close the shape. Sub-pixel artifacts on the closing edge
-- have been reported when the agent supplies "exactly the right number
-- of distinct vertices" — e.g. a 5-point star drawn as 10 alternating
-- outer/inner vertices, where the close-edge from p10 back to p1
-- doesn't render cleanly. Defensively: if the last supplied vertex is
-- not already a copy of the first, we append a duplicate of the first
-- as the closing vertex. Zero-length edge geometrically; better
-- rendering in practice.
--
-- args (required): vertices (>= 3)
-- args (optional): name, color, fill_color, thickness, style, layer,
--                  hidden_on_planner
function M.drawing_create_polygon(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'drawing_create_polygon requires args (table)' }
    end
    if type(args.vertices) ~= 'table' or #args.vertices < 3 then
        return { ok = false, error = 'drawing_create_polygon requires args.vertices (>= 3 {north,east} pairs)' }
    end
    for i, v in ipairs(args.vertices) do
        if type(v) ~= 'table' or type(v.north) ~= 'number' or type(v.east) ~= 'number' then
            return { ok = false, error = 'vertex ' .. i .. ' missing/invalid {north, east} numbers' }
        end
    end

    -- Defensive close: append a duplicate of the first vertex if it
    -- isn't already the last one. See block comment above for why.
    local first = args.vertices[1]
    local last = args.vertices[#args.vertices]
    if first.north ~= last.north or first.east ~= last.east then
        table.insert(args.vertices, { north = first.north, east = first.east })
    end

    local cx, cy, rel = compute_center_and_relative_points(args.vertices)
    local name = (type(args.name) == 'string' and args.name ~= '') and args.name
                 or unique_drawing_name('Polygon')

    local obj = {
        primitiveType = 'Polygon', polygonMode = 'free', name = name,
        colorString = args.color or '0xff0000ff',
        fillColorString = args.fill_color or '0xff000080',
        mapX = cx, mapY = cy,
        visible = true,
        hiddenOnPlanner = (args.hidden_on_planner == true),
        style = args.style or DEFAULT_LINE_STYLE,
        thickness = args.thickness or DEFAULT_THICKNESS,
        points = rel,
    }
    local _, err = inject_drawing(obj, args.layer or 'Common')
    if err then return { ok = false, error = err } end
    return { ok = true, name = name, type = 'Polygon', mode = 'free',
             north = cx, east = cy, vertex_count = #rel,
             layer = args.layer or 'Common' }
end

-- drawing_create_textbox — text label at a map point.
--
-- args (required):
--   north, east   meters; anchor of the textbox
--   text          string to display
--
-- args (optional):
--   name              default 'Text Box-N'
--   color             text color (default 0x00ff00ff = green opaque)
--   fill_color        background fill (default 0xff000080 = red 50%)
--   font              ttf file name (default 'DejaVuLGCSansCondensed.ttf')
--   font_size         pixels (default 24)
--   border_thickness  pixels (default 4)
--   angle             radians (default 0)
--   layer             default 'Common'
--   hidden_on_planner default false
function M.drawing_create_textbox(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'drawing_create_textbox requires args (table)' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'drawing_create_textbox requires args.north and args.east (numbers, meters)' }
    end
    if type(args.text) ~= 'string' or args.text == '' then
        return { ok = false, error = 'drawing_create_textbox requires args.text (non-empty string)' }
    end
    local name = (type(args.name) == 'string' and args.name ~= '') and args.name
                 or unique_drawing_name('Text Box')
    -- See drawing_create_rect for why angle is degrees, not radians.
    local angle = args.angle_deg or 0
    local obj = {
        primitiveType = 'TextBox', name = name,
        colorString = args.color or '0x00ff00ff',
        fillColorString = args.fill_color or '0xff000080',
        mapX = args.north, mapY = args.east,
        visible = true, hiddenOnPlanner = (args.hidden_on_planner == true),
        text = args.text,
        font = args.font or 'DejaVuLGCSansCondensed.ttf',
        fontSize = args.font_size or 24,
        borderThickness = args.border_thickness or 4,
        angle = angle,
    }
    local _, err = inject_drawing(obj, args.layer or 'Common')
    if err then return { ok = false, error = err } end
    return { ok = true, name = name, type = 'TextBox',
             north = args.north, east = args.east, text = args.text,
             layer = args.layer or 'Common' }
end

-- drawing_create_icon — icon (NATO/Russian symbol or custom png) at a
-- map point. The icon `file` is a filename within the active icon
-- folder ('./MissionEditor/data/NewMap/images/<theme>/' where theme is
-- 'nato' or 'russian' depending on the user's options). User picks
-- which theme, we just store the bare filename.
--
-- args (required):
--   north, east   meters; anchor of the icon
--   file          icon filename (e.g. 'aaa_air_neutral.png')
--
-- args (optional):
--   name, color (tint, default white opaque), scale (default 1),
--   angle (radians, default 0), layer, hidden_on_planner
function M.drawing_create_icon(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'drawing_create_icon requires args (table)' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'drawing_create_icon requires args.north and args.east (numbers, meters)' }
    end
    if type(args.file) ~= 'string' or args.file == '' then
        return { ok = false, error = 'drawing_create_icon requires args.file (icon filename)' }
    end
    local name = (type(args.name) == 'string' and args.name ~= '') and args.name
                 or unique_drawing_name('Icon')
    -- See drawing_create_rect for why angle is degrees, not radians.
    local angle = args.angle_deg or 0
    local obj = {
        primitiveType = 'Icon', name = name,
        colorString = args.color or '0xffffffff',
        mapX = args.north, mapY = args.east,
        visible = true, hiddenOnPlanner = (args.hidden_on_planner == true),
        file = args.file,
        scale = args.scale or 1,
        angle = angle,
    }
    local _, err = inject_drawing(obj, args.layer or 'Common')
    if err then return { ok = false, error = err } end
    return { ok = true, name = name, type = 'Icon',
             north = args.north, east = args.east, file = args.file,
             layer = args.layer or 'Common' }
end

-- ============================================================
-- Drawings — setters (per-field)
-- ============================================================

-- drawing_set_color — change outline / line / text color (the
-- colorString field). For polygons + textboxes this is the OUTLINE /
-- BORDER / TEXT color; the fill is set via drawing_set_fill_color.
-- For lines and icons this is the only color the shape has.
function M.drawing_set_color(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'drawing_set_color requires args.name (string)' }
    end
    if type(args.color) ~= 'string' or args.color == '' then
        return { ok = false, error = 'drawing_set_color requires args.color (hex string like 0xrrggbbaa)' }
    end
    local obj, err = mutate_drawing(args.name, function(o) o.colorString = args.color end)
    if err then return { ok = false, error = err } end
    return { ok = true, name = args.name, color = obj.colorString }
end

-- drawing_set_fill_color — change fill color (polygon shapes + textbox
-- only). Refuses on Line / Icon — those have no fill concept.
function M.drawing_set_fill_color(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'drawing_set_fill_color requires args.name (string)' }
    end
    if type(args.color) ~= 'string' or args.color == '' then
        return { ok = false, error = 'drawing_set_fill_color requires args.color (hex string like 0xrrggbbaa)' }
    end
    local target = find_drawing_by_name(args.name)
    if not target then return { ok = false, error = 'drawing not found' } end
    if target.primitiveType == 'Line' or target.primitiveType == 'Icon' then
        return { ok = false,
                 error = target.primitiveType .. ' has no fill — use drawing_set_color instead' }
    end
    local obj, err = mutate_drawing(args.name, function(o) o.fillColorString = args.color end)
    if err then return { ok = false, error = err } end
    return { ok = true, name = args.name, fill_color = obj.fillColorString }
end

-- drawing_set_pos — move the drawing's anchor (mapX / mapY). For shapes
-- with relative-to-anchor points (line, free polygon) the relative
-- offsets ride along, so the shape moves rigidly. For analytic shapes
-- (circle, rect, oval, arrow) only the center moves.
function M.drawing_set_pos(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'drawing_set_pos requires args.name (string)' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'drawing_set_pos requires args.north and args.east (numbers, meters)' }
    end
    local obj, err = mutate_drawing(args.name, function(o)
        o.mapX = args.north
        o.mapY = args.east
    end)
    if err then return { ok = false, error = err } end
    return { ok = true, name = args.name, north = obj.mapX, east = obj.mapY }
end

-- drawing_set_name — rename a drawing. Refuses on collision via the
-- panel's verifyName (drawing names are unique across all layers).
function M.drawing_set_name(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'drawing_set_name requires args.name (string)' }
    end
    if type(args.new_name) ~= 'string' or args.new_name == '' then
        return { ok = false, error = 'drawing_set_name requires args.new_name (non-empty string)' }
    end
    if args.new_name == args.name then
        return { ok = true, name = args.new_name, unchanged = true }
    end
    if find_drawing_by_name(args.new_name) then
        return { ok = false, error = 'name "' .. args.new_name .. '" already in use' }
    end
    local obj, err = mutate_drawing(args.name, function(o) o.name = args.new_name end)
    if err then return { ok = false, error = err } end
    return { ok = true, name = obj.name, previous_name = args.name }
end

-- drawing_set_text — change the text content of a TextBox. Refuses on
-- non-TextBox drawings.
function M.drawing_set_text(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'drawing_set_text requires args.name (string)' }
    end
    if type(args.text) ~= 'string' or args.text == '' then
        return { ok = false, error = 'drawing_set_text requires args.text (non-empty string)' }
    end
    local target = find_drawing_by_name(args.name)
    if not target then return { ok = false, error = 'drawing not found' } end
    if target.primitiveType ~= 'TextBox' then
        return { ok = false, error = 'drawing is ' .. target.primitiveType
                                     .. ', not TextBox; use drawing_remove + drawing_create_textbox' }
    end
    local obj, err = mutate_drawing(args.name, function(o) o.text = args.text end)
    if err then return { ok = false, error = err } end
    return { ok = true, name = args.name, text = obj.text }
end

-- drawing_set_thickness — change outline / line thickness in pixels.
-- Applies to Line and Polygon shapes. Refuses on TextBox (which has
-- borderThickness instead) and Icon (which has scale).
function M.drawing_set_thickness(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'drawing_set_thickness requires args.name (string)' }
    end
    if type(args.thickness) ~= 'number' or args.thickness <= 0 then
        return { ok = false, error = 'drawing_set_thickness requires args.thickness (positive number)' }
    end
    local target = find_drawing_by_name(args.name)
    if not target then return { ok = false, error = 'drawing not found' } end
    if target.primitiveType ~= 'Line' and target.primitiveType ~= 'Polygon' then
        return { ok = false, error = target.primitiveType
                                     .. ' has no thickness (TextBox has border-thickness; Icon has scale)' }
    end
    local obj, err = mutate_drawing(args.name, function(o) o.thickness = args.thickness end)
    if err then return { ok = false, error = err } end
    return { ok = true, name = args.name, thickness = obj.thickness }
end

-- drawing_set_angle — rotate a drawing around its anchor.
--
-- Supported shapes (those with an angle field in saveToMission):
--   * TextBox     — rotates the text label
--   * Icon        — rotates the icon image
--   * Polygon oval / rect / arrow — rotates the analytic shape
--
-- Refused shapes:
--   * Line        — no angle field; shape geometry is the points list
--   * Polygon circle  — rotation is meaningless (rotation-symmetric)
--   * Polygon free    — rotation would need to transform every point;
--                       remove + re-create with rotated vertices
--                       (or wait for a future drawing_rotate-points helper)
--
-- Args:
--   name       drawing name (required)
--   angle_deg  rotation in degrees (CW positive). Stored verbatim — the
--              ME's draw panel reads/writes mapData.angle as DEGREES
--              (objectUpdateSpinBoxAngle at me_draw_panel.lua:558 does
--              math.floor(angle + 0.5) clamped [0, 360]). Opposite to
--              unit/group heading which IS radians; ED inconsistency.
function M.drawing_set_angle(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'drawing_set_angle requires args.name (string)' }
    end
    if type(args.angle_deg) ~= 'number' then
        return { ok = false, error = 'drawing_set_angle requires args.angle_deg (number, degrees)' }
    end
    local target = find_drawing_by_name(args.name)
    if not target then return { ok = false, error = 'drawing not found' } end

    -- Type / mode gate. Only the shapes that have an `angle` field in
    -- saveToMission's per-shape savers can be rotated this way.
    local pt = target.primitiveType
    local mode = target.polygonMode
    local rotatable =
        pt == 'TextBox' or pt == 'Icon'
        or (pt == 'Polygon' and (mode == 'oval' or mode == 'rect' or mode == 'arrow'))
    if not rotatable then
        local descriptor = pt
        if pt == 'Polygon' and mode then descriptor = 'Polygon ' .. mode end
        return { ok = false,
                 error = descriptor .. ' has no rotation; supported: TextBox, Icon, '
                         .. 'Polygon oval/rect/arrow' }
    end

    -- Degrees stored verbatim; no math.rad — see comment above.
    local obj, err = mutate_drawing(args.name, function(o) o.angle = args.angle_deg end)
    if err then return { ok = false, error = err } end
    return { ok = true, name = args.name, angle = obj.angle }
end

-- ============================================================
-- Read-side verbs: list / get
-- ============================================================
--
-- Output convention:
--   * list verbs return concise summaries with translated north / east
--     (matching our --north / --east flag convention)
--   * get verbs return the raw mission-table structure (so callers can see
--     the underlying field names — useful when designing future setter
--     verbs or scripting). Cycle-causing back-references (boss, mapObjects)
--     are stripped to keep JSON serializable.

-- ============================================================
-- Trigger verbs (mission.trigrules)
-- ============================================================
--
-- mission.trigrules is the editor source-of-truth. Each entry has shape:
--   { predicate = "triggerOnce" | "triggerContinious" | "triggerStart" | "triggerFront",
--     comment   = "<user-facing name>",
--     eventlist = "" | <event id>,
--     rules     = { { predicate = "c_*", ...field args... }, ... },
--     actions   = { { predicate = "a_*", ...field args... }, ... } }
--
-- ED's me_mission.unload regenerates mission.trig.{conditions,actions,func,
-- events,funcStartup} from trigrules at save time (me_mission.lua:4592-4598),
-- so we never touch mission.trig.* directly — only trigrules.

-- _trigger_alias_cache — lazy-built map of every predicate ED knows about,
-- keyed by both canonical name AND friendly kebab-alias. Each value is
-- { canonical=..., kind="condition"|"action"|"trigger", descr=<field-schema> }.
-- Cleared on first call after init; rebuilt only if ED's descriptor tables
-- look like they've shifted (descriptor tables are session-stable in
-- practice — this cache is a perf optimization, not a correctness gate).
local _trigger_alias_cache

-- _trigger_predicate_name — normalize a predicate value to its canonical
-- string name, regardless of whether ED stored it as a string (in-memory
-- after createTrigger / fresh insert) or a descriptor table (loaded from
-- disk by me_mission.load via Trigger.loadTriggers, which expands string
-- names to {name=..., fields=...} entries).
--
-- Returns "" for unrecognized shapes so callers can short-circuit cleanly.
local function _trigger_predicate_name(p)
    if type(p) == 'string' then return p end
    if type(p) == 'table' and type(p.name) == 'string' then return p.name end
    return ''
end

-- _trigger_make_alias — strip prefix + underscore→dash to get the friendly
-- form. "c_flag_is_true" → "flag-is-true", "a_set_flag" → "set-flag",
-- "triggerOnce" → "once", "triggerContinious" → "continuous" (fixes typo).
-- Accepts either a canonical string or a {name=..., fields=...} descriptor
-- table — ED uses both shapes for the predicate field depending on whether
-- the trigger was just created (string) or loaded from disk (table).
local function _trigger_make_alias(canonical)
    local s = _trigger_predicate_name(canonical)
    if s == '' then return '' end
    if s:sub(1, 2) == 'c_' or s:sub(1, 2) == 'a_' then
        s = s:sub(3)
    elseif s:sub(1, 7) == 'trigger' then
        s = s:sub(8)
        -- Special case: ED's misspelling of "Continuous"
        if s == 'Continious' then return 'continuous' end
    end
    return s:gsub('_', '-'):lower()
end

-- _trigger_build_alias_cache — populate _trigger_alias_cache by walking ED's
-- three descriptor arrays: me_predicates.rulesDescr (conditions, c_*),
-- me_trigrules.actionsDescr (actions, a_*), and me_trigrules.triggersDescr
-- (trigger types). actionsDescr and triggersDescr are pure 1-indexed arrays.
-- rulesDescr is mostly a 1-indexed array but ALSO carries pseudo-predicates
-- under string keys (currently just `["or"]` — see me_predicates.lua:1555,
-- "special predicates have individual key"); pairs() picks both up.
local function _trigger_build_alias_cache()
    local Trigger = require('me_trigrules')
    local Predicates = require('me_predicates')
    local cache = {}

    -- Conditions: me_predicates.rulesDescr is mostly { name = "c_*", ...}
    -- entries, plus pseudo-predicates like ["or"] keyed by their literal
    -- name. Walk with pairs() so we pick up both shapes.
    if type(Predicates.rulesDescr) == 'table' then
        for _, descr in pairs(Predicates.rulesDescr) do
            if type(descr) == 'table' and type(descr.name) == 'string' then
                local entry = { canonical = descr.name, kind = 'condition', descr = descr }
                cache[descr.name] = entry
                cache[_trigger_make_alias(descr.name)] = entry
            end
        end
    end

    -- Actions: me_trigrules.actionsDescr is the same shape with "a_*" names.
    if type(Trigger.actionsDescr) == 'table' then
        for _, descr in ipairs(Trigger.actionsDescr) do
            if type(descr) == 'table' and type(descr.name) == 'string' then
                local entry = { canonical = descr.name, kind = 'action', descr = descr }
                cache[descr.name] = entry
                cache[_trigger_make_alias(descr.name)] = entry
            end
        end
    end

    -- Trigger types: me_trigrules.triggersDescr.
    if type(Trigger.triggersDescr) == 'table' then
        for _, descr in ipairs(Trigger.triggersDescr) do
            if type(descr) == 'table' and type(descr.name) == 'string' then
                local entry = { canonical = descr.name, kind = 'trigger', descr = descr }
                cache[descr.name] = entry
                cache[_trigger_make_alias(descr.name)] = entry
            end
        end
    end

    _trigger_alias_cache = cache
end

-- _trigger_resolve_predicate — name-or-alias → canonical_name, kind, descr,
-- err. Optionally filter by kind ("condition" / "action" / "trigger") to
-- disambiguate — passing kind=nil accepts any.
local function _trigger_resolve_predicate(name_or_alias, expected_kind)
    if not _trigger_alias_cache then _trigger_build_alias_cache() end
    local entry = _trigger_alias_cache[name_or_alias]
    if not entry then
        return nil, nil, nil, 'unknown predicate "' .. tostring(name_or_alias) .. '"'
    end
    if expected_kind and entry.kind ~= expected_kind then
        return nil, nil, nil,
               'predicate "' .. name_or_alias .. '" is a ' .. entry.kind
               .. ', expected ' .. expected_kind
    end
    return entry.canonical, entry.kind, entry.descr, nil
end

-- _trigger_panel_refresh — best-effort kick: if the trigger panel is
-- currently visible, rebind its listbox against the current
-- mission.trigrules.
--
-- We do NOT call Trigger.show(true) for this. show(true) calls
-- ED's fixTriggers() which DELETES any trigger with #actions < 1
-- (see me_trigrules.lua: function fixTriggers — invalid trigger
-- removed). Freshly-created triggers from `trigger create` have
-- empty actions by design (the user fills them in via subsequent
-- `trigger action ...` verbs), so show(true) silently wipes them
-- before the listbox is rebound. Same reason show(false) was bad:
-- it leads back into the same purge path on close-then-reopen.
--
-- Instead we go straight to predicates.rulesToList(window.triggersList,
-- mission.trigrules, cdata) — that's the same listbox-rebind helper
-- ED itself uses elsewhere (e.g. the trigger-reorder buttons), and
-- it has no fixTriggers / no data mutation. It just clears the
-- listbox and re-adds an item per entry in mission.trigrules.
local function _trigger_panel_refresh()
    local ok_t, Trigger = pcall(require, 'me_trigrules')
    if not ok_t or type(Trigger) ~= 'table' then return end
    local visible = false
    if type(Trigger.triggersWindow) == 'table' and type(Trigger.triggersWindow.isVisible) == 'function' then
        local ok_vis, vis = pcall(Trigger.triggersWindow.isVisible, Trigger.triggersWindow)
        visible = ok_vis and vis == true
    end
    if not visible then return end

    local ok_p, predicates = pcall(require, 'me_predicates')
    if not ok_p or type(predicates) ~= 'table'
       or type(predicates.rulesToList) ~= 'function' then return end

    local box = Trigger.triggersWindow.Box
    if type(box) ~= 'table' or type(box.triggersList) ~= 'table' then return end

    local ok_m, Mission = pcall(require, 'me_mission')
    if not ok_m or type(Mission) ~= 'table'
       or type(Mission.mission) ~= 'table' then return end
    local trigrules = Mission.mission.trigrules or {}

    -- cdata is module-local in me_trigrules; fall back to nil — rulesToList
    -- only uses cdata for predicate-text rendering and tolerates nil.
    local cdata = Trigger.cdata
    pcall(predicates.rulesToList, box.triggersList, trigrules, cdata)
end

-- _trigger_find_by_name — locate a trigger in mission.trigrules by its
-- comment field. Returns trigger, index_1based, total_count or nil.
local function _trigger_find_by_name(name)
    local Mission = require('me_mission')
    local mission = Mission.mission
    if type(mission) ~= 'table' or type(mission.trigrules) ~= 'table' then
        return nil, nil, 0
    end
    for i, t in ipairs(mission.trigrules) do
        if type(t) == 'table' and t.comment == name then
            return t, i, #mission.trigrules
        end
    end
    return nil, nil, #mission.trigrules
end

-- _trigger_unique_name — auto-suffix "-2", "-3", ... on collision (matches
-- the existing me group create-* collision behavior).
local function _trigger_unique_name(base)
    if not _trigger_find_by_name(base) then return base end
    local n = 2
    while _trigger_find_by_name(base .. '-' .. n) do n = n + 1 end
    return base .. '-' .. n
end

-- _trigger_default_name — ED's default when the user hits "new trigger" in
-- the panel: "Trigger " .. os.time(). We mirror it for parity.
local function _trigger_default_name()
    return 'Trigger ' .. tostring(os.time())
end

-- _trigger_field_combo_kind — classify a field's reference kind by its
-- comboFunc slot, with a fallback by descriptor-table identity. Returns
-- "group" / "unit" / "zone" / "coalition" / "airdrome" / "event" / "draw"
-- / nil (literal field, no resolution).
--
-- Two-tier detection:
--   1. If the field IS one of the shared selector tables exported by
--      me_predicates (UNIT_SELECTOR / VEHICLE_SELECTOR / AIRCARRIER_SELECTOR
--      / DRAW_SELECTOR), classify by table identity. This is required
--      because their comboFunc (unitsLister, drawObjectsLister, ...) is
--      LOCAL in me_predicates.lua and can't be reached from outside the
--      module — so the comboFunc-based check below would silently miss
--      them, leaving entry.<field> as the unresolved name string instead
--      of the numeric id the panel/save expect (issue #45).
--   2. Otherwise compare comboFunc against the listers that ARE exported.
local function _trigger_field_combo_kind(field_descr)
    if type(field_descr) ~= 'table' or field_descr.type ~= 'combo' then
        return nil
    end

    local Trigger = require('me_trigrules')
    local Predicates = require('me_predicates')

    -- Tier 1: shared selector descriptors. The predicate's `fields` array
    -- references these tables BY VALUE (e.g. me_predicates rulesDescr has
    -- `fields = { UNIT_SELECTOR, ... }`), so identity comparison is
    -- reliable.
    if field_descr == Predicates.UNIT_SELECTOR
            or field_descr == Predicates.VEHICLE_SELECTOR
            or field_descr == Predicates.AIRCARRIER_SELECTOR then
        return 'unit'
    end
    if field_descr == Predicates.DRAW_SELECTOR then
        return 'draw'
    end

    -- Tier 2: comboFunc identity. Most listers are exported on the module
    -- table; the few that aren't (unitsLister and friends) are handled by
    -- tier 1 above.
    local fn = field_descr.comboFunc
    if type(fn) ~= 'function' then return nil end

    -- Group references — multiple variants (generic, static, air-helicopter,
    -- vehicle, vehicle-static, etc) all classify as "group".
    if fn == Trigger.groupsLister
            or fn == Trigger.groupsStaticLister
            or fn == Trigger.groupsAHLister
            or fn == Trigger.groupsListerS
            or fn == Trigger.groupsVLister
            or fn == Trigger.groupsVSLister
            or fn == Predicates.groupsLister then
        return 'group'
    end

    -- Zone references.
    if fn == Predicates.zonesLister then return 'zone' end

    -- Coalition references.
    if fn == Trigger.coalitionIdToName
            or fn == Trigger.coalition2IdToName
            or fn == Trigger.winnerLister
            or fn == Predicates.coalitionIdToName
            or fn == Predicates.coalitionIdToName2 then
        return 'coalition'
    end

    -- Airdrome / helipad references.
    if fn == Trigger.airdromeAndHeliportLister
            or fn == Predicates.airdromeLister
            or fn == Predicates.helipadLister then
        return 'airdrome'
    end

    -- Event references.
    if fn == Trigger.eventLister then return 'event' end

    return nil
end

-- _trigger_resolve_ref — value normalization for reference fields. If kind
-- is group/unit/zone, accept either an integer id or a name (string) and
-- return the integer id. For coalition, pass through. For other kinds,
-- pass through. Returns resolved_value, err.
local function _trigger_resolve_ref(kind, value)
    -- 'draw' targets are draw-object names (strings); the panel's combo
    -- stores them as-is, so no name→id resolution is needed.
    if kind == 'coalition' or kind == 'event' or kind == 'draw' or kind == nil then
        return value, nil
    end
    -- integer-or-numeric-string → treat as id
    local as_num = tonumber(value)
    if as_num and as_num == math.floor(as_num) then
        return as_num, nil
    end
    if type(value) ~= 'string' then
        return nil, 'expected integer or name string for ' .. kind .. ' reference'
    end
    if kind == 'group' then
        local Mission = require('me_mission')
        local g = Mission.group_by_name and Mission.group_by_name[value]
        if g then return g.groupId, nil end
        return nil, 'no group named "' .. value .. '"'
    elseif kind == 'unit' then
        local Mission = require('me_mission')
        local u = Mission.unit_by_name and Mission.unit_by_name[value]
        if u then return u.unitId, nil end
        return nil, 'no unit named "' .. value .. '"'
    elseif kind == 'zone' then
        -- Trigger zones don't live in mission.triggers.zones at runtime —
        -- they're held by the Mission.TriggerZoneData controller, which
        -- exposes ids + a name lookup but no by-name index. Iterate ids
        -- and match (same pattern as find_zone above).
        local ok_tzd, TZD = pcall(require, 'Mission.TriggerZoneData')
        if ok_tzd and type(TZD) == 'table'
                and type(TZD.getTriggerZoneIds) == 'function'
                and type(TZD.getTriggerZoneName) == 'function' then
            for _, zid in ipairs(TZD.getTriggerZoneIds() or {}) do
                if TZD.getTriggerZoneName(zid) == value then return zid, nil end
            end
        end
        return nil, 'no zone named "' .. value .. '"'
    elseif kind == 'airdrome' then
        return nil, 'airdrome reference by name not supported in v1; pass integer id'
    end
    return value, nil
end

-- _trigger_coerce_value — string from CLI → typed Lua value per descriptor.
-- For "edit" fields the descriptor may not say what the type should be, so
-- we infer: "true"/"false" → bool, parseable → number, else string. Array
-- values use comma-separated form (descriptor signals via field.type or
-- by the field having a known multi-int shape like typebomb/typemissile).
local function _trigger_coerce_value(field_descr, value)
    if type(field_descr) ~= 'table' then return value end
    -- known array-of-int fields per ED's trigger schema
    local id = field_descr.id
    if id == 'typebomb' or id == 'typemissile' or id == 'typemlrs' then
        local out = {}
        for piece in tostring(value):gmatch('[^,]+') do
            local n = tonumber(piece)
            if not n then return nil end
            table.insert(out, n)
        end
        return out
    end
    if value == 'true' then return true end
    if value == 'false' then return false end
    local n = tonumber(value)
    if n ~= nil then return n end
    return tostring(value)
end

-- _trigger_field_descr — find a single field descriptor by id within a
-- predicate's descr.fields list (or descr.fields under triggersDescr).
local function _trigger_field_descr(descr, field_id)
    if type(descr) ~= 'table' or type(descr.fields) ~= 'table' then return nil end
    for _, f in ipairs(descr.fields) do
        if type(f) == 'table' and f.id == field_id then return f end
    end
    return nil
end

-- _trigger_apply_fields — walk the user-supplied fields table, validate
-- each against descr, coerce types, resolve references, allocate dict
-- keys for action text/comment/radiotext fields. Mutates entry in place.
-- Returns ok, err.
--
-- kind: "condition" | "action" | "trigger" | nil — needed because action
--       text/comment/radiotext fields go through dictionary.fixDict to
--       allocate a DictKey_* reference. Other kinds store literals.
-- predicate_canonical: the canonical c_*/a_*/trigger* name — needed for
--       the a_do_script special case (its `text` field is a raw script,
--       not a dict-keyed message).
local function _trigger_apply_fields(entry, descr, fields, kind, predicate_canonical)
    if type(fields) ~= 'table' then return true, nil end
    local ok_dict, dictionary = pcall(require, 'dictionary')

    -- Map of action-side fields that go through DictKey allocation.
    -- Source: me_trigrules.saveTriggers (lines ~3902-3914) and me_predicates.
    -- actionToString — these are the only action fields ED's serializer
    -- routes through textToMis at save time.
    local ACTION_DICT_FIELDS = {
        text       = 'ActionText',
        radiotext  = 'ActionRadioText',
        comment    = 'ActionComment',
    }

    for k, v in pairs(fields) do
        local fd = _trigger_field_descr(descr, k)
        if not fd then
            return false, 'unknown field "' .. tostring(k) .. '" for predicate "'
                          .. tostring(descr and descr.name or '?') .. '"'
        end
        local coerced = _trigger_coerce_value(fd, v)
        if coerced == nil then
            return false, 'invalid value for field "' .. tostring(k) .. '"'
        end
        local refkind = _trigger_field_combo_kind(fd)
        local resolved, ref_err = _trigger_resolve_ref(refkind, coerced)
        if ref_err then return false, ref_err end

        -- Decide: literal write, or DictKey allocation via fixDict?
        local dict_comment = nil
        if kind == 'action' and ACTION_DICT_FIELDS[k] then
            -- a_do_script's `text` is a literal Lua script, not a dict-keyed
            -- message — ED skips textToMis for it (me_trigrules.lua:3908).
            if not (k == 'text' and predicate_canonical == 'a_do_script') then
                dict_comment = ACTION_DICT_FIELDS[k]
            end
        end

        if dict_comment and type(resolved) == 'string'
                and resolved:sub(1, 8) ~= 'DictKey_' and ok_dict
                and type(dictionary.fixDict) == 'function' then
            -- fixDict: allocate DictKey_<dict_comment>_<num>, store value in
            -- dictionary['DEFAULT'][key], then write both entry[k] = literal
            -- and entry["KeyDict_"..k] = key. ED's saveTriggers will read
            -- KeyDict_<k> at save time and call textToMis to round-trip.
            pcall(dictionary.fixDict, entry, k, resolved, dict_comment)
        else
            entry[k] = resolved
        end
    end
    return true, nil
end

-- _trigger_resolve_for_get — reverse of fixDict: given an entry from a
-- trigrules trigger / rule / action, return a flat fields table with
-- DictKey_* references resolved back to literal strings, and reference
-- ids accompanied by *_name fields where resolvable. Skips the
-- KeyDict_* companions (they're internal indirection). If raw=true,
-- returns the entry verbatim instead.
local function _trigger_resolve_for_get(entry, descr, raw)
    local out = {}
    if type(entry) ~= 'table' then return out end
    if raw then
        for k, v in pairs(entry) do out[k] = v end
        return out
    end
    local ok_dict, dictionary = pcall(require, 'dictionary')
    for k, v in pairs(entry) do
        if k == 'predicate' then
            -- skip — emitted separately at the caller's level
        elseif k:sub(1, 8) == 'KeyDict_' then
            -- skip companion
        elseif type(v) == 'string' and v:sub(1, 8) == 'DictKey_'
                and ok_dict and type(dictionary.getValueDict) == 'function' then
            local literal = dictionary.getValueDict(v)
            out[k] = literal or v
        else
            out[k] = v
            -- enrichment for reference fields
            local fd = _trigger_field_descr(descr, k)
            local kind = fd and _trigger_field_combo_kind(fd)
            if kind == 'group' and type(v) == 'number' then
                local Mission = require('me_mission')
                if Mission.group_by_id and Mission.group_by_id[v] then
                    out[k .. '_name'] = Mission.group_by_id[v].name
                end
            elseif kind == 'unit' and type(v) == 'number' then
                local Mission = require('me_mission')
                if Mission.unit_by_id and Mission.unit_by_id[v] then
                    out[k .. '_name'] = Mission.unit_by_id[v].name
                end
            elseif kind == 'zone' and type(v) == 'number' then
                -- Same as _trigger_resolve_ref: zones live in TriggerZoneData
                -- at runtime, not mission.triggers.zones.
                local ok_tzd, TZD = pcall(require, 'Mission.TriggerZoneData')
                if ok_tzd and type(TZD) == 'table'
                        and type(TZD.getTriggerZoneName) == 'function' then
                    local n = TZD.getTriggerZoneName(v)
                    if n then out[k .. '_name'] = n end
                end
            end
        end
    end
    return out
end

-- _trigger_ensure_trigrules — make sure mission.trigrules exists; create
-- an empty array if not. Mirrors ED's me_trigrules.show() init guard.
local function _trigger_ensure_trigrules()
    local Mission = require('me_mission')
    local mission = Mission.mission
    if type(mission) ~= 'table' then return nil, 'no mission loaded' end
    if type(mission.trigrules) ~= 'table' then mission.trigrules = {} end
    return mission.trigrules, nil
end

-- _trigger_friendly_type — canonical "triggerOnce" / "triggerContinious" /
-- ... → friendly alias ("once" / "continuous" / ...).
local function _trigger_friendly_type(canonical)
    return _trigger_make_alias(canonical or '')
end

-- trigger_list — compact list of every trigger in mission.trigrules.
-- Returns one row per trigger: {name, type, conditions, actions, eventlist}.
function M.trigger_list(args)
    local trigrules, err = _trigger_ensure_trigrules()
    if not trigrules then return { ok = false, error = err } end
    local out = {}
    for _, t in ipairs(trigrules) do
        if type(t) == 'table' then
            table.insert(out, {
                name       = t.comment or '',
                type       = _trigger_friendly_type(t.predicate),
                conditions = (type(t.rules)   == 'table') and #t.rules   or 0,
                actions    = (type(t.actions) == 'table') and #t.actions or 0,
                eventlist  = t.eventlist or '',
            })
        end
    end
    return { ok = true, count = #out, triggers = out }
end

-- trigger_get — full trigger detail. Resolves DictKey_* references to
-- literal text and enriches reference ids with their *_name companion
-- (group_name, unit_name, zone_name). args.raw=true returns the
-- on-disk trigrules entry verbatim for debugging.
function M.trigger_get(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'trigger_get requires args.name (string)' }
    end
    local raw = args.raw == true
    local _, err = _trigger_ensure_trigrules()
    if err then return { ok = false, error = err } end
    local t, idx = _trigger_find_by_name(args.name)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.name .. '"' }
    end
    if raw then
        return { ok = true, name = args.name, index = idx, trigger = t }
    end

    local conditions = {}
    if type(t.rules) == 'table' then
        for i, r in ipairs(t.rules) do
            local pname = _trigger_predicate_name(r.predicate)
            local _, _, descr = _trigger_resolve_predicate(pname)
            local fields = _trigger_resolve_for_get(r, descr, false)
            fields.predicate = nil  -- don't double-emit
            table.insert(conditions, {
                index     = i,
                predicate = pname,
                alias     = _trigger_make_alias(r.predicate),
                fields    = fields,
            })
        end
    end

    local actions = {}
    if type(t.actions) == 'table' then
        for i, a in ipairs(t.actions) do
            local pname = _trigger_predicate_name(a.predicate)
            local _, _, descr = _trigger_resolve_predicate(pname)
            local fields = _trigger_resolve_for_get(a, descr, false)
            fields.predicate = nil
            table.insert(actions, {
                index     = i,
                predicate = pname,
                alias     = _trigger_make_alias(a.predicate),
                fields    = fields,
            })
        end
    end

    return {
        ok         = true,
        name       = t.comment or '',
        type       = _trigger_friendly_type(t.predicate),
        eventlist  = t.eventlist or '',
        conditions = conditions,
        actions    = actions,
    }
end

-- _trigger_descr_to_field_dump — flatten a descr.fields list to a dump
-- shape suitable for JSON: array of {id, type, default, kind?}.
local function _trigger_descr_to_field_dump(descr)
    local out = {}
    if type(descr) ~= 'table' or type(descr.fields) ~= 'table' then return out end
    for _, f in ipairs(descr.fields) do
        if type(f) == 'table' and type(f.id) == 'string' then
            local entry = { id = f.id, type = f.type or 'edit' }
            if f.default ~= nil then entry.default = f.default end
            local refkind = _trigger_field_combo_kind(f)
            if refkind then entry.refkind = refkind end
            table.insert(out, entry)
        end
    end
    return out
end

-- _trigger_predicate_example — generate the CLI invocation string for a
-- predicate. Used in the dump to show agents how to invoke it.
local function _trigger_predicate_example(canonical, alias, kind, descr)
    local parts = {}
    if kind == 'condition' or kind == 'action' then
        table.insert(parts, 'me trigger add-' .. kind .. ' --trigger T --predicate ' .. alias)
    elseif kind == 'trigger' then
        table.insert(parts, 'me trigger create --type ' .. alias .. ' --name N')
    else
        return ''
    end
    -- Suggest one example pair per known field (skip KeyDict_* internal
    -- companions; user only sees the literal field).
    if type(descr) == 'table' and type(descr.fields) == 'table' then
        for _, f in ipairs(descr.fields) do
            if type(f) == 'table' and type(f.id) == 'string'
                    and f.id:sub(1, 8) ~= 'KeyDict_' and f.id ~= 'comment' then
                local val = '<' .. f.id .. '>'
                table.insert(parts, f.id .. '=' .. val)
                break  -- one suggestion is enough; full list is in `fields`.
            end
        end
    end
    return table.concat(parts, ' ')
end

-- trigger_list_predicates — dump every predicate ED knows about, optionally
-- filtered by kind ("condition" / "action" / "trigger") and/or substring.
-- Each entry: {name, alias, kind, display, fields=[...], example=...}.
function M.trigger_list_predicates(args)
    args = args or {}
    if not _trigger_alias_cache then _trigger_build_alias_cache() end
    local kind_filter = (type(args.kind) == 'string' and args.kind ~= '') and args.kind or nil
    local search = (type(args.search) == 'string' and args.search ~= '') and string.lower(args.search) or nil

    -- Walk only canonical names (the cache keys both canonical and alias to
    -- the same entry; we deduplicate by the canonical we walk).
    local Trigger = require('me_trigrules')
    local Predicates = require('me_predicates')
    local seen = {}
    local out = {}

    local function collect(name, kind)
        if seen[name] then return end
        seen[name] = true
        local entry = _trigger_alias_cache[name]
        if not entry then return end
        if kind_filter and entry.kind ~= kind_filter then return end
        local alias = _trigger_make_alias(name)
        if search and not (string.lower(name):find(search, 1, true)
                          or alias:find(search, 1, true)) then
            return
        end
        local display = ''
        if type(entry.descr) == 'table' and type(entry.descr.display) == 'string' then
            display = entry.descr.display
        end
        table.insert(out, {
            name    = name,
            alias   = alias,
            kind    = entry.kind,
            display = display,
            fields  = _trigger_descr_to_field_dump(entry.descr),
            example = _trigger_predicate_example(name, alias, entry.kind, entry.descr),
        })
    end

    if type(Predicates.rulesDescr) == 'table' then
        -- pairs() (not ipairs) so pseudo-predicates under string keys
        -- (currently just ["or"]) are surfaced too.
        for _, descr in pairs(Predicates.rulesDescr) do
            if type(descr) == 'table' and type(descr.name) == 'string' then
                collect(descr.name)
            end
        end
    end
    if type(Trigger.actionsDescr) == 'table' then
        for _, descr in ipairs(Trigger.actionsDescr) do
            if type(descr) == 'table' and type(descr.name) == 'string' then
                collect(descr.name)
            end
        end
    end
    if type(Trigger.triggersDescr) == 'table' then
        for _, td in ipairs(Trigger.triggersDescr) do
            if type(td) == 'table' and type(td.name) == 'string' then collect(td.name) end
        end
    end

    table.sort(out, function(a, b) return a.name < b.name end)
    return { ok = true, count = #out, predicates = out }
end

-- trigger_describe_predicate — single-predicate spec. Same shape as one
-- entry from trigger_list_predicates. Accepts canonical or alias name.
function M.trigger_describe_predicate(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'trigger_describe_predicate requires args.name (string)' }
    end
    local canonical, kind, descr, err = _trigger_resolve_predicate(args.name)
    if err then return { ok = false, error = err } end
    local display = ''
    if type(descr) == 'table' and type(descr.display) == 'string' then
        display = descr.display
    end
    local alias = _trigger_make_alias(canonical)
    return {
        ok      = true,
        name    = canonical,
        alias   = alias,
        kind    = kind,
        display = display,
        fields  = _trigger_descr_to_field_dump(descr),
        example = _trigger_predicate_example(canonical, alias, kind, descr),
    }
end

-- trigger_create — insert a new trigger of the given type. Name defaults
-- to ED's "Trigger <epoch>" pattern with auto-suffix on collision.
-- Bundled rules/actions are added by the caller via repeated calls to
-- trigger_add_condition / trigger_add_action — that composition lives at
-- the CLI layer (see me_trigger_create.go).
function M.trigger_create(args)
    args = args or {}
    local type_arg = args['type']
    if type(type_arg) ~= 'string' or type_arg == '' then
        return { ok = false, error = 'trigger_create requires args.type (once|continuous|start|front)' }
    end
    local canonical, kind, descr, err = _trigger_resolve_predicate(type_arg, 'trigger')
    if err then return { ok = false, error = 'trigger_create: ' .. err } end

    local trigrules, terr = _trigger_ensure_trigrules()
    if not trigrules then return { ok = false, error = terr } end

    -- Build the trigger via ED's createTrigger to inherit field defaults.
    local Trigger = require('me_trigrules')
    if type(Trigger.createTrigger) ~= 'function' then
        return { ok = false, error = 'me_trigrules.createTrigger unavailable' }
    end
    local ok_call, new_trigger = pcall(Trigger.createTrigger, descr)
    if not ok_call or type(new_trigger) ~= 'table' then
        return { ok = false, error = 'createTrigger failed: ' .. tostring(new_trigger) }
    end

    -- Override the auto-generated comment with the user's name (or its
    -- collision-resolved equivalent).
    local desired_name = (type(args.name) == 'string' and args.name ~= '')
                        and args.name or _trigger_default_name()
    new_trigger.comment = _trigger_unique_name(desired_name)

    -- DO NOT overwrite new_trigger.predicate. ED's createTrigger sets
    -- new_trigger.predicate = descr (the descriptor TABLE {name=..., fields=...}).
    -- ED's saveTriggers reads .predicate.name to serialize, so replacing the
    -- table with a canonical string would silently drop the trigger on save.

    table.insert(trigrules, new_trigger)
    _trigger_panel_refresh()

    return {
        ok    = true,
        name  = new_trigger.comment,
        type  = _trigger_friendly_type(canonical),
        index = #trigrules,
    }
end

-- trigger_remove — delete a trigger by name. Refuses on missing trigger.
function M.trigger_remove(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'trigger_remove requires args.name (string)' }
    end
    local trigrules, err = _trigger_ensure_trigrules()
    if not trigrules then return { ok = false, error = err } end
    local _, idx = _trigger_find_by_name(args.name)
    if not idx then
        return { ok = false, error = 'no trigger named "' .. args.name .. '"' }
    end
    table.remove(trigrules, idx)
    _trigger_panel_refresh()
    return { ok = true, name = args.name, removed_index = idx, count = #trigrules }
end

-- trigger_set_name — rename a trigger (mutate the comment field).
-- Refuses if the new name collides with another existing trigger.
function M.trigger_set_name(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'trigger_set_name requires args.name (current name, string)' }
    end
    if type(args.to) ~= 'string' or args.to == '' then
        return { ok = false, error = 'trigger_set_name requires args.to (new name, string)' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end
    local t = _trigger_find_by_name(args.name)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.name .. '"' }
    end
    if args.to ~= args.name then
        local existing = _trigger_find_by_name(args.to)
        if existing then
            return { ok = false, error = 'a trigger named "' .. args.to .. '" already exists' }
        end
    end
    t.comment = args.to
    _trigger_panel_refresh()
    return { ok = true, name = args.to, previous_name = args.name }
end

-- trigger_set_eventlist — set or clear the event filter on a trigger.
-- args.event is the event id (string from ED's eventLister) or empty
-- string to clear.
function M.trigger_set_eventlist(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'trigger_set_eventlist requires args.name' }
    end
    if args.event ~= nil and type(args.event) ~= 'string' then
        return { ok = false, error = 'trigger_set_eventlist requires args.event (string or nil)' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end
    local t = _trigger_find_by_name(args.name)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.name .. '"' }
    end
    t.eventlist = args.event or ''
    _trigger_panel_refresh()
    return { ok = true, name = args.name, eventlist = t.eventlist }
end

-- _trigger_build_rule_or_action — internal: build a {predicate=..., ...}
-- entry from a user-supplied predicate name + fields, validating against
-- the descriptor and applying type coercion / reference resolution / dict
-- key allocation. Returns entry, err.
local function _trigger_build_rule_or_action(predicate_name, fields, expected_kind)
    local canonical, kind, descr, err = _trigger_resolve_predicate(predicate_name, expected_kind)
    if err then return nil, err end

    -- Use the right ED factory based on kind to inherit field defaults:
    --   condition → me_predicates.createRule(descr)
    --   action    → me_trigrules.createAction(descr)
    -- If the factory is unavailable or returns an unexpected shape, fall
    -- back to a minimal {predicate=canonical}.
    local Trigger = require('me_trigrules')
    local entry = nil
    if kind == 'condition' then
        local Predicates = require('me_predicates')
        if type(Predicates.createRule) == 'function' then
            local ok, built = pcall(Predicates.createRule, descr)
            if ok and type(built) == 'table' then entry = built end
        end
    elseif kind == 'action' then
        if type(Trigger.createAction) == 'function' then
            local ok, built = pcall(Trigger.createAction, descr)
            if ok and type(built) == 'table' then entry = built end
        end
    end
    if entry == nil then
        -- Fallback path only: factories returned nothing usable, so we
        -- synthesize a minimal entry. Use the descriptor table shape that
        -- ED's saveTriggers expects (it reads .predicate.name) so the
        -- entry survives a save round-trip.
        entry = { predicate = descr }
    end
    -- DO NOT overwrite entry.predicate when the factory built it.
    -- createRule / createAction set entry.predicate = descr (the descriptor
    -- TABLE), which is what ED's saveTriggers reads .name from at save time.
    -- Replacing the table with a canonical string drops the entry on save.

    local ok_apply, apply_err = _trigger_apply_fields(entry, descr, fields, kind, canonical)
    if not ok_apply then return nil, apply_err end
    return entry, nil
end

-- trigger_add_condition — append a condition entry to trigger.rules.
function M.trigger_add_condition(args)
    if type(args) ~= 'table' or type(args.trigger) ~= 'string' or args.trigger == '' then
        return { ok = false, error = 'trigger_add_condition requires args.trigger (name)' }
    end
    if type(args.predicate) ~= 'string' or args.predicate == '' then
        return { ok = false, error = 'trigger_add_condition requires args.predicate' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end
    local t = _trigger_find_by_name(args.trigger)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.trigger .. '"' }
    end
    if type(t.rules) ~= 'table' then t.rules = {} end

    local entry, err = _trigger_build_rule_or_action(args.predicate, args.fields, 'condition')
    if not entry then return { ok = false, error = 'trigger_add_condition: ' .. err } end

    table.insert(t.rules, entry)
    _trigger_panel_refresh()
    return {
        ok        = true,
        trigger   = args.trigger,
        predicate = _trigger_predicate_name(entry.predicate),
        index     = #t.rules,
    }
end

-- trigger_add_action — append an action entry to trigger.actions.
function M.trigger_add_action(args)
    if type(args) ~= 'table' or type(args.trigger) ~= 'string' or args.trigger == '' then
        return { ok = false, error = 'trigger_add_action requires args.trigger (name)' }
    end
    if type(args.predicate) ~= 'string' or args.predicate == '' then
        return { ok = false, error = 'trigger_add_action requires args.predicate' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end
    local t = _trigger_find_by_name(args.trigger)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.trigger .. '"' }
    end
    if type(t.actions) ~= 'table' then t.actions = {} end

    local entry, err = _trigger_build_rule_or_action(args.predicate, args.fields, 'action')
    if not entry then return { ok = false, error = 'trigger_add_action: ' .. err } end

    table.insert(t.actions, entry)
    _trigger_panel_refresh()
    return {
        ok        = true,
        trigger   = args.trigger,
        predicate = _trigger_predicate_name(entry.predicate),
        index     = #t.actions,
    }
end

-- trigger_remove_condition — remove the rule at index N (1-based).
function M.trigger_remove_condition(args)
    if type(args) ~= 'table' or type(args.trigger) ~= 'string' or args.trigger == '' then
        return { ok = false, error = 'trigger_remove_condition requires args.trigger (name)' }
    end
    if type(args.index) ~= 'number' or args.index < 1 then
        return { ok = false, error = 'trigger_remove_condition requires args.index (1-based)' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end
    local t = _trigger_find_by_name(args.trigger)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.trigger .. '"' }
    end
    if type(t.rules) ~= 'table' or args.index > #t.rules then
        return { ok = false,
                 error = 'trigger has only ' .. (type(t.rules) == 'table' and #t.rules or 0)
                         .. ' conditions; cannot remove index ' .. args.index }
    end
    table.remove(t.rules, args.index)
    _trigger_panel_refresh()
    return { ok = true, trigger = args.trigger,
             removed_index = args.index, remaining = #t.rules }
end

-- trigger_remove_action — remove the action at index N (1-based).
function M.trigger_remove_action(args)
    if type(args) ~= 'table' or type(args.trigger) ~= 'string' or args.trigger == '' then
        return { ok = false, error = 'trigger_remove_action requires args.trigger (name)' }
    end
    if type(args.index) ~= 'number' or args.index < 1 then
        return { ok = false, error = 'trigger_remove_action requires args.index (1-based)' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end
    local t = _trigger_find_by_name(args.trigger)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.trigger .. '"' }
    end
    if type(t.actions) ~= 'table' or args.index > #t.actions then
        return { ok = false,
                 error = 'trigger has only ' .. (type(t.actions) == 'table' and #t.actions or 0)
                         .. ' actions; cannot remove index ' .. args.index }
    end
    table.remove(t.actions, args.index)
    _trigger_panel_refresh()
    return { ok = true, trigger = args.trigger,
             removed_index = args.index, remaining = #t.actions }
end

-- _reorder_resolve_target — turn a position-flag args table into a final
-- 1-based target index, computed against the post-removal list.
--
-- Returns target_idx, err. If err is non-nil, caller should propagate.
--
-- Args expected:
--   list           — the array we'll be reordering inside (read-only here)
--   from_idx       — 1-based source position in `list` (already validated)
--   args           — the user-supplied args table; reads:
--                      args.to_index   (number, 1-based final position)
--                      args.before     (anchor reference: name OR index)
--                      args.after      (anchor reference: name OR index)
--                      args.to_start   (boolean — sugar for to_index = 1)
--                      args.to_end     (boolean — sugar for to_index = #list)
--   find_ref_idx   — function(list, ref) → idx | nil, err
--                    Resolves the --before / --after anchor reference to a
--                    1-based index in `list`. For triggers, the impl looks
--                    up by name (t.comment); for conditions/actions, the
--                    impl validates the ref is a number in 1..#list.
--
-- Validates exactly-one-position-flag and self-reference. Self-reference
-- (--before/--after pointing at the source itself) collapses to a no-op
-- target (target == from_idx) so the caller's no-op short-circuit
-- handles it without a separate code path.
local function _reorder_resolve_target(list, from_idx, args, find_ref_idx)
    -- Count position flags. Exactly one must be set.
    local set = {}
    if args.to_index ~= nil then table.insert(set, '--to-index') end
    if args.before   ~= nil then table.insert(set, '--before')   end
    if args.after    ~= nil then table.insert(set, '--after')    end
    if args.to_start == true then table.insert(set, '--to-start') end
    if args.to_end   == true then table.insert(set, '--to-end')   end
    if #set ~= 1 then
        return nil, 'exactly one of --to-index / --before / --after / '
                    .. '--to-start / --to-end is required'
    end

    local n = #list

    if args.to_start == true then
        return 1, nil
    end
    if args.to_end == true then
        return n, nil
    end
    if args.to_index ~= nil then
        if type(args.to_index) ~= 'number' then
            return nil, '--to-index must be a number'
        end
        if args.to_index < 1 or args.to_index > n then
            return nil, '--to-index must be in 1..' .. n
                        .. ' (got ' .. tostring(args.to_index) .. ')'
        end
        return args.to_index, nil
    end

    -- --before / --after: resolve the anchor's index, then translate to a
    -- post-removal slot.
    local ref = args.before ~= nil and args.before or args.after
    local x_idx, ref_err = find_ref_idx(list, ref)
    if ref_err then return nil, ref_err end
    if not x_idx then
        return nil, 'reference not found: ' .. tostring(ref)
    end

    -- Self-reference → return from_idx so caller's no-op short-circuit
    -- handles it. (--before/--after pointing at the source is a logical
    -- no-op — same as --to-index <where-source-is>.)
    if x_idx == from_idx then
        return from_idx, nil
    end

    -- After removing source, items above from_idx shift down by 1.
    local x_post_removal = (x_idx > from_idx) and (x_idx - 1) or x_idx
    if args.before ~= nil then
        return x_post_removal, nil
    else
        return x_post_removal + 1, nil
    end
end

-- _reorder_apply — table.remove + table.insert. Caller must have already
-- short-circuited the from_idx == target_idx case.
local function _reorder_apply(list, from_idx, target_idx)
    local item = table.remove(list, from_idx)
    table.insert(list, target_idx, item)
end

-- trigger_reorder — move a trigger to a new 1-based position in
-- mission.trigrules.
--
-- Args:
--   args.name      (string, required) — trigger to move (matched against
--                                       t.comment)
--   args.to_index  (number) | args.before (string trigger name)
--   args.after     (string)  | args.to_start (true) | args.to_end (true)
--                                       — exactly one position flag
--
-- Returns { ok = true, moved = bool, from = N, to = M }. moved=false is a
-- no-op (source already at target); not an error.
function M.trigger_reorder(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'trigger_reorder requires args.name (string)' }
    end
    local trigrules, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end

    local _, from_idx = _trigger_find_by_name(args.name)
    if not from_idx then
        return { ok = false, error = 'no trigger named "' .. args.name .. '"' }
    end

    -- Anchor lookup for --before/--after: ref is a trigger name; map it
    -- to the trigger's 1-based index in mission.trigrules. nil = not
    -- found.
    local function find_trigger_ref(list, ref)
        if type(ref) ~= 'string' then
            return nil, '--before / --after expects a trigger name (string)'
        end
        for i, t in ipairs(list) do
            if type(t) == 'table' and t.comment == ref then return i end
        end
        return nil, 'no trigger named "' .. ref .. '"'
    end

    local target_idx, terr2 = _reorder_resolve_target(trigrules, from_idx, args, find_trigger_ref)
    if terr2 then return { ok = false, error = terr2 } end

    if from_idx == target_idx then
        return { ok = true, moved = false, from = from_idx, to = target_idx }
    end

    _reorder_apply(trigrules, from_idx, target_idx)
    _trigger_panel_refresh()
    return { ok = true, moved = true, from = from_idx, to = target_idx }
end

-- trigger_reorder_condition — move a condition to a new 1-based position
-- in t.rules.
--
-- Args:
--   args.trigger   (string, required) — parent trigger name
--   args.index     (number, required) — source condition's 1-based index
--   args.to_index  (number) | args.before (number index)
--   args.after     (number) | args.to_start (true) | args.to_end (true)
--                                                 — exactly one position
--
-- Returns { ok = true, moved = bool, trigger = "T", from = N, to = M }.
function M.trigger_reorder_condition(args)
    if type(args) ~= 'table' or type(args.trigger) ~= 'string' or args.trigger == '' then
        return { ok = false, error = 'trigger_reorder_condition requires args.trigger (name)' }
    end
    if type(args.index) ~= 'number' or args.index < 1 then
        return { ok = false, error = 'trigger_reorder_condition requires args.index (1-based)' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end

    local t = _trigger_find_by_name(args.trigger)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.trigger .. '"' }
    end
    if type(t.rules) ~= 'table' or args.index > #t.rules then
        return { ok = false,
                 error = 'trigger has only ' .. (type(t.rules) == 'table' and #t.rules or 0)
                         .. ' conditions; cannot reorder index ' .. args.index }
    end

    -- Anchor for --before/--after is a 1-based index into t.rules.
    local function find_index_ref(list, ref)
        if type(ref) ~= 'number' then
            return nil, '--before / --after expects a 1-based index (number)'
        end
        if ref < 1 or ref > #list then
            return nil, '--before / --after index must be in 1..' .. #list
                        .. ' (got ' .. tostring(ref) .. ')'
        end
        return ref
    end

    local target_idx, terr2 = _reorder_resolve_target(t.rules, args.index, args, find_index_ref)
    if terr2 then return { ok = false, error = terr2 } end

    if args.index == target_idx then
        return { ok = true, moved = false, trigger = args.trigger,
                 from = args.index, to = target_idx }
    end

    _reorder_apply(t.rules, args.index, target_idx)
    _trigger_panel_refresh()
    return { ok = true, moved = true, trigger = args.trigger,
             from = args.index, to = target_idx }
end

-- trigger_reorder_action — move an action to a new 1-based position in
-- t.actions. Same shape as trigger_reorder_condition but operates on
-- t.actions instead of t.rules.
function M.trigger_reorder_action(args)
    if type(args) ~= 'table' or type(args.trigger) ~= 'string' or args.trigger == '' then
        return { ok = false, error = 'trigger_reorder_action requires args.trigger (name)' }
    end
    if type(args.index) ~= 'number' or args.index < 1 then
        return { ok = false, error = 'trigger_reorder_action requires args.index (1-based)' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end

    local t = _trigger_find_by_name(args.trigger)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.trigger .. '"' }
    end
    if type(t.actions) ~= 'table' or args.index > #t.actions then
        return { ok = false,
                 error = 'trigger has only ' .. (type(t.actions) == 'table' and #t.actions or 0)
                         .. ' actions; cannot reorder index ' .. args.index }
    end

    local function find_index_ref(list, ref)
        if type(ref) ~= 'number' then
            return nil, '--before / --after expects a 1-based index (number)'
        end
        if ref < 1 or ref > #list then
            return nil, '--before / --after index must be in 1..' .. #list
                        .. ' (got ' .. tostring(ref) .. ')'
        end
        return ref
    end

    local target_idx, terr2 = _reorder_resolve_target(t.actions, args.index, args, find_index_ref)
    if terr2 then return { ok = false, error = terr2 } end

    if args.index == target_idx then
        return { ok = true, moved = false, trigger = args.trigger,
                 from = args.index, to = target_idx }
    end

    _reorder_apply(t.actions, args.index, target_idx)
    _trigger_panel_refresh()
    return { ok = true, moved = true, trigger = args.trigger,
             from = args.index, to = target_idx }
end

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
        table.insert(out, {
            id = g.groupId,
            name = g.name,
            category = cat,
            country = country.name,
            side = side_name,
            north = g.x,
            east = g.y,
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
    return { ok = true, group = snapshot }
end

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
    local f_type = args.type or nil

    local out = {}
    walk_groups(function(g, country, side_name, cat)
        if f_side and string.lower(side_name) ~= f_side then return end
        if f_country and string.lower(country.name or '') ~= f_country then return end
        if f_category and cat ~= f_category then return end
        if f_group and g.name ~= f_group then return end
        for _, u in ipairs(g.units or {}) do
            if not (f_name and not string.find(string.lower(u.name or ''), f_name, 1, true)) then
                if not (f_type and u.type ~= f_type) then
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

-- unit_get — full raw unit table (back-refs stripped), by name or id.
function M.unit_get(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'unit_get requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'unit_get requires exactly one of args.name or args.id' }
    end

    local found_unit, found_group, found_country, found_side, found_cat
    walk_groups(function(g, country, side_name, cat)
        for _, u in ipairs(g.units or {}) do
            if (has_name and u.name == args.name)
                    or (has_id and u.unitId == args.id) then
                found_unit, found_group, found_country = u, g, country
                found_side, found_cat = side_name, cat
                return false
            end
        end
    end)

    if not found_unit then
        return { ok = false, error = 'unit not found' }
    end
    local snapshot = strip_back_refs(found_unit)
    snapshot._group_name = found_group.name
    snapshot._group_id = found_group.groupId
    snapshot._country = found_country.name
    snapshot._side = found_side
    snapshot._category = found_cat
    return { ok = true, unit = snapshot }
end

-- zone_list — return concise summaries of all trigger zones.
--
-- args (optional):
--   shape: "circle" | "quad"  -- numeric type 0 / 2 in mission-table
--   name:  string  -- substring (case-insensitive)
--
-- Returns { ok = true, zones = [ ... ], count = N }.
function M.zone_list(args)
    args = args or {}
    local f_shape = args.shape and string.lower(args.shape) or nil
    local f_name = args.name and string.lower(args.name) or nil

    local ok_tzd, TZD = pcall(require, 'Mission.TriggerZoneData')
    if not ok_tzd or type(TZD) ~= 'table' then
        return { ok = false, error = 'Mission.TriggerZoneData unavailable' }
    end

    local out = {}
    for _, zid in ipairs(TZD.getTriggerZoneIds() or {}) do
        local nm = TZD.getTriggerZoneName(zid)
        local tnum = TZD.getTriggerZoneType(zid)
        local shape = (tnum == 0 and 'circle') or (tnum == 2 and 'quad') or ('type=' .. tostring(tnum))
        if not (f_shape and shape ~= f_shape)
                and not (f_name and nm and not string.find(string.lower(nm), f_name, 1, true)) then
            local x, y = TZD.getTriggerZonePosition(zid)
            local r, g, b, a = TZD.getTriggerZoneColor(zid)
            local pts = TZD.getTriggerZonePoints(zid) or {}
            table.insert(out, {
                id = zid,
                name = nm,
                shape = shape,
                type = tnum,
                north = x,
                east = y,
                radius = TZD.getTriggerZoneRadius(zid),
                color = { r, g, b, a },
                hidden = TZD.getTriggerZoneHidden(zid),
                vertex_count = (tnum == 2) and #pts or nil,
            })
        end
    end
    return { ok = true, zones = out, count = #out }
end

-- zone_get — full zone detail by name or id.
function M.zone_get(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_get requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_get requires exactly one of args.name or args.id' }
    end

    local zid, _ = find_zone(has_name and args.name or nil,
                             has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end

    local TZD = require('Mission.TriggerZoneData')
    local x, y = TZD.getTriggerZonePosition(zid)
    local r, g, b, a = TZD.getTriggerZoneColor(zid)
    local tnum = TZD.getTriggerZoneType(zid)
    local shape = (tnum == 0 and 'circle') or (tnum == 2 and 'quad') or ('type=' .. tostring(tnum))
    local pts_rel = TZD.getTriggerZonePoints(zid) or {}

    -- Convert relative points back to absolute for user clarity (matches the
    -- shape of --vertices on input). Keep raw relative points too.
    local pts_abs = {}
    for _, p in ipairs(pts_rel) do
        table.insert(pts_abs, { north = p.x + x, east = p.y + y })
    end

    return {
        ok = true,
        zone = {
            id = zid,
            name = TZD.getTriggerZoneName(zid),
            shape = shape,
            type = tnum,
            north = x,
            east = y,
            radius = TZD.getTriggerZoneRadius(zid),
            color = { r, g, b, a },
            hidden = TZD.getTriggerZoneHidden(zid),
            properties = TZD.getTriggerZoneProperties(zid),
            link_unit_id = TZD.getLinkUnitId(zid),
            heading = TZD.getTriggerZone(zid) and TZD.getTriggerZone(zid):getHeading() or 0,
            points_relative = pts_rel,
            vertices_absolute = (tnum == 2) and pts_abs or nil,
        },
    }
end

-- =============================================================================
-- Camera (ME map view)
--
-- ED's camera lives in MapWindow. setCamera takes 2D world meters (x = north,
-- y = east) — same units as Terrain.convertLatLonToMeters returns and the
-- same field names as Mission.AirdromeController exposes on each airdrome.
-- setScale takes meters-per-screen-unit; lower = more zoomed in. Order
-- matters: when changing scale and panning at once, set scale first or the
-- camera position snaps oddly at the old scale.

local function _camera_resolve_airdrome(needle)
    if type(needle) ~= 'string' or needle == '' then return nil end
    local ok, AC = pcall(require, 'Mission.AirdromeController')
    if not ok or not AC or type(AC.getAirdromes) ~= 'function' then return nil end
    local got_ok, airdromes = pcall(AC.getAirdromes)
    if not got_ok then return nil end
    local n_low = needle:lower()
    for _, ad in ipairs(airdromes or {}) do
        if ad.getName then
            local name = ad:getName()
            if name and name:lower() == n_low then
                return { name = name, x = ad.x, y = ad.y }
            end
        end
    end
    for _, ad in ipairs(airdromes or {}) do
        if ad.getName then
            local name = ad:getName()
            if name and name:lower():find(n_low, 1, true) then
                return { name = name, x = ad.x, y = ad.y }
            end
        end
    end
    return nil
end

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
        local ad = _camera_resolve_airdrome(args.name)
        if not ad then
            return { ok = false, error = string.format("no airdrome found matching %q", tostring(args.name)) }
        end
        name, x, y = ad.name, ad.x, ad.y
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

-- =============================================================================
-- Airbases
--
-- Two verbs:
--   * airbase_list — lightweight summary, one row per airdrome (no parking).
--   * airbase_get  — deep info for one airdrome, including parking stands and
--                    runways. Used by agents to plan spawns / answer "what
--                    stands does Hama have for an F-16?".
--
-- Read-only against Mission.AirdromeController.getAirdromes() and
-- Terrain.getStandList / Terrain.getRunwayList. No mission needs to be open
-- (terrain data is theatre-level), so no module_mission guard.

local function _airbase_find_by_name(needle)
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
    local ad = _airbase_find_by_name(args.name)
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
        local ad = _airbase_find_by_name(args.airbase)
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
        local ad = _airbase_find_by_name(args.airbase)
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

function M.airbase_get(args)
    args = args or {}
    if type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = "--name is required" }
    end
    if not _G.Terrain then
        return { ok = false, error = "Terrain module not available" }
    end
    local ad = _airbase_find_by_name(args.name)
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
-- { id = 'ComboTask', params = { tasks = {} } }.
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
-- dropdown + selected-WP fields). Required after any route mutation —
-- update_group_map_objects only repaints the map layer; the route panel
-- caches its display state separately and won't pick up new/removed/
-- renamed waypoints without an explicit panel_route.update() call.
--
-- Safe no-op if me_route isn't available (defensive — same posture as
-- refresh_group_view's pcall on update_group_map_objects).
local function refresh_route_panel()
    pcall(function()
        local panel_route = require('me_route')
        if type(panel_route.update) == 'function' then
            panel_route.update()
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
        task = { id = 'ComboTask', params = { tasks = {} } },
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
    wp.task = { id = 'ComboTask', params = { tasks = {} } }
    return wp
end

-- Stub stubs for the verbs covered by the helper tests — full
-- implementations land in Tasks 3-8. These minimum-viable forms exist
-- only so the Task 2 helper tests can pass.

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
    new_wp.task = { id = 'ComboTask', params = { tasks = {} } }
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
    new_wp.task = { id = 'ComboTask', params = { tasks = {} } }
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
    local ad = _airbase_find_by_name(args.airbase)
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

    -- Move the waypoint to the airbase position via MapWindow.move_waypoint
    -- (handles spans, symbol, label, child units for WP 0). Done first so
    -- setAirGroupOn* in the takeoff branches see the WP at the target.
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
    local units_positioned = false
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
    refresh_route_panel()
    refresh_group_view(g)
    return { ok = true, group = g.name, index = args.index, action = wp.action }
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
-- Lives down here (not in the unit verb block) because it reaches into
-- the airbase helpers (_airbase_find_by_name) and the route-block locals
-- (AIRFIELD_TYPES, ensure_map_objects, refresh_route_panel). Those are
-- declared later in the file than the rest of the unit verbs; Lua 5.1's
-- lexical scoping means a function referencing them must come AFTER
-- their declaration.

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
    local ad = _airbase_find_by_name(args.airbase)
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

return M
