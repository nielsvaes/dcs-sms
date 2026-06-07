-- community_cache.lua — persist the last successfully-fetched manifest JSON
-- so the Community tab has something to show with no network.
local paths = require('dcs_sms_me.paths')
local M = {}

function M.save(raw_json)
    if type(raw_json) ~= 'string' then return false, 'expected string' end
    local f, oerr = io.open(paths.COMMUNITY_CACHE_FILE, 'wb')
    if not f then return false, 'open failed: ' .. tostring(oerr) end
    f:write(raw_json); f:close()
    return true
end

function M.load()
    local f = io.open(paths.COMMUNITY_CACHE_FILE, 'rb')
    if not f then return nil end
    local s = f:read('*a'); f:close()
    if not s or s == '' then return nil end
    return s
end

return M
