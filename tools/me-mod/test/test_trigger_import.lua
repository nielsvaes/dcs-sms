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

-- ---------------- inject (Task 7) ----------------
local function find_descr(list, name)
    for _, d in pairs(list) do if d.name == name then return d end end
end

local trigrules = {}
local media_calls = {}
local dict_calls = {}
local inject_env = {
    schema = s,
    create_trigger = descr.createTrigger,
    create_rule    = descr.createRule,
    create_action  = descr.createAction,
    fix_dict = function(entry, field, literal, label)
        dict_calls[#dict_calls + 1] = { field = field, literal = literal, label = label }
        entry[field] = 'DictKey_' .. label .. '_900'
        entry['KeyDict_' .. field] = entry[field]
    end,
    media_add = function(short, data, prefix)
        media_calls[#media_calls + 1] = { short = short, prefix = prefix }
        return 'ResKey_' .. prefix .. '_55'
    end,
    resources = { ['brief.png'] = 'UE5HQllURVM=' },  -- base64('PNGBYTES')
    trigrules = trigrules,
    unique_name = function(base) return base .. '-2' end,
}

local inj_portable = {
    { name = 'activate HornetCap', type = 'once', eventlist = '',
      conditions = {
        { predicate = 'c_all_of_group_in_zone',
          fields = { group = { ref = 'group', id = 12, name = 'Enemy Convoy' },
                     zone  = { ref = 'zone',  id = 99, name = 'Ambush Zone' } } } },
      actions = {
        { predicate = 'a_activate_group',
          fields = { group = { ref = 'group', id = 7, name = 'HornetCap' } } },
        { predicate = 'a_out_text_delay',
          fields = { text = 'Station established', seconds = 10 } },
        { predicate = 'a_out_picture',
          fields = { file = { res = 'brief.png' }, seconds = 10 } },
        { predicate = 'a_do_script',
          fields = { text = 'env.info("hi")' } },
      } },
}
local inj_plan = timport.resolve(inj_portable, {
    gid_map = { [12] = 200 }, zone_by_name = { ['Ambush Zone'] = 31 },
}, { schema = s,
     find_by_name = function(kind, name)
         if kind == 'group' and name == 'HornetCap' then return 77 end
     end,
     target_flags = {}, prefab_flags = {} })

local result = timport.inject(inj_plan, {}, inject_env)
check(result.count == 1 and #trigrules == 1, 'one trigger injected')
local e = trigrules[1]
check(e.comment == 'activate HornetCap-2', 'name went through unique_name')
check(type(e.predicate) == 'table' and e.predicate.name == 'triggerOnce',
      'trigger predicate stays a descriptor table')
check(e.rules[1].group == 200 and e.rules[1].zone == 31, 'condition refs rebound')
check(e.actions[1].group == 77, 'action ref rebound via name')
check(dict_calls[1] and dict_calls[1].field == 'text'
      and dict_calls[1].label == 'ActionText'
      and e.actions[2].text == 'DictKey_ActionText_900', 'dict text re-keyed')
check(media_calls[1] and media_calls[1].short == 'brief.png'
      and media_calls[1].prefix == 'Action'
      and e.actions[3].file == 'ResKey_Action_55', 'media re-added and re-keyed')
check(e.actions[4].text == 'env.info("hi")', 'do-script text NOT dict-keyed')
check(type(e.actions[1].predicate) == 'table', 'action predicate stays descriptor table')

-- unchecked trigger skipped
trigrules = {}; inject_env.trigrules = trigrules
local r2 = timport.inject(inj_plan, { checked = { [1] = false } }, inject_env)
check(r2.count == 0 and #trigrules == 0, 'unchecked trigger not injected')

-- binding 'skip' drops the condition; binding id rebinds; zero-actions guard
local p_skip = {
    { name = 'needs map', type = 'once', eventlist = '',
      conditions = { { predicate = 'c_unit_alive',
                       fields = { unit = { ref = 'unit', id = 500, name = 'Gone' } } } },
      actions = { { predicate = 'a_activate_group',
                    fields = { group = { ref = 'group', id = 1, name = 'AlsoGone' } } } } },
}
local plan_skip = timport.resolve(p_skip, {}, { schema = s,
    find_by_name = function() return nil end, target_flags = {}, prefab_flags = {} })

trigrules = {}; inject_env.trigrules = trigrules
local r3 = timport.inject(plan_skip, { bindings = {
    ['1/conditions/1/unit'] = 'skip',
    ['1/actions/1/group']   = 42,
} }, inject_env)
check(r3.count == 1 and #trigrules[1].rules == 0 and trigrules[1].actions[1].group == 42,
      'skip drops condition, binding rebinds action')

trigrules = {}; inject_env.trigrules = trigrules
local r4 = timport.inject(plan_skip, { bindings = {
    ['1/conditions/1/unit'] = 'skip',
    ['1/actions/1/group']   = 'skip',
} }, inject_env)
check(r4.count == 0 and #r4.skipped == 1, 'zero-actions trigger skipped with reason')

-- unknown predicate → trigger skipped, others continue
local p_unknown = {
    { name = 'bad', type = 'once', eventlist = '', conditions = {},
      actions = { { predicate = 'a_not_a_real_action', fields = {} } } },
    { name = 'good', type = 'start', eventlist = '', conditions = {},
      actions = { { predicate = 'a_do_script', fields = { text = 'x()' } } } },
}
local plan_u = timport.resolve(p_unknown, {}, { schema = s,
    find_by_name = function() return nil end, target_flags = {}, prefab_flags = {} })
trigrules = {}; inject_env.trigrules = trigrules
local r5 = timport.inject(plan_u, {}, inject_env)
check(r5.count == 1 and #r5.skipped == 1 and trigrules[1].comment:find('good'),
      'unknown predicate skips that trigger only')

-- missing embedded resource → action dropped, error recorded
local p_nores = {
    { name = 'nores', type = 'once', eventlist = '', conditions = {},
      actions = { { predicate = 'a_out_sound', fields = { file = { res = 'gone.ogg' } } },
                  { predicate = 'a_do_script', fields = { text = 'y()' } } } },
}
local plan_nr = timport.resolve(p_nores, {}, { schema = s,
    find_by_name = function() return nil end, target_flags = {}, prefab_flags = {} })
trigrules = {}; inject_env.trigrules = trigrules
local r6 = timport.inject(plan_nr, {}, inject_env)
check(r6.count == 1 and #trigrules[1].actions == 1 and #r6.errors >= 1,
      'missing resource drops only that action')

-- inject tolerates malformed entries (same untrusted-input rule as resolve)
local p_malformed = {
    { name = 'survivor', type = 'once', eventlist = '',
      conditions = { 42 },
      actions = { true,
                  { predicate = 'a_do_script', fields = { text = 'z()' } } } },
}
local plan_m = timport.resolve(p_malformed, {}, { schema = s,
    find_by_name = function() return nil end, target_flags = {}, prefab_flags = {} })
trigrules = {}; inject_env.trigrules = trigrules
local ok_inj, r7 = pcall(timport.inject, plan_m, {}, inject_env)
check(ok_inj == true, 'inject does not throw on malformed entries')
check(r7.count == 1 and #trigrules[1].rules == 0 and #trigrules[1].actions == 1,
      'malformed entries dropped, valid action survives')

-- non-numeric garbage binding rejected (entity-ref bindings are numeric ids)
trigrules = {}; inject_env.trigrules = trigrules
local r8 = timport.inject(plan_skip, { bindings = {
    ['1/conditions/1/unit'] = 'skip',
    ['1/actions/1/group']   = { evil = true },
} }, inject_env)
check(r8.count == 0 and #r8.errors >= 1, 'garbage binding rejected, entry dropped')

-- numeric-string binding coerced ('42' from a dialog combo is fine)
trigrules = {}; inject_env.trigrules = trigrules
local r9 = timport.inject(plan_skip, { bindings = {
    ['1/conditions/1/unit'] = 'skip',
    ['1/actions/1/group']   = '42',
} }, inject_env)
check(r9.count == 1 and trigrules[1].actions[1].group == 42,
      'numeric-string binding coerced to number')

-- failed media reports ONCE even when referenced by multiple actions
local p_nores2 = {
    { name = 'nores2', type = 'once', eventlist = '', conditions = {},
      actions = { { predicate = 'a_out_sound', fields = { file = { res = 'gone.ogg' } } },
                  { predicate = 'a_out_picture', fields = { file = { res = 'gone.ogg' }, seconds = 5 } },
                  { predicate = 'a_do_script', fields = { text = 'y()' } } } },
}
local plan_nr2 = timport.resolve(p_nores2, {}, { schema = s,
    find_by_name = function() return nil end, target_flags = {}, prefab_flags = {} })
trigrules = {}; inject_env.trigrules = trigrules
local r10 = timport.inject(plan_nr2, {}, inject_env)
check(r10.count == 1 and #trigrules[1].actions == 1 and #r10.errors == 1,
      'failed media cached: one error for two referencing actions')

print(string.format('test_trigger_import: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL ' .. e) end
os.exit(failed == 0 and 0 or 1)
