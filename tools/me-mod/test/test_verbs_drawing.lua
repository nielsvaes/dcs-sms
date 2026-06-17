-- test_verbs_drawing.lua — Lua-side unit tests for verbs/drawing_verbs.lua.

local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path

local mock = require('mock_me_mission')
package.preload['me_mission']    = function() return mock end
package.preload['me_map_window'] = function() return mock end

-- ============================================================
-- me_draw_panel stub
-- ============================================================
-- Maintains an internal layered list of drawing objects. The real panel's
-- saveToMission / loadFromMission round-trip is a full rewrite; the stub
-- mirrors that. getObjects() returns a name→runtime-object map (mapData =
-- {x, y} mirrors mapX/mapY for read-side parity).
local state = { layers = {} }

local function default_layers()
    return {
        { name = 'Red',     objects = {} },
        { name = 'Blue',    objects = {} },
        { name = 'Neutral', objects = {} },
        { name = 'Common',  objects = {} },
        { name = 'Author',  objects = {} },
    }
end

local function deep_copy(t)
    if type(t) ~= 'table' then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deep_copy(v) end
    return out
end

local panel = {}

function panel.saveToMission()
    return deep_copy(state)
end

function panel.loadFromMission(data)
    state = { layers = {} }
    for _, l in ipairs((data and data.layers) or {}) do
        local lc = { name = l.name, objects = {} }
        for _, o in ipairs(l.objects or {}) do
            local oc = deep_copy(o)
            oc.layerName = l.name
            table.insert(lc.objects, oc)
        end
        table.insert(state.layers, lc)
    end
end

function panel.getObjects()
    local out = {}
    for _, l in ipairs(state.layers or {}) do
        for _, o in ipairs(l.objects or {}) do
            local runtime = deep_copy(o)
            runtime.mapData = { x = o.mapX, y = o.mapY }
            runtime.layerName = l.name
            out[o.name] = runtime
        end
    end
    return out
end

function panel.objectDelete(obj)
    for _, l in ipairs(state.layers or {}) do
        for i, o in ipairs(l.objects or {}) do
            if o.name == obj.name then
                table.remove(l.objects, i)
                return
            end
        end
    end
end

function panel._reset() state = { layers = default_layers() } end

package.preload['me_draw_panel'] = function() return panel end

-- Stubs for sibling modules pulled in by the aggregator.
package.preload['terrain'] = function()
    return { GetSurfaceType = function() return 'sea' end }
end
package.preload['utils_common'] = function() return { actions = {} } end
package.preload['me_db_api']    = function() return { templates = {}, unit_by_type = {} } end
package.preload['me_payload']   = function() return { setDefaultLivery = function() end } end
package.preload['me_route']     = function()
    return { isAirfieldWaypoint = function() return false end,
             attractToAirfield = function() end,
             update = function() end }
end

package.path = here .. '../lua/?.lua;' .. here .. '../lua/?/init.lua;' .. package.path

local verbs = require('dcs_sms_me.verbs')

-- ============================================================
-- Test harness
-- ============================================================

local passed, failed, errors = 0, 0, {}

local function assert_eq(actual, expected, name)
    if actual == expected then passed = passed + 1
    else failed = failed + 1
        table.insert(errors, string.format('%s: expected %s, got %s',
            name, tostring(expected), tostring(actual)))
    end
end

local function assert_true(cond, name)  assert_eq(cond and true or false, true, name) end
local function assert_false(cond, name) assert_eq(cond and true or false, false, name) end

local function assert_contains(haystack, needle, name)
    if type(haystack) == 'string' and haystack:find(needle, 1, true) then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(errors, string.format('%s: expected string containing %q, got %s',
            name, needle, tostring(haystack)))
    end
end

local function reset() panel._reset(); mock.new_mission() end

-- Walk the cached mission.drawings table (saveToMission shape) for a name.
local function cache_has_drawing(cache, name)
    if type(cache) ~= 'table' or type(cache.layers) ~= 'table' then return false end
    for _, l in ipairs(cache.layers) do
        for _, o in ipairs(l.objects or {}) do
            if o.name == name then return true end
        end
    end
    return false
end

-- ============================================================
-- drawing_create_circle
-- ============================================================

local function test_create_circle_happy()
    reset()
    local r = verbs.drawing_create_circle({
        north = 1000, east = 2000, radius = 500 })
    assert_true(r.ok, 'create_circle: ok')
    assert_eq(r.type, 'Polygon', 'create_circle: type=Polygon')
    assert_eq(r.mode, 'circle', 'create_circle: mode=circle')
    assert_eq(r.layer, 'Common', 'create_circle: default layer')
    assert_eq(r.radius, 500, 'create_circle: radius')
    assert_eq(panel.getObjects()[r.name].mapData.x, 1000, 'create_circle: stored mapData.x')
    assert_eq(panel.getObjects()[r.name].mapData.y, 2000, 'create_circle: stored mapData.y')
