-- Standalone test for prefab_ops place math (rotate + translate).
-- The ME-API injection itself is not unit-testable; covered by manual smoke.
-- Run via: lua test_prefab_ops_place.lua  (cwd: tools/me-mod/test/)

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end

package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local prefab_ops = require('prefab_ops')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1
    end
end

local function approx(a, b, eps)
    eps = eps or 0.001
    return math.abs(a - b) <= eps
end

-- Math helper: place_xy(rel_x, rel_y, anchor, rotation_deg) → (world_x, world_y)
do
    local x, y = prefab_ops._place_xy(100, 0, { x = 1000, y = 2000 }, 0)
    check('rot 0: (100, 0) at anchor (1000, 2000) → (1100, 2000)',
          approx(x, 1100) and approx(y, 2000), 'got ' .. x .. ', ' .. y)

    local x2, y2 = prefab_ops._place_xy(100, 0, { x = 0, y = 0 }, 90)
    check('rot 90: (100, 0) → (0, 100)',
          approx(x2, 0) and approx(y2, 100), 'got ' .. x2 .. ', ' .. y2)

    local x3, y3 = prefab_ops._place_xy(0, 100, { x = 0, y = 0 }, 90)
    check('rot 90: (0, 100) → (-100, 0)',
          approx(x3, -100) and approx(y3, 0), 'got ' .. x3 .. ', ' .. y3)

    local x4, y4 = prefab_ops._place_xy(100, 0, { x = 500, y = 500 }, 180)
    check('rot 180: (100, 0) at anchor (500, 500) → (400, 500)',
          approx(x4, 400) and approx(y4, 500), 'got ' .. x4 .. ', ' .. y4)
end

-- 0.1.0 back-compat un-rebase helper: adds world_anchor back to every
-- vertex inside mapData's geometry sub-arrays, leaves mapData.{x,y}
-- untouched. Locks behavior so a future bump can't silently break the
-- shim by misfiring (or not firing) on legacy saves.
do
    local md = {
        x = -100, y = -200,                 -- the polygon anchor in distilled coords; untouched
        points = {                          -- vertices have been over-rebased by (-1000, -2000)
            { x = -1000, y = -2000 },
            { x = -900,  y = -2000 },
        },
    }
    prefab_ops._unrebase_mapData_geometry(md, 1000, 2000)
    check('un-rebase: mapData.x untouched', md.x == -100, 'got ' .. md.x)
    check('un-rebase: mapData.y untouched', md.y == -200, 'got ' .. md.y)
    check('un-rebase: points[1] (-1000,-2000) + (1000,2000) = (0,0)',
          approx(md.points[1].x, 0) and approx(md.points[1].y, 0),
          'got ' .. md.points[1].x .. ', ' .. md.points[1].y)
    check('un-rebase: points[2] (-900,-2000) + (1000,2000) = (100,0)',
          approx(md.points[2].x, 100) and approx(md.points[2].y, 0),
          'got ' .. md.points[2].x .. ', ' .. md.points[2].y)

    -- nil mapData: no-op (no error).
    prefab_ops._unrebase_mapData_geometry(nil, 1000, 2000)
    check('un-rebase nil mapData: no error', true)

    -- Recurses through nested geometry tables.
    local md2 = {
        x = 0, y = 0,
        arc_points = { sub = { { x = -50, y = -50 } } },
    }
    prefab_ops._unrebase_mapData_geometry(md2, 50, 50)
    check('un-rebase: nested vertex (-50,-50) + (50,50) = (0,0)',
          approx(md2.arc_points.sub[1].x, 0) and approx(md2.arc_points.sub[1].y, 0),
          'got ' .. md2.arc_points.sub[1].x .. ', ' .. md2.arc_points.sub[1].y)
end

-- Drawing rotation: vertices inside mapData get rotated around the local
-- origin; mapData.{x,y} itself stays untouched (it's the polygon anchor and
-- rotates downstream via _place_xy).
do
    local md = {
        x = 100, y = 200,
        points = {
            { x = 100, y = 0   },   -- east
            { x = 0,   y = 100 },   -- north
        },
    }
    prefab_ops._rotate_mapData_geometry(md, 90)
    -- 90deg rotation: (x, y) → (-y, x). So (100, 0) → (0, 100); (0, 100) → (-100, 0).
    check('rotate 90: mapData.x untouched', md.x == 100, 'got ' .. md.x)
    check('rotate 90: mapData.y untouched', md.y == 200, 'got ' .. md.y)
    check('rotate 90: points[1] (100,0) → (0,100)',
          approx(md.points[1].x, 0) and approx(md.points[1].y, 100),
          'got ' .. md.points[1].x .. ', ' .. md.points[1].y)
    check('rotate 90: points[2] (0,100) → (-100,0)',
          approx(md.points[2].x, -100) and approx(md.points[2].y, 0),
          'got ' .. md.points[2].x .. ', ' .. md.points[2].y)

    -- 0deg rotation: no-op.
    local md2 = { x = 5, y = 5, points = { { x = 7, y = 9 } } }
    prefab_ops._rotate_mapData_geometry(md2, 0)
    check('rotate 0: vertex unchanged',
          md2.points[1].x == 7 and md2.points[1].y == 9,
          'got ' .. md2.points[1].x .. ', ' .. md2.points[1].y)

    -- nil mapData: no-op (no error).
    prefab_ops._rotate_mapData_geometry(nil, 90)
    check('rotate nil mapData: no error', true)

    -- Recurses into nested geometry sub-arrays (e.g. arc_points).
    local md3 = {
        x = 0, y = 0,
        arc_points = {
            sub = { { x = 100, y = 0 } },
        },
    }
    prefab_ops._rotate_mapData_geometry(md3, 180)
    check('rotate 180: nested vertex (100,0) → (-100,0)',
          approx(md3.arc_points.sub[1].x, -100) and approx(md3.arc_points.sub[1].y, 0),
          'got ' .. md3.arc_points.sub[1].x .. ', ' .. md3.arc_points.sub[1].y)
end

