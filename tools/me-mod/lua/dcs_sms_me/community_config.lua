-- community_config.lua — single source of truth for community-library
-- endpoints + schema. Change the repo URL here and nowhere else.
local M = {}

-- raw.githubusercontent.com base for the community repo's default branch.
-- Trailing slash required; file_url concatenates directly.
-- NOTE: placeholder repo coordinates — update to the real repo when it exists.
M.RAW_BASE = 'https://raw.githubusercontent.com/nielsvaes/dcs-sms-prefabs/main/'

-- Manifest path within the repo.
M.MANIFEST_PATH = 'index.json'

-- Manifest schema major version the client understands.
M.SCHEMA_VERSION = 1

-- Folder (inside the user's own prefab library) that imports land in.
M.COMMUNITY_FOLDER = 'Community'

function M.manifest_url() return M.RAW_BASE .. M.MANIFEST_PATH end
function M.file_url(rel_path) return M.RAW_BASE .. tostring(rel_path or '') end

return M
