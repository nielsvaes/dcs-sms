-- test_trigger_export.lua — trigrules → portable form.
local here = arg and arg[0] and arg[0]:match('^(.*[\\/])') or './'
package.path = here .. '?.lua;' .. here .. '../lua/?.lua;' .. package.path

local descr  = require('mock_trigger_descr')
local schema = require('dcs_sms_me.trigger_schema')
local b64    = require('dcs_sms_me.base64')
local export = require('dcs_sms_me.trigger_export')

local passed, failed, errors = 0, 0, {}
local function check(cond, name)
    if cond then passed = passed + 1
    else failed = failed + 1; errors[#errors + 1] = name end
end

local s = schema.new({
    rulesDescr = descr.rulesDescr, actionsDescr = descr.actionsDescr,
    triggersDescr = descr.triggersDescr, field_kind_fn = descr.field_kind,
})

local function find_descr(list, name)
    for _, d in pairs(list) do if d.name == name then return d end end
end

-- Build a realistic trigrules slice with ED-shaped entries
-- (predicate = descriptor TABLE, like disk-loaded missions).
local t_group_zone = {
    predicate = find_descr(descr.triggersDescr, 'triggerOnce'),
    comment = 'activate HornetCap', eventlist = '',
    colorItem = '0xff8800ff',   -- ED trigger-list color (hex)
    rules = {
        { predicate = find_descr(descr.rulesDescr, 'c_all_of_group_in_zone'),
          group = 12, zone = 99 },
    },
    actions = {
        { predicate = find_descr(descr.actionsDescr, 'a_activate_group'), group = 7 },
        { predicate = find_descr(descr.actionsDescr, 'a_out_text_delay'),
          text = 'DictKey_ActionText_50', KeyDict_text = 'DictKey_ActionText_50',
          seconds = 10 },
        { predicate = find_descr(descr.actionsDescr, 'a_out_picture'),
          file = 'ResKey_Action_36', seconds = 10 },
    },
}
local t_flags = {
    predicate = find_descr(descr.triggersDescr, 'triggerContinious'),
    comment = 'flag chain', eventlist = '',
    rules   = { { predicate = find_descr(descr.rulesDescr, 'c_flag_is_true'), flag = 100 } },
    actions = { { predicate = find_descr(descr.actionsDescr, 'a_set_flag'), flag = 101 },
                { predicate = find_descr(descr.actionsDescr, 'a_do_script'),
                  text = 'trigger.action.setUserFlag(1)' } },
}

local env = {
    schema = s,
    dict_get = function(key)
        if key == 'DictKey_ActionText_50' then return 'Station established' end
        return nil
    end,
    entity_name = function(kind, id)
        local names = { group = { [12] = 'Enemy Convoy', [7] = 'HornetCap' },
                        zone  = { [99] = 'Ambush Zone' } }
        return names[kind] and names[kind][id]
    end,
    media_read = function(key)
        if key == 'ResKey_Action_36' then return 'brief.png', 'PNGBYTES' end
        return nil, 'no such resource'
    end,
}

local out = export.to_portable({ t_group_zone, t_flags }, env)
check(out ~= nil and #out.triggers == 2, 'two triggers exported')

local tr1 = out.triggers[1]
check(tr1.name == 'activate HornetCap' and tr1.type == 'once', 'name + friendly type')
check(tr1.color == '0xff8800ff', 'trigger colorItem captured as portable color')
check(tr1.conditions[1].predicate == 'c_all_of_group_in_zone', 'condition canonical name')
local cf = tr1.conditions[1].fields
check(type(cf.group) == 'table' and cf.group.ref == 'group' and cf.group.id == 12
      and cf.group.name == 'Enemy Convoy', 'group ref encoded with name')
check(type(cf.zone) == 'table' and cf.zone.ref == 'zone' and cf.zone.name == 'Ambush Zone',
      'zone ref encoded')
check(tr1.actions[1].fields.group.id == 7, 'action group ref')
check(tr1.actions[2].fields.text == 'Station established', 'DictKey resolved to literal')
check(tr1.actions[2].fields.KeyDict_text == nil, 'KeyDict_ companion skipped')
check(type(tr1.actions[3].fields.file) == 'table'
      and tr1.actions[3].fields.file.res == 'brief.png', 'ResKey → {res=short}')

check(#out.resources == 1 and out.resources[1].name == 'brief.png'
      and out.resources[1].data == b64.encode('PNGBYTES'), 'resource embedded base64')

local tr2 = out.triggers[2]
check(tr2.color == nil, 'colorless trigger emits no color field')
check(tr2.actions[2].fields.text == 'trigger.action.setUserFlag(1)',
      'do-script text passes verbatim')
check(#out.flags_used == 2 and out.flags_used[1] == 100 and out.flags_used[2] == 101,
      'flags collected from structured fields only (script text NOT scanned)')

-- Unresolvable media → warning, field passes through as plain string
local t_bad_media = {
    predicate = find_descr(descr.triggersDescr, 'triggerOnce'),
    comment = 'bad media', eventlist = '',
    rules = {}, actions = { { predicate = find_descr(descr.actionsDescr, 'a_out_sound'),
                              file = 'ResKey_Action_99' } },
}
local out2 = export.to_portable({ t_bad_media }, env)
check(out2.triggers[1].actions[1].fields.file == 'ResKey_Action_99',
      'unreadable media stays verbatim string')
check(#out2.warnings >= 1, 'unreadable media produces warning')

-- non-string colorItem (e.g. a number) is not emitted as a portable color
local t_badcolor = {
    predicate = find_descr(descr.triggersDescr, 'triggerOnce'),
    comment = 'numcolor', eventlist = '', colorItem = 123,
    rules = {}, actions = { { predicate = find_descr(descr.actionsDescr, 'a_do_script'),
                              text = 'x()' } },
}
local out3 = export.to_portable({ t_badcolor }, env)
check(out3.triggers[1].color == nil, 'non-string colorItem dropped on export')

-- extract_flags over raw trigrules (used for target-side overlap scan)
local flags = export.extract_flags({ t_flags }, s)
check(#flags == 2, 'extract_flags standalone')

-- find_related: selection id sets
local rel = export.find_related({ t_group_zone, t_flags }, {
    group_ids = { [12] = true }, unit_ids = {}, zone_ids = {},
}, s)
check(#rel == 1 and rel[1].index == 1, 'related trigger detected via group id')
check(#rel[1].outside_refs == 2, 'outside refs reported (group 7 + zone 99)')

local rel2 = export.find_related({ t_flags }, {
    group_ids = {}, unit_ids = {}, zone_ids = {},
}, s)
check(#rel2 == 0, 'flag-only trigger not related to entity selection')

print(string.format('test_trigger_export: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL ' .. e) end
os.exit(failed == 0 and 0 or 1)
