-- paint_statics.lua — "Paint Statics" tool window (M0 spike stage).
--
-- M0: instrumented brush state machine over me_map_window. Arms a map
-- state that paints a hardcoded static type along a held left-drag and
-- draws a cursor-following brush circle. Records event counts so the
-- "does onMouseDrag fire continuously?" question (design brief §3) can
-- be answered empirically via the gui bridge.
--
-- Debug surface (gui-bridge driven, no UI yet):
--   M._arm_spike(opts)     — install the brush map state
--   M._disarm_spike()      — restore pan state, remove overlay
--   M._spike_stats()       — event counters + placed-static names
--
-- See: docs/superpowers/specs/2026-06-12-paint-statics-design.md

local M = {}

local S = {
    armed       = false,
    painting    = false,
    pan_state   = nil,
    brush_id    = nil,   -- MapWindow draw-object id for the brush circle
    brush_data  = nil,
    radius      = 50,    -- meters
    country     = nil,   -- country name used by the spike
    static_type = 'Oil Barrel',
    category    = 'Structures',
    shape_name  = 'M92_Oilbarrel',
    min_step    = 8,     -- meters between spike placements along a drag
    last        = nil,   -- last placed world point {x, y}
    events      = nil,
    placed      = nil,   -- list of group names created by the spike
}

local function log_write(level, msg)
    pcall(function() log.write('sms.me.paint', level, msg) end)
end

