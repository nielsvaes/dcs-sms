-- dcs-sms framework: prefab module (sms.prefab).
--
-- Public namespace for prefab management at runtime: load/save prefab
-- files, register them in an in-memory map, spawn instances at any anchor +
-- rotation + (optional) country override, and clean up via per-instance
-- handles or bulk destroy_all.
--
-- A prefab is a portable bundle of groups + statics + zones + drawings
-- distilled from an ME selection dump. See sms.prefab.distill (in
-- prefab_distill.lua) for the input side. See spec for the file format.
--
-- Loading order: sms.lua -> log.lua -> utils.lua -> constants.lua ->
-- group.lua -> unit.lua -> area.lua -> timer.lua -> rule.lua ->
-- group_spawn.lua -> static.lua -> events.lua -> weapon.lua -> task.lua ->
-- commands.lua -> options.lua -> utils_serialize.lua -> prefab_distill.lua ->
-- prefab.lua.
--
-- See docs/superpowers/specs/2026-05-03-sms-prefab-design.md.

assert(type(sms) == "table", "framework/sms.lua must be loaded first")
assert(type(sms.utils) == "table", "framework/utils.lua must be loaded first")
assert(type(sms.utils.serialize) == "function", "framework/utils_serialize.lua must be loaded first")
assert(type(sms.constants) == "table" or type(sms.K) == "table", "framework/constants.lua must be loaded first")
assert(type(sms.prefab) == "table" and type(sms.prefab.distill) == "function", "framework/prefab_distill.lua must be loaded first")

local log = sms.log.module("sms.prefab")

-- ---------------------------------------------------------------------------
-- Module-private state
-- ---------------------------------------------------------------------------

local _registry = {}    -- name -> template_table
local _instances = {}   -- id -> handle
local _next_instance_id = 1

-- ---------------------------------------------------------------------------
-- Math helpers (pure; unit-testable separately if desired).
-- Exposed under sms.prefab._<name> so the smoke tests can poke them.
-- ---------------------------------------------------------------------------

-- Rotate a point (x, y) around origin (0, 0) by rotation_deg degrees,
-- clockwise from north (DCS convention).
function sms.prefab._rotate_xy(x, y, rotation_deg)
    if not rotation_deg or rotation_deg == 0 then return x, y end
    local r = rotation_deg * (math.pi / 180)
    local c, s = math.cos(r), math.sin(r)
    return x * c - y * s, x * s + y * c
end

-- Resolve a vec2/vec3-shaped anchor into (x, z). Spec: caller passes
-- {x = world_x, z = world_y} (DCS world coords; framework convention 2D-y =
-- 3D-z). Also accepts {x, y} for 2D callers.
function sms.prefab._anchor_xy(anchor)
    if type(anchor) ~= 'table' then return nil end
    local ax = anchor.x
    local az = anchor.z or anchor.y
    if type(ax) ~= 'number' or type(az) ~= 'number' then return nil end
    return ax, az
end

-- ---------------------------------------------------------------------------
-- Registry: load / load_dir / save / unload / list / get / register
-- ---------------------------------------------------------------------------

function sms.prefab.load(path)
    if type(path) ~= 'string' or path == '' then
        log.warn('load: path required')
        return nil
    end
    local ok, result = pcall(dofile, path)
    if not ok then
        log.error('load: dofile failed for ' .. path .. ': ' .. tostring(result))
        return nil
    end
    if type(result) ~= 'table' or type(result.meta) ~= 'table' or type(result.meta.name) ~= 'string' then
        log.warn('load: file at ' .. path .. ' has no meta.name')
        return nil
    end
    if _registry[result.meta.name] then
        log.warn("load: overwriting prefab '" .. result.meta.name .. "'")
    end
    _registry[result.meta.name] = result
    return result
end

function sms.prefab.load_dir(dir)
    if type(dir) ~= 'string' or dir == '' then
        log.warn('load_dir: dir required')
        return 0
    end
    if not lfs then
        log.warn('load_dir: lfs not available — call sms.prefab.load(path) per file instead')
        return 0
    end
    local count = 0
    local function recurse(d)
        for entry in lfs.dir(d) do
            if entry ~= '.' and entry ~= '..' then
                local full = d .. '/' .. entry
                local attr = lfs.attributes(full)
                if attr and attr.mode == 'directory' then
                    recurse(full)
                elseif attr and (entry:match('%.prefab$') or entry:match('%.lua$')) then
                    if sms.prefab.load(full) then count = count + 1 end
                end
            end
        end
    end
    local ok = pcall(recurse, dir)
    if not ok then
        log.warn('load_dir: directory not accessible: ' .. dir)
    end
    return count