-- Heading composition: world_heading_deg = (file_heading_deg + rotation_deg) mod 360
do
    check('heading 30 + rotation 60 = 90', prefab_ops._heading_world(30, 60) == 90)
    check('heading 350 + rotation 20 = 10', prefab_ops._heading_world(350, 20) == 10)
    check('heading -30 + rotation 0 = 330', prefab_ops._heading_world(-30, 0) == 330)
end

-- Full pipeline: file (deg) -> rotation -> radians for DCS injection.
-- The earlier triple-conversion bug had `v * (180/math.pi)` baked in, so a
-- 45-deg saved heading came out as ~1.0177 rad (= 58.31°) instead of the
-- correct 0.7854 rad. These assertions lock that down.
do
    -- 45° saved, no extra rotation → π/4 rad.
    local g = { heading = 45, units = { { heading = 45 } } }
    prefab_ops._transform_headings(g, 0)
    check('heading 45° → π/4 rad (group)',
          approx(g.heading, math.pi / 4),
          'got ' .. tostring(g.heading))
    check('heading 45° → π/4 rad (nested unit)',
          approx(g.units[1].heading, math.pi / 4),
          'got ' .. tostring(g.units[1].heading))

    -- 0° saved → 0 rad regardless of rotation.
    local g2 = { heading = 0 }
    prefab_ops._transform_headings(g2, 0)
    check('heading 0° → 0 rad', g2.heading == 0, 'got ' .. tostring(g2.heading))

    -- 30° saved + 60° place rotation → 90° → π/2 rad.
    local g3 = { heading = 30 }
    prefab_ops._transform_headings(g3, 60)
    check('heading 30° + rot 60° → π/2 rad',
          approx(g3.heading, math.pi / 2),
          'got ' .. tostring(g3.heading))

    -- Wrap: 350° + 20° → 10° → π/18 rad.
    local g4 = { heading = 350 }
    prefab_ops._transform_headings(g4, 20)
    check('heading 350° + rot 20° wraps to π/18 rad',
          approx(g4.heading, math.pi / 18),
          'got ' .. tostring(g4.heading))
end

-- Escort/Follow formation offset: transform_coords must NOT move a task's
-- params.pos. It's a relative {x,y,z} vector in the escorted group's frame
-- (Distance / Elevation / Interval), not a world coordinate. Rebasing it on
-- save + re-anchoring it here made Distance/Elevation blow up to map scale on
-- placement — interval survived only because it's pos.z, outside the {x,y}
-- pair. See the Tanker+Escort prefab bug.
do
    local g = {
        x = 100, y = 200,
        units = { { x = 100, y = 200 } },
        route = { points = { [1] = {
            x = 100, y = 200,
            task = { params = { tasks = { [1] = {
                id = 'Escort',
                params = { groupId = 5, pos = { x = -304.8, y = 45.72, z = 91.44 } },
            } } } },
        } } },
    }
    prefab_ops._transform_coords(g, { x = 1000, y = 2000 }, 0)
    -- Real map coords ARE transformed (relative + anchor).
    check('escort place: group xy transformed',
          approx(g.x, 1100) and approx(g.y, 2200), 'got ' .. g.x .. ', ' .. g.y)
    check('escort place: unit xy transformed',
          approx(g.units[1].x, 1100) and approx(g.units[1].y, 2200),
          'got ' .. g.units[1].x .. ', ' .. g.units[1].y)
    check('escort place: waypoint xy transformed',
          approx(g.route.points[1].x, 1100) and approx(g.route.points[1].y, 2200),
          'got ' .. g.route.points[1].x .. ', ' .. g.route.points[1].y)
    -- The formation offset is left exactly as-is.
    local pos = g.route.points[1].task.params.tasks[1].params.pos
    check('escort place: task pos.x untouched', approx(pos.x, -304.8), 'got ' .. pos.x)
    check('escort place: task pos.y untouched', approx(pos.y, 45.72), 'got ' .. pos.y)
    check('escort place: task pos.z untouched', approx(pos.z, 91.44), 'got ' .. pos.z)
end

-- Version gate for the legacy pos un-rebase: fires only on prefabs older than
-- the fix (0.6.0). Unset/empty counts as oldest. Numeric (not lexical) compare
-- so it never mis-fires on a future 0.10.0 — and never on the fixed format.
do
    check('version_lt: "0.5.0" < "0.6.0"', prefab_ops._version_lt('0.5.0', '0.6.0') == true)
    check('version_lt: "" (unset) < "0.6.0"', prefab_ops._version_lt('', '0.6.0') == true)
    check('version_lt: "0.1.0" < "0.6.0"', prefab_ops._version_lt('0.1.0', '0.6.0') == true)
    check('version_lt: "0.6.0" not < "0.6.0"', prefab_ops._version_lt('0.6.0', '0.6.0') == false)
    check('version_lt: "0.7.0" not < "0.6.0"', prefab_ops._version_lt('0.7.0', '0.6.0') == false)
    check('version_lt: "0.10.0" not < "0.6.0" (numeric, not lexical)',
          prefab_ops._version_lt('0.10.0', '0.6.0') == false)
end

-- Legacy migration: prefabs saved before the pos fix stored the escort/follow
-- formation offset with the centroid already subtracted (the rebase_xy bug).
-- On place, un-rebase adds meta.world_anchor back to reconstruct the true
-- offset. Mirrors the 0.1.0 mapData un-rebase shim. Only a pos {x,y,z} is
-- touched; real anchor-relative coords are left alone.
do
    local g = {
        x = -50, y = -50,   -- a real anchor-relative coord; must NOT change
        route = { points = { [1] = { task = { params = { tasks = { [1] = {
            id = 'Escort',
            params = { pos = { x = -37672.04, y = -10053.43, z = 91.44 } },
        } } } } } } },
    }
    prefab_ops._unrebase_task_pos(g, 37367.24, 10099.15)
    local pos = g.route.points[1].task.params.tasks[1].params.pos
    check('unrebase pos.x: -37672.04 + 37367.24 ≈ -304.8', approx(pos.x, -304.8, 0.01), 'got ' .. pos.x)
    check('unrebase pos.y: -10053.43 + 10099.15 ≈ 45.72', approx(pos.y, 45.72, 0.01), 'got ' .. pos.y)
    check('unrebase pos.z untouched', approx(pos.z, 91.44), 'got ' .. pos.z)
    check('unrebase: real coord g.x untouched', g.x == -50, 'got ' .. g.x)

    -- No pos → no-op, no error.
    local g2 = { x = 0, y = 0, units = { { x = 1, y = 2 } } }
    prefab_ops._unrebase_task_pos(g2, 100, 200)
    check('unrebase: group without pos is a no-op',
          g2.units[1].x == 1 and g2.units[1].y == 2)
