-- dcs_sms_me/verbs/trigger_verbs.lua — mission.trigrules CRUD + reordering.
--
-- Verbs: trigger_list, trigger_get, trigger_list_predicates,
-- trigger_describe_predicate, trigger_create, trigger_remove,
-- trigger_set_<name|eventlist>, trigger_<add|remove|reorder>_<condition|action>,
-- trigger_reorder.
-- See dcs_sms_me/verbs.lua for the aggregator and the verb-naming convention.

local M = {}

-- Trigger verbs operate against mission.trigrules and ED's predicate
-- descriptors. They don't share any of the helpers in verb_helpers.lua —
-- every helper here is _trigger_*-prefixed and stays local to this file.

-- ============================================================
-- Trigger verbs (mission.trigrules)
-- ============================================================
--
-- mission.trigrules is the editor source-of-truth. Each entry has shape:
--   { predicate = "triggerOnce" | "triggerContinious" | "triggerStart" | "triggerFront",
--     comment   = "<user-facing name>",
--     eventlist = "" | <event id>,
--     rules     = { { predicate = "c_*", ...field args... }, ... },
--     actions   = { { predicate = "a_*", ...field args... }, ... } }
--
-- ED's me_mission.unload regenerates mission.trig.{conditions,actions,func,
-- events,funcStartup} from trigrules at save time (me_mission.lua:4592-4598),
-- so we never touch mission.trig.* directly — only trigrules.

-- _trigger_alias_cache — lazy-built map of every predicate ED knows about,
-- keyed by both canonical name AND friendly kebab-alias. Each value is
-- { canonical=..., kind="condition"|"action"|"trigger", descr=<field-schema> }.
-- Cleared on first call after init; rebuilt only if ED's descriptor tables
-- look like they've shifted (descriptor tables are session-stable in
-- practice — this cache is a perf optimization, not a correctness gate).
local _trigger_alias_cache

-- _trigger_predicate_name — normalize a predicate value to its canonical
-- string name, regardless of whether ED stored it as a string (in-memory
-- after createTrigger / fresh insert) or a descriptor table (loaded from
-- disk by me_mission.load via Trigger.loadTriggers, which expands string
-- names to {name=..., fields=...} entries).
--
-- Returns "" for unrecognized shapes so callers can short-circuit cleanly.
local function _trigger_predicate_name(p)
    if type(p) == 'string' then return p end
    if type(p) == 'table' and type(p.name) == 'string' then return p.name end
    return ''
end

-- _trigger_make_alias — strip prefix + underscore→dash to get the friendly
-- form. "c_flag_is_true" → "flag-is-true", "a_set_flag" → "set-flag",
-- "triggerOnce" → "once", "triggerContinious" → "continuous" (fixes typo).
-- Accepts either a canonical string or a {name=..., fields=...} descriptor
-- table — ED uses both shapes for the predicate field depending on whether
-- the trigger was just created (string) or loaded from disk (table).
local function _trigger_make_alias(canonical)
    local s = _trigger_predicate_name(canonical)
    if s == '' then return '' end
    if s:sub(1, 2) == 'c_' or s:sub(1, 2) == 'a_' then
        s = s:sub(3)
    elseif s:sub(1, 7) == 'trigger' then
        s = s:sub(8)
        -- Special case: ED's misspelling of "Continuous"
        if s == 'Continious' then return 'continuous' end
    end
    return s:gsub('_', '-'):lower()
end

-- _trigger_build_alias_cache — populate _trigger_alias_cache by walking ED's
-- three descriptor arrays: me_predicates.rulesDescr (conditions, c_*),
-- me_trigrules.actionsDescr (actions, a_*), and me_trigrules.triggersDescr
-- (trigger types). actionsDescr and triggersDescr are pure 1-indexed arrays.
-- rulesDescr is mostly a 1-indexed array but ALSO carries pseudo-predicates
-- under string keys (currently just `["or"]` — see me_predicates.lua:1555,
-- "special predicates have individual key"); pairs() picks both up.
local function _trigger_build_alias_cache()
    local Trigger = require('me_trigrules')
    local Predicates = require('me_predicates')
    local cache = {}

    -- Conditions: me_predicates.rulesDescr is mostly { name = "c_*", ...}
    -- entries, plus pseudo-predicates like ["or"] keyed by their literal
    -- name. Walk with pairs() so we pick up both shapes.
    if type(Predicates.rulesDescr) == 'table' then
        for _, descr in pairs(Predicates.rulesDescr) do
            if type(descr) == 'table' and type(descr.name) == 'string' then
                local entry = { canonical = descr.name, kind = 'condition', descr = descr }
                cache[descr.name] = entry
                cache[_trigger_make_alias(descr.name)] = entry
            end
        end
    end

    -- Actions: me_trigrules.actionsDescr is the same shape with "a_*" names.
    if type(Trigger.actionsDescr) == 'table' then
        for _, descr in ipairs(Trigger.actionsDescr) do
            if type(descr) == 'table' and type(descr.name) == 'string' then
                local entry = { canonical = descr.name, kind = 'action', descr = descr }
                cache[descr.name] = entry
                cache[_trigger_make_alias(descr.name)] = entry
            end
        end
    end

    -- Trigger types: me_trigrules.triggersDescr.
    if type(Trigger.triggersDescr) == 'table' then
        for _, descr in ipairs(Trigger.triggersDescr) do
            if type(descr) == 'table' and type(descr.name) == 'string' then
                local entry = { canonical = descr.name, kind = 'trigger', descr = descr }
                cache[descr.name] = entry
                cache[_trigger_make_alias(descr.name)] = entry
            end
        end
    end

    _trigger_alias_cache = cache
end

-- _trigger_resolve_predicate — name-or-alias → canonical_name, kind, descr,
-- err. Optionally filter by kind ("condition" / "action" / "trigger") to
-- disambiguate — passing kind=nil accepts any.
local function _trigger_resolve_predicate(name_or_alias, expected_kind)
    if not _trigger_alias_cache then _trigger_build_alias_cache() end
    local entry = _trigger_alias_cache[name_or_alias]
    if not entry then
        return nil, nil, nil, 'unknown predicate "' .. tostring(name_or_alias) .. '"'
    end
    if expected_kind and entry.kind ~= expected_kind then
        return nil, nil, nil,
               'predicate "' .. name_or_alias .. '" is a ' .. entry.kind
               .. ', expected ' .. expected_kind
    end
    return entry.canonical, entry.kind, entry.descr, nil
