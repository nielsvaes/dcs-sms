-- test_community_import.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local made_dirs = {}
package.preload['lfs'] = function()
    return {
        writedir = function() return (os.getenv('TEMP') or '.') .. '\\' end,
        mkdir = function(p) made_dirs[p] = true; os.execute('mkdir "' .. tostring(p):gsub('/','\\'):gsub('\\$','') .. '" 2>nul'); return true end,
        attributes = function(p) local f=io.open(p,'rb'); if f then f:close(); return {mode='file'} end; return nil end,
    }
end
local paths = require('dcs_sms_me.paths')
-- Point PREFABS_DIR at a temp dir we can write.
local base = (os.getenv('TEMP') or '.') .. '\\sms_import_test_' .. tostring(os.time()) .. '\\'
os.execute('mkdir "' .. base:gsub('/','\\'):gsub('\\$','') .. '" 2>nul')
paths.PREFABS_DIR = base
local sha256 = require('dcs_sms_me.vendor.sha256')
local imp = require('dcs_sms_me.community_import')

local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

local body = 'return {\n  ["meta"] = { ["name"] = "x" },\n  ["groups"] = {},\n}\n'
local good = sha256.hex(body)
local entry = { name = 'SA-10 ring', sha256 = good, path = 'prefabs/x.prefab' }

check('not imported yet', imp.is_imported(entry) == false)
local ok, path = imp.import(entry, body)
check('import ok', ok == true, path)
check('path in Community folder', path and path:find('Community', 1, true) ~= nil, path)
check('file written', (function() local f=io.open(path,'rb'); if f then local s=f:read('*a'); f:close(); return s==body end end)())
check('now imported', imp.is_imported(entry) == true)

-- Tamper: wrong hash rejected.
local bad_entry = { name='evil', sha256='deadbeef', path='p' }
local ok2, err2 = imp.import(bad_entry, body)
check('hash mismatch rejected', ok2 == false and type(err2)=='string', err2)

-- Non-data body rejected even if hash matches.
local evil = 'os.execute("calc") return {}'
local evil_entry = { name='evil2', sha256=sha256.hex(evil), path='p' }
local ok3, err3 = imp.import(evil_entry, evil)
check('non-data rejected', ok3 == false and type(err3)=='string', err3)

-- Name sanitization: a slashy name stays inside Community/.
local slashy = { name='a/../b', sha256=good, path='p' }
local ok4, p4 = imp.import(slashy, body)
check('sanitized stays under Community', ok4 == true and p4:find('Community', 1, true) and not p4:find('%.%.'), p4)

if failures > 0 then os.exit(1) end
print('All community_import tests passed.')
