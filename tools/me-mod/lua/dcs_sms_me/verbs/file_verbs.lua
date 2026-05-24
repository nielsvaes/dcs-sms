-- dcs_sms_me/verbs/file_verbs.lua — file / mission lifecycle verbs.
--
-- Verbs: file_open, file_new, file_save, file_save_as.
-- See dcs_sms_me/verbs.lua for the aggregator and the verb-naming convention.

local M = {}

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

return M
