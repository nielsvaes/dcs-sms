-- prefab_ops.lua — prefab save / load / place operations.
--
-- This file ships in three parts (one per group). Save + exists land
-- here in Task 4; scan_dir + load in Task 5; place in Task 6.
--
-- All public symbols return either a positive value (path, table,
-- record) on success, or nil + error_string on failure. No throws.

local lfs            = require('lfs')
local paths          = require('dcs_sms_me.paths')
local distill        = require('dcs_sms_me.prefab_distill').distill
local serializer     = require('dcs_sms_me.serializer')
local selection      = require('dcs_sms_me.selection')
local warehouse_ops  = require('dcs_sms_me.warehouse_ops')
local ship_warehouse = require('dcs_sms_me.ship_warehouse')
local cfg            = require('dcs_sms_me.community_config')

local M = {}

local function prefab_path(name)
    return paths.PREFABS_DIR .. name .. '.prefab'
end

local function legacy_prefab_path(name)
    return paths.PREFABS_DIR .. name .. '.lua'
end

-- Windows-reserved DOS device names. Reject regardless of case.
local DOS_RESERVED = {
    CON = true, PRN = true, AUX = true, NUL = true,
    COM1 = true, COM2 = true, COM3 = true, COM4 = true, COM5 = true,
    COM6 = true, COM7 = true, COM8 = true, COM9 = true,
    LPT1 = true, LPT2 = true, LPT3 = true, LPT4 = true, LPT5 = true,
    LPT6 = true, LPT7 = true, LPT8 = true, LPT9 = true,
}

-- Validate a single folder-name segment (NOT a path — no separators allowed).
-- Returns true on valid; false + reason on invalid.
function M._validate_folder_name(name)
    if type(name) ~= 'string' then return false, 'must be a string' end
    local trimmed = name:match('^%s*(.-)%s*$') or ''
    if trimmed == '' then return false, 'cannot be empty' end
    if trimmed:find('[<>:"/\\|%?%*]') then
        return false, 'contains a reserved character (< > : " / \\ | ? *)'
    end
    if trimmed:sub(1, 1) == '.' then return false, 'cannot start with a dot' end
    if DOS_RESERVED[trimmed:upper()] then
        return false, 'reserved Windows name'
    end
    return true
end

-- Validate a multi-segment folder path (in-memory '/'-form). Empty string is
-- valid (means "root"). Otherwise every segment must pass _validate_folder_name
-- AND be neither '.' nor '..' (path-traversal guard). Returns true on valid,
-- false + reason on invalid.
function M._validate_folder_path(folder_rel)
    if type(folder_rel) ~= 'string' then return false, 'must be a string' end
    if folder_rel == '' then return true end
    if folder_rel:find('\\') then
        return false, 'use / as folder separator, not \\'
    end
    for segment in folder_rel:gmatch('[^/]+') do
        if segment == '.' or segment == '..' then
            return false, 'folder path cannot contain "." or ".." segments'
        end
        local ok, why = M._validate_folder_name(segment)
        if not ok then return false, why end
    end
    return true
end

function M.exists(name)
    if type(name) ~= 'string' or name == '' then return false end
    local f = io.open(prefab_path(name), 'r')
    if f then f:close(); return true end
    f = io.open(legacy_prefab_path(name), 'r')
    if f then f:close(); return true end
    return false
end

-- Wrap a selection.snapshot() result into the dump-envelope shape that
-- prefab_distill.distill expects (top-level groups/statics/zones/drawings).
local function selection_to_dump(snap)
    return {
        groups   = snap.groups   or {},
        statics  = snap.statics  or {},   -- may be empty if statics ride inside groups (per Sub-project 2)
        zones    = snap.zones    or {},
        drawings = snap.drawings or {},
    }
end

