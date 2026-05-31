-- Standalone test for me_camera.lua.
-- Stubs the global MapWindow so pan_to() exercises happy / error paths.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Stub me_mission with a valid .mission.map so pan_to's guard passes.
-- Individual tests override package.loaded['me_mission'] to exercise the
-- no-mission-open path.
package.preload['me_mission'] = function()
    return { mission = { map = {} } }
end

local me_camera = require('dcs_sms_me.me_camera')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- ---------------------------------------------------------------------------
-- Happy path: MapWindow.setCamera receives the x/y unchanged.
-- ---------------------------------------------------------------------------
do
    local calls = {}
    _G.MapWindow = {
        setCamera = function(x, y) calls[#calls + 1] = { x = x, y = y } end,
    }
    local r = me_camera.pan_to(123, -45)
    check('happy: ok',                 r.ok == true)
    check('happy: error nil',          r.error == nil)
    check('happy: setCamera called once', #calls == 1)
    check('happy: x forwarded',        calls[1].x == 123)
    check('happy: y forwarded',        calls[1].y == -45)
end

-- ---------------------------------------------------------------------------
-- Missing MapWindow → ok=false with a descriptive error, no crash.
-- ---------------------------------------------------------------------------
do
    _G.MapWindow = nil
    local r = me_camera.pan_to(1, 2)
    check('no MapWindow: ok=false',    r.ok == false)
    check('no MapWindow: error mentions setCamera',
        type(r.error) == 'string' and r.error:find('setCamera') ~= nil)
end

-- ---------------------------------------------------------------------------
-- MapWindow without setCamera (older / stripped) → same as missing.
-- ---------------------------------------------------------------------------
do
    _G.MapWindow = { setScale = function() end }   -- has setScale, not setCamera
    local r = me_camera.pan_to(1, 2)
    check('partial MapWindow: ok=false', r.ok == false)
    check('partial MapWindow: error mentions setCamera',
        type(r.error) == 'string' and r.error:find('setCamera') ~= nil)
end

-- ---------------------------------------------------------------------------
-- setCamera throws → error string surfaces, ok=false.
-- ---------------------------------------------------------------------------
do
    _G.MapWindow = { setCamera = function() error('boom in setCamera') end }
    local r = me_camera.pan_to(1, 2)
    check('setCamera throws: ok=false', r.ok == false)
    check('setCamera throws: error mentions boom',
        type(r.error) == 'string' and r.error:find('boom') ~= nil)
end

-- ---------------------------------------------------------------------------
-- Non-numeric coords → ok=false BEFORE any MapWindow lookup.
-- ---------------------------------------------------------------------------
do
    local setCamera_called = false
    _G.MapWindow = { setCamera = function() setCamera_called = true end }

    local r1 = me_camera.pan_to(nil, 5)
    check('nil x: ok=false',           r1.ok == false)
    check('nil x: error mentions invalid', r1.error:find('invalid') ~= nil)

    local r2 = me_camera.pan_to(5, 'oops')
    check('string y: ok=false',        r2.ok == false)

    local r3 = me_camera.pan_to({}, {})
    check('table coords: ok=false',    r3.ok == false)

    check('non-numeric: setCamera never called', setCamera_called == false)
end

-- ---------------------------------------------------------------------------
-- pan_to does NOT call setScale even when it's present (per the
-- camera_scale memory feedback: never change the user's zoom).
-- ---------------------------------------------------------------------------
do
    local set_scale_calls = 0
    _G.MapWindow = {
        setCamera = function() end,
        setScale  = function() set_scale_calls = set_scale_calls + 1 end,
    }
    me_camera.pan_to(10, 20)
    check('setScale untouched (RDP-safe)', set_scale_calls == 0)
end

-- ---------------------------------------------------------------------------
-- No mission open: me_mission.mission.map is missing → ok=false, setCamera
-- never called. Mirrors verbs.camera_focus's guard against ED throwing on
-- the menu / MP-browser / startup screen.
-- ---------------------------------------------------------------------------
do
    local cam_calls = 0
    _G.MapWindow = { setCamera = function() cam_calls = cam_calls + 1 end }

    package.loaded['me_mission'] = { mission = nil }
    local r1 = me_camera.pan_to(1, 2)
    check('no mission.mission: ok=false',           r1.ok == false)
    check('no mission.mission: error mentions mission',
          type(r1.error) == 'string' and r1.error:find('mission') ~= nil)

    package.loaded['me_mission'] = { mission = { map = nil } }
    local r2 = me_camera.pan_to(1, 2)
    check('no mission.map: ok=false',               r2.ok == false)

    check('no mission: setCamera never called',     cam_calls == 0)

    -- Restore so subsequent tests don't trip the guard.
    package.loaded['me_mission'] = { mission = { map = {} } }
end

print('')
if failures == 0 then
    print('All me_camera tests passed.')
    os.exit(0)
else
    print(failures .. ' me_camera tests FAILED.')
    os.exit(1)
end
