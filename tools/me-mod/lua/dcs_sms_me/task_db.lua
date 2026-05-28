-- task_db.lua — lazy loader + cache over ED's me_action_db.
--
-- Public surface (call via `local T = require('dcs_sms_me.task_db')`):
--   T.resolve(task_id, group_task, kind) -> canonical, descr, err
--   T.list(group_task)                   -> { waypoint = {...}, enroute = {...} }, err
--   T.list_all()                         -> { { group_task=..., waypoint=..., enroute=... }, ... }, err
--   T.describe(task_id, kind)            -> descr, err   (kind may be nil to accept either)
--   T.reset()                            -> nil          (testing hook: forget the cache)
--
-- The cache is built once per ME session on first call. The mock-test
-- harness can inject a fake `me_action_db` via package.preload BEFORE
-- the first call.
--
-- See tools/me-mod/lua/dcs_sms_me/verbs/trigger_verbs.lua for the
-- predicate-cache analog this module is patterned after.

local M = {}

local _cache = nil   -- { by_id = { [TaskId] = entry, ... }, by_group_task = { [GT] = {wp={...},en={...}} } }
                      -- entry = { canonical = TaskId, kind = 'waypoint'|'enroute', descr = <descr>,
                      --           group_tasks = { GT1, GT2, ... } }

local function _safe_log(level, msg)
    local ok_log, log = pcall(function() return _G.log end)
    if ok_log and log and type(log.write) == 'function' then
        log.write('sms.me.task_db', level, msg)
    end
end

-- _walk_nested: me_action_db = { GT = { waypointTasks = {...}, enrouteTasks = {...} } }
local function _walk_nested(db)
    local cache = { by_id = {}, by_group_task = {} }
    for gt, gt_entry in pairs(db) do
        if type(gt_entry) == 'table' then
            local wp_list, en_list = {}, {}
            local function ingest(sub, kind, dest_list)
                if type(sub) ~= 'table' then return end
                for task_id, descr in pairs(sub) do
                    if type(task_id) == 'string' and type(descr) == 'table' then
                        table.insert(dest_list, task_id)
                        local entry = cache.by_id[task_id]
                        if not entry then
                            entry = { canonical = task_id, kind = kind, descr = descr, group_tasks = {} }
                            cache.by_id[task_id] = entry
                        end
                        -- group_tasks dedup
                        local seen = false
                        for _, g in ipairs(entry.group_tasks) do
                            if g == gt then seen = true; break end
                        end
                        if not seen then table.insert(entry.group_tasks, gt) end
                    end
                end
            end
            ingest(gt_entry.waypointTasks or gt_entry.waypoint_tasks, 'waypoint', wp_list)
            ingest(gt_entry.enrouteTasks  or gt_entry.enroute_tasks,  'enroute',  en_list)
            table.sort(wp_list); table.sort(en_list)
            cache.by_group_task[gt] = { waypoint = wp_list, enroute = en_list }
        end
    end
    return cache
end

-- _walk_flat: me_action_db = { TaskId = { kind=..., group_tasks={...}, ... } }
local function _walk_flat(db)
    local cache = { by_id = {}, by_group_task = {} }
    for task_id, descr in pairs(db) do
        if type(task_id) == 'string' and type(descr) == 'table' then
            local kind = descr.kind or descr.task_kind
            local gts  = descr.group_tasks or descr.groupTasks or {}
            if (kind == 'waypoint' or kind == 'enroute') and type(gts) == 'table' then
                cache.by_id[task_id] = {
                    canonical = task_id, kind = kind, descr = descr,
                    group_tasks = gts,
                }
                for _, gt in ipairs(gts) do
                    cache.by_group_task[gt] = cache.by_group_task[gt] or { waypoint = {}, enroute = {} }
                    table.insert(cache.by_group_task[gt][kind], task_id)
                end
            end
        end
    end
    for _, gt_lists in pairs(cache.by_group_task) do
        table.sort(gt_lists.waypoint); table.sort(gt_lists.enroute)
    end
    return cache
end

-- _looks_nested: heuristic. True if any value under db is a table that
-- contains `waypointTasks` or `enrouteTasks` (camelCase or snake_case).
local function _looks_nested(db)
    for _, v in pairs(db) do
        if type(v) == 'table' and (v.waypointTasks or v.enrouteTasks
                or v.waypoint_tasks or v.enroute_tasks) then
            return true
        end
    end
    return false
end

local function _count(t)
    local n = 0; for _ in pairs(t) do n = n + 1 end; return n
end

local function _build()
    local ok, db = pcall(require, 'me_action_db')
    if not ok or type(db) ~= 'table' then
        return nil, "me_action_db not available (require failed) — this verb needs ED's MissionEditor/modules/me_action_db.lua"
    end
    local shape_nested = _looks_nested(db)
    local cache = shape_nested and _walk_nested(db) or _walk_flat(db)
    if not next(cache.by_id) then
        return nil, "me_action_db loaded but no task descriptors found — ED may have changed the module shape (probe with `dcs-sms exec --target gui 'return type(require(\"me_action_db\"))'`)"
    end
    _safe_log('INFO', string.format('task_db cache built (shape=%s, tasks=%d)',
        shape_nested and 'nested' or 'flat', _count(cache.by_id)))
    return cache, nil