end

-- Polygon (quad) trigger zone vertices. A zone's `points` are stored RELATIVE
-- to the zone's own {x,y} center — the same invariant drawings keep for
-- mapData — so placement must rotate them about the local origin but must NOT
-- add the drop anchor. Adding it left the polygon offset from its own centre
-- by exactly the placement delta (anchor − world_anchor), while the zone's
-- circle icon landed correctly. Circle zones have no `points` and were fine.
do
    -- Rotation 0: vertices unchanged, centre transformed.
    local z = {
        x = 100, y = 200, radius = 3000, type = 2,
        points = { { x = -3000, y = -3000 }, { x = 3000, y = -3000 },
                   { x = 3000, y = 3000 },   { x = -3000, y = 3000 } },
    }
    prefab_ops._transform_zone(z, { x = 1000, y = 2000 }, 0)
    check('quad zone: centre transformed (100,200)+(1000,2000) → (1100,2200)',
          approx(z.x, 1100) and approx(z.y, 2200), 'got ' .. z.x .. ', ' .. z.y)
    check('quad zone rot 0: vertex 1 stays relative (-3000,-3000)',
          approx(z.points[1].x, -3000) and approx(z.points[1].y, -3000),
          'got ' .. z.points[1].x .. ', ' .. z.points[1].y)
    check('quad zone rot 0: vertex 3 stays relative (3000,3000)',
          approx(z.points[3].x, 3000) and approx(z.points[3].y, 3000),
          'got ' .. z.points[3].x .. ', ' .. z.points[3].y)

    -- Rotation 90: vertices rotate about the zone centre, not about the anchor.
    local z2 = {
        x = 0, y = 0, radius = 100, type = 2,
        points = { { x = 100, y = 0 }, { x = 0, y = 100 } },
    }
    prefab_ops._transform_zone(z2, { x = 5000, y = 6000 }, 90)
    check('quad zone rot 90: centre (0,0) → anchor (5000,6000)',
          approx(z2.x, 5000) and approx(z2.y, 6000), 'got ' .. z2.x .. ', ' .. z2.y)
    check('quad zone rot 90: vertex (100,0) → (0,100), still relative',
          approx(z2.points[1].x, 0) and approx(z2.points[1].y, 100),
          'got ' .. z2.points[1].x .. ', ' .. z2.points[1].y)
    check('quad zone rot 90: vertex (0,100) → (-100,0), still relative',
          approx(z2.points[2].x, -100) and approx(z2.points[2].y, 0),
          'got ' .. z2.points[2].x .. ', ' .. z2.points[2].y)

    -- Circle zone: no points, behaves exactly as before.
    local z3 = { x = -50, y = 25, radius = 500, type = 0 }
    prefab_ops._transform_zone(z3, { x = 1000, y = 1000 }, 0)
    check('circle zone: centre transformed, no points key introduced',
          approx(z3.x, 950) and approx(z3.y, 1025) and z3.points == nil,
          'got ' .. z3.x .. ', ' .. z3.y)
end

-- Legacy migration: prefabs saved before this fix (<= 0.6.0) had the prefab
-- centroid subtracted from every polygon-zone vertex by distill's rebase_xy.
-- On place, un-rebase adds meta.world_anchor back to reconstruct the true
-- relative vertex. Mirrors the pos / mapData shims. Values below are the real
-- ones from the quad_zone_test repro prefab.
do
    local z = {
        x = 78.985142857127, y = 3560.5106285714,   -- centre: correct, must NOT change
        radius = 3000, type = 2,
        points = {
            { x = 287332.71954286, y = -645502.61714286 },
            { x = 287431.37005714, y = -633254.03017143 },
            { x = 293332.71954286, y = -639502.61714286 },
            { x = 293298.0288,     y = -650482.09142857 },
        },
    }
    prefab_ops._unrebase_zone_points(z, -290348.70948571, 642185.33897143)
    check('unrebase zone: vertex 1 → (-3015.99, -3317.28)',
          approx(z.points[1].x, -3015.99, 0.01) and approx(z.points[1].y, -3317.28, 0.01),
          'got ' .. z.points[1].x .. ', ' .. z.points[1].y)
    check('unrebase zone: vertex 4 → (2949.32, -8296.75)',
          approx(z.points[4].x, 2949.32, 0.01) and approx(z.points[4].y, -8296.75, 0.01),
          'got ' .. z.points[4].x .. ', ' .. z.points[4].y)
    -- Recovered vertices must sum to ~0 — that is what "relative to the zone
    -- centre" means, and it is how the bug was originally identified.
    local sx, sy = 0, 0
    for _, p in ipairs(z.points) do sx, sy = sx + p.x, sy + p.y end
    check('unrebase zone: recovered vertices sum to (0,0)',
          approx(sx, 0, 0.01) and approx(sy, 0, 0.01), 'got ' .. sx .. ', ' .. sy)
    check('unrebase zone: centre untouched',
          approx(z.x, 78.985142857127) and approx(z.y, 3560.5106285714),
          'got ' .. z.x .. ', ' .. z.y)

    -- Circle zone (no points) → no-op, no error.
    local z2 = { x = 10, y = 20, radius = 500 }
    prefab_ops._unrebase_zone_points(z2, 1000, 2000)
    check('unrebase zone: circle zone is a no-op', z2.x == 10 and z2.y == 20)
end

-- Version gate for the zone-vertex un-rebase: fires on everything up to and
-- including 0.6.0 (the whole history carried the bug), never on 0.7.0+.
do
    check('version_lt: "0.6.0" < "0.7.0"', prefab_ops._version_lt('0.6.0', '0.7.0') == true)
    check('version_lt: "" (unset) < "0.7.0"', prefab_ops._version_lt('', '0.7.0') == true)
    check('version_lt: "0.7.0" not < "0.7.0"', prefab_ops._version_lt('0.7.0', '0.7.0') == false)
    check('version_lt: "0.10.0" not < "0.7.0" (numeric, not lexical)',
          prefab_ops._version_lt('0.10.0', '0.7.0') == false)