end

local function test_create_circle_auto_name_increments()
    reset()
    local r1 = verbs.drawing_create_circle({ north = 0, east = 0, radius = 100 })
    local r2 = verbs.drawing_create_circle({ north = 0, east = 0, radius = 100 })
    assert_eq(r1.name, 'Circle-1', 'create_circle auto name 1')
    assert_eq(r2.name, 'Circle-2', 'create_circle auto name 2')
end

local function test_create_circle_custom_layer()
    reset()
    local r = verbs.drawing_create_circle({
        north = 0, east = 0, radius = 100, layer = 'Red' })
    assert_eq(r.layer, 'Red', 'create_circle Red: layer')
    assert_eq(panel.getObjects()[r.name].layerName, 'Red', 'create_circle: stored on Red layer')
end

local function test_create_circle_unknown_layer()
    reset()
    local r = verbs.drawing_create_circle({
        north = 0, east = 0, radius = 100, layer = 'Bogus' })
    assert_false(r.ok, 'create_circle bogus layer: refused')
    assert_contains(r.error, 'unknown layer', 'create_circle: layer error')
end

local function test_create_circle_arg_validation()
    reset()
    assert_false(verbs.drawing_create_circle(nil).ok, 'create_circle: nil')
    assert_false(verbs.drawing_create_circle({}).ok, 'create_circle: empty')
    assert_false(verbs.drawing_create_circle({ north = 0, east = 0 }).ok,
                 'create_circle: missing radius')
    assert_false(verbs.drawing_create_circle({ north = 0, east = 0, radius = 0 }).ok,
                 'create_circle: zero radius')
    assert_false(verbs.drawing_create_circle({ north = 0, east = 0, radius = -1 }).ok,
                 'create_circle: negative radius')
end

-- ============================================================
-- drawing_create_rect / oval / arrow
-- ============================================================

local function test_create_rect_happy()
    reset()
    local r = verbs.drawing_create_rect({
        north = 100, east = 200, width = 300, height = 400, angle_deg = 45 })
    assert_true(r.ok, 'create_rect: ok')
    assert_eq(r.mode, 'rect', 'create_rect: mode')
    assert_eq(r.width, 300, 'create_rect: width')
    assert_eq(r.height, 400, 'create_rect: height')
    assert_eq(r.angle, 45, 'create_rect: angle (degrees)')
    -- IMPORTANT: angle is stored in DEGREES verbatim, not radians
    assert_eq(panel.getObjects()[r.name].angle, 45,
              'create_rect: angle stored in degrees not radians')
end

local function test_create_rect_arg_validation()
    reset()
    assert_false(verbs.drawing_create_rect({ north = 0, east = 0, height = 100 }).ok,
                 'create_rect: missing width')
    assert_false(verbs.drawing_create_rect({ north = 0, east = 0, width = 100 }).ok,
                 'create_rect: missing height')
    assert_false(verbs.drawing_create_rect({ north = 0, east = 0, width = 0, height = 100 }).ok,
                 'create_rect: zero width')
end

local function test_create_oval_happy()
    reset()
    local r = verbs.drawing_create_oval({
        north = 0, east = 0, r1 = 200, r2 = 100, angle_deg = 30 })
    assert_true(r.ok, 'create_oval: ok')
    assert_eq(r.r1, 200, 'create_oval: r1')
    assert_eq(r.r2, 100, 'create_oval: r2')
end

local function test_create_oval_arg_validation()
    reset()
    assert_false(verbs.drawing_create_oval({ north = 0, east = 0, r1 = 100 }).ok,
                 'create_oval: missing r2')
    assert_false(verbs.drawing_create_oval({ north = 0, east = 0, r1 = 0, r2 = 100 }).ok,
                 'create_oval: zero r1')
end

local function test_create_arrow_happy()
    reset()
    local r = verbs.drawing_create_arrow({
        north = 0, east = 0, length = 500, angle_deg = 90 })
    assert_true(r.ok, 'create_arrow: ok')
    assert_eq(r.mode, 'arrow', 'create_arrow: mode')
    assert_eq(r.length, 500, 'create_arrow: length')
end

local function test_create_arrow_arg_validation()
    reset()
    assert_false(verbs.drawing_create_arrow({ north = 0, east = 0 }).ok,
                 'create_arrow: missing length')
    assert_false(verbs.drawing_create_arrow({ north = 0, east = 0, length = -10 }).ok,
                 'create_arrow: negative length')
end

-- ============================================================
-- drawing_create_line / chevron / polygon
-- ============================================================

