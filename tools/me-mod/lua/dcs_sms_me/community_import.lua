-- community_import.lua — adopt a community prefab into the user's library.
-- Validates the data-only shape (safe-load) BEFORE writing. Imports land in
-- the reserved Community/ folder so they never collide with hand-made prefabs.
-- No SHA-256 integrity check: authenticity/integrity is already provided by the
-- cert-verified HTTPS fetch from the catalog repo (see community_transport), and
-- pure-Lua hashing of a large body would stall the single-threaded editor.
local paths   = require('dcs_sms_me.paths')
local cfg     = require('dcs_sms_me.community_config')
local safe    = require('dcs_sms_me.prefab_safe_load')
local lfs     = require('lfs')

local M = {}

-- Reduce a manifest name to a safe single-segment filename. Strips path
-- separators and Windows-reserved characters; collapses whitespace.
local function safe_basename(name)
    local s = tostring(name or 'prefab')
    s = s:gsub('[<>:"/\\|%?%*]', '_')   -- reserved chars
    s = s:gsub('%.%.', '_')             -- no parent refs
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then s = 'prefab' end
    return s
end

function M.target_path(entry)
    return paths.PREFABS_DIR .. cfg.COMMUNITY_FOLDER .. '\\' .. safe_basename(entry.name) .. '.prefab'
end

function M.is_imported(entry)
    local p = M.target_path(entry)
    return lfs.attributes(p) ~= nil
end

function M.import(entry, body)
    if type(entry) ~= 'table' then return false, 'entry required' end
    if type(body) ~= 'string' or body == '' then return false, 'empty body' end

    -- Safety: must parse as pure data (never executed). This is the security
    -- boundary for untrusted community prefabs — it rejects anything with code.
    local tbl, perr = safe.load_string(body)
    if not tbl then return false, 'rejected by safe-load: ' .. tostring(perr) end

    -- Write verbatim into Community/.
    -- lfs.mkdir creates the parent and the Community/ folder if missing.
    local community_dir = paths.PREFABS_DIR .. cfg.COMMUNITY_FOLDER
    lfs.mkdir(paths.PREFABS_DIR)
    lfs.mkdir(community_dir .. '\\')
    local path = M.target_path(entry)
    local f, oerr = io.open(path, 'wb')
    if not f then return false, 'write failed: ' .. tostring(oerr) end
    f:write(body); f:close()
    return true, path
end

return M
