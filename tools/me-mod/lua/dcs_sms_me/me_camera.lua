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
    local ok, err = pcall(mw.setCamera, x, y)
    if not ok then return { ok = false, error = tostring(err) } end
    return { ok = true }
end

return M
