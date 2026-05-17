-- mass_edit_ops.lua — apply pipeline for the Mass Edit tool.
--
-- compute_plan(scope, checked, parent_map, property_id, operation, op_args)
--   → plan{ property_id, operation, op_args, rows[], affected_groups[], error? }
-- apply_plan(plan) → summary{ changed, failed, errors[], affected_groups[] }
--
-- compute_plan is pure (no mutation): it reads current values, applies the
-- selected transform to derive new values, runs the registry's optional
-- preflight, and returns the resulting plan. apply_plan walks the plan and
-- calls each property's writer under pcall, refreshes affected group views
-- once, and registers an undo snapshot via the 'mass_edit' handler on
-- undo.lua.

local registry   = require('dcs_sms_me.mass_edit_registry')
local transforms = require('dcs_sms_me.mass_edit_transforms')

local M = {}

local DCS_CATEGORIES = { plane = true, helicopter = true, vehicle = true, ship = true, static = true }

-- Index the registry by id for O(1) lookup.
local by_id = {}
for _, e in ipairs(registry) do by_id[e.id] = e end

-- Public for tests / introspection.
function M.find(id) return by_id[id] end

-- Determine the DCS category of an entity by looking at its parent group's
-- bucket. The mock and the real ME both shape the data the same way: a
-- group sits inside country.<category>.group, and units / waypoints are
-- nested inside the group. The category isn't stored on the group itself,
-- so we ask the caller for it via parent_map (which always points at the
-- group regardless of entity scope).
local function group_category(g)
    -- Try the explicit category field if present (set by some flows).
    if g and DCS_CATEGORIES[g.category] then return g.category end
    -- Fall back: walk the mission tree once to locate the group's bucket.
    local Mission = require('me_mission')
    local mission = Mission and Mission.mission
    if not mission or type(mission.coalition) ~= 'table' then return nil end
    for _, side in pairs(mission.coalition) do
        if type(side) == 'table' and type(side.country) == 'table' then
            for _, country in ipairs(side.country) do
                for cat, _ in pairs(DCS_CATEGORIES) do
                    local bucket = country[cat]
                    if type(bucket) == 'table' and type(bucket.group) == 'table' then
                        for _, gg in ipairs(bucket.group) do
                            if gg == g then return cat end
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- Check whether an entity's category is permitted by entry.applies_to.
-- '*' means any. Returns ok, reason.
local function category_allowed(entry, category)
    for _, c in ipairs(entry.applies_to) do
        if c == '*' or c == category then return true end
    end
    return false, 'category mismatch: ' .. tostring(category)
end

-- Sort row order for auto_number / preview consistency. ordering arg
-- comes from op_args.order; defaults to 'name_asc'. Other supported
-- values: 'selection', 'pos_north_south', 'pos_west_east'. Sorting is
-- stable (Lua table.sort is not stable, so we tag each row with its
-- selection index and break ties by it).
local function sort_rows_for_plan(rows, order)
    order = order or 'name_asc'
    if order == 'selection' then return rows end

    for i, r in ipairs(rows) do r._sel_idx = i end

    local sort_fn
    if order == 'name_asc' then
        sort_fn = function(a, b)
            local an = tostring(a.entity.name or '')
            local bn = tostring(b.entity.name or '')
            if an == bn then return a._sel_idx < b._sel_idx end
            return an < bn
        end
    elseif order == 'pos_north_south' then
        sort_fn = function(a, b)
            local ax = a.entity.x or (a.group and a.group.x) or 0
            local bx = b.entity.x or (b.group and b.group.x) or 0
            if ax == bx then return a._sel_idx < b._sel_idx end
            return ax > bx
        end
    elseif order == 'pos_west_east' then
        sort_fn = function(a, b)
            local ay = a.entity.y or (a.group and a.group.y) or 0
            local by = b.entity.y or (b.group and b.group.y) or 0
            if ay == by then return a._sel_idx < b._sel_idx end
            return ay < by
        end
    else
        return rows
    end

    table.sort(rows, sort_fn)
    for _, r in ipairs(rows) do r._sel_idx = nil end
    return rows
end

function M.compute_plan(scope, checked_entities, parent_map, property_id, operation, op_args)
    local entry = by_id[property_id]
    if not entry then
        return { property_id = property_id, operation = operation, op_args = op_args,
                 rows = {}, affected_groups = {},
                 error = 'unknown property: ' .. tostring(property_id) }
    end
    if entry.scope ~= scope then
        return { property_id = property_id, operation = operation, op_args = op_args,
                 rows = {}, affected_groups = {},
                 error = 'property ' .. property_id .. ' belongs to scope ' .. entry.scope ..
                         ', not ' .. tostring(scope) }
    end
    local transform = transforms[operation]
    if not transform then
        return { property_id = property_id, operation = operation, op_args = op_args,
                 rows = {}, affected_groups = {},
                 error = 'unknown operation: ' .. tostring(operation) }
    end

    -- Build rows, then sort for the transform.
    local rows = {}
    for _, entity in ipairs(checked_entities) do
        local group = parent_map and parent_map[entity] or entity
        rows[#rows + 1] = { entity = entity, group = group, old = nil, new = nil, ok = true, error = nil }
    end
    rows = sort_rows_for_plan(rows, op_args and op_args.order)

    -- Pre-compute current value + transform + preflight, in plan order.
    local ctx = {}
    for idx, row in ipairs(rows) do
        local entity = row.entity
        local group  = row.group

        local needs_cat_check = (scope == 'group' or scope == 'unit' or scope == 'waypoint')
        if needs_cat_check then
            local cat = group_category(group)
            local ok, reason = category_allowed(entry, cat or 'unknown')
            if not ok then
                row.ok = false; row.error = reason
            end
        end

        row.old = entry.reader(entity)
        if row.ok then
            row.new = transform(row.old, op_args or {}, idx)
            if operation == 'toggle_set' and row.new == nil then
                row.ok = false; row.error = 'leave unchanged'
            elseif entry.preflight then
                local pf_ok, pf_err = entry.preflight(entity, row.new, ctx)
                if not pf_ok then
                    row.ok = false; row.error = pf_err or 'preflight failed'
                end
            end
        end
    end

    local seen, affected = {}, {}
    for _, r in ipairs(rows) do
        if r.ok and r.group and not seen[r.group] then
            seen[r.group] = true
            affected[#affected + 1] = r.group
        end
    end

    return {
        property_id     = property_id,
        operation       = operation,
        op_args         = op_args,
        rows            = rows,
        affected_groups = affected,
    }
end

-- apply_plan is added in the next task. Stub here so the module load
-- doesn't fail when tests call it.
function M.apply_plan(plan)
    return { changed = 0, failed = 0, errors = {}, affected_groups = {}, error = 'not implemented' }
end

return M
