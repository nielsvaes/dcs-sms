-- community_config.lua — single source of truth for community-library
-- endpoints + schema. Change the repo URL here and nowhere else.
local M = {}

-- raw.githubusercontent.com base for the community repo's default branch.
-- Trailing slash required; file_url concatenates directly.
-- Catalog source: https://github.com/nielsvaes/dcs-sms-prefabs
M.RAW_BASE = 'https://raw.githubusercontent.com/nielsvaes/dcs-sms-prefabs/main/'

-- Manifest path within the repo.
M.MANIFEST_PATH = 'index.json'

-- Manifest schema major version the client understands.
M.SCHEMA_VERSION = 1

-- Folder (inside the user's own prefab library) that imports land in.
M.COMMUNITY_FOLDER = 'Community'

-- Message shown when a user write is rejected for targeting the reserved
-- Community/ folder. Shared by the prefab_ops guards and the UI so every
-- blocked path says the same thing.
M.MANAGED_MSG = 'Community is managed automatically — it only holds downloads.'

-- True if `rel` is the Community folder or a path inside it. `rel` is a
-- library-relative folder path ('' = root); both '/' and '\' separators and
-- any case are accepted. 'CommunityCenter' does NOT match — the prefix guard
-- requires a separator after the folder name.
function M.is_community_path(rel)
    local s = tostring(rel or ''):gsub('\\', '/')
    s = s:gsub('^/+', ''):gsub('/+$', '')
    local lc = s:lower()
    local c  = M.COMMUNITY_FOLDER:lower()
    return lc == c or lc:sub(1, #c + 1) == c .. '/'
end

function M.manifest_url() return M.RAW_BASE .. M.MANIFEST_PATH end
function M.file_url(rel_path) return M.RAW_BASE .. tostring(rel_path or '') end

-- Sidecar metadata URL for a prefab: 'prefabs/x.prefab' -> the x.meta.json
-- next to it. The community catalog stores each prefab's screenshot list in
-- this sidecar; index.json (the manifest) does not carry it.
function M.meta_url(prefab_path)
    local p = tostring(prefab_path or ''):gsub('%.prefab$', '')
    return M.RAW_BASE .. p .. '.meta.json'
end

-- URL for a community screenshot given its repo-relative path
-- ('<thread_id>/<n>.png'); images live under the repo's images/ dir.
function M.image_url(rel)
    return M.RAW_BASE .. 'images/' .. tostring(rel or '')
end

return M
