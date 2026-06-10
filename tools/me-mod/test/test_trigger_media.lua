-- test_trigger_media.lua — ResKey read/add over an injected fake
-- dictionary + filesystem (no lfs / no DCS).
local here = arg and arg[0] and arg[0]:match('^(.*[\\/])') or './'
package.path = here .. '?.lua;' .. here .. '../lua/?.lua;' .. package.path

local media = require('dcs_sms_me.trigger_media')

local passed, failed, errors = 0, 0, {}
local function check(cond, name)
    if cond then passed = passed + 1
    else failed = failed + 1; errors[#errors + 1] = name end
end

-- ---- read ----
local fake_dict = {
    getValueResource = function(key)
        if key == 'ResKey_Action_36' then
            return 'brief.png', 'l10n/DEFAULT/brief.png'
        end
        return nil
    end,
}
local files = { ['C:/tmp/Mission/l10n/DEFAULT/brief.png'] = 'PNGBYTES' }
local env = {
    dictionary = fake_dict,
    temp_mission_path = 'C:/tmp/Mission/',
    read_file = function(path) return files[path] end,
}

local short, bytes = media.read('ResKey_Action_36', env)
check(short == 'brief.png' and bytes == 'PNGBYTES', 'read resolves key to bytes')

local s2, err2 = media.read('ResKey_Action_99', env)
check(s2 == nil and err2 ~= nil, 'read unknown key → nil, err')

local s3, err3 = media.read(nil, env)
check(s3 == nil and err3 ~= nil, 'read nil key → nil, err')

-- ---- add ----
local added, removed = {}, {}
local add_env = {
    dictionary = {
        getNewResourceId = function(prefix) return 'ResKey_' .. prefix .. '_77' end,
        setValueToResource = function(key, short_name, src_path, dict)
            added[#added + 1] = { key = key, short = short_name, src = src_path, dict = dict }
            return key
        end,
    },
    tmp_dir = 'C:/tmp/sms/',
    write_file = function(path, data) files[path] = data; return true end,
    remove_file = function(path) removed[#removed + 1] = path; files[path] = nil end,
}

local key, aerr = media.add('alert.ogg', 'OGGBYTES', { prefix = 'Action', env = add_env })
check(key == 'ResKey_Action_77' and aerr == nil, 'add returns fresh key')
check(#added == 1 and added[1].short == 'alert.ogg'
      and added[1].dict == 'DEFAULT'
      and added[1].src == 'C:/tmp/sms/alert.ogg', 'add registers via setValueToResource')
check(#removed == 1 and removed[1] == 'C:/tmp/sms/alert.ogg', 'add cleans up temp file')

local k2, e2 = media.add('', 'X', { env = add_env })
check(k2 == nil and e2 ~= nil, 'add empty name → nil, err')
local k3, e3 = media.add('a.png', nil, { env = add_env })
check(k3 == nil and e3 ~= nil, 'add nil bytes → nil, err')

-- write failure propagates as nil, err (no throw)
local k4, e4 = media.add('b.png', 'X', { env = {
    dictionary = add_env.dictionary, tmp_dir = 'C:/tmp/sms/',
    write_file = function() return nil, 'disk full' end,
    remove_file = function() end,
} })
check(k4 == nil and e4 ~= nil, 'add write failure → nil, err')

print(string.format('test_trigger_media: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL ' .. e) end
os.exit(failed == 0 and 0 or 1)
