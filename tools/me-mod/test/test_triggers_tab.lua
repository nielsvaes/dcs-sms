-- test_triggers_tab.lua — pure presentation helpers of the Triggers tab.
local here = arg and arg[0] and arg[0]:match('^(.*[\\/])') or './'
package.path = here .. '?.lua;' .. here .. '../lua/?.lua;' .. package.path

local descr  = require('mock_trigger_descr')
local schema = require('dcs_sms_me.trigger_schema')
local tab    = require('dcs_sms_me.triggers_tab')

local passed, failed, errors = 0, 0, {}
local function check(cond, name)
    if cond then passed = passed + 1
    else failed = failed + 1; errors[#errors + 1] = name end
end

check(type(tab.build) == 'function', 'module loads headless with build()')

local s = schema.new({
    rulesDescr = descr.rulesDescr, actionsDescr = descr.actionsDescr,
    triggersDescr = descr.triggersDescr, field_kind_fn = descr.field_kind,
})
local function find_descr(list, name)
    for _, d in pairs(list) do if d.name == name then return d end end
end

local t_portable_ok = {
    predicate = find_descr(descr.triggersDescr, 'triggerContinious'),
    comment = 'freq check', eventlist = '',
    rules   = { { predicate = find_descr(descr.rulesDescr, 'c_flag_is_true'), flag = 1 } },
    actions = { { predicate = find_descr(descr.actionsDescr, 'a_do_script'), text = 'x()' } },
}
local t_refs = {
    predicate = find_descr(descr.triggersDescr, 'triggerOnce'),
    comment = 'zone gate', eventlist = '',
    rules   = { { predicate = find_descr(descr.rulesDescr, 'c_all_of_group_in_zone'),
                  group = 12, zone = 99 } },
    actions = { { predicate = find_descr(descr.actionsDescr, 'a_out_picture'),
                  file = 'ResKey_Action_36', seconds = 10 } },
}

-- refs_summary: 'none' when fully portable; badges otherwise (sorted,
-- deduped).
check(tab.refs_summary(t_portable_ok, s) == 'none', 'portable → none')
local summary = tab.refs_summary(t_refs, s)
check(summary:find('group') and summary:find('zone') and summary:find('media'),
      'badges for group/zone/media')

-- detail_text: resolved friendly rendering
local env = {
    schema = s,
    dict_get = function(k) return nil end,
    entity_name = function(kind, id)
        if kind == 'group' and id == 12 then return 'Enemy Convoy' end
        if kind == 'zone' and id == 99 then return 'Ambush Zone' end
    end,
    media_short = function(k) return k == 'ResKey_Action_36' and 'brief.png' or nil end,
}
local text = tab.detail_text(t_refs, s, env)
check(text:find('zone gate', 1, true) and text:find('once', 1, true), 'header line')
check(text:find('all%-of%-group%-in%-zone'), 'condition alias listed')
check(text:find('Enemy Convoy', 1, true), 'ref rendered with name')
check(text:find('brief.png', 1, true), 'media rendered with filename')
check(text:find('Portability', 1, true), 'portability section present')

print(string.format('test_triggers_tab: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL ' .. e) end
os.exit(failed == 0 and 0 or 1)
