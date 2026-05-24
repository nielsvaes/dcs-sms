-- test_verbs_zone.lua — Lua-side unit tests for verbs/zone_verbs.lua.

local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path

local mock = require('mock_me_mission')
package.preload['me_mission']    = function() return mock end
package.preload['me_map_window'] = function() return mock end

-- ============================================================
-- Mission.TriggerZoneData stub
-- ============================================================
-- Mirrors the real TZD API enough that zone verbs can mutate / read state.
-- Zones are stored in a closure-scoped table indexed by zoneId. The
-- ENTRY shape is: { name, x, y, radius, type, color, hidden, properties,
-- points, linkUnitId }.
local zones = {}
local next_zid = 1

local TZD = {}

local function _unique_name(name)
    local n = name
    local i = 2
    local exists = function(nn)
        for _, z in pairs(zones) do if z.name == nn then return true end end
        return false
    end
    while exists(n) do n = name .. '-' .. i; i = i + 1 end
    return n
end

function TZD.addTriggerZone(name, x, y, radius, properties, color, ztype, points)
    local final = _unique_name(name)
    local zid = next_zid
    next_zid = next_zid + 1
    zones[zid] = {
        name = final, x = x, y = y, radius = radius,
        type = ztype, color = color or { 1, 1, 1, 0.15 },
        hidden = false,
        properties = properties or {},
        points = points or {},
        linkUnitId = nil,
    }
    return zid
end

function TZD.getTriggerZoneIds()
    local out = {}
    for zid in pairs(zones) do table.insert(out, zid) end
    table.sort(out)
    return out
end

function TZD.getTriggerZoneName(zid)     return zones[zid] and zones[zid].name end
function TZD.getTriggerZoneType(zid)     return zones[zid] and zones[zid].type end
function TZD.getTriggerZoneRadius(zid)   return zones[zid] and zones[zid].radius end
function TZD.getTriggerZoneHidden(zid)   return zones[zid] and zones[zid].hidden end
function TZD.getTriggerZonePoints(zid)   return zones[zid] and zones[zid].points end
function TZD.getTriggerZoneProperties(zid) return zones[zid] and zones[zid].properties end
function TZD.getLinkUnitId(zid)          return zones[zid] and zones[zid].linkUnitId end

function TZD.getTriggerZonePosition(zid)
    local z = zones[zid]; if not z then return 0, 0 end
    return z.x, z.y
end

function TZD.getTriggerZoneColor(zid)
    local z = zones[zid]; if not z then return 1, 1, 1, 1 end
    return z.color[1], z.color[2], z.color[3], z.color[4] or 1
end

function TZD.getTriggerZone(zid)
    return zones[zid] and { getHeading = function() return 0 end }
end

function TZD.setTriggerZoneColor(zid, r, g, b, a)
    if zones[zid] then zones[zid].color = { r, g, b, a } end
end
function TZD.setTriggerZoneName(zid, new_name)
    if zones[zid] then zones[zid].name = _unique_name(new_name) end
end
function TZD.setTriggerZonePosition(zid, x, y)
    if zones[zid] then zones[zid].x = x; zones[zid].y = y end
end
function TZD.setTriggerZoneRadius(zid, radius)
    if zones[zid] then zones[zid].radius = radius end
end
function TZD.setTriggerZoneHidden(zid, hidden)
    if zones[zid] then zones[zid].hidden = hidden end
end
function TZD.setTriggerZonePoints(zid, points)
    if zones[zid] then zones[zid].points = points end
end
function TZD.removeTriggerZone(zid) zones[zid] = nil end
function TZD.linkToUnit(zid, uid) if zones[zid] then zones[zid].linkUnitId = uid end end
function TZD.unlinkFromUnit(zid)  if zones[zid] then zones[zid].linkUnitId = nil end end

-- Reset between tests
function TZD._reset()
    zones = {}
    next_zid = 1
end

package.preload['Mission.TriggerZoneData'] = function() return TZD end