local function test_create_line_happy()
    reset()
    local r = verbs.drawing_create_line({
        vertices = {
            { north = 0,    east = 0 },
            { north = 1000, east = 1000 },
            { north = 2000, east = 2000 },
        },
    })
    assert_true(r.ok, 'create_line: ok')
    assert_eq(r.type, 'Line', 'create_line: type')
    assert_eq(r.vertex_count, 3, 'create_line: 3 vertices')
    assert_eq(r.closed, false, 'create_line: default not closed')
    assert_eq(r.mode, 'segments', 'create_line: default mode')
    assert_eq(r.north, 1000, 'create_line: center north = avg')
end

local function test_create_line_closed()
    reset()
    local r = verbs.drawing_create_line({
        vertices = {
            { north = 0,    east = 0 },
            { north = 1000, east = 0 },
            { north = 0,    east = 1000 },
        },
        closed = true,
    })
    assert_true(r.ok, 'create_line closed: ok')
    assert_eq(r.closed, true, 'create_line closed: applied')
end

local function test_create_line_arg_validation()
    reset()
    assert_false(verbs.drawing_create_line({}).ok, 'create_line: missing vertices')
    assert_false(verbs.drawing_create_line({
        vertices = { { north = 0, east = 0 } } }).ok,
        'create_line: only 1 vertex')
    assert_false(verbs.drawing_create_line({
        vertices = { { north = 0 }, { north = 1, east = 1 } } }).ok,
        'create_line: vertex missing east')
end

local function test_create_chevron_happy()
    reset()
    local r = verbs.drawing_create_chevron({
        north = 1000, east = 2000, bearing = 0, size = 500 })
    assert_true(r.ok, 'create_chevron: ok')
    assert_eq(r.tip.north, 1000, 'create_chevron: tip north')
    assert_eq(r.tip.east, 2000, 'create_chevron: tip east')
    assert_eq(r.size, 500, 'create_chevron: size')
    assert_eq(r.arm_angle, 100, 'create_chevron: default arm_angle')
end

local function test_create_chevron_custom_arm_angle()
    reset()
    local r = verbs.drawing_create_chevron({
        north = 0, east = 0, bearing = 90, size = 100, arm_angle = 150 })
    assert_true(r.ok, 'create_chevron custom: ok')
    assert_eq(r.arm_angle, 150, 'create_chevron: arm_angle override')
end

local function test_create_chevron_arg_validation()
    reset()
    assert_false(verbs.drawing_create_chevron({ north = 0, east = 0 }).ok,
                 'create_chevron: missing bearing/size')
    assert_false(verbs.drawing_create_chevron({
        north = 0, east = 0, bearing = 0, size = 100, arm_angle = 200 }).ok,
        'create_chevron: arm_angle > 180')
    assert_false(verbs.drawing_create_chevron({
        north = 0, east = 0, bearing = 0, size = 100, arm_angle = 0 }).ok,
        'create_chevron: arm_angle <= 0')
end

local function test_create_polygon_happy()
    reset()
    local r = verbs.drawing_create_polygon({
        vertices = {
            { north = 0,    east = 0 },
            { north = 1000, east = 0 },
            { north = 1000, east = 1000 },
        },
    })
    assert_true(r.ok, 'create_polygon: ok')
    assert_eq(r.type, 'Polygon', 'create_polygon: type')
    assert_eq(r.mode, 'free', 'create_polygon: mode = free')
    -- Defensive close appends a duplicate of vertex 1 → vertex_count=4
    assert_eq(r.vertex_count, 4, 'create_polygon: vertex_count includes close')
end

local function test_create_polygon_already_closed_not_duplicated()
    reset()
    local r = verbs.drawing_create_polygon({
        vertices = {
            { north = 0, east = 0 },
            { north = 1, east = 0 },
            { north = 0, east = 1 },
            { north = 0, east = 0 },  -- already closes
        },
    })
    assert_true(r.ok, 'create_polygon closed: ok')
    assert_eq(r.vertex_count, 4, 'create_polygon: no extra close vertex appended')
end

-- ============================================================
-- drawing_create_textbox / icon
-- ============================================================

local function test_create_textbox_happy()
    reset()
    local r = verbs.drawing_create_textbox({
        north = 0, east = 0, text = 'Hello', font_size = 18 })
    assert_true(r.ok, 'create_textbox: ok')
    assert_eq(r.type, 'TextBox', 'create_textbox: type')
    assert_eq(r.text, 'Hello', 'create_textbox: text')
    assert_eq(panel.getObjects()[r.name].fontSize, 18, 'create_textbox: fontSize stored')
end

