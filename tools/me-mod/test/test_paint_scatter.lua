-- test_paint_scatter.lua — unit tests for the pure scatter core.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local scatter = require('dcs_sms_me.paint_scatter')
local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

local PALETTE = {
    { kind = 'static', type = 'Oil Barrel', shape_name = 'M92_Oilbarrel', category = 'Structures', weight = 1 },
}

local function dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

-- ---------------------------------------------------------------------------
-- Construction validation
-- ---------------------------------------------------------------------------
do
    local s, err = scatter.new_session({})
    check('rejects missing radius', s == nil and type(err) == 'string', tostring(err))
end
do
    local s, err = scatter.new_session({ radius = 50, density = 1, palette = {} })
    check('rejects empty palette', s == nil and type(err) == 'string', tostring(err))
end
do
    local s, err = scatter.new_session({
        radius = 50, density = 1,
        palette = { { type = 'A', weight = 0 } },
    })
    check('rejects zero total weight', s == nil and type(err) == 'string', tostring(err))
end
do
    local s = scatter.new_session({ radius = 50, density = 1, palette = PALETTE, seed = 1 })
    check('constructs with valid opts', s ~= nil)
end

-- ---------------------------------------------------------------------------
-- Determinism: same seed + same stroke → identical placements
-- ---------------------------------------------------------------------------
do
    local function run()
        local s = scatter.new_session({
            radius = 30, density = 1, min_spacing = 2, palette = PALETTE, seed = 42,
        })
        local out = {}
        for _, p in ipairs({ {0,0}, {25,0}, {50,5}, {75,10} }) do
            local placed = s:step(p[1], p[2])
            for _, q in ipairs(placed) do out[#out+1] = q end
        end
        return out
    end
    local a, b = run(), run()
    local same = #a == #b and #a > 0
    if same then
        for i = 1, #a do
            if a[i].x ~= b[i].x or a[i].y ~= b[i].y or a[i].heading_deg ~= b[i].heading_deg
               or a[i].type ~= b[i].type then same = false; break end
        end
    end
    check('seeded runs identical', same, #a .. ' vs ' .. #b)
end

-- ---------------------------------------------------------------------------
-- Density without spacing: one blob → count ≈ density * area / 100 (±1)
-- ---------------------------------------------------------------------------
do
    local R, D = 40, 1.0
    local s = scatter.new_session({ radius = R, density = D, min_spacing = 0, palette = PALETTE, seed = 7 })
    local placed = s:step(0, 0)
    local expected = D * math.pi * R * R / 100  -- ≈ 50.3
    check('density count ±1', math.abs(#placed - expected) <= 1, #placed .. ' vs ' .. expected)
end

-- ---------------------------------------------------------------------------
-- All placements within radius of the brush position
-- ---------------------------------------------------------------------------
do
    local R = 25
    local s = scatter.new_session({ radius = R, density = 2, palette = PALETTE, seed = 3 })
    local placed = s:step(100, -200)
    local ok = #placed > 0
    for _, p in ipairs(placed) do
        if dist(p, { x = 100, y = -200 }) > R + 1e-9 then ok = false break end
    end
    check('placements inside brush circle', ok, #placed .. ' placed')
end

-- ---------------------------------------------------------------------------
-- min_spacing respected across the whole stroke (brute force)
-- ---------------------------------------------------------------------------
do
    local SP = 6
    local s = scatter.new_session({ radius = 30, density = 5, min_spacing = SP, palette = PALETTE, seed = 11 })
    local all = {}
    for _, p in ipairs({ {0,0}, {20,0}, {40,0}, {60,20} }) do
        for _, q in ipairs(s:step(p[1], p[2])) do all[#all+1] = q end
    end
    local ok = #all > 0
    for i = 1, #all do
        for j = i + 1, #all do
            if dist(all[i], all[j]) < SP - 1e-9 then ok = false end
        end
    end
    check('min_spacing holds stroke-wide', ok, #all .. ' placed')
end

-- ---------------------------------------------------------------------------
-- Re-sweeping the same spot does not re-saturate
-- ---------------------------------------------------------------------------
do
    local s = scatter.new_session({ radius = 30, density = 2, palette = PALETTE, seed = 5 })
    local first = s:step(0, 0)
    local second = s:step(0, 0)
    check('same-spot second step places nothing', #first > 0 and #second == 0,
          #first .. ' then ' .. #second)
end
do
    -- Loop back onto an earlier (non-last) brush position: also no re-saturation.
    local s = scatter.new_session({ radius = 30, density = 2, palette = PALETTE, seed = 6 })
    local a = s:step(0, 0)
    s:step(200, 0)   -- far away, disjoint
    local c = s:step(0, 0)
    check('looping back onto old ground places nothing', #a > 0 and #c == 0,
          #a .. ' then ' .. #c)
end

-- ---------------------------------------------------------------------------
-- Weighted palette: weights honored (3:1 within loose bounds), zero weight never picked
-- ---------------------------------------------------------------------------
do
    local pal = {
        { type = 'A', weight = 3 },
        { type = 'B', weight = 1 },
        { type = 'C', weight = 0 },
    }
    local s = scatter.new_session({ radius = 60, density = 3, min_spacing = 0, palette = pal, seed = 13 })
    local counts = { A = 0, B = 0, C = 0 }
    local placed = s:step(0, 0)
    for _, p in ipairs(placed) do counts[p.type] = counts[p.type] + 1 end
    local total = counts.A + counts.B + counts.C
    local ratio = counts.A / math.max(counts.B, 1)
    check('zero-weight type never picked', counts.C == 0, counts.C)
    check('weights roughly honored', total > 100 and ratio > 1.8 and ratio < 4.5,
          string.format('A=%d B=%d ratio=%.2f', counts.A, counts.B, ratio))
end

-- ---------------------------------------------------------------------------
-- Heading policies
-- ---------------------------------------------------------------------------
do
    local s = scatter.new_session({ radius = 40, density = 1, palette = PALETTE, heading = 135, seed = 17 })
    local placed = s:step(0, 0)
    local ok = #placed > 0
    for _, p in ipairs(placed) do if p.heading_deg ~= 135 then ok = false end end
    check('fixed heading applied', ok)
end
do
    local s = scatter.new_session({ radius = 40, density = 2, palette = PALETTE, heading = 'random', seed = 19 })
    local placed = s:step(0, 0)
    local in_range, varied = #placed > 1, false
    for _, p in ipairs(placed) do
        if p.heading_deg < 0 or p.heading_deg >= 360 then in_range = false end
        if p.heading_deg ~= placed[1].heading_deg then varied = true end
    end
    check('random headings in [0,360) and varied', in_range and varied)
end

-- ---------------------------------------------------------------------------
-- existing_points block placements within min_spacing
-- ---------------------------------------------------------------------------
do
    local SP = 10
    local s = scatter.new_session({
        radius = 20, density = 5, min_spacing = SP, palette = PALETTE, seed = 23,
        existing_points = { { x = 0, y = 0 } },
    })
    local placed = s:step(0, 0)
    local ok = true
    for _, p in ipairs(placed) do
        if dist(p, { x = 0, y = 0 }) < SP - 1e-9 then ok = false end
    end
    check('existing points enforce spacing', ok, #placed .. ' placed')
end

-- ---------------------------------------------------------------------------
-- Unseeded session still works (no crash, sane output)
-- ---------------------------------------------------------------------------
do
    local s = scatter.new_session({ radius = 30, density = 1, palette = PALETTE })
    local placed = s:step(0, 0)
    check('unseeded session places', #placed > 0, #placed)
end

if failures > 0 then os.exit(1) end
print('All paint_scatter tests passed.')