-- Mission.linkTriggerZone / unlinkTriggerZone — high-level wrappers the verb
-- uses. They delegate to TZD plus poke unit.linkChildrenTZone (which the
-- verb's caller doesn't inspect, so we just track linkUnitId here).
function mock.linkTriggerZone(zid, uid)
    TZD.linkToUnit(zid, uid)
end
function mock.unlinkTriggerZone(zid)
    TZD.unlinkFromUnit(zid)
end

-- Stubs for sibling modules pulled in by other verb files via the aggregator.
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

local function reset()
    mock.new_mission()
    TZD._reset()
end

-- ============================================================
-- zone_create_circle
-- ============================================================

local function test_create_circle_happy()
    reset()
    local r = verbs.zone_create_circle({
        name = 'Z1', north = 1000, east = 2000, radius = 500 })
    assert_true(r.ok, 'create_circle: ok')
    assert_eq(r.name, 'Z1', 'create_circle: name')
    assert_eq(r.type, 'circle', 'create_circle: type')
    assert_true(type(r.zoneId) == 'number', 'create_circle: zoneId number')
    -- Verify stored shape
    local x, y = TZD.getTriggerZonePosition(r.zoneId)
    assert_eq(x, 1000, 'create_circle: x stored')
    assert_eq(y, 2000, 'create_circle: y stored')
    assert_eq(TZD.getTriggerZoneRadius(r.zoneId), 500, 'create_circle: radius stored')
    assert_eq(TZD.getTriggerZoneType(r.zoneId), 0, 'create_circle: type=0 (circle)')
end

local function test_create_circle_default_color()
    reset()
    local r = verbs.zone_create_circle({
        name = 'Z2', north = 0, east = 0, radius = 100 })
    local cr, cg, cb, ca = TZD.getTriggerZoneColor(r.zoneId)
    assert_eq(cr, 1, 'default color r=1')
    assert_eq(cg, 1, 'default color g=1')
    assert_eq(cb, 1, 'default color b=1')
    assert_eq(ca, 0.15, 'default color a=0.15')
end

local function test_create_circle_custom_color()
    reset()
    local r = verbs.zone_create_circle({
        name = 'Z3', north = 0, east = 0, radius = 100,
        color = { 0.5, 0.2, 0.1, 0.8 } })
    local cr, cg, cb, ca = TZD.getTriggerZoneColor(r.zoneId)
    assert_eq(cr, 0.5, 'custom color r')
    assert_eq(ca, 0.8, 'custom color a')
end

local function test_create_circle_hidden()
    reset()
    local r = verbs.zone_create_circle({
        name = 'Z4', north = 0, east = 0, radius = 100, hidden = true })
    assert_true(TZD.getTriggerZoneHidden(r.zoneId), 'create_circle hidden=true: applied')
end

local function test_create_circle_name_uniquification()
    reset()
    verbs.zone_create_circle({ name = 'Z5', north = 0, east = 0, radius = 100 })
    local r2 = verbs.zone_create_circle({ name = 'Z5', north = 0, east = 0, radius = 100 })
    assert_true(r2.ok, 'create_circle dup: still ok')
    assert_eq(r2.name, 'Z5-2', 'create_circle dup: name uniquified')
end

local function test_create_circle_arg_validation()
    reset()
    assert_false(verbs.zone_create_circle(nil).ok, 'create_circle: nil')
    assert_false(verbs.zone_create_circle({}).ok, 'create_circle: empty')
    assert_false(verbs.zone_create_circle({ north = 0, east = 0, radius = 100 }).ok,
                 'create_circle: missing name')
    assert_false(verbs.zone_create_circle({ name = 'Z', east = 0, radius = 100 }).ok,
                 'create_circle: missing north')
    assert_false(verbs.zone_create_circle({ name = 'Z', north = 0, radius = 100 }).ok,
                 'create_circle: missing east')
    assert_false(verbs.zone_create_circle({ name = 'Z', north = 0, east = 0 }).ok,
                 'create_circle: missing radius')
    assert_false(verbs.zone_create_circle({ name = 'Z', north = 0, east = 0, radius = 0 }).ok,
                 'create_circle: radius=0 rejected')
    assert_false(verbs.zone_create_circle({ name = 'Z', north = 0, east = 0, radius = -1 }).ok,
                 'create_circle: negative radius rejected')
    assert_false(verbs.zone_create_circle({ name = '', north = 0, east = 0, radius = 1 }).ok,
                 'create_circle: empty name rejected')
