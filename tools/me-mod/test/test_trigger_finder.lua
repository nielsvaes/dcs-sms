-- test_trigger_finder.lua — unit tests for the pure trigger_finder_model.
-- Runs on standalone Lua 5.1 (no DCS). Injects stub field_kind/type_label so
-- the model never touches the editor.
local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path
package.path = here .. '../lua/?.lua;' .. here .. '../lua/?/init.lua;' .. package.path

local model = require('dcs_sms_me.trigger_finder_model')

local passed, failed, errors = 0, 0, {}
local function assert_eq(actual, expected, name)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(errors, string.format('%s: expected %s, got %s',
            name, tostring(expected), tostring(actual)))
    end
end
local function assert_true(cond, name) assert_eq(cond and true or false, true, name) end

-- Stub schema closures: field key string -> ref kind; predicate -> its own string.
local function field_kind(_predicate, key)
    if key == 'unit' then return 'unit'
    elseif key == 'group' then return 'group'
    elseif key == 'zone' then return 'zone' end
    return nil
end
local function type_label(predicate) return tostring(predicate) end

local groups = {
    { id = 1, name = 'CAP-1', kind = 'group',
      units = { { id = 11, name = 'CAP-1-1' }, { id = 12, name = 'CAP-1-2' } } },
    { id = 2, name = 'CAP-2', kind = 'group',
      units = { { id = 21, name = 'CAP-2-1' } } },
    { id = 9, name = 'SAM-Static', kind = 'static' },
}
local trigrules = {
    { comment = 'UNIT DEAD', predicate = 'triggerOnce',
      rules = { { predicate = 'unit-dead', unit = 11 } }, actions = {} },          -- 1
    { comment = 'GROUP IN ZONE', predicate = 'triggerOnce',
      rules = { { predicate = 'group-in-zone', group = 1, zone = 99 } }, actions = {} }, -- 2
    { comment = 'EXPLODE STATIC', predicate = 'triggerOnce',
      rules = {}, actions = { { predicate = 'explosion', group = 9 } } },          -- 3
    { comment = 'DOUBLE', predicate = 'triggerContinious',
      rules = { { predicate = 'a', unit = 11 }, { predicate = 'b', unit = 11 } }, actions = {} }, -- 4
}

local function run()
    local res = model.build({ groups = groups, trigrules = trigrules,
                              field_kind = field_kind, type_label = type_label })

    -- Node count: 3 group-level nodes + 3 unit nodes (2 + 1) = 6
    assert_eq(#res.nodes, 6, 'node count')

    -- by_key lookup + kinds
    assert_eq(res.by_key['g1'].kind, 'group', 'g1 kind')
    assert_eq(res.by_key['g9'].kind, 'static', 'g9 static kind')
    assert_eq(res.by_key['u11'].kind, 'unit', 'u11 kind')
    assert_true(res.by_key['g1'].expandable, 'g1 expandable')
    assert_true(not res.by_key['g9'].expandable, 'static not expandable')
    assert_eq(res.by_key['u11'].parent, 'g1', 'u11 parent')
    assert_eq(res.by_key['u11'].depth, 1, 'u11 depth')

    -- Counts
    assert_eq(res.by_key['g1'].count, 1, 'g1 count (group-in-zone)')
    assert_eq(res.by_key['g2'].count, 0, 'g2 count zero')
    assert_eq(res.by_key['g9'].count, 1, 'static count (explosion)')
    assert_eq(res.by_key['u11'].count, 2, 'u11 count (unit-dead + double, deduped)')
    assert_eq(res.by_key['u12'].count, 0, 'u12 count zero')

    -- Trigger records on u11: ordered by trigrules index 1 then 4
    local t = res.by_key['u11'].triggers
    assert_eq(t[1].index, 1, 'u11 first trigger index')
    assert_eq(t[1].name, 'UNIT DEAD', 'u11 first trigger name')
    assert_eq(t[1].type, 'triggerOnce', 'u11 first trigger type label')
    assert_eq(t[1].why, 'condition · unit-dead', 'u11 first trigger why')
    assert_eq(t[2].index, 4, 'u11 second trigger index (double, deduped to one)')
    assert_eq(t[2].why, 'condition · a', 'u11 second trigger why uses first matching entry')

    -- Static matched via an ACTION
    assert_eq(res.by_key['g9'].triggers[1].why, 'action · explosion', 'static why is action')

    -- Empty input is safe
    local empty = model.build({})
    assert_eq(#empty.nodes, 0, 'empty build node count')
end

run()
print(string.format('test_trigger_finder: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
