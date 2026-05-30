-- task_db.lua — lazy loader + cache over ED's me_action_db.
--
-- Public surface (call via `local T = require('dcs_sms_me.task_db')`):
--   T.resolve(canonical_id, group_type, group_task, kind)
--       -> canonical, entry, err
--   T.list(group_type, group_task)
--       -> { waypoint = {...}, enroute = {...} }, err
--   T.list_all()
--       -> { { group_type='plane', group_task='CAS',
--              waypoint = {...}, enroute = {...} }, ... }, err
--   T.describe(canonical_id, kind)
--       -> entry, err   (kind may be nil to accept either)
--   T.descr_fields(entry)
--       -> {{id,type,default}, ...}
--   T.descr_default_params(entry)
--       -> shallow copy of entry.params
--   T.reset()
--       -> nil          (testing hook: forget the cache)
--
-- Live probe (May 2026 ED Open Beta) of me_action_db:
--
-- - `me_action_db.actionsData`: 114-entry array. Each entry =
--   `{ desc, displayName, task={id, key?, params}, type }`. `type`
--   discriminates: 1=waypoint task, 2=enroute task, 3=command,
--   4=option. Only types 1 and 2 are in scope for gh #69.
--
-- - Some entries share a `task.id` but carry distinct `task.key`
--   values — e.g. all 5 enroute "EngageTargets" variants have
--   `task.id="EngageTargets"` and `task.key in {CAS,CAP,SEAD,
--   FighterSweep,AntiShip}`. ED treats each variant as its own
--   action (different defaults, different group-task slot in
--   availableActions). We treat each variant as a distinct
--   canonical identifier: `canonical = task.key or task.id`.
--   So `--task CAS` resolves to the CAS-flavored EngageTargets,
--   `--task Bombing` to Bombing, etc.
--
-- - `me_action_db.availableActions`: the static legality index
--   `availableActions[group_type][type_num][group_task] = {action_id, ...}`
--   where each action_id is an integer index into actionsData. When
--   the group's `group_task` has no entry, fall back to
--   `availableActions[group_type][type_num]['Default']`. ED's UI uses
--   this same index to decide whether to render a task entry — if
--   the action's id isn't in this list, ED silently filters the task
--   out of the listbox even though the data persists. So gh #69
--   verbs MUST gate adds against this list, or the user gets a task
--   that's written into the .miz but invisible in the editor.
--
-- The cache is built once per ME session on first call. The mock-test
-- harness can inject a fake `me_action_db` via package.preload BEFORE
-- the first call.
--
-- See tools/me-mod/lua/dcs_sms_me/verbs/trigger_verbs.lua for the
-- predicate-cache analog this module is patterned after.

local M = {}

local TYPE_WAYPOINT, TYPE_ENROUTE = 1, 2

-- _cache shape:
--   {
--     by_canonical = {
--       [canonical_id] = {
--         canonical    = string,            -- task.key or task.id
--         task_id      = string,            -- DCS task.id (e.g. "EngageTargets")
--         task_key     = string|nil,        -- DCS task.key when present
--         kind         = 'waypoint'|'enroute',
--         action_id    = integer,           -- index into actionsData
--         display_name = string,
--         desc         = string,
--         params       = table,             -- task.params defaults
--       },
--       ...
--     },
--     by_action_id = { [action_id] = entry, ... },  -- reverse lookup
--     -- availability index, mirror of me_action_db.availableActions but
--     -- only types 1 and 2, mapped to canonical identifiers:
--     legal = {
--       [group_type] = {
--         waypoint = { [group_task_or_Default] = {canonical_id, ...} },
--         enroute  = { [group_task_or_Default] = {canonical_id, ...} },
--       },
--       ...
--     },
--   }
local _cache = nil

local function _safe_log(level_name, msg)
    local ok_log, log = pcall(function() return _G.log end)
    if ok_log and log and type(log.write) == 'function' then
        local lvl = log[level_name] or log.INFO
        log.write('sms.me.task_db', lvl, msg)
    end
end

local function _kind_for_type(t)
    if t == TYPE_WAYPOINT then return 'waypoint' end
    if t == TYPE_ENROUTE  then return 'enroute'  end
    return nil
end