end

-- ============================================================
-- zone_create_quad
-- ============================================================

local function test_create_quad_happy()
    reset()
    local r = verbs.zone_create_quad({
        name = 'Q1',
        vertices = {
            { north = 0,    east = 0 },
            { north = 1000, east = 0 },
            { north = 1000, east = 1000 },
            { north = 0,    east = 1000 },
        },
    })
    assert_true(r.ok, 'create_quad: ok')
    assert_eq(r.type, 'quad', 'create_quad: type')
    assert_eq(r.vertex_count, 4, 'create_quad: vertex_count')
    assert_eq(r.center.north, 500, 'create_quad: center.north = avg')
    assert_eq(r.center.east, 500, 'create_quad: center.east = avg')
    assert_eq(TZD.getTriggerZoneType(r.zoneId), 2, 'create_quad: stored type=2')
end

local function test_create_quad_triangle()
    reset()
    local r = verbs.zone_create_quad({
        name = 'Q2',
        vertices = {
            { north = 0,    east = 0 },
            { north = 1000, east = 0 },
            { north = 500,  east = 1000 },
        },
    })
    assert_true(r.ok, 'create_quad triangle: ok (3 verts)')
    assert_eq(r.vertex_count, 3, 'create_quad: 3 vertices')
end

local function test_create_quad_radius_default_from_bbox()
    reset()
    local r = verbs.zone_create_quad({
        name = 'Q3',
        vertices = {
            { north = 0,    east = 0 },
            { north = 1000, east = 0 },
            { north = 1000, east = 1000 },
            { north = 0,    east = 1000 },
        },
    })
    -- bbox diagonal = sqrt(1000^2 + 1000^2) ≈ 1414.21
    -- default radius = diagonal / 2 ≈ 707.1
    local radius = TZD.getTriggerZoneRadius(r.zoneId)
    assert_true(radius > 700 and radius < 715, 'create_quad: default radius ≈ diag/2')
end

local function test_create_quad_arg_validation()
    reset()
    assert_false(verbs.zone_create_quad(nil).ok, 'create_quad: nil')
    assert_false(verbs.zone_create_quad({ name = 'Q' }).ok, 'create_quad: missing vertices')
    assert_false(verbs.zone_create_quad({
        name = 'Q', vertices = { { north = 0, east = 0 }, { north = 1, east = 1 } } }).ok,
        'create_quad: < 3 vertices')
    assert_false(verbs.zone_create_quad({
        name = 'Q', vertices = { { north = 0 }, { north = 1, east = 1 }, { north = 2, east = 2 } } }).ok,
        'create_quad: vertex missing east')
end

-- ============================================================
-- zone_remove
-- ============================================================

local function test_remove_by_name()
    reset()
    local r1 = verbs.zone_create_circle({ name = 'R1', north = 0, east = 0, radius = 100 })
    local r2 = verbs.zone_remove({ name = 'R1' })
    assert_true(r2.ok, 'remove by name: ok')
    assert_eq(r2.id, r1.zoneId, 'remove: returns id')
    assert_eq(TZD.getTriggerZoneName(r1.zoneId), nil, 'remove: zone gone')
end

local function test_remove_by_id()
    reset()
    local r1 = verbs.zone_create_circle({ name = 'R2', north = 0, east = 0, radius = 100 })
    local r2 = verbs.zone_remove({ id = r1.zoneId })
    assert_true(r2.ok, 'remove by id: ok')
end

local function test_remove_not_found()
    reset()
    local r = verbs.zone_remove({ name = 'ghost' })
    assert_false(r.ok, 'remove not found: error')
    assert_contains(r.error, 'not found', 'remove: error msg')
end

local function test_remove_arg_validation()
    reset()
    assert_false(verbs.zone_remove({}).ok, 'remove: empty')
    assert_false(verbs.zone_remove({ name = 'x', id = 1 }).ok, 'remove: both')