end

local function _ensure()
    if _cache then return _cache, nil end
    local c, err = _build()
    if not c then return nil, err end
    _cache = c
    return _cache, nil
end

function M.reset()
    _cache = nil
end

function M.resolve(task_id, group_task, kind)
    if type(task_id) ~= 'string' or task_id == '' then
        return nil, nil, 'task id is required'
    end
    local cache, err = _ensure()
    if not cache then return nil, nil, err end
    local entry = cache.by_id[task_id]
    if not entry then
        return nil, nil, 'unknown task id "' .. task_id .. '"'
    end
    if kind and entry.kind ~= kind then
        return nil, nil, 'task "' .. task_id .. '" is a ' .. entry.kind ..
                        ' task, not a ' .. kind .. ' task'
    end
    if group_task and group_task ~= '' then
        local ok_gt = false
        for _, g in ipairs(entry.group_tasks) do
            if g == group_task then ok_gt = true; break end
        end
        if not ok_gt then
            return nil, nil, 'task "' .. task_id .. '" is not legal for group task "'
                            .. group_task .. '"'
        end
    end
    return entry.canonical, entry.descr, nil
end

function M.list(group_task)
    local cache, err = _ensure()
    if not cache then return nil, err end
    local lists = cache.by_group_task[group_task]
    if not lists then
        return { waypoint = {}, enroute = {} }, nil
    end
    -- shallow-copy so callers can't mutate the cache
    local wp = {}; for i, v in ipairs(lists.waypoint) do wp[i] = v end
    local en = {}; for i, v in ipairs(lists.enroute)  do en[i] = v end
    return { waypoint = wp, enroute = en }, nil
end

function M.list_all()
    local cache, err = _ensure()
    if not cache then return nil, err end
    local out = {}
    local keys = {}
    for gt in pairs(cache.by_group_task) do table.insert(keys, gt) end
    table.sort(keys)
    for _, gt in ipairs(keys) do
        local lists = cache.by_group_task[gt]
        local wp = {}; for i, v in ipairs(lists.waypoint) do wp[i] = v end
        local en = {}; for i, v in ipairs(lists.enroute)  do en[i] = v end
        table.insert(out, { group_task = gt, waypoint = wp, enroute = en })
    end
    return out, nil
end

function M.describe(task_id, kind)
    if type(task_id) ~= 'string' or task_id == '' then
        return nil, 'task id is required'
    end
    local cache, err = _ensure()
    if not cache then return nil, err end
    local entry = cache.by_id[task_id]
    if not entry then return nil, 'unknown task id "' .. task_id .. '"' end
    if kind and entry.kind ~= kind then
        return nil, 'task "' .. task_id .. '" is a ' .. entry.kind .. ' task, not ' .. kind
    end
    return entry, nil
end

-- _descr_fields: best-effort flatten of a descriptor's parameter schema.
-- Used by describe-task to produce JSON-friendly output.
function M.descr_fields(descr)
    local out = {}
    if type(descr) ~= 'table' then return out end
    local fields = descr.fields or descr.params or descr.fields_schema
    if type(fields) ~= 'table' then
        -- fall back to inferring from the default params table
        local defaults = descr.default or descr.defaults or {}
        if type(defaults) == 'table' then
            for k, v in pairs(defaults) do
                table.insert(out, { id = k, type = type(v), default = v })
            end
        end
        table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
        return out
    end
    -- ordered list (1-indexed array)
    for _, f in ipairs(fields) do
        if type(f) == 'table' and type(f.id or f.name) == 'string' then
            local entry = { id = f.id or f.name }
            if f.type then entry.type = f.type end
            if f.default ~= nil then entry.default = f.default end
            if type(f.values) == 'table' then entry.options = f.values
            elseif type(f.options) == 'table' then entry.options = f.options end
            table.insert(out, entry)
        end
    end
    return out
end

-- M.descr_default_params: pull a defaults table out of the descriptor for
-- use as a base when the add-task verb composes a new task entry.
function M.descr_default_params(descr)
    if type(descr) ~= 'table' then return {} end
    local defaults = descr.default or descr.defaults
    if type(defaults) == 'table' then
        local copy = {}; for k, v in pairs(defaults) do copy[k] = v end
        return copy
    end
    -- derive from fields list
    local out = {}
    local fields = descr.fields or descr.params or descr.fields_schema
    if type(fields) == 'table' then
        for _, f in ipairs(fields) do
            if type(f) == 'table' and (f.id or f.name) and f.default ~= nil then
                out[f.id or f.name] = f.default
            end
        end
    end
    return out
end

return M
