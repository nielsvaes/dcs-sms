-- Parity test: framework/prefab_distill.lua vs tools/me-mod/lua/dcs_sms_me/prefab_distill.lua.
-- Both must produce deep-equal output for the same input.
-- Run via: lua test_distill_parity.lua  (cwd: tools/me-mod/test/)

-- 1) Load me-mod copy (module-style).
package.path = '../lua/dcs_sms_me/?.lua;' .. package.path
local memod_distill = require('prefab_distill').distill

-- 2) Load framework copy. Framework-style: stub sms, sms.log, sms.K.
sms = {}
sms.log = { module = function() return { warn=function() end, error=function() end, info=function() end, debug=function() end } end }
sms.K = { statics = {} }   -- empty catalog → both fall through to shape-inference
sms.prefab = nil
package.path = '../../../framework/?.lua;' .. package.path
dofile('../../../framework/prefab_distill.lua')
local fw_distill = sms.prefab.distill

-- Recursive deep-equal that ignores meta.created_utc (timestamp differs per call).
local function deep_equal(a, b, path)
    path = path or 'root'
    if type(a) ~= type(b) then return false, path .. ': type ' .. type(a) .. ' vs ' .. type(b) end
    if type(a) ~= 'table' then
        if a ~= b then return false, path .. ': ' .. tostring(a) .. ' vs ' .. tostring(b) end
        return true
    end
    for k, v in pairs(a) do
        if not (path == 'root.meta' and k == 'created_utc') then
            local ok, why = deep_equal(v, b[k], path .. '.' .. tostring(k))
            if not ok then return false, why end
        end
    end
    for k, _ in pairs(b) do
        if a[k] == nil and not (path == 'root.meta' and k == 'created_utc') then
            return false, path .. '.' .. tostring(k) .. ': missing in a'
        end
    end
    return true
end

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1
    end
end

local function approx(a, b)
    return type(a) == 'number' and math.abs(a - b) <= 1e-6
end

local function load_dump(path)
    local f = assert(loadfile(path))
    return f()
end

local function assert_parity(name, dump, opts)
    local a = memod_distill(dump, opts)
    local b = fw_distill(dump, opts)
    if a == nil and b == nil then
        check(name .. ' (both nil)', true)
        return
    end
    if (a == nil) ~= (b == nil) then
        check(name, false, 'memod=' .. tostring(a) .. ' fw=' .. tostring(b))
        return
    end
    local ok, why = deep_equal(a, b)
    check(name, ok, why)
end

-- Case 1: real synthetic fixture.
local fixture = load_dump('fixtures/dump_synthetic_aerial.lua')
assert_parity('synthetic aerial fixture', fixture, {name='test', theatre='Caucasus'})

-- Case 2: minimal single group.
assert_parity('single group at origin', {
    groups = { { name='G1', x=0, y=0, units={ { name='U1', type='F-16C_50', x=0, y=0, heading=0 } } } }
}, {name='one'})

-- Case 3: two groups for centroid.
assert_parity('two groups for centroid', {
    groups = {
        { name='G1', x=0,   y=0,   units={ { name='U1', type='F-16C_50', x=0,   y=0,   heading=0 } } },
        { name='G2', x=200, y=400, units={ { name='U2', type='F-16C_50', x=200, y=400, heading=math.pi } } },
    }
}, {name='two'})

-- Case 4: opts.name missing → both should return nil.
assert_parity('no name → nil', { groups={ { x=0, y=0 } } }, {})

-- Case 5: empty dump → both should return nil.
assert_parity('empty dump → nil', { groups={}, statics={}, zones={}, drawings={} }, {name='empty'})

-- Case 6: zones + drawings mixed.
assert_parity('zones+drawings', {
    groups = {},
    statics = {},
    zones    = { { name='Z1', x=100, y=200, radius=50, type=0, properties={} } },
    drawings = { { name='D1', primitiveType='Polygon', mapData={ x=300, y=400 }, points={ {x=0,y=0}, {x=10,y=0}, {x=10,y=10} } } },
}, {name='zd'})