end

-- ============================================================
-- zone_set_color / set_name / set_pos / set_radius / set_hidden
-- ============================================================

local function test_set_color_happy()
    reset()
    local r1 = verbs.zone_create_circle({ name = 'C1', north = 0, east = 0, radius = 100 })
    local r2 = verbs.zone_set_color({ name = 'C1', color = { 0.1, 0.2, 0.3 } })
    assert_true(r2.ok, 'set_color: ok')
    assert_eq(r2.color[4], 0.15, 'set_color: alpha defaults to 0.15')
end

local function test_set_color_explicit_alpha()
    reset()
    verbs.zone_create_circle({ name = 'C2', north = 0, east = 0, radius = 100 })
    local r = verbs.zone_set_color({ name = 'C2', color = { 0.1, 0.2, 0.3, 0.9 } })
    assert_eq(r.color[4], 0.9, 'set_color: alpha = 0.9')
end

local function test_set_color_arg_validation()
    reset()
    verbs.zone_create_circle({ name = 'C3', north = 0, east = 0, radius = 100 })
    assert_false(verbs.zone_set_color({ name = 'C3' }).ok, 'set_color: missing color')
    assert_false(verbs.zone_set_color({ name = 'C3', color = {} }).ok,
                 'set_color: empty color')
    assert_false(verbs.zone_set_color({ name = 'C3', color = { 0.1, 0.2 } }).ok,
                 'set_color: < 3 components')
end

local function test_set_name_happy()
    reset()
    verbs.zone_create_circle({ name = 'N1', north = 0, east = 0, radius = 100 })
    local r = verbs.zone_set_name({ name = 'N1', new_name = 'N1-renamed' })
    assert_true(r.ok, 'set_name: ok')
    assert_eq(r.name, 'N1-renamed', 'set_name: applied')
    assert_eq(r.requested_name, 'N1-renamed', 'set_name: requested_name field')
end

local function test_set_name_arg_validation()
    reset()
    verbs.zone_create_circle({ name = 'N2', north = 0, east = 0, radius = 100 })
    assert_false(verbs.zone_set_name({ name = 'N2' }).ok, 'set_name: missing new_name')
    assert_false(verbs.zone_set_name({ name = 'N2', new_name = '' }).ok,
                 'set_name: empty new_name')
end

local function test_set_pos_happy()
    reset()
    verbs.zone_create_circle({ name = 'P1', north = 0, east = 0, radius = 100 })
    local r = verbs.zone_set_pos({ name = 'P1', north = 5000, east = 6000 })
    assert_true(r.ok, 'set_pos: ok')
    assert_eq(r.north, 5000, 'set_pos: returns north')
    assert_eq(r.east, 6000, 'set_pos: returns east')
end

local function test_set_pos_arg_validation()
    reset()
    verbs.zone_create_circle({ name = 'P2', north = 0, east = 0, radius = 100 })
    assert_false(verbs.zone_set_pos({ name = 'P2' }).ok, 'set_pos: missing coords')
    assert_false(verbs.zone_set_pos({ name = 'P2', north = 0 }).ok,
                 'set_pos: missing east')
end

local function test_set_radius_happy()
    reset()
    local c = verbs.zone_create_circle({ name = 'R1', north = 0, east = 0, radius = 100 })
    local r = verbs.zone_set_radius({ name = 'R1', radius = 2000 })
    assert_true(r.ok, 'set_radius: ok')
    assert_eq(TZD.getTriggerZoneRadius(c.zoneId), 2000, 'set_radius: applied')
end

local function test_set_radius_arg_validation()
    reset()
    verbs.zone_create_circle({ name = 'R2', north = 0, east = 0, radius = 100 })
    assert_false(verbs.zone_set_radius({ name = 'R2' }).ok, 'set_radius: missing')
    assert_false(verbs.zone_set_radius({ name = 'R2', radius = 0 }).ok,
                 'set_radius: zero rejected')
    assert_false(verbs.zone_set_radius({ name = 'R2', radius = -10 }).ok,
                 'set_radius: negative rejected')
