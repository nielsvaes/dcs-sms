-- Standalone test for mass_edit_transforms.lua. Pure functions, no preloads.

package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local T = require('dcs_sms_me.mass_edit_transforms')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- set_all: returns args.value regardless of old.
check('set_all returns value',         T.set_all('foo',  { value = 'bar' }, 1) == 'bar')
check('set_all with number value',     T.set_all(0,      { value = 5    }, 1) == 5)
check('set_all with nil old',          T.set_all(nil,    { value = 'x'  }, 1) == 'x')

-- add_prefix: prepends text.
check('add_prefix basic',              T.add_prefix('Bar', { text = 'Foo-' }, 1) == 'Foo-Bar')
check('add_prefix nil old',            T.add_prefix(nil,   { text = 'Foo-' }, 1) == 'Foo-')

-- add_suffix: appends text.
check('add_suffix basic',              T.add_suffix('Foo', { text = '-Bar' }, 1) == 'Foo-Bar')
check('add_suffix nil old',            T.add_suffix(nil,   { text = '-x'   }, 1) == '-x')

-- escape_pattern: escapes Lua metacharacters so find_replace stays plain-text.
check('escape_pattern dot',            T.escape_pattern('a.b')   == 'a%.b')
check('escape_pattern dash',           T.escape_pattern('a-b')   == 'a%-b')
check('escape_pattern combo',          T.escape_pattern('(a)+b') == '%(a%)%+b')

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All mass_edit_transforms base tests passed.')
