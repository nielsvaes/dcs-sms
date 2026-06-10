-- trigger_import.lua — rebind + inject portable prefab triggers into the
-- open mission's trigrules. Two halves:
--   M.resolve(portable, maps, env) → plan   (pure; this file, Task 5)
--   M.inject(plan, decisions, env)          (Task 7)
--
-- Resolution order per entity ref (spec §3):
--   1. placement id-map  (groups/units by old id; ZONES BY NAME — prefab
--      zones carry no persistent ids, the place record pairs
--      orig_name → runtime_id)
--   2. name lookup in the target mission
--   3. descriptor default (spec §4 stray-default rule)
--   4. unresolved → manual-map row in the import dialog
--
-- Never throws; resolve returns a plan even for empty input.

local M = {}

local function ref_key(t_idx, list, entry_idx, field)
    return string.format('%d/%s/%d/%s', t_idx, list, entry_idx, field)
end

local function resolve_one(kind, id, name, maps, env, descr, field)
    -- 1. placement map
    if kind == 'group' and maps.gid_map and id ~= nil and maps.gid_map[id] then
        return 'map', maps.gid_map[id]
    end
    if kind == 'unit' and maps.uid_map and id ~= nil and maps.uid_map[id] then
        return 'map', maps.uid_map[id]
    end
    if kind == 'zone' and maps.zone_by_name and name and maps.zone_by_name[name] then
        return 'map', maps.zone_by_name[name]
    end
    -- 2. name lookup
    if name and type(env.find_by_name) == 'function' then
        local found = env.find_by_name(kind, name)
        if found ~= nil then return 'name', found end
    end
    -- 3. descriptor default
    local default = env.schema.field_default(descr, field)
    if default ~= nil then return 'default', default end
    -- 4. give up
    return 'unresolved', nil
end