end

local function test_set_hidden_happy()
    reset()
    local c = verbs.zone_create_circle({ name = 'H1', north = 0, east = 0, radius = 100 })
    local r = verbs.zone_set_hidden({ name = 'H1', hidden = true })
    assert_true(r.ok, 'set_hidden: ok')
    assert_true(TZD.getTriggerZoneHidden(c.zoneId), 'set_hidden true: applied')
    verbs.zone_set_hidden({ name = 'H1', hidden = false })
    assert_false(TZD.getTriggerZoneHidden(c.zoneId), 'set_hidden false: applied')
end

local function test_set_hidden_arg_validation()
    reset()
    verbs.zone_create_circle({ name = 'H2', north = 0, east = 0, radius = 100 })
    assert_false(verbs.zone_set_hidden({ name = 'H2' }).ok, 'set_hidden: missing bool')
    assert_false(verbs.zone_set_hidden({ name = 'H2', hidden = 'true' }).ok,
                 'set_hidden: string rejected')
end

-- ============================================================
-- zone_set_vertices
-- ============================================================

local function test_set_vertices_happy()
    reset()
    local q = verbs.zone_create_quad({
        name = 'V1',
        vertices = {
            { north = 0, east = 0 }, { north = 100, east = 0 },
            { north = 100, east = 100 }, { north = 0, east = 100 },
        },
    })
    local r = verbs.zone_set_vertices({
        name = 'V1',
        vertices = {
            { north = 1000, east = 1000 }, { north = 3000, east = 1000 },
            { north = 3000, east = 3000 }, { north = 1000, east = 3000 },
        },
    })
    assert_true(r.ok, 'set_vertices: ok')
    assert_eq(r.center.north, 2000, 'set_vertices: new center.north')
    assert_eq(r.center.east, 2000, 'set_vertices: new center.east')
    assert_eq(r.vertex_count, 4, 'set_vertices: count')
end

local function test_set_vertices_refused_on_circle()
    reset()
    verbs.zone_create_circle({ name = 'V2', north = 0, east = 0, radius = 100 })
    local r = verbs.zone_set_vertices({
        name = 'V2', vertices = {
            { north = 0, east = 0 }, { north = 1, east = 0 }, { north = 0, east = 1 } } })
    assert_false(r.ok, 'set_vertices on circle: refused')
    assert_contains(r.error, 'not a quad', 'set_vertices circle: error msg')
end

local function test_set_vertices_arg_validation()
    reset()
    verbs.zone_create_quad({
        name = 'V3', vertices = {
            { north = 0, east = 0 }, { north = 1, east = 0 }, { north = 0, east = 1 } } })
    assert_false(verbs.zone_set_vertices({ name = 'V3' }).ok,
                 'set_vertices: missing vertices')
    assert_false(verbs.zone_set_vertices({
        name = 'V3', vertices = { { north = 0, east = 0 } } }).ok,
        'set_vertices: < 3 vertices')
end

-- ============================================================
-- zone_set_link
-- ============================================================

local function test_set_link_to_unit()
    reset()
    local g = mock.add_plane({ name = 'L1' })
    local u = g.units[1]
    local z = verbs.zone_create_circle({ name = 'LZ1', north = 0, east = 0, radius = 100 })
    local r = verbs.zone_set_link({ name = 'LZ1', unit = u.name })
    assert_true(r.ok, 'set_link unit: ok')
    assert_eq(r.unit_id, u.unitId, 'set_link: unit_id returned')
    assert_eq(TZD.getLinkUnitId(z.zoneId), u.unitId, 'set_link: linkUnitId stored')
end

local function test_set_link_by_unit_id()
    reset()
    local g = mock.add_plane({ name = 'L2' })
    verbs.zone_create_circle({ name = 'LZ2', north = 0, east = 0, radius = 100 })
    local r = verbs.zone_set_link({ name = 'LZ2', unit_id = g.units[1].unitId })
    assert_true(r.ok, 'set_link by unit_id: ok')
end

