-- Verifies scan_dir surfaces meta.community as row.community + row.author for
-- downloaded community prefabs, and leaves them unset for the user's own.

local tmp_dir = os.getenv('TEMP') or os.getenv('TMP') or '.'
local run_dir = tmp_dir .. '\\dcs_sms_test_community_' .. tostring(os.time()) .. '\\'
os.execute('mkdir "' .. run_dir:sub(1, -2) .. '" 2>nul')

local function write_file(path, body)
    local f = assert(io.open(path, 'w'))
    f:write(body)
    f:close()
end

-- A community import: meta carries a community sub-table.
write_file(run_dir .. 'shared.prefab',
    'return {\n'
    .. '  ["meta"] = {\n'
    .. '    ["name"] = "shared",\n'
    .. '    ["community"] = { ["author"] = "coconut", ["source"] = "https://d/x" },\n'
    .. '  },\n'
    .. '  ["groups"] = {}, ["statics"] = {}, ["zones"] = {}, ["drawings"] = {},\n'
    .. '}\n')

-- A hand-made prefab: no community marker.
write_file(run_dir .. 'mine.prefab',
    'return {\n'
    .. '  ["meta"] = { ["name"] = "mine" },\n'
    .. '  ["groups"] = {}, ["statics"] = {}, ["zones"] = {}, ["drawings"] = {},\n'
    .. '}\n')

local function list_dir(path)
    local p = io.popen('dir /b "' .. path:gsub('/', '\\'):gsub('\\$', '') .. '" 2>nul')
    local entries = {}
    if p then
        for line in p:lines() do entries[#entries + 1] = line end
        p:close()
    end
    return entries
end
local function is_dir(path)
    local p = io.popen('if exist "' .. path:gsub('/', '\\') .. '\\*" (echo Y) else (echo N)')
    if not p then return false end
    local r = p:read('*l'); p:close()
    return r and r:match('Y') ~= nil
end

package.preload['lfs'] = function()
    return {
        writedir = function() return '' end,
        mkdir = function() return true end,
        dir = function(p)
            local entries = list_dir(p)
            local i = 0
            return function() i = i + 1; return entries[i] end
        end,
        attributes = function(p)
            if is_dir(p:gsub('\\$', '')) then return { mode = 'directory' } end
            return { mode = 'file' }
        end,
    }
end

package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end

log = log or {}
log.INFO = log.INFO or 0; log.WARNING = log.WARNING or 0; log.ERROR = log.ERROR or 0
log.write = log.write or function() end

package.path = package.path .. ';../lua/?.lua;../lua/?/init.lua'

local paths = require('dcs_sms_me.paths')
paths.PREFABS_DIR = run_dir
local prefab_ops = require('dcs_sms_me.prefab_ops')

local function pass(l) io.write('PASS ', l, '\n') end
local function eq(l, got, expected)
    if got == expected then pass(l) else
        io.write('FAIL ', l, ' got=', tostring(got), ' expected=', tostring(expected), '\n')
        os.exit(1)
    end
end

local rows = prefab_ops.scan_dir()
local by_name = {}
for _, r in ipairs(rows) do by_name[r.name] = r end

eq('community flag on import',   by_name['shared'] and by_name['shared'].community, true)
eq('author on import',          by_name['shared'] and by_name['shared'].author,    'coconut')
eq('no community flag on own',  by_name['mine']   and by_name['mine'].community,   false)
eq('no author on own',          by_name['mine']   and by_name['mine'].author,      nil)

os.remove(run_dir .. 'shared.prefab')
os.remove(run_dir .. 'mine.prefab')
os.execute('rmdir "' .. run_dir:sub(1, -2) .. '" 2>nul')

io.write('All prefab_ops community/author tests passed.\n')
