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

-- find_replace: plain-text substring replace; replaces ALL occurrences;
-- meta chars in `find` are escaped via escape_pattern.
check('find_replace basic',
      T.find_replace('Hornet-01-Alpha', { find = 'Alpha', replace = 'Beta' }, 1)
      == 'Hornet-01-Beta')
check('find_replace all occurrences',
      T.find_replace('aa-bb-aa', { find = 'aa', replace = 'cc' }, 1)
      == 'cc-bb-cc')
check('find_replace with dot in find — treated literally',
      T.find_replace('a.b.c', { find = '.', replace = '-' }, 1)
      == 'a-b-c')
check('find_replace with parens in find',
      T.find_replace('(test)', { find = '(test)', replace = '[test]' }, 1)
      == '[test]')
check('find_replace empty replace',
      T.find_replace('foo-bar', { find = '-', replace = '' }, 1)
      == 'foobar')
check('find_replace miss returns original',
      T.find_replace('foo', { find = 'xyz', replace = 'q' }, 1)
      == 'foo')
check('find_replace nil old returns empty',
      T.find_replace(nil, { find = 'x', replace = 'y' }, 1)
      == '')

-- auto_number: substitute {n} in args.pattern with start + (idx-1)*step,
-- zero-padded to args.pad.
check('auto_number idx=1 start=1 step=1 pad=2',
      T.auto_number('anything', { pattern = 'Hornet-{n}', start = 1, step = 1, pad = 2 }, 1)
      == 'Hornet-01')
check('auto_number idx=3 start=10 step=1 pad=3',
      T.auto_number(nil, { pattern = 'Wp-{n}', start = 10, step = 1, pad = 3 }, 3)
      == 'Wp-012')
check('auto_number step=5',
      T.auto_number(nil, { pattern = '{n}', start = 0, step = 5, pad = 2 }, 4)
      == '15')
check('auto_number pad=1 (no zero-pad)',
      T.auto_number(nil, { pattern = '#{n}', start = 1, step = 1, pad = 1 }, 7)
      == '#7')
check('auto_number two {n} tokens both expand',
      T.auto_number(nil, { pattern = 'A{n}-B{n}', start = 5, step = 1, pad = 2 }, 1)
      == 'A05-B05')
check('auto_number pattern with no {n} returns pattern verbatim',
      T.auto_number(nil, { pattern = 'static', start = 1, step = 1, pad = 2 }, 3)
      == 'static')

-- offset: numeric add.
check('offset basic',             T.offset(100, { delta = 25 }, 1) == 125)
check('offset negative',          T.offset(100, { delta = -50 }, 1) == 50)
check('offset nil old treats as 0', T.offset(nil, { delta = 5 }, 1) == 5)
check('offset zero delta',        T.offset(10, { delta = 0 }, 1) == 10)

-- toggle_set: returns args.value as-is. nil means "leave unchanged" — the
-- transform returns nil; compute_plan reads this and skips the row.
check('toggle_set true',          T.toggle_set(false, { value = true }, 1)  == true)
check('toggle_set false',         T.toggle_set(true,  { value = false }, 1) == false)
check('toggle_set leave-unchanged', T.toggle_set(true, { value = nil }, 1)  == nil)

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All mass_edit_transforms base tests passed.')
