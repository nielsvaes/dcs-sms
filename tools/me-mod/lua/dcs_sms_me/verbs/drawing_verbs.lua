-- dcs_sms_me/verbs/drawing_verbs.lua — F10-map drawing CRUD.
--
-- Verbs: drawing_list, drawing_get, drawing_remove,
-- drawing_create_<circle|oval|rect|arrow|line|polygon|chevron|textbox|icon>,
-- drawing_set_<color|fill_color|pos|name|text|thickness|angle>.
-- See dcs_sms_me/verbs.lua for the aggregator and the verb-naming convention.

local M = {}

-- Drawing verbs operate against me_draw_panel, not the mission-table coalition
-- tree, so they don't pull any of the helpers from verb_helpers.lua.

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

-- commit_to_mission — resync the cached mission.drawings table from the live
-- draw panel after a saveToMission → modify → loadFromMission cycle.
--
-- The ME serializer (me_mission.unload) reads mission.drawings — a CACHE —
-- rather than calling me_draw_panel.saveToMission() at save time. loadFromMission
-- rebuilds the panel's live layers_ (so the change renders) but does NOT touch
-- that cache; ED only resyncs it on its own draw-panel events (objectDelete at
-- me_draw_panel.lua:1477, onClose at :2050). A verb-driven create/edit fires
-- none of those, so without this the drawing renders but is silently dropped on
-- the next `me file save` until the user touches the Draw panel. Mirror ED's own
-- `mission.drawings = saveToMission()`. pcall-guarded so a missing me_mission /
-- panel API degrades to a no-op rather than failing the verb. (drawing_remove
-- needs no equivalent — it goes through panel.objectDelete, which ED resyncs.)
local function commit_to_mission(panel)
    pcall(function()
        local Mission = require('me_mission')
        if type(Mission.mission) == 'table' and type(panel.saveToMission) == 'function' then
            Mission.mission.drawings = panel.saveToMission()
        end
    end)
