-- test_trigger_schema.lua — predicate resolution + field classification.
local here = arg and arg[0] and arg[0]:match('^(.*[\\/])') or './'
package.path = here .. '?.lua;' .. here .. '../lua/?.lua;' .. package.path

local descr  = require('mock_trigger_descr')
local schema = require('dcs_sms_me.trigger_schema')

local passed, failed, errors = 0, 0, {}
local function check(cond, name)
    if cond then passed = passed + 1
    else failed = failed + 1; errors[#errors + 1] = name end
end

local s = schema.new({
    rulesDescr    = descr.rulesDescr,
    actionsDescr  = descr.actionsDescr,
    triggersDescr = descr.triggersDescr,
    field_kind_fn = descr.field_kind,
})

-- resolve: canonical + alias both work, kind filter enforced
local c, k = s:resolve('c_flag_is_true')
check(c == 'c_flag_is_true' and k == 'condition', 'resolve canonical condition')
c, k = s:resolve('flag-is-true')
check(c == 'c_flag_is_true' and k == 'condition', 'resolve alias condition')
c, k = s:resolve('activate-group')
check(c == 'a_activate_group' and k == 'action', 'resolve alias action')
c, k = s:resolve('continuous')
check(c == 'triggerContinious' and k == 'trigger', 'resolve continuous typo alias')
c, k = s:resolve('or')
check(c == 'or' and k == 'condition', 'resolve pseudo-predicate or')
local _, _, _, err = s:resolve('no_such_predicate')
check(err ~= nil, 'unknown predicate errors')
local _, _, _, err2 = s:resolve('a_set_flag', 'condition')
check(err2 ~= nil, 'kind mismatch errors')

-- make_alias / predicate_name handle both string and descriptor-table shapes
check(s.make_alias('triggerContinious') == 'continuous', 'alias typo fix')
check(s.make_alias({ name = 'c_all_of_group_in_zone' }) == 'all-of-group-in-zone',
      'alias from descriptor table')
check(s.predicate_name({ name = 'a_do_script' }) == 'a_do_script', 'predicate_name table')
check(s.predicate_name('a_do_script') == 'a_do_script', 'predicate_name string')
check(s.predicate_name(42) == '', 'predicate_name junk → empty')

-- field_descr + field_kind + field_default
local _, _, gz = s:resolve('c_all_of_group_in_zone')
local fd = s.field_descr(gz, 'zone')
check(fd ~= nil and fd.id == 'zone', 'field_descr finds zone')
check(s:field_kind(fd) == 'zone', 'field_kind via injected fn')
check(s.field_default(gz, 'zone') == 0, 'field_default zone = 0')
check(s.field_default(gz, 'group') == nil, 'field_default group = nil')

-- field_kind_for: descr + field id → kind in one call (the shared helper
-- trigger_export / triggers_tab / trigger_finder route through).
check(s:field_kind_for(gz, 'zone') == 'zone', 'field_kind_for resolves zone')
check(s:field_kind_for(gz, 'no_such_field') == nil, 'field_kind_for unknown field → nil')

print(string.format('test_trigger_schema: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL ' .. e) end
os.exit(failed == 0 and 0 or 1)
