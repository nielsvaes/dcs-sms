-- test_community_meta.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local cmeta = require('dcs_sms_me.community_meta')
local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

local m = cmeta.parse({ images = { '123/1.png', '123/2.png', '123/3.png' }, author = 'x' })
check('parse ok', m ~= nil)
check('three images', m and #m.images == 3, m and #m.images)
check('order preserved', m.images[1] == '123/1.png' and m.images[3] == '123/3.png')

local none = cmeta.parse({ author = 'x' })  -- no images field
check('no images -> empty list', none ~= nil and type(none.images) == 'table' and #none.images == 0)

local junk = cmeta.parse({ images = { '1.png', 42, '', false, '2.png' } })
check('drops non-string / empty', junk and #junk.images == 2
      and junk.images[1] == '1.png' and junk.images[2] == '2.png',
      junk and table.concat(junk.images, ','))

local bad = cmeta.parse('nope')
check('reject non-table', bad == nil)

local bad2 = cmeta.parse({ images = 'nope' })  -- images not a table
check('non-table images -> empty list', bad2 ~= nil and #bad2.images == 0)

if failures > 0 then os.exit(1) end
print('All community_meta tests passed.')
