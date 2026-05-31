-- Standalone test for export_import_warehouse_airbase._save / _load / _delete /
-- _apply_to_entities / _list_files. Uses a temp dir as the warehouse folder.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Build a unique temp dir per test run.
local lfs = require('lfs')
local tmp_root = os.getenv('TEMP') or os.getenv('TMP') or '.'
local tmp_dir  = tmp_root .. '\\sms-test-warehouses-' .. tostring(os.time()) .. '\\'
lfs.mkdir(tmp_dir)

package.preload['dcs_sms_me.paths'] = function()
    return {
        ROOT             = tmp_root .. '\\',
        WAREHOUSES_DIR   = tmp_dir,
        ensure_warehouses= function()
            lfs.mkdir(tmp_dir)
        end,
    }
end

-- In-memory warehouse store.
local warehouse_state = {
    [12] = {
        coalition = 'red',
        unlimitedAircrafts = false,
        aircrafts = { ['F-16C_50'] = { count = 20 } },
        weapons   = { ['AIM-120C']  = { count = 300 } },
        gasoline  = 5000,
    },
    [27] = {
        coalition = 'blue',
        unlimitedAircrafts = true,
    },
}
package.preload['dcs_sms_me.warehouse_ops'] = function()
    local function clone(t)
        if type(t) ~= 'table' then return t end
        local out = {}
        for k, v in pairs(t) do out[k] = clone(v) end
        return out
    end
    return {
        extract = function(id) return clone(warehouse_state[id]) end,
        apply   = function(id, e) warehouse_state[id] = clone(e); return true end,
    }
end

local undo_records = {}
package.preload['dcs_sms_me.undo'] = function()
    local handlers = {}
    return {
        register_handler = function(name, fn) handlers[name] = fn end,
        record_generic   = function(name, payload) undo_records[#undo_records + 1] = { name = name, payload = payload } end,
        _trigger         = function(name, payload) return handlers[name] and handlers[name](payload) end,
    }
end

local form = require('dcs_sms_me.mass_edit_forms.export_import_warehouse_airbase')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- _save: write the warehouse for airbase id 12 under the name 'Cold War'.
local res = form._save('Cold War', { id = 12, name = 'Anapa' })
check('save returns ok', res and res.ok == true, 'err=' .. tostring(res and res.err))
check('file exists',     lfs.attributes(tmp_dir .. 'Cold War.lua', 'mode') == 'file')

-- _list_files: should return 'Cold War'.
local list = form._list_files()
local found = false
for _, name in ipairs(list) do if name == 'Cold War' then found = true; break end end
check('list_files reports Cold War', found, 'got: ' .. table.concat(list, ','))

-- _load: read the saved table.
local loaded = form._load('Cold War')
check('load returns table',  type(loaded) == 'table')
check('loaded coalition is red',  loaded and loaded.coalition == 'red')
check('loaded F-16C_50 count 20', loaded and loaded.aircrafts and loaded.aircrafts['F-16C_50'] and
                                  loaded.aircrafts['F-16C_50'].count == 20)

-- _apply_to_entities: apply the loaded warehouse to airbase id 27.
local apply_res = form._apply_to_entities({ { id = 27, name = 'Krasnodar' } }, 'Cold War')
check('apply_to_entities ok',  apply_res and apply_res.ok == true)
check('Krasnodar coalition flipped to red', warehouse_state[27].coalition == 'red')
check('Krasnodar gasoline now 5000',         warehouse_state[27].gasoline == 5000)
check('one undo record recorded',           #undo_records == 1)

-- _delete: remove the file.
form._delete('Cold War')
check('file removed', lfs.attributes(tmp_dir .. 'Cold War.lua', 'mode') == nil)

-- _save sanitises the filename.
local sani = form._save('weird/name?with*chars', { id = 12, name = 'Anapa' })
check('save with weird chars still ok', sani and sani.ok == true)
local list2 = form._list_files()
local sani_found = false
for _, name in ipairs(list2) do
    if name:find('weird', 1, true) and not name:find('/') and not name:find('?') and not name:find('*') then
        sani_found = true
    end
end
check('sanitised filename is on disk and lists without disallowed chars', sani_found,
      'got: ' .. table.concat(list2, ','))

-- Cleanup.
for _, name in ipairs(form._list_files()) do
    os.remove(tmp_dir .. name .. '.lua')
end
lfs.rmdir(tmp_dir)

if failures > 0 then
    print('FAILED: ' .. failures .. ' failures')
    os.exit(1)
end
print('All export_import_warehouse_airbase tests passed.')