local function _build()
    local ok, db = pcall(require, 'me_action_db')
    if not ok or type(db) ~= 'table' then
        return nil, "me_action_db not available (require failed) — this verb needs ED's MissionEditor/modules/me_action_db.lua"
    end
    if type(db.actionsData) ~= 'table' then
        return nil, "me_action_db.actionsData missing or wrong type — ED may have changed the module shape"
    end

    local cache = {
        by_canonical = {},
        by_action_id = {},
        legal = {},
    }

    -- Walk actionsData, build canonical entries
    for action_id, a in ipairs(db.actionsData) do
        local kind = _kind_for_type(a.type)
        if kind and type(a.task) == 'table' and type(a.task.id) == 'string' then
            local canonical = a.task.key or a.task.id
            -- If a duplicate (task.key or task.id) lands on the same canonical
            -- key (rare — only for unkeyed duplicates), keep the first.
            if not cache.by_canonical[canonical] then
                local entry = {
                    canonical    = canonical,
                    task_id      = a.task.id,
                    task_key     = a.task.key,
                    kind         = kind,
                    action_id    = action_id,
                    display_name = a.displayName or canonical,
                    desc         = a.desc or '',
                    params       = (type(a.task.params) == 'table') and a.task.params or {},
                }
                cache.by_canonical[canonical] = entry
                cache.by_action_id[action_id] = entry
            end
        end
    end

    -- Walk availableActions to build the legal-actions-per-(group_type, kind, group_task) index
    if type(db.availableActions) == 'table' then
        for group_type, by_action_type in pairs(db.availableActions) do
            if type(by_action_type) == 'table' then
                cache.legal[group_type] = { waypoint = {}, enroute = {} }
                for action_type, by_group_task in pairs(by_action_type) do
                    local kind = _kind_for_type(action_type)
                    if kind and type(by_group_task) == 'table' then
                        for group_task, action_id_list in pairs(by_group_task) do
                            if type(action_id_list) == 'table' then
                                local canon_list = {}
                                local seen = {}
                                for _, aid in ipairs(action_id_list) do
                                    local entry = cache.by_action_id[aid]
                                    if entry and not seen[entry.canonical] then
                                        table.insert(canon_list, entry.canonical)
                                        seen[entry.canonical] = true
                                    end
                                end
                                table.sort(canon_list)
                                cache.legal[group_type][kind][group_task] = canon_list
                            end
                        end
                    end
                end
            end
        end
    end

    if not next(cache.by_canonical) then
        return nil, "me_action_db.actionsData walked but no task descriptors found"
    end

    _safe_log('INFO', string.format(
        'task_db cache built (%d canonical task entries; %d group types in legal index)',
        (function() local n = 0; for _ in pairs(cache.by_canonical) do n = n + 1 end; return n end)(),
        (function() local n = 0; for _ in pairs(cache.legal) do n = n + 1 end; return n end)()))
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

-- _legal_for: return the array of canonical ids legal for
-- (group_type, kind, group_task), falling back to 'Default' when the
-- specific group_task isn't indexed. Returns {} if nothing matches.
local function _legal_for(cache, group_type, kind, group_task)
    local by_group = cache.legal[group_type] and cache.legal[group_type][kind]
    if not by_group then return {} end
    if group_task and by_group[group_task] then return by_group[group_task] end
    return by_group['Default'] or {}
end

function M.resolve(canonical_id, group_type, group_task, kind)
    if type(canonical_id) ~= 'string' or canonical_id == '' then
        return nil, nil, 'task id is required'
    end
    local cache, err = _ensure()
    if not cache then return nil, nil, err end
    local entry = cache.by_canonical[canonical_id]
    if not entry then
        return nil, nil, 'unknown task id "' .. canonical_id .. '"'
    end
    if kind and entry.kind ~= kind then
        return nil, nil, 'task "' .. canonical_id .. '" is a ' .. entry.kind ..
                        ' task, not a ' .. kind .. ' task'
    end
    -- Static legality gate via availableActions. Only checked when caller
    -- passes both group_type AND group_task — bare resolve()s skip the
    -- gate (used by describe / classification).
    if group_type and group_task and group_task ~= '' then
        local legal = _legal_for(cache, group_type, entry.kind, group_task)
        local ok = false
        for _, c in ipairs(legal) do
            if c == canonical_id then ok = true; break end
        end
        if not ok then
            return nil, nil, 'task "' .. canonical_id .. '" is not a legal ' ..
                             entry.kind .. ' task for group type "' .. group_type ..
                             '" with main task "' .. group_task ..
                             '" (run `me waypoint list-tasks --group-name <X>` to see legal ids)'
        end
    end
    return entry.canonical, entry, nil
end

local function _copy_list(src)
    local out = {}
    for i, v in ipairs(src) do out[i] = v end
    return out
end

function M.list(group_type, group_task)
    local cache, err = _ensure()
    if not cache then return nil, err end
    if group_type and group_task and group_task ~= '' then
        return {
            waypoint = _copy_list(_legal_for(cache, group_type, 'waypoint', group_task)),
            enroute  = _copy_list(_legal_for(cache, group_type, 'enroute',  group_task)),
        }, nil
    end
    -- No group context: return all canonical ids by kind (sorted).
    local wp, en = {}, {}
    for canonical, entry in pairs(cache.by_canonical) do
        if entry.kind == 'waypoint' then table.insert(wp, canonical)
        else table.insert(en, canonical) end
    end
    table.sort(wp); table.sort(en)
    return { waypoint = wp, enroute = en }, nil