end

-- End-to-end vertex math: the whole point of the fix. The ME renders a
-- polygon vertex at zone.x + points[i].x, so after placing a prefab at an
-- anchor the rendered vertex must sit at (original world vertex) + (anchor −
-- world_anchor) — displaced by the placement delta exactly once, not twice.
do
    local K = { x = -290348.70948571, y = 642185.33897143 }  -- world_anchor
    local A = { x = -200000, y = 700000 }                    -- drop anchor
    -- Correctly-saved (0.7.0) zone: centre anchor-relative, vertices relative.
    local z = { x = 78.985142857127, y = 3560.5106285714, radius = 3000, type = 2,
                points = { { x = -3015.99, y = -3317.28 } } }
    prefab_ops._transform_zone(z, A, 0)
    local rendered_x = z.x + z.points[1].x
    local rendered_y = z.y + z.points[1].y
    -- Original world vertex = K + centre_rel + vertex_rel.
    local orig_x = K.x + 78.985142857127 + (-3015.99)
    local orig_y = K.y + 3560.5106285714 + (-3317.28)
    check('e2e: rendered vertex = original + (anchor − world_anchor), once',
          approx(rendered_x, orig_x + (A.x - K.x), 0.01)
          and approx(rendered_y, orig_y + (A.y - K.y), 0.01),
          'got ' .. rendered_x .. ', ' .. rendered_y)
end

-- Bounding box: AABB over every entity's position, in the prefab's
-- anchor-relative frame (the frame distill produces).
do
    local prefab = {
        meta   = { name = 'fixture' },
        groups = {
            { x = 0, y = 0, units = { { x = 100, y = -50 }, { x = -200, y = 30 } } },
        },
        statics = { { x = 50, y = 75 } },
        zones   = { { x = 0, y = 0, radius = 80 } },     -- expands ±80 on both axes
        drawings = {
            { mapData = { x = -10, y = 10, points = { { x = -50, y = 0 }, { x = 50, y = 100 } } } },
            -- Effective vertex coords: (-60, 10) and (40, 110).
        },
    }
    local bb = prefab_ops.compute_bbox(prefab)
    check('bbox: x range covers unit + drawing left', bb.min_x == -200, 'got ' .. bb.min_x)
    check('bbox: x range covers unit right', bb.max_x == 100, 'got ' .. bb.max_x)
    check('bbox: y range covers drawing vertex top', bb.min_y == -80, 'got ' .. bb.min_y)
    check('bbox: y range covers drawing vertex bottom', bb.max_y == 110, 'got ' .. bb.max_y)

    local empty = prefab_ops.compute_bbox({ meta = {}, groups = {}, statics = {}, zones = {}, drawings = {} })
    check('empty prefab: bbox is nil', empty == nil)

    check('non-table prefab: bbox is nil', prefab_ops.compute_bbox('nope') == nil)
end

-- Bounding box, polygon zones: a quad zone's real footprint is its vertices,
-- not its `radius` (which for a quad is only an icon/hit-test hint and can be
-- far smaller than the polygon — 3000 vs ~8900 m in the quad_zone_test repro).
-- Vertices are relative to the zone centre, so the extent is centre + vertex.
do
    local prefab = {
        meta  = { name = 'quad', sms_prefab_version = '0.7.0' },
        zones = {
            { x = 100, y = 200, radius = 50, type = 2,   -- radius deliberately tiny
              points = { { x = -1000, y = -2000 }, { x = 3000, y = -2000 },
                         { x = 3000, y = 4000 },   { x = -1000, y = 4000 } } },
        },
    }
    local bb = prefab_ops.compute_bbox(prefab)
    check('bbox quad: min_x = 100 + (-1000)', bb and bb.min_x == -900, 'got ' .. tostring(bb and bb.min_x))
    check('bbox quad: max_x = 100 + 3000',    bb and bb.max_x == 3100, 'got ' .. tostring(bb and bb.max_x))
    check('bbox quad: min_y = 200 + (-2000)', bb and bb.min_y == -1800, 'got ' .. tostring(bb and bb.min_y))
    check('bbox quad: max_y = 200 + 4000',    bb and bb.max_y == 4200, 'got ' .. tostring(bb and bb.max_y))

    -- Circle zones keep the radius-expansion behaviour.
    local circ = prefab_ops.compute_bbox({ meta = {}, zones = { { x = 0, y = 0, radius = 80 } } })
    check('bbox circle: still radius-expanded to ±80',
          circ and circ.min_x == -80 and circ.max_x == 80
          and circ.min_y == -80 and circ.max_y == 80,
          'got ' .. tostring(circ and circ.min_x) .. '..' .. tostring(circ and circ.max_x))

    -- A polygon zone with an empty/degenerate points list falls back to radius
    -- rather than contributing nothing.
    local degen = prefab_ops.compute_bbox({ meta = {}, zones = { { x = 0, y = 0, radius = 25, type = 2, points = {} } } })
    check('bbox quad: empty points falls back to radius',
          degen and degen.min_x == -25 and degen.max_x == 25,
          'got ' .. tostring(degen and degen.min_x))
end

