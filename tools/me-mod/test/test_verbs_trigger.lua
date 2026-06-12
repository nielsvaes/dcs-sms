-- test_verbs_trigger.lua — Lua-side unit tests for verbs/trigger_verbs.lua.

local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path

local mock = require('mock_me_mission')
package.preload['me_mission']    = function() return mock end
package.preload['me_map_window'] = function() return mock end

-- ============================================================
-- Predicate descriptor stubs (me_predicates + me_trigrules)
-- ============================================================
-- The verb queries these via require('me_predicates').rulesDescr,
-- require('me_trigrules').actionsDescr, .triggersDescr. Each descriptor:
--   { name = 'c_<id>' | 'a_<id>' | 'triggerXxx',
--     display = 'Display text',
--     fields = { { id = 'flag', type = 'edit' [, default = ...] }, ... } }
-- Selector singleton descriptors (UNIT_SELECTOR / DRAW_SELECTOR on
-- me_predicates) are detected by table identity for ref-kind classification.

local Predicates = {}
local Trigger = {}

Predicates.UNIT_SELECTOR = { id = 'unit', type = 'combo',
                              comboFunc = function() end }
Predicates.DRAW_SELECTOR = { id = 'draw', type = 'combo',
                              comboFunc = function() end }
Predicates.VEHICLE_SELECTOR = { id = 'vehicle', type = 'combo',
                                 comboFunc = function() end }
Predicates.AIRCARRIER_SELECTOR = { id = 'aircarrier', type = 'combo',
                                    comboFunc = function() end }

-- Listers used by the field-kind classifier. The verbs only check identity,
-- not behavior — bodies are no-ops.
Predicates.zonesLister = function() end
Predicates.groupsLister = function() end
Predicates.coalitionIdToName = function() end
Predicates.coalitionIdToName2 = function() end
Predicates.airdromeLister = function() end
Predicates.helipadLister = function() end

Trigger.groupsLister      = function() end
Trigger.groupsStaticLister = function() end
Trigger.groupsAHLister    = function() end
Trigger.groupsListerS     = function() end
Trigger.groupsVLister     = function() end
Trigger.groupsVSLister    = function() end
Trigger.coalitionIdToName = function() end
Trigger.coalition2IdToName = function() end
Trigger.winnerLister      = function() end
Trigger.airdromeAndHeliportLister = function() end
Trigger.eventLister       = function() end

