-- static_preview_panel.lua — embedded 3D model preview for Paint Statics.
--
-- Wraps ED's DemoScene machinery (the same widget the vanilla ME Static
-- panel uses for its livery preview — see me_static.lua initLiveryPreview /
-- setPreviewType): a DemoSceneWidget is an ordinary dxgui widget we insert
-- into the tool window, driven by a scene script that defines a global
-- state table (camera + per-frame update funcs). Drag-rotate and wheel-zoom
-- adjust that table's cameraAngH/V / cameraDistMult, exactly as vanilla does.
--
-- PRIVATE SCENE (not the shared one): DCS's own Scripts/DemoScenes/
-- staticPreview.lua keeps its camera in a single GLOBAL `staticPreview`
-- table, and the vanilla ME Static panel uses the same file — so whichever
-- DemoSceneWidget loaded last owned the one camera slot and the other froze
-- (and a closing panel destroyed the shared camera, dangling the survivor).
-- We instead load our own clone, scenes/sms_static_preview_scene.lua, which
-- defines a private `dcs_sms_static_preview` global — fully isolated from the
-- vanilla panel regardless of open/close order. If our scene can't be loaded
-- (odd install), we fall back to the shared vanilla scene so the preview
-- still works, just with the old contention.
--
-- Everything is pcall-guarded and the module degrades to "no preview":
-- create() returns nil on any failure, set_type() returns false — the
-- caller then shows its text/metadata fallback. A 3D-widget failure must
-- never take painting down (design brief D10).
--
-- Public:
--   M.create(parent_raw) → handle | nil
--   handle:set_type(type_name) → ok, err   -- show this static's model
--   handle:set_bounds(x, y, w, h)
--   handle:set_visible(visible)
--   handle:dispose()

local M = {}

local function log_write(level, msg)
    pcall(function() log.write('sms.me.paint.preview', level, msg) end)
end

-- DCS-root-relative path to our private scene script (installed alongside
-- the rest of the mod under MissionEditor/modules/dcs_sms_me/). loadScript
-- resolves relative to the DCS root, the same way the vanilla panel loads
-- 'Scripts/DemoScenes/staticPreview.lua'.
local PRIVATE_SCENE_PATH   = 'MissionEditor/modules/dcs_sms_me/scenes/sms_static_preview_scene.lua'
local PRIVATE_SCENE_GLOBAL = 'dcs_sms_static_preview'
local SHARED_SCENE_GLOBAL  = 'staticPreview'

local Handle = {}
Handle.__index = Handle

-- The scene state table for THIS handle (our private global, or the shared
-- vanilla one if we fell back). self.scene_global is the global's name.
local function scene_globals(self)
    local sp = _G[self.scene_global]
    if type(sp) == 'table' then return sp end
    return nil
end

function M.create(parent_raw)
    if not (parent_raw and parent_raw.insertWidget) then return nil end

    -- Prefer our private scene (isolated camera). Fall back to the shared
    -- vanilla scene via ManagerDemoScene if loadScript fails for any reason.
    local widget, scene_global
    local ok = pcall(function()
        local DemoSceneWidget = require('DemoSceneWidget')
        local w = DemoSceneWidget.new()
        w:loadScript(PRIVATE_SCENE_PATH)
        if type(_G[PRIVATE_SCENE_GLOBAL]) ~= 'table' then
            error('private scene global not defined after loadScript')
        end
        widget, scene_global = w, PRIVATE_SCENE_GLOBAL
        parent_raw:insertWidget(widget)
    end)
    if not ok or not widget then
        log_write(log and log.WARNING or 2,
            'private preview scene unavailable, using shared vanilla scene')
        widget, scene_global = nil, nil
        local ok2 = pcall(function()
            local ManagerDemoScene = require('ManagerDemoScene')
            local w = ManagerDemoScene.newDemoScene('staticPreview.lua')
            if not w then error('newDemoScene returned nil') end
            widget, scene_global = w, SHARED_SCENE_GLOBAL
            parent_raw:insertWidget(widget)
        end)
        if not ok2 or not widget then
            log_write(log and log.WARNING or 2, '3D preview unavailable — falling back to text metadata')
            return nil
        end
    end

    local self = setmetatable({
        widget       = widget,
        scene_global = scene_global,                       -- 'dcs_sms_static_preview' or 'staticPreview'
        update_func  = scene_global .. '.payloadPreviewUpdate',
        norot_func   = scene_global .. '.payloadPreviewUpdateNoRotate',
        model        = nil,
        dragging     = false,
        last_x       = 0,
        last_y       = 0,
        ang_h0       = 0,
        ang_v0       = 0,
    }, Handle)

    -- Drag-rotate + wheel-zoom, mirroring me_static.lua's callbacks. The
    -- camera state lives in this handle's scene global table; the per-frame
    -- update func reads it back.
    pcall(function()
        widget:addMouseDownCallback(function(w, x, y, button)
            local sp = scene_globals(self)
            if not sp then return end
            self.dragging = true
            self.last_x, self.last_y = x, y
            self.ang_h0, self.ang_v0 = sp.cameraAngH, sp.cameraAngV
            pcall(function()
                local sceneAPI = widget:getScene()
                sceneAPI:setUpdateFunc(self.norot_func)
            end)
            pcall(function() w:captureMouse() end)
        end)
        widget:addMouseUpCallback(function(w)
            self.dragging = false
            pcall(function() w:releaseMouse() end)
        end)
        widget:addMouseMoveCallback(function(_, x, y)
            if not self.dragging then return end
            local sp = scene_globals(self)
            if not sp then return end
            sp.cameraAngH = self.ang_h0 + (self.last_x - x) * sp.mouseSensitivity
            sp.cameraAngV = self.ang_v0 - (self.last_y - y) * sp.mouseSensitivity
            local cap = math.pi * 0.48
            if sp.cameraAngV > cap then sp.cameraAngV = cap end
            if sp.cameraAngV < -cap then sp.cameraAngV = -cap end
        end)
        widget:addMouseWheelCallback(function(_, _, _, clicks)
            local sp = scene_globals(self)
            if not sp then return end
            sp.cameraDistMult = sp.cameraDistMult - clicks * sp.wheelSensitivity
            if sp.cameraDistMult > 2.3 then sp.cameraDistMult = 2.3 end
            return true
        end)
    end)

    return self
