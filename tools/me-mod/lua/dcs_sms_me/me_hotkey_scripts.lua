-- me_hotkey_scripts.lua — persistence + CRUD for user-defined hotkey scripts.
--
-- A script is { id, name, key, code }. Stored as a Lua list under
-- Saved Games\DCS\dcs-sms\me_scripts.lua, separate from the built-in key-override
-- file (me_hotkeys.lua). serialize/deserialize/CRUD/compile are pure (no IO) so
-- they unit-test without disk; the paths/lfs requires are lazy (mirrors
-- me_hotkey_config.lua) so this module loads in a test VM.

local M = {}

-- ---- pure serialize / deserialize ----

function M.serialize(scripts)
    if type(scripts) ~= 'table' then scripts = {} end
    local parts = { '-- DCS-SMS ME Hotkey user scripts (auto-generated; safe to delete).\nreturn {\n' }
    for _, s in ipairs(scripts) do
        if type(s) == 'table' and type(s.id) == 'string' and s.id ~= '' then
            parts[#parts + 1] = string.format(
                '    { id = %q, name = %q, key = %q, code = %q },\n',
                s.id, tostring(s.name or ''), tostring(s.key or ''), tostring(s.code or ''))
        end
    end
    parts[#parts + 1] = '}\n'
    return table.concat(parts)
end

-- Validate + clean one decoded table into a script, or nil if malformed.
local function clean_one(s)
    if type(s) ~= 'table' or type(s.id) ~= 'string' or s.id == '' then return nil end
    return {
        id   = s.id,
        name = type(s.name) == 'string' and s.name or '',
        key  = type(s.key)  == 'string' and s.key  or '',
        code = type(s.code) == 'string' and s.code or '',
    }
end

local function clean_list(t)
    local out = {}
    if type(t) == 'table' then
        for _, s in ipairs(t) do
            local c = clean_one(s)
            if c then out[#out + 1] = c end
        end
    end
    return out
end

function M.deserialize(str)
    if type(str) ~= 'string' then return {} end
    local f = (loadstring or load)(str)
    if not f then return {} end
    local ok, t = pcall(f)
    if not ok then return {} end
    return clean_list(t)
end

-- ---- ids ----

function M.next_id(scripts)
    local max = 0
    for _, s in ipairs(scripts or {}) do
        local n = tostring(s.id or ''):match('^script%.(%d+)$')
        if n then n = tonumber(n); if n and n > max then max = n end end
    end
    return 'script.' .. (max + 1)
end

-- ---- pure CRUD (returns a fresh list; never mutates input) ----

local function copy_list(scripts)
    local out = {}
    for _, s in ipairs(scripts or {}) do
        out[#out + 1] = { id = s.id, name = s.name, key = s.key, code = s.code }
    end
    return out
end

function M.add(scripts, fields)
    local list = copy_list(scripts)
    local id = M.next_id(list)
    list[#list + 1] = {
        id = id,
        name = tostring((fields and fields.name) or ''),
        key  = tostring((fields and fields.key)  or ''),
        code = tostring((fields and fields.code) or ''),
    }
    return list, id
end

function M.update(scripts, id, fields)
    local list = copy_list(scripts)
    fields = fields or {}
    for _, s in ipairs(list) do
        if s.id == id then
            if fields.name ~= nil then s.name = tostring(fields.name) end
            if fields.key  ~= nil then s.key  = tostring(fields.key)  end
            if fields.code ~= nil then s.code = tostring(fields.code) end
            break
        end
    end
    return list
end

function M.remove(scripts, id)
    local list = {}
    for _, s in ipairs(scripts or {}) do
        if s.id ~= id then list[#list + 1] = { id = s.id, name = s.name, key = s.key, code = s.code } end
    end
    return list
end

function M.get(scripts, id)
    for _, s in ipairs(scripts or {}) do if s.id == id then return s end end
    return nil
end

-- ---- compile ----

-- Returns true on success, or (false, errmsg) on a syntax error.
function M.compile(code)
    local f, err = (loadstring or load)(tostring(code or ''))
    if f then return true end
    return false, tostring(err)
end

-- ---- script -> engine action ----

-- Invoke thunk: compile + pcall the code at fire time, logging any error so a
-- broken script never aborts the ME.
local function make_invoke(name, code)
    return function()
        local f, err = (loadstring or load)(tostring(code or ''))
        if not f then
            if log and log.write then
                log.write('sms.me.script', log.ERROR, 'script "' .. tostring(name) .. '" compile error: ' .. tostring(err))
            end
            return
        end
        local ok, rerr = pcall(f)
        if not ok and log and log.write then
            log.write('sms.me.script', log.ERROR, 'script "' .. tostring(name) .. '" runtime error: ' .. tostring(rerr))
        end
    end
end

function M.to_actions(scripts)
    local actions = {}
    for _, s in ipairs(scripts or {}) do
        actions[#actions + 1] = {
            id = s.id,
            label = (s.name ~= nil and s.name ~= '') and s.name or s.id,
            category = 'Scripts',
            default_key = s.key or '',
            ed_key = nil,
            script = true,
            invoke = make_invoke(s.name, s.code),
        }
    end
    return actions
end

-- ---- IO (lazy paths/lfs) ----

M.PATH = nil
local function config_path()
    if not M.PATH then
        M.PATH = require('dcs_sms_me.paths').ROOT .. 'me_scripts.lua'
    end
    return M.PATH
end

function M.load()
    local f = loadfile(config_path())
    if not f then return {} end
    local ok, t = pcall(f)
    if not ok then return {} end
    return clean_list(t)
end

function M.save(scripts)
    local path = config_path()
    pcall(function() require('lfs').mkdir(require('dcs_sms_me.paths').ROOT) end)
    local fh, err = io.open(path, 'w')
    if not fh then
        if log and log.write then
            log.write('sms.me', log.ERROR, 'me_hotkey_scripts save failed: ' .. tostring(err))
        end
        return false
    end
    fh:write(M.serialize(scripts))
    fh:close()
    return true
end

return M