-- Case 7: mapObjects (the ME's render-side widget cache) gets stripped
-- during distill. Carrying it over caused GH#56 (duplicate target-zone
-- triangles on placement). Both copies must drop it.
do
    local with_mo = {
        groups = {
            {
                name = 'G1', x = 0, y = 0,
                mapObjects = {
                    route = {
                        points = { { x=0, y=0, id=12, classKey='RoutePoint' } },
                        targetZones = { [4] = { { id=65, classKey='S00000005' } } },
                    },
                    units = {}, zones = {},
                },
                units = { { name='U1', type='F-16C_50', x=0, y=0, heading=0 } },
            },
        },
    }
    local memod_out = memod_distill(with_mo, {name='strip-mo'})
    local fw_out    = fw_distill(with_mo,    {name='strip-mo'})
    check('mapObjects stripped (me-mod)',
          memod_out and memod_out.groups and memod_out.groups[1]
              and memod_out.groups[1].mapObjects == nil,
          'me-mod distill left mapObjects in the output')
    check('mapObjects stripped (framework)',
          fw_out and fw_out.groups and fw_out.groups[1]
              and fw_out.groups[1].mapObjects == nil,
          'framework distill left mapObjects in the output')
    assert_parity('mapObjects parity', with_mo, {name='strip-mo'})
end

-- Case 8: escort/follow formation offset. distill's rebase_xy must NOT
-- subtract the centroid from a task's params.pos — it's a relative {x,y,z}
-- vector, not a world coordinate. Rebasing corrupted the saved Distance/
-- Elevation (z Interval was spared only by sitting outside the {x,y} pair).
-- The waypoint's own coords in the same task ARE rebased. Both copies must
-- behave identically. See the Tanker+Escort prefab bug.
do
    local dump = {
        groups = {
            {
                name = 'Escort-1', x = 1000, y = 2000,
                units = { { name = 'E1', type = 'FA-18C_hornet', x = 1000, y = 2000, heading = 0 } },
                route = { points = {
                    [1] = { x = 1000, y = 2000, task = { id = 'ComboTask', params = { tasks = {} } } },
                    [2] = { x = 1000, y = 2000, task = { id = 'ComboTask', params = { tasks = {
                        [1] = { id = 'Escort', number = 1, enabled = true, auto = false,
                                params = { groupId = 5, engagementDistMax = 60000,
                                           pos = { x = -304.8, y = 45.72, z = 91.44 } } },
                    } } } },
                } },
            },
        },
    }

    local function escort_pos(out)
        local ok, pos = pcall(function()
            return out.groups[1].route.points[2].task.params.tasks[1].params.pos
        end)
        return ok and pos or nil
    end
    local function wp2(out)
        local ok, p = pcall(function() return out.groups[1].route.points[2] end)
        return ok and p or nil
    end

    local mem = memod_distill(dump, { name = 'escort' })
    local fw  = fw_distill(dump,    { name = 'escort' })
    local mpos, fpos = escort_pos(mem), escort_pos(fw)

    check('escort distill: me-mod keeps pos.x (not rebased)',
          mpos and approx(mpos.x, -304.8), 'got ' .. tostring(mpos and mpos.x))
    check('escort distill: me-mod keeps pos.y (not rebased)',
          mpos and approx(mpos.y, 45.72), 'got ' .. tostring(mpos and mpos.y))
    check('escort distill: framework keeps pos.x (not rebased)',
          fpos and approx(fpos.x, -304.8), 'got ' .. tostring(fpos and fpos.x))
    check('escort distill: framework keeps pos.y (not rebased)',
          fpos and approx(fpos.y, 45.72), 'got ' .. tostring(fpos and fpos.y))
    -- Sanity: the waypoint's own coords WERE rebased (centroid 1000,2000 → 0,0),
    -- proving the skip is targeted at pos, not a blanket no-op.
    local w = wp2(mem)
    check('escort distill: waypoint xy still rebased to origin',
          w and approx(w.x, 0) and approx(w.y, 0),
          'got ' .. tostring(w and w.x) .. ', ' .. tostring(w and w.y))

    assert_parity('escort pos parity', dump, { name = 'escort' })
