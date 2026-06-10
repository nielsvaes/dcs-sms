-- test_trigger_import.lua — portable triggers → resolution plan (Task 5)
-- and → injected trigrules entries (Task 7 appends more checks below).
local here = arg and arg[0] and arg[0]:match('^(.*[\\/])') or './'
package.path = here .. '?.lua;' .. here .. '../lua/?.lua;' .. package.path

local descr   = require('mock_trigger_descr')
local schema  = require('dcs_sms_me.trigger_schema')
local timport = require('dcs_sms_me.trigger_import')

local passed, failed, errors = 0, 0, {}
local function check(cond, name)
    if cond then passed = passed + 1
    else failed = failed + 1; errors[#errors + 1] = name end
end

local s = schema.new({
    rulesDescr = descr.rulesDescr, actionsDescr = descr.actionsDescr,
    triggersDescr = descr.triggersDescr, field_kind_fn = descr.field_kind,
})

-- Portable triggers (shape produced by trigger_export.to_portable).
local portable = {
    { name = 'activate HornetCap', type = 'once', eventlist = '',
      conditions = {
        { predicate = 'c_all_of_group_in_zone',
          fields = { group = { ref = 'group', id = 12, name = 'Enemy Convoy' },
                     zone  = { ref = 'zone',  id = 99, name = 'Ambush Zone' } } },
      },
      actions = {
        { predicate = 'a_activate_group',
          fields = { group = { ref = 'group', id = 7, name = 'HornetCap' } } },
      } },
    { name = 'check AWACS', type = 'continuous', eventlist = '',
      conditions = {
        { predicate = 'c_unit_alive',
          fields = { unit = { ref = 'unit', id = 500, name = 'AWACS Overlord' } } },
        -- stray defaulted zone ref (spec §4): unresolvable + has default → cleared
        { predicate = 'c_predicate',
          fields = { text = 'return true',
                     zone = { ref = 'zone', id = 4444, name = 'Gone Zone' } } },
      },
      actions = {
        { predicate = 'a_set_flag', fields = { flag = 100 } },
      } },
}

local maps = {
    gid_map = { [12] = 200 },             -- convoy was bundled and placed
    uid_map = {},
    zone_by_name = { ['Ambush Zone'] = 31 },
}
local env = {
    schema = s,
    find_by_name = function(kind, name)
        if kind == 'group' and name == 'HornetCap' then return 77 end
        return nil
    end,
    target_flags = { 100, 555 },
    prefab_flags = { 100, 101 },
}

local plan = timport.resolve(portable, maps, env)
check(plan ~= nil and #plan.triggers == 2, 'plan has two triggers')

local t1 = plan.triggers[1]
check(t1.unresolved == 0, 't1 fully resolved')
local function ref_of(t, list, entry, field)
    for _, r in ipairs(t.refs) do
        if r.list == list and r.entry == entry and r.field == field then return r end
    end
end
local r_group = ref_of(t1, 'conditions', 1, 'group')
check(r_group.resolution == 'map' and r_group.value == 200, 'group via gid_map')
local r_zone = ref_of(t1, 'conditions', 1, 'zone')
check(r_zone.resolution == 'map' and r_zone.value == 31, 'zone via zone_by_name')
local r_act = ref_of(t1, 'actions', 1, 'group')
check(r_act.resolution == 'name' and r_act.value == 77, 'group via name lookup')

local t2 = plan.triggers[2]
local r_unit = ref_of(t2, 'conditions', 1, 'unit')
check(r_unit.resolution == 'unresolved', 'unit unresolved')
check(r_unit.key == '2/conditions/1/unit', 'stable ref key')
check(t2.unresolved == 1, 'unresolved count excludes default-cleared')
local r_stray = ref_of(t2, 'conditions', 2, 'zone')
check(r_stray.resolution == 'default' and r_stray.value == 0,
      'stray defaulted zone cleared to descriptor default')
check(t2.would_lose_all_actions == false, 'actions have no unresolved refs')

check(#plan.flag_overlaps == 1 and plan.flag_overlaps[1] == 100, 'flag overlap detected')

-- would_lose_all_actions: single action with unresolved ref
local p2 = {
    { name = 'lonely', type = 'once', eventlist = '',
      conditions = {},
      actions = { { predicate = 'a_activate_group',
                    fields = { group = { ref = 'group', id = 1, name = 'Nope' } } } } },
}
local plan2 = timport.resolve(p2, {}, { schema = s,
    find_by_name = function() return nil end, target_flags = {}, prefab_flags = {} })
check(plan2.triggers[1].would_lose_all_actions == true,
      'all-actions-unresolved flagged')

-- portable input not mutated
check(type(portable[1].conditions[1].fields.group) == 'table'
      and portable[1].conditions[1].fields.group.id == 12, 'input unmutated')

-- malformed prefab data must not throw (prefab files are user-editable;
-- Community ones are untrusted — safe_load checks grammar, not shape)
local ok_mal, plan_mal = pcall(timport.resolve, {
    'not a trigger table',
    { name = 'half-formed', type = 'once',
      conditions = { 'junk entry', { predicate = 'c_flag_is_true', fields = 'junk' } },
      actions = { { predicate = 'a_do_script', fields = { text = 'x()' } } } },
}, {}, { schema = s, find_by_name = function() return nil end,
         target_flags = {}, prefab_flags = {} })
check(ok_mal == true and #plan_mal.triggers == 2, 'malformed entries tolerated, no throw')
check(plan_mal.triggers[2].unresolved == 0, 'junk entries contribute no refs')

-- whole to_portable bundle accepted (not just the bare triggers array)
local plan_bundle = timport.resolve({ triggers = p2, resources = {} }, {},
    { schema = s, find_by_name = function() return nil end,
      target_flags = {}, prefab_flags = {} })
check(#plan_bundle.triggers == 1, 'to_portable bundle shape accepted')

-- flag overlap is type-insensitive: 100 (number) vs '100' (string) match
local plan_flags = timport.resolve({}, {}, { schema = s,
    find_by_name = function() return nil end,
    target_flags = { 100 }, prefab_flags = { '100' } })
check(#plan_flags.flag_overlaps == 1, 'numeric vs string flag values overlap')

print(string.format('test_trigger_import: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL ' .. e) end
os.exit(failed == 0 and 0 or 1)