end

function sms.prefab.save(prefab_table, path)
    if type(prefab_table) ~= 'table' or type(prefab_table.meta) ~= 'table' then
        log.warn('save: prefab_table missing meta')
        return false
    end
    if type(path) ~= 'string' or path == '' then
        log.warn('save: path required')
        return false
    end
    if type(io) ~= 'table' or not io.open then
        log.warn('save: io.open not available in this environment')
        return false
    end
    local f, err = io.open(path, 'w')
    if not f then
        log.error('save: open failed: ' .. tostring(err))
        return false
    end
    f:write(sms.utils.serialize(prefab_table))
    f:close()
    return true
end

-- Register a template directly (without going through dofile). Useful for
-- programmatically constructed prefabs and for tests. The 'load' path is
-- the production happy path; this is the in-memory equivalent.
function sms.prefab.register(name, template)
    if type(name) ~= 'string' or name == '' then
        log.warn('register: name required')
        return nil
    end
    if type(template) ~= 'table' or type(template.meta) ~= 'table' then
        log.warn("register: template missing meta")
        return nil
    end
    if _registry[name] then
        log.warn("register: overwriting prefab '" .. name .. "'")
    end
    template.meta.name = name
    _registry[name] = template
    return template
end

function sms.prefab.unload(name)
    if _registry[name] then
        _registry[name] = nil
        return true
    end
    return false
end

function sms.prefab.list()
    local out = {}
    for name in pairs(_registry) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function sms.prefab.get(name)
    return _registry[name]
end

-- ---------------------------------------------------------------------------
-- Spawn implementation
-- ---------------------------------------------------------------------------

local _category_for_group_type = {
    plane      = Group.Category and Group.Category.AIRPLANE   or 0,
    helicopter = Group.Category and Group.Category.HELICOPTER or 1,
    vehicle    = Group.Category and Group.Category.GROUND     or 2,
    ground     = Group.Category and Group.Category.GROUND     or 2,
    ship       = Group.Category and Group.Category.SHIP       or 3,
    train      = Group.Category and Group.Category.TRAIN      or 4,
}

-- Resolve country opt: accepts a numeric id, a string name (case-insensitive),
-- or nil. Returns numeric id or nil.
local function resolve_country(c)
    if c == nil then return nil end
    if type(c) == 'number' then return c end
    if type(c) == 'string' and sms.utils.resolve_country then
        local id = sms.utils.resolve_country(c)
        return id
    end
    return nil
end

-- Probe Group.getByName / StaticObject.getByName to find a free name with
-- the same auto-suffix convention used by sms.group.create.
local function unique_name(base)
    if not Group.getByName(base) and not (StaticObject and StaticObject.getByName and StaticObject.getByName(base)) then
        return base
    end
    local i = 1
    while true do
        local candidate = base .. '-' .. i
        if not Group.getByName(candidate) and not (StaticObject and StaticObject.getByName and StaticObject.getByName(candidate)) then
            return candidate
        end
        i = i + 1
        if i > 9999 then return base .. '-' .. tostring(os.time()) end
    end
end

-- Deep copy a table; needed because we mutate the spawn-time table without
-- modifying the registered template.
local function deep_copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = deep_copy(val) end
    return out
end

-- Apply rotation + translation to every (x, y) pair in a sub-table.
local function apply_transform(t, anchor_x, anchor_z, rotation_deg)
    if type(t) ~= 'table' then return end
    if type(t.x) == 'number' and type(t.y) == 'number' then
        local rx, ry = sms.prefab._rotate_xy(t.x, t.y, rotation_deg)
        t.x = anchor_x + rx
        t.y = anchor_z + ry
    end
    for _, v in pairs(t) do
        if type(v) == 'table' then
            apply_transform(v, anchor_x, anchor_z, rotation_deg)
        end
    end
end

-- Apply rotation to every heading field. (Headings are in degrees in the
-- prefab file; DCS expects radians on spawn.)
local function rotate_headings(t, rotation_deg)
    if type(t) ~= 'table' then return end
    for k, v in pairs(t) do
        if k == 'heading' and type(v) == 'number' then
            t[k] = ((v + rotation_deg) % 360)
        elseif type(v) == 'table' then
            rotate_headings(v, rotation_deg)
        end
    end