-- Bounding box on a legacy (≤0.6.0) prefab: the stored vertices are corrupted
-- by the old rebase, so compute_bbox must un-rebase them the same way place
-- does before measuring — otherwise the place-at-click preview overlay would
-- balloon to hundreds of km. Numbers are the real quad_zone_test values.
do
    local K = { x = -290348.70948571, y = 642185.33897143 }
    local prefab = {
        meta  = { name = 'legacy', sms_prefab_version = '0.6.0', world_anchor = K },
        zones = {
            { x = 78.985142857127, y = 3560.5106285714, radius = 3000, type = 2,
              points = {
                  { x = 287332.71954286, y = -645502.61714286 },
                  { x = 287431.37005714, y = -633254.03017143 },
                  { x = 293332.71954286, y = -639502.61714286 },
                  { x = 293298.0288,     y = -650482.09142857 },
              } },
        },
    }
    local bb = prefab_ops.compute_bbox(prefab)
    -- True relative vertices span x −3015.99..2984.01, y −8296.75..8931.31,
    -- around centre (78.99, 3560.51).
    check('bbox legacy quad: min_x ≈ 78.99 - 3015.99', bb and approx(bb.min_x, -2937.00, 0.01),
          'got ' .. tostring(bb and bb.min_x))
    check('bbox legacy quad: max_x ≈ 78.99 + 2984.01', bb and approx(bb.max_x, 3063.00, 0.01),
          'got ' .. tostring(bb and bb.max_x))
    check('bbox legacy quad: min_y ≈ 3560.51 - 8296.75', bb and approx(bb.min_y, -4736.24, 0.01),
          'got ' .. tostring(bb and bb.min_y))
    check('bbox legacy quad: max_y ≈ 3560.51 + 8931.31', bb and approx(bb.max_y, 12491.82, 0.01),
          'got ' .. tostring(bb and bb.max_y))
    -- Sanity: nowhere near the corrupted-vertex scale (hundreds of km).
    check('bbox legacy quad: stays at prefab scale, not map scale',
          bb and math.abs(bb.min_x) < 100000 and math.abs(bb.max_y) < 100000,
          'got ' .. tostring(bb and bb.min_x) .. ', ' .. tostring(bb and bb.max_y))
end

-- Country override: stamps country_name + clears numeric country on the
-- group AND each unit. nil/empty leaves everything alone.
do
    local g = {
        country = 80,
        country_name = 'Russia',
        units = { { country = 80 }, { country = 80, country_name = 'Russia' } },
    }
    prefab_ops._override_country(g, 'USA')
    check('override: group country_name set', g.country_name == 'USA')
    check('override: group country (numeric) cleared', g.country == nil)
    check('override: unit[1] country_name set', g.units[1].country_name == 'USA')
    check('override: unit[1] country (numeric) cleared', g.units[1].country == nil)
    check('override: unit[2] country_name overwritten', g.units[2].country_name == 'USA')

    local g2 = { country = 80, country_name = 'Russia' }
    prefab_ops._override_country(g2, nil)
    check('override nil: country_name untouched', g2.country_name == 'Russia')
    check('override nil: country (numeric) untouched', g2.country == 80)

    prefab_ops._override_country(g2, '')
    check('override "": country_name untouched', g2.country_name == 'Russia')
    check('override "": country (numeric) untouched', g2.country == 80)

    -- Static (no units array) must not blow up.
    local s = { country = 1, type = 'static' }
    prefab_ops._override_country(s, 'Insurgents')
    check('override on static (no units): country_name set', s.country_name == 'Insurgents')
    check('override on static (no units): no error', s.country == nil)
end

-- Resolve effective anchor: keep_position uses meta.world_anchor.
do
    local prefab = { meta = { world_anchor = { x = 5000, y = 6000 } }, groups = {}, statics = {}, zones = {}, drawings = {} }
    local a, r = prefab_ops._resolve_anchor(prefab, { keep_position = true, anchor = { x = 1, y = 1 }, rotation = 30 })
    check('keep_position: anchor from meta', a.x == 5000 and a.y == 6000)
    check('keep_position: rotation forced 0', r == 0)

    local a2, r2 = prefab_ops._resolve_anchor(prefab, { anchor = { x = 100, y = 200 }, rotation = 45 })
    check('non-keep_position: anchor from opts', a2.x == 100 and a2.y == 200)
    check('non-keep_position: rotation passed through', r2 == 45)

    local a3 = prefab_ops._resolve_anchor(prefab, { rotation = 0 })
    check('no anchor + no keep_position: returns nil', a3 == nil)

    -- Malformed-meta paths under keep_position: every "the world_anchor
    -- is missing or not a coordinate pair" path should fall through to
    -- nil rather than spawn at (0,0) or throw on the field access.
    local no_meta = { groups = {}, statics = {}, zones = {}, drawings = {} }
    check('keep_position + no meta: returns nil',
          prefab_ops._resolve_anchor(no_meta, { keep_position = true }) == nil)

    local no_anchor = { meta = {}, groups = {}, statics = {}, zones = {}, drawings = {} }
    check('keep_position + meta but no world_anchor: returns nil',
          prefab_ops._resolve_anchor(no_anchor, { keep_position = true }) == nil)

    local bad_x = { meta = { world_anchor = { x = 'oops', y = 6000 } } }
    check('keep_position + non-numeric world_anchor.x: returns nil',
          prefab_ops._resolve_anchor(bad_x, { keep_position = true }) == nil)

    local bad_y = { meta = { world_anchor = { x = 5000 } } }   -- missing y entirely
    check('keep_position + missing world_anchor.y: returns nil',
          prefab_ops._resolve_anchor(bad_y, { keep_position = true }) == nil)

    -- Same defensive checks for the non-keep_position path.
    local bad_opts_anchor = { meta = { world_anchor = { x = 1, y = 2 } } }
    check('non-keep_position + non-numeric opts.anchor.x: returns nil',
          prefab_ops._resolve_anchor(bad_opts_anchor, { anchor = { x = 'oops', y = 1 } }) == nil)
end

-- ---------------------------------------------------------------------------
-- find_missing_types: country catalog check.
-- Stubs me_db_api so we can assert the helper walks Countries[*].Units[*][*]
-- correctly and returns the list of types the country can't deploy.
-- ---------------------------------------------------------------------------

-- DB stub: USA has the carrier and a humvee; Abkhazia has only a Hi-Speed Boat.
package.preload['me_db_api'] = function()
    return {
        db = {
            Countries = {
                [1] = {
                    Name = 'USA',
                    Units = {
                        Ships  = { Ship = { { Name = 'CVN_71_Theodore_Roosevelt' } } },
                        Cars   = { Car  = { { Name = 'Hummer' } } },
                        Planes = { Plane = { { Name = 'F-16C_50' } } },
                    },
                },
                [2] = {
                    Name = 'Abkhazia',
                    Units = {
                        Ships = { Ship = { { Name = 'speedboat' } } },
                    },
                },
                [3] = {
                    Name = 'NoUnits',  -- well-formed but empty catalog
                    Units = {},
                },
            },
        },
    }