local function test_set_link_clear()
    reset()
    local g = mock.add_plane({ name = 'L3' })
    local z = verbs.zone_create_circle({ name = 'LZ3', north = 0, east = 0, radius = 100 })
    verbs.zone_set_link({ name = 'LZ3', unit = g.units[1].name })
    local r = verbs.zone_set_link({ name = 'LZ3', clear = true })
    assert_true(r.ok, 'set_link clear: ok')
    assert_eq(r.cleared, true, 'set_link clear: cleared field')
    assert_eq(TZD.getLinkUnitId(z.zoneId), nil, 'set_link clear: linkUnitId removed')
end

local function test_set_link_relink_dedupes()
    -- Verb defensively unlinks before re-linking when zone is already linked.
    reset()
    local g1 = mock.add_plane({ name = 'L4a' })
    local g2 = mock.add_plane({ name = 'L4b' })
    verbs.zone_create_circle({ name = 'LZ4', north = 0, east = 0, radius = 100 })
    verbs.zone_set_link({ name = 'LZ4', unit = g1.units[1].name })
    local r = verbs.zone_set_link({ name = 'LZ4', unit = g2.units[1].name })
    assert_true(r.ok, 'set_link relink: ok')
    assert_eq(r.unit_id, g2.units[1].unitId, 'set_link relink: now g2 unit')
end

local function test_set_link_unit_not_found()
    reset()
    verbs.zone_create_circle({ name = 'LZ5', north = 0, east = 0, radius = 100 })
    local r = verbs.zone_set_link({ name = 'LZ5', unit = 'ghost-unit' })
    assert_false(r.ok, 'set_link missing unit: refused')
    assert_contains(r.error, 'unit not found', 'set_link: error msg')
end

local function test_set_link_arg_validation()
    reset()
    verbs.zone_create_circle({ name = 'LZ6', north = 0, east = 0, radius = 100 })
    assert_false(verbs.zone_set_link({ name = 'LZ6' }).ok,
                 'set_link: no action specified')
    assert_false(verbs.zone_set_link({ name = 'LZ6', unit = 'x', clear = true }).ok,
                 'set_link: multiple actions')
    assert_false(verbs.zone_set_link({ name = 'LZ6', unit = 'x', unit_id = 1 }).ok,
                 'set_link: unit + unit_id')
end

-- ============================================================
-- zone_list
-- ============================================================

local function test_list_all()
    reset()
    verbs.zone_create_circle({ name = 'L1', north = 0, east = 0, radius = 100 })
    verbs.zone_create_quad({
        name = 'L2', vertices = {
            { north = 0, east = 0 }, { north = 1, east = 0 }, { north = 0, east = 1 } } })
    local r = verbs.zone_list({})
    assert_true(r.ok, 'list: ok')
    assert_eq(r.count, 2, 'list: count = 2')
end

local function test_list_filter_shape()
    reset()
    verbs.zone_create_circle({ name = 'C1', north = 0, east = 0, radius = 100 })
    verbs.zone_create_circle({ name = 'C2', north = 0, east = 0, radius = 100 })
    verbs.zone_create_quad({
        name = 'Q1', vertices = {
            { north = 0, east = 0 }, { north = 1, east = 0 }, { north = 0, east = 1 } } })
    local r1 = verbs.zone_list({ shape = 'circle' })
    assert_eq(r1.count, 2, 'list shape=circle: count = 2')
    local r2 = verbs.zone_list({ shape = 'quad' })
    assert_eq(r2.count, 1, 'list shape=quad: count = 1')
end

local function test_list_filter_name_substring()
    reset()
    verbs.zone_create_circle({ name = 'CAS-North', north = 0, east = 0, radius = 100 })
    verbs.zone_create_circle({ name = 'CAS-South', north = 0, east = 0, radius = 100 })
    verbs.zone_create_circle({ name = 'OBJ-1', north = 0, east = 0, radius = 100 })
    local r = verbs.zone_list({ name = 'cas' })
    assert_eq(r.count, 2, 'list name substring (case insensitive): count = 2')
end

