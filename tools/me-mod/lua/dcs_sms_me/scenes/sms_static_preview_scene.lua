-- sms_static_preview_scene.lua — private DemoScene for the Paint Statics 3D preview.
--
-- THIS IS NOT A REQUIRE-ABLE MODULE. It is a DCS DemoScene script, loaded by
-- path through DemoSceneWidget:loadScript(...) from static_preview_panel.lua.
-- It runs in the scene Lua environment and defines globals (loadScene + the
-- state table), exactly like DCS's own Scripts/DemoScenes/staticPreview.lua.
-- Never `require` it.
--
-- WHY THIS EXISTS: the vanilla ME Static-object panel's 3D livery preview and
-- ours both used DCS's shared `staticPreview.lua`, which keeps its camera in a
-- single GLOBAL table (`staticPreview.scene.cam`). Whichever DemoSceneWidget
-- loaded its scene LAST owned that one camera slot; the other viewport froze,
-- and when a panel closed it destroyed the camera, leaving the survivor
-- pointing at a dead object. Switching between our tool and the vanilla Static
-- panel is constant, so this clone renames the global to
-- `dcs_sms_static_preview` — a private slot that never collides with vanilla's.
-- Both viewports now spin independently regardless of open/close order.
--
-- Kept a near-verbatim clone of staticPreview.lua (camera math, update funcs,
-- loadScene) so behaviour matches the vanilla viewport the user already knows.
-- `loadScene` is necessarily the global name the DemoSceneWidget contract calls;
-- it is invoked synchronously right after loadScript, so the transient global
-- collision with vanilla's `loadScene` never matters in practice.

local sceneEnvironment = require('demosceneEnvironment')

dcs_sms_static_preview =
{
    scene = {},

    objectHeight = 5000,         -- height of the object the camera orbits

    cameraSpeed  = 0.25,
    cameraFov    = 60,
    cameraAngVDefault = math.rad(25),
    cameraDistance = 50,
    cameraDistMult = 0,

    cameraAngH   = 0,
    cameraAngV   = 0,
    cameraRadius = 0,
    cameraHeight = 0,
    camAng = 0,
    camDist = 0,
    camTime = 0,

    mouseSensitivity = 0.0034,   -- camera rotate speed (drag)
    wheelSensitivity = 0.02,     -- camera zoom speed (wheel)
}

-- Auto-rotating per-frame update (advances camTime → orbits the camera).
dcs_sms_static_preview.payloadPreviewUpdate = function(t, dt)
    local s = dcs_sms_static_preview
    s.camTime = s.camTime + dt
    s.camAng = s.cameraSpeed * s.camTime + s.cameraAngH
    s.camDist = s.cameraDistance * math.exp(s.cameraDistMult)
    s.cameraHeight = math.sin(s.cameraAngV) * s.camDist
    s.cameraRadius = math.cos(s.cameraAngV) * s.camDist
    s.scene.cam.transform:setPosition(
        math.sin(s.camAng) * s.cameraRadius,
        s.objectHeight + s.cameraHeight,
        math.cos(s.camAng) * s.cameraRadius)
    s.scene.cam.transform:lookAtPoint(0, s.objectHeight, 0)
end

-- Drag-hold update: holds camTime fixed so the model doesn't auto-spin while
-- the user rotates by dragging (cameraAngH/V are driven by the mouse handler).
dcs_sms_static_preview.payloadPreviewUpdateNoRotate = function(t, dt)
    local s = dcs_sms_static_preview
    s.camAng = s.cameraSpeed * s.camTime + s.cameraAngH
    s.camDist = s.cameraDistance * math.exp(s.cameraDistMult)
    s.cameraHeight = math.sin(s.cameraAngV) * s.camDist
    s.cameraRadius = math.cos(s.cameraAngV) * s.camDist
    s.scene.cam.transform:setPosition(
        math.sin(s.camAng) * s.cameraRadius,
        s.objectHeight + s.cameraHeight,
        math.cos(s.camAng) * s.cameraRadius)
    s.scene.cam.transform:lookAtPoint(0, s.objectHeight, 0)
end

function loadScene(scenePtr)
    local sceneAPI = sceneEnvironment.getInterface(scenePtr)
    sceneAPI:setSky(true)
    sceneAPI:setEnvironmentMap("nevada01")
    dcs_sms_static_preview.scene.cam = sceneAPI:addCamera(0, 0, 0)
    dcs_sms_static_preview.scene.cam:setNearClip(0.2)
    dcs_sms_static_preview.scene.cam:setFarClip(10000)
end
