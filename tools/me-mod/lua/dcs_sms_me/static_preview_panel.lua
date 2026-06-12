-- static_preview_panel.lua — embedded 3D model preview for Paint Statics.
--
-- Wraps ED's DemoScene machinery (the same widget the vanilla ME Static
-- panel uses for its livery preview — see me_static.lua initLiveryPreview /
-- setPreviewType): ManagerDemoScene.newDemoScene('staticPreview.lua')
-- returns a DemoSceneWidget, an ordinary dxgui widget we insert into the
-- tool window. The scene script defines a GLOBAL `staticPreview` table
-- (camera state + per-frame update funcs); drag-rotate and wheel-zoom
-- work by adjusting its cameraAngH/V / cameraDistMult fields, exactly as
-- the vanilla panel does.
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

local Handle = {}
Handle.__index = Handle

-- The scene globals (populated by Scripts/DemoScenes/staticPreview.lua
-- when the scene loads). nil until the first newDemoScene call.
local function scene_globals()
    local sp = _G.staticPreview
    if type(sp) == 'table' then return sp end
    return nil
end

function M.create(parent_raw)
    if not (parent_raw and parent_raw.insertWidget) then return nil end

    local widget
    local ok = pcall(function()
        local ManagerDemoScene = require('ManagerDemoScene')
        widget = ManagerDemoScene.newDemoScene('staticPreview.lua')
        if not widget then error('newDemoScene returned nil') end
        parent_raw:insertWidget(widget)
    end)
    if not ok or not widget then
        log_write(log and log.WARNING or 2, '3D preview unavailable — falling back to text metadata')
        return nil
    end

    local self = setmetatable({
        widget   = widget,
        model    = nil,
        dragging = false,
        last_x   = 0,
        last_y   = 0,
        ang_h0   = 0,
        ang_v0   = 0,
    }, Handle)

    -- Drag-rotate + wheel-zoom, mirroring me_static.lua's callbacks. The
    -- camera state lives in the scene's global table; the per-frame update
    -- func reads it back.
    pcall(function()
        widget:addMouseDownCallback(function(w, x, y, button)
            local sp = scene_globals()
            if not sp then return end
            self.dragging = true
            self.last_x, self.last_y = x, y
            self.ang_h0, self.ang_v0 = sp.cameraAngH, sp.cameraAngV
            pcall(function()
                local sceneAPI = widget:getScene()
                sceneAPI:setUpdateFunc('staticPreview.payloadPreviewUpdateNoRotate')
            end)
            pcall(function() w:captureMouse() end)
        end)
        widget:addMouseUpCallback(function(w)
            self.dragging = false
            pcall(function() w:releaseMouse() end)
        end)
        widget:addMouseMoveCallback(function(_, x, y)
            if not self.dragging then return end
            local sp = scene_globals()
            if not sp then return end
            sp.cameraAngH = self.ang_h0 + (self.last_x - x) * sp.mouseSensitivity
            sp.cameraAngV = self.ang_v0 - (self.last_y - y) * sp.mouseSensitivity
            local cap = math.pi * 0.48
            if sp.cameraAngV > cap then sp.cameraAngV = cap end
            if sp.cameraAngV < -cap then sp.cameraAngV = -cap end
        end)
        widget:addMouseWheelCallback(function(_, _, _, clicks)
            local sp = scene_globals()
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

        local sp = scene_globals()
        if not sp then error('staticPreview scene globals missing') end

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
        sceneAPI:setUpdateFunc('staticPreview.payloadPreviewUpdate')

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