end

-- Convert all heading fields deg → rad in-place (final pre-DCS step).
local function headings_to_rad(t)
    if type(t) ~= 'table' then return end
    for k, v in pairs(t) do
        if k == 'heading' and type(v) == 'number' then
            t[k] = v * (math.pi / 180)
        elseif type(v) == 'table' then
            headings_to_rad(v)
        end
    end
end

-- Spawn one group: coalition.addGroup. Returns spawned name on success, nil + log on failure.
local function spawn_group(group_table, country_override, name_prefix)
    local g = deep_copy(group_table)
    local country = country_override or g.country
    if not country then
        log.warn("spawn: group '" .. tostring(g.name) .. "' has no country and none provided")
        return nil
    end
    local cat = _category_for_group_type[g.type]
    if not cat then
        log.warn("spawn: group '" .. tostring(g.name) .. "' unknown type '" .. tostring(g.type) .. "'")
        return nil
    end
    local desired = (name_prefix or '') .. (g.name or 'unnamed')
    local resolved = unique_name(desired)
    g.name = resolved
    -- Auto-suffix unit names too — append the same suffix (delta from the original name).
    if g.units then
        local suffix = resolved:sub(#desired + 1)            -- "" if no suffix added
        for _, u in pairs(g.units) do
            if type(u) == 'table' and type(u.name) == 'string' and suffix ~= '' then
                u.name = u.name .. suffix
            end
        end
    end
    headings_to_rad(g)
    -- Drop our distill enrichment fields that DCS doesn't expect.
    g.country = nil
    local ok, err = pcall(coalition.addGroup, country, cat, g)
    if not ok then
        log.error("spawn: coalition.addGroup failed for '" .. resolved .. "': " .. tostring(err))
        return nil
    end
    return resolved
end

local function spawn_static(static_table, country_override, name_prefix)
    local s = deep_copy(static_table)
    local country = country_override or s.country
    if not country then
        log.warn("spawn: static '" .. tostring(s.name) .. "' has no country and none provided")
        return nil
    end
    local desired = (name_prefix or '') .. (s.name or 'unnamed')
    s.name = unique_name(desired)
    headings_to_rad(s)
    s.country = nil
    local ok, err = pcall(coalition.addStaticObject, country, s)
    if not ok then
        log.error("spawn: coalition.addStaticObject failed for '" .. s.name .. "': " .. tostring(err))
        return nil
    end
    return s.name
end

-- Spawn a drawing via trigger.action.* APIs. Returns a {name, mark_id, kind}
-- table on success, nil on failure.
local function spawn_drawing(drawing, mark_id_alloc)
    local kind = drawing.primitiveType or 'Unknown'
    local mark_id = mark_id_alloc()
    local coalition_id = -1                                     -- all
    local color    = drawing.color     or {1, 1, 1, 1}
    local fill     = drawing.fillColor or {1, 1, 1, 0.25}
    local line_type = drawing.lineType or 1                     -- 1 = solid

    local ok, err
    if kind == 'Line' and drawing.points and #drawing.points >= 2 then
        local p1 = drawing.points[1]
        local p2 = drawing.points[2]
        ok, err = pcall(trigger.action.lineToAll, coalition_id, mark_id,
            { x = p1.x, y = 0, z = p1.y },
            { x = p2.x, y = 0, z = p2.y },
            color, line_type, true, drawing.text or '')
    elseif kind == 'Polygon' and drawing.points and #drawing.points >= 3 then
        ok, err = pcall(function()
            local args = { 7, coalition_id, mark_id }     -- shapeId 7 = freeform polygon
            for _, p in ipairs(drawing.points) do
                args[#args + 1] = { x = p.x, y = 0, z = p.y }
            end
            args[#args + 1] = color
            args[#args + 1] = fill
            args[#args + 1] = line_type
            args[#args + 1] = true
            args[#args + 1] = drawing.text or ''
            trigger.action.markupToAll(table.unpack and table.unpack(args) or unpack(args))
        end)
    elseif kind == 'Circle' then
        local r = drawing.radius or 1000
        local cx = (drawing.mapData and drawing.mapData.x) or drawing.x or 0
        local cy = (drawing.mapData and drawing.mapData.y) or drawing.y or 0
        ok, err = pcall(trigger.action.circleToAll, coalition_id, mark_id,
            { x = cx, y = 0, z = cy }, r, color, fill, line_type, true, drawing.text or '')
    elseif kind == 'TextBox' or kind == 'Text' then
        local cx = (drawing.mapData and drawing.mapData.x) or drawing.x or 0
        local cy = (drawing.mapData and drawing.mapData.y) or drawing.y or 0
        ok, err = pcall(trigger.action.textToAll, coalition_id, mark_id,
            { x = cx, y = 0, z = cy }, color, fill, drawing.fontSize or 16, true, drawing.text or '')
    elseif kind == 'Icon' then
        local cx = (drawing.mapData and drawing.mapData.x) or drawing.x or 0
        local cy = (drawing.mapData and drawing.mapData.y) or drawing.y or 0
        ok, err = pcall(trigger.action.markToAll, mark_id, drawing.text or drawing.name or '',
            { x = cx, y = 0, z = cy }, true)
    else
        log.warn("spawn: drawing kind '" .. kind .. "' not supported in v1 — skipping")
        return nil
    end
    if not ok then
        log.error("spawn: drawing render failed for '" .. tostring(drawing.name) .. "': " .. tostring(err))
        return nil
    end
    return { name = drawing.name, mark_id = mark_id, kind = kind }
end

function sms.prefab.spawn(name, opts)
    opts = opts or {}
    local template = _registry[name]
    if not template then
        log.warn("spawn: prefab '" .. tostring(name) .. "' not registered")
        return nil
    end
    local rotation = opts.rotation or 0
    local country = resolve_country(opts.country)
    if opts.country ~= nil and country == nil then
        log.warn('spawn: opts.country invalid: ' .. tostring(opts.country))
        return nil
    end

    local anchor_x, anchor_z
    if opts.keep_position then
        anchor_x = template.meta.world_anchor.x
        anchor_z = template.meta.world_anchor.y
        rotation = 0
    else
        anchor_x, anchor_z = sms.prefab._anchor_xy(opts.anchor)
        if not anchor_x then
            log.warn('spawn: opts.anchor required (or set keep_position=true)')
            return nil
        end
    end

    -- Phase 1: build mutable copies, transform coords + headings.
    local groups   = {}
    local statics  = {}
    for _, g in ipairs(template.groups or {})   do
        local copy = deep_copy(g)
        rotate_headings(copy, rotation)
        apply_transform(copy, anchor_x, anchor_z, rotation)
        groups[#groups + 1] = copy
    end
    for _, s in ipairs(template.statics or {})  do
        local copy = deep_copy(s)
        rotate_headings(copy, rotation)
        apply_transform(copy, anchor_x, anchor_z, rotation)
        statics[#statics + 1] = copy
    end

    -- Phase 2: realize in DCS.
    local spawned_groups   = {}
    local spawned_statics  = {}
    local spawned_drawings = {}
    local zones            = {}
    local template_to_runtime = {}     -- "Aerial-1" -> "Aerial-1-2"

    for _, g in ipairs(groups) do
        local original = g.name
        local rt = spawn_group(g, country, opts.name_prefix)
        if rt then
            spawned_groups[#spawned_groups + 1] = sms.group(rt)
            template_to_runtime[original] = rt
        end
    end
    for _, s in ipairs(statics) do
        local original = s.name
        local rt = spawn_static(s, country, opts.name_prefix)
        if rt then
            spawned_statics[#spawned_statics + 1] = sms.static(rt)
            template_to_runtime[original] = rt
        end
    end

    -- Drawings: transform coords first, then realize.
    local mark_id_seed = math.floor(os.time() * 1000)
    local drawings = {}
    for _, d in ipairs(template.drawings or {}) do
        local copy = deep_copy(d)
        apply_transform(copy, anchor_x, anchor_z, rotation)
        drawings[#drawings + 1] = copy
    end
    local function alloc_mark_id()
        mark_id_seed = mark_id_seed + 1
        return mark_id_seed
    end
    for _, d in ipairs(drawings) do
        local entry = spawn_drawing(d, alloc_mark_id)
        if entry then spawned_drawings[#spawned_drawings + 1] = entry end
    end

    -- Zones: data-only. Transform coords; attach to handle.
    --
    -- A polygon ("quad") zone's `points` are vertices stored RELATIVE to the
    -- zone's own {x,y} centre (consumers read a vertex as zone.x + points[i].x),
    -- so only the centre is anchored; the vertices are rotated about the local
    -- origin and never translated. Running apply_transform over the whole zone
    -- added the anchor to every vertex too, displacing the polygon from its own
    -- centre by the placement delta. Mirrors rebase_zone in prefab_distill.lua.
    -- Circle zones have no `points` and take the plain path.
    for _, z in ipairs(template.zones or {}) do
        local copy = deep_copy(z)
        local verts = copy.points
        copy.points = nil
        apply_transform(copy, anchor_x, anchor_z, rotation)
        copy.points = verts
        if type(verts) == 'table' and rotation and rotation ~= 0 then
            for _, p in ipairs(verts) do
                if type(p) == 'table' and type(p.x) == 'number' and type(p.y) == 'number' then
                    p.x, p.y = sms.prefab._rotate_xy(p.x, p.y, rotation)
                end
            end
        end
        zones[#zones + 1] = copy
    end

    if #spawned_groups == 0 and #spawned_statics == 0 and #spawned_drawings == 0 and #zones == 0 then
        log.error("spawn: nothing in prefab '" .. name .. "' was spawnable")
        return nil
    end

    -- Build handle.
    local id = _next_instance_id
    _next_instance_id = id + 1
    local handle = {
        _name                = name,
        _id                  = id,
        _anchor              = { x = anchor_x, z = anchor_z },
        _rotation            = rotation,
        _groups              = spawned_groups,
        _statics             = spawned_statics,
        _drawings            = spawned_drawings,
        _zones               = zones,
        _template_to_runtime = template_to_runtime,
        _destroyed           = false,
    }
    setmetatable(handle, { __index = sms.prefab })
    _instances[id] = handle
    return handle
end

-- ---------------------------------------------------------------------------
-- Handle methods (dispatched via __index = sms.prefab)
-- ---------------------------------------------------------------------------

function sms.prefab.get_name(h)     return h._name end
function sms.prefab.get_id(h)       return h._id end
function sms.prefab.get_anchor(h)   return { x = h._anchor.x, z = h._anchor.z } end
function sms.prefab.get_rotation(h) return h._rotation end
function sms.prefab.get_groups(h)   return h._destroyed and {} or h._groups end
function sms.prefab.get_statics(h)  return h._destroyed and {} or h._statics end
function sms.prefab.get_zones(h)    return h._destroyed and {} or h._zones end
function sms.prefab.get_drawings(h) return h._destroyed and {} or h._drawings end

local function find_by_name(arr, name)
    for _, x in ipairs(arr) do
        if x.name == name then return x end
    end
    return nil
end

function sms.prefab.get_group(h, template_name)
    if h._destroyed then return nil end
    local rt = h._template_to_runtime[template_name]
    if not rt then return nil end
    return sms.group(rt)
end

function sms.prefab.get_static(h, template_name)
    if h._destroyed then return nil end
    local rt = h._template_to_runtime[template_name]
    if not rt then return nil end
    return sms.static(rt)
end

function sms.prefab.get_zone(h, name)
    if h._destroyed then return nil end
    return find_by_name(h._zones, name)
end

function sms.prefab.is_alive(h)
    if h._destroyed then return false end
    for _, g in ipairs(h._groups) do
        if g and g.is_alive and g:is_alive() then return true end
    end
    for _, s in ipairs(h._statics) do
        if s and s.is_alive and s:is_alive() then return true end
    end
    return false
end

function sms.prefab.destroy(h)
    if h._destroyed then return end
    for _, g in ipairs(h._groups) do
        pcall(function()
            local raw = Group.getByName(g.name)
            if raw then raw:destroy() end
        end)
    end
    for _, s in ipairs(h._statics) do
        pcall(function()
            if StaticObject and StaticObject.getByName then
                local raw = StaticObject.getByName(s.name)
                if raw then raw:destroy() end
            end
        end)
    end
    for _, d in ipairs(h._drawings) do
        pcall(trigger.action.removeMark, d.mark_id)
    end
    h._destroyed = true
    _instances[h._id] = nil
end

-- ---------------------------------------------------------------------------
-- Multi-instance helpers
-- ---------------------------------------------------------------------------

function sms.prefab.list_instances(name)
    local out = {}
    for _, h in pairs(_instances) do
        if not name or h:get_name() == name then
            out[#out + 1] = h
        end
    end
    return out
end

function sms.prefab.destroy_all(name)
    local count = 0
    for id, h in pairs(_instances) do
        if not name or h:get_name() == name then
            h:destroy()
            count = count + 1
        end
    end
    return count
end