local function test_create_textbox_arg_validation()
    reset()
    assert_false(verbs.drawing_create_textbox({ north = 0, east = 0 }).ok,
                 'create_textbox: missing text')
    assert_false(verbs.drawing_create_textbox({ north = 0, east = 0, text = '' }).ok,
                 'create_textbox: empty text')
end

local function test_create_icon_happy()
    reset()
    local r = verbs.drawing_create_icon({
        north = 0, east = 0, file = 'aaa_air_neutral.png' })
    assert_true(r.ok, 'create_icon: ok')
    assert_eq(r.type, 'Icon', 'create_icon: type')
    assert_eq(r.file, 'aaa_air_neutral.png', 'create_icon: file')
end

local function test_create_icon_arg_validation()
    reset()
    assert_false(verbs.drawing_create_icon({ north = 0, east = 0 }).ok,
                 'create_icon: missing file')
end

-- ============================================================
-- drawing_list
-- ============================================================

local function test_list_all()
    reset()
    verbs.drawing_create_circle({ north = 0, east = 0, radius = 100 })
    verbs.drawing_create_rect({ north = 0, east = 0, width = 10, height = 10 })
    local r = verbs.drawing_list({})
    assert_true(r.ok, 'list: ok')
    assert_eq(r.count, 2, 'list: count = 2')
end

local function test_list_filter_layer()
    reset()
    verbs.drawing_create_circle({ north = 0, east = 0, radius = 100, layer = 'Red' })
    verbs.drawing_create_circle({ north = 0, east = 0, radius = 100, layer = 'Blue' })
    local r = verbs.drawing_list({ layer = 'Red' })
    assert_eq(r.count, 1, 'list layer=Red: count = 1')
end

local function test_list_filter_type()
    reset()
    verbs.drawing_create_circle({ north = 0, east = 0, radius = 100 })
    verbs.drawing_create_textbox({ north = 0, east = 0, text = 'hi' })
    local r = verbs.drawing_list({ type = 'TextBox' })
    assert_eq(r.count, 1, 'list type=TextBox: count = 1')
end

local function test_list_filter_mode()
    reset()
    verbs.drawing_create_circle({ north = 0, east = 0, radius = 100 })
    verbs.drawing_create_rect({ north = 0, east = 0, width = 10, height = 10 })
    local r = verbs.drawing_list({ mode = 'circle' })
    assert_eq(r.count, 1, 'list mode=circle: count = 1')
end

