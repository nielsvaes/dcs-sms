-- trigger_media.lua — read/add embedded mission resources (pictures,
-- sounds, script files) referenced by triggers via ResKey_*.
--
-- Discovery notes (verified against DCS install 2026-06-10):
--   * require('dictionary').getValueResource(key) → shortName, relPath;
--     bytes live at <tempMissionPath><relPath> while a mission is open
--     (tempMissionPath is a GLOBAL in the ME GUI state).
--   * dictionary.getNewResourceId(prefix) allocates 'ResKey_<prefix>_N';
--     prefix 'Action' for out-picture/out-sound, 'advancedFile' for
--     a_do_script_file.
--   * dictionary.setValueToResource(key, shortName, absSrcPath, 'DEFAULT')
--     copies the file into the open mission and registers it. It dedupes
--     by SHORT FILENAME: if the basename already exists in the dict the
--     existing file wins and the key simply maps to it (we accept that —
--     log at INFO, no byte-compare in v1).
--   * Saving the mission persists mapResource + files into the .miz.
--
-- env is injectable for tests; production defaults resolve lazily so
-- this module loads in the test VM (no lfs/dictionary at require time).
-- All functions return value | nil, err. Never throw.

local M = {}

local function default_env()
    local env = {}
    local ok, dict = pcall(require, 'dictionary')
    env.dictionary = ok and dict or nil
    env.temp_mission_path = rawget(_G, 'tempMissionPath')
    env.read_file = function(path)
        local f = io.open(path, 'rb')
        if not f then return nil end
        local data = f:read('*a')
        f:close()
        return data
    end
    -- Temp staging dir for add(): setValueToResource copies FROM a path,
    -- so bytes must hit disk first.
    local ok_p, paths = pcall(require, 'dcs_sms_me.paths')
    env.tmp_dir = ok_p and (paths.ROOT .. 'tmp\\') or nil
    env.write_file = function(path, data)
        local ok_l, lfs = pcall(require, 'lfs')
        if ok_l and env.tmp_dir then pcall(lfs.mkdir, env.tmp_dir) end
        local f, oerr = io.open(path, 'wb')
        if not f then return nil, tostring(oerr) end
        f:write(data)
        f:close()
        return true
    end
    env.remove_file = function(path) pcall(os.remove, path) end
    return env
end

-- read(res_key[, env]) → short_name, bytes | nil, err
function M.read(res_key, env)
    if type(res_key) ~= 'string' or res_key == '' then
        return nil, 'res_key required'
    end
    env = env or default_env()
    if not (env.dictionary and type(env.dictionary.getValueResource) == 'function') then
        return nil, 'dictionary module unavailable'
    end
    local ok, short, rel = pcall(env.dictionary.getValueResource, res_key)
    if not ok or type(short) ~= 'string' or type(rel) ~= 'string' then
        return nil, 'unresolvable resource key: ' .. res_key
    end
    if type(env.temp_mission_path) ~= 'string' then
        return nil, 'tempMissionPath unavailable (no mission open?)'
    end
    local bytes = env.read_file(env.temp_mission_path .. rel)
    if type(bytes) ~= 'string' then
        return nil, 'resource file unreadable: ' .. rel
    end
    return short, bytes
end

-- add(short_name, bytes[, opts]) → res_key | nil, err
-- opts = { prefix = 'Action' (default) | 'advancedFile', env = <inject> }
function M.add(short_name, bytes, opts)
    if type(short_name) ~= 'string' or short_name == '' then
        return nil, 'short_name required'
    end
    if type(bytes) ~= 'string' then
        return nil, 'bytes required'
    end
    opts = opts or {}
    local env = opts.env or default_env()
    local dict = env.dictionary
    if not (dict and type(dict.getNewResourceId) == 'function'
            and type(dict.setValueToResource) == 'function') then
        return nil, 'dictionary module unavailable'
    end
    if type(env.tmp_dir) ~= 'string' then
        return nil, 'no staging dir available'
    end

    local staging = env.tmp_dir .. short_name
    local wok, werr = env.write_file(staging, bytes)
    if not wok then
        return nil, 'staging write failed: ' .. tostring(werr)
    end

    local key
    local ok, err = pcall(function()
        key = dict.getNewResourceId(opts.prefix or 'Action')
        key = dict.setValueToResource(key, short_name, staging, 'DEFAULT')
    end)
    env.remove_file(staging)
    if not ok or type(key) ~= 'string' then
        return nil, 'setValueToResource failed: ' .. tostring(err)
    end
    return key
end

return M
