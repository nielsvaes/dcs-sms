-- dcs_sms_me/verbs/zone_verbs.lua — trigger-zone lifecycle + setters + list/get.
--
-- Verbs: zone_create_<circle|quad>, zone_set_<color|name|pos|radius|hidden|
-- vertices|link>, zone_remove, zone_list, zone_get.
-- See dcs_sms_me/verbs.lua for the aggregator and the verb-naming convention.

local M = {}

local H = require('dcs_sms_me.verb_helpers')
local find_unit_in_mission = H.find_unit_in_mission
local compute_lat_lon      = H.compute_lat_lon

-- ============================================================
-- Trigger zone lifecycle verbs
-- ============================================================

-- DCS trigger zone types (from Mission.TriggerZone.lua line 9):
--   TYPE_CIRCLE    = 0
--   TYPE_RECTANGLE = 1   (unused at the ME UI level — quads use type 2)
--   TYPE_POLYGON   = 2   (4 vertices = "Quad-Point Zone" in the ME UI)
local ZONE_TYPE_CIRCLE = 0
local ZONE_TYPE_POLYGON = 2

-- Default color matches what TriggerZone.construct sets internally:
-- {r=1, g=1, b=1, a=0.15} — translucent white. RGBA components are floats 0..1.
local function default_zone_color() return { 1, 1, 1, 0.15 } end

-- find_zone_by_name / find_zone_by_id — TriggerZoneData doesn't expose a
-- by-name lookup directly; we iterate getTriggerZoneIds() and match.
local function find_zone(by_name, by_id)
    local TZD = require('Mission.TriggerZoneData')
    if type(TZD) ~= 'table' or type(TZD.getTriggerZoneIds) ~= 'function' then
        return nil, nil
    end
    for _, zid in ipairs(TZD.getTriggerZoneIds() or {}) do
        if by_id and zid == by_id then return zid, TZD.getTriggerZoneName(zid) end
        if by_name then
            local n = TZD.getTriggerZoneName(zid)
            if n == by_name then return zid, n end
        end
    end
    return nil, nil
end

-- zone_create_circle — circular trigger zone at (north, east) with given radius.
--
-- args (required):
--   name:   string  -- zone name (uniquified by TriggerZoneData if duplicate)
--   north:  number  -- meters north of theatre origin
--   east:   number  -- meters east of theatre origin
--   radius: number  -- meters
--
-- args (optional):
--   color:  { r, g, b, a } floats 0..1; defaults to translucent white
--   hidden: bool, default false
--   properties: table, default {}
--
-- Returns { ok = true, zoneId, name } on success.
function M.zone_create_circle(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_create_circle requires args (table)' }
    end
    if type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'zone_create_circle requires args.name (string)' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'zone_create_circle requires args.north and args.east (numbers, meters)' }
    end
    if type(args.radius) ~= 'number' or args.radius <= 0 then
        return { ok = false, error = 'zone_create_circle requires args.radius (positive number, meters)' }
    end

    local ok_tzd, TZD = pcall(require, 'Mission.TriggerZoneData')
    if not ok_tzd or type(TZD) ~= 'table' or type(TZD.addTriggerZone) ~= 'function' then
        return { ok = false, error = 'Mission.TriggerZoneData unavailable' }
    end

    local color = (type(args.color) == 'table') and args.color or default_zone_color()
    local properties = (type(args.properties) == 'table') and args.properties or {}

    -- mission-table fields: x = north, y = east
    local x, y = args.north, args.east

    -- addTriggerZone returns the allocated zoneId on success.
    local ok_call, zid_or_err = pcall(TZD.addTriggerZone, args.name, x, y, args.radius,
                                       properties, color, ZONE_TYPE_CIRCLE, nil)
    if not ok_call then
        return { ok = false, error = 'addTriggerZone: ' .. tostring(zid_or_err) }
    end
    if type(zid_or_err) ~= 'number' then
        return { ok = false, error = 'addTriggerZone returned non-number: ' .. tostring(zid_or_err) }
    end

    -- Name may have been uniquified by TZD.makeTriggerZoneNameUnique.
    local final_name = TZD.getTriggerZoneName and TZD.getTriggerZoneName(zid_or_err) or args.name

    if args.hidden == true and type(TZD.setTriggerZoneHidden) == 'function' then
        pcall(TZD.setTriggerZoneHidden, zid_or_err, true)
    end

    return { ok = true, zoneId = zid_or_err, name = final_name, type = 'circle' }
