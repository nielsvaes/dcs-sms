-- community_manifest.lua — validate + query the community index.
local cfg = require('dcs_sms_me.community_config')
local M = {}

local function as_number(v) return tonumber(v) or 0 end
local function as_string(v) return (type(v) == 'string') and v or '' end

local function normalize_entry(raw)
    local tags = {}
    if type(raw.tags) == 'table' then
        for _, t in ipairs(raw.tags) do
            if type(t) == 'string' and t ~= '' then tags[#tags + 1] = t:lower() end
        end
    end
    return {
        name        = as_string(raw.name),
        author      = as_string(raw.author),
        date        = as_string(raw.date),
        theatre     = as_string(raw.theatre),
        description = as_string(raw.description),
        tags        = tags,
        likes       = as_number(raw.likes),
        groups      = as_number(raw.groups),
        statics     = as_number(raw.statics),
        zones       = as_number(raw.zones),
        drawings    = as_number(raw.drawings),
        airbases    = as_number(raw.airbases),
        place_at_origin = raw.place_at_origin == true,
        path        = as_string(raw.path),
    }
end

function M.parse(decoded)
    if type(decoded) ~= 'table' then return nil, 'manifest is not an object' end
    if type(decoded.schema) ~= 'number' then return nil, 'manifest missing numeric schema' end
    if decoded.schema ~= cfg.SCHEMA_VERSION then
        return nil, 'unsupported manifest schema ' .. tostring(decoded.schema)
            .. ' (expected ' .. cfg.SCHEMA_VERSION .. ')'
    end
    if type(decoded.prefabs) ~= 'table' then return nil, 'manifest missing prefabs array' end
    local entries = {}
    for _, raw in ipairs(decoded.prefabs) do
        if type(raw) == 'table' then
            local e = normalize_entry(raw)
            -- Skip entries that can't be downloaded.
            if e.name ~= '' and e.path ~= '' then
                entries[#entries + 1] = e
            end
        end
    end
    return { schema = decoded.schema, generated = as_string(decoded.generated), entries = entries }
end

function M.all_tags(entries)
    local set = {}
    for _, e in ipairs(entries or {}) do
        for _, t in ipairs(e.tags or {}) do set[t] = true end
    end
    local out = {}
    for t in pairs(set) do out[#out + 1] = t end
    table.sort(out)
    return out
end

local function has_tag(entry, tag)
    for _, t in ipairs(entry.tags or {}) do if t == tag then return true end end
    return false
end

function M.filter(entries, opts)
    opts = opts or {}
    local text = (opts.text or ''):lower()
    local want_tags = opts.tags or {}
    local out = {}
    for _, e in ipairs(entries or {}) do
        local ok = true
        for _, wt in ipairs(want_tags) do
            if not has_tag(e, wt:lower()) then ok = false; break end
        end
        if ok and text ~= '' then
            local hay = (e.name .. ' ' .. e.author .. ' ' .. table.concat(e.tags, ' ')):lower()
            if not hay:find(text, 1, true) then ok = false end
        end
        if ok then out[#out + 1] = e end
    end
    return out
end

function M.sort(entries, key)
    table.sort(entries, function(a, b)
        if key == 'name' then return a.name:lower() < b.name:lower() end
        if key == 'newest' then
            if a.date == b.date then return a.name:lower() < b.name:lower() end
            return a.date > b.date
        end
        -- default: likes desc, name asc tiebreak
        if a.likes == b.likes then return a.name:lower() < b.name:lower() end
        return a.likes > b.likes
    end)
    return entries
end

return M
