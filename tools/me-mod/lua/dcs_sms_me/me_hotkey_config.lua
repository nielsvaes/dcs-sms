-- me_hotkey_config.lua — persistence of ME-Hotkey override deltas.
--
-- Stores ONLY the entries that differ from registry defaults (an action at
-- its default is absent), as a Lua file under Saved Games\DCS\dcs-sms\.
-- serialize/deserialize are pure (no IO) so they unit-test without disk; the
-- paths require is lazy (mirrors me_settings.lua) so this module loads in a
-- test VM without touching lfs.

local M = {}

-- Backend selection. The spike (research/me-hotkey-spike.md) may flip this to
-- 'global'; 'perkey' is correct when a re-registered key replaces ED's.
M.BACKEND_MODE = 'perkey'

-- ---- pure serialize / deserialize ----

function M.serialize(overrides)
    if type(overrides) ~= 'table' then overrides = {} end
    local keys = {}
    for k in pairs(overrides) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = { '-- DCS-SMS ME Hotkeys overrides (auto-generated; safe to delete).\nreturn {\n' }
    for _, k in ipairs(keys) do
        parts[#parts + 1] = string.format('    [%q] = %q,\n', k, tostring(overrides[k]))
    end
    parts[#parts + 1] = '}\n'
    return table.concat(parts)
end

function M.deserialize(s)
    if type(s) ~= 'string' then return {} end
    local f = (loadstring or load)(s)
    if not f then return {} end
    local ok, t = pcall(f)
    if not ok or type(t) ~= 'table' then return {} end
    local out = {}
    for k, v in pairs(t) do
        if type(k) == 'string' and type(v) == 'string' then out[k] = v end
    end
    return out
end

-- ---- IO (lazy paths/lfs) ----

M.PATH = nil
local function config_path()
    if not M.PATH then
        M.PATH = require('dcs_sms_me.paths').ROOT .. 'me_hotkeys.lua'
    end
    return M.PATH
end

function M.load()
    local f = loadfile(config_path())
    if not f then return {} end
    local ok, t = pcall(f)
    if not ok or type(t) ~= 'table' then return {} end
    local out = {}
    for k, v in pairs(t) do
        if type(k) == 'string' and type(v) == 'string' then out[k] = v end
    end
    return out
end

function M.save(overrides)
    local path = config_path()
    pcall(function() require('lfs').mkdir(require('dcs_sms_me.paths').ROOT) end)
    local fh, err = io.open(path, 'w')
    if not fh then
        if log and log.write then
            log.write('sms.me', log.ERROR, 'me_hotkey_config save failed: ' .. tostring(err))
        end
        return false
    end
    fh:write(M.serialize(overrides))
    fh:close()
    return true
end

return M