end

function M.list_all()
    local cache, err = _ensure()
    if not cache then return nil, err end
    local out = {}
    local gtypes = {}
    for gt in pairs(cache.legal) do table.insert(gtypes, gt) end
    table.sort(gtypes)
    for _, group_type in ipairs(gtypes) do
        local by_kind = cache.legal[group_type]
        local gtasks = {}
        local seen_gt = {}
        for _, kind in ipairs({'waypoint', 'enroute'}) do
            for group_task in pairs(by_kind[kind] or {}) do
                if not seen_gt[group_task] then
                    table.insert(gtasks, group_task); seen_gt[group_task] = true
                end
            end
        end
        table.sort(gtasks)
        for _, group_task in ipairs(gtasks) do
            table.insert(out, {
                group_type = group_type,
                group_task = group_task,
                waypoint   = _copy_list(by_kind.waypoint[group_task] or {}),
                enroute    = _copy_list(by_kind.enroute [group_task] or {}),
            })
        end
    end
    return out, nil
end

function M.describe(canonical_id, kind)
    if type(canonical_id) ~= 'string' or canonical_id == '' then
        return nil, 'task id is required'
    end
    local cache, err = _ensure()
    if not cache then return nil, err end
    local entry = cache.by_canonical[canonical_id]
    if not entry then return nil, 'unknown task id "' .. canonical_id .. '"' end
    if kind and entry.kind ~= kind then
        return nil, 'task "' .. canonical_id .. '" is a ' .. entry.kind .. ' task, not ' .. kind
    end
    return entry, nil
end

-- M.describe_by_stored: look up an entry from an in-mission task table.
-- Required because what's stored at wp.task.params.tasks[i] carries
-- (id, key, ...) and we need to find the right canonical entry —
-- task.key takes precedence when present, otherwise task.id.
function M.describe_by_stored(stored_task)
    if type(stored_task) ~= 'table' then return nil, 'stored task is not a table' end
    local canonical = stored_task.key or stored_task.id
    if type(canonical) ~= 'string' then return nil, 'stored task has no id/key' end
    return M.describe(canonical, nil)
end

-- _load_extras: lazy-require task_extras.lua. Optional; missing module
-- is treated as "no supplementary descriptors" and never blocks
-- describe_fields. Re-evaluated each call so tests / dev-reload pick up
-- edits.
local function _load_extras()
    local ok, extras = pcall(require, 'dcs_sms_me.task_extras')
    if not ok or type(extras) ~= 'table' then return nil end
    return extras
end

-- _copy_field_spec: shallow-copy one entry from task_extras to avoid
-- exposing the cached table to caller mutation.
local function _copy_field_spec(f)
    local out = {}
    for k, v in pairs(f) do
        if type(v) == 'table' then
            local sub = {}
            for i, vv in ipairs(v) do sub[i] = vv end
            out[k] = sub
        else
            out[k] = v
        end
    end
    return out
end

-- M.descr_fields: flatten the entry.params defaults table into a sorted
-- list of {id, type, default} rows for JSON-friendly describe output.
-- When task_extras carries a richer schema for this task's canonical id,
-- the `always` fields replace the actionsData defaults and `variants`
-- are returned via a separate selector entry on each field.
function M.descr_fields(entry)
    local out = {}
    if type(entry) ~= 'table' then return out end

    local extras = _load_extras()
    local task_extras = extras and entry.canonical and extras[entry.canonical]

    if task_extras then
        -- "always" fields take precedence over actionsData defaults.
        for _, f in ipairs(task_extras.always or {}) do
            table.insert(out, _copy_field_spec(f))
        end
        if task_extras.selector then
            table.insert(out, _copy_field_spec(task_extras.selector))
        end
        table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
        return out
    end

    if type(entry.params) ~= 'table' then return out end
    for k, v in pairs(entry.params) do
        table.insert(out, { id = k, type = type(v), default = v })
    end
    table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return out
end

-- M.descr_variants: return the array of pattern-conditional variants
-- (each { value=..., fields={...} }) for the entry, or nil if the task
-- has no task_extras entry. Used by waypoint_describe_task to surface
-- per-pattern extra fields alongside the always-on schema.
function M.descr_variants(entry)
    if type(entry) ~= 'table' or not entry.canonical then return nil end
    local extras = _load_extras()
    local task_extras = extras and extras[entry.canonical]
    if not task_extras or type(task_extras.variants) ~= 'table' then return nil end
    local out = {}
    for _, v in ipairs(task_extras.variants) do
        local copy = { value = v.value, fields = {} }
        for i, f in ipairs(v.fields or {}) do
            copy.fields[i] = _copy_field_spec(f)
        end
        table.insert(out, copy)
    end
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
