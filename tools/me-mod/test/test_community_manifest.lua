-- test_community_manifest.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local cm = require('dcs_sms_me.community_manifest')
local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

local decoded = {
    schema = 1, generated = '2026-06-07T00:00:00Z',
    prefabs = {
        { name='SA-10 ring', author='Niels', date='2026-06-01', theatre='Caucasus',
          description='S-300', tags={'sam','ewr'}, likes=42, groups=7, zones=1,
          sha256='aa', path='prefabs/sa10.prefab' },
        { name='CAP pair', author='Wedge', date='2026-06-05', theatre='Syria',
          tags={'cap'}, likes=18, groups=1, sha256='bb', path='prefabs/cap.prefab' },
        { name='SA-6', author='Hawg', date='2026-05-20',
          tags={'sam'}, likes=27, sha256='cc', path='prefabs/sa6.prefab' },
        -- No sha256: must still be accepted (integrity is not hash-checked).
        { name='No Hash', author='Anon', date='2026-05-01',
          tags={}, likes=0, path='prefabs/nohash.prefab' },
    },
}

local m, err = cm.parse(decoded)
check('parse ok', m ~= nil, err)
check('entries count', m and #m.entries == 4)
check('entry without sha256 is kept', (function()
    for _, e in ipairs(m.entries) do if e.name == 'No Hash' then return true end end
    return false
end)())
check('defaults theatre', m.entries[3].theatre == '' or m.entries[3].theatre == '?', m.entries[3].theatre)
check('tags always table', type(m.entries[3].tags) == 'table' and m.entries[3].tags[1] == 'sam')
check('numeric counts', m.entries[1].groups == 7 and m.entries[3].groups == 0)

local bad, berr = cm.parse({ schema = 99, prefabs = {} })
check('reject unknown schema', bad == nil and type(berr) == 'string')

local bad2, berr2 = cm.parse({ prefabs = 'nope' })
check('reject missing schema/prefabs', bad2 == nil and type(berr2) == 'string')

local tags = cm.all_tags(m.entries)
check('all_tags sorted unique', tags[1]=='cap' and tags[2]=='ewr' and tags[3]=='sam' and #tags==3,
      table.concat(tags, ','))

local sam = cm.filter(m.entries, { tags = {'sam'} })
check('tag filter', #sam == 2)
local both = cm.filter(m.entries, { tags = {'sam','ewr'} })
check('tag filter AND', #both == 1 and both[1].name == 'SA-10 ring')
local txt = cm.filter(m.entries, { text = 'wedge' })
check('text matches author', #txt == 1 and txt[1].name == 'CAP pair')

local by_likes = cm.sort({ unpack(m.entries) }, 'likes')
check('sort likes desc', by_likes[1].likes == 42 and by_likes[3].likes == 18)
local by_name = cm.sort({ unpack(m.entries) }, 'name')
check('sort name asc', by_name[1].name == 'CAP pair')
local by_new = cm.sort({ unpack(m.entries) }, 'newest')
check('sort newest', by_new[1].date == '2026-06-05')

if failures > 0 then os.exit(1) end
print('All community_manifest tests passed.')
