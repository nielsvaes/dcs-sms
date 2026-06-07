-- community_import.lua — adopt a community prefab into the user's library.
-- Verifies SHA-256 + data-only shape BEFORE writing. Imports land in the
-- reserved Community/ folder so they never collide with hand-made prefabs.
local paths   = require('dcs_sms_me.paths')
local cfg     = require('dcs_sms_me.community_config')
local sha256  = require('dcs_sms_me.vendor.sha256')
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

    -- 1. Integrity: hash must match the manifest.
    local got = sha256.hex(body)
    if got ~= tostring(entry.sha256 or ''):lower() then
        return false, 'sha256 mismatch (expected ' .. tostring(entry.sha256) .. ', got ' .. got .. ')'
    end

    -- 2. Safety: must parse as pure data (never executed).
    local tbl, perr = safe.load_string(body)
    if not tbl then return false, 'rejected by safe-load: ' .. tostring(perr) end

    -- 3. Write verbatim into Community/.
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