end

-- _trigger_panel_refresh — best-effort kick: if the trigger panel is
-- currently visible, rebind its listbox against the current
-- mission.trigrules.
--
-- We do NOT call Trigger.show(true) for this. show(true) calls
-- ED's fixTriggers() which DELETES any trigger with #actions < 1
-- (see me_trigrules.lua: function fixTriggers — invalid trigger
-- removed). Freshly-created triggers from `trigger create` have
-- empty actions by design (the user fills them in via subsequent
-- `trigger action ...` verbs), so show(true) silently wipes them
-- before the listbox is rebound. Same reason show(false) was bad:
-- it leads back into the same purge path on close-then-reopen.
--
-- Instead we go straight to predicates.rulesToList(window.triggersList,
-- mission.trigrules, cdata) — that's the same listbox-rebind helper
-- ED itself uses elsewhere (e.g. the trigger-reorder buttons), and
-- it has no fixTriggers / no data mutation. It just clears the
-- listbox and re-adds an item per entry in mission.trigrules.
local function _trigger_panel_refresh()
    local ok_t, Trigger = pcall(require, 'me_trigrules')
    if not ok_t or type(Trigger) ~= 'table' then return end
    local visible = false
    if type(Trigger.triggersWindow) == 'table' and type(Trigger.triggersWindow.isVisible) == 'function' then
        local ok_vis, vis = pcall(Trigger.triggersWindow.isVisible, Trigger.triggersWindow)
        visible = ok_vis and vis == true
    end
    if not visible then return end

    local ok_p, predicates = pcall(require, 'me_predicates')
    if not ok_p or type(predicates) ~= 'table'
       or type(predicates.rulesToList) ~= 'function' then return end

    local box = Trigger.triggersWindow.Box
    if type(box) ~= 'table' or type(box.triggersList) ~= 'table' then return end

    local ok_m, Mission = pcall(require, 'me_mission')
    if not ok_m or type(Mission) ~= 'table'
       or type(Mission.mission) ~= 'table' then return end
    local trigrules = Mission.mission.trigrules or {}

    -- cdata is module-local in me_trigrules; fall back to nil — rulesToList
    -- only uses cdata for predicate-text rendering and tolerates nil.
    local cdata = Trigger.cdata
    pcall(predicates.rulesToList, box.triggersList, trigrules, cdata)
end

-- _trigger_find_by_name — locate a trigger in mission.trigrules by its
-- comment field. Returns trigger, index_1based, total_count or nil.
local function _trigger_find_by_name(name)
    local Mission = require('me_mission')
    local mission = Mission.mission
    if type(mission) ~= 'table' or type(mission.trigrules) ~= 'table' then
        return nil, nil, 0
    end
    for i, t in ipairs(mission.trigrules) do
        if type(t) == 'table' and t.comment == name then
            return t, i, #mission.trigrules
        end
    end
    return nil, nil, #mission.trigrules
end

-- _trigger_unique_name — auto-suffix "-2", "-3", ... on collision (matches
-- the existing me group create-* collision behavior).
local function _trigger_unique_name(base)
    if not _trigger_find_by_name(base) then return base end
    local n = 2
    while _trigger_find_by_name(base .. '-' .. n) do n = n + 1 end
    return base .. '-' .. n
end

-- _trigger_default_name — ED's default when the user hits "new trigger" in
-- the panel: "Trigger " .. os.time(). We mirror it for parity.
local function _trigger_default_name()
    return 'Trigger ' .. tostring(os.time())
end