local function any_selection(snap)
    return (#(snap.groups or {})   > 0)
        or (#(snap.statics or {})  > 0)
        or (#(snap.zones or {})    > 0)
        or (#(snap.drawings or {}) > 0)
end

function M.save_selection(name, place_at_origin, airbases, folder)
    if type(name) ~= 'string' or name == '' then
        return nil, 'name required'
    end
    folder = folder or ''
    local valid, why = M._validate_folder_path(folder)
    if not valid then return nil, 'invalid folder: ' .. why end
    if cfg.is_community_path(folder) then return nil, cfg.MANAGED_MSG end

    local snap = selection.snapshot()
    if not snap or not snap.ok then
        return nil, 'selection lookup failed: ' .. tostring(snap and snap.error or 'no snapshot')
    end
    if not any_selection(snap) then
        return nil, 'no selection — nothing to save'
    end

    local dump = selection_to_dump(snap)

    -- Capture the current theatre via Mission.TheatreOfWarData.getName(); same
    -- accessor ME core uses when serializing a mission (me_mission.lua ~4505)
    -- and when MissionEditor.lua bootstraps. The require path is
    -- `Mission.TheatreOfWarData`, NOT bare `TheatreOfWarData` — the bare path
    -- silently fails the require (was an actual bug here, fixed 2026-05-03).
    -- pcall-guarded so the standalone test VM (no DCS modules) and any future
    -- API rename degrade to no-theatre rather than failing the save.
    local theatre
    pcall(function()
        local TheatreOfWarData = require('Mission.TheatreOfWarData')
        if TheatreOfWarData and type(TheatreOfWarData.getName) == 'function' then
            theatre = TheatreOfWarData.getName()
        end
    end)

    local prefab = distill(dump, {
        name             = name,
        theatre          = theatre,
        place_at_origin  = place_at_origin == true,
        airbases         = airbases,
    })
    if not prefab then
        return nil, 'distill returned nil — check log for details'
    end

    -- After distill, attach per-ship warehouse data inline on each unit.
    -- The data rides through serialization on `unit._sms_warehouse` and
    -- gets spliced back at the new unitId during M.place. is_default
    -- filtering inside attach_to_prefab keeps untouched ships from
    -- bloating the file.
    pcall(ship_warehouse.attach_to_prefab, prefab)

    local serialized = serializer.serialize(prefab)
    if type(serialized) ~= 'string' then
        return nil, 'serialize returned non-string'
    end

    paths.ensure_prefab_folder(folder)
    local path = paths.folder_to_abs(folder) .. name .. '.prefab'
    local f, oerr = io.open(path, 'w')
    if not f then
        return nil, 'open failed: ' .. tostring(oerr)
    end
    f:write(serialized)
    f:close()

    return true, path
end

-- Move a prefab file from <source_folder>/<name>.prefab to
-- <target_folder>/<name>.prefab. Both folders are in-memory '/'-form
-- ('' = root). The prefab name is unchanged (rename-during-move is
-- not supported; use a separate workflow for that).
-- Returns true, new_path on success; nil, error_string on failure.
function M.move_prefab(source_folder, name, target_folder)
    if type(name) ~= 'string' or name == '' then
        return nil, 'name required'
    end
    source_folder = source_folder or ''
    target_folder = target_folder or ''
    local svalid, swhy = M._validate_folder_path(source_folder)
    if not svalid then return nil, 'invalid source folder: ' .. swhy end
    local tvalid, twhy = M._validate_folder_path(target_folder)
    if not tvalid then return nil, 'invalid target folder: ' .. twhy end
    if cfg.is_community_path(target_folder) then return nil, cfg.MANAGED_MSG end

    local source_path = paths.folder_to_abs(source_folder) .. name .. '.prefab'
    if not lfs.attributes(source_path) then
        return nil, 'source not found: ' .. source_path
    end

    paths.ensure_prefab_folder(target_folder)
    local target = paths.folder_to_abs(target_folder) .. name .. '.prefab'

    if target == source_path then
        return nil, 'source and target are the same'
    end

    if lfs.attributes(target) then
        return nil, 'target already exists: ' .. target
    end

    local ok, oerr = os.rename(source_path, target)
    if not ok then return nil, 'os.rename failed: ' .. tostring(oerr) end
    return true, target
end

-- Rename a folder under PREFABS_DIR.
-- old_rel / new_name are in-memory '/'-form; new_name is a single segment
-- (validated via _validate_folder_name) and replaces the *last* segment of
-- old_rel. Returns true, new_rel on success; nil, error_string on failure.
function M.rename_folder(old_rel, new_name)
    if type(old_rel) ~= 'string' or old_rel == '' then
        return nil, 'old folder required'
    end
    local ovalid, owhy = M._validate_folder_path(old_rel)
    if not ovalid then return nil, 'invalid folder: ' .. owhy end
    local valid, why = M._validate_folder_name(new_name)
    if not valid then return nil, why end

    -- Compute new_rel by replacing the last segment.
    local parent = old_rel:match('^(.+)/[^/]+$') or ''
    local new_rel = (parent == '' and new_name) or (parent .. '/' .. new_name)

    -- Community/ is import-managed: can't rename it (or a subfolder of it),
    -- and can't rename another folder INTO the reserved name.
    if cfg.is_community_path(old_rel) or cfg.is_community_path(new_rel) then
        return nil, cfg.MANAGED_MSG
    end

    local old_abs = paths.folder_to_abs(old_rel):sub(1, -2)  -- strip trailing '\'
    local new_abs = paths.folder_to_abs(new_rel):sub(1, -2)

    if not lfs.attributes(old_abs) then
        return nil, 'folder not found: ' .. old_rel
    end
    if old_abs == new_abs then
        return nil, 'old and new are the same'
    end

    -- Refuse if target already exists. lfs.attributes returns nil for missing.
    if lfs.attributes(new_abs) then
        return nil, 'target folder already exists: ' .. new_rel
    end

    local ok, oerr = os.rename(old_abs, new_abs)
    if not ok then return nil, 'os.rename failed: ' .. tostring(oerr) end
    return true, new_rel
end

-- Rename a single prefab file in place — i.e. keep its containing folder and
-- only swap the basename. old_path is the absolute path to the existing file
-- (as returned by scan_dir's `path`). new_name is a bare prefab name (no
-- extension, no separators) and replaces meta.name as well as the filename.
--
-- Returns true, new_path on success; false, error_string on failure. Returns
-- true, old_path (no-op) when old_path's basename already matches new_name.
function M.rename_file(old_path, new_name)
    if type(old_path) ~= 'string' or old_path == '' then
        return false, 'old_path required'
    end
    local valid, why = M._validate_folder_name(new_name)
    if not valid then return false, why end

    -- Derive new_path by replacing the basename of old_path. Match either
    -- separator so the function works regardless of how the caller assembled
    -- the path (folder_to_abs uses '\', tests/fixtures sometimes use '/').
    local dir = old_path:match('^(.*[\\/])[^\\/]+$')
    local new_path = (dir or '') .. new_name .. '.prefab'
    if old_path == new_path then return true, old_path end

    -- Collision check at the actual destination — NOT against PREFABS_DIR
    -- root. Also probe the legacy '.lua' sibling, since scan_dir treats both
    -- extensions as the same prefab.
    local probe = io.open(new_path, 'r')
    if probe then probe:close(); return false, 'target name already exists' end
    local legacy_path = new_path:gsub('%.prefab$', '.lua')
    probe = io.open(legacy_path, 'r')
    if probe then probe:close(); return false, 'target name already exists' end

    local prefab, lerr = M.load(old_path)
    if not prefab then return false, 'load failed: ' .. tostring(lerr) end
    prefab.meta = prefab.meta or {}
    prefab.meta.name = new_name

    local serialized = serializer.serialize(prefab)
    local f, oerr = io.open(new_path, 'w')
    if not f then return false, 'open failed: ' .. tostring(oerr) end
    f:write(serialized)
    f:close()

    local rok = os.remove(old_path)
    if not rok then
        os.remove(new_path)
        return false, 'could not delete old file (rolled back)'
    end
    return true, new_path
end

-- Recursively delete a folder under PREFABS_DIR.
-- Walks depth-first: os.remove every file, then lfs.rmdir each empty directory
-- bottom-up. Returns true on success; nil, error_string on failure (first error
-- aborts; the partial deletion is left in place — caller refreshes from disk).
function M.delete_folder(folder_rel)
    if type(folder_rel) ~= 'string' or folder_rel == '' then
        return nil, 'folder required'
    end
    local valid, why = M._validate_folder_path(folder_rel)
    if not valid then return nil, 'invalid folder: ' .. why end
    local abs = paths.folder_to_abs(folder_rel):sub(1, -2)
    if not lfs.attributes(abs) then
        return nil, 'folder not found: ' .. folder_rel
    end

    local function remove_recursive(dir_abs)
        for entry in lfs.dir(dir_abs) do
            if entry ~= '.' and entry ~= '..' then
                local sub = dir_abs .. '\\' .. entry
                local attr = lfs.attributes(sub)
                if attr and attr.mode == 'directory' then
                    local ok, err = remove_recursive(sub)
                    if not ok then return nil, err end
                elseif attr and attr.mode == 'file' then
                    local ok = os.remove(sub)
                    if not ok then return nil, 'remove failed: ' .. sub end
                end
            end
        end
        local ok = lfs.rmdir(dir_abs)
        if not ok then return nil, 'rmdir failed: ' .. dir_abs end
        return true
    end

    local ok, err = remove_recursive(abs)
    if not ok then return nil, err end
    return true
end

-- Count files + subfolders under a folder, recursively. Used by the
-- "Delete folder" confirmation UI. Returns file_count, subfolder_count.
-- Counts ALL files (not just .prefab) because delete_folder removes
-- every file under the tree — the confirmation must reflect what will
-- actually be deleted, including .bak / .lua legacy / stray notes.
function M.count_folder_contents(folder_rel)
    if type(folder_rel) ~= 'string' or folder_rel == '' then return 0, 0 end
    if not M._validate_folder_path(folder_rel) then return 0, 0 end
    local abs = paths.folder_to_abs(folder_rel):sub(1, -2)
    if not lfs.attributes(abs) then return 0, 0 end
    local files, dirs = 0, 0
    local function walk(d)
        for entry in lfs.dir(d) do
            if entry ~= '.' and entry ~= '..' then
                local sub = d .. '\\' .. entry
                local attr = lfs.attributes(sub)
                if attr and attr.mode == 'directory' then
                    dirs = dirs + 1
                    walk(sub)
                elseif attr and attr.mode == 'file' then
                    files = files + 1
                end
            end
        end
    end
    pcall(walk, abs)
    return files, dirs
end

-- ---------------------------------------------------------------------------
-- Load + scan
-- ---------------------------------------------------------------------------

function M.load(path)
    if type(path) ~= 'string' or path == '' then return nil, 'path required' end
    local ok, result = pcall(dofile, path)
    if not ok then return nil, 'dofile failed: ' .. tostring(result) end
    if type(result) ~= 'table' then return nil, 'file did not return a table' end
    if type(result.meta) ~= 'table' or type(result.meta.name) ~= 'string' then
        return nil, 'missing meta.name'
    end
    return result
end

local function count(t)
    if type(t) ~= 'table' then return 0 end
    return #t
end

-- Split a `groups` array into (non-static, static) counts. DCS represents
-- statics as groups with type='static' (see me_copy_paste.duplicateGroup
-- and the merge in `inject_group`), so prefab.statics is typically empty
-- and statics live inside prefab.groups. Counting them separately is what
-- lets the library's S column show a meaningful number.
local function split_group_counts(groups)
    if type(groups) ~= 'table' then return 0, 0 end
    local g, s = 0, 0
    for _, entry in ipairs(groups) do
        if type(entry) == 'table' and entry.type == 'static' then
            s = s + 1
        else
            g = g + 1
        end
    end
    return g, s
end

local function row_from_prefab(name, path, prefab)
    local meta = prefab.meta
    local g_count, s_inline = split_group_counts(prefab.groups)
    local airbase_count = 0
    if type(meta.airbases) == 'table' then airbase_count = #meta.airbases end
    -- Downloaded community prefabs carry meta.community = { author, source }
    -- (stamped by the Discord catalog bot). Surface it so the library can show
    -- the original author; own prefabs leave these unset.
    local is_community = type(meta.community) == 'table'
    return {
        name            = meta.name or name,
        path            = path,
        theatre         = meta.theatre,
        source_dump     = meta.source_dump,
        place_at_origin = meta.place_at_origin == true,
        community       = is_community,
        author          = is_community and meta.community.author or nil,
        airbase_count   = airbase_count,
        group_count     = g_count,
        -- Statics from inline `type='static'` groups + any in the legacy
        -- top-level statics array (older fixtures / hand-written prefabs).
        static_count    = s_inline + count(prefab.statics),
        zone_count      = count(prefab.zones),
        drawing_count   = count(prefab.drawings),
    }
end

function M.scan_dir()
    paths.ensure_prefabs()
    local rows = {}

    -- Recursive walker. `abs_dir` ends in '\'. `rel_folder` is the
    -- in-memory '/'-form ('' for root, 'CAP', 'CAP/Tomcats', ...).
    local function walk(abs_dir, rel_folder)
        local ok, err = pcall(function()
            for entry in lfs.dir(abs_dir) do
                if entry ~= '.' and entry ~= '..' then
                    local abs_path = abs_dir .. entry
                    local attr = lfs.attributes(abs_path)
                    if attr and attr.mode == 'directory' then
                        local sub_rel = (rel_folder == '' and entry) or (rel_folder .. '/' .. entry)
                        walk(abs_path .. '\\', sub_rel)
                    elseif attr and attr.mode == 'file' then
                        local name, is_legacy
                        if entry:match('%.prefab$') then
                            name = entry:gsub('%.prefab$', '')
                            is_legacy = false
                        elseif entry:match('%.lua$') then
                            name = entry:gsub('%.lua$', '')
                            is_legacy = true
                        end
                        if name then
                            local path = abs_path
                            if is_legacy then
                                -- Legacy migration: rename within the SAME subdirectory.
                                local new_path = abs_dir .. name .. '.prefab'
                                local existing = io.open(new_path, 'r')
                                if existing then
                                    existing:close()
                                    if log and log.write then
                                        log.write('sms.me.prefab', log.WARNING,
                                            'collision: ' .. name .. '.lua and ' .. name .. '.prefab both present in ' .. rel_folder .. ', leaving as-is')
                                    end
                                elseif os.rename(path, new_path) then
                                    if log and log.write then
                                        log.write('sms.me.prefab', log.INFO,
                                            'migrated ' .. rel_folder .. '/' .. name .. '.lua -> .prefab')
                                    end
                                    path = new_path
                                else
                                    if log and log.write then
                                        log.write('sms.me.prefab', log.WARNING,
                                            'rename failed for ' .. name .. '.lua in ' .. rel_folder .. ', keeping as-is')
                                    end
                                end
                            end
                            local prefab, lerr = M.load(path)
                            local row
                            if prefab then
                                row = row_from_prefab(name, path, prefab)
                            else
                                row = { name = name, path = path, error = lerr }
                            end
                            row.folder = rel_folder
                            rows[#rows + 1] = row
                        end
                    end
                end
            end
        end)
        if not ok then
            if log and log.write then
                log.write('sms.me.prefab', log.WARNING,
                    'scan_dir at "' .. tostring(rel_folder) .. '" failed: ' .. tostring(err))
            end
        end
    end

    walk(paths.PREFABS_DIR, '')

    table.sort(rows, function(a, b)
        if a.folder ~= b.folder then return a.folder < b.folder end
        return a.name < b.name
    end)
    return rows
end

-- ---------------------------------------------------------------------------
-- Place math (unit-testable, exposed under M._<name>)
-- ---------------------------------------------------------------------------

-- Rotate (rel_x, rel_y) by rotation_deg and translate to world coords.
-- DCS 2D map space: x = North, y = East (top-down view of the 3D world
-- space where x = North, z = East, y = altitude). heading 0 = +x = North.
-- We use a standard CCW rotation for relative placement: positive
-- rotation_deg increases heading (e.g. unit pointing North + 90° → East).
-- _rotate_mapData_geometry uses the same matrix so polygons rotate the
-- same way as the groups inside them.
function M._place_xy(rel_x, rel_y, anchor, rotation_deg)
    local r = (rotation_deg or 0) * (math.pi / 180)
    local c, s = math.cos(r), math.sin(r)
    local rx = rel_x * c - rel_y * s
    local ry = rel_x * s + rel_y * c
    return anchor.x + rx, anchor.y + ry
end

-- 0.1.0 back-compat: undo distill's incorrect per-vertex centroid
-- subtraction by adding (ax, ay) (= meta.world_anchor) back to every
-- {x,y} pair inside mapData's geometry sub-arrays. mapData.{x,y} itself
-- is the polygon anchor and stays untouched. No-op when mapData is nil.
function M._unrebase_mapData_geometry(mapData, ax, ay)
    if type(mapData) ~= 'table' then return end
    local function unrebase(t)
        if type(t) ~= 'table' then return end
        if type(t.x) == 'number' and type(t.y) == 'number' then
            t.x = t.x + ax
            t.y = t.y + ay
        end
        for _, sub in pairs(t) do
            if type(sub) == 'table' then unrebase(sub) end
        end
    end
    for k, v in pairs(mapData) do
        if k ~= 'x' and k ~= 'y' and type(v) == 'table' then
            unrebase(v)
        end
    end
end

-- Rotate every {x,y} pair inside mapData's geometry sub-arrays (points,
-- arc_points, etc.) by rotation_deg around the local origin. mapData.{x,y}
-- itself is the polygon's anchor and is NOT touched here — it rotates
-- downstream via _place_xy. No-op when rotation is 0 or mapData is nil.
function M._rotate_mapData_geometry(mapData, rotation_deg)
    if type(mapData) ~= 'table' then return end
    local deg = rotation_deg or 0
    if deg == 0 then return end
    local rad = deg * (math.pi / 180)
    local cs, sn = math.cos(rad), math.sin(rad)
    local function rotate_xy(t)
        if type(t) ~= 'table' then return end
        if type(t.x) == 'number' and type(t.y) == 'number' then
            local px, py = t.x, t.y
            t.x = px * cs - py * sn
            t.y = px * sn + py * cs
        end
        for _, sub in pairs(t) do
            if type(sub) == 'table' then rotate_xy(sub) end
        end
    end
    for k, v in pairs(mapData) do
        if k ~= 'x' and k ~= 'y' and type(v) == 'table' then
            rotate_xy(v)
        end
    end
end

-- Compose a stored heading (degrees) with a placement rotation, normalising
-- the result to [0, 360).  Input may be negative or > 360.
function M._heading_world(file_heading_deg, rotation_deg)
    local h = ((file_heading_deg or 0) + (rotation_deg or 0)) % 360
    if h < 0 then h = h + 360 end
    return h
end

-- Resolve the effective anchor and rotation from opts.
-- Returns anchor_table, rotation_deg — or nil if no valid anchor is available.
--
-- Rules:
--   keep_position = true  → anchor = prefab.meta.world_anchor, rotation forced 0
--   opts.anchor present   → use that anchor, rotation = opts.rotation or 0
--   otherwise             → nil (caller must report error)
function M._resolve_anchor(prefab, opts)
    if opts.keep_position then
        local wa = prefab.meta and prefab.meta.world_anchor
        if not (wa and type(wa.x) == 'number' and type(wa.y) == 'number') then
            return nil
        end
        return { x = wa.x, y = wa.y }, 0
    end
    if not (opts.anchor and type(opts.anchor.x) == 'number' and type(opts.anchor.y) == 'number') then
        return nil
    end
    return { x = opts.anchor.x, y = opts.anchor.y }, opts.rotation or 0
end

-- ---------------------------------------------------------------------------
-- Place — runtime ME-API injection
-- ---------------------------------------------------------------------------
-- The ME mutation API (discovered by reading me_copy_paste.lua and me_mission.lua):
--
--   Groups:
--     INSERT — `Mission.missionCountry[countryName][groupType].group` table is
--     the canonical data store; the blessed add path (from duplicateGroup in
--     me_copy_paste.lua) is:
--       1. Mission.create_group_objects(group)
--       2. table.insert(country[group.type].group, group)
--       3. Mission.create_group_map_objects(group)
--     For simple prefab injection we use `Mission.create_group` to create a
--     new shell, then the pattern above to insert a pre-built group table.
--     Because that still requires ME-internal country resolution, the wrapper
--     falls back to direct table.insert when `Mission.missionCountry` is
--     accessible — and degrades gracefully if it is not.
--     REMOVE — `Mission.remove_group(group)` takes the full group object
--     (NOT a bare ID).
--
--   Trigger zones:
--     INSERT — `TriggerZoneController.addTriggerZone(name, x, y, radius,
--               properties, color, type, points)` returns an id.
--     REMOVE — `TriggerZoneController.removeTriggerZone(id)`
--
--   Drawings:
--     INSERT — `panel_draw.copyObjToCoord(object, x, y)` — creates a copy
--              and returns the new object.  The returned object is what we
--              store in the undo record.
--     REMOVE — `panel_draw.objectDelete(object)` — takes the full object.
--
--   Statics in DCS are modelled as groups of type='static' and live in the
--   same country[type].group table as other group types.  There is no
--   separate addStaticObject symbol in the discovered ME API surface.
--
--   Note: `Mission.addGroup` and `Mission.addStaticObject` (as suggested in
--   the task template) do NOT exist in the examined DCS install
--   (2024-era, checked me_mission.lua 9759 lines). All group injection goes
--   through create_group_objects + missionCountry table.

-- Stamp a country override onto a copied group/static and its units. We
-- write country_name (a string) and clear the numeric country id so
-- resolve_country picks up the override at step 1. No-op for nil/empty
-- overrides — caller's signal that the prefab's own country should win.
local function override_country(group, country_name)
    if not country_name or country_name == '' then return end
    if type(group) ~= 'table' then return end
    group.country_name = country_name
    group.country = nil
    if type(group.units) == 'table' then
        for _, u in pairs(group.units) do
            if type(u) == 'table' then
                u.country_name = country_name
                u.country = nil
            end
        end
    end
end
M._override_country = override_country

-- Build a set of unit type names that `country_name` can deploy. Walks
-- DB.db.Countries (from me_db_api — same data the unit-creation panels
-- use) and unions the .Name field across every Units.<plural>.<subcat>
-- table — Ships, Planes, Helicopters, Cars, Fortifications, Cargos,
-- Heliports, Warehouses, etc. Returns nil when the DB API or country
-- entry isn't reachable so the caller can degrade to "skip the check"
-- rather than failing closed in environments without the DB (test VM,
-- pre-init bootstrap).
local function build_country_type_set(country_name)
    if type(country_name) ~= 'string' or country_name == '' then return nil end
    local ok, DB = pcall(require, 'me_db_api')
    if not ok or type(DB) ~= 'table' or type(DB.db) ~= 'table'
       or type(DB.db.Countries) ~= 'table' then
        return nil
    end
    local country
    for _, c in pairs(DB.db.Countries) do
        if type(c) == 'table' and c.Name == country_name then country = c; break end
    end
    if not country or type(country.Units) ~= 'table' then return nil end

    local set = {}
    for _, plural in pairs(country.Units) do
        if type(plural) == 'table' then
            for _, subcat in pairs(plural) do
                if type(subcat) == 'table' then
                    for _, entry in pairs(subcat) do
                        if type(entry) == 'table' and type(entry.Name) == 'string' then
                            set[entry.Name] = true
                        end
                    end
                end
            end
        end
    end
    return set
end

-- Walk a prefab and return the sorted, de-duplicated list of unit type
-- names that `country_name` doesn't support. nil return = "couldn't run
-- the check" (DB unavailable, missing country, etc.) — the caller should
-- treat that as proceed-without-validation. Empty array = country
-- supports every type in the prefab.
local function find_missing_types(prefab, country_name)
    local set = build_country_type_set(country_name)
    if not set then return nil end

    local missing, seen = {}, {}
    local function check_units(g)
        if type(g) ~= 'table' or type(g.units) ~= 'table' then return end
        for _, u in ipairs(g.units) do
            if type(u) == 'table' and type(u.type) == 'string' and u.type ~= ''
               and not set[u.type] and not seen[u.type] then
                seen[u.type] = true
                missing[#missing + 1] = u.type
            end
        end
    end
    if type(prefab) == 'table' then
        if type(prefab.groups)  == 'table' then for _, g in ipairs(prefab.groups)  do check_units(g) end end
        if type(prefab.statics) == 'table' then for _, g in ipairs(prefab.statics) do check_units(g) end end
    end
    table.sort(missing)
    return missing
end
M._find_missing_types = find_missing_types  -- exposed for tests

-- Walk every entity in a loaded prefab and return the axis-aligned bounding
-- box of their positions, in the prefab's anchor-relative coordinate frame
-- (the same frame distill writes). Returns nil if the prefab has no
-- positionable entities. Powers the place-at-click preview overlay.
--
--  groups   — group's own (x, y) plus each unit's (x, y).
--  statics  — same shape as groups (statics inject as type='static' groups).
--  zones    — zone center expanded by its radius.
--  drawings — mapData.x/y plus every point inside mapData.points (deltas
--             from the polygon anchor).
function M.compute_bbox(prefab)
    if type(prefab) ~= 'table' then return nil end
    local minx, miny =  math.huge,  math.huge
    local maxx, maxy = -math.huge, -math.huge
    local seen = false
    local function add(x, y)
        if type(x) ~= 'number' or type(y) ~= 'number' then return end
        seen = true
        if x < minx then minx = x end
        if x > maxx then maxx = x end
        if y < miny then miny = y end
        if y > maxy then maxy = y end
    end
    local function walk_group(g)
        if type(g) ~= 'table' then return end
        if type(g.x) == 'number' and type(g.y) == 'number' then add(g.x, g.y) end
        if type(g.units) == 'table' then
            for _, u in pairs(g.units) do
                if type(u) == 'table' and type(u.x) == 'number' and type(u.y) == 'number' then
                    add(u.x, u.y)
                end
            end
        end
    end
    for _, g in ipairs(prefab.groups   or {}) do walk_group(g) end
    for _, s in ipairs(prefab.statics  or {}) do walk_group(s) end
    for _, z in ipairs(prefab.zones    or {}) do
        if type(z.x) == 'number' and type(z.y) == 'number' then
            local r = tonumber(z.radius) or 0
            add(z.x - r, z.y - r)
            add(z.x + r, z.y + r)
        end
    end
    for _, d in ipairs(prefab.drawings or {}) do
        local md = d.mapData
        if type(md) == 'table' then
            local ax = tonumber(md.x) or 0
            local ay = tonumber(md.y) or 0
            add(ax, ay)
            if type(md.points) == 'table' then
                for _, p in ipairs(md.points) do
                    if type(p) == 'table' then add(ax + (p.x or 0), ay + (p.y or 0)) end
                end
            end
        end
    end
    if not seen then return nil end
    return { min_x = minx, min_y = miny, max_x = maxx, max_y = maxy }
end

-- Walk a group/static table and rewrite every {x, y} pair using the
-- place_xy transform. Mutates in place.
local function transform_coords(t, anchor, rotation_deg)
    if type(t) ~= 'table' then return end
    if type(t.x) == 'number' and type(t.y) == 'number' then
        t.x, t.y = M._place_xy(t.x, t.y, anchor, rotation_deg)
    end
    for _, v in pairs(t) do
        if type(v) == 'table' then transform_coords(v, anchor, rotation_deg) end
    end
end

-- Compose the prefab's stored heading (degrees, written by distill's
-- rad→deg conversion) with the placement rotation (degrees), then convert
-- the composed heading back to radians for DCS injection — DCS group/unit
-- tables expect heading in radians at runtime.
--
-- Earlier version had `v * (180 / math.pi)` here too, treating the file
-- value as radians; that was a bug (file is already in degrees) and caused
-- placed heading = stored * (180/pi) % 360 * (pi/180) ≈ stored * (180/pi)
-- modulo wrap, e.g. 45° → 1.0177 rad (~58.31°).
--
-- Assumption: every `heading` key encountered here is a body-frame
-- orientation that should rotate with the group. That holds for all
-- entities we currently distill (group-level + unit-level on groups and
-- statics; drawings + zones contain no `heading` keys). If a future
-- spec adds a heading-like field that's already in world frame (e.g.
-- a sensor bore-sight), the recursive walk below would incorrectly
-- rotate it — revisit then.
local function transform_headings(t, rotation_deg)
    if type(t) ~= 'table' then return end
    for k, v in pairs(t) do
        if k == 'heading' and type(v) == 'number' then
            t[k] = M._heading_world(v, rotation_deg) * (math.pi / 180)
        elseif type(v) == 'table' then
            transform_headings(v, rotation_deg)
        end
    end
end
M._transform_headings = transform_headings

-- Cross-prefab id remap. Walks a placed group recursively and rewrites every
-- known unit/group id reference using the supplied old→new maps. Driven by
-- the carrier-test bug: when a prefab contains units that reference each
-- other (statics linked to a carrier, aircraft starting on the carrier's
-- deck, the carrier's own TACAN/ICLS broadcasts, Link 16 datalinks, Escort/
-- EPLRS task params), the source mission ids must be remapped to the new
-- ids allocated for this placement — otherwise links silently break.
--
-- Reference fields handled:
--   unitId        — `linkUnit.unitId`, `helipadId` (waypoint), `missionUnitId`
--                   (Link 16 teamMembers), and ActivateBeacon / ActivateICLS
--                   / ActivateLink4 task params. Also rewrites the unit's
--                   own `unit.unitId` when it appears as a key.
--   groupId       — `task.params.groupId` (EPLRS, Escort), and the group's
--                   own `group.groupId`.
--   missionUnitId — Link 16 datalink network teamMembers.
--   helipadId     — waypoint binding to a ship deck slot.
--   airdromeId    — map airbase id; preserved when keep_airdrome_ids=true
--                   (placing at original anchor), nilled otherwise.
--
-- Lookup behaviour:
--   - If the value is in the map → rewritten to the new id.
--   - If the value is NOT in the map → nilled. Matches the pre-fix safety
--     behaviour for fields that were unconditionally nilled (linkUnit,
--     helipadId), and prevents stale cross-mission references from
--     surviving for fields that were unconditionally kept (task params,
--     datalink network).
--   - airdromeId is nilled-or-kept based solely on opts.keep_airdrome_ids.
--
-- Caller MUST pass maps built from the OLD ids of every group in the
-- prefab (across all groups, not just this one — that's the whole point;
-- a static linked to a carrier needs the carrier's old→new entry to
-- resolve the linkUnit reference).
local UID_KEYS = { unitId = true, missionUnitId = true, helipadId = true }
local GID_KEYS = { groupId = true }
function M._remap_ids(group, uid_map, gid_map, opts)
    if type(group) ~= 'table' then return end
    opts = opts or {}
    local keep_airdrome_ids = opts.keep_airdrome_ids == true
    uid_map = uid_map or {}
    gid_map = gid_map or {}

    -- Three-way classification per id value `v` encountered in the walk:
    --   (a) v is a SOURCE id (key of the map) → rewrite to map[v]
    --   (b) v is an already-allocated DEST id (value of the map) AND not
    --       also a source key → preserve (idempotency on re-walk)
    --   (c) v is in neither set → cross-mission reference; nil it
    --
    -- The pre-fix code used a single guard "if not is_new_uid[v]" — which
    -- collapsed cases (a) and (b) when source and dest spaces overlapped.
    -- Placing into a fresh mission, getNewUnitId starts at 1 and source ids
    -- also begin near 1, so overlap is the rule, not the exception. The
    -- effect was that any source id v whose value happened to also be a
    -- freshly-allocated dest got skipped, while another unit (whose source
    -- mapped TO v) got correctly remapped — both ended up with the same
    -- final unitId. Mission.unit_by_id[v] = whichever inject ran last;
    -- the other became a "ghost" group invisible to the marquee hit-test
    -- (which iterates Mission.unit_by_id). See GH#57.
    --
    -- Note on idempotency: when source and dest spaces overlap on a value
    -- that is BOTH a source key AND a dest value (e.g. uid_map[10]=50,
    -- uid_map[99]=10), a second walk over already-remapped data will
    -- re-rewrite that value (because case (a) wins over case (b) when the
    -- value is in both sets). M.place calls _remap_ids exactly once per
    -- group, so this does not arise in production. Tests in the
    -- non-overlapping case still demonstrate idempotency.
    local is_source_uid, is_new_uid = {}, {}
    for old, new in pairs(uid_map) do
        is_source_uid[old] = true
        is_new_uid[new] = true
    end
    local is_source_gid, is_new_gid = {}, {}
    for old, new in pairs(gid_map) do
        is_source_gid[old] = true
        is_new_gid[new] = true
    end

    local seen = {}
    local function walk(t)
        if type(t) ~= 'table' then return end
        if seen[t] then return end
        seen[t] = true
        for k, v in pairs(t) do
            if type(v) == 'number' then
                if UID_KEYS[k] then
                    if is_source_uid[v] then t[k] = uid_map[v]
                    elseif not is_new_uid[v] then t[k] = nil end
                elseif GID_KEYS[k] then
                    if is_source_gid[v] then t[k] = gid_map[v]
                    elseif not is_new_gid[v] then t[k] = nil end
                elseif k == 'airdromeId' then
                    if not keep_airdrome_ids then t[k] = nil end
                end
            elseif type(v) == 'table' then
                walk(v)
            end
        end
    end
    walk(group)
end

-- Deep-copy a table. Used so place can transform without mutating the
-- registered template (caller may place the same prefab multiple times).
local function deep_copy(v, seen)
    if type(v) ~= 'table' then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, vv in pairs(v) do out[k] = deep_copy(vv, seen) end
    return out
end

-- ME-API call wrappers.
-- Each returns (result_or_id, err_string_or_nil).
-- pcall guards degrade missing symbols to per-entity logged failures;
-- the overall place() still returns a partial record.

-- Resolve the country object + name from a prefab group's stored country
-- info. distill captures the numeric country id (group.country); the ME
-- mutation API needs the country NAME (as a key into Mission.missionCountry).
-- Order of attempts:
--   1. group.country_name (forward-compat — if a future distill writes it)
--   2. iterate Mission.missionCountry to find a country whose .id == ours
--   3. CoalitionController.getCountryNameById as a fallback
-- Returns: country_obj, country_name | nil, error_string
local function resolve_country(group)
    local Mission = require('me_mission')
    if type(Mission.missionCountry) ~= 'table' then
        return nil, 'Mission.missionCountry unavailable'
    end

    if type(group.country_name) == 'string'
        and Mission.missionCountry[group.country_name] then
        return Mission.missionCountry[group.country_name], group.country_name
    end

    if type(group.country) == 'number' then
        local id = group.country
        for name, c in pairs(Mission.missionCountry) do
            if type(c) == 'table' and c.id == id then
                return c, name
            end
        end
        local ok, ctrl = pcall(require, 'Mission.CoalitionController')
        if ok and ctrl and type(ctrl.getCountryNameById) == 'function' then
            local ok2, name = pcall(ctrl.getCountryNameById, id)
            if ok2 and type(name) == 'string' then
                local c = Mission.missionCountry[name]
                if c then return c, name end
            end
        end
        return nil, 'no country with id=' .. tostring(id) .. ' in current mission'
    end

    return nil, 'group has no country id or name'
end

-- Groups (and statics, which are groups of type='static') — full
-- duplicateGroup-style injection: assumes group.groupId / unit.unitId have
-- already been replaced with freshly-allocated ids by the caller (and that
-- intra-prefab id references have been remapped — see M._remap_ids), then
-- sets boss links, prep mapObjects, then create + insert + create_map_objects.
--
-- Mirrors the behavior of me_copy_paste.duplicateGroup but:
--   - resolves country from numeric id (we strip boss during distill)
--   - skips the Surface check (would pop a UI warning on water-placed)
--   - skips INUFixPoints / NavTargetPoints regeneration (rare;
--     v2 work if a real prefab needs them)
--
-- Id allocation + cross-prefab id remap happen in M.place's three-pass
-- pipeline (allocate → remap → inject) so that statics linked to a carrier
-- in the same prefab keep their linkUnit pointing at the carrier's NEW id
-- instead of being nilled. See the carrier-test bug write-up.
--
-- Removal (undo) goes through Mission.remove_group(group_obj) — see the
-- M._remove.group wrapper below.
--
-- ctx.keep_position (bool) — when true, preserve the source unit's
-- parking_id / parking / parking_landing[_id] verbatim (the prefab is being
-- placed at its original world anchor, so the source airfield IS the
-- destination airfield and parking-spot names are stable). When false,
-- strip the parking binding and let Pass F re-attract.
local function inject_group(group, ctx)
    local Mission = require('me_mission')

    local country, country_name_or_err = resolve_country(group)
    if not country then return nil, country_name_or_err end
    local country_name = country_name_or_err

    if not group.type or group.type == '' then
        return nil, 'group has no type field'
    end
    if not country[group.type] then country[group.type] = { group = {} } end
    if not country[group.type].group then country[group.type].group = {} end

    -- Reserve a fresh, conflict-free group name. The new groupId was
    -- already written by M.place via _remap_ids before we got here.
    local fresh_name = group.name or 'group'
    if type(Mission.check_group_name) == 'function' then
        local ok, n = pcall(Mission.check_group_name, fresh_name)
        if ok and type(n) == 'string' then fresh_name = n end
    end
    group.name = fresh_name
    if type(Mission.group_by_name) == 'table' then
        Mission.group_by_name[group.name] = group
    end
    if type(Mission.group_by_id) == 'table' and group.groupId then
        Mission.group_by_id[group.groupId] = group
    end
    group.boss = country
    -- Always reset mapObjects to empty stubs. Older prefabs (pre-GH#56)
    -- baked the source mission's render-side widget cache into the file;
    -- carrying that over here leaves duplicate target-zone markers on
    -- the map (see GH#56). The ME's create_group_map_objects rebuilds
    -- from `route.points` etc. when the placed group is first selected.
    group.mapObjects = { units = {}, zones = {}, route = {} }

    -- Color (best-effort — non-static groups carry color from coalition)
    if type(Mission.countryCoalition) == 'table'
        and Mission.countryCoalition[country_name]
        and Mission.countryCoalition[country_name].color then
        group.color = Mission.countryCoalition[country_name].color
    end

    -- Reserve fresh unit names; back-link to the group; strip parking links
    -- (only when not placing at original anchor — see ctx.keep_position).
    -- Unit ids were already remapped by _remap_ids before we got here.
    if type(group.units) == 'table' then
        for _, u in pairs(group.units) do
            if type(u) == 'table' then
                if type(Mission.getUnitName) == 'function' then
                    local ok, nm = pcall(Mission.getUnitName, group.name)
                    if ok and type(nm) == 'string' then u.name = nm end
                end
                u.boss = group
                if not (ctx and ctx.keep_position) then
                    u.parking = nil
                    u.parking_landing = nil
                    u.parking_id = nil
                    u.parking_landing_id = nil
                end
                -- Clear runtime link lists baked into the unit data by the
                -- source mission. distill strips `boss` back-refs, so each
                -- entry in here is half-dead — its `boss` is nil. ME's drag
                -- handler walks unit.linkChildren and accesses wpt.boss
                -- (me_map_window.lua:3086), which would nil-index and break
                -- ME state. Pass E rebuilds these lists with live entries
                -- via Mission.linkWaypoint. Mirrors me_copy_paste:337-338.
                u.linkChildren     = nil
                u.linkChildrenTZone = nil
                if type(Mission.unit_by_name) == 'table' and u.name then
                    Mission.unit_by_name[u.name] = u
                end
                if type(Mission.unit_by_id) == 'table' and u.unitId then
                    Mission.unit_by_id[u.unitId] = u
                end
            end
        end
    end

    -- Set the boss back-link on every route waypoint, and reset wpt.targets
    -- to empty. wpt.targets is the editor's denormalised mark cache for
    -- "task-with-a-zone" actions (Search Then Engage In Zone, AttackTargets-
    -- InZone, etc.) — it's a render-side artifact that me_action_map_objects
    -- rebuilds via insert_target when the actions panel first shows the
    -- task. Carrying the source mission's entries over would give two
    -- widgets per zone task (one from the data, one freshly inserted by
    -- mark.set when the user opens the panel for the placed group). DCS's
    -- own duplicate-group at me_copy_paste.lua:306 does the same reset.
    -- linkUnit / helipadId / airdromeId / nested task params were already
    -- handled by _remap_ids in M.place's pipeline.
    if type(group.route) == 'table' and type(group.route.points) == 'table' then
        for _, wpt in pairs(group.route.points) do
            if type(wpt) == 'table' then
                wpt.boss = group
                wpt.targets = {}
            end
        end
    end

    -- Insertion sequence (me_copy_paste.duplicateGroup lines 380-382)
    local ok_cgo, cgo_err = pcall(Mission.create_group_objects, group)
    if not ok_cgo then
        return nil, 'create_group_objects: ' .. tostring(cgo_err)
    end

    table.insert(country[group.type].group, group)

    local ok_cgmo, cgmo_err = pcall(Mission.create_group_map_objects, group)
    if not ok_cgmo then
        -- Already in the country's group table; visuals failed though.
        return group.groupId or true,
            'create_group_map_objects: ' .. tostring(cgmo_err)
    end

    -- Replay actionMapObjects.onTaskShow for every sub-task in the group's
    -- route. This is what me_actions_listbox.showTasksMapObjects does when
    -- the user clicks the group in the ME; running it here makes zone /
    -- mark widgets visible immediately on placement instead of only after
    -- the user touches the group. It also pre-populates the per-task
    -- elements[task].mark linkage so the next mark.set call (e.g. user
    -- double-clicks the task in the actions panel) moves the existing
    -- widget rather than inserting a second one.
    local ok_amo, actionMapObjects = pcall(require, 'me_action_map_objects')
    if ok_amo and actionMapObjects
        and type(actionMapObjects.onTaskShow) == 'function'
        and type(group.route) == 'table'
        and type(group.route.points) == 'table'
    then
        for _, wpt in ipairs(group.route.points) do
            if type(wpt) == 'table' and type(wpt.task) == 'table'
                and type(wpt.task.params) == 'table'
                and type(wpt.task.params.tasks) == 'table'
            then
                for _, subtask in ipairs(wpt.task.params.tasks) do
                    pcall(actionMapObjects.onTaskShow, group, wpt, subtask)
                end
            end
        end
        if type(group.tasks) == 'table' and group.route.points[1] then
            for _, subtask in ipairs(group.tasks) do
                pcall(actionMapObjects.onTaskShow, group, group.route.points[1], subtask)
            end
        end
    end

    return group.groupId or true
end

-- Trigger zones via TriggerZoneController.addTriggerZone.
-- Signature: addTriggerZone(name, x, y, radius, properties, color, type, points)
local function inject_zone(zone)
    local ok_req, ctrl = pcall(require, 'Mission.TriggerZoneController')
    if not ok_req or not ctrl then
        return nil, 'Mission.TriggerZoneController not available'
    end
    if type(ctrl.addTriggerZone) ~= 'function' then
        return nil, 'TriggerZoneController.addTriggerZone not available'
    end
    local name   = zone.name or 'Zone'
    local x      = zone.x or 0
    local y      = zone.y or 0
    local radius = zone.radius or 1000
    local props  = zone.properties or {}
    -- Color: prefer the .miz-shape `color = {r,g,b,a}` table written by
    -- prefab_distill's normalize_zone_color. Fall back to synthesizing
    -- from the live ME object's separate red/green/blue/alpha fields —
    -- backward compat for prefabs saved by ME-mod ≤ v0.3.2 (and any
    -- other source that captured the live TriggerZone's pairs() shape
    -- without normalizing). nil means "use addTriggerZone's default".
    local color = zone.color
    if not color and (type(zone.red) == 'number' or type(zone.green) == 'number'
        or type(zone.blue) == 'number' or type(zone.alpha) == 'number')
    then
        color = { zone.red or 1, zone.green or 1, zone.blue or 1, zone.alpha or 1 }
    end
    local ztype  = zone.type or 0
    local points = zone.points -- may be nil for circle zones
    local ok, result = pcall(ctrl.addTriggerZone, name, x, y, radius, props, color, ztype, points)
    if not ok then return nil, tostring(result) end
    return result  -- returns the new zone id
end

-- Drawings via panel_draw.copyObjToCoord.
--
-- copyObjToCoord(drawing, target_x, target_y) creates a copy and returns
-- the new object. Internally it calls MapWindow.createDrawObject(mapData)
-- to render at the geometry's current absolute coords, then
-- MapWindow.updateDrawObject(mapId, {target_x, target_y}) which shifts
-- the visual by (target_x - drawing.mapData.x).
--
-- Caller MUST pass target_{x,y} as the desired new world anchor and
-- leave drawing.mapData.{x,y} at the source coords so the shift delta
-- is non-zero. This is why we don't pre-set mapData.x/y in M.place's
-- drawing loop — see the comment block there.
--
-- The returned object (not just an id) is stored in the undo record so
-- that panel_draw.objectDelete can remove it.
local function inject_drawing(drawing, target_x, target_y)
    local ok_req, panel = pcall(require, 'me_draw_panel')
    if not ok_req or not panel then
        return nil, 'me_draw_panel not available'
    end
    if type(panel.copyObjToCoord) ~= 'function' then
        return nil, 'panel_draw.copyObjToCoord not available'
    end
    -- If caller didn't supply explicit target coords, fall back to
    -- whatever the drawing's mapData/top-level says (legacy paths).
    local tx = target_x or (drawing.mapData and drawing.mapData.x) or drawing.x or 0
    local ty = target_y or (drawing.mapData and drawing.mapData.y) or drawing.y or 0
    local ok, result = pcall(panel.copyObjToCoord, drawing, tx, ty)
    if not ok then return nil, tostring(result) end
    return result  -- returns the new drawing object
end

-- Remove wrappers — used by undo.lua.
-- Exposed as M._remove table so undo.lua can call them by entity type.

local function remove_group(group_obj)
    -- Mission.remove_group takes the full group object (not just an id).
    -- See me_copy_paste.lua lines 259 and 541.
    local ok_req, Mission = pcall(require, 'me_mission')
    if not ok_req or not Mission then
        return false, 'me_mission not available'
    end
    if type(Mission.remove_group) ~= 'function' then
        return false, 'Mission.remove_group not available'
    end
    return pcall(Mission.remove_group, group_obj)
end

local function remove_zone(zone_id)
    -- TriggerZoneController.removeTriggerZone(id).
    local ok_req, ctrl = pcall(require, 'Mission.TriggerZoneController')
    if not ok_req or not ctrl then
        return false, 'Mission.TriggerZoneController not available'
    end
    if type(ctrl.removeTriggerZone) ~= 'function' then
        return false, 'TriggerZoneController.removeTriggerZone not available'
    end
    return pcall(ctrl.removeTriggerZone, zone_id)
end

local function remove_drawing(drawing_obj)
    -- panel_draw.objectDelete(object) — takes the full object.
    -- See me_copy_paste.lua line 554 and me_draw_panel.lua objectDelete.
    local ok_req, panel = pcall(require, 'me_draw_panel')
    if not ok_req or not panel then
        return false, 'me_draw_panel not available'
    end
    if type(panel.objectDelete) ~= 'function' then
        return false, 'panel_draw.objectDelete not available'
    end
    return pcall(panel.objectDelete, drawing_obj)
end

M._remove = {
    group   = remove_group,
    zone    = remove_zone,
    drawing = remove_drawing,
}

-- M.place(prefab, opts) — inject a loaded prefab into the open mission.
--
-- opts fields:
--   anchor         {x, y}  — world map point to place at (required unless keep_position)
--   rotation       number  — clockwise rotation in degrees (default 0)
--   keep_position  bool    — ignore anchor/rotation; use prefab.meta.world_anchor as-is
--   country_name   string  — override every group/static/unit to this country
--                            (a key in Mission.missionCountry). Drawings and
--                            zones are unaffected. Nil/empty = use the country
--                            stored in the prefab.
--
-- Returns injection_record on (partial) success, or nil + error_string if
-- nothing could be injected.
--
-- injection_record fields:
--   prefab_name   string
--   groups        [{orig_name, runtime_id, group_obj}]
--   zones         [{orig_name, runtime_id}]
--   drawings      [{orig_name, drawing_obj}]
--   errors        [string]   — per-entity failures (partial success)
function M.place(prefab, opts)
    if type(prefab) ~= 'table' or type(prefab.meta) ~= 'table' then
        return nil, 'invalid prefab'
    end
    opts = opts or {}

    -- Validate country override against the open mission's country table.
    -- An override the mission can't satisfy means the user picked from a
    -- stale dropdown — surface as a hard error rather than silently falling
    -- back to the stored country.
    if opts.country_name and opts.country_name ~= '' then
        local Mission = require('me_mission')
        if type(Mission.missionCountry) ~= 'table'
            or not Mission.missionCountry[opts.country_name] then
            return nil, 'country "' .. tostring(opts.country_name) ..
                '" is not available in the current mission'
        end
        -- Catalog check: refuse if any prefab unit's type isn't in the
        -- selected country's catalog. Without this, the place succeeds
        -- visually but DCS silently falls back to a different model the
        -- next time the user clicks the unit (e.g. carrier → Hi-Speed
        -- Boat under Abkhazia) — opaque and easy to miss. Skips silently
        -- if the DB API isn't reachable.
        local missing = find_missing_types(prefab, opts.country_name)
        if missing and #missing > 0 then
            local label = (#missing == 1) and 'unit type' or 'unit types'
            return nil, 'country "' .. opts.country_name .. '" doesn\'t have ' .. label
                .. ' "' .. table.concat(missing, '", "') .. '" in its catalog'
                .. ' — pick a different country or save the prefab with the original countries'
        end
    end

    local anchor, rotation = M._resolve_anchor(prefab, opts)
    if not anchor then
        return nil, 'no anchor (and not keep_position)'
    end

    local record = {
        prefab_name = prefab.meta.name,
        groups   = {},
        zones    = {},
        drawings = {},
        errors   = {},
    }

    local function injection_count()
        return #record.groups + #record.zones + #record.drawings
    end

    -- Three-pass placement (allocate → remap → inject). Driven by the
    -- carrier-test bug: a static's linkUnit, an aircraft's helipadId, the
    -- carrier's own ActivateBeacon/ICLS unitId, Link 16 missionUnitId, and
    -- Escort/EPLRS task params all reference unit/group ids from the SOURCE
    -- mission. Allocating new ids per-group and nilling references (the old
    -- behavior) destroyed every intra-prefab link. The three-pass version
    -- builds a cross-prefab old→new id map first, then rewrites every
    -- known-id-bearing field via _remap_ids, then inject_group runs without
    -- re-allocating ids or nilling links.

    -- Pass A: deep-copy + transform every group/static into "placeable"
    -- entries. Keeps the per-group injection loop below working off the same
    -- copies _remap_ids will walk.
    local placeable = {}
    local function add_placeable(template, kind)
        local g = deep_copy(template)
        override_country(g, opts.country_name)
        transform_coords(g, anchor, rotation)
        transform_headings(g, rotation)
        placeable[#placeable + 1] = { template = template, copy = g, kind = kind }
    end
    for _, g_t in ipairs(prefab.groups  or {}) do add_placeable(g_t, 'group')  end
    for _, s_t in ipairs(prefab.statics or {}) do add_placeable(s_t, 'static') end

    -- Pass B: allocate fresh group + unit ids across ALL placeables and
    -- record old→new in cross-prefab maps. Uses Mission.getNewGroupId /
    -- getNewUnitId — same module-public allocators me_copy_paste relies on.
    local Mission = require('me_mission')
    local uid_map, gid_map = {}, {}
    for _, p in ipairs(placeable) do
        local g = p.copy
        if g.groupId and type(Mission.getNewGroupId) == 'function' then
            local ok, gid = pcall(Mission.getNewGroupId)
            if ok then gid_map[g.groupId] = gid end
        end
        if type(g.units) == 'table' then
            for _, u in ipairs(g.units) do
                if u.unitId and type(Mission.getNewUnitId) == 'function' then
                    local ok, uid = pcall(Mission.getNewUnitId)
                    if ok then uid_map[u.unitId] = uid end
                end
            end
        end
    end

    -- Pass C: remap. Rewrites group.groupId / unit.unitId AND every nested
    -- id reference (linkUnit, helipadId, missionUnitId, task params, ...)
    -- via the maps. References that don't resolve in-prefab get nilled
    -- (matches the pre-fix safety for cross-mission references). airdromeId
    -- is preserved only when placing at the original anchor.
    local remap_opts = { keep_airdrome_ids = opts.keep_position == true }
    for _, p in ipairs(placeable) do
        M._remap_ids(p.copy, uid_map, gid_map, remap_opts)
    end

    -- Pass D: per-group inject. inject_group no longer allocates ids or nils
    -- linkUnit/etc — passes A/B/C already handled both.
    -- ctx.keep_position carries through so the parking-strip can be skipped
    -- when placing at the original anchor (parking_id is airfield-relative
    -- and stable, so the source binding is meaningful at the destination).
    local inject_ctx = { keep_position = opts.keep_position == true }
    for _, p in ipairs(placeable) do
        local g = p.copy
        local label = p.kind == 'static' and 'static' or 'group'
        local result, err = inject_group(g, inject_ctx)
        if result then
            record.groups[#record.groups + 1] = {
                orig_name  = p.template.name,
                runtime_id = (type(result) == 'number') and result or g.groupId,
                group_obj  = g,  -- kept for undo (remove_group needs the full object)
            }
            if err then
                record.errors[#record.errors + 1] = label .. ' ' .. tostring(p.template.name)
                    .. ' (partial): ' .. err
            end
        else
            record.errors[#record.errors + 1] = label .. ' ' .. tostring(p.template.name)
                .. ': ' .. tostring(err)
        end
    end

    -- Pass E: establish the runtime link for any waypoint with a linkUnit
    -- that resolves to an in-prefab unit. _remap_ids set the right unitId
    -- in the linkUnit snapshot, but the ME's runtime needs a Mission.linkWaypoint
    -- call to:
    --   1. Replace the snapshot table with a live reference to the actual
    --      unit table (so move-handlers can reach it via wpt.linkUnit).
    --   2. Append the waypoint to unit.linkChildren — the list ME's delete
    --      logic walks. Without this, deleting the linked-to unit (e.g. the
    --      carrier) leaves orphaned statics/aircraft, which then breaks ME
    --      state walks like File > New (the orphan references a dead id).
    --
    -- This must run AFTER all groups are inserted (Pass D) so unit_by_id is
    -- fully populated. Mirrors me_copy_paste.duplicateGroup lines 383-391.
    --
    -- unlinkWaypoint nils helipadId / airdromeId as a side effect (see
    -- me_mission.lua linkWaypoint/unlinkWaypoint), so we stash + restore
    -- those — otherwise an aircraft starting on the carrier deck would lose
    -- its parking-spot binding to the relink dance.
    for _, p in ipairs(placeable) do
        local g = p.copy
        local wpt = g.route and g.route.points and g.route.points[1]
        if wpt and type(wpt.linkUnit) == 'table' then
            local link_uid = wpt.linkUnit.unitId
            if link_uid then
                local unitP = Mission.unit_by_id and Mission.unit_by_id[link_uid]
                if unitP and type(Mission.linkWaypoint) == 'function' then
                    local saved_linkOffset = g.linkOffset
                    local saved_helipadId = wpt.helipadId
                    local saved_airdromeId = wpt.airdromeId
                    pcall(Mission.unlinkWaypoint, wpt)
                    local ok = pcall(Mission.linkWaypoint, wpt, unitP.boss, unitP)
                    if ok then
                        g.linkOffset = saved_linkOffset
                        if saved_helipadId  then wpt.helipadId  = saved_helipadId  end
                        if saved_airdromeId then wpt.airdromeId = saved_airdromeId end
                    end
                end
            else
                -- linkUnit snapshot exists but its unitId was nilled by
                -- _remap_ids (out-of-prefab reference). Drop the half-broken
                -- snapshot so it doesn't surface as a phantom link.
                wpt.linkUnit = nil
            end
        end
    end

    -- Pass F: airfield re-attraction. Mirrors me_copy_paste.lua:393-398.
    --
    -- For airfield waypoints (TakeOffParking / TakeOff / TakeOffParkingHot /
    -- Landing / LandingReFuAr) that don't have a live linkUnit binding from
    -- Pass E, ask vanilla ME to assign a parking/runway slot at the
    -- destination. me_route.attractToAirfield(wpt, group) calls
    -- mod_parking.setAirGroupOnAirport(group, wpt.x, wpt.y) for parking-type
    -- takeoffs, which writes parking / parking_id / parking_landing[_id] back
    -- onto every unit in the group at the assigned slot.
    --
    -- Per-group, runs when EITHER:
    --   (a) opts.keep_position is false — placing at a new anchor, the source
    --       parking_id is meaningless at the destination airfield. *Or:*
    --   (b) any unit in the group has parking_id == nil after inject_group —
    --       prefab is from a pre-mid-2024 source mission that DCS never
    --       migrated in memory (ED added explicit parking_id storage around
    --       mid-2024; ME populates it at save time, not load time, so a
    --       2024-saved .miz opened in current ME keeps the un-migrated shape
    --       — the distilled prefab inherits it). attractToAirfield resolves
    --       the closest spot at the unit's (x, y); for a ramp-start aircraft
    --       the last-drag (x, y) is typically within tens of meters of the
    --       intended spot, so it usually picks correctly.
    --
    -- Skipped per-waypoint when wpt.linkUnit is a live table: that's a
    -- carrier-deck takeoff bound by Pass E. attractToAirfield internally
    -- calls module_mission.unlinkWaypoint(wpt) (me_route.lua:484), which
    -- would clobber the binding we just established.
    local ok_pr, panel_route = pcall(require, 'me_route')
    if ok_pr and panel_route
        and type(panel_route.isAirfieldWaypoint) == 'function'
        and type(panel_route.attractToAirfield) == 'function'
    then
        for _, p in ipairs(placeable) do
            local g = p.copy
            local needs_attract = (not opts.keep_position)
            if not needs_attract and type(g.units) == 'table' then
                -- Read parking_id AFTER inject_group ran. In keep_position mode
                -- the field is preserved verbatim, so a nil here means the source
                -- prefab never had it (pre-mid-2024 source mission, see comment
                -- block above). Iteration order doesn't matter — we just need
                -- to know whether ANY unit lacks parking_id.
                for _, u in ipairs(g.units) do
                    if type(u) == 'table' and not u.parking_id then
                        needs_attract = true
                        break
                    end
                end
            end
            if needs_attract and type(g.route) == 'table' and type(g.route.points) == 'table' then
                -- ipairs over route.points: attractToAirfield for non-takeoff
                -- waypoints (e.g. Landing) calls MapWindow.move_waypoint which
                -- mutates group.x/y, so processing waypoints in order matters.
                for _, wpt in ipairs(g.route.points) do
                    if type(wpt) == 'table'
                        and panel_route.isAirfieldWaypoint(wpt.type)
                        and not (type(wpt.linkUnit) == 'table' and wpt.linkUnit.unitId)
                    then
                        -- airdromeId nilled to match the vanilla mirror;
                        -- attractToAirfield writes a fresh airdromeId for
                        -- non-ship takeoffs anyway.
                        wpt.airdromeId = nil
                        pcall(panel_route.attractToAirfield, wpt, g)
                    end
                end
            end
        end
    end

    -- Zones.
    for _, z_template in ipairs(prefab.zones or {}) do
        local z = deep_copy(z_template)
        transform_coords(z, anchor, rotation)
        local id, err = inject_zone(z)
        if id then
            record.zones[#record.zones + 1] = { orig_name = z_template.name, runtime_id = id }
        else
            record.errors[#record.errors + 1] = 'zone ' .. tostring(z_template.name) .. ': ' .. tostring(err)
        end
    end

    -- Drawings — pipeline notes:
    --
    -- ME stores polygon vertices (mapData.points[i].{x,y}) RELATIVE to
    -- mapData.{x,y}. The renderer computes vertex world position as
    -- `mapData.x + points[i].x`. ME's own copy/paste (me_copy_paste.lua:651-653)
    -- just translates mapData.{x,y} and never touches the inner points.
    --
    -- distill at sms_prefab_version >= "0.2.0" preserves this invariant
    -- (skips geometry sub-arrays inside mapData when subtracting the
    -- centroid). Earlier versions ("0.1.0", or unset) had a bug that
    -- subtracted the centroid from each inner vertex too, breaking the
    -- relative-to-mapData invariant. We keep an un-rebase shim here that
    -- reverses that subtraction on those legacy files; it's gated on the
    -- meta.sms_prefab_version field so 0.2.0 saves don't get touched.
    --
    -- copyObjToCoord internals: createDrawObject(mapData) + moveObject
    -- (which updates mapData.{x,y} via updateDrawObject). So we LEAVE
    -- mapData.{x,y} at the post-distill (anchor-relative) value and pass
    -- target = anchor + rotated(post-distill xy) as the world center.
    local ax, ay = 0, 0
    if prefab.meta and prefab.meta.world_anchor then
        ax = prefab.meta.world_anchor.x or 0
        ay = prefab.meta.world_anchor.y or 0
    end
    -- Opt IN to the un-rebase shim for known-broken versions only. Earlier
    -- code did `~= '0.2.0'`, which would have silently fired the shim on a
    -- hypothetical future 0.3.0 save and double-added world_anchor into
    -- vertices that were never rebased. Treating it as a known-bad list
    -- means new versions stay safe by default; add to this list if a future
    -- format reintroduces the same bug.
    local v = (prefab.meta and prefab.meta.sms_prefab_version) or ''
    local needs_unrebase_shim = (v == '' or v == '0.1.0')

    for _, d_template in ipairs(prefab.drawings or {}) do
        local d = deep_copy(d_template)

        -- 0.1.0 back-compat: undo the over-rebase distill applied to
        -- vertices on legacy saves. New saves at 0.2.0+ skip this.
        if needs_unrebase_shim then
            M._unrebase_mapData_geometry(d.mapData, ax, ay)
        end

        -- Drawing rotation: vertices inside mapData are deltas relative to
        -- mapData.{x,y}, so rotating them around the local origin (0,0) is
        -- equivalent to rotating the polygon around its anchor. mapData.x/y
        -- itself rotates downstream via _place_xy.
        M._rotate_mapData_geometry(d.mapData, rotation)

        -- mapData.x/y is at anchor-relative coords from distill. Compute
        -- the new world center; pass it to copyObjToCoord as the target.
        local rel_x = (d.mapData and d.mapData.x) or d.x or 0
        local rel_y = (d.mapData and d.mapData.y) or d.y or 0
        local world_x, world_y = M._place_xy(rel_x, rel_y, anchor, rotation)

        local drawing_obj, err = inject_drawing(d, world_x, world_y)
        if drawing_obj then
            record.drawings[#record.drawings + 1] = {
                orig_name   = d_template.name,
                drawing_obj = drawing_obj,  -- kept for undo (objectDelete needs the full object)
            }
        else
            record.errors[#record.errors + 1] = 'drawing ' .. tostring(d_template.name) .. ': ' .. tostring(err)
        end
    end

    -- Log per-entity errors so the user can see WHY entities failed,
    -- not just a count. The 'see log' message above only helps if the
    -- log actually has the lines.
    if log and log.write and #record.errors > 0 then
        for _, e in ipairs(record.errors) do
            log.write('sms.me.prefab', log.ERROR, 'place: ' .. tostring(e))
        end
    end

    if injection_count() == 0 then
        return nil, 'no entities injected (' .. #record.errors .. ' errors — see log)'
    end

    -- Splice per-ship warehouse entries into mission.AirportsEquipment.warehouses
    -- using each placed unit's freshly-allocated unitId. Coalition is overridden
    -- by opts.override_coalition (lowercased) when the user picked a country
    -- whose coalition differs from what was saved.
    pcall(ship_warehouse.apply_from_record, record, {
        override_coalition = opts and opts.override_coalition,
    })

    return record
end

-- Apply meta.airbases to the live mission state. Re-resolves each entry by
-- airbase name (the airdromeNumber at save time may not match in the
-- destination mission). Theatre mismatch (or unknown prefab theatre) refuses
-- the whole step. Returns (true, summary) on success or (nil, summary_with_error)
-- on failure.
--
-- opts = {
--     current_theatre    = string?,  -- if set, refuse on theatre mismatch OR
--                                    -- when prefab has no recorded theatre
--                                    -- (we extracted these airbases from SOME
--                                    -- map; without provenance we can't verify
--                                    -- the destination is the right one)
--     override_coalition = string?,  -- if set ('RED'/'BLUE'/'NEUTRAL'), every applied
--                                    -- airbase ends up under this coalition instead
--                                    -- of whatever was saved into the prefab
-- }
--
-- summary = {
--     applied   = N,                 -- count of warehouses successfully spliced
--     skipped   = N,                 -- count of named airdromes NOT found in destination
--     missing   = { name1, ... },    -- names that were skipped
--     snapshots = {                  -- pre-write live state per applied airbase, in
--         { airdrome_number = N,     --   apply order. Consumed by undo.lua to roll
--           prev = entry|nil },      --   back the splice. prev=nil means there was
--         ...                        --   no prior live entry; on undo, those snaps
--     },                             --   are skipped (no clean "remove entry" path).
--     error     = string?,           -- set on hard failure (theatre mismatch, etc.)
-- }
function M.apply_airbases(prefab, opts)
    if type(prefab) ~= 'table' or type(prefab.meta) ~= 'table' then
        return nil, { applied = 0, skipped = 0, missing = {}, error = 'prefab missing meta' }
    end
    local airbases = prefab.meta.airbases
    if type(airbases) ~= 'table' or #airbases == 0 then
        return true, { applied = 0, skipped = 0, missing = {}, snapshots = {} }
    end

    opts = opts or {}
    local current_theatre = opts.current_theatre
    if current_theatre then
        if not prefab.meta.theatre or prefab.meta.theatre == '' then
            return nil, {
                applied = 0, skipped = #airbases, missing = {},
                error = 'prefab has no recorded theatre; cannot verify destination is the right map. Refusing to apply.',
            }
        end
        if prefab.meta.theatre ~= current_theatre then
            return nil, {
                applied = 0, skipped = #airbases, missing = {},
                error = 'theatre mismatch: prefab=' .. tostring(prefab.meta.theatre)
                        .. ' destination=' .. tostring(current_theatre),
            }
        end
    end

    local AC_ok, AC = pcall(require, 'Mission.AirdromeController')
    if not AC_ok or not AC or type(AC.getAirdromes) ~= 'function' then
        return nil, {
            applied = 0, skipped = #airbases, missing = {},
            error = 'AirdromeController unavailable',
        }
    end

    local by_name = {}
    for _, ad in ipairs(AC.getAirdromes() or {}) do
        if ad.getName then by_name[ad:getName()] = ad end
    end

    local override_coalition = opts.override_coalition
    local applied, skipped, missing, snapshots = 0, 0, {}, {}
    for _, ab in ipairs(airbases) do
        local ad = ab.name and by_name[ab.name] or nil
        if ad and ad.getAirdromeNumber then
            local n = ad:getAirdromeNumber()
            -- Snapshot pre-write live state before splicing. Stored on the
            -- summary so undo.lua can roll back per applied airbase. Capture
            -- BEFORE warehouse_ops.apply so the deep copy reflects the
            -- destination's prior state, not what we just wrote.
            local prev = warehouse_ops.extract(n)
            -- If an override coalition is supplied, build a shallow wrapper
            -- around the saved warehouse with the override applied. We don't
            -- mutate ab.warehouse — warehouse_ops.apply deep-copies what it
            -- receives, so a shallow wrapper is enough to keep the prefab
            -- table intact for any subsequent calls.
            local warehouse_to_apply = ab.warehouse
            if override_coalition and type(warehouse_to_apply) == 'table' then
                local wrapped = {}
                for k, v in pairs(warehouse_to_apply) do wrapped[k] = v end
                wrapped.coalition = override_coalition
                warehouse_to_apply = wrapped
            end
            local ok = warehouse_ops.apply(n, warehouse_to_apply)
            if ok then
                applied = applied + 1
                snapshots[#snapshots + 1] = { airdrome_number = n, prev = prev }
            else
                skipped = skipped + 1; missing[#missing + 1] = ab.name
            end
        else
            skipped = skipped + 1
            if ab.name then missing[#missing + 1] = ab.name end
        end
    end
    return true, { applied = applied, skipped = skipped, missing = missing, snapshots = snapshots }
end

return M
