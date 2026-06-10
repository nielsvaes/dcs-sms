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
    local schema = env.schema

    for t_idx, trig in ipairs(portable) do
        local refs, unresolved = {}, 0
        local actions_with_unresolved = {}

        local function scan(list_name, entries)
            for e_idx, entry in ipairs(entries or {}) do
                local _, _, descr = schema:resolve(entry.predicate)
                for field, v in pairs(entry.fields or {}) do
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

    -- Flag overlap: values present in both arrays (spec decision 6: warn only).
    local target_set = {}
    for _, fv in ipairs(env.target_flags or {}) do target_set[fv] = true end
    local seen = {}
    for _, fv in ipairs(env.prefab_flags or {}) do
        if target_set[fv] and not seen[fv] then
            seen[fv] = true
            plan.flag_overlaps[#plan.flag_overlaps + 1] = fv
        end
    end
    table.sort(plan.flag_overlaps, function(a, b) return tostring(a) < tostring(b) end)

    return plan
end

return M
