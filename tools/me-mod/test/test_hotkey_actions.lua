-- Standalone test for me_hotkey_actions.lua data shape. No dxgui needed:
-- invoke thunks require ME modules lazily, so the registry loads in plain Lua.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

local A = require('dcs_sms_me.me_hotkey_actions')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local list = A.list()
check('list is a non-empty table', type(list) == 'table' and #list > 0)

local valid_cat = {}
for _, c in ipairs(A.CATEGORIES) do valid_cat[c] = true end

local seen_id, seen_default = {}, {}
local all_fields_ok, unique_ids, unique_defaults, cats_ok, invokes_ok = true, true, true, true, true
for _, a in ipairs(list) do
    if type(a.id) ~= 'string' or a.id == '' then all_fields_ok = false end
    if type(a.label) ~= 'string' or a.label == '' then all_fields_ok = false end
    if type(a.default_key) ~= 'string' or a.default_key == '' then all_fields_ok = false end
    if type(a.invoke) ~= 'function' then invokes_ok = false end
    if not valid_cat[a.category] then cats_ok = false end
    if seen_id[a.id] then unique_ids = false end
    seen_id[a.id] = true
    local nk = A.normalize_key(a.default_key)
    if seen_default[nk] then unique_defaults = false end
    seen_default[nk] = true
end
check('every action has id/label/default_key strings', all_fields_ok)
check('every invoke is a function', invokes_ok)
check('every category is one of CATEGORIES', cats_ok)
check('action ids are unique', unique_ids)
check('default keys are unique (no two actions share a default)', unique_defaults)

check('get_action returns by id', A.get_action('map.multi_select') ~= nil)
check('get_action unknown returns nil', A.get_action('nope') == nil)

check('normalize_key lowercases', A.normalize_key('Ctrl+M') == 'ctrl+m')
check('ED_CONFLICTS has ctrl+m (start mission)', A.ED_CONFLICTS['ctrl+m'] ~= nil)
check('ED_CONFLICTS has ctrl+d (DTC)', A.ED_CONFLICTS['ctrl+d'] ~= nil)

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All me_hotkey_actions tests passed.')