local function test_list_summary_fields()
    reset()
    local c = verbs.zone_create_circle({
        name = 'S1', north = 100, east = 200, radius = 500,
        color = { 0.1, 0.2, 0.3, 0.4 } })
    local r = verbs.zone_list({ name = 'S1' })
    local s = r.zones[1]
    assert_eq(s.id, c.zoneId, 'summary: id')
    assert_eq(s.shape, 'circle', 'summary: shape')
    assert_eq(s.type, 0, 'summary: type=0')
    assert_eq(s.north, 100, 'summary: north')
    assert_eq(s.east, 200, 'summary: east')
    assert_eq(s.radius, 500, 'summary: radius')
    assert_eq(s.color[1], 0.1, 'summary: color r')
    assert_eq(s.hidden, false, 'summary: hidden')
end

-- ============================================================
-- zone_get
-- ============================================================

local function test_get_circle()
    reset()
    local c = verbs.zone_create_circle({
        name = 'G1', north = 100, east = 200, radius = 500 })
    local r = verbs.zone_get({ name = 'G1' })
    assert_true(r.ok, 'get circle: ok')
    assert_eq(r.zone.shape, 'circle', 'get: shape')
    assert_eq(r.zone.id, c.zoneId, 'get: id')
    assert_eq(r.zone.north, 100, 'get: north')
end

