-- trigger_schema.lua — ED trigger-descriptor cache + classification.
--
-- Shared by trigger_export.lua / trigger_import.lua. Deliberately
-- DUPLICATES (does not refactor out) the local helpers inside
-- verbs/trigger_verbs.lua (_trigger_build_alias_cache,
-- _trigger_make_alias, _trigger_field_combo_kind): touching the shipped
-- verb file for this feature is avoidable regression risk. If a third
-- consumer appears, fold trigger_verbs onto this module then.
--
-- Constructors:
--   M.new(opts)      — injectable (tests): { rulesDescr, actionsDescr,
--                      triggersDescr, field_kind_fn }
--   M.from_editor()  — live ME: builds from me_predicates/me_trigrules,
--                      with the selector-identity field classifier.
--                      Returns nil outside the editor.
--
-- All methods return nil/'' on bad input; never throw.

local M = {}

local Schema = {}
Schema.__index = Schema

function M.predicate_name(p)
    if type(p) == 'string' then return p end
    if type(p) == 'table' and type(p.name) == 'string' then return p.name end
    return ''
end

function M.make_alias(canonical)
    local s = M.predicate_name(canonical)
    if s == '' then return '' end
    if s:sub(1, 2) == 'c_' or s:sub(1, 2) == 'a_' then
        s = s:sub(3)
    elseif s:sub(1, 7) == 'trigger' then
        s = s:sub(8)
        if s == 'Continious' then return 'continuous' end
    end
    return s:gsub('_', '-'):lower()
end

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({
        field_kind_fn = opts.field_kind_fn,
        -- expose statics on the instance so callers can use one handle
        predicate_name = M.predicate_name,
        make_alias     = M.make_alias,
        field_descr    = M.field_descr,
        field_default  = M.field_default,
    }, Schema)

    local cache = {}
    local function collect(descr, kind)
        if type(descr) == 'table' and type(descr.name) == 'string' then
            local entry = { canonical = descr.name, kind = kind, descr = descr }
            cache[descr.name] = entry
            cache[M.make_alias(descr.name)] = entry
        end
    end
    -- pairs() (not ipairs) on rulesDescr: pseudo-predicates like ["or"]
    -- live under string keys.
    if type(opts.rulesDescr) == 'table' then
        for _, d in pairs(opts.rulesDescr) do collect(d, 'condition') end
    end
    if type(opts.actionsDescr) == 'table' then
        for _, d in ipairs(opts.actionsDescr) do collect(d, 'action') end
    end
    if type(opts.triggersDescr) == 'table' then
        for _, d in ipairs(opts.triggersDescr) do collect(d, 'trigger') end
    end
    self._cache = cache
    return self
end

-- → canonical, kind, descr, err
function Schema:resolve(name_or_alias, expected_kind)
    local entry = self._cache[name_or_alias]
    if not entry then
        return nil, nil, nil, 'unknown predicate "' .. tostring(name_or_alias) .. '"'
    end
    if expected_kind and entry.kind ~= expected_kind then
        return nil, nil, nil, 'predicate "' .. tostring(name_or_alias)
               .. '" is a ' .. entry.kind .. ', expected ' .. expected_kind
    end
    return entry.canonical, entry.kind, entry.descr, nil
end

function M.field_descr(descr, field_id)
    if type(descr) ~= 'table' or type(descr.fields) ~= 'table' then return nil end
    for _, f in ipairs(descr.fields) do
        if type(f) == 'table' and f.id == field_id then return f end
    end
    return nil
end

function M.field_default(descr, field_id)
    local fd = M.field_descr(descr, field_id)
    if type(fd) == 'table' then return fd.default end
    return nil
end

-- → 'group'|'unit'|'zone'|'coalition'|'airdrome'|'event'|'draw'|nil
function Schema:field_kind(field_descr)
    if type(self.field_kind_fn) == 'function' then
        return self.field_kind_fn(field_descr)
    end
    return nil
end

-- Live-editor constructor. The classifier mirrors trigger_verbs'
-- _trigger_field_combo_kind: tier 1 = shared selector-table identity
-- (their comboFunc is module-local and unreachable), tier 2 = exported
-- lister identity.
function M.from_editor()
    local ok_t, Trigger = pcall(require, 'me_trigrules')
    local ok_p, Predicates = pcall(require, 'me_predicates')
    if not (ok_t and ok_p and type(Trigger) == 'table' and type(Predicates) == 'table') then
        return nil
    end

    local function field_kind(fd)
        if type(fd) ~= 'table' or fd.type ~= 'combo' then return nil end
        if fd == Predicates.UNIT_SELECTOR
                or fd == Predicates.VEHICLE_SELECTOR
                or fd == Predicates.AIRCARRIER_SELECTOR then
            return 'unit'
        end
        if fd == Predicates.DRAW_SELECTOR then return 'draw' end
        local fn = fd.comboFunc
        if type(fn) ~= 'function' then return nil end
        if fn == Trigger.groupsLister or fn == Trigger.groupsStaticLister
                or fn == Trigger.groupsAHLister or fn == Trigger.groupsListerS
                or fn == Trigger.groupsVLister or fn == Trigger.groupsVSLister
                or fn == Predicates.groupsLister then
            return 'group'
        end
        if fn == Predicates.zonesLister then return 'zone' end
        if fn == Trigger.coalitionIdToName or fn == Trigger.coalition2IdToName
                or fn == Trigger.winnerLister or fn == Predicates.coalitionIdToName
                or fn == Predicates.coalitionIdToName2 then
            return 'coalition'
        end
        if fn == Trigger.airdromeAndHeliportLister or fn == Predicates.airdromeLister
                or fn == Predicates.helipadLister then
            return 'airdrome'
        end
        if fn == Trigger.eventLister then return 'event' end
        return nil
    end

    return M.new({
        rulesDescr    = Predicates.rulesDescr,
        actionsDescr  = Trigger.actionsDescr,
        triggersDescr = Trigger.triggersDescr,
        field_kind_fn = field_kind,
    })
end

return M
