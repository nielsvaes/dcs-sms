-- paint_scatter.lua — the pure, deterministic scatter core for Paint Statics.
--
-- No dxgui, no ME APIs — plain Lua 5.1 so it runs under the test harness
-- and can be driven headlessly. A "session" is one brush stroke: feed it
-- brush positions along the drag via session:step(x, y); each step returns
-- the list of new placements for that brush blob.
--
-- Density definition: target objects per 100 m² of ground (a 10×10 m
-- square). A step at a fresh position with radius R tries
-- density·πR²/100 candidate points, uniform in the brush circle.
--
-- Re-saturation control: candidates that fall inside ANY previously swept
-- brush circle of this stroke are rejected. Because candidate count is
-- proportional to the full circle area and the rejection removes exactly
-- the already-swept fraction, the expected yield per step is
-- density·(newly covered area)/100 with no lens-overlap math — unbiased
-- and O(1) per candidate via two spatial hashes:
--   * accepted-point grid, cell = min_spacing (3×3 scan ⇒ all points
--     within min_spacing)
--   * swept-center grid, cell = 2·radius (3×3 scan ⇒ all centers within
--     2R, and a candidate can only be inside a circle whose center is
--     within R+R of the brush position)
--
-- Randomness: math.random. When opts.seed is given, math.randomseed(seed)
-- runs at session creation so a stroke is reproducible; otherwise the RNG
-- is left as-is.
--
-- Public:
--   M.new_session(opts) → session | nil, err
--     opts.radius          brush radius, meters (required, > 0)
--     opts.density         objects per 100 m² (required, > 0)
--     opts.min_spacing     minimum distance between objects, meters (default 0)
--     opts.palette         non-empty list of rows { type, shape_name,
--                          category, weight, ... } — weight ≥ 0, total > 0.
--                          Rows are tagged records (kind='static' today;
--                          kind='prefab' reserved — see design brief D4).
--     opts.heading         'random' (default) or fixed degrees number
--     opts.seed            optional number for reproducible scatter
--     opts.existing_points optional list of {x=, y=} that count for
--                          min_spacing (e.g. statics painted by earlier
--                          strokes) but not as swept area
--   session:step(x, y) → list of { type, shape_name, category, x, y,
--                                  heading_deg, row }  (row = palette row)
--   session:count() → total placements this session

local M = {}

local Session = {}
Session.__index = Session

-- ---------------------------------------------------------------------------
-- Spatial hash helpers. Keys are 'cx:cy' strings (Lua 5.1 has no integer
-- pairs key without table nesting; string keys keep it flat and fast enough).
-- ---------------------------------------------------------------------------

local function grid_key(cx, cy)
    return cx .. ':' .. cy
end

