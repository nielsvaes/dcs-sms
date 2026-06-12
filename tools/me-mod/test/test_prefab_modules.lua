-- test_prefab_modules.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local pm = require('dcs_sms_me.prefab_modules')
local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

-- Injected deps: a fake setRequiredModules-style resolver + display names.
local function required_ids(unit_type)
    if unit_type == 'UH-60L' or unit_type == 'KC130J' then return { 'UH-60L' } end
    if unit_type == 'A-4E-C' then return { 'A-4E-C' } end
    return {}  -- core / exempt
end
local function display_name(id)
    if id == 'UH-60L' then return 'UH-60L Black Hawk' end
    return id
end
local detect_deps = { required_ids = required_ids, display_name = display_name }

-- detect(): mixed selection aggregates per module with multiplicity.
local dump = {
    groups = {
        { units = { { type = 'UH-60L' }, { type = 'UH-60L' }, { type = 'M-1 Abrams' } } },
        { units = { { type = 'A-4E-C' } } },
    },
    statics = {
        { units = { { type = 'KC130J' } } },
    },
}
local req = pm.detect(dump, detect_deps)
check('detect returns a table', type(req) == 'table')
check('UH-60L count = 3 (2 units + 1 static KC130J)', req['UH-60L'] and req['UH-60L'].count == 3,
      req['UH-60L'] and req['UH-60L'].count)
check('UH-60L objects per type', req['UH-60L'] and req['UH-60L'].objects['UH-60L'] == 2
      and req['UH-60L'].objects['KC130J'] == 1)
check('UH-60L display name', req['UH-60L'] and req['UH-60L'].display_name == 'UH-60L Black Hawk')
check('A-4E-C count = 1', req['A-4E-C'] and req['A-4E-C'].count == 1)
check('A-4E-C display falls back to id', req['A-4E-C'] and req['A-4E-C'].display_name == 'A-4E-C')
check('core unit M-1 Abrams not recorded', req['M-1 Abrams'] == nil)

-- detect(): no mod units -> nil (so meta stays byte-stable).
local clean = { groups = { { units = { { type = 'M-1 Abrams' } } } } }
check('detect nil when nothing required', pm.detect(clean, detect_deps) == nil)

-- detect(): bad input -> nil, never throws.
check('detect nil on non-table', pm.detect('nope', detect_deps) == nil)

-- missing(): present vs absent plugins (injected).
local function plugin_present(id) return id == 'A-4E-C' end  -- only A-4E-C installed
local prefab = { meta = { required_modules = {
    ['UH-60L'] = { id = 'UH-60L', display_name = 'UH-60L Black Hawk', count = 3 },
    ['A-4E-C'] = { id = 'A-4E-C', display_name = 'A-4E-C', count = 1 },
} } }
local miss = pm.missing(prefab, { plugin_present = plugin_present })
check('missing returns 1 entry (UH-60L absent)', #miss == 1 and miss[1].id == 'UH-60L', #miss)
check('missing carries display_name + count', miss[1].display_name == 'UH-60L Black Hawk' and miss[1].count == 3)

-- missing(): no required_modules -> empty.
check('missing empty when no req', #pm.missing({ meta = {} }, { plugin_present = plugin_present }) == 0)
check('missing empty on bad prefab', #pm.missing(nil) == 0)

-- absent(): list-shaped sibling of missing() for the Community manifest entry,
-- whose required_modules is an ARRAY of { id, display_name, count } (not a map).
local function present_only_a4(id) return id == 'A-4E-C' end
local list = {
    { id = 'UH-60L', display_name = 'UH-60L Black Hawk', count = 3 },
    { id = 'A-4E-C', display_name = 'A-4E-C', count = 1 },
}
local ab = pm.absent(list, { plugin_present = present_only_a4 })
check('absent returns 1 entry (UH-60L absent)', #ab == 1 and ab[1].id == 'UH-60L', #ab)
check('absent carries display_name + count', ab[1].display_name == 'UH-60L Black Hawk' and ab[1].count == 3)

-- absent(): all present -> empty.
local function present_all(_) return true end
check('absent empty when all present', #pm.absent(list, { plugin_present = present_all }) == 0)

-- absent(): multiple missing sort by id; display_name falls back to id.
local function present_none(_) return false end
local many = { { id = 'Zulu' }, { id = 'Alpha', display_name = 'Alpha Mod' } }
local ab2 = pm.absent(many, { plugin_present = present_none })
check('absent sorts by id', #ab2 == 2 and ab2[1].id == 'Alpha' and ab2[2].id == 'Zulu')
check('absent display_name falls back to id', ab2[2].display_name == 'Zulu')

-- absent(): bad input -> empty, never throws.
check('absent empty on non-table', #pm.absent('nope') == 0)
check('absent empty on nil', #pm.absent(nil) == 0)

os.exit(failures == 0 and 0 or 1)
