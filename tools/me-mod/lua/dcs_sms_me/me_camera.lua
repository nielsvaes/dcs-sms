-- me_camera.lua — pan the ME map camera onto an x/y point.
--
-- Pure pass-through to MapWindow.setCamera(x, y). Mission-table
-- coordinates: x = north-south (positive north), y = east-west (positive
-- east) — same convention as group.x / group.y in the loaded mission.
--
-- Deliberately does NOT touch MapWindow.setScale. Snapping the user's
-- zoom level mid-session is jarring (especially over RDP) and the call
-- sites that need a pan also keep the user's current viewport scale.
--
-- pcall-guarded so a missing MapWindow / setCamera (test VM, partially-
-- initialised editor) degrades to a structured error rather than a
-- runtime exception.
--
-- Public:
--   M.pan_to(x, y) → { ok, error? }

local M = {}

function M.pan_to(x, y)
    if type(x) ~= 'number' or type(y) ~= 'number' then
        return { ok = false, error = 'invalid coordinates' }
    end
    local mw = _G.MapWindow
    if not (type(mw) == 'table' and type(mw.setCamera) == 'function') then
        return { ok = false, error = 'MapWindow.setCamera unavailable' }
    end
    -- ED's setCamera writes the new center back to module_mission.mission.map.
    -- That subtable doesn't exist on the menu / MP browser / startup screen,
    -- and ED doesn't null-check it — a bare setCamera call there throws.
    -- Same guard as verbs.camera_focus (verbs.lua:5180).
    local mm_ok, mm = pcall(require, 'me_mission')
    if not (mm_ok and type(mm) == 'table'
            and type(mm.mission) == 'table'
            and type(mm.mission.map) == 'table') then
        return { ok = false, error = 'no mission open' }
    end
    local ok, err = pcall(mw.setCamera, x, y)
    if not ok then return { ok = false, error = tostring(err) } end
    return { ok = true }
end

return M
