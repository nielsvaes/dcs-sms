-- prefab_distill.lua — pure-data transform from ME selection dump to prefab.
--
-- This is a packaged-as-module mirror of framework/prefab_distill.lua.
-- The two MUST produce identical output for the same input — see
-- tools/me-mod/test/test_distill_parity.lua. The framework copy is
-- canonical; this copy adapts only the packaging (returns M instead of
-- setting sms.prefab.distill) and replaces the optional sms.K.statics
-- catalog with an internal table (currently empty; both must stay in sync).
--
-- No DCS dependencies — runnable in standalone Lua 5.1 for unit tests.
--
-- Public:
--   M.distill(dump_or_path, opts) → prefab_table | nil
--     opts.name    = string                  -- required; written to meta.name
--     opts.theatre = string?                 -- optional; written to meta.theatre
--     opts._log    = { warn=fn, error=fn }?  -- optional; injected logger
--                                            -- (default: silent no-op)

local M = {}

-- 0.2.0: distill no longer subtracts the centroid from polygon vertices
-- inside `drawing.mapData.points` (and other geometry sub-arrays). Files
-- saved at 0.1.0 had broken vertex deltas; me-mod's place path keeps a
-- compensating un-rebase shim for those, gated on this version field.
-- 0.4.0: prefabs may carry an optional `triggers` array plus
-- meta.resources (base64 media) and meta.flags_used. Loaders that
-- pre-date 0.4.0 ignore the extra keys; 0.4.0 loads older files
-- unchanged. See docs/superpowers/specs/2026-06-10-prefab-triggers-design.md.
-- 0.5.0: prefabs may carry an optional `meta.required_modules` map (module id
-- → { id, display_name, objects, count }), attached by the ME save path after
-- distill. Loaders that pre-date 0.5.0 ignore it; 0.5.0 loads older files
-- unchanged. See docs/superpowers/specs/2026-06-11-prefab-mod-dependencies-design.md.
-- 0.6.0: distill no longer rebases an Escort/Follow task's formation offset
-- (`params.pos` {x,y,z}) — it's a relative vector, not a world coordinate, and
-- subtracting the centroid corrupted the saved Distance/Elevation. Files saved
-- at ≤0.5.0 have the corrupted offset; me-mod's place path keeps a compensating
-- un-rebase shim for those (M._unrebase_task_pos), gated on this version field.
-- 0.7.0: distill no longer rebases a polygon ("quad") trigger zone's `points`
-- — they are vertices stored relative to the zone's own {x,y} centre, not world
-- coordinates, so subtracting the centroid corrupted them and place re-added
-- the drop anchor, leaving the polygon offset from its own centre by exactly
-- the placement delta. Files saved at ≤0.6.0 carry the corrupted vertices;
-- me-mod's place path keeps a compensating un-rebase shim for those
-- (M._unrebase_zone_points), gated on this version field.
local PREFAB_VERSION = "0.7.0"

-- Shape-inference catalog. Currently empty; mirrors framework's
-- sms.K.statics population (also currently empty). If the framework adds
-- entries, mirror them here and the parity test will catch any divergence.
local STATIC_TYPES = {}

local function rad_to_deg(r)
    return r * (180 / math.pi)
end

local function utc_now()
    return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

-- ME's TriggerZone class stores color as four separate fields — see
-- Mission/TriggerZone.lua:38 (`ModuleProperty.make4arg(M, 'setColor',
-- 'getColor', 'red', 'green', 'blue', 'alpha')`). The .miz format wraps
-- those into `color = {r, g, b, a}` (Mission/TriggerZoneData.lua:559).
-- Place-side inject_zone reads zone.color, so distill must normalise to
-- the .miz shape — strip_back_refs walks the live object via pairs() and
-- only sees the four separate fields. Without this, zones round-trip
-- through a prefab with the default (1,1,1,0.15) color regardless of
-- what the user actually set.
local function normalize_zone_color(z)
    if type(z) ~= 'table' then return end
    if z.color ~= nil then return end
    if type(z.red) == 'number' or type(z.green) == 'number'
        or type(z.blue) == 'number' or type(z.alpha) == 'number' then
        z.color = {
            z.red   or 1,
            z.green or 1,
            z.blue  or 1,
            z.alpha or 1,
        }
    end
end

local function is_static_entity(entry)
    if entry.units and entry.units[1] and STATIC_TYPES[entry.units[1].type] then
        return true
    end
    if entry.category and entry.dead ~= nil and not entry.route then
        return true
    end
    return false
end