end

-- zone_create_quad — polygon trigger zone with 4 vertices (the ME's
-- "Quad-Point Zone"). Despite the name we accept any N>=3 vertex count —
-- the underlying type=2 polygon supports it.
--
-- args (required):
--   name:     string
--   vertices: list of { north = N, east = E } in absolute world meters
--             (NOT relative to center — we compute the center for you).
--
-- args (optional):
--   color, hidden, properties — see zone_create_circle
--   radius:   icon radius in meters; defaults to half the bounding-box diagonal
--             (matches what the ME would compute for a rectangular quad).
--
-- Returns { ok = true, zoneId, name, center = { north, east } } on success.
function M.zone_create_quad(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_create_quad requires args (table)' }
    end
    if type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'zone_create_quad requires args.name (string)' }
    end
    if type(args.vertices) ~= 'table' or #args.vertices < 3 then
        return { ok = false, error = 'zone_create_quad requires args.vertices (>= 3 {north,east} pairs)' }
    end

    -- Validate each vertex.
    for i, v in ipairs(args.vertices) do
        if type(v) ~= 'table' or type(v.north) ~= 'number' or type(v.east) ~= 'number' then
            return { ok = false,
                     error = 'vertex ' .. i .. ' missing/invalid {north,east} numbers' }
        end
    end

    -- Compute center as average of vertices.
    local cx, cy = 0, 0
    for _, v in ipairs(args.vertices) do
        cx = cx + v.north
        cy = cy + v.east
    end
    cx = cx / #args.vertices
    cy = cy / #args.vertices

    -- Convert absolute vertices to points relative to center
    -- (mission-table fields: x = north, y = east).
    local points = {}
    local minN, maxN, minE, maxE = math.huge, -math.huge, math.huge, -math.huge
    for _, v in ipairs(args.vertices) do
        table.insert(points, { x = v.north - cx, y = v.east - cy })
        if v.north < minN then minN = v.north end
        if v.north > maxN then maxN = v.north end
        if v.east  < minE then minE = v.east  end
        if v.east  > maxE then maxE = v.east  end
    end

    -- Default radius = half bounding-box diagonal — sized so the icon
    -- circumscribes the quad. User can override.
    local default_radius = 0.5 * math.sqrt((maxN - minN) ^ 2 + (maxE - minE) ^ 2)
    local radius = (type(args.radius) == 'number' and args.radius > 0) and args.radius
                   or math.max(default_radius, 1)

    local ok_tzd, TZD = pcall(require, 'Mission.TriggerZoneData')
    if not ok_tzd or type(TZD) ~= 'table' or type(TZD.addTriggerZone) ~= 'function' then
        return { ok = false, error = 'Mission.TriggerZoneData unavailable' }
    end

    local color = (type(args.color) == 'table') and args.color or default_zone_color()
    local properties = (type(args.properties) == 'table') and args.properties or {}

    local ok_call, zid_or_err = pcall(TZD.addTriggerZone, args.name, cx, cy, radius,
                                       properties, color, ZONE_TYPE_POLYGON, points)
    if not ok_call then
        return { ok = false, error = 'addTriggerZone: ' .. tostring(zid_or_err) }
    end
    if type(zid_or_err) ~= 'number' then
        return { ok = false, error = 'addTriggerZone returned non-number: ' .. tostring(zid_or_err) }
    end

    local final_name = TZD.getTriggerZoneName and TZD.getTriggerZoneName(zid_or_err) or args.name

    if args.hidden == true and type(TZD.setTriggerZoneHidden) == 'function' then
        pcall(TZD.setTriggerZoneHidden, zid_or_err, true)
    end

    return { ok = true, zoneId = zid_or_err, name = final_name, type = 'quad',
             center = { north = cx, east = cy }, vertex_count = #points }
end

-- ============================================================
-- Zone setters (per-field)
-- ============================================================
--
-- Each setter takes { name = "<X>" | id = <N>, <field> = <value> } and wraps
-- the matching Mission.TriggerZoneData.setTriggerZone* call. Returns the new
-- value on success so callers can confirm the write took.

-- zone_set_color — change RGBA color of a zone.
-- args: { name | id, color = { r, g, b[, a] } } floats 0..1.
-- Alpha defaults to 0.15 (DCS's translucent fill alpha) if missing.
function M.zone_set_color(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_color requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_color requires exactly one of args.name or args.id' }
    end
    if type(args.color) ~= 'table' or type(args.color[1]) ~= 'number'
            or type(args.color[2]) ~= 'number' or type(args.color[3]) ~= 'number' then
        return { ok = false, error = 'zone_set_color requires args.color = { r, g, b[, a] } floats 0..1' }
    end
    local zid, zname = find_zone(has_name and args.name or nil,
                                 has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end
    local r, g, b = args.color[1], args.color[2], args.color[3]
    local a = (type(args.color[4]) == 'number') and args.color[4] or 0.15
    local TZD = require('Mission.TriggerZoneData')
    local ok_call, err = pcall(TZD.setTriggerZoneColor, zid, r, g, b, a)
    if not ok_call then
        return { ok = false, error = 'setTriggerZoneColor: ' .. tostring(err) }
    end
    return { ok = true, id = zid, name = zname, color = { r, g, b, a } }
end

-- zone_set_name — rename a zone. ME enforces uniqueness via
-- makeTriggerZoneNameUnique, so the stored name may include a suffix.
function M.zone_set_name(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_name requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_name requires exactly one of args.name or args.id' }
    end
    if type(args.new_name) ~= 'string' or args.new_name == '' then
        return { ok = false, error = 'zone_set_name requires args.new_name (non-empty string)' }
    end
    local zid = find_zone(has_name and args.name or nil, has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end
    local TZD = require('Mission.TriggerZoneData')
    local ok_call, err = pcall(TZD.setTriggerZoneName, zid, args.new_name)
    if not ok_call then
        return { ok = false, error = 'setTriggerZoneName: ' .. tostring(err) }
    end
    -- Read back what TZD actually stored — the ME may have appended a suffix.
    local final = TZD.getTriggerZoneName(zid)
    return { ok = true, id = zid, name = final, requested_name = args.new_name }
end

-- zone_set_pos — move zone center to (north, east).
-- For circles, this just moves the center. For quads, the relative points
-- ride along (translation), but the shape doesn't reshape — use
-- zone_set_vertices for that.
function M.zone_set_pos(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_pos requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_pos requires exactly one of args.name or args.id' }
    end
    if type(args.north) ~= 'number' or type(args.east) ~= 'number' then
        return { ok = false, error = 'zone_set_pos requires args.north and args.east (numbers, meters)' }
    end
    local zid, zname = find_zone(has_name and args.name or nil, has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end
    local TZD = require('Mission.TriggerZoneData')
    -- mission-table fields: x = north, y = east
    local ok_call, err = pcall(TZD.setTriggerZonePosition, zid, args.north, args.east)
    if not ok_call then
        return { ok = false, error = 'setTriggerZonePosition: ' .. tostring(err) }
    end
    return { ok = true, id = zid, name = zname, north = args.north, east = args.east }
end

-- zone_set_radius — set zone radius (circle: trigger radius; quad: icon radius).
function M.zone_set_radius(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_radius requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_radius requires exactly one of args.name or args.id' }
    end
    if type(args.radius) ~= 'number' or args.radius <= 0 then
        return { ok = false, error = 'zone_set_radius requires args.radius (positive number, meters)' }
    end
    local zid, zname = find_zone(has_name and args.name or nil, has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end
    local TZD = require('Mission.TriggerZoneData')
    local ok_call, err = pcall(TZD.setTriggerZoneRadius, zid, args.radius)
    if not ok_call then
        return { ok = false, error = 'setTriggerZoneRadius: ' .. tostring(err) }
    end
    return { ok = true, id = zid, name = zname, radius = args.radius }
end

-- zone_set_hidden — toggle zone visibility in the ME view.
-- Caller must pass an explicit boolean — the CLI rejects missing --hidden.
function M.zone_set_hidden(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_hidden requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_hidden requires exactly one of args.name or args.id' }
    end
    if type(args.hidden) ~= 'boolean' then
        return { ok = false, error = 'zone_set_hidden requires args.hidden (boolean)' }
    end
    local zid, zname = find_zone(has_name and args.name or nil, has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end
    local TZD = require('Mission.TriggerZoneData')
    local ok_call, err = pcall(TZD.setTriggerZoneHidden, zid, args.hidden)
    if not ok_call then
        return { ok = false, error = 'setTriggerZoneHidden: ' .. tostring(err) }
    end
    return { ok = true, id = zid, name = zname, hidden = args.hidden }
end

-- zone_set_vertices — reshape a quad zone in absolute world coords.
-- Computes a new center (average of vertices) and stores points relative to
-- that center — same shape zone_create_quad produces, so save+reload behavior
-- is identical. Refuses on non-quad zones.
--
-- args: { name|id, vertices = { { north=N, east=E }, ... } } (>= 3)
function M.zone_set_vertices(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_vertices requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_vertices requires exactly one of args.name or args.id' }
    end
    if type(args.vertices) ~= 'table' or #args.vertices < 3 then
        return { ok = false, error = 'zone_set_vertices requires args.vertices (>= 3 {north,east} pairs)' }
    end
    for i, v in ipairs(args.vertices) do
        if type(v) ~= 'table' or type(v.north) ~= 'number' or type(v.east) ~= 'number' then
            return { ok = false, error = 'vertex ' .. i .. ' missing/invalid {north,east} numbers' }
        end
    end

    local zid, zname = find_zone(has_name and args.name or nil, has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end

    local TZD = require('Mission.TriggerZoneData')
    -- Refuse on circle zones — they have no vertices to reshape. The user
    -- almost certainly wanted set-radius / set-pos.
    if TZD.getTriggerZoneType(zid) ~= 2 then  -- 2 = polygon/quad
        return { ok = false, error = 'zone is not a quad; use set-radius/set-pos for circle zones' }
    end

    -- Average vertices for new center, then compute relative points.
    local cx, cy = 0, 0
    for _, v in ipairs(args.vertices) do
        cx = cx + v.north; cy = cy + v.east
    end
    cx = cx / #args.vertices; cy = cy / #args.vertices
    local rel = {}
    for _, v in ipairs(args.vertices) do
        table.insert(rel, { x = v.north - cx, y = v.east - cy })
    end

    local ok_pos, err_pos = pcall(TZD.setTriggerZonePosition, zid, cx, cy)
    if not ok_pos then
        return { ok = false, error = 'setTriggerZonePosition: ' .. tostring(err_pos) }
    end
    local ok_pts, err_pts = pcall(TZD.setTriggerZonePoints, zid, rel)
    if not ok_pts then
        return { ok = false, error = 'setTriggerZonePoints: ' .. tostring(err_pts) }
    end
    return { ok = true, id = zid, name = zname,
             center = { north = cx, east = cy },
             vertex_count = #rel }
end

-- zone_set_link — link a trigger zone to a unit (so the zone's center
-- follows the unit), or clear an existing link.
--
-- Wraps Mission.linkTriggerZone / Mission.unlinkTriggerZone (the
-- high-level wrappers used by the ME's panel UI), NOT the lower-level
-- TZD.linkToUnit directly. The wrappers do TWO things on link:
--   1. TriggerZoneController.linkToUnit(zid, uid) — sets the zone's
--      linkUnitId, captures local coords, captures heading.
--   2. table.insert(unit.linkChildrenTZone, zid) — back-reference on
--      the unit so the unit's drag/move handlers (in me_map_window,
--      me_aircraft, me_ship, me_vehicle, me_static) know to refresh
--      this zone's position when the unit moves.
--
-- Calling only step 1 (the bare TZD function) leaves the link visible
-- in the LINK UNIT dropdown and persisted to .miz, but the zone won't
-- move with the unit in the live ME view — save+reload "fixes" it
-- because load reconstructs linkChildrenTZone from the zone's stored
-- linkUnitId, but in-session drag is broken without the back-ref.
--
-- args (zone selector — required): name | id (mutually exclusive)
-- args (action — exactly one required):
--   unit:     string  — link to unit by name
--   unit_id:  number  — link to unit by id
--   clear:    true    — remove the link
function M.zone_set_link(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_set_link requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_set_link requires exactly one of args.name or args.id' }
    end

    local has_unit = type(args.unit) == 'string' and args.unit ~= ''
    local has_unit_id = type(args.unit_id) == 'number'
    local has_clear = (args.clear == true)
    local action_count = (has_unit and 1 or 0) + (has_unit_id and 1 or 0) + (has_clear and 1 or 0)
    if action_count ~= 1 then
        return { ok = false,
                 error = 'zone_set_link requires exactly one of args.unit, args.unit_id, or args.clear=true' }
    end

    local zid, zname = find_zone(has_name and args.name or nil, has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end

    local Mission = require('me_mission')

    if has_clear then
        if type(Mission.unlinkTriggerZone) ~= 'function' then
            return { ok = false, error = 'Mission.unlinkTriggerZone unavailable' }
        end
        local ok_call, err = pcall(Mission.unlinkTriggerZone, zid)
        if not ok_call then
            return { ok = false, error = 'unlinkTriggerZone: ' .. tostring(err) }
        end
        return { ok = true, id = zid, name = zname, cleared = true }
    end

    -- Resolve target unit.
    local u = find_unit_in_mission(has_unit and args.unit or nil,
                                   has_unit_id and args.unit_id or nil)
    if not u then
        return { ok = false, error = 'unit not found' }
    end

    if type(Mission.linkTriggerZone) ~= 'function' then
        return { ok = false, error = 'Mission.linkTriggerZone unavailable' }
    end

    -- linkTriggerZone tolerates re-linking but doesn't dedupe the
    -- linkChildrenTZone back-reference list — calling it twice on the
    -- same (zone, unit) pair would push the zoneId in twice. Defensively
    -- unlink first if the zone is currently linked.
    if type(Mission.unlinkTriggerZone) == 'function' then
        local TZD = require('Mission.TriggerZoneData')
        if type(TZD.getLinkUnitId) == 'function' and TZD.getLinkUnitId(zid) then
            pcall(Mission.unlinkTriggerZone, zid)
        end
    end

    local ok_call, err = pcall(Mission.linkTriggerZone, zid, u.unitId)
    if not ok_call then
        return { ok = false, error = 'linkTriggerZone: ' .. tostring(err) }
    end

    return {
        ok = true,
        id = zid,
        name = zname,
        unit_id = u.unitId,
        unit_name = u.name,
    }
end

-- zone_remove — remove a trigger zone by name or id (mutually exclusive).
function M.zone_remove(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_remove requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_remove requires exactly one of args.name (string) or args.id (number)' }
    end

    local zid, zname = find_zone(has_name and args.name or nil,
                                 has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end

    local TZD = require('Mission.TriggerZoneData')
    local ok_call, err = pcall(TZD.removeTriggerZone, zid)
    if not ok_call then
        return { ok = false, error = 'removeTriggerZone: ' .. tostring(err),
                 resolved = { id = zid, name = zname } }
    end

    return { ok = true, id = zid, name = zname }
end

-- ============================================================
-- Zone list / get
-- ============================================================

-- zone_list — return concise summaries of all trigger zones.
--
-- args (optional):
--   shape: "circle" | "quad"  -- numeric type 0 / 2 in mission-table
--   name:  string  -- substring (case-insensitive)
--
-- Returns { ok = true, zones = [ ... ], count = N }.
function M.zone_list(args)
    args = args or {}
    local f_shape = args.shape and string.lower(args.shape) or nil
    local f_name = args.name and string.lower(args.name) or nil

    local ok_tzd, TZD = pcall(require, 'Mission.TriggerZoneData')
    if not ok_tzd or type(TZD) ~= 'table' then
        return { ok = false, error = 'Mission.TriggerZoneData unavailable' }
    end

    local out = {}
    for _, zid in ipairs(TZD.getTriggerZoneIds() or {}) do
        local nm = TZD.getTriggerZoneName(zid)
        local tnum = TZD.getTriggerZoneType(zid)
        local shape = (tnum == 0 and 'circle') or (tnum == 2 and 'quad') or ('type=' .. tostring(tnum))
        if not (f_shape and shape ~= f_shape)
                and not (f_name and nm and not string.find(string.lower(nm), f_name, 1, true)) then
            local x, y = TZD.getTriggerZonePosition(zid)
            local r, g, b, a = TZD.getTriggerZoneColor(zid)
            local pts = TZD.getTriggerZonePoints(zid) or {}
            local lat, lon = compute_lat_lon(x, y)
            table.insert(out, {
                id = zid,
                name = nm,
                shape = shape,
                type = tnum,
                north = x,
                east = y,
                lat = lat,
                lon = lon,
                radius = TZD.getTriggerZoneRadius(zid),
                color = { r, g, b, a },
                hidden = TZD.getTriggerZoneHidden(zid),
                vertex_count = (tnum == 2) and #pts or nil,
            })
        end
    end
    return { ok = true, zones = out, count = #out }
end

-- zone_get — full zone detail by name or id.
function M.zone_get(args)
    if type(args) ~= 'table' then
        return { ok = false, error = 'zone_get requires args (table)' }
    end
    local has_name = type(args.name) == 'string' and args.name ~= ''
    local has_id = type(args.id) == 'number'
    if has_name == has_id then
        return { ok = false, error = 'zone_get requires exactly one of args.name or args.id' }
    end

    local zid, _ = find_zone(has_name and args.name or nil,
                             has_id and args.id or nil)
    if not zid then
        return { ok = false, error = 'zone not found' }
    end

    local TZD = require('Mission.TriggerZoneData')
    local x, y = TZD.getTriggerZonePosition(zid)
    local r, g, b, a = TZD.getTriggerZoneColor(zid)
    local tnum = TZD.getTriggerZoneType(zid)
    local shape = (tnum == 0 and 'circle') or (tnum == 2 and 'quad') or ('type=' .. tostring(tnum))
    local pts_rel = TZD.getTriggerZonePoints(zid) or {}

    -- Convert relative points back to absolute for user clarity (matches the
    -- shape of --vertices on input). Each absolute vertex also gets its own
    -- lat/lon (GH#66 request 4) so callers iterating a quad's corners don't
    -- have to per-vertex round-trip through `me coords to-geo`. Keep raw
    -- relative points too.
    local pts_abs = {}
    for _, p in ipairs(pts_rel) do
        local vn, ve = p.x + x, p.y + y
        local vlat, vlon = compute_lat_lon(vn, ve)
        table.insert(pts_abs, { north = vn, east = ve, lat = vlat, lon = vlon })
    end

    local zlat, zlon = compute_lat_lon(x, y)
    return {
        ok = true,
        zone = {
            id = zid,
            name = TZD.getTriggerZoneName(zid),
            shape = shape,
            type = tnum,
            north = x,
            east = y,
            lat = zlat,
            lon = zlon,
            radius = TZD.getTriggerZoneRadius(zid),
            color = { r, g, b, a },
            hidden = TZD.getTriggerZoneHidden(zid),
            properties = TZD.getTriggerZoneProperties(zid),
            link_unit_id = TZD.getLinkUnitId(zid),
            heading = TZD.getTriggerZone(zid) and TZD.getTriggerZone(zid):getHeading() or 0,
            points_relative = pts_rel,
            vertices_absolute = (tnum == 2) and pts_abs or nil,
        },
    }
end

return M
