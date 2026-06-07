-- paths.lua — output directory constants and dir-creation helpers.
--
-- Nests under the same Saved Games\DCS\dcs-sms\ root the bridge uses, with
-- per-feature subdirs:
--   me/        — selection dumps (sub-project 2)
--   prefabs/   — distilled prefab files (sub-project 3)

local lfs = require('lfs')
local M = {}

M.ROOT           = lfs.writedir() .. 'dcs-sms\\'
M.OUTBOX_DIR     = M.ROOT .. 'me\\'
M.PREFABS_DIR    = M.ROOT .. 'prefabs\\'
M.WAREHOUSES_DIR       = M.ROOT .. 'airbase-warehouses\\'
M.LIB_DIR              = M.ROOT .. 'lib\\'                       -- bundled LuaSec payload (user-supplied)
M.COMMUNITY_CACHE_FILE = M.ROOT .. 'community-cache.json'        -- last-fetched manifest (offline)
M.LOG_TAG              = 'sms.me'

-- Translate an in-memory folder string ('', 'CAP', 'CAP/Tomcats') into
-- an absolute filesystem path ending in '\'. '/' is the canonical
-- in-memory separator; the filesystem uses '\'. This function is the
-- single seam between the two.
function M.folder_to_abs(folder_rel)
    if folder_rel == nil or folder_rel == '' then
        return M.PREFABS_DIR
    end
    local fs = folder_rel:gsub('/', '\\')
    if fs:sub(-1) ~= '\\' then fs = fs .. '\\' end
    return M.PREFABS_DIR .. fs
end

function M.ensure_outbox()
    lfs.mkdir(M.ROOT)
    lfs.mkdir(M.OUTBOX_DIR)
end

function M.ensure_prefabs()
    lfs.mkdir(M.ROOT)
    lfs.mkdir(M.PREFABS_DIR)
end

function M.ensure_warehouses()
    lfs.mkdir(M.ROOT)
    lfs.mkdir(M.WAREHOUSES_DIR)
end

-- mkdir every segment of an in-memory folder path top-down, starting from
-- PREFABS_DIR. Idempotent; lfs.mkdir on an existing dir is a no-op.
-- '' means "just ensure PREFABS_DIR itself".
function M.ensure_prefab_folder(folder_rel)
    M.ensure_prefabs()
    if folder_rel == nil or folder_rel == '' then return end
    local acc = M.PREFABS_DIR
    for segment in folder_rel:gmatch('[^/]+') do
        acc = acc .. segment .. '\\'
        lfs.mkdir(acc)
    end
end

return M