local function strip_back_refs(value, visited)
    if type(value) ~= 'table' then return value end
    if visited[value] then return nil end
    visited[value] = true

    local out = {}
    local captured_country
    for k, v in pairs(value) do
        if k == 'boss' then
            -- Capture country before dropping. Real ME dumps have boss as
            -- the country object directly (boss.id is the country id,
            -- boss.name is e.g. "USA"). Synthetic test fixtures may use the
            -- older boss.country.id shape — accept both.
            if type(v) == 'table' then
                if type(v.id) == 'number' then
                    captured_country = v.id
                elseif type(v.country) == 'table' and type(v.country.id) == 'number' then
                    captured_country = v.country.id
                end
            end
            -- Drop the boss field entirely.
        elseif k == 'mapObjects' or k == 'targets' then
            -- Drop render-side caches. Two separate caches feed the same
            -- bug class:
            --
            --   * mapObjects — group-level widget cache (route line,
            --     waypoint icons, target zones). Holds widget ids and
            --     userObject back-pointers bound to a specific live
            --     mission.
            --   * targets — per-waypoint mark cache for zone-bearing
            --     tasks (Search Then Engage In Zone, AttackTargetsInZone,
            --     ...). me_action_map_objects rebuilds it via insert_target
            --     when the actions panel first shows the task.
            --
            -- Carrying either into a saved prefab leaves duplicate
            -- route / target-zone markers on placement (GH#56: dragging
            -- the Search Then Engage zone triangle moves the waypoint
            -- instead). The placement-side inject_group also resets both
            -- defensively for prefabs that pre-date this fix.
        else
            local cv, sub_country = strip_back_refs(v, visited)
            out[k] = cv
            if sub_country and not captured_country then
                captured_country = sub_country
            end
        end
    end

    visited[value] = nil
    return out, captured_country
end

local function convert_headings(t)
    if type(t) ~= 'table' then return end
    for k, v in pairs(t) do
        if k == 'heading' and type(v) == 'number' then
            t[k] = rad_to_deg(v)
        elseif type(v) == 'table' then
            convert_headings(v)
        end
    end
end

-- See framework/prefab_distill.lua for the comment block on why mapData
-- gets special-cased here. Both copies must stay in sync byte-for-byte
-- inside the function body so test_distill_parity stays green.
local function rebase_xy(t, ax, ay)
    if type(t) ~= 'table' then return end
    if type(t.x) == 'number' and type(t.y) == 'number' then
        t.x = t.x - ax
        t.y = t.y - ay
    end
    for k, v in pairs(t) do
        if type(v) == 'table' then
            if k == 'mapData' then
                if type(v.x) == 'number' and type(v.y) == 'number' then
                    v.x = v.x - ax
                    v.y = v.y - ay
                end
            elseif k == 'pos' and type(v.x) == 'number'
                    and type(v.y) == 'number' and type(v.z) == 'number' then
                -- Task-param formation offset (Escort/Follow etc.): a relative
                -- {x,y,z} vector in the escorted group's frame (Distance/
                -- Elevation/Interval), NOT a world coordinate. Rebasing its x/y
                -- corrupts the saved Distance/Elevation (Interval/z was spared
                -- only by sitting outside the {x,y} pair). Real map positions
                -- are pure 2D {x,y}; the numeric z is the tell. Leave untouched.
            else
                rebase_xy(v, ax, ay)
            end
        end
    end
end

-- Trigger-zone rebase. A polygon ("quad", type 2) zone stores its vertices in
-- `points` RELATIVE to the zone's own {x,y} centre — the same invariant
-- drawings keep for mapData — so only the centre may be rebased. Handing the
-- whole zone to rebase_xy subtracted the centroid from every vertex too, and
-- place then re-added the drop anchor, leaving the polygon offset from its own
-- centre by exactly the placement delta (the zone's circle icon, driven by
-- {x,y} alone, still landed correctly). Circle zones have no `points` and were
-- never affected. Handled here at the call site rather than by keying on
-- `points` inside rebase_xy, because other `points` arrays in a prefab DO hold
-- world coordinates (route waypoints, the unit-level threat-ring render cache)
-- and must keep being rebased.
local function rebase_zone(z, ax, ay)
    if type(z) ~= 'table' then return end
    local verts = z.points
    z.points = nil
    rebase_xy(z, ax, ay)
    z.points = verts
end

local function noop_log(...) end