-- _trigger_field_combo_kind — classify a field's reference kind by its
-- comboFunc slot, with a fallback by descriptor-table identity. Returns
-- "group" / "unit" / "zone" / "coalition" / "airdrome" / "event" / "draw"
-- / nil (literal field, no resolution).
--
-- Two-tier detection:
--   1. If the field IS one of the shared selector tables exported by
--      me_predicates (UNIT_SELECTOR / VEHICLE_SELECTOR / AIRCARRIER_SELECTOR
--      / DRAW_SELECTOR), classify by table identity. This is required
--      because their comboFunc (unitsLister, drawObjectsLister, ...) is
--      LOCAL in me_predicates.lua and can't be reached from outside the
--      module — so the comboFunc-based check below would silently miss
--      them, leaving entry.<field> as the unresolved name string instead
--      of the numeric id the panel/save expect (issue #45).
--   2. Otherwise compare comboFunc against the listers that ARE exported.
local function _trigger_field_combo_kind(field_descr)
    if type(field_descr) ~= 'table' or field_descr.type ~= 'combo' then
        return nil
    end

    local Trigger = require('me_trigrules')
    local Predicates = require('me_predicates')

    -- Tier 1: shared selector descriptors. The predicate's `fields` array
    -- references these tables BY VALUE (e.g. me_predicates rulesDescr has
    -- `fields = { UNIT_SELECTOR, ... }`), so identity comparison is
    -- reliable.
    if field_descr == Predicates.UNIT_SELECTOR
            or field_descr == Predicates.VEHICLE_SELECTOR
            or field_descr == Predicates.AIRCARRIER_SELECTOR then
        return 'unit'
    end
    if field_descr == Predicates.DRAW_SELECTOR then
        return 'draw'
    end

    -- Tier 2: comboFunc identity. Most listers are exported on the module
    -- table; the few that aren't (unitsLister and friends) are handled by
    -- tier 1 above.
    local fn = field_descr.comboFunc
    if type(fn) ~= 'function' then return nil end

    -- Group references — multiple variants (generic, static, air-helicopter,
    -- vehicle, vehicle-static, etc) all classify as "group".
    if fn == Trigger.groupsLister
            or fn == Trigger.groupsStaticLister
            or fn == Trigger.groupsAHLister
            or fn == Trigger.groupsListerS
            or fn == Trigger.groupsVLister
            or fn == Trigger.groupsVSLister
            or fn == Predicates.groupsLister then
        return 'group'
    end

    -- Zone references.
    if fn == Predicates.zonesLister then return 'zone' end

    -- Coalition references.
    if fn == Trigger.coalitionIdToName
            or fn == Trigger.coalition2IdToName
            or fn == Trigger.winnerLister
            or fn == Predicates.coalitionIdToName
            or fn == Predicates.coalitionIdToName2 then
        return 'coalition'
    end

    -- Airdrome / helipad references.
    if fn == Trigger.airdromeAndHeliportLister
            or fn == Predicates.airdromeLister
            or fn == Predicates.helipadLister then
        return 'airdrome'
    end

    -- Event references.
    if fn == Trigger.eventLister then return 'event' end

    return nil
end

-- _trigger_resolve_ref — value normalization for reference fields. If kind
-- is group/unit/zone, accept either an integer id or a name (string) and
-- return the integer id. For coalition, pass through. For other kinds,
-- pass through. Returns resolved_value, err.
local function _trigger_resolve_ref(kind, value)
    -- 'draw' targets are draw-object names (strings); the panel's combo
    -- stores them as-is, so no name→id resolution is needed.
    if kind == 'coalition' or kind == 'event' or kind == 'draw' or kind == nil then
        return value, nil
    end
    -- integer-or-numeric-string → treat as id
    local as_num = tonumber(value)
    if as_num and as_num == math.floor(as_num) then
        return as_num, nil
    end
    if type(value) ~= 'string' then
        return nil, 'expected integer or name string for ' .. kind .. ' reference'
    end
    if kind == 'group' then
        local Mission = require('me_mission')
        local g = Mission.group_by_name and Mission.group_by_name[value]
        if g then return g.groupId, nil end
        return nil, 'no group named "' .. value .. '"'
    elseif kind == 'unit' then
        local Mission = require('me_mission')
        local u = Mission.unit_by_name and Mission.unit_by_name[value]
        if u then return u.unitId, nil end
        return nil, 'no unit named "' .. value .. '"'
    elseif kind == 'zone' then
        -- Trigger zones don't live in mission.triggers.zones at runtime —
        -- they're held by the Mission.TriggerZoneData controller, which
        -- exposes ids + a name lookup but no by-name index. Iterate ids
        -- and match (same pattern as zone_verbs' find_zone).
        local ok_tzd, TZD = pcall(require, 'Mission.TriggerZoneData')
        if ok_tzd and type(TZD) == 'table'
                and type(TZD.getTriggerZoneIds) == 'function'
                and type(TZD.getTriggerZoneName) == 'function' then
            for _, zid in ipairs(TZD.getTriggerZoneIds() or {}) do
                if TZD.getTriggerZoneName(zid) == value then return zid, nil end
            end
        end
        return nil, 'no zone named "' .. value .. '"'
    elseif kind == 'airdrome' then
        return nil, 'airdrome reference by name not supported in v1; pass integer id'
    end
    return value, nil
end

-- _trigger_coerce_value — string from CLI → typed Lua value per descriptor.
-- For "edit" fields the descriptor may not say what the type should be, so
-- we infer: "true"/"false" → bool, parseable → number, else string. Array
-- values use comma-separated form (descriptor signals via field.type or
-- by the field having a known multi-int shape like typebomb/typemissile).
local function _trigger_coerce_value(field_descr, value)
    if type(field_descr) ~= 'table' then return value end
    -- known array-of-int fields per ED's trigger schema
    local id = field_descr.id
    if id == 'typebomb' or id == 'typemissile' or id == 'typemlrs' then
        local out = {}
        for piece in tostring(value):gmatch('[^,]+') do
            local n = tonumber(piece)
            if not n then return nil end
            table.insert(out, n)
        end
        return out
    end
    if value == 'true' then return true end
    if value == 'false' then return false end
    local n = tonumber(value)
    if n ~= nil then return n end
    return tostring(value)
end

-- _trigger_field_descr — find a single field descriptor by id within a
-- predicate's descr.fields list (or descr.fields under triggersDescr).
local function _trigger_field_descr(descr, field_id)
    if type(descr) ~= 'table' or type(descr.fields) ~= 'table' then return nil end
    for _, f in ipairs(descr.fields) do
        if type(f) == 'table' and f.id == field_id then return f end
    end
    return nil
end

-- _trigger_apply_fields — walk the user-supplied fields table, validate
-- each against descr, coerce types, resolve references, allocate dict
-- keys for action text/comment/radiotext fields. Mutates entry in place.
-- Returns ok, err.
--
-- kind: "condition" | "action" | "trigger" | nil — needed because action
--       text/comment/radiotext fields go through dictionary.fixDict to
--       allocate a DictKey_* reference. Other kinds store literals.
-- predicate_canonical: the canonical c_*/a_*/trigger* name — needed for
--       the a_do_script special case (its `text` field is a raw script,
--       not a dict-keyed message).
local function _trigger_apply_fields(entry, descr, fields, kind, predicate_canonical)
    if type(fields) ~= 'table' then return true, nil end
    local ok_dict, dictionary = pcall(require, 'dictionary')

    -- Map of action-side fields that go through DictKey allocation.
    -- Source: me_trigrules.saveTriggers (lines ~3902-3914) and me_predicates.
    -- actionToString — these are the only action fields ED's serializer
    -- routes through textToMis at save time.
    local ACTION_DICT_FIELDS = {
        text       = 'ActionText',
        radiotext  = 'ActionRadioText',
        comment    = 'ActionComment',
    }

    for k, v in pairs(fields) do
        local fd = _trigger_field_descr(descr, k)
        if not fd then
            return false, 'unknown field "' .. tostring(k) .. '" for predicate "'
                          .. tostring(descr and descr.name or '?') .. '"'
        end
        local coerced = _trigger_coerce_value(fd, v)
        if coerced == nil then
            return false, 'invalid value for field "' .. tostring(k) .. '"'
        end
        local refkind = _trigger_field_combo_kind(fd)
        local resolved, ref_err = _trigger_resolve_ref(refkind, coerced)
        if ref_err then return false, ref_err end

        -- Decide: literal write, or DictKey allocation via fixDict?
        local dict_comment = nil
        if kind == 'action' and ACTION_DICT_FIELDS[k] then
            -- a_do_script's `text` is a literal Lua script, not a dict-keyed
            -- message — ED skips textToMis for it (me_trigrules.lua:3908).
            if not (k == 'text' and predicate_canonical == 'a_do_script') then
                dict_comment = ACTION_DICT_FIELDS[k]
            end
        end

        if dict_comment and type(resolved) == 'string'
                and resolved:sub(1, 8) ~= 'DictKey_' and ok_dict
                and type(dictionary.fixDict) == 'function' then
            -- fixDict: allocate DictKey_<dict_comment>_<num>, store value in
            -- dictionary['DEFAULT'][key], then write both entry[k] = literal
            -- and entry["KeyDict_"..k] = key. ED's saveTriggers will read
            -- KeyDict_<k> at save time and call textToMis to round-trip.
            pcall(dictionary.fixDict, entry, k, resolved, dict_comment)
        else
            entry[k] = resolved
        end
    end
    return true, nil
end

-- _trigger_resolve_for_get — reverse of fixDict: given an entry from a
-- trigrules trigger / rule / action, return a flat fields table with
-- DictKey_* references resolved back to literal strings, and reference
-- ids accompanied by *_name fields where resolvable. Skips the
-- KeyDict_* companions (they're internal indirection). If raw=true,
-- returns the entry verbatim instead.
local function _trigger_resolve_for_get(entry, descr, raw)
    local out = {}
    if type(entry) ~= 'table' then return out end
    if raw then
        for k, v in pairs(entry) do out[k] = v end
        return out
    end
    local ok_dict, dictionary = pcall(require, 'dictionary')
    for k, v in pairs(entry) do
        if k == 'predicate' then
            -- skip — emitted separately at the caller's level
        elseif k:sub(1, 8) == 'KeyDict_' then
            -- skip companion
        elseif type(v) == 'string' and v:sub(1, 8) == 'DictKey_'
                and ok_dict and type(dictionary.getValueDict) == 'function' then
            local literal = dictionary.getValueDict(v)
            out[k] = literal or v
        else
            out[k] = v
            -- enrichment for reference fields
            local fd = _trigger_field_descr(descr, k)
            local kind = fd and _trigger_field_combo_kind(fd)
            if kind == 'group' and type(v) == 'number' then
                local Mission = require('me_mission')
                if Mission.group_by_id and Mission.group_by_id[v] then
                    out[k .. '_name'] = Mission.group_by_id[v].name
                end
            elseif kind == 'unit' and type(v) == 'number' then
                local Mission = require('me_mission')
                if Mission.unit_by_id and Mission.unit_by_id[v] then
                    out[k .. '_name'] = Mission.unit_by_id[v].name
                end
            elseif kind == 'zone' and type(v) == 'number' then
                -- Same as _trigger_resolve_ref: zones live in TriggerZoneData
                -- at runtime, not mission.triggers.zones.
                local ok_tzd, TZD = pcall(require, 'Mission.TriggerZoneData')
                if ok_tzd and type(TZD) == 'table'
                        and type(TZD.getTriggerZoneName) == 'function' then
                    local n = TZD.getTriggerZoneName(v)
                    if n then out[k .. '_name'] = n end
                end
            end
        end
    end
    return out
end

-- _trigger_ensure_trigrules — make sure mission.trigrules exists; create
-- an empty array if not. Mirrors ED's me_trigrules.show() init guard.
local function _trigger_ensure_trigrules()
    local Mission = require('me_mission')
    local mission = Mission.mission
    if type(mission) ~= 'table' then return nil, 'no mission loaded' end
    if type(mission.trigrules) ~= 'table' then mission.trigrules = {} end
    return mission.trigrules, nil
end

-- _trigger_friendly_type — canonical "triggerOnce" / "triggerContinious" /
-- ... → friendly alias ("once" / "continuous" / ...).
local function _trigger_friendly_type(canonical)
    return _trigger_make_alias(canonical or '')
end

-- trigger_list — compact list of every trigger in mission.trigrules.
-- Returns one row per trigger: {name, type, conditions, actions, eventlist}.
function M.trigger_list(args)
    local trigrules, err = _trigger_ensure_trigrules()
    if not trigrules then return { ok = false, error = err } end
    local out = {}
    for _, t in ipairs(trigrules) do
        if type(t) == 'table' then
            table.insert(out, {
                name       = t.comment or '',
                type       = _trigger_friendly_type(t.predicate),
                conditions = (type(t.rules)   == 'table') and #t.rules   or 0,
                actions    = (type(t.actions) == 'table') and #t.actions or 0,
                eventlist  = t.eventlist or '',
            })
        end
    end
    return { ok = true, count = #out, triggers = out }
end

-- trigger_get — full trigger detail. Resolves DictKey_* references to
-- literal text and enriches reference ids with their *_name companion
-- (group_name, unit_name, zone_name). args.raw=true returns the
-- on-disk trigrules entry verbatim for debugging.
function M.trigger_get(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'trigger_get requires args.name (string)' }
    end
    local raw = args.raw == true
    local _, err = _trigger_ensure_trigrules()
    if err then return { ok = false, error = err } end
    local t, idx = _trigger_find_by_name(args.name)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.name .. '"' }
    end
    if raw then
        return { ok = true, name = args.name, index = idx, trigger = t }
    end

    local conditions = {}
    if type(t.rules) == 'table' then
        for i, r in ipairs(t.rules) do
            local pname = _trigger_predicate_name(r.predicate)
            local _, _, descr = _trigger_resolve_predicate(pname)
            local fields = _trigger_resolve_for_get(r, descr, false)
            fields.predicate = nil  -- don't double-emit
            table.insert(conditions, {
                index     = i,
                predicate = pname,
                alias     = _trigger_make_alias(r.predicate),
                fields    = fields,
            })
        end
    end

    local actions = {}
    if type(t.actions) == 'table' then
        for i, a in ipairs(t.actions) do
            local pname = _trigger_predicate_name(a.predicate)
            local _, _, descr = _trigger_resolve_predicate(pname)
            local fields = _trigger_resolve_for_get(a, descr, false)
            fields.predicate = nil
            table.insert(actions, {
                index     = i,
                predicate = pname,
                alias     = _trigger_make_alias(a.predicate),
                fields    = fields,
            })
        end
    end

    return {
        ok         = true,
        name       = t.comment or '',
        type       = _trigger_friendly_type(t.predicate),
        eventlist  = t.eventlist or '',
        conditions = conditions,
        actions    = actions,
    }
end

-- _trigger_descr_to_field_dump — flatten a descr.fields list to a dump
-- shape suitable for JSON: array of {id, type, default, kind?}.
local function _trigger_descr_to_field_dump(descr)
    local out = {}
    if type(descr) ~= 'table' or type(descr.fields) ~= 'table' then return out end
    for _, f in ipairs(descr.fields) do
        if type(f) == 'table' and type(f.id) == 'string' then
            local entry = { id = f.id, type = f.type or 'edit' }
            if f.default ~= nil then entry.default = f.default end
            local refkind = _trigger_field_combo_kind(f)
            if refkind then entry.refkind = refkind end
            table.insert(out, entry)
        end
    end
    return out
end

-- _trigger_predicate_example — generate the CLI invocation string for a
-- predicate. Used in the dump to show agents how to invoke it.
local function _trigger_predicate_example(canonical, alias, kind, descr)
    local parts = {}
    if kind == 'condition' or kind == 'action' then
        table.insert(parts, 'me trigger add-' .. kind .. ' --trigger T --predicate ' .. alias)
    elseif kind == 'trigger' then
        table.insert(parts, 'me trigger create --type ' .. alias .. ' --name N')
    else
        return ''
    end
    -- Suggest one example pair per known field (skip KeyDict_* internal
    -- companions; user only sees the literal field).
    if type(descr) == 'table' and type(descr.fields) == 'table' then
        for _, f in ipairs(descr.fields) do
            if type(f) == 'table' and type(f.id) == 'string'
                    and f.id:sub(1, 8) ~= 'KeyDict_' and f.id ~= 'comment' then
                local val = '<' .. f.id .. '>'
                table.insert(parts, f.id .. '=' .. val)
                break  -- one suggestion is enough; full list is in `fields`.
            end
        end
    end
    return table.concat(parts, ' ')
end

-- trigger_list_predicates — dump every predicate ED knows about, optionally
-- filtered by kind ("condition" / "action" / "trigger") and/or substring.
-- Each entry: {name, alias, kind, display, fields=[...], example=...}.
function M.trigger_list_predicates(args)
    args = args or {}
    if not _trigger_alias_cache then _trigger_build_alias_cache() end
    local kind_filter = (type(args.kind) == 'string' and args.kind ~= '') and args.kind or nil
    local search = (type(args.search) == 'string' and args.search ~= '') and string.lower(args.search) or nil

    -- Walk only canonical names (the cache keys both canonical and alias to
    -- the same entry; we deduplicate by the canonical we walk).
    local Trigger = require('me_trigrules')
    local Predicates = require('me_predicates')
    local seen = {}
    local out = {}

    local function collect(name, kind)
        if seen[name] then return end
        seen[name] = true
        local entry = _trigger_alias_cache[name]
        if not entry then return end
        if kind_filter and entry.kind ~= kind_filter then return end
        local alias = _trigger_make_alias(name)
        if search and not (string.lower(name):find(search, 1, true)
                          or alias:find(search, 1, true)) then
            return
        end
        local display = ''
        if type(entry.descr) == 'table' and type(entry.descr.display) == 'string' then
            display = entry.descr.display
        end
        table.insert(out, {
            name    = name,
            alias   = alias,
            kind    = entry.kind,
            display = display,
            fields  = _trigger_descr_to_field_dump(entry.descr),
            example = _trigger_predicate_example(name, alias, entry.kind, entry.descr),
        })
    end

    if type(Predicates.rulesDescr) == 'table' then
        -- pairs() (not ipairs) so pseudo-predicates under string keys
        -- (currently just ["or"]) are surfaced too.
        for _, descr in pairs(Predicates.rulesDescr) do
            if type(descr) == 'table' and type(descr.name) == 'string' then
                collect(descr.name)
            end
        end
    end
    if type(Trigger.actionsDescr) == 'table' then
        for _, descr in ipairs(Trigger.actionsDescr) do
            if type(descr) == 'table' and type(descr.name) == 'string' then
                collect(descr.name)
            end
        end
    end
    if type(Trigger.triggersDescr) == 'table' then
        for _, td in ipairs(Trigger.triggersDescr) do
            if type(td) == 'table' and type(td.name) == 'string' then collect(td.name) end
        end
    end

    table.sort(out, function(a, b) return a.name < b.name end)
    return { ok = true, count = #out, predicates = out }
end

-- trigger_describe_predicate — single-predicate spec. Same shape as one
-- entry from trigger_list_predicates. Accepts canonical or alias name.
function M.trigger_describe_predicate(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'trigger_describe_predicate requires args.name (string)' }
    end
    local canonical, kind, descr, err = _trigger_resolve_predicate(args.name)
    if err then return { ok = false, error = err } end
    local display = ''
    if type(descr) == 'table' and type(descr.display) == 'string' then
        display = descr.display
    end
    local alias = _trigger_make_alias(canonical)
    return {
        ok      = true,
        name    = canonical,
        alias   = alias,
        kind    = kind,
        display = display,
        fields  = _trigger_descr_to_field_dump(descr),
        example = _trigger_predicate_example(canonical, alias, kind, descr),
    }
end

-- trigger_create — insert a new trigger of the given type. Name defaults
-- to ED's "Trigger <epoch>" pattern with auto-suffix on collision.
-- Bundled rules/actions are added by the caller via repeated calls to
-- trigger_add_condition / trigger_add_action — that composition lives at
-- the CLI layer (see me_trigger_create.go).
function M.trigger_create(args)
    args = args or {}
    local type_arg = args['type']
    if type(type_arg) ~= 'string' or type_arg == '' then
        return { ok = false, error = 'trigger_create requires args.type (once|continuous|start|front)' }
    end
    local canonical, kind, descr, err = _trigger_resolve_predicate(type_arg, 'trigger')
    if err then return { ok = false, error = 'trigger_create: ' .. err } end

    local trigrules, terr = _trigger_ensure_trigrules()
    if not trigrules then return { ok = false, error = terr } end

    -- Build the trigger via ED's createTrigger to inherit field defaults.
    local Trigger = require('me_trigrules')
    if type(Trigger.createTrigger) ~= 'function' then
        return { ok = false, error = 'me_trigrules.createTrigger unavailable' }
    end
    local ok_call, new_trigger = pcall(Trigger.createTrigger, descr)
    if not ok_call or type(new_trigger) ~= 'table' then
        return { ok = false, error = 'createTrigger failed: ' .. tostring(new_trigger) }
    end

    -- Override the auto-generated comment with the user's name (or its
    -- collision-resolved equivalent).
    local desired_name = (type(args.name) == 'string' and args.name ~= '')
                        and args.name or _trigger_default_name()
    new_trigger.comment = _trigger_unique_name(desired_name)

    -- DO NOT overwrite new_trigger.predicate. ED's createTrigger sets
    -- new_trigger.predicate = descr (the descriptor TABLE {name=..., fields=...}).
    -- ED's saveTriggers reads .predicate.name to serialize, so replacing the
    -- table with a canonical string would silently drop the trigger on save.

    table.insert(trigrules, new_trigger)
    _trigger_panel_refresh()

    return {
        ok    = true,
        name  = new_trigger.comment,
        type  = _trigger_friendly_type(canonical),
        index = #trigrules,
    }
end

-- trigger_remove — delete a trigger by name. Refuses on missing trigger.
function M.trigger_remove(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'trigger_remove requires args.name (string)' }
    end
    local trigrules, err = _trigger_ensure_trigrules()
    if not trigrules then return { ok = false, error = err } end
    local _, idx = _trigger_find_by_name(args.name)
    if not idx then
        return { ok = false, error = 'no trigger named "' .. args.name .. '"' }
    end
    table.remove(trigrules, idx)
    _trigger_panel_refresh()
    return { ok = true, name = args.name, removed_index = idx, count = #trigrules }
end

-- trigger_set_name — rename a trigger (mutate the comment field).
-- Refuses if the new name collides with another existing trigger.
function M.trigger_set_name(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'trigger_set_name requires args.name (current name, string)' }
    end
    if type(args.to) ~= 'string' or args.to == '' then
        return { ok = false, error = 'trigger_set_name requires args.to (new name, string)' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end
    local t = _trigger_find_by_name(args.name)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.name .. '"' }
    end
    if args.to ~= args.name then
        local existing = _trigger_find_by_name(args.to)
        if existing then
            return { ok = false, error = 'a trigger named "' .. args.to .. '" already exists' }
        end
    end
    t.comment = args.to
    _trigger_panel_refresh()
    return { ok = true, name = args.to, previous_name = args.name }
end

-- trigger_set_eventlist — set or clear the event filter on a trigger.
-- args.event is the event id (string from ED's eventLister) or empty
-- string to clear.
function M.trigger_set_eventlist(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'trigger_set_eventlist requires args.name' }
    end
    if args.event ~= nil and type(args.event) ~= 'string' then
        return { ok = false, error = 'trigger_set_eventlist requires args.event (string or nil)' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end
    local t = _trigger_find_by_name(args.name)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.name .. '"' }
    end
    t.eventlist = args.event or ''
    _trigger_panel_refresh()
    return { ok = true, name = args.name, eventlist = t.eventlist }
end

-- _trigger_build_rule_or_action — internal: build a {predicate=..., ...}
-- entry from a user-supplied predicate name + fields, validating against
-- the descriptor and applying type coercion / reference resolution / dict
-- key allocation. Returns entry, err.
local function _trigger_build_rule_or_action(predicate_name, fields, expected_kind)
    local canonical, kind, descr, err = _trigger_resolve_predicate(predicate_name, expected_kind)
    if err then return nil, err end

    -- Use the right ED factory based on kind to inherit field defaults:
    --   condition → me_predicates.createRule(descr)
    --   action    → me_trigrules.createAction(descr)
    -- If the factory is unavailable or returns an unexpected shape, fall
    -- back to a minimal {predicate=canonical}.
    local Trigger = require('me_trigrules')
    local entry = nil
    if kind == 'condition' then
        local Predicates = require('me_predicates')
        if type(Predicates.createRule) == 'function' then
            local ok, built = pcall(Predicates.createRule, descr)
            if ok and type(built) == 'table' then entry = built end
        end
    elseif kind == 'action' then
        if type(Trigger.createAction) == 'function' then
            local ok, built = pcall(Trigger.createAction, descr)
            if ok and type(built) == 'table' then entry = built end
        end
    end
    if entry == nil then
        -- Fallback path only: factories returned nothing usable, so we
        -- synthesize a minimal entry. Use the descriptor table shape that
        -- ED's saveTriggers expects (it reads .predicate.name) so the
        -- entry survives a save round-trip.
        entry = { predicate = descr }
    end
    -- DO NOT overwrite entry.predicate when the factory built it.
    -- createRule / createAction set entry.predicate = descr (the descriptor
    -- TABLE), which is what ED's saveTriggers reads .name from at save time.
    -- Replacing the table with a canonical string drops the entry on save.

    local ok_apply, apply_err = _trigger_apply_fields(entry, descr, fields, kind, canonical)
    if not ok_apply then return nil, apply_err end
    return entry, nil
end

-- trigger_add_condition — append a condition entry to trigger.rules.
function M.trigger_add_condition(args)
    if type(args) ~= 'table' or type(args.trigger) ~= 'string' or args.trigger == '' then
        return { ok = false, error = 'trigger_add_condition requires args.trigger (name)' }
    end
    if type(args.predicate) ~= 'string' or args.predicate == '' then
        return { ok = false, error = 'trigger_add_condition requires args.predicate' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end
    local t = _trigger_find_by_name(args.trigger)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.trigger .. '"' }
    end
    if type(t.rules) ~= 'table' then t.rules = {} end

    local entry, err = _trigger_build_rule_or_action(args.predicate, args.fields, 'condition')
    if not entry then return { ok = false, error = 'trigger_add_condition: ' .. err } end

    table.insert(t.rules, entry)
    _trigger_panel_refresh()
    return {
        ok        = true,
        trigger   = args.trigger,
        predicate = _trigger_predicate_name(entry.predicate),
        index     = #t.rules,
    }
end

-- trigger_add_action — append an action entry to trigger.actions.
function M.trigger_add_action(args)
    if type(args) ~= 'table' or type(args.trigger) ~= 'string' or args.trigger == '' then
        return { ok = false, error = 'trigger_add_action requires args.trigger (name)' }
    end
    if type(args.predicate) ~= 'string' or args.predicate == '' then
        return { ok = false, error = 'trigger_add_action requires args.predicate' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end
    local t = _trigger_find_by_name(args.trigger)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.trigger .. '"' }
    end
    if type(t.actions) ~= 'table' then t.actions = {} end

    local entry, err = _trigger_build_rule_or_action(args.predicate, args.fields, 'action')
    if not entry then return { ok = false, error = 'trigger_add_action: ' .. err } end

    table.insert(t.actions, entry)
    _trigger_panel_refresh()
    return {
        ok        = true,
        trigger   = args.trigger,
        predicate = _trigger_predicate_name(entry.predicate),
        index     = #t.actions,
    }
end

-- trigger_remove_condition — remove the rule at index N (1-based).
function M.trigger_remove_condition(args)
    if type(args) ~= 'table' or type(args.trigger) ~= 'string' or args.trigger == '' then
        return { ok = false, error = 'trigger_remove_condition requires args.trigger (name)' }
    end
    if type(args.index) ~= 'number' or args.index < 1 then
        return { ok = false, error = 'trigger_remove_condition requires args.index (1-based)' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end
    local t = _trigger_find_by_name(args.trigger)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.trigger .. '"' }
    end
    if type(t.rules) ~= 'table' or args.index > #t.rules then
        return { ok = false,
                 error = 'trigger has only ' .. (type(t.rules) == 'table' and #t.rules or 0)
                         .. ' conditions; cannot remove index ' .. args.index }
    end
    table.remove(t.rules, args.index)
    _trigger_panel_refresh()
    return { ok = true, trigger = args.trigger,
             removed_index = args.index, remaining = #t.rules }
end

-- trigger_remove_action — remove the action at index N (1-based).
function M.trigger_remove_action(args)
    if type(args) ~= 'table' or type(args.trigger) ~= 'string' or args.trigger == '' then
        return { ok = false, error = 'trigger_remove_action requires args.trigger (name)' }
    end
    if type(args.index) ~= 'number' or args.index < 1 then
        return { ok = false, error = 'trigger_remove_action requires args.index (1-based)' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end
    local t = _trigger_find_by_name(args.trigger)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.trigger .. '"' }
    end
    if type(t.actions) ~= 'table' or args.index > #t.actions then
        return { ok = false,
                 error = 'trigger has only ' .. (type(t.actions) == 'table' and #t.actions or 0)
                         .. ' actions; cannot remove index ' .. args.index }
    end
    table.remove(t.actions, args.index)
    _trigger_panel_refresh()
    return { ok = true, trigger = args.trigger,
             removed_index = args.index, remaining = #t.actions }
end

-- _reorder_resolve_target — turn a position-flag args table into a final
-- 1-based target index, computed against the post-removal list.
--
-- Returns target_idx, err. If err is non-nil, caller should propagate.
--
-- Args expected:
--   list           — the array we'll be reordering inside (read-only here)
--   from_idx       — 1-based source position in `list` (already validated)
--   args           — the user-supplied args table; reads:
--                      args.to_index   (number, 1-based final position)
--                      args.before     (anchor reference: name OR index)
--                      args.after      (anchor reference: name OR index)
--                      args.to_start   (boolean — sugar for to_index = 1)
--                      args.to_end     (boolean — sugar for to_index = #list)
--   find_ref_idx   — function(list, ref) → idx | nil, err
--                    Resolves the --before / --after anchor reference to a
--                    1-based index in `list`. For triggers, the impl looks
--                    up by name (t.comment); for conditions/actions, the
--                    impl validates the ref is a number in 1..#list.
--
-- Validates exactly-one-position-flag and self-reference. Self-reference
-- (--before/--after pointing at the source itself) collapses to a no-op
-- target (target == from_idx) so the caller's no-op short-circuit
-- handles it without a separate code path.
local function _reorder_resolve_target(list, from_idx, args, find_ref_idx)
    -- Count position flags. Exactly one must be set.
    local set = {}
    if args.to_index ~= nil then table.insert(set, '--to-index') end
    if args.before   ~= nil then table.insert(set, '--before')   end
    if args.after    ~= nil then table.insert(set, '--after')    end
    if args.to_start == true then table.insert(set, '--to-start') end
    if args.to_end   == true then table.insert(set, '--to-end')   end
    if #set ~= 1 then
        return nil, 'exactly one of --to-index / --before / --after / '
                    .. '--to-start / --to-end is required'
    end

    local n = #list

    if args.to_start == true then
        return 1, nil
    end
    if args.to_end == true then
        return n, nil
    end
    if args.to_index ~= nil then
        if type(args.to_index) ~= 'number' then
            return nil, '--to-index must be a number'
        end
        if args.to_index < 1 or args.to_index > n then
            return nil, '--to-index must be in 1..' .. n
                        .. ' (got ' .. tostring(args.to_index) .. ')'
        end
        return args.to_index, nil
    end

    -- --before / --after: resolve the anchor's index, then translate to a
    -- post-removal slot.
    local ref = args.before ~= nil and args.before or args.after
    local x_idx, ref_err = find_ref_idx(list, ref)
    if ref_err then return nil, ref_err end
    if not x_idx then
        return nil, 'reference not found: ' .. tostring(ref)
    end

    -- Self-reference → return from_idx so caller's no-op short-circuit
    -- handles it. (--before/--after pointing at the source is a logical
    -- no-op — same as --to-index <where-source-is>.)
    if x_idx == from_idx then
        return from_idx, nil
    end

    -- After removing source, items above from_idx shift down by 1.
    local x_post_removal = (x_idx > from_idx) and (x_idx - 1) or x_idx
    if args.before ~= nil then
        return x_post_removal, nil
    else
        return x_post_removal + 1, nil
    end
end

-- _reorder_apply — table.remove + table.insert. Caller must have already
-- short-circuited the from_idx == target_idx case.
local function _reorder_apply(list, from_idx, target_idx)
    local item = table.remove(list, from_idx)
    table.insert(list, target_idx, item)
end

-- trigger_reorder — move a trigger to a new 1-based position in
-- mission.trigrules.
function M.trigger_reorder(args)
    if type(args) ~= 'table' or type(args.name) ~= 'string' or args.name == '' then
        return { ok = false, error = 'trigger_reorder requires args.name (string)' }
    end
    local trigrules, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end

    local _, from_idx = _trigger_find_by_name(args.name)
    if not from_idx then
        return { ok = false, error = 'no trigger named "' .. args.name .. '"' }
    end

    -- Anchor lookup for --before/--after: ref is a trigger name; map it
    -- to the trigger's 1-based index in mission.trigrules. nil = not
    -- found.
    local function find_trigger_ref(list, ref)
        if type(ref) ~= 'string' then
            return nil, '--before / --after expects a trigger name (string)'
        end
        for i, t in ipairs(list) do
            if type(t) == 'table' and t.comment == ref then return i end
        end
        return nil, 'no trigger named "' .. ref .. '"'
    end

    local target_idx, terr2 = _reorder_resolve_target(trigrules, from_idx, args, find_trigger_ref)
    if terr2 then return { ok = false, error = terr2 } end

    if from_idx == target_idx then
        return { ok = true, moved = false, from = from_idx, to = target_idx }
    end

    _reorder_apply(trigrules, from_idx, target_idx)
    _trigger_panel_refresh()
    return { ok = true, moved = true, from = from_idx, to = target_idx }
end

-- trigger_reorder_condition — move a condition to a new 1-based position
-- in t.rules.
function M.trigger_reorder_condition(args)
    if type(args) ~= 'table' or type(args.trigger) ~= 'string' or args.trigger == '' then
        return { ok = false, error = 'trigger_reorder_condition requires args.trigger (name)' }
    end
    if type(args.index) ~= 'number' or args.index < 1 then
        return { ok = false, error = 'trigger_reorder_condition requires args.index (1-based)' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end

    local t = _trigger_find_by_name(args.trigger)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.trigger .. '"' }
    end
    if type(t.rules) ~= 'table' or args.index > #t.rules then
        return { ok = false,
                 error = 'trigger has only ' .. (type(t.rules) == 'table' and #t.rules or 0)
                         .. ' conditions; cannot reorder index ' .. args.index }
    end

    -- Anchor for --before/--after is a 1-based index into t.rules.
    local function find_index_ref(list, ref)
        if type(ref) ~= 'number' then
            return nil, '--before / --after expects a 1-based index (number)'
        end
        if ref < 1 or ref > #list then
            return nil, '--before / --after index must be in 1..' .. #list
                        .. ' (got ' .. tostring(ref) .. ')'
        end
        return ref
    end

    local target_idx, terr2 = _reorder_resolve_target(t.rules, args.index, args, find_index_ref)
    if terr2 then return { ok = false, error = terr2 } end

    if args.index == target_idx then
        return { ok = true, moved = false, trigger = args.trigger,
                 from = args.index, to = target_idx }
    end

    _reorder_apply(t.rules, args.index, target_idx)
    _trigger_panel_refresh()
    return { ok = true, moved = true, trigger = args.trigger,
             from = args.index, to = target_idx }
end

-- trigger_reorder_action — move an action to a new 1-based position in
-- t.actions. Same shape as trigger_reorder_condition but operates on
-- t.actions instead of t.rules.
function M.trigger_reorder_action(args)
    if type(args) ~= 'table' or type(args.trigger) ~= 'string' or args.trigger == '' then
        return { ok = false, error = 'trigger_reorder_action requires args.trigger (name)' }
    end
    if type(args.index) ~= 'number' or args.index < 1 then
        return { ok = false, error = 'trigger_reorder_action requires args.index (1-based)' }
    end
    local _, terr = _trigger_ensure_trigrules()
    if terr then return { ok = false, error = terr } end

    local t = _trigger_find_by_name(args.trigger)
    if not t then
        return { ok = false, error = 'no trigger named "' .. args.trigger .. '"' }
    end
    if type(t.actions) ~= 'table' or args.index > #t.actions then
        return { ok = false,
                 error = 'trigger has only ' .. (type(t.actions) == 'table' and #t.actions or 0)
                         .. ' actions; cannot reorder index ' .. args.index }
    end

    local function find_index_ref(list, ref)
        if type(ref) ~= 'number' then
            return nil, '--before / --after expects a 1-based index (number)'
        end
        if ref < 1 or ref > #list then
            return nil, '--before / --after index must be in 1..' .. #list
                        .. ' (got ' .. tostring(ref) .. ')'
        end
        return ref
    end

    local target_idx, terr2 = _reorder_resolve_target(t.actions, args.index, args, find_index_ref)
    if terr2 then return { ok = false, error = terr2 } end

    if args.index == target_idx then
        return { ok = true, moved = false, trigger = args.trigger,
                 from = args.index, to = target_idx }
    end

    _reorder_apply(t.actions, args.index, target_idx)
    _trigger_panel_refresh()
    return { ok = true, moved = true, trigger = args.trigger,
             from = args.index, to = target_idx }
end

return M