Predicates.rulesDescr = {
    { name = 'c_flag_is_true',
      display = 'FLAG IS TRUE',
      fields = { { id = 'flag', type = 'edit' } } },
    { name = 'c_time_more',
      display = 'TIME MORE',
      fields = { { id = 'seconds', type = 'edit' } } },
    -- A condition with a unit reference (tier-1 identity match).
    { name = 'c_unit_alive',
      display = 'UNIT IS ALIVE',
      fields = { Predicates.UNIT_SELECTOR } },
    -- A condition with a zone reference (tier-2 comboFunc match via
    -- Predicates.zonesLister identity).
    { name = 'c_unit_in_zone',
      display = 'UNIT IN ZONE',
      fields = {
          Predicates.UNIT_SELECTOR,
          { id = 'zone', type = 'combo', comboFunc = Predicates.zonesLister },
      } },
    -- LUA PREDICATE: its `text` field must be dict-keyed on save, exactly
    -- like an action's text (ED's saveTriggers routes every condition
    -- rule's `text` through textToMis).
    { name = 'c_predicate',
      display = 'LUA PREDICATE',
      fields = { { id = 'text', type = 'edit' } } },
    -- Pseudo-predicate keyed by string in rulesDescr (mirrors ED's `["or"]`).
    ['or'] = { name = 'or', display = 'OR', fields = {} },
}

Trigger.actionsDescr = {
    { name = 'a_set_flag',
      display = 'SET FLAG',
      fields = {
          { id = 'flag',  type = 'edit' },
          { id = 'value', type = 'edit', default = 1 },
      } },
    { name = 'a_message_to_all',
      display = 'MESSAGE TO ALL',
      fields = {
          { id = 'text', type = 'edit' },
      } },
    { name = 'a_do_script',
      display = 'DO SCRIPT',
      fields = {
          { id = 'text', type = 'edit' },
      } },
    { name = 'a_group_activate',
      display = 'GROUP ACTIVATE',
      fields = {
          { id = 'group', type = 'combo', comboFunc = Trigger.groupsLister },
      } },
}

Trigger.triggersDescr = {
    { name = 'triggerOnce',       display = 'ONCE',       fields = {} },
    { name = 'triggerContinious', display = 'CONTINUOUS', fields = {} },
    { name = 'triggerStart',      display = 'MISSION START', fields = {} },
    { name = 'triggerFront',      display = 'FRONT',      fields = {} },
}

function Trigger.createTrigger(descr)
    return {
        predicate = descr,
        comment   = 'Trigger ' .. tostring(os.time()),
        eventlist = '',
        rules     = {},
        actions   = {},
    }
end

function Predicates.createRule(descr)
    local entry = { predicate = descr }
    if type(descr.fields) == 'table' then
        for _, f in ipairs(descr.fields) do
            if type(f) == 'table' and f.id and f.default ~= nil then
                entry[f.id] = f.default
            end
        end
    end
    return entry
end

function Trigger.createAction(descr)
    local entry = { predicate = descr }
    if type(descr.fields) == 'table' then
        for _, f in ipairs(descr.fields) do
            if type(f) == 'table' and f.id and f.default ~= nil then
                entry[f.id] = f.default
            end
        end
    end
    return entry
end

package.preload['me_predicates'] = function() return Predicates end
package.preload['me_trigrules']  = function() return Trigger end

-- Dictionary stub. fixDict allocates DictKey_<comment>_<n>, stores the literal
-- in a shared dict, and writes entry[field] = key + entry['KeyDict_' .. field] = key.
local dict_storage = {}
local dict_next = 1
local dictionary_stub = {}
function dictionary_stub.fixDict(entry, field, value, comment_prefix)
    local key = 'DictKey_' .. (comment_prefix or 'X') .. '_' .. dict_next
    dict_next = dict_next + 1
    dict_storage[key] = value
    entry[field] = key
    entry['KeyDict_' .. field] = key
end
function dictionary_stub.getValueDict(key) return dict_storage[key] end
package.preload['dictionary'] = function() return dictionary_stub end

-- TriggerZoneData stub for zone-by-name resolution.
local zone_registry = {}  -- zid → name
package.preload['Mission.TriggerZoneData'] = function()
    return {
        getTriggerZoneIds = function()
            local ids = {}
            for zid in pairs(zone_registry) do table.insert(ids, zid) end
            table.sort(ids)
            return ids
        end,
        getTriggerZoneName = function(zid) return zone_registry[zid] end,
    }
end

-- Stubs for the other modules pulled in by the aggregator's noun files.
package.preload['terrain']      = function() return { GetSurfaceType = function() return 'sea' end } end
package.preload['utils_common'] = function() return { actions = {} } end
package.preload['me_db_api']    = function() return { templates = {}, unit_by_type = {} } end
package.preload['me_payload']   = function() return { setDefaultLivery = function() end } end
package.preload['me_route']     = function()
    return { isAirfieldWaypoint = function() return false end,
             attractToAirfield = function() end,
             update = function() end }
end
package.preload['me_draw_panel'] = function()
    return { saveToMission = function() return { layers = {} } end,
             loadFromMission = function() end,
             getObjects = function() return {} end,
             objectDelete = function() end }
end

package.path = here .. '../lua/?.lua;' .. here .. '../lua/?/init.lua;' .. package.path

local verbs = require('dcs_sms_me.verbs')

-- ============================================================
-- Test harness
-- ============================================================

local passed, failed, errors = 0, 0, {}

local function assert_eq(actual, expected, name)
    if actual == expected then passed = passed + 1
    else failed = failed + 1
        table.insert(errors, string.format('%s: expected %s, got %s',
            name, tostring(expected), tostring(actual)))
    end
end

local function assert_true(cond, name)  assert_eq(cond and true or false, true, name) end
local function assert_false(cond, name) assert_eq(cond and true or false, false, name) end

local function assert_contains(haystack, needle, name)
    if type(haystack) == 'string' and haystack:find(needle, 1, true) then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(errors, string.format('%s: expected string containing %q, got %s',
            name, needle, tostring(haystack)))
    end
end

local function reset()
    mock.new_mission()
    -- Reset dict + zone registry between tests
    dict_storage = {}
    zone_registry = {}
end

-- ============================================================
-- trigger_list_predicates
-- ============================================================

local function test_list_predicates_all()
    reset()
    local r = verbs.trigger_list_predicates({})
    assert_true(r.ok, 'list_predicates: ok')
    assert_true(r.count >= 4, 'list_predicates: includes condition predicates')
end

local function test_list_predicates_filter_kind()
    reset()
    local r1 = verbs.trigger_list_predicates({ kind = 'condition' })
    local r2 = verbs.trigger_list_predicates({ kind = 'action' })
    local r3 = verbs.trigger_list_predicates({ kind = 'trigger' })
    assert_true(r1.count >= 1, 'list_predicates kind=condition: nonzero')
    assert_true(r2.count >= 1, 'list_predicates kind=action: nonzero')
    assert_true(r3.count == 4, 'list_predicates kind=trigger: 4 entries')
end

local function test_list_predicates_filter_search()
    reset()
    local r = verbs.trigger_list_predicates({ search = 'flag' })
    assert_true(r.count >= 1, 'list_predicates search=flag: hits')
end

local function test_list_predicates_includes_or_pseudo()
    -- The ['or'] entry under rulesDescr is keyed by string, picked up via
    -- pairs() walk; verifies the rules-descr walk handles non-ipairs entries.
    reset()
    local r = verbs.trigger_list_predicates({})
    local has_or = false
    for _, p in ipairs(r.predicates) do
        if p.name == 'or' then has_or = true; break end
    end
    assert_true(has_or, 'list_predicates: includes "or" pseudo predicate')
end

-- ============================================================
-- trigger_describe_predicate
-- ============================================================

local function test_describe_canonical()
    reset()
    local r = verbs.trigger_describe_predicate({ name = 'c_flag_is_true' })
    assert_true(r.ok, 'describe canonical: ok')
    assert_eq(r.alias, 'flag-is-true', 'describe: alias')
    assert_eq(r.kind, 'condition', 'describe: kind')
    assert_true(#r.fields >= 1, 'describe: at least 1 field')
end

local function test_describe_alias()
    reset()
    local r = verbs.trigger_describe_predicate({ name = 'flag-is-true' })
    assert_true(r.ok, 'describe alias: ok')
    assert_eq(r.name, 'c_flag_is_true', 'describe alias: canonical name')
end

local function test_describe_unknown()
    reset()
    local r = verbs.trigger_describe_predicate({ name = 'unknown_predicate' })
    assert_false(r.ok, 'describe unknown: refused')
    assert_contains(r.error, 'unknown predicate', 'describe: error msg')
end

local function test_describe_continuous_alias_fixed_typo()
    -- ED's actual name is "triggerContinious" (typo); alias maker normalizes
    -- it to the correctly-spelled "continuous".
    reset()
    local r = verbs.trigger_describe_predicate({ name = 'triggerContinious' })
    assert_true(r.ok, 'describe Continious: ok')
    assert_eq(r.alias, 'continuous', 'describe: typo-corrected alias')
end

local function test_describe_arg_validation()
    reset()
    assert_false(verbs.trigger_describe_predicate(nil).ok, 'describe: nil')
    assert_false(verbs.trigger_describe_predicate({}).ok, 'describe: missing name')
end

-- ============================================================
-- trigger_create / trigger_remove / trigger_list / trigger_get
-- ============================================================

local function test_create_happy()
    reset()
    local r = verbs.trigger_create({ type = 'once', name = 'T1' })
    assert_true(r.ok, 'create: ok')
    assert_eq(r.name, 'T1', 'create: name')
    assert_eq(r.type, 'once', 'create: type')
    assert_eq(r.index, 1, 'create: index = 1')
    assert_eq(#mock.mission.trigrules, 1, 'create: trigrules length')
end

local function test_create_default_name()
    reset()
    local r = verbs.trigger_create({ type = 'once' })
    assert_true(r.ok, 'create default name: ok')
    assert_contains(r.name, 'Trigger ', 'create: default name has Trigger prefix')
end

local function test_create_name_collision_uniquifies()
    reset()
    verbs.trigger_create({ type = 'once', name = 'T2' })
    local r2 = verbs.trigger_create({ type = 'once', name = 'T2' })
    assert_true(r2.ok, 'create collision: ok')
    assert_eq(r2.name, 'T2-2', 'create collision: name uniquified')
end

local function test_create_arg_validation()
    reset()
    assert_false(verbs.trigger_create({}).ok, 'create: missing type')
    assert_false(verbs.trigger_create({ type = '' }).ok, 'create: empty type')
    assert_false(verbs.trigger_create({ type = 'bogus' }).ok, 'create: unknown type')
    -- Using a condition predicate as trigger type fails kind check
    assert_false(verbs.trigger_create({ type = 'flag-is-true' }).ok,
                 'create: condition as trigger refused')
end

local function test_remove_happy()
    reset()
    verbs.trigger_create({ type = 'once', name = 'R1' })
    local r = verbs.trigger_remove({ name = 'R1' })
    assert_true(r.ok, 'remove: ok')
    assert_eq(r.count, 0, 'remove: count after = 0')
end

local function test_remove_not_found()
    reset()
    local r = verbs.trigger_remove({ name = 'ghost' })
    assert_false(r.ok, 'remove not found: refused')
end

local function test_list_happy()
    reset()
    verbs.trigger_create({ type = 'once', name = 'L1' })
    verbs.trigger_create({ type = 'continuous', name = 'L2' })
    local r = verbs.trigger_list({})
    assert_true(r.ok, 'list: ok')
    assert_eq(r.count, 2, 'list: count = 2')
    assert_eq(r.triggers[1].name, 'L1', 'list: name')
    assert_eq(r.triggers[2].type, 'continuous', 'list: type alias')
end

local function test_get_happy()
    reset()
    verbs.trigger_create({ type = 'once', name = 'G1' })
    local r = verbs.trigger_get({ name = 'G1' })
    assert_true(r.ok, 'get: ok')
    assert_eq(r.name, 'G1', 'get: name')
    assert_eq(r.type, 'once', 'get: type alias')
    assert_eq(#r.conditions, 0, 'get: 0 conditions')
    assert_eq(#r.actions, 0, 'get: 0 actions')
end

local function test_get_not_found()
    reset()
    local r = verbs.trigger_get({ name = 'ghost' })
    assert_false(r.ok, 'get not found: refused')
end

-- ============================================================
-- trigger_set_name / set_eventlist
-- ============================================================

local function test_set_name_happy()
    reset()
    verbs.trigger_create({ type = 'once', name = 'SN1' })
    local r = verbs.trigger_set_name({ name = 'SN1', to = 'SN1-renamed' })
    assert_true(r.ok, 'set_name: ok')
    assert_eq(r.name, 'SN1-renamed', 'set_name: applied')
end

local function test_set_name_collision_refused()
    reset()
    verbs.trigger_create({ type = 'once', name = 'SN2a' })
    verbs.trigger_create({ type = 'once', name = 'SN2b' })
    local r = verbs.trigger_set_name({ name = 'SN2a', to = 'SN2b' })
    assert_false(r.ok, 'set_name collision: refused')
end

local function test_set_eventlist_happy()
    reset()
    verbs.trigger_create({ type = 'once', name = 'EV1' })
    local r = verbs.trigger_set_eventlist({ name = 'EV1', event = 'EVENT_TAKEOFF' })
    assert_true(r.ok, 'set_eventlist: ok')
    assert_eq(r.eventlist, 'EVENT_TAKEOFF', 'set_eventlist: applied')
end

local function test_set_eventlist_clear()
    reset()
    verbs.trigger_create({ type = 'once', name = 'EV2' })
    verbs.trigger_set_eventlist({ name = 'EV2', event = 'X' })
    local r = verbs.trigger_set_eventlist({ name = 'EV2', event = '' })
    assert_true(r.ok, 'set_eventlist clear: ok')
    assert_eq(r.eventlist, '', 'set_eventlist clear: empty')
end

-- ============================================================
-- trigger_add_condition / remove_condition
-- ============================================================

local function test_add_condition_simple()
    reset()
    verbs.trigger_create({ type = 'once', name = 'AC1' })
    local r = verbs.trigger_add_condition({
        trigger = 'AC1', predicate = 'flag-is-true',
        fields = { flag = 100 } })
    assert_true(r.ok, 'add_condition: ok')
    assert_eq(r.index, 1, 'add_condition: index = 1')
    assert_eq(r.predicate, 'c_flag_is_true', 'add_condition: canonical predicate')
end

local function test_add_condition_unit_ref_resolves_name_to_id()
    reset()
    local g = mock.add_plane({ name = 'Hornet' })  -- unit will be 'Hornet-1'
    local unit_name = g.units[1].name
    verbs.trigger_create({ type = 'once', name = 'AC2' })
    local r = verbs.trigger_add_condition({
        trigger = 'AC2', predicate = 'c_unit_alive',
        fields = { unit = unit_name } })
    assert_true(r.ok, 'add_condition unit by name: ok')
    -- Verify stored value is the integer unitId, not the name
    local got = verbs.trigger_get({ name = 'AC2' })
    assert_eq(got.conditions[1].fields.unit, g.units[1].unitId,
              'add_condition: unit name → unitId in storage')
    assert_eq(got.conditions[1].fields.unit_name, unit_name,
              'add_condition get: enrichment with _name companion')
end

local function test_add_condition_unit_ref_unknown_name()
    reset()
    verbs.trigger_create({ type = 'once', name = 'AC3' })
    local r = verbs.trigger_add_condition({
        trigger = 'AC3', predicate = 'c_unit_alive',
        fields = { unit = 'Ghost' } })
    assert_false(r.ok, 'add_condition unknown unit: refused')
    assert_contains(r.error, 'no unit', 'add_condition: error msg')
end

local function test_add_condition_unknown_field()
    reset()
    verbs.trigger_create({ type = 'once', name = 'AC4' })
    local r = verbs.trigger_add_condition({
        trigger = 'AC4', predicate = 'flag-is-true',
        fields = { wrong_field = 1 } })
    assert_false(r.ok, 'add_condition unknown field: refused')
    assert_contains(r.error, 'unknown field', 'add_condition: error msg')
end

local function test_add_condition_arg_validation()
    reset()
    assert_false(verbs.trigger_add_condition({}).ok, 'add_condition: empty')
    assert_false(verbs.trigger_add_condition({ trigger = 'x' }).ok,
                 'add_condition: missing predicate')
    -- Using an action predicate as condition fails kind check
    verbs.trigger_create({ type = 'once', name = 'AC5' })
    local r = verbs.trigger_add_condition({
        trigger = 'AC5', predicate = 'set-flag', fields = { flag = 1 } })
    assert_false(r.ok, 'add_condition: action-as-condition refused')
end

local function test_remove_condition_happy()
    reset()
    verbs.trigger_create({ type = 'once', name = 'RC1' })
    verbs.trigger_add_condition({ trigger = 'RC1', predicate = 'flag-is-true',
        fields = { flag = 1 } })
    verbs.trigger_add_condition({ trigger = 'RC1', predicate = 'flag-is-true',
        fields = { flag = 2 } })
    local r = verbs.trigger_remove_condition({ trigger = 'RC1', index = 1 })
    assert_true(r.ok, 'remove_condition: ok')
    assert_eq(r.remaining, 1, 'remove_condition: 1 remaining')
end

local function test_remove_condition_oob()
    reset()
    verbs.trigger_create({ type = 'once', name = 'RC2' })
    local r = verbs.trigger_remove_condition({ trigger = 'RC2', index = 1 })
    assert_false(r.ok, 'remove_condition oob: refused')
    assert_contains(r.error, 'only 0', 'remove_condition: error msg')
end

-- ============================================================
-- trigger_add_action / remove_action
-- ============================================================

local function test_add_action_simple()
    reset()
    verbs.trigger_create({ type = 'once', name = 'AA1' })
    local r = verbs.trigger_add_action({
        trigger = 'AA1', predicate = 'set-flag',
        fields = { flag = 100, value = 1 } })
    assert_true(r.ok, 'add_action: ok')
    assert_eq(r.predicate, 'a_set_flag', 'add_action: canonical predicate')
end

local function test_add_condition_predicate_text_routes_through_dict()
    -- c_predicate's text field must go through fixDict (allocating a
    -- DictKey_* + KeyDict_text companion). Without it, ED's saveTriggers
    -- wipes the Lua predicate on save (rule.text becomes nil). Regression
    -- guard for the "Lua predicate empties when the mission is saved" bug.
    reset()
    verbs.trigger_create({ type = 'once', name = 'PC1' })
    local r = verbs.trigger_add_condition({
        trigger = 'PC1', predicate = 'predicate',
        fields = { text = 'return MIZ.whatever' } })
    assert_true(r.ok, 'add_condition predicate: ok')
    local raw = verbs.trigger_get({ name = 'PC1', raw = true })
    local rule = raw.trigger.rules[1]
    assert_eq(rule.KeyDict_text ~= nil, true,
              'add_condition predicate: KeyDict_text companion set')
    assert_contains(rule.text, 'DictKey_',
                    'add_condition predicate: text replaced with DictKey_*')
    -- Reading via get (resolved) should give back the literal Lua code.
    local got = verbs.trigger_get({ name = 'PC1' })
    assert_eq(got.conditions[1].fields.text, 'return MIZ.whatever',
              'add_condition predicate read: literal text resolved')
end

local function test_add_action_text_routes_through_dict()
    -- a_message_to_all's text field should go through fixDict (allocating
    -- a DictKey_*). On read-back, the verb resolves it back to the literal.
    reset()
    verbs.trigger_create({ type = 'once', name = 'AA2' })
    local r = verbs.trigger_add_action({
        trigger = 'AA2', predicate = 'message-to-all',
        fields = { text = 'Hello world' } })
    assert_true(r.ok, 'add_action message: ok')
    -- Inspect underlying entry to confirm dict key allocation
    local raw = verbs.trigger_get({ name = 'AA2', raw = true })
    local action = raw.trigger.actions[1]
    assert_eq(action.KeyDict_text ~= nil, true, 'add_action: KeyDict_text companion set')
    assert_contains(action.text, 'DictKey_', 'add_action: text replaced with DictKey_*')
    -- Reading via get (resolved) should give back the literal
    local got = verbs.trigger_get({ name = 'AA2' })
    assert_eq(got.actions[1].fields.text, 'Hello world',
              'add_action read: literal text resolved')
end

local function test_add_action_do_script_skips_dict()
    -- a_do_script's text field is a raw Lua script — ED's saveTriggers skips
    -- textToMis for it, so fixDict must also be skipped.
    reset()
    verbs.trigger_create({ type = 'once', name = 'AA3' })
    local r = verbs.trigger_add_action({
        trigger = 'AA3', predicate = 'do-script',
        fields = { text = 'env.info("hi")' } })
    assert_true(r.ok, 'add_action do_script: ok')
    local raw = verbs.trigger_get({ name = 'AA3', raw = true })
    local action = raw.trigger.actions[1]
    assert_eq(action.KeyDict_text, nil,
              'add_action do_script: NO KeyDict_text (script not dict-keyed)')
    assert_eq(action.text, 'env.info("hi")',
              'add_action do_script: text stored as literal')
end

local function test_add_action_group_ref()
    reset()
    local g = mock.add_plane({ name = 'Strike-1' })
    verbs.trigger_create({ type = 'once', name = 'AA4' })
    local r = verbs.trigger_add_action({
        trigger = 'AA4', predicate = 'group-activate',
        fields = { group = 'Strike-1' } })
    assert_true(r.ok, 'add_action group: ok')
    local got = verbs.trigger_get({ name = 'AA4' })
    assert_eq(got.actions[1].fields.group, g.groupId,
              'add_action: group name → groupId')
    assert_eq(got.actions[1].fields.group_name, 'Strike-1',
              'add_action get: enrichment with group_name')
end

local function test_remove_action_happy()
    reset()
    verbs.trigger_create({ type = 'once', name = 'RA1' })
    verbs.trigger_add_action({ trigger = 'RA1', predicate = 'set-flag',
        fields = { flag = 1, value = 1 } })
    local r = verbs.trigger_remove_action({ trigger = 'RA1', index = 1 })
    assert_true(r.ok, 'remove_action: ok')
    assert_eq(r.remaining, 0, 'remove_action: 0 remaining')
end

local function test_remove_action_oob()
    reset()
    verbs.trigger_create({ type = 'once', name = 'RA2' })
    local r = verbs.trigger_remove_action({ trigger = 'RA2', index = 1 })
    assert_false(r.ok, 'remove_action oob: refused')
    assert_contains(r.error, 'only 0', 'remove_action: error msg')
end

local function test_remove_action_arg_validation()
    reset()
    assert_false(verbs.trigger_remove_action({}).ok, 'remove_action: empty')
    assert_false(verbs.trigger_remove_action({ trigger = 'X' }).ok,
                 'remove_action: missing index')
    assert_false(verbs.trigger_remove_action({ trigger = 'X', index = 0 }).ok,
                 'remove_action: zero index')
    assert_false(verbs.trigger_remove_action({ index = 1 }).ok,
                 'remove_action: missing trigger')
    -- Unknown trigger
    local r = verbs.trigger_remove_action({ trigger = 'ghost', index = 1 })
    assert_false(r.ok, 'remove_action: unknown trigger')
end

-- ============================================================
-- trigger_reorder
-- ============================================================

local function test_reorder_to_index()
    reset()
    verbs.trigger_create({ type = 'once', name = 'A' })
    verbs.trigger_create({ type = 'once', name = 'B' })
    verbs.trigger_create({ type = 'once', name = 'C' })
    local r = verbs.trigger_reorder({ name = 'A', to_index = 3 })
    assert_true(r.ok, 'reorder to_index: ok')
    assert_true(r.moved, 'reorder: moved=true')
    local lst = verbs.trigger_list({})
    assert_eq(lst.triggers[1].name, 'B', 'reorder: B is first')
    assert_eq(lst.triggers[3].name, 'A', 'reorder: A is last')
end

local function test_reorder_before_anchor()
    reset()
    verbs.trigger_create({ type = 'once', name = 'A' })
    verbs.trigger_create({ type = 'once', name = 'B' })
    verbs.trigger_create({ type = 'once', name = 'C' })
    local r = verbs.trigger_reorder({ name = 'C', before = 'B' })
    assert_true(r.ok, 'reorder before: ok')
    local lst = verbs.trigger_list({})
    assert_eq(lst.triggers[2].name, 'C', 'reorder before B: C is 2nd')
end

local function test_reorder_after_anchor()
    reset()
    verbs.trigger_create({ type = 'once', name = 'A' })
    verbs.trigger_create({ type = 'once', name = 'B' })
    verbs.trigger_create({ type = 'once', name = 'C' })
    local r = verbs.trigger_reorder({ name = 'A', after = 'B' })
    assert_true(r.ok, 'reorder after: ok')
    local lst = verbs.trigger_list({})
    assert_eq(lst.triggers[2].name, 'A', 'reorder after B: A is 2nd')
end

local function test_reorder_to_start_to_end()
    reset()
    verbs.trigger_create({ type = 'once', name = 'A' })
    verbs.trigger_create({ type = 'once', name = 'B' })
    verbs.trigger_create({ type = 'once', name = 'C' })
    verbs.trigger_reorder({ name = 'C', to_start = true })
    local lst = verbs.trigger_list({})
    assert_eq(lst.triggers[1].name, 'C', 'reorder to_start: C is first')
end

local function test_reorder_self_reference_no_op()
    reset()
    verbs.trigger_create({ type = 'once', name = 'A' })
    verbs.trigger_create({ type = 'once', name = 'B' })
    local r = verbs.trigger_reorder({ name = 'A', before = 'A' })
    assert_true(r.ok, 'reorder self: ok')
    assert_false(r.moved, 'reorder self: moved=false (no-op)')
end

local function test_reorder_arg_validation()
    reset()
    verbs.trigger_create({ type = 'once', name = 'A' })
    verbs.trigger_create({ type = 'once', name = 'B' })
    -- No position flag
    local r1 = verbs.trigger_reorder({ name = 'A' })
    assert_false(r1.ok, 'reorder: missing position flag')
    -- Multiple position flags
    local r2 = verbs.trigger_reorder({ name = 'A', to_index = 1, to_start = true })
    assert_false(r2.ok, 'reorder: multiple position flags')
    -- to_index out of range
    local r3 = verbs.trigger_reorder({ name = 'A', to_index = 99 })
    assert_false(r3.ok, 'reorder: to_index oob')
    -- Unknown anchor
    local r4 = verbs.trigger_reorder({ name = 'A', before = 'ghost' })
    assert_false(r4.ok, 'reorder: unknown anchor')
    -- Unknown trigger
    local r5 = verbs.trigger_reorder({ name = 'ghost', to_start = true })
    assert_false(r5.ok, 'reorder: unknown trigger')
end

-- ============================================================
-- trigger_reorder_condition / action
-- ============================================================

local function test_reorder_condition_happy()
    reset()
    verbs.trigger_create({ type = 'once', name = 'RC1' })
    verbs.trigger_add_condition({ trigger = 'RC1', predicate = 'flag-is-true', fields = { flag = 1 } })
    verbs.trigger_add_condition({ trigger = 'RC1', predicate = 'flag-is-true', fields = { flag = 2 } })
    verbs.trigger_add_condition({ trigger = 'RC1', predicate = 'flag-is-true', fields = { flag = 3 } })
    local r = verbs.trigger_reorder_condition({ trigger = 'RC1', index = 1, to_index = 3 })
    assert_true(r.ok, 'reorder_condition: ok')
    assert_true(r.moved, 'reorder_condition: moved')
end

local function test_reorder_condition_oob()
    reset()
    verbs.trigger_create({ type = 'once', name = 'RC2' })
    verbs.trigger_add_condition({ trigger = 'RC2', predicate = 'flag-is-true', fields = { flag = 1 } })
    local r = verbs.trigger_reorder_condition({ trigger = 'RC2', index = 5, to_index = 1 })
    assert_false(r.ok, 'reorder_condition source oob: refused')
end

local function test_reorder_action_happy()
    reset()
    verbs.trigger_create({ type = 'once', name = 'RA1' })
    verbs.trigger_add_action({ trigger = 'RA1', predicate = 'set-flag', fields = { flag = 1, value = 1 } })
    verbs.trigger_add_action({ trigger = 'RA1', predicate = 'set-flag', fields = { flag = 2, value = 1 } })
    local r = verbs.trigger_reorder_action({ trigger = 'RA1', index = 1, to_end = true })
    assert_true(r.ok, 'reorder_action: ok')
    assert_true(r.moved, 'reorder_action: moved')
end

local function test_reorder_action_oob_source()
    reset()
    verbs.trigger_create({ type = 'once', name = 'RA2' })
    verbs.trigger_add_action({ trigger = 'RA2', predicate = 'set-flag', fields = { flag = 1, value = 1 } })
    local r = verbs.trigger_reorder_action({ trigger = 'RA2', index = 5, to_index = 1 })
    assert_false(r.ok, 'reorder_action source oob: refused')
end

local function test_reorder_action_arg_validation()
    reset()
    verbs.trigger_create({ type = 'once', name = 'RA3' })
    verbs.trigger_add_action({ trigger = 'RA3', predicate = 'set-flag', fields = { flag = 1, value = 1 } })
    verbs.trigger_add_action({ trigger = 'RA3', predicate = 'set-flag', fields = { flag = 2, value = 1 } })
    -- Missing trigger
    assert_false(verbs.trigger_reorder_action({ index = 1, to_start = true }).ok,
                 'reorder_action: missing trigger')
    -- Missing index
    assert_false(verbs.trigger_reorder_action({ trigger = 'RA3', to_start = true }).ok,
                 'reorder_action: missing index')
    -- No position flag
    assert_false(verbs.trigger_reorder_action({ trigger = 'RA3', index = 1 }).ok,
                 'reorder_action: missing position flag')
    -- Multiple position flags
    assert_false(verbs.trigger_reorder_action({
        trigger = 'RA3', index = 1, to_index = 2, to_start = true }).ok,
        'reorder_action: multiple position flags')
end

-- ============================================================
-- Test runner
-- ============================================================

local tests = {
    test_list_predicates_all,
    test_list_predicates_filter_kind,
    test_list_predicates_filter_search,
    test_list_predicates_includes_or_pseudo,
    test_describe_canonical,
    test_describe_alias,
    test_describe_unknown,
    test_describe_continuous_alias_fixed_typo,
    test_describe_arg_validation,
    test_create_happy,
    test_create_default_name,
    test_create_name_collision_uniquifies,
    test_create_arg_validation,
    test_remove_happy,
    test_remove_not_found,
    test_list_happy,
    test_get_happy,
    test_get_not_found,
    test_set_name_happy,
    test_set_name_collision_refused,
    test_set_eventlist_happy,
    test_set_eventlist_clear,
    test_add_condition_simple,
    test_add_condition_unit_ref_resolves_name_to_id,
    test_add_condition_unit_ref_unknown_name,
    test_add_condition_unknown_field,
    test_add_condition_arg_validation,
    test_add_condition_predicate_text_routes_through_dict,
    test_remove_condition_happy,
    test_remove_condition_oob,
    test_add_action_simple,
    test_add_action_text_routes_through_dict,
    test_add_action_do_script_skips_dict,
    test_add_action_group_ref,
    test_remove_action_happy,
    test_remove_action_oob,
    test_remove_action_arg_validation,
    test_reorder_to_index,
    test_reorder_before_anchor,
    test_reorder_after_anchor,
    test_reorder_to_start_to_end,
    test_reorder_self_reference_no_op,
    test_reorder_arg_validation,
    test_reorder_condition_happy,
    test_reorder_condition_oob,
    test_reorder_action_happy,
    test_reorder_action_oob_source,
    test_reorder_action_arg_validation,
}

for _, t in ipairs(tests) do t() end

print(string.format('test_verbs_trigger: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