function M.distill(dump_or_path, opts)
    opts = opts or {}
    local log_warn  = (opts._log and opts._log.warn)  or noop_log
    local log_error = (opts._log and opts._log.error) or noop_log

    if not opts.name or opts.name == '' then
        log_warn('distill: opts.name is required')
        return nil
    end

    local dump
    local source_dump_name
    if type(dump_or_path) == 'string' then
        local ok, result = pcall(dofile, dump_or_path)
        if not ok then
            log_error('distill: dofile failed for ' .. dump_or_path .. ': ' .. tostring(result))
            return nil
        end
        dump = result
        source_dump_name = dump_or_path:match('([^/\\]+)$') or dump_or_path
    elseif type(dump_or_path) == 'table' then
        dump = dump_or_path
    else
        log_warn('distill: dump must be a path string or table')
        return nil
    end

    if type(dump) ~= 'table' then
        log_warn('distill: dump did not load to a table')
        return nil
    end

    local raw_groups   = dump.groups   or {}
    local raw_statics  = dump.statics  or {}
    local raw_zones    = dump.zones    or {}
    local raw_drawings = dump.drawings or {}

    if #raw_groups == 0 and #raw_statics == 0 and #raw_zones == 0 and #raw_drawings == 0 then
        log_warn('distill: dump has no entities — nothing to distill')
        return nil
    end

    local clean_groups   = {}
    local clean_statics  = {}
    for _, entry in ipairs(raw_groups) do
        local cleaned, country = strip_back_refs(entry, {})
        if cleaned then
            if country and not cleaned.country then
                cleaned.country = country
            end
            if cleaned.units then
                for _, u in pairs(cleaned.units) do
                    if u and not u.country then u.country = country end
                end
            end
            if is_static_entity(cleaned) then
                clean_statics[#clean_statics + 1] = cleaned
            else
                clean_groups[#clean_groups + 1] = cleaned
            end
        end
    end
    for _, entry in ipairs(raw_statics) do
        local cleaned, country = strip_back_refs(entry, {})
        if cleaned then
            if country and not cleaned.country then
                cleaned.country = country
            end
            clean_statics[#clean_statics + 1] = cleaned
        end
    end
    local clean_zones = {}
    for _, z in ipairs(raw_zones) do
        local cleaned = strip_back_refs(z, {})
        if cleaned then
            normalize_zone_color(cleaned)
            clean_zones[#clean_zones + 1] = cleaned
        end
    end
    local clean_drawings = {}
    for _, d in ipairs(raw_drawings) do
        local cleaned = strip_back_refs(d, {})
        if cleaned then clean_drawings[#clean_drawings + 1] = cleaned end
    end

    local sum_x, sum_y, n = 0, 0, 0
    local function add_point(p)
        if type(p) == 'table' and type(p.x) == 'number' and type(p.y) == 'number' then
            sum_x = sum_x + p.x; sum_y = sum_y + p.y; n = n + 1
        end
    end
    for _, g in ipairs(clean_groups)   do add_point(g) end
    for _, s in ipairs(clean_statics)  do add_point(s) end
    for _, z in ipairs(clean_zones)    do add_point(z) end
    for _, d in ipairs(clean_drawings) do
        if d.mapData then add_point(d.mapData) else add_point(d) end
    end
    if n == 0 then
        log_warn('distill: no positionable entities — cannot anchor')
        return nil
    end
    local cx, cy = sum_x / n, sum_y / n

    for _, g in ipairs(clean_groups)   do rebase_xy(g, cx, cy) end
    for _, s in ipairs(clean_statics)  do rebase_xy(s, cx, cy) end
    for _, z in ipairs(clean_zones)    do rebase_zone(z, cx, cy) end
    for _, d in ipairs(clean_drawings) do rebase_xy(d, cx, cy) end

    for _, g in ipairs(clean_groups)   do convert_headings(g) end
    for _, s in ipairs(clean_statics)  do convert_headings(s) end

    local meta = {
        sms_prefab_version = PREFAB_VERSION,
        name               = opts.name,
        created_utc        = utc_now(),
        source_dump        = source_dump_name,
        world_anchor       = { x = cx, y = cy },
        theatre            = opts.theatre,
    }
    -- Only emit when set so older saves stay byte-stable on no-op resaves.
    if opts.place_at_origin == true then
        meta.place_at_origin = true
    end
    -- Optional per-airbase warehouse data captured by the marquee detect flow.
    -- We store the raw extracted entries verbatim — same shape DCS uses in the
    -- .miz `warehouses` file. Re-resolved by name on apply.
    if type(opts.airbases) == 'table' and #opts.airbases > 0 then
        meta.airbases = {}
        for i, ab in ipairs(opts.airbases) do
            if type(ab) == 'table' and type(ab.name) == 'string'
               and type(ab.warehouse) == 'table' then
                meta.airbases[#meta.airbases + 1] = {
                    name                    = ab.name,
                    airdrome_number_at_save = ab.airdrome_number_at_save,
                    warehouse               = ab.warehouse,
                }
            end
        end
        if #meta.airbases == 0 then meta.airbases = nil end
    end

    return {
        meta = meta,
        groups   = clean_groups,
        statics  = clean_statics,
        zones    = clean_zones,
        drawings = clean_drawings,
    }
end

return M