end

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
    commit_to_mission(panel)
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
    commit_to_mission(panel)
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
    local f_name_prefix = args.name_prefix and string.lower(args.name_prefix) or nil

    local panel = require('me_draw_panel')
    local out = {}
    for name, obj in pairs(panel.getObjects()) do
        local mode = obj.polygonMode or obj.lineMode
        local name_lc = string.lower(name)
        if not (f_layer and obj.layerName ~= f_layer)
                and not (f_type and obj.primitiveType ~= f_type)
                and not (f_mode and (not mode or string.lower(mode) ~= f_mode))
                and not (f_name and not string.find(name_lc, f_name, 1, true))
                and not (f_name_prefix and string.sub(name_lc, 1, #f_name_prefix) ~= f_name_prefix) then
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
                -- points[] from saveToMission is stored relative to the anchor
                -- (mapX, mapY). That round-trips through loadFromMission but
                -- is non-obvious for callers that just want to draw the shape
                -- somewhere else — surface absolute world coords too so they
                -- don't have to redo the sum every time.
                if type(obj_save.points) == 'table' and #obj_save.points > 0 then
                    local abs = {}
                    for i, p in ipairs(obj_save.points) do
                        abs[i] = {
                            north = (obj_save.mapX or 0) + (p.x or 0),
                            east  = (obj_save.mapY or 0) + (p.y or 0),
                        }
                    end
                    snapshot.points_absolute = abs
                end
                return { ok = true, drawing = snapshot }
            end
        end
    end
    return { ok = false, error = 'drawing not found' }
end

-- drawing_remove — delete one or many drawings.
--
-- Three calling shapes (validated by the CLI; this verb is forgiving and
-- works directly too):
--   1. { name = 'X' }                        — exact single delete.
--   2. { name_prefix = 'P' [, layer = 'L'] } — batch delete every drawing
--                                              whose name starts with P
--                                              (case-insensitive), optionally
--                                              scoped to a single layer.
--   3. { layer = 'L', all = true }           — wipe a full layer (the `all`
--                                              flag exists so callers don't
--                                              do this by accident).
--
-- Returns { ok=true, removed = {names...}, count = N }. Reports
-- ok=false when zero drawings matched the selector so the CLI can
-- distinguish "no-op" from "environment problem".
function M.drawing_remove(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'drawing_remove requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_prefix = type(args.name_prefix) == 'string' and args.name_prefix ~= ''
    local has_layer = type(args.layer) == 'string' and args.layer ~= ''
    local wipe_layer = args.all == true

    if not has_name and not has_prefix and not has_layer then
        return { ok = false, error = 'drawing_remove: provide name, name_prefix, or layer (with all=true)' }
    end
    if has_name and (has_prefix or has_layer) then
        return { ok = false, error = 'drawing_remove: name is exclusive with name_prefix and layer' }
    end
    if not has_name and not has_prefix and has_layer and not wipe_layer then
        return { ok = false, error = 'drawing_remove: layer-only selector requires all=true' }
    end

    local panel = require('me_draw_panel')
    local objects = panel.getObjects()

    -- Single-name fast path keeps the legacy shape.
    if has_name then
        local obj = objects[args.name]
        if not obj then
            return { ok = false, error = 'drawing not found' }
        end
        local ok_call, err = pcall(panel.objectDelete, obj)
        if not ok_call then
            return { ok = false, error = 'objectDelete: ' .. tostring(err) }
        end
        return { ok = true, removed = { args.name }, count = 1, name = args.name }
    end

    -- Batch path. Collect first (don't mutate while iterating panel.getObjects).
    local prefix_lc = has_prefix and string.lower(args.name_prefix) or nil
    local to_remove = {}
    for name, obj in pairs(objects) do
        local match_layer = (not has_layer) or obj.layerName == args.layer
        local match_prefix = (not prefix_lc) or string.sub(string.lower(name), 1, #prefix_lc) == prefix_lc
        if match_layer and match_prefix then
            table.insert(to_remove, { name = name, obj = obj })
        end
    end
    table.sort(to_remove, function(a, b) return a.name < b.name end)

    if #to_remove == 0 then
        return { ok = false, error = 'no drawings matched selector', removed = {}, count = 0 }
    end

    local removed = {}
    for _, entry in ipairs(to_remove) do
        local ok_call, err = pcall(panel.objectDelete, entry.obj)
        if not ok_call then
            return {
                ok = false,
                error = 'objectDelete failed on "' .. entry.name .. '": ' .. tostring(err),
                removed = removed,
                count = #removed,
            }
        end
        table.insert(removed, entry.name)
    end
    return { ok = true, removed = removed, count = #removed }
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

-- drawing_create_chevron — V-shape / directional tick mark.
--
-- Built on top of the same Line/segments plumbing as drawing_create_line,
-- but the 3 vertices (left-arm, tip, right-arm) are computed from a
-- compact spec so callers don't have to redo the trig for every tick they
-- want to draw on a route or threat-direction indicator.
--
-- args (required):
--   north, east   meters; the tip of the V
--   bearing       degrees, 0=N, 90=E, clockwise; the direction the tip points
--   size          meters; length of each arm extending backward from the tip
--
-- args (optional):
--   arm_angle           degrees; angle of each arm from the forward bearing.
--                       Default 100 (wide V — 160° tip, good for route ticks).
--                       150 gives a tight 60° arrowhead. Must be in (0, 180).
--   name, color, thickness, style, layer, hidden_on_planner — same as
--   drawing_create_line.
function M.drawing_create_chevron(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'drawing_create_chevron requires args (table)' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'drawing_create_chevron requires args.north and args.east (numbers, meters)' }
    end
    if type(args.bearing) ~= 'number' then
        return { ok = false, error = 'drawing_create_chevron requires args.bearing (degrees)' }
    end
    if type(args.size) ~= 'number' or args.size <= 0 then
        return { ok = false, error = 'drawing_create_chevron requires args.size (meters > 0)' }
    end
    local arm_angle = args.arm_angle or 100
    if type(arm_angle) ~= 'number' or arm_angle <= 0 or arm_angle >= 180 then
        return { ok = false, error = 'drawing_create_chevron: arm_angle must be in (0, 180) degrees' }
    end

    -- Bearing 0 = north (mission-table x axis); rotate clockwise.
    -- Arm endpoints sit at bearing +/- arm_angle from the tip.
    local rad = math.pi / 180
    local b = args.bearing
    local n_tip, e_tip = args.north, args.east
    local function arm_endpoint(offset_deg)
        local theta = (b + offset_deg) * rad
        return n_tip + args.size * math.cos(theta),
               e_tip + args.size * math.sin(theta)
    end
    local n_left,  e_left  = arm_endpoint( arm_angle)
    local n_right, e_right = arm_endpoint(-arm_angle)

    -- Order: left-arm -> tip -> right-arm. Segments mode draws the two
    -- arms of the V; the tip is the shared vertex.
    local vertices = {
        { north = n_left,  east = e_left  },
        { north = n_tip,   east = e_tip   },
        { north = n_right, east = e_right },
    }
    local cx, cy, rel = compute_center_and_relative_points(vertices)
    local name = (type(args.name) == 'string' and args.name ~= '') and args.name
                 or unique_drawing_name('Chevron')

    local obj = {
        primitiveType = 'Line',
        name = name,
        colorString = args.color or '0xff0000ff',
        mapX = cx, mapY = cy,
        visible = true,
        hiddenOnPlanner = (args.hidden_on_planner == true),
        lineMode = 'segments',
        style = args.style or DEFAULT_LINE_STYLE,
        thickness = args.thickness or DEFAULT_THICKNESS,
        closed = false,
        points = rel,
    }
    local _, err = inject_drawing(obj, args.layer or 'Common')
    if err then return { ok = false, error = err } end
    return {
        ok = true, name = name, type = 'Line', mode = 'segments',
        north = cx, east = cy,
        tip = { north = n_tip, east = e_tip },
        bearing = b, size = args.size, arm_angle = arm_angle,
        layer = args.layer or 'Common',
    }
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

return M
