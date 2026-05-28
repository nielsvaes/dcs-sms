-- task_db.lua — lazy loader + cache over ED's me_action_db.
--
-- Public surface (call via `local T = require('dcs_sms_me.task_db')`):
--   T.resolve(task_id, group_task, kind) -> canonical, entry, err
--   T.list(group_task)                   -> { waypoint = {...}, enroute = {...} }, err
--   T.list_all()                         -> { { kind='waypoint', tasks={...} }, ... }, err
--   T.describe(task_id, kind)            -> entry, err   (kind may be nil to accept either)
--   T.descr_fields(entry)                -> {{id,type,default}, ...}
--   T.descr_default_params(entry)        -> shallow copy of entry.params
--   T.reset()                            -> nil          (testing hook: forget the cache)
--
-- Live probe (May 2026 ED Open Beta build) found me_action_db's top
-- level is mostly functions and constants — the task descriptors live
-- in `me_action_db.actionsData`, a 114-entry array where each entry
-- has `{desc, displayName, task={id, params}, type}`. The `type` field
-- discriminates: 1=waypoint task, 2=enroute task, 3=command, 4=option.
-- Only types 1 and 2 are in scope for gh #69; commands and options
-- wrap WrappedAction and are out of scope.
--
-- Task ids can appear multiple times in actionsData (e.g. EngageTargets
-- repeats 6× — presumably one variant per group-task context with
-- different defaults). We keep the first occurrence per (task_id, kind).
--
-- Group-task gating ("for a CAS group, only Bombing/AttackGroup/... are
-- legal") is NOT a static index in actionsData. ED does it at runtime
-- via me_action_db.isGroupCapableOfAction(group, action) which needs
-- a live group reference. v1 of gh #69 drops the static gate; the
-- group_task argument on resolve/list is accepted and ignored.
--
-- The cache is built once per ME session on first call. The mock-test
-- harness can inject a fake `me_action_db` via package.preload BEFORE
-- the first call.
--
-- See tools/me-mod/lua/dcs_sms_me/verbs/trigger_verbs.lua for the
-- predicate-cache analog this module is patterned after.

local M = {}

local _cache = nil   -- { by_id = { [TaskId] = entry, ... },
                     --   waypoint_ids = {sorted}, enroute_ids = {sorted} }
                     -- entry = { canonical = TaskId, kind = 'waypoint'|'enroute',
                     --           display_name = string, desc = string, params = table }

local function _safe_log(level_name, msg)
    local ok_log, log = pcall(function() return _G.log end)
    if ok_log and log and type(log.write) == 'function' then
        local lvl = log[level_name] or log.INFO
        log.write('sms.me.task_db', lvl, msg)
    end
end

local function _build()
    local ok, db = pcall(require, 'me_action_db')
    if not ok or type(db) ~= 'table' then
        return nil, "me_action_db not available (require failed) — this verb needs ED's MissionEditor/modules/me_action_db.lua"
    end
    if type(db.actionsData) ~= 'table' then
        return nil, "me_action_db.actionsData missing or wrong type — ED may have changed the module shape"
    end
    local TYPE_WAYPOINT, TYPE_ENROUTE = 1, 2
    local cache = { by_id = {}, waypoint_ids = {}, enroute_ids = {} }
    for _, a in ipairs(db.actionsData) do
        if type(a) == 'table' and type(a.task) == 'table' and type(a.task.id) == 'string' then
            local kind = (a.type == TYPE_WAYPOINT) and 'waypoint'
                      or (a.type == TYPE_ENROUTE)  and 'enroute'
                      or nil
            if kind and not cache.by_id[a.task.id] then
                cache.by_id[a.task.id] = {
                    canonical    = a.task.id,
                    kind         = kind,
                    display_name = a.displayName or a.task.id,
                    desc         = a.desc or '',
                    params       = (type(a.task.params) == 'table') and a.task.params or {},
                }
                table.insert(kind == 'waypoint' and cache.waypoint_ids or cache.enroute_ids, a.task.id)
            end
        end
    end
    table.sort(cache.waypoint_ids); table.sort(cache.enroute_ids)
    if not next(cache.by_id) then
        return nil, "me_action_db.actionsData walked but no task descriptors found"
    end
    _safe_log('INFO', string.format('task_db cache built (waypoint=%d, enroute=%d)',
        #cache.waypoint_ids, #cache.enroute_ids))
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
    -- group_task is accepted for backwards-compat (callers in route_verbs
    -- still pass it) but ignored: ED's group-task gating is runtime-only.
    local _ = group_task
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
    return entry.canonical, entry, nil
end

local function _copy_list(src)
    local out = {}
    for i, v in ipairs(src) do out[i] = v end
    return out
end

function M.list(group_task)
    -- group_task accepted for backwards-compat, ignored (no static gating).
    local _ = group_task
    local cache, err = _ensure()
    if not cache then return nil, err end
    return { waypoint = _copy_list(cache.waypoint_ids),
             enroute  = _copy_list(cache.enroute_ids) }, nil
end

function M.list_all()
    local cache, err = _ensure()
    if not cache then return nil, err end
    return {
        { kind = 'waypoint', tasks = _copy_list(cache.waypoint_ids) },
        { kind = 'enroute',  tasks = _copy_list(cache.enroute_ids)  },
    }, nil
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

-- M.descr_fields: flatten the entry.params defaults table into a sorted
-- list of {id, type, default} rows for JSON-friendly describe output.
function M.descr_fields(entry)
    local out = {}
    if type(entry) ~= 'table' or type(entry.params) ~= 'table' then
        return out
    end
    for k, v in pairs(entry.params) do
        table.insert(out, { id = k, type = type(v), default = v })
    end
    table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return out
end

-- M.descr_default_params: shallow copy of entry.params for use as a
-- base when the add-task verb composes a new task entry.
function M.descr_default_params(entry)
    if type(entry) ~= 'table' or type(entry.params) ~= 'table' then
        return {}
    end
    local copy = {}
    for k, v in pairs(entry.params) do copy[k] = v end
    return copy
end

return M
