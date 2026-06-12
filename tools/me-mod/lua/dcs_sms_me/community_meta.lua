-- community_meta.lua — parse a community prefab's <stem>.meta.json sidecar.
-- The catalog stores each prefab's screenshot list here (index.json does NOT
-- carry it), so the Community tab fetches this on selection to learn what
-- images to show. Defensive like community_manifest: never throws, ignores
-- unknown fields, returns clean data.
local M = {}

local function as_string(v) return (type(v) == 'string') and v or '' end

-- Parse a decoded meta object -> { images = { <rel-path-string>, ... } }.
-- `images` holds the repo-relative screenshot paths ('<thread>/<n>.png'); any
-- non-string / empty entries are dropped. Returns nil on a non-table input.
function M.parse(decoded)
    if type(decoded) ~= 'table' then return nil, 'meta is not an object' end
    local images = {}
    if type(decoded.images) == 'table' then
        for _, v in ipairs(decoded.images) do
            local s = as_string(v)
            if s ~= '' then images[#images + 1] = s end
        end
    end
    return { images = images }
end

return M
