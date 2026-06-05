-- Standalone test for me_hotkey_scripts.lua. Pure serialize/CRUD/compile/to_actions;
-- the paths/lfs requires are lazy so the module loads without disk.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
_G.log = _G.log or { write = function() end, INFO = 1, WARNING = 2, ERROR = 3 }
local S = require('dcs_sms_me.me_hotkey_scripts')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function same_script(a, b)
    return a.id == b.id and a.name == b.name and a.key == b.key and a.code == b.code
end

-- round-trip including quotes + newlines in code
local list = {
    { id = 'script.1', name = 'Hi "there"', key = 'Ctrl+Shift+1', code = 'local x = "a"\nreturn x' },
    { id = 'script.2', name = 'No key',      key = '',             code = 'return 1' },
}
local round = S.deserialize(S.serialize(list))
check('round-trip count', #round == 2)
check('round-trip script 1 identity', round[1] and same_script(round[1], list[1]))
check('round-trip preserves empty key', round[2] and round[2].key == '')

-- malformed input
check('deserialize non-string -> {}', #S.deserialize(nil) == 0)
check('deserialize garbage -> {}', #S.deserialize('this is not lua {{{') == 0)
check('deserialize non-table -> {}', #S.deserialize('return 42') == 0)
check('deserialize drops entries without id', #S.deserialize('return { { name = "x" } }') == 0)

-- next_id
check('next_id of empty is script.1', S.next_id({}) == 'script.1')
check('next_id of {1,2} is script.3', S.next_id(list) == 'script.3')
check('next_id ignores non-numeric ids', S.next_id({ { id = 'script.foo' } }) == 'script.1')

-- add assigns fresh id, does not mutate input
local base = {}
local added, new_id = S.add(base, { name = 'A', key = 'm', code = 'return 0' })
check('add returns new id', new_id == 'script.1')
check('add appended one', #added == 1 and added[1].name == 'A')
check('add did not mutate input', #base == 0)

-- update by id
local updated = S.update(added, 'script.1', { name = 'A2', key = 'n' })
check('update mutates name', S.get(updated, 'script.1').name == 'A2')
check('update mutates key', S.get(updated, 'script.1').key == 'n')
check('update keeps code when not given', S.get(updated, 'script.1').code == 'return 0')

-- remove by id
local removed = S.remove(updated, 'script.1')
check('remove drops the script', #removed == 0)
check('remove left input intact', #updated == 1)

-- compile
check('compile valid lua', S.compile('return 1 + 1') == true)
local ok_c, err_c = S.compile('this is not lua ===')
check('compile bad lua returns false', ok_c == false)
check('compile bad lua returns error string', type(err_c) == 'string')

-- to_actions
local acts = S.to_actions(list)
check('to_actions one per script', #acts == 2)
check('to_actions category is Scripts', acts[1].category == 'Scripts')
check('to_actions sets script flag', acts[1].script == true)
check('to_actions default_key is the key', acts[1].default_key == 'Ctrl+Shift+1')
check('to_actions invoke is a function', type(acts[1].invoke) == 'function')
check('to_actions label falls back to id when name empty',
      S.to_actions({ { id = 'script.9', name = '', key = '', code = '' } })[1].label == 'script.9')

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All me_hotkey_scripts tests passed.')