local function grid_insert(grid, cell, x, y)
    local cx = math.floor(x / cell)
    local cy = math.floor(y / cell)
    local k = grid_key(cx, cy)
    local bucket = grid[k]
    if not bucket then bucket = {}; grid[k] = bucket end
    bucket[#bucket + 1] = { x = x, y = y }
end

-- True if any stored point lies within `dist` of (x, y). Scans the 3×3
-- cell neighborhood — sufficient when cell ≥ dist.
local function grid_has_within(grid, cell, x, y, dist)
    local cx = math.floor(x / cell)
    local cy = math.floor(y / cell)
    local d2 = dist * dist
    for ix = cx - 1, cx + 1 do
        for iy = cy - 1, cy + 1 do
            local bucket = grid[grid_key(ix, iy)]
            if bucket then
                for i = 1, #bucket do
                    local p = bucket[i]
                    local dx, dy = p.x - x, p.y - y
                    if dx * dx + dy * dy < d2 then return true end
                end
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Session
-- ---------------------------------------------------------------------------

function M.new_session(opts)
    if type(opts) ~= 'table' then return nil, 'opts must be a table' end
    local radius = tonumber(opts.radius)
    if not radius or radius <= 0 then return nil, 'radius must be a positive number' end
    local density = tonumber(opts.density)
    if not density or density <= 0 then return nil, 'density must be a positive number' end
    local min_spacing = tonumber(opts.min_spacing) or 0
    if min_spacing < 0 then min_spacing = 0 end

    if type(opts.palette) ~= 'table' or #opts.palette == 0 then
        return nil, 'palette must be a non-empty list'
    end
    local total_weight = 0
    for _, row in ipairs(opts.palette) do
        local w = tonumber(row.weight) or 0
        if w < 0 then return nil, 'palette weights must be >= 0' end
        total_weight = total_weight + w
    end
    if total_weight <= 0 then return nil, 'palette total weight must be > 0' end

    local heading = opts.heading
    if heading == nil then heading = 'random' end
    if heading ~= 'random' and type(heading) ~= 'number' then
        return nil, "heading must be 'random' or a degrees number"
    end

    if opts.seed ~= nil then
        math.randomseed(tonumber(opts.seed) or 0)
    end

    local self = setmetatable({
        radius       = radius,
        density      = density,
        min_spacing  = min_spacing,
        palette      = opts.palette,
        total_weight = total_weight,
        heading      = heading,
        -- accepted-point spatial hash (spacing). Cell must be ≥ min_spacing
        -- for the 3×3 scan to be exhaustive; 1 m floor avoids cell = 0.
        point_grid   = {},
        point_cell   = math.max(min_spacing, 1),
        -- swept brush centers (re-saturation control). Cell = 2R so the
        -- 3×3 scan covers every center within 2R of a candidate's blob.
        center_grid  = {},
        center_cell  = 2 * radius,
        placed_total = 0,
        -- carry-over of the fractional candidate budget between steps so
        -- low densities accumulate instead of rounding to zero forever
        _carry       = 0,
    }, Session)

    if type(opts.existing_points) == 'table' then
        for _, p in ipairs(opts.existing_points) do
            if type(p) == 'table' and type(p.x) == 'number' and type(p.y) == 'number' then
                grid_insert(self.point_grid, self.point_cell, p.x, p.y)
            end
        end
    end

    return self
end

-- Weighted random palette pick.
local function pick_row(self)
    local r = math.random() * self.total_weight
    local acc = 0
    for _, row in ipairs(self.palette) do
        acc = acc + (tonumber(row.weight) or 0)
        if r < acc then return row end
    end
    return self.palette[#self.palette]
end

local function pick_heading(self)
    if self.heading == 'random' then
        return math.random() * 360
    end
    return self.heading % 360
end

function Session:step(x, y)
    local placed = {}
    local R = self.radius

    -- Candidate budget for one full circle, with fractional carry-over.
    local budget = self.density * math.pi * R * R / 100 + self._carry
    local n = math.floor(budget)
    self._carry = budget - n

    for _ = 1, n do
        -- Uniform point in the brush circle.
        local r = R * math.sqrt(math.random())
        local a = math.random() * 2 * math.pi
        local px = x + r * math.cos(a)
        local py = y + r * math.sin(a)

        -- Reject if inside any previously swept blob (re-saturation control).
        if not grid_has_within(self.center_grid, self.center_cell, px, py, R) then
            -- Reject if too close to an accepted/existing point.
            if self.min_spacing <= 0
               or not grid_has_within(self.point_grid, self.point_cell, px, py, self.min_spacing) then
                local row = pick_row(self)
                placed[#placed + 1] = {
                    type        = row.type,
                    shape_name  = row.shape_name,
                    category    = row.category,
                    x           = px,
                    y           = py,
                    heading_deg = pick_heading(self),
                    row         = row,
                }
                grid_insert(self.point_grid, self.point_cell, px, py)
            end
        end
    end

    -- Mark this blob as swept AFTER generating, so the current circle
    -- doesn't reject its own candidates. Skip near-duplicate centers
    -- (stationary cursor) to keep buckets small; a center within R/10 of
    -- an existing one adds no meaningful new coverage.
    if not grid_has_within(self.center_grid, self.center_cell, x, y, R / 10) then
        grid_insert(self.center_grid, self.center_cell, x, y)
    end

    self.placed_total = self.placed_total + #placed
    return placed
end

function Session:count()
    return self.placed_total
end

return M
