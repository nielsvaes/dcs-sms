-- trigger_export.lua — convert mission.trigrules entries to the portable
-- prefab `triggers` form (spec: docs/superpowers/specs/
-- 2026-06-10-prefab-triggers-design.md §1), detect triggers related to a
-- selection, and extract structured-field flag references.
--
-- Pure transform: all ME access is injected via `env`:
--   env.schema       — trigger_schema instance
--   env.dict_get     — function(DictKey) → literal | nil
--   env.entity_name  — function(kind, id) → name | nil
--   env.media_read   — function(ResKey) → short_name, bytes | nil, err
--
-- Returns tables | nil, err. Never throws.

local b64 = require('dcs_sms_me.base64')

local M = {}

local function deep_copy(v, seen)
    if type(v) ~= 'table' then return v end
    seen = seen or {}
    if seen[v] then return nil end
    seen[v] = true
    local out = {}
    for k, vv in pairs(v) do out[k] = deep_copy(vv, seen) end
    seen[v] = nil
    return out
end

local function is_flag_field(id)
    return type(id) == 'string' and id:match('^flag%d*$') ~= nil
end

-- Convert one rule/action entry. Returns portable_entry; appends to
-- resources (dedup map by short name) + flags (set) + warnings.
local function convert_entry(entry, kind, env, resources, res_seen, flags, warnings)
    local schema = env.schema
    local pname = schema.predicate_name(entry.predicate)
    local _, _, descr = schema:resolve(pname)
    local fields = {}

    for k, v in pairs(entry) do
        if k == 'predicate' then
            -- emitted separately
        elseif type(k) == 'string' and k:sub(1, 8) == 'KeyDict_' then
            -- dictionary companion; re-allocated at import
        elseif type(v) == 'string' and v:sub(1, 8) == 'DictKey_' then
            local literal = env.dict_get and env.dict_get(v)
            if literal == nil then
                warnings[#warnings + 1] = pname .. '.' .. k
                    .. ': dictionary text unresolvable (' .. v .. '), kept key'
                fields[k] = v
            else
                fields[k] = literal
            end
        elseif type(v) == 'string' and v:sub(1, 7) == 'ResKey_' then
            local short, bytes
            if env.media_read then short, bytes = env.media_read(v) end
            if short and bytes then
                if not res_seen[short] then
                    res_seen[short] = true
                    resources[#resources + 1] = { name = short, data = b64.encode(bytes) }
                end
                fields[k] = { res = short }
            else
                warnings[#warnings + 1] = pname .. '.' .. k
                    .. ': media unreadable (' .. v .. '), reference kept but file NOT embedded'
                fields[k] = v
            end
        else
            local fd = schema.field_descr(descr, k)
            local refkind = fd and schema:field_kind(fd)
            if (refkind == 'group' or refkind == 'unit' or refkind == 'zone'
                    or refkind == 'airdrome') and type(v) == 'number' then
                local name = env.entity_name and env.entity_name(refkind, v)
                fields[k] = { ref = refkind, id = v, name = name }
                if name == nil then
                    warnings[#warnings + 1] = pname .. '.' .. k .. ': ' .. refkind
                        .. ' id ' .. tostring(v) .. ' has no name in this mission'
                end
            else
                fields[k] = deep_copy(v)
            end
            if is_flag_field(k) and (type(v) == 'number' or type(v) == 'string') then
                flags[v] = true
            end
        end
    end

    return { predicate = pname, fields = fields }
end

-- to_portable(entries, env) → { triggers, resources, flags_used, warnings } | nil, err
function M.to_portable(entries, env)
    if type(entries) ~= 'table' then return nil, 'entries must be a table' end
    if type(env) ~= 'table' or type(env.schema) ~= 'table' then
        return nil, 'env.schema required'
    end
    local schema = env.schema
    local triggers, resources, warnings = {}, {}, {}
    local res_seen, flags = {}, {}

    for _, t in ipairs(entries) do
        if type(t) == 'table' then
            local conditions, actions = {}, {}
            for _, r in ipairs(t.rules or {}) do
                conditions[#conditions + 1] =
                    convert_entry(r, 'condition', env, resources, res_seen, flags, warnings)
            end
            for _, a in ipairs(t.actions or {}) do
                actions[#actions + 1] =
                    convert_entry(a, 'action', env, resources, res_seen, flags, warnings)
            end
            local rec = {
                name       = t.comment or '',
                type       = schema.make_alias(t.predicate),
                eventlist  = t.eventlist or '',
                conditions = conditions,
                actions    = actions,
            }
            -- Trigger-list color. ED stores it on the trigger as the hex
            -- string `colorItem` ('0xrrggbbaa'); absent = the default list
            -- color. Carried so the prefab reproduces the author's
            -- color-coding when the triggers are imported elsewhere.
            if type(t.colorItem) == 'string' then rec.color = t.colorItem end
            triggers[#triggers + 1] = rec
        end
    end

    local flags_used = {}
    for fv in pairs(flags) do flags_used[#flags_used + 1] = fv end
    table.sort(flags_used, function(a, b) return tostring(a) < tostring(b) end)

    return {
        triggers   = triggers,
        resources  = resources,
        flags_used = flags_used,
        warnings   = warnings,
    }
end

-- Walk one trigger's rules+actions, calling fn(refkind, id, field_id)
-- for every entity reference found in structured fields.
local function walk_refs(t, schema, fn)
    local function walk_list(list)
        for _, entry in ipairs(list or {}) do
            local _, _, descr = schema:resolve(schema.predicate_name(entry.predicate))
            for k, v in pairs(entry) do
                if k ~= 'predicate' and type(v) == 'number' then
                    local fd = schema.field_descr(descr, k)
                    local refkind = fd and schema:field_kind(fd)
                    if refkind == 'group' or refkind == 'unit' or refkind == 'zone' then
                        fn(refkind, v, k)
                    end
                end
            end
        end
    end
    walk_list(t.rules)
    walk_list(t.actions)
end

-- find_related(trigrules, sel, schema) → { { index, trigger, refs,
--   outside_refs } } where sel = { group_ids = {set}, unit_ids = {set},
--   zone_ids = {set} }. A trigger is related iff ≥1 structured field
--   references a selected entity.
function M.find_related(trigrules, sel, schema)
    if type(trigrules) ~= 'table' or type(sel) ~= 'table' or type(schema) ~= 'table' then
        return {}
    end
    local sets = { group = sel.group_ids or {}, unit = sel.unit_ids or {},
                   zone = sel.zone_ids or {} }
    local out = {}
    for i, t in ipairs(trigrules) do
        if type(t) == 'table' then
            local refs, outside, hit = {}, {}, false
            walk_refs(t, schema, function(kind, id, field_id)
                local selected = sets[kind] and sets[kind][id] == true
                local rec = { kind = kind, id = id, field = field_id,
                              selected = selected or false }
                refs[#refs + 1] = rec
                if selected then hit = true else outside[#outside + 1] = rec end
            end)
            if hit then
                out[#out + 1] = { index = i, trigger = t, refs = refs,
                                  outside_refs = outside }
            end
        end
    end
    return out
end

-- extract_flags(entries, schema) → sorted unique array of flag values
-- referenced by structured fields (id matching ^flag%d*$). Used both for
-- meta.flags_used at save and the target-mission overlap scan at import.
function M.extract_flags(entries, schema)
    local flags = {}
    for _, t in ipairs(entries or {}) do
        if type(t) == 'table' then
            for _, list in ipairs({ t.rules or {}, t.actions or {} }) do
                for _, entry in ipairs(list) do
                    for k, v in pairs(entry) do
                        if is_flag_field(k)
                                and (type(v) == 'number' or type(v) == 'string') then
                            flags[v] = true
                        end
                    end
                end
            end
        end
    end
    local out = {}
    for fv in pairs(flags) do out[#out + 1] = fv end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

return M