local function test_list_filter_name_substring()
    reset()
    verbs.drawing_create_circle({ name = 'CAS-radius', north = 0, east = 0, radius = 100 })
    verbs.drawing_create_circle({ name = 'OBJ-radius', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_list({ name = 'cas' })
    assert_eq(r.count, 1, 'list name=cas (case insensitive): count = 1')
end

-- Regression for GH#73, request 3: `--name "ROUTE_"` (uppercase, trailing
-- underscore) must match every ROUTE_NNN drawing as a case-insensitive
-- substring and exclude others. The reporter saw count:0; we couldn't
-- reproduce — this locks the behavior so it can't regress. The underscore is
-- not a Lua pattern magic char and the match uses plain find, so it's literal.
local function test_list_filter_name_route_prefix()
    reset()
    verbs.drawing_create_circle({ name = 'ROUTE_001', north = 0, east = 0, radius = 100 })
    verbs.drawing_create_circle({ name = 'ROUTE_002', north = 0, east = 0, radius = 100 })
    verbs.drawing_create_circle({ name = 'WP_001',    north = 0, east = 0, radius = 100 })
    assert_eq(verbs.drawing_list({ name = 'ROUTE_' }).count, 2, 'list name=ROUTE_ : count = 2')
    assert_eq(verbs.drawing_list({ name = 'route_' }).count, 2, 'list name=route_ (lowercase): count = 2')
    assert_eq(verbs.drawing_list({ name_prefix = 'ROUTE_' }).count, 2, 'list name_prefix=ROUTE_ : count = 2')
end

local function test_list_summary_fields()
    reset()
    verbs.drawing_create_circle({ name = 'S1', north = 100, east = 200, radius = 500,
        color = '0xaabbccdd', layer = 'Blue' })
    local r = verbs.drawing_list({ name = 'S1' })
    local s = r.drawings[1]
    assert_eq(s.name, 'S1', 'summary: name')
    assert_eq(s.type, 'Polygon', 'summary: type')
    assert_eq(s.mode, 'circle', 'summary: mode')
    assert_eq(s.layer, 'Blue', 'summary: layer')
    assert_eq(s.north, 100, 'summary: north')
    assert_eq(s.east, 200, 'summary: east')
    assert_eq(s.color, '0xaabbccdd', 'summary: color')
end

-- ============================================================
-- drawing_get
-- ============================================================

local function test_get_happy()
    reset()
    verbs.drawing_create_circle({
        name = 'G1', north = 100, east = 200, radius = 500 })
    local r = verbs.drawing_get({ name = 'G1' })
    assert_true(r.ok, 'get: ok')
    assert_eq(r.drawing.name, 'G1', 'get: name')
    assert_eq(r.drawing.north, 100, 'get: top-level north')
    assert_eq(r.drawing.east, 200, 'get: top-level east')
    assert_eq(r.drawing.radius, 500, 'get: radius')
end

local function test_get_line_returns_absolute_points()
    reset()
    verbs.drawing_create_line({
        name = 'G2',
        vertices = {
            { north = 0,    east = 0 },
            { north = 1000, east = 1000 },
        },
    })
    local r = verbs.drawing_get({ name = 'G2' })
    assert_true(r.ok, 'get line: ok')
    assert_eq(#r.drawing.points_absolute, 2, 'get line: 2 abs points')
    assert_eq(r.drawing.points_absolute[1].north, 0, 'get line: abs vert 1 north')
    assert_eq(r.drawing.points_absolute[2].east, 1000, 'get line: abs vert 2 east')
end

local function test_get_not_found()
    reset()
    local r = verbs.drawing_get({ name = 'ghost' })
    assert_false(r.ok, 'get not found: error')
    assert_contains(r.error, 'not found', 'get: error msg')
end

local function test_get_arg_validation()
    reset()
    assert_false(verbs.drawing_get({}).ok, 'get: missing name')
    assert_false(verbs.drawing_get({ name = '' }).ok, 'get: empty name')
end

-- ============================================================
-- drawing_remove
-- ============================================================

local function test_remove_by_name()
    reset()
    verbs.drawing_create_circle({ name = 'R1', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_remove({ name = 'R1' })
    assert_true(r.ok, 'remove by name: ok')
    assert_eq(r.count, 1, 'remove: count = 1')
    assert_eq(panel.getObjects()['R1'], nil, 'remove: drawing gone')
end

local function test_remove_by_prefix()
    reset()
    verbs.drawing_create_circle({ name = 'CAS-1', north = 0, east = 0, radius = 100 })
    verbs.drawing_create_circle({ name = 'CAS-2', north = 0, east = 0, radius = 100 })
    verbs.drawing_create_circle({ name = 'OBJ-1', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_remove({ name_prefix = 'CAS' })
    assert_true(r.ok, 'remove by prefix: ok')
    assert_eq(r.count, 2, 'remove prefix: count = 2')
    assert_true(panel.getObjects()['OBJ-1'] ~= nil, 'remove prefix: OBJ-1 spared')
end

local function test_remove_prefix_case_insensitive()
    reset()
    verbs.drawing_create_circle({ name = 'CAS-1', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_remove({ name_prefix = 'cas' })
    assert_eq(r.count, 1, 'remove prefix lowercase: matches CAS')
end

local function test_remove_layer_wipe()
    reset()
    verbs.drawing_create_circle({ name = 'L-1', north = 0, east = 0, radius = 100, layer = 'Red' })
    verbs.drawing_create_circle({ name = 'L-2', north = 0, east = 0, radius = 100, layer = 'Red' })
    verbs.drawing_create_circle({ name = 'L-3', north = 0, east = 0, radius = 100, layer = 'Blue' })
    local r = verbs.drawing_remove({ layer = 'Red', all = true })
    assert_true(r.ok, 'remove layer wipe: ok')
    assert_eq(r.count, 2, 'remove layer wipe: count = 2')
end

local function test_remove_layer_without_all_refused()
    reset()
    verbs.drawing_create_circle({ name = 'L-X', north = 0, east = 0, radius = 100, layer = 'Red' })
    local r = verbs.drawing_remove({ layer = 'Red' })
    assert_false(r.ok, 'remove layer-only without all: refused')
    assert_contains(r.error, 'all=true', 'remove: needs all=true')
end

local function test_remove_no_matches()
    reset()
    verbs.drawing_create_circle({ name = 'R1', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_remove({ name_prefix = 'ghost' })
    assert_false(r.ok, 'remove no matches: refused')
    assert_eq(r.count, 0, 'remove no matches: count = 0')
end

local function test_remove_arg_validation()
    reset()
    assert_false(verbs.drawing_remove({}).ok, 'remove: no selector')
    assert_false(verbs.drawing_remove({ name = 'x', name_prefix = 'y' }).ok,
                 'remove: name + prefix mutually exclusive')
    assert_false(verbs.drawing_remove({ name = 'x', layer = 'Red' }).ok,
                 'remove: name + layer mutually exclusive')
end

-- ============================================================
-- drawing_set_color
-- ============================================================

local function test_set_color_happy()
    reset()
    verbs.drawing_create_circle({ name = 'SC1', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_set_color({ name = 'SC1', color = '0xabcdef12' })
    assert_true(r.ok, 'set_color: ok')
    assert_eq(r.color, '0xabcdef12', 'set_color: applied')
    assert_eq(panel.getObjects()['SC1'].colorString, '0xabcdef12', 'set_color: persisted')
end

local function test_set_color_not_found()
    reset()
    local r = verbs.drawing_set_color({ name = 'ghost', color = '0xff0000ff' })
    assert_false(r.ok, 'set_color not found: error')
end

local function test_set_color_arg_validation()
    reset()
    verbs.drawing_create_circle({ name = 'SC2', north = 0, east = 0, radius = 100 })
    assert_false(verbs.drawing_set_color({ name = 'SC2' }).ok, 'set_color: missing color')
    assert_false(verbs.drawing_set_color({ color = '0x000000ff' }).ok, 'set_color: missing name')
end

-- ============================================================
-- drawing_set_fill_color
-- ============================================================

local function test_set_fill_color_polygon_ok()
    reset()
    verbs.drawing_create_circle({ name = 'SF1', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_set_fill_color({ name = 'SF1', color = '0x11223344' })
    assert_true(r.ok, 'set_fill_color polygon: ok')
    assert_eq(panel.getObjects()['SF1'].fillColorString, '0x11223344',
              'set_fill_color: stored')
end

local function test_set_fill_color_line_refused()
    reset()
    verbs.drawing_create_line({ name = 'SF2',
        vertices = { { north = 0, east = 0 }, { north = 1, east = 1 } } })
    local r = verbs.drawing_set_fill_color({ name = 'SF2', color = '0x11223344' })
    assert_false(r.ok, 'set_fill_color Line: refused')
    assert_contains(r.error, 'no fill', 'set_fill_color: error msg')
end

local function test_set_fill_color_icon_refused()
    reset()
    verbs.drawing_create_icon({ name = 'SF3', north = 0, east = 0, file = 'x.png' })
    local r = verbs.drawing_set_fill_color({ name = 'SF3', color = '0x11223344' })
    assert_false(r.ok, 'set_fill_color Icon: refused')
end

-- ============================================================
-- drawing_set_pos / set_name / set_text / set_thickness / set_angle
-- ============================================================

local function test_set_pos_happy()
    reset()
    verbs.drawing_create_circle({ name = 'P1', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_set_pos({ name = 'P1', north = 9000, east = 8000 })
    assert_true(r.ok, 'set_pos: ok')
    assert_eq(r.north, 9000, 'set_pos: north')
    assert_eq(panel.getObjects()['P1'].mapData.x, 9000, 'set_pos: persisted x')
end

local function test_set_pos_arg_validation()
    reset()
    verbs.drawing_create_circle({ name = 'P2', north = 0, east = 0, radius = 100 })
    assert_false(verbs.drawing_set_pos({ name = 'P2' }).ok, 'set_pos: missing coords')
end

local function test_set_name_happy()
    reset()
    verbs.drawing_create_circle({ name = 'N1', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_set_name({ name = 'N1', new_name = 'N1-renamed' })
    assert_true(r.ok, 'set_name: ok')
    assert_eq(r.name, 'N1-renamed', 'set_name: applied')
    assert_true(panel.getObjects()['N1-renamed'] ~= nil, 'set_name: stored under new name')
end

local function test_set_name_collision_refused()
    reset()
    verbs.drawing_create_circle({ name = 'N2a', north = 0, east = 0, radius = 100 })
    verbs.drawing_create_circle({ name = 'N2b', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_set_name({ name = 'N2a', new_name = 'N2b' })
    assert_false(r.ok, 'set_name collision: refused')
    assert_contains(r.error, 'in use', 'set_name collision: error msg')
end

local function test_set_name_unchanged()
    reset()
    verbs.drawing_create_circle({ name = 'N3', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_set_name({ name = 'N3', new_name = 'N3' })
    assert_true(r.ok, 'set_name same: ok')
    assert_eq(r.unchanged, true, 'set_name same: unchanged flagged')
end

local function test_set_text_happy()
    reset()
    verbs.drawing_create_textbox({ name = 'T1', north = 0, east = 0, text = 'Old' })
    local r = verbs.drawing_set_text({ name = 'T1', text = 'New text' })
    assert_true(r.ok, 'set_text: ok')
    assert_eq(panel.getObjects()['T1'].text, 'New text', 'set_text: persisted')
end

local function test_set_text_non_textbox_refused()
    reset()
    verbs.drawing_create_circle({ name = 'T2', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_set_text({ name = 'T2', text = 'Hi' })
    assert_false(r.ok, 'set_text on Polygon: refused')
    assert_contains(r.error, 'not TextBox', 'set_text: error msg')
end

local function test_set_thickness_polygon_ok()
    reset()
    verbs.drawing_create_circle({ name = 'TH1', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_set_thickness({ name = 'TH1', thickness = 8 })
    assert_true(r.ok, 'set_thickness polygon: ok')
    assert_eq(panel.getObjects()['TH1'].thickness, 8, 'set_thickness: persisted')
end

local function test_set_thickness_line_ok()
    reset()
    verbs.drawing_create_line({ name = 'TH2',
        vertices = { { north = 0, east = 0 }, { north = 1, east = 1 } } })
    local r = verbs.drawing_set_thickness({ name = 'TH2', thickness = 4 })
    assert_true(r.ok, 'set_thickness line: ok')
end

local function test_set_thickness_textbox_refused()
    reset()
    verbs.drawing_create_textbox({ name = 'TH3', north = 0, east = 0, text = 'x' })
    local r = verbs.drawing_set_thickness({ name = 'TH3', thickness = 4 })
    assert_false(r.ok, 'set_thickness TextBox: refused')
    assert_contains(r.error, 'border-thickness', 'set_thickness TextBox: error msg')
end

local function test_set_thickness_icon_refused()
    reset()
    verbs.drawing_create_icon({ name = 'TH4', north = 0, east = 0, file = 'x.png' })
    local r = verbs.drawing_set_thickness({ name = 'TH4', thickness = 4 })
    assert_false(r.ok, 'set_thickness Icon: refused')
    assert_contains(r.error, 'scale', 'set_thickness Icon: error msg')
end

local function test_set_thickness_arg_validation()
    reset()
    verbs.drawing_create_circle({ name = 'TH5', north = 0, east = 0, radius = 100 })
    assert_false(verbs.drawing_set_thickness({ name = 'TH5' }).ok,
                 'set_thickness: missing')
    assert_false(verbs.drawing_set_thickness({ name = 'TH5', thickness = 0 }).ok,
                 'set_thickness: zero rejected')
end

-- ============================================================
-- drawing_set_angle (type-gated)
-- ============================================================

local function test_set_angle_textbox_ok()
    reset()
    verbs.drawing_create_textbox({ name = 'A1', north = 0, east = 0, text = 'x' })
    local r = verbs.drawing_set_angle({ name = 'A1', angle_deg = 45 })
    assert_true(r.ok, 'set_angle TextBox: ok')
    assert_eq(panel.getObjects()['A1'].angle, 45,
              'set_angle: stored verbatim (degrees, not radians)')
end

local function test_set_angle_icon_ok()
    reset()
    verbs.drawing_create_icon({ name = 'A2', north = 0, east = 0, file = 'x.png' })
    local r = verbs.drawing_set_angle({ name = 'A2', angle_deg = 90 })
    assert_true(r.ok, 'set_angle Icon: ok')
end

local function test_set_angle_rect_ok()
    reset()
    verbs.drawing_create_rect({ name = 'A3', north = 0, east = 0, width = 100, height = 100 })
    local r = verbs.drawing_set_angle({ name = 'A3', angle_deg = 15 })
    assert_true(r.ok, 'set_angle rect: ok')
end

local function test_set_angle_oval_ok()
    reset()
    verbs.drawing_create_oval({ name = 'A4', north = 0, east = 0, r1 = 100, r2 = 50 })
    local r = verbs.drawing_set_angle({ name = 'A4', angle_deg = 30 })
    assert_true(r.ok, 'set_angle oval: ok')
end

local function test_set_angle_arrow_ok()
    reset()
    verbs.drawing_create_arrow({ name = 'A5', north = 0, east = 0, length = 100 })
    local r = verbs.drawing_set_angle({ name = 'A5', angle_deg = 45 })
    assert_true(r.ok, 'set_angle arrow: ok')
end

local function test_set_angle_circle_refused()
    reset()
    verbs.drawing_create_circle({ name = 'A6', north = 0, east = 0, radius = 100 })
    local r = verbs.drawing_set_angle({ name = 'A6', angle_deg = 30 })
    assert_false(r.ok, 'set_angle circle: refused')
    assert_contains(r.error, 'no rotation', 'set_angle: error msg')
end

local function test_set_angle_line_refused()
    reset()
    verbs.drawing_create_line({ name = 'A7',
        vertices = { { north = 0, east = 0 }, { north = 1, east = 1 } } })
    local r = verbs.drawing_set_angle({ name = 'A7', angle_deg = 30 })
    assert_false(r.ok, 'set_angle Line: refused')
end

local function test_set_angle_free_polygon_refused()
    reset()
    verbs.drawing_create_polygon({
        name = 'A8',
        vertices = {
            { north = 0, east = 0 }, { north = 1, east = 0 }, { north = 0, east = 1 } } })
    local r = verbs.drawing_set_angle({ name = 'A8', angle_deg = 30 })
    assert_false(r.ok, 'set_angle free polygon: refused')
end

local function test_set_angle_arg_validation()
    reset()
    verbs.drawing_create_textbox({ name = 'A9', north = 0, east = 0, text = 'x' })
    assert_false(verbs.drawing_set_angle({ name = 'A9' }).ok, 'set_angle: missing')
end

-- ============================================================
-- mission.drawings cache resync (regression)
-- ============================================================
-- The ME serializer reads the cached mission.drawings, not the live draw
-- panel. A create/set verb that didn't resync that cache left the drawing
-- rendered but dropped on the next `me file save` until the Draw panel was
-- touched. These lock in the resync done by commit_to_mission.

local function test_create_refreshes_mission_cache()
    reset()
    -- Fresh mission: cache exists but is empty (mirrors a just-loaded .miz).
    assert_false(cache_has_drawing(mock.mission.drawings, 'CacheCircle'),
                 'cache: drawing absent before create')
    verbs.drawing_create_circle({ name = 'CacheCircle', north = 0, east = 0, radius = 100 })
    assert_true(cache_has_drawing(mock.mission.drawings, 'CacheCircle'),
                'cache: created drawing committed to mission.drawings')
end

local function test_set_refreshes_mission_cache()
    reset()
    verbs.drawing_create_circle({ name = 'CacheC2', north = 0, east = 0, radius = 100 })
    -- A mutate verb must also resync (it goes through loadFromMission too).
    mock.mission.drawings = nil   -- prove the set verb re-populates it
    verbs.drawing_set_color({ name = 'CacheC2', color = '0x11223344' })
    assert_true(cache_has_drawing(mock.mission.drawings, 'CacheC2'),
                'cache: set-color committed to mission.drawings')
end

-- ============================================================
-- Test runner
-- ============================================================

local tests = {
    test_create_refreshes_mission_cache,
    test_set_refreshes_mission_cache,
    test_create_circle_happy,
    test_create_circle_auto_name_increments,
    test_create_circle_custom_layer,
    test_create_circle_unknown_layer,
    test_create_circle_arg_validation,
    test_create_rect_happy,
    test_create_rect_arg_validation,
    test_create_oval_happy,
    test_create_oval_arg_validation,
    test_create_arrow_happy,
    test_create_arrow_arg_validation,
    test_create_line_happy,
    test_create_line_closed,
    test_create_line_arg_validation,
    test_create_chevron_happy,
    test_create_chevron_custom_arm_angle,
    test_create_chevron_arg_validation,
    test_create_polygon_happy,
    test_create_polygon_already_closed_not_duplicated,
    test_create_textbox_happy,
    test_create_textbox_arg_validation,
    test_create_icon_happy,
    test_create_icon_arg_validation,
    test_list_all,
    test_list_filter_layer,
    test_list_filter_type,
    test_list_filter_mode,
    test_list_filter_name_substring,
    test_list_filter_name_route_prefix,
    test_list_summary_fields,
    test_get_happy,
    test_get_line_returns_absolute_points,
    test_get_not_found,
    test_get_arg_validation,
    test_remove_by_name,
    test_remove_by_prefix,
    test_remove_prefix_case_insensitive,
    test_remove_layer_wipe,
    test_remove_layer_without_all_refused,
    test_remove_no_matches,
    test_remove_arg_validation,
    test_set_color_happy,
    test_set_color_not_found,
    test_set_color_arg_validation,
    test_set_fill_color_polygon_ok,
    test_set_fill_color_line_refused,
    test_set_fill_color_icon_refused,
    test_set_pos_happy,
    test_set_pos_arg_validation,
    test_set_name_happy,
    test_set_name_collision_refused,
    test_set_name_unchanged,
    test_set_text_happy,
    test_set_text_non_textbox_refused,
    test_set_thickness_polygon_ok,
    test_set_thickness_line_ok,
    test_set_thickness_textbox_refused,
    test_set_thickness_icon_refused,
    test_set_thickness_arg_validation,
    test_set_angle_textbox_ok,
    test_set_angle_icon_ok,
    test_set_angle_rect_ok,
    test_set_angle_oval_ok,
    test_set_angle_arrow_ok,
    test_set_angle_circle_refused,
    test_set_angle_line_refused,
    test_set_angle_free_polygon_refused,
    test_set_angle_arg_validation,
}

for _, t in ipairs(tests) do t() end

print(string.format('test_verbs_drawing: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