-- Build a closed N-gon approximating a circle, for MapWindow draw objects.
local function circle_points(radius, n)
    n = n or 36
    local pts = {}
    for i = 0, n do
        local a = (i / n) * 2 * math.pi
        pts[#pts + 1] = { x = radius * math.cos(a), y = radius * math.sin(a) }
    end
    return pts
end

local function remove_brush_overlay()
    pcall(function()
        if S.brush_id then
            local MapWindow = require('me_map_window')
            if MapWindow and MapWindow.removeDrawObject then
                MapWindow.removeDrawObject(S.brush_id)
            end
        end
    end)
    S.brush_id, S.brush_data = nil, nil
end

local function create_brush_overlay()
    pcall(function()
        local MapWindow = require('me_map_window')
        if not (MapWindow and MapWindow.createDrawObject) then return end
        local data = {
            objectType = 'Polygon',
            points     = circle_points(S.radius),
            thickness  = 2,
            color      = { 0.2, 1, 0.4, 1 },     -- green outline
            fillColor  = { 0.2, 1, 0.4, 0.08 },  -- faint green fill
            file       = './MissionEditor/data/NewMap/images/draw/polyline_solid.png',
            x          = 0,
            y          = 0,
            angle      = 0,
        }
        S.brush_data = data
        S.brush_id = MapWindow.createDrawObject(data)
        if S.brush_id and MapWindow.addDrawObject then
            pcall(function() MapWindow.addDrawObject(S.brush_id) end)
        end
    end)
end

local function move_brush_overlay(wx, wy)
    pcall(function()
        if not (S.brush_id and S.brush_data) then return end
        S.brush_data.x, S.brush_data.y = wx, wy
        local MapWindow = require('me_map_window')
        if MapWindow and MapWindow.updateDrawObject then
            MapWindow.updateDrawObject(S.brush_id, S.brush_data)
        end
    end)
end

-- Pick a usable country for the spike: prefer USA, else first mission country.
local function pick_country()
    local name
    pcall(function()
        local Mission = require('me_mission')
        if type(Mission.missionCountry) ~= 'table' then return end
        if Mission.missionCountry['USA'] then name = 'USA'; return end
        local names = {}
        for n in pairs(Mission.missionCountry) do
            if type(n) == 'string' then names[#names + 1] = n end
        end
        table.sort(names)
        name = names[1]
    end)
    return name
end

-- Place one hardcoded static at world (wx, wy) through the real verb path.
local function spike_place(wx, wy, source)
    local ok = pcall(function()
        local verbs = require('dcs_sms_me.verbs')
        local r = verbs.group_create_static({
            country     = S.country,
            type        = S.static_type,
            category    = S.category,
            shape_name  = S.shape_name,
            north       = wx,
            east        = wy,
            name        = 'PaintSpike #001',
            heading_deg = 0,
        })
        if r and r.ok then
            S.placed[#S.placed + 1] = r.name
        else
            log_write(log.WARNING, 'spike place failed: ' .. tostring(r and r.error))
        end
    end)
    if not ok then log_write(log.ERROR, 'spike_place threw (' .. tostring(source) .. ')') end
end

-- Place if the cursor world point moved at least min_step from last placement.
local function spike_step(wx, wy, source)
    if S.last then
        local dx, dy = wx - S.last.x, wy - S.last.y
        if (dx * dx + dy * dy) < (S.min_step * S.min_step) then return end
    end
    S.last = { x = wx, y = wy }
    spike_place(wx, wy, source)
end

function M._arm_spike(opts)
    opts = opts or {}
    if S.armed then return { ok = false, error = 'already armed' } end
    S.radius      = tonumber(opts.radius) or S.radius
    S.min_step    = tonumber(opts.min_step) or S.min_step
    S.country     = opts.country or pick_country()
    if not S.country then return { ok = false, error = 'no country available in mission' } end
    S.events = { down = 0, drag = 0, drag_other = 0, move = 0, up = 0, wheel = 0 }
    S.placed = {}
    S.last   = nil

    local ok, err = pcall(function()
        local MapWindow = require('me_map_window')
        if not (MapWindow and MapWindow.setState and MapWindow.getPanState and MapWindow.getMapPoint) then
            error('me_map_window missing required symbols')
        end
        S.pan_state = MapWindow.getPanState()
        local function forward(method, ...)
            local ps = S.pan_state
            if not ps then return end
            local fn = ps[method]
            if type(fn) == 'function' then pcall(fn, ps, ...) end
        end

        local brush_state = {}

        function brush_state:onMouseDown(x, y, button)
            if button ~= 1 then
                forward('onMouseDown', x, y, button)
                return
            end
            S.events.down = S.events.down + 1
            pcall(function()
                local wx, wy = MapWindow.getMapPoint(x, y)
                if not (wx and wy) then return end
                S.painting = true
                S.last = nil
                spike_step(wx, wy, 'down')
                move_brush_overlay(wx, wy)
            end)
        end

        function brush_state:onMouseUp(x, y, button)
            if button ~= 1 then
                forward('onMouseUp', x, y, button)
                return
            end
            S.events.up = S.events.up + 1
            S.painting = false
        end

        function brush_state:onMouseDrag(dx, dy, button, x, y)
            if button ~= 1 then
                S.events.drag_other = S.events.drag_other + 1
                forward('onMouseDrag', dx, dy, button, x, y)
                return
            end
            S.events.drag = S.events.drag + 1
            pcall(function()
                if not S.painting then return end
                local wx, wy = MapWindow.getMapPoint(x, y)
                if not (wx and wy) then return end
                spike_step(wx, wy, 'drag')
                move_brush_overlay(wx, wy)
            end)
        end

        function brush_state:onMouseMove(x, y)
            S.events.move = S.events.move + 1
            forward('onMouseMove', x, y)
            pcall(function()
                local wx, wy = MapWindow.getMapPoint(x, y)
                if not (wx and wy) then return end
                move_brush_overlay(wx, wy)
                -- Fallback sampling path: if onMouseDrag turns out not to
                -- fire during a held left-drag, S.painting set by onMouseDown
                -- lets us sample here instead. Tagged 'move' in stats.
                if S.painting then spike_step(wx, wy, 'move') end
            end)
        end

        function brush_state:onMouseWheel(x, y, clicks)
            S.events.wheel = S.events.wheel + 1
            forward('onMouseWheel', x, y, clicks)
        end

        create_brush_overlay()
        MapWindow.setState(brush_state)
    end)
    if not ok then
        remove_brush_overlay()
        S.pan_state = nil
        return { ok = false, error = tostring(err) }
    end
    S.armed = true
    log_write(log.INFO, 'spike armed (country=' .. tostring(S.country) .. ')')
    return { ok = true, country = S.country }
end

function M._disarm_spike()
    if not S.armed then return { ok = false, error = 'not armed' } end
    remove_brush_overlay()
    pcall(function()
        local MapWindow = require('me_map_window')
        if MapWindow and MapWindow.setState and MapWindow.getPanState then
            MapWindow.setState(MapWindow.getPanState())
        end
    end)
    S.armed, S.painting, S.pan_state, S.last = false, false, nil, nil
    log_write(log.INFO, 'spike disarmed; placed=' .. tostring(S.placed and #S.placed or 0))
    return { ok = true, placed = S.placed and #S.placed or 0 }
end

function M._spike_stats()
    return {
        ok      = true,
        armed   = S.armed,
        events  = S.events,
        placed  = S.placed and #S.placed or 0,
        names   = S.placed,
    }
end

return M