local function test_get_quad_returns_absolute_vertices()
    reset()
    local q = verbs.zone_create_quad({
        name = 'G2',
        vertices = {
            { north = 0,    east = 0 },
            { north = 1000, east = 0 },
            { north = 1000, east = 1000 },
            { north = 0,    east = 1000 },
        } })
    local r = verbs.zone_get({ name = 'G2' })
    assert_true(r.ok, 'get quad: ok')
    assert_eq(r.zone.shape, 'quad', 'get quad: shape')
    assert_eq(#r.zone.vertices_absolute, 4, 'get quad: 4 abs vertices returned')
    -- Confirm round-trip: absolute reconstruction equals what we passed (avg = 500)
    -- Vertex 1 was {0, 0}; relative is {-500, -500}; absolute = -500+500, -500+500 = 0,0
    assert_eq(r.zone.vertices_absolute[1].north, 0, 'get quad: vert 1 north')
    assert_eq(r.zone.vertices_absolute[1].east, 0, 'get quad: vert 1 east')
end

local function test_get_not_found()
    reset()
    local r = verbs.zone_get({ name = 'ghost' })
    assert_false(r.ok, 'get not found: error')
end

local function test_get_arg_validation()
    reset()
    assert_false(verbs.zone_get({}).ok, 'get: empty')
    assert_false(verbs.zone_get({ name = 'x', id = 1 }).ok, 'get: both')
end

-- ============================================================
-- lat/lon enrichment (GH#66 request 4)
-- ============================================================

-- Stub Terrain only for the duration of one test so other tests stay on the
-- "no Terrain → no lat/lon" path.
local function with_terrain_stub(fn)
    local saved = _G.Terrain
    _G.Terrain = {
        convertMetersToLatLon = function(x, y) return x / 111000, y / 85000 end,
    }
    local ok, err = pcall(fn)
    _G.Terrain = saved
    if not ok then error(err, 0) end
end

local function test_list_includes_lat_lon()
    reset()
    verbs.zone_create_circle({ name = 'LL1', north = 111000, east = 85000, radius = 500 })
    with_terrain_stub(function()
        local r = verbs.zone_list({})
        assert_true(r.ok, 'zone_list w/ Terrain: ok')
        local found
        for _, z in ipairs(r.zones) do if z.name == 'LL1' then found = z end end
        assert_true(found ~= nil, 'zone_list: row found')
        assert_eq(found.lat, 1, 'zone_list: lat from Terrain stub')
        assert_eq(found.lon, 1, 'zone_list: lon from Terrain stub')
    end)
end

local function test_get_circle_includes_lat_lon()
    reset()
    verbs.zone_create_circle({ name = 'LL2', north = 222000, east = 170000, radius = 500 })
    with_terrain_stub(function()
        local r = verbs.zone_get({ name = 'LL2' })
        assert_true(r.ok, 'zone_get circle w/ Terrain: ok')
        assert_eq(r.zone.lat, 2, 'zone_get circle: lat')
        assert_eq(r.zone.lon, 2, 'zone_get circle: lon')
    end)
end

local function test_get_quad_each_vertex_has_lat_lon()
    reset()
    verbs.zone_create_quad({
        name = 'LL3',
        vertices = {
            { north = 0,      east = 0 },
            { north = 111000, east = 0 },
            { north = 111000, east = 85000 },
            { north = 0,      east = 85000 },
        } })
    with_terrain_stub(function()
        local r = verbs.zone_get({ name = 'LL3' })
        assert_true(r.ok, 'zone_get quad w/ Terrain: ok')
        assert_eq(#r.zone.vertices_absolute, 4, 'zone_get quad: 4 vertices')
        -- Each vertex should now carry its own lat/lon.
        for i, v in ipairs(r.zone.vertices_absolute) do
            assert_true(type(v.lat) == 'number',
                'zone_get quad: vertex ' .. i .. ' has numeric lat')
            assert_true(type(v.lon) == 'number',
                'zone_get quad: vertex ' .. i .. ' has numeric lon')
        end
        -- And the linear stub gives clean integers for the (111000, 85000)
        -- aligned corner — catches arg-swap and per-vertex offset bugs.
        local v3 = r.zone.vertices_absolute[3]
        assert_eq(v3.lat, 1, 'zone_get quad: vertex 3 lat from stub')
        assert_eq(v3.lon, 1, 'zone_get quad: vertex 3 lon from stub')
    end)
end

local function test_list_omits_lat_lon_when_no_terrain()
    reset()
    verbs.zone_create_circle({ name = 'LL4', north = 111000, east = 85000, radius = 500 })
    local r = verbs.zone_list({})
    assert_true(r.ok, 'zone_list no Terrain: ok')
    local found
    for _, z in ipairs(r.zones) do if z.name == 'LL4' then found = z end end
    assert_true(found ~= nil, 'zone_list: row found')
    assert_eq(found.lat, nil, 'zone_list: lat absent without Terrain')
    assert_eq(found.lon, nil, 'zone_list: lon absent without Terrain')
end

-- ============================================================
-- Test runner
-- ============================================================

local tests = {
    test_create_circle_happy,
    test_create_circle_default_color,
    test_create_circle_custom_color,
    test_create_circle_hidden,
    test_create_circle_name_uniquification,
    test_create_circle_arg_validation,
    test_create_quad_happy,
    test_create_quad_triangle,
    test_create_quad_radius_default_from_bbox,
    test_create_quad_arg_validation,
    test_remove_by_name,
    test_remove_by_id,
    test_remove_not_found,
    test_remove_arg_validation,
    test_set_color_happy,
    test_set_color_explicit_alpha,
    test_set_color_arg_validation,
    test_set_name_happy,
    test_set_name_arg_validation,
    test_set_pos_happy,
    test_set_pos_arg_validation,
    test_set_radius_happy,
    test_set_radius_arg_validation,
    test_set_hidden_happy,
    test_set_hidden_arg_validation,
    test_set_vertices_happy,
    test_set_vertices_refused_on_circle,
    test_set_vertices_arg_validation,
    test_set_link_to_unit,
    test_set_link_by_unit_id,
    test_set_link_clear,
    test_set_link_relink_dedupes,
    test_set_link_unit_not_found,
    test_set_link_arg_validation,
    test_list_all,
    test_list_filter_shape,
    test_list_filter_name_substring,
    test_list_summary_fields,
    test_get_circle,
    test_get_quad_returns_absolute_vertices,
    test_get_not_found,
    test_get_arg_validation,
    test_list_includes_lat_lon,
    test_get_circle_includes_lat_lon,
    test_get_quad_each_vertex_has_lat_lon,
    test_list_omits_lat_lon_when_no_terrain,
}

for _, t in ipairs(tests) do t() end

print(string.format('test_verbs_zone: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