end

-- Resolve a unit def's model shape, preferring the richer descriptors —
-- same chain as me_utilities.getShape (which we call when available).
local function resolve_shape(unitDef)
    local shape
    pcall(function()
        local U = require('me_utilities')
        if type(U.getShape) == 'function' then shape = U.getShape(unitDef) end
    end)
    if shape == nil then shape = unitDef.ShapeName or unitDef.Shape end
    if shape == '' then shape = nil end
    return shape
end

function Handle:set_type(type_name)
    local ok, err = pcall(function()
        local DB = require('me_db_api')
        local unitDef = DB.unit_by_type and DB.unit_by_type[type_name]
        if not unitDef then error('unknown type: ' .. tostring(type_name)) end

        local sceneAPI = self.widget:getScene()
        if self.model ~= nil and self.model.obj ~= nil then
            pcall(function() sceneAPI.remove(self.model) end)
            self.model = nil
        end

        local shape = resolve_shape(unitDef)
        if not shape then error('no shape for type: ' .. tostring(type_name)) end

        local sp = scene_globals(self)
        if not sp then error(self.scene_global .. ' scene globals missing') end

        local model = sceneAPI:addModel(shape, 0, sp.objectHeight, 0)
        if not (model and model.valid == true) then
            error('model failed to load: ' .. tostring(shape))
        end
        self.model = model

        -- Center on the bounding box and pull the camera back far enough
        -- to frame the whole model (vanilla setPreviewType math).
        local radius = model:getRadius()
        local x0, y0, z0, x1, y1, z1 = model:getBBox()
        model.transform:setPosition(-(x0 + x1) * 0.5,
                                    sp.objectHeight - (y0 + y1) * 0.5,
                                    -(z0 + z1) * 0.5)
        sp.cameraDistMult = 0
        sp.cameraAngV = sp.cameraAngVDefault
        sp.cameraDistance = radius / math.tan(math.rad(sp.cameraFov * 0.5))
        sceneAPI:setUpdateFunc(self.update_func)

        -- Encyclopedia pose arguments (gear up, doors closed, …).
        if unitDef.encyclopediaAnimation and unitDef.encyclopediaAnimation.args then
            for arg, value in pairs(unitDef.encyclopediaAnimation.args) do
                pcall(function() model:setArgument(arg, value) end)
            end
        end
    end)
    if not ok then
        log_write(log and log.INFO or 3, 'preview set_type failed: ' .. tostring(err))
        return false, tostring(err)
    end
    return true
end

function Handle:set_bounds(x, y, w, h)
    pcall(function()
        self.widget:setBounds(x, y, w, h)
        self.widget.aspect = w / math.max(h, 1)
    end)
end

function Handle:set_visible(visible)
    pcall(function() self.widget:setVisible(visible == true) end)
end

function Handle:dispose()
    pcall(function()
        local ManagerDemoScene = require('ManagerDemoScene')
        if ManagerDemoScene.removeWidget then ManagerDemoScene.removeWidget(self.widget) end
    end)
    pcall(function() self.widget:destroy() end)
    self.widget, self.model = nil, nil
end

return M