end

do
    -- Carrier under USA: empty missing list (USA has it).
    local prefab = {
        meta = {},
        groups = {
            { units = { { type = 'CVN_71_Theodore_Roosevelt' } } },
        },
    }
    local m = prefab_ops._find_missing_types(prefab, 'USA')
    check('USA supports carrier: no missing types', type(m) == 'table' and #m == 0,
          'got ' .. tostring(m and #m))
end

do
    -- Carrier under Abkhazia: the carrier type comes back as missing.
    local prefab = {
        meta = {},
        groups = {
            { units = { { type = 'CVN_71_Theodore_Roosevelt' } } },
        },
    }
    local m = prefab_ops._find_missing_types(prefab, 'Abkhazia')
    check('Abkhazia missing carrier: 1 missing type',
          type(m) == 'table' and #m == 1, 'got ' .. tostring(m and #m))
    check('Abkhazia missing carrier: name reported',
          m and m[1] == 'CVN_71_Theodore_Roosevelt')
end

do
    -- Multiple missing types come back sorted + de-duplicated.
    local prefab = {
        meta = {},
        groups = {
            { units = { { type = 'CVN_71_Theodore_Roosevelt' }, { type = 'F-16C_50' } } },
            { units = { { type = 'F-16C_50' } } },         -- duplicate; should not be repeated
            { units = { { type = 'Hummer' } } },           -- USA has it; Abkhazia doesn't
        },
        statics = {
            { units = { { type = 'CVN_71_Theodore_Roosevelt' } } },  -- duplicate, walks statics too
        },
    }
    local m = prefab_ops._find_missing_types(prefab, 'Abkhazia')
    check('multi-missing: 3 unique entries', type(m) == 'table' and #m == 3,
          'got ' .. tostring(m and #m))
    check('multi-missing: sorted alphabetically',
          m[1] == 'CVN_71_Theodore_Roosevelt' and m[2] == 'F-16C_50' and m[3] == 'Hummer',
          'got ' .. table.concat(m or {}, ', '))
end

do
    -- Unknown country in DB: nil (caller should treat as "skip the check").
    local prefab = { meta = {}, groups = { { units = { { type = 'Hummer' } } } } }
    local m = prefab_ops._find_missing_types(prefab, 'Atlantis')
    check('unknown country returns nil', m == nil)
end

do
    -- Empty / nil country name: nil.
    check('nil country returns nil',
          prefab_ops._find_missing_types({ meta = {}, groups = {} }, nil) == nil)
    check('empty country returns nil',
          prefab_ops._find_missing_types({ meta = {}, groups = {} }, '') == nil)
end

do
    -- Country with empty Units catalog: every type is missing.
    local prefab = {
        meta = {},
        groups = { { units = { { type = 'CVN_71_Theodore_Roosevelt' } } } },
    }
    local m = prefab_ops._find_missing_types(prefab, 'NoUnits')
    check('empty catalog: all types reported missing',
          type(m) == 'table' and #m == 1 and m[1] == 'CVN_71_Theodore_Roosevelt')
end

-- ---------------------------------------------------------------------------
-- _remap_ids: rewrite stale source unit/group ids inside a placed group to
-- the new ids allocated for the same prefab. Driven by the carrier-test bug
-- where statics linked to the carrier (linkUnit.unitId), aircraft starting
-- on the carrier (helipadId), the carrier's own beacon tasks (ActivateBeacon
-- unitId), Link 16 datalinks (missionUnitId), and Escort/EPLRS task params
-- (groupId) all kept the source-mission ids and broke at runtime.
--
-- Maps are { [old_id] = new_id }. Anything not in the map is treated as a
-- truly cross-mission reference and gets nilled (matches the pre-fix safety
-- behavior for fields that were nilled unconditionally).
-- ---------------------------------------------------------------------------
do
    local uid_map = { [225] = 14, [226] = 4, [227] = 5, [228] = 6, [229] = 7, [234] = 1 }
    local gid_map = { [698] = 50, [700] = 51 }

    -- Carrier-style group: the unit's own unitId remaps to its new value.
    local carrier = {
        groupId = 698,
        units = { { unitId = 225, type = 'CVN_71_Theodore_Roosevelt' } },
        route = {
            points = {
                [1] = {
                    task = {
                        params = {
                            tasks = {
                                [1] = { id = 'WrappedAction', params = {
                                    action = { id = 'ActivateBeacon', params = { unitId = 225 } } } },
                                [2] = { id = 'WrappedAction', params = {
                                    action = { id = 'ActivateICLS', params = { unitId = 225 } } } },
                            },
                        },
                    },
                },
            },
        },
    }
    prefab_ops._remap_ids(carrier, uid_map, gid_map, { keep_airdrome_ids = false })
    check('remap: carrier groupId 698→50', carrier.groupId == 50, 'got ' .. tostring(carrier.groupId))
    check('remap: carrier unit unitId 225→14', carrier.units[1].unitId == 14,
          'got ' .. tostring(carrier.units[1].unitId))
    check('remap: ActivateBeacon unitId 225→14',
          carrier.route.points[1].task.params.tasks[1].params.action.params.unitId == 14)
    check('remap: ActivateICLS unitId 225→14',
          carrier.route.points[1].task.params.tasks[2].params.action.params.unitId == 14)

    -- Static linked to the carrier: route.points[1].linkUnit.unitId remaps.
    local static = {
        groupId = 234,                      -- not in gid_map; nil out
        linkOffset = true,
        units = { { unitId = 234, type = 'AS32-31A' } },
        route = {
            points = {
                [1] = {
                    helipadId = 225,        -- ref to carrier
                    linkUnit = { unitId = 225, alt = 0, frequency = 127500000 },
                },
            },
        },
    }
    prefab_ops._remap_ids(static, uid_map, gid_map, { keep_airdrome_ids = false })
    check('remap: static linkUnit.unitId 225→14',
          static.route.points[1].linkUnit.unitId == 14)
    check('remap: static helipadId 225→14',
          static.route.points[1].helipadId == 14)
    check('remap: static.linkOffset preserved (not an id field)',
          static.linkOffset == true)
    check('remap: static.groupId not in map → nilled',
          static.groupId == nil)
    check('remap: static unit.unitId 234→1', static.units[1].unitId == 1)

    -- Aircraft starting on the carrier: TakeOffParking with helipadId + linkUnit.
    -- Datalink network has missionUnitId references to its own flight members.
    local aircraft = {
        groupId = 698,                      -- not the carrier's group; coincidence — both 698 in source
        units = {
            { unitId = 226, type = 'FA-18C_hornet', datalinks = { Link16 = { network = { teamMembers = {
                [1] = { missionUnitId = 226 },
                [2] = { missionUnitId = 227 },
                [3] = { missionUnitId = 228 },
                [4] = { missionUnitId = 229 },
            } } } } },
        },
        route = {
            points = {
                [1] = {
                    type = 'TakeOffParking',
                    helipadId = 225,
                    linkUnit = { unitId = 225 },
                    airdromeId = 12,        -- map airbase id; behaviour depends on opts
                },
            },
        },
    }
    prefab_ops._remap_ids(aircraft, uid_map, gid_map, { keep_airdrome_ids = false })
    check('remap: aircraft helipadId 225→14',
          aircraft.route.points[1].helipadId == 14)
    check('remap: aircraft linkUnit.unitId 225→14',
          aircraft.route.points[1].linkUnit.unitId == 14)
    check('remap: aircraft Link16 missionUnitId[1] 226→4',
          aircraft.units[1].datalinks.Link16.network.teamMembers[1].missionUnitId == 4)
    check('remap: aircraft Link16 missionUnitId[4] 229→7',
          aircraft.units[1].datalinks.Link16.network.teamMembers[4].missionUnitId == 7)
    check('remap: airdromeId nilled when keep_airdrome_ids=false',
          aircraft.route.points[1].airdromeId == nil)

    -- airdromeId preserved when keep_airdrome_ids=true (place at original anchor).
    local aircraft2 = {
        groupId = 700, units = { { unitId = 226 } },
        route = { points = { [1] = { airdromeId = 12 } } },
    }
    prefab_ops._remap_ids(aircraft2, uid_map, gid_map, { keep_airdrome_ids = true })
    check('remap: airdromeId preserved when keep_airdrome_ids=true',
          aircraft2.route.points[1].airdromeId == 12)

    -- Escort task: route.points[].task.params.tasks[].params.groupId is a
    -- reference to the bombers; remap via gid_map.
    local viper_escort = {
        groupId = 700,                      -- in gid_map → remaps to 51
        units = { { unitId = 226 } },
        route = {
            points = {
                [1] = {
                    task = { params = { tasks = {
                        [1] = { id = 'ControlledTask', params = {
                            task = { id = 'Escort', params = { groupId = 698 } } } },
                    } } },
                },
            },
        },
    }
    prefab_ops._remap_ids(viper_escort, uid_map, gid_map, { keep_airdrome_ids = false })
    check('remap: Escort task groupId 698→50',
          viper_escort.route.points[1].task.params.tasks[1].params.task.params.groupId == 50)
    check('remap: viper_escort own groupId 700→51',
          viper_escort.groupId == 51)

    -- EPLRS task: action.params.groupId is also a group reference.
    local eplrs = {
        groupId = 700, units = { { unitId = 226 } },
        route = { points = { [1] = { task = { params = { tasks = {
            [1] = { id = 'WrappedAction', params = {
                action = { id = 'EPLRS', params = { value = true, groupId = 698 } } } },
        } } } } } },
    }
    prefab_ops._remap_ids(eplrs, uid_map, gid_map, { keep_airdrome_ids = false })
    check('remap: EPLRS groupId 698→50',
          eplrs.route.points[1].task.params.tasks[1].params.action.params.groupId == 50)

    -- Cross-mission reference (id not in any map): nil it. Matches pre-fix
    -- safety for linkUnit/helipadId.
    local stale = {
        groupId = 9999,                     -- not in gid_map
        units = { { unitId = 9998 } },      -- not in uid_map
        route = { points = { [1] = {
            helipadId = 12345,              -- not in uid_map → nil
            linkUnit  = { unitId = 12345 }, -- inner unitId nilled; rest of linkUnit kept
        } } },
    }
    prefab_ops._remap_ids(stale, uid_map, gid_map, { keep_airdrome_ids = false })
    check('remap: stale groupId nilled', stale.groupId == nil)
    check('remap: stale unit.unitId nilled', stale.units[1].unitId == nil)
    check('remap: stale helipadId nilled', stale.route.points[1].helipadId == nil)
    check('remap: stale linkUnit.unitId nilled',
          stale.route.points[1].linkUnit and stale.route.points[1].linkUnit.unitId == nil)

    -- Robust against missing route / units (statics-only minimal shape).
    local minimal = { groupId = 234, units = nil, route = nil }
    prefab_ops._remap_ids(minimal, uid_map, gid_map, {})
    check('remap: minimal group (no route, no units) does not error',
          minimal.groupId == nil)  -- 234 is in uid_map but not gid_map → nil

    -- Idempotent: a second pass over already-remapped data is a no-op (new
    -- ids are not in the maps, so nothing matches).
    local twice = {
        groupId = 698,
        units = { { unitId = 225 } },
        route = { points = { [1] = { linkUnit = { unitId = 225 } } } },
    }
    prefab_ops._remap_ids(twice, uid_map, gid_map, {})
    prefab_ops._remap_ids(twice, uid_map, gid_map, {})
    check('remap: idempotent — groupId stays at new value 50', twice.groupId == 50)
    check('remap: idempotent — unit.unitId stays at new value 14', twice.units[1].unitId == 14)
    check('remap: idempotent — linkUnit.unitId stays at new value 14',
          twice.route.points[1].linkUnit.unitId == 14)
end

-- ---------------------------------------------------------------------------
-- GH#57: when a source id overlaps a freshly-allocated destination id (which
-- always happens placing into a fresh mission, where getNewUnitId starts at
-- 1 and source ids also start near 1), the remap MUST still rewrite — the
-- pre-fix `is_new_uid` guard incorrectly treated source-side values that
-- happened to also be dest-side values as "already remapped" and skipped
-- them. Result: two placed groups landed on the same final unitId, and
-- Mission.unit_by_id[id] = whichever was injected second; the first became
-- a "ghost" — invisible to the marquee hit-test, which iterates unit_by_id.
-- ---------------------------------------------------------------------------
do
    -- Overlap scenario: source id 10 is also the destination for source 99.
    --   uid_map = { [10] = 50, [99] = 10 }
    -- A unit whose source unitId is 10 must be remapped to 50, not preserved
    -- as 10. (Pre-fix: is_new_uid[10]=true → skip → unit.unitId stays at 10.)
    local uid_map = { [10] = 50, [99] = 10 }
    local gid_map = {}
    local g = { units = { { unitId = 10 } } }
    prefab_ops._remap_ids(g, uid_map, gid_map, {})
    check('GH#57: source unitId 10 (also a dest value) remaps to 50, not preserved as 10',
          g.units[1].unitId == 50, 'got ' .. tostring(g.units[1].unitId))

    -- Same shape for groupId. Source 10 is also dest for source 99.
    local uid_map_b = {}
    local gid_map_b = { [10] = 50, [99] = 10 }
    local g_b = { groupId = 10 }
    prefab_ops._remap_ids(g_b, uid_map_b, gid_map_b, {})
    check('GH#57: source groupId 10 (also a dest value) remaps to 50, not preserved as 10',
          g_b.groupId == 50, 'got ' .. tostring(g_b.groupId))

    -- Pass-D-style: two source units, source ids overlap dest values.
    -- Both must end up with DIFFERENT final unitIds (no collision in the
    -- caller's downstream Mission.unit_by_id[uid] = unit assignment).
    local uid_map_c = { [10] = 50, [99] = 10 }
    local gid_map_c = {}
    local unit_a = { unitId = 10 }   -- source 10 → expect 50
    local unit_b = { unitId = 99 }   -- source 99 → expect 10
    prefab_ops._remap_ids({ units = { unit_a } }, uid_map_c, gid_map_c, {})
    prefab_ops._remap_ids({ units = { unit_b } }, uid_map_c, gid_map_c, {})
    check('GH#57: two units with overlapping ids end up with distinct dest ids',
          unit_a.unitId ~= unit_b.unitId,
          'unit_a=' .. tostring(unit_a.unitId) .. ' unit_b=' .. tostring(unit_b.unitId))
    check('GH#57: unit_a (source 10) remaps to 50',
          unit_a.unitId == 50, 'got ' .. tostring(unit_a.unitId))
    check('GH#57: unit_b (source 99) remaps to 10',
          unit_b.unitId == 10, 'got ' .. tostring(unit_b.unitId))
end

-- ---------------------------------------------------------------------------
-- M.place drawing-cache resync (regression for "placed prefab drawing vanishes
-- on save unless clicked in the Draw panel").
--
-- The ME serializer (me_mission.unload) reads mission.drawings — a CACHE — not
-- me_draw_panel.saveToMission() live. Prefab placement injects drawings via
-- panel.copyObjToCoord, which adds to the panel's live layers_ (so it renders)
-- but does NOT refresh mission.drawings. Without a resync, a placed drawing is
-- dropped on save. M.place must commit the live draw state back into
-- mission.drawings (mirroring ED's own `mission.drawings = saveToMission()`).
--
-- Mocks me_mission (just the .mission cache table) and me_draw_panel
-- (copyObjToCoord appends to a live list; saveToMission snapshots it) by
-- seeding package.loaded so M.place's lazy requires pick them up.
-- ---------------------------------------------------------------------------
do
    -- Live draw-panel state: copyObjToCoord pushes here, saveToMission reads it.
    local drawn = {}
    local panel = {
        copyObjToCoord = function(obj, x, y)
            local newObj = {}
            for k, v in pairs(obj) do newObj[k] = v end
            newObj._placed_x, newObj._placed_y = x, y
            table.insert(drawn, newObj)
            return newObj
        end,
        saveToMission = function()
            -- Mirror ED: walk the live state into a fresh layered table.
            local objects = {}
            for i, o in ipairs(drawn) do objects[i] = { name = o.name } end
            return { layers = { { name = 'Common', objects = objects } } }
        end,
    }
    -- Stale cache: a pre-existing mission.drawings WITHOUT the placed drawing.
    local me_mission_mock = { mission = { drawings = { layers = {}, _stale = true } } }

    package.loaded['me_mission']    = me_mission_mock
    package.loaded['me_draw_panel'] = panel

    local function cache_has_drawing(cache, name)
        if type(cache) ~= 'table' or type(cache.layers) ~= 'table' then return false end
        for _, l in ipairs(cache.layers) do
            for _, o in ipairs(l.objects or {}) do
                if o.name == name then return true end
            end
        end
        return false
    end

    local prefab = {
        meta = { name = 'DrawOnly', sms_prefab_version = '0.5.0',
                 world_anchor = { x = 1000, y = 2000 } },
        groups = {}, statics = {}, zones = {},
        drawings = {
            { name = 'TestCircle', primitiveType = 'Polygon', polygonMode = 'circle',
              mapData = { x = 0, y = 0, radius = 500 } },
        },
    }

    local rec, err = prefab_ops.place(prefab, { anchor = { x = 5000, y = 6000 }, rotation = 0 })
    check('place drawings-only: returns a record', type(rec) == 'table',
          'got ' .. tostring(rec) .. ' / ' .. tostring(err))
    check('place drawings-only: one drawing injected',
          rec and #rec.drawings == 1, 'got ' .. tostring(rec and #rec.drawings))
    -- The regression assertion: the placed drawing must be present in the
    -- cached mission.drawings the serializer reads. Pre-fix this stays stale.
    check('place drawings-only: mission.drawings cache holds the placed drawing',
          cache_has_drawing(me_mission_mock.mission.drawings, 'TestCircle'),
          'cache was not resynced from the live draw panel after placement')
    check('place drawings-only: stale cache marker was replaced',
          me_mission_mock.mission.drawings._stale == nil,
          'mission.drawings still points at the stale pre-place table')
end

if failures > 0 then
    print(string.format('%d failure(s)', failures))
    os.exit(1)
end
print('All prefab_ops place tests passed.')