function M.resolve(portable, maps, env)
    maps = maps or {}
    env = env or {}
    local plan = { triggers = {}, flag_overlaps = {} }
    if type(portable) ~= 'table' or type(env.schema) ~= 'table' then
        return plan
    end
    -- Accept either the triggers array itself or the whole to_portable
    -- bundle ({triggers=..., resources=...}) — passing the bundle is an
    -- easy caller mistake that would otherwise yield a silently empty plan.
    if type(portable.triggers) == 'table' and portable[1] == nil then
        portable = portable.triggers
    end
    local schema = env.schema

    for t_idx, raw_trig in ipairs(portable) do
        local trig = type(raw_trig) == 'table' and raw_trig or {}
        local refs, unresolved = {}, 0
        local actions_with_unresolved = {}

        local function scan(list_name, entries)
            if type(entries) ~= 'table' then return end
            for e_idx, entry in ipairs(entries) do
                -- Prefab files are user-editable (and Community ones are
                -- untrusted): tolerate malformed entries rather than throw.
                local fields = type(entry) == 'table' and entry.fields or nil
                local _, _, descr
                if type(entry) == 'table' then
                    _, _, descr = schema:resolve(entry.predicate)
                end
                for field, v in pairs(type(fields) == 'table' and fields or {}) do
                    if type(v) == 'table' and v.ref then
                        local resolution, value =
                            resolve_one(v.ref, v.id, v.name, maps, env, descr, field)
                        if resolution == 'unresolved' then
                            unresolved = unresolved + 1
                            if list_name == 'actions' then
                                actions_with_unresolved[e_idx] = true
                            end
                        end
                        refs[#refs + 1] = {
                            list = list_name, entry = e_idx, field = field,
                            kind = v.ref, id = v.id, name = v.name,
                            resolution = resolution, value = value,
                            key = ref_key(t_idx, list_name, e_idx, field),
                        }
                    end
                end
            end
        end
        scan('conditions', trig.conditions)
        scan('actions', trig.actions)

        local n_actions = #(trig.actions or {})
        local n_bad = 0
        for _ in pairs(actions_with_unresolved) do n_bad = n_bad + 1 end

        plan.triggers[#plan.triggers + 1] = {
            portable = trig,
            refs = refs,
            unresolved = unresolved,
            would_lose_all_actions = (n_actions > 0 and n_bad == n_actions),
        }
    end

    -- Flag overlap: values present in both arrays (spec decision 6: warn
    -- only). Compare by tostring — ED stores flag fields as number OR
    -- string depending on entry path, so 100 in one mission and '100' in
    -- another are the same flag.
    local target_set = {}
    for _, fv in ipairs(env.target_flags or {}) do target_set[tostring(fv)] = true end
    local seen = {}
    for _, fv in ipairs(env.prefab_flags or {}) do
        local k = tostring(fv)
        if target_set[k] and not seen[k] then
            seen[k] = true
            plan.flag_overlaps[#plan.flag_overlaps + 1] = fv
        end
    end
    table.sort(plan.flag_overlaps, function(a, b) return tostring(a) < tostring(b) end)

    return plan
end

local b64 = require('dcs_sms_me.base64')

-- Action fields that round-trip through the dictionary (mirrors ED's
-- saveTriggers / trigger_verbs' ACTION_DICT_FIELDS). a_do_script's text
-- is a raw script literal — never dict-keyed.
local ACTION_DICT_FIELDS = {
    text      = 'ActionText',
    radiotext = 'ActionRadioText',
    comment   = 'ActionComment',
}

-- Build one trigrules sub-entry (rule or action) from a portable entry.
-- Returns entry | nil (dropped), err_or_nil.
local function build_entry(portable_entry, kind, t_idx, list_name, e_idx,
                           resolved_by_key, decisions, env, media_cache, errors)
    local schema = env.schema
    local canonical, _, descr, err = schema:resolve(portable_entry.predicate, kind)
    if err then return nil, err end

    local factory = (kind == 'condition') and env.create_rule or env.create_action
    local entry
    if type(factory) == 'function' then
        local ok, built = pcall(factory, descr)
        if ok and type(built) == 'table' then entry = built end
    end
    if entry == nil then entry = { predicate = descr } end
    -- entry.predicate must stay the descriptor table (ED save reads .name).

    local bindings = (decisions and decisions.bindings) or {}

    for field, v in pairs(portable_entry.fields or {}) do
        if type(v) == 'table' and v.ref then
            local key = string.format('%d/%s/%d/%s', t_idx, list_name, e_idx, field)
            local planned = resolved_by_key[key]
            local value
            if planned and planned.resolution ~= 'unresolved' then
                value = planned.value
            else
                local b = bindings[key]
                if b == 'skip' then
                    return nil, nil  -- user chose to drop this condition/action
                end
                value = b
            end
            if value == nil then
                -- Unresolved and unbound: drop the entry, report.
                errors[#errors + 1] = (portable_entry.predicate or '?') .. '.' .. field
                    .. ': reference to ' .. tostring(v.name or v.id)
                    .. ' unbound — entry dropped'
                return nil, nil
            end
            entry[field] = value
        elseif type(v) == 'table' and v.res then
            local res_key = media_cache[v.res]
            if res_key == nil then
                local data = env.resources and env.resources[v.res]
                if type(data) == 'string' then
                    local bytes = b64.decode(data)
                    if bytes then
                        local prefix = (canonical == 'a_do_script_file' and field == 'file')
                                       and 'advancedFile' or 'Action'
                        local k2, merr = env.media_add(v.res, data, prefix)
                        if k2 then
                            res_key = k2
                            media_cache[v.res] = k2
                        else
                            errors[#errors + 1] = 'media add failed for ' .. v.res
                                .. ': ' .. tostring(merr)
                        end
                    else
                        errors[#errors + 1] = 'embedded media corrupt (bad base64): ' .. v.res
                    end
                else
                    errors[#errors + 1] = 'prefab has no embedded data for media: ' .. v.res
                end
            end
            if res_key == nil then
                return nil, nil  -- media-bearing entry without media: drop it
            end
            entry[field] = res_key
        else
            if kind == 'action' and ACTION_DICT_FIELDS[field]
                    and type(v) == 'string' and canonical ~= 'a_do_script'
                    and type(env.fix_dict) == 'function' then
                pcall(env.fix_dict, entry, field, v, ACTION_DICT_FIELDS[field])
            else
                entry[field] = v
            end
        end
    end

    return entry, nil
end

-- M.inject(plan, decisions, env) — see contract at top of file.
function M.inject(plan, decisions, env)
    decisions = decisions or {}
    local out = { entries = {}, count = 0, skipped = {}, errors = {} }
    if type(plan) ~= 'table' or type(env) ~= 'table'
            or type(env.schema) ~= 'table' or type(env.trigrules) ~= 'table' then
        out.errors[#out.errors + 1] = 'inject: bad plan/env'
        return out
    end
    local schema = env.schema
    local checked = decisions.checked or {}
    local media_cache = {}

    for t_idx, pt in ipairs(plan.triggers or {}) do
        repeat
            if checked[t_idx] == false then break end
            local trig = pt.portable

            -- Index this trigger's planned resolutions by ref key.
            local resolved_by_key = {}
            for _, r in ipairs(pt.refs or {}) do resolved_by_key[r.key] = r end

            local _, _, tdescr, terr = schema:resolve(trig.type or '', 'trigger')
            if terr then
                out.skipped[#out.skipped + 1] =
                    { name = trig.name, reason = 'unknown trigger type: ' .. tostring(trig.type) }
                break
            end
            local new_trigger
            if type(env.create_trigger) == 'function' then
                local ok, built = pcall(env.create_trigger, tdescr)
                if ok and type(built) == 'table' then new_trigger = built end
            end
            if new_trigger == nil then
                new_trigger = { predicate = tdescr, rules = {}, actions = {} }
            end
            new_trigger.comment = env.unique_name and env.unique_name(trig.name or 'Trigger')
                                  or (trig.name or 'Trigger')
            new_trigger.eventlist = trig.eventlist or ''
            new_trigger.rules = {}
            new_trigger.actions = {}

            local failed_reason = nil
            for e_idx, c in ipairs(trig.conditions or {}) do
                local entry, err = build_entry(c, 'condition', t_idx, 'conditions',
                    e_idx, resolved_by_key, decisions, env, media_cache, out.errors)
                if err then failed_reason = err; break end
                if entry then new_trigger.rules[#new_trigger.rules + 1] = entry end
            end
            if not failed_reason then
                for e_idx, a in ipairs(trig.actions or {}) do
                    local entry, err = build_entry(a, 'action', t_idx, 'actions',
                        e_idx, resolved_by_key, decisions, env, media_cache, out.errors)
                    if err then failed_reason = err; break end
                    if entry then new_trigger.actions[#new_trigger.actions + 1] = entry end
                end
            end

            if failed_reason then
                out.skipped[#out.skipped + 1] = { name = trig.name, reason = failed_reason }
                break
            end
            if #new_trigger.actions == 0 then
                -- ED's fixTriggers purges action-less triggers at panel open;
                -- importing one would silently vanish (spec §3 guard).
                out.skipped[#out.skipped + 1] =
                    { name = trig.name, reason = 'no actions remain after skips' }
                break
            end

            table.insert(env.trigrules, new_trigger)
            out.entries[#out.entries + 1] = new_trigger
            out.count = out.count + 1
        until true
    end

    return out
end

return M
