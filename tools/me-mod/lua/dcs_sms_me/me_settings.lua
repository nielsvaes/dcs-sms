-- me_settings.lua — small key-value settings persisted under
-- Saved Games\DCS\dcs-sms\me_settings.lua. Read at menu install time
-- so user toggles can persist across DCS restarts (currently the
-- "External execution" toggle uses this for an opt-in remember).
--
-- Schema: the file just returns a Lua table. Adding new keys is
-- backward-compat — load() falls back to DEFAULTS for missing fields.
--
-- Public:
--   M.load()         -> table  (settings; never nil, defaults applied)
--   M.save(settings) -> bool   (true on success; logs + returns false on error)

local M = {}

-- Defaults — keys present here are returned for missing fields too.
local DEFAULTS = {
    gui_bridge = false,  -- External execution toggle remembered across launches
}

local function paths_root()
    -- Require lazily so the module loads cleanly in test VMs without
    -- lfs (the prefab_naming + paths chain is otherwise untouched).
    return require('dcs_sms_me.paths').ROOT
end

M.PATH = nil  -- set lazily on first load/save; depends on lfs.writedir

local function settings_path()
    if not M.PATH then M.PATH = paths_root() .. 'me_settings.lua' end
    return M.PATH
end

local function defaulted(t)
    for k, v in pairs(DEFAULTS) do
        if t[k] == nil then t[k] = v end
    end
    return t
end

function M.load()
    local path = settings_path()
    local f = loadfile(path)
    if not f then return defaulted({}) end
    local ok, settings = pcall(f)
    if not ok or type(settings) ~= 'table' then
        if log and log.write then
            log.write('sms.me', log.WARNING, 'me_settings: ' .. tostring(path)
                .. ' load failed, using defaults')
        end
        return defaulted({})
    end
    return defaulted(settings)
end

local function serialize_bool(v)
    return v == true and 'true' or 'false'
end

function M.save(settings)
    if type(settings) ~= 'table' then return false end
    local path = settings_path()
    -- Ensure the dcs-sms root directory exists. lfs.mkdir on an existing
    -- dir is a no-op so this is safe to call every save.
    pcall(function() require('lfs').mkdir(paths_root()) end)
    local fh, err = io.open(path, 'w')
    if not fh then
        if log and log.write then
            log.write('sms.me', log.ERROR, 'me_settings save failed: ' .. tostring(err))
        end
        return false
    end
    -- The schema is a flat list of keys today; expand the serializer
    -- (or pull in dcs_sms_me.serializer) if nested tables ever appear.
    fh:write('-- DCS-SMS ME settings (auto-generated; safe to delete).\n')
    fh:write('return {\n')
    fh:write(string.format('    gui_bridge = %s,\n', serialize_bool(settings.gui_bridge)))
    fh:write('}\n')
    fh:close()
    return true
end

return M
