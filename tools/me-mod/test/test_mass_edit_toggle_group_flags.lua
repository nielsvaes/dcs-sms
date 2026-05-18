-- Standalone test for mass_edit_forms.toggle_group_flags.
-- Tests M._apply + the registered undo handler.
--
-- The form writes group fields directly (no verb roundtrip -- the
-- toggle fields have no side effects, unlike set_country). So these
-- tests verify field state on the entity tables directly: after apply,
-- did g.hidden / g.uncontrolled / etc. flip to the expected value?
-- After undo, did they restore?

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')

-- Stub me_mission for transitive requires.
package.preload['me_mission'] = function() return mock end

-- Stub selection for undo.lua's transitive prefab_ops requires.
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end

-- Stub me_refresh so the form's refresh calls are recorded but no-op'd.
local refresh_calls = {}
local panel_refresh_calls = 0
package.preload['dcs_sms_me.me_refresh'] = function()
    return {
        refresh_group_view   = function(g) refresh_calls[#refresh_calls + 1] = { kind = 'refresh',  g = g } end,
        recreate_group_view  = function(g) refresh_calls[#refresh_calls + 1] = { kind = 'recreate', g = g } end,
        update_hidden_group  = function(g) refresh_calls[#refresh_calls + 1] = { kind = 'hidden',   g = g } end,
        refresh_group_panels = function()  panel_refresh_calls = panel_refresh_calls + 1 end,
    }
end

local form = require('dcs_sms_me.mass_edit_forms.toggle_group_flags')
local undo = require('dcs_sms_me.undo')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function reset()
    refresh_calls = {}
    panel_refresh_calls = 0
    undo.clear()
end

-- ---------------------------------------------------------------------------
-- Module shape
-- ---------------------------------------------------------------------------
do
    check('form.scope = group',                    form.scope == 'group')
    check('form.title non-empty',                  type(form.title) == 'string' and #form.title > 0)
    check('form.new is a function',                type(form.new) == 'function')
    check('form._apply is a function',             type(form._apply) == 'function')
end

-- Helper: build a categories map from a list of (entity, category) pairs.
local function categories_map(pairs_list)
    local out = {}
    for _, p in ipairs(pairs_list) do out[p[1]] = p[2] end
    return out
end

-- Case 1: empty selection -> nothing_selected.
do
    reset()
    local result = form._apply({}, { hidden = true }, {})
    check('empty: changed=0',                     result.changed == 0)
    check('empty: nothing_selected',              result.nothing_selected == true)
    check('empty: toast = "Nothing selected"',    result.toast == 'Nothing selected')
    check('empty: sev = warning',                 result.sev == 'warning')
end

-- Case 2: empty settings (every LEAVE) -> nothing_to_apply.
do
    reset()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    local before_hidden = g.hidden
    local result = form._apply({ g }, {}, categories_map({ { g, 'plane' } }))
    check('no-settings: changed=0',               result.changed == 0)
    check('no-settings: nothing_to_apply',        result.nothing_to_apply == true)
    check('no-settings: toast = "Nothing to apply"', result.toast == 'Nothing to apply')
    check('no-settings: sev = warning',           result.sev == 'warning')
    check('no-settings: g.hidden untouched',      g.hidden == before_hidden)
end

-- Case 3: single plane, one property ON -> field flipped, changed=1.
do
    reset()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    g.hidden = false
    local result = form._apply({ g }, { hidden = true }, categories_map({ { g, 'plane' } }))
    check('single-on: changed=1',                 result.changed == 1)
    check('single-on: not_applicable=0',          (result.not_applicable or 0) == 0)
    check('single-on: g.hidden = true',           g.hidden == true)
    check('single-on: toast = "1 flag changes"',  result.toast == '1 flag changes')
    check('single-on: sev = success',             result.sev == 'success')
    check('single-on: undo recorded',             undo.has_record() == true)
    check('single-on: update_hidden_group called (mirrors ED checkbox handler)',
          #refresh_calls == 1 and refresh_calls[1].g == g and refresh_calls[1].kind == 'hidden')
    check('single-on: refresh_group_panels called once', panel_refresh_calls == 1)
end

-- Case 4: single plane, two properties (ON, OFF) -> both fields flipped,
-- changed=2 (one (entity, field) pair each).
do
    reset()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    g.lateActivation = true   -- starting state we'll flip to false
    g.uncontrolled   = false  -- starting state we'll flip to true
    local result = form._apply({ g },
        { lateActivation = false, uncontrolled = true },
        categories_map({ { g, 'plane' } }))
    check('two-props: changed=2',                 result.changed == 2)
    check('two-props: g.lateActivation = false',  g.lateActivation == false)
    check('two-props: g.uncontrolled = true',     g.uncontrolled == true)
    check('two-props: toast = "2 flag changes"',  result.toast == '2 flag changes')
    -- Only one update_hidden_group call per entity, even with multiple fields touched.
    check('two-props: update_hidden_group called once',
          #refresh_calls == 1 and refresh_calls[1].kind == 'hidden')
end

-- Case 5: plane + vehicle, property `uncontrolled` ON -> field flipped on
-- plane; vehicle counted as not_applicable (uncontrolled is plane/heli
-- only) and its field is untouched.
do
    reset()
    mock.new_mission()
    local g_plane = mock.add_plane({ name = 'P' })
    local g_veh   = mock.add_vehicle({ name = 'V' })
    g_plane.uncontrolled = false
    g_veh.uncontrolled   = false
    local result = form._apply(
        { g_plane, g_veh },
        { uncontrolled = true },
        categories_map({ { g_plane, 'plane' }, { g_veh, 'vehicle' } })
    )
    check('mix-cat: changed=1',                   result.changed == 1)
    check('mix-cat: not_applicable=1',            result.not_applicable == 1)
    check('mix-cat: plane uncontrolled = true',   g_plane.uncontrolled == true)
    check('mix-cat: vehicle uncontrolled untouched (false)',
          g_veh.uncontrolled == false)
    check('mix-cat: toast = "1 flag changes · 1 not applicable"',
          result.toast == '1 flag changes · 1 not applicable')
    check('mix-cat: sev = success',               result.sev == 'success')
    -- update_hidden_group only fired for the plane (the only one we touched).
    check('mix-cat: refresh fired only for plane',
          #refresh_calls == 1 and refresh_calls[1].g == g_plane and refresh_calls[1].kind == 'hidden')
end

-- Case 6: plane + static, property `hidden` ON -> field flipped on BOTH
-- (hidden applies to every category).
do
    reset()
    mock.new_mission()
    local g_plane = mock.add_plane({ name = 'P' })
    local g_stat  = mock.add_static({ name = 'S' })
    g_plane.hidden = false
    g_stat.hidden  = false
    local result = form._apply(
        { g_plane, g_stat },
        { hidden = true },
        categories_map({ { g_plane, 'plane' }, { g_stat, 'static' } })
    )
    check('hidden-universal: changed=2',          result.changed == 2)
    check('hidden-universal: not_applicable=0',   (result.not_applicable or 0) == 0)
    check('hidden-universal: plane.hidden=true',  g_plane.hidden == true)
    check('hidden-universal: static.hidden=true', g_stat.hidden == true)
    check('hidden-universal: 2 update_hidden_group calls',
          #refresh_calls == 2 and refresh_calls[1].kind == 'hidden' and refresh_calls[2].kind == 'hidden')
end

-- Case 7: static + plane-only property -> static counted as not_applicable;
-- with no other entities, result is "Nothing applicable" and no fields
-- change.
do
    reset()
    mock.new_mission()
    local g_stat = mock.add_static({ name = 'S' })
    g_stat.uncontrolled = false
    local result = form._apply(
        { g_stat },
        { uncontrolled = true },  -- plane/heli only
        categories_map({ { g_stat, 'static' } })
    )
    check('nothing-applicable: changed=0',        result.changed == 0)
    check('nothing-applicable: not_applicable=1', result.not_applicable == 1)
    check('nothing-applicable: toast = "Nothing applicable"',
          result.toast == 'Nothing applicable')
    check('nothing-applicable: sev = warning',    result.sev == 'warning')
    check('nothing-applicable: field untouched',  g_stat.uncontrolled == false)
    check('nothing-applicable: 0 recreate calls', #refresh_calls == 0)
end

-- Case 8: undo restores fields in reverse order (multi-field on one
-- entity unwinds in the opposite order it applied).
do
    reset()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    g.hidden         = false
    g.uncontrolled   = false
    g.lateActivation = false
    local result = form._apply({ g },
        { hidden = true, uncontrolled = true, lateActivation = true },
        categories_map({ { g, 'plane' } }))
    check('undo-setup: changed=3',                result.changed == 3)
    check('undo-setup: hidden=true',              g.hidden == true)
    check('undo-setup: uncontrolled=true',        g.uncontrolled == true)
    check('undo-setup: lateActivation=true',      g.lateActivation == true)

    local ok, partial = undo.undo()
    check('undo: ok = true',                      ok == true)
    check('undo: no partial-failure message',     partial == nil)
    check('undo: hidden restored to false',       g.hidden == false)
    check('undo: uncontrolled restored to false', g.uncontrolled == false)
    check('undo: lateActivation restored to false', g.lateActivation == false)
end

-- Case 9: hiddenOnPlanner field uses direct write semantics (not routed
-- through any verb). Verify the field name on the entity dict matches.
do
    reset()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    g.hiddenOnPlanner = false
    local result = form._apply({ g },
        { hiddenOnPlanner = true },
        categories_map({ { g, 'plane' } }))
    check('planner-write: changed=1',             result.changed == 1)
    check('planner-write: g.hiddenOnPlanner=true', g.hiddenOnPlanner == true)
end

-- Case 10: uncontrollable field (GAME MASTER ONLY) writes g.uncontrollable
-- (with -able, distinct from g.uncontrolled).
do
    reset()
    mock.new_mission()
    local g = mock.add_vehicle({ name = 'V' })  -- uncontrollable applies to vehicles
    g.uncontrollable = false
    g.uncontrolled = false  -- track separately to confirm we don't touch the wrong field
    local result = form._apply({ g },
        { uncontrollable = true },
        categories_map({ { g, 'vehicle' } }))
    check('uncontrollable-write: changed=1',                 result.changed == 1)
    check('uncontrollable-write: g.uncontrollable=true',     g.uncontrollable == true)
    check('uncontrollable-write: g.uncontrolled untouched',  g.uncontrolled == false)
end

-- Case 11: helicopter is treated the same as plane for applicability.
do
    reset()
    mock.new_mission()
    local g = mock.add_helicopter({ name = 'H' })
    g.hiddenOnMFD = false
    local result = form._apply({ g },
        { hiddenOnMFD = true },
        categories_map({ { g, 'helicopter' } }))
    check('heli: changed=1',                      result.changed == 1)
    check('heli: not_applicable=0',               (result.not_applicable or 0) == 0)
    check('heli: g.hiddenOnMFD=true',             g.hiddenOnMFD == true)
end

-- Case 12: hiddenOnMFD's non-boolean default ({}) round-trips correctly.
-- Before apply: g.hiddenOnMFD = {} (table, freshly-created group).
-- Apply ON: should write true. Undo should restore to false (the
-- normalized "off" value for a previously non-boolean field).
do
    reset()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    g.hiddenOnMFD = {}   -- non-boolean default
    local result = form._apply({ g },
        { hiddenOnMFD = true },
        categories_map({ { g, 'plane' } }))
    check('mfd-default-table: changed=1',         result.changed == 1)
    check('mfd-default-table: g.hiddenOnMFD=true', g.hiddenOnMFD == true)
    -- Undo: should restore to false (normalized).
    local ok = undo.undo()
    check('mfd-default-table: undo ok=true',      ok == true)
    check('mfd-default-table: g.hiddenOnMFD=false (normalized from {})',
          g.hiddenOnMFD == false)
end

-- Case 13: missing categories map -> every entity treated as 'unknown'
-- which matches no APPLIES_TO row, so nothing changes.
do
    reset()
    mock.new_mission()
    local g = mock.add_plane({ name = 'A' })
    g.hidden = false
    local result = form._apply({ g }, { hidden = true }, nil)
    check('no-categories: changed=0',             result.changed == 0)
    check('no-categories: not_applicable=1',      result.not_applicable == 1)
    check('no-categories: g.hidden untouched',    g.hidden == false)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All toggle_group_flags tests passed.')