end

-- Case 9: polygon (quad) trigger-zone vertices. distill's rebase_xy must NOT
-- subtract the centroid from a zone's `points` — they are vertices stored
-- relative to the zone's own {x,y} centre, not world coordinates. Rebasing
-- them on save + re-anchoring on place left the polygon offset from its centre
-- by the placement delta. The zone's own centre IS rebased. The unit-level
-- `zones` render cache (threat rings) holds real world coords and must still
-- be rebased. Both copies must behave identically. See quad_zone_test prefab.
do
    local dump = {
        groups = {
            {
                name = 'G1', x = 1000, y = 2000,
                units = { { name = 'U1', type = 'AAV7', x = 1000, y = 2000, heading = 0,
                            -- Render-side threat ring: ABSOLUTE world coords.
                            zones = { { classKey = 'ThreatRangeBorder', radius = 1200,
                                        points = { { x = 1000, y = 3200 } } } } } },
            },
        },
        zones = {
            -- Centre (1000, 2000); vertices relative to it, summing to zero.
            { name = 'Z1', x = 1000, y = 2000, radius = 3000, type = 2, properties = {},
              points = { { x = -3000, y = -3000 }, { x = 3000, y = -3000 },
                         { x = 3000, y = 3000 },   { x = -3000, y = 3000 } } },
        },
    }

    local mem = memod_distill(dump, { name = 'quad' })
    local fw  = fw_distill(dump,    { name = 'quad' })

    for label, out in pairs({ ['me-mod'] = mem, ['framework'] = fw }) do
        local z = out and out.zones and out.zones[1]
        -- Centroid of the two positionable entities (group + zone) is (1000,2000),
        -- so the zone centre rebases to the origin.
        check('quad distill (' .. label .. '): zone centre rebased to origin',
              z and approx(z.x, 0) and approx(z.y, 0),
              'got ' .. tostring(z and z.x) .. ', ' .. tostring(z and z.y))
        check('quad distill (' .. label .. '): vertex 1 kept relative (-3000,-3000)',
              z and z.points and approx(z.points[1].x, -3000) and approx(z.points[1].y, -3000),
              'got ' .. tostring(z and z.points and z.points[1].x))
        check('quad distill (' .. label .. '): vertex 3 kept relative (3000,3000)',
              z and z.points and approx(z.points[3].x, 3000) and approx(z.points[3].y, 3000),
              'got ' .. tostring(z and z.points and z.points[3].x))
        -- Vertices still sum to zero — the relative-to-centre invariant.
        local sx, sy = 0, 0
        if z and z.points then
            for _, p in ipairs(z.points) do sx, sy = sx + p.x, sy + p.y end
        end
        check('quad distill (' .. label .. '): vertices still sum to (0,0)',
              approx(sx, 0) and approx(sy, 0), 'got ' .. sx .. ', ' .. sy)
        -- The unit-level threat-ring cache holds world coords and MUST rebase,
        -- proving the skip is targeted at trigger zones, not any `points` key.
        local ring = out and out.groups and out.groups[1] and out.groups[1].units
                     and out.groups[1].units[1] and out.groups[1].units[1].zones
                     and out.groups[1].units[1].zones[1]
        check('quad distill (' .. label .. '): unit threat-ring points still rebased',
              ring and ring.points and approx(ring.points[1].x, 0)
              and approx(ring.points[1].y, 1200),
              'got ' .. tostring(ring and ring.points and ring.points[1].x)
              .. ', ' .. tostring(ring and ring.points and ring.points[1].y))
    end

    assert_parity('quad zone points parity', dump, { name = 'quad' })
end

if failures > 0 then
    print(string.format('%d failure(s)', failures))
    os.exit(1)
end
print('All distill-parity tests passed.')
