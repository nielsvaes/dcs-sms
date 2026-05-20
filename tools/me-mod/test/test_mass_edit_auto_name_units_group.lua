-- Standalone test for mass_edit_forms.auto_name_units_group.
-- Stubs Mission.renameUnit to drive both the happy path and the
-- collision / throw failure paths.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')

-- Stubbable Mission.renameUnit: by default applies the new name and
-- returns true (mirrors the ME's collision-free path). Individual
-- tests override mission_module.renameUnit for collision / throw
-- behavior.
local mission_module = setmetatable({}, { __index = mock })
function mission_module.renameUnit(u, new_name)
    u.name = new_name
    return true
end
package.preload['me_mission'] = function() return mission_module end

package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end
package.preload['dcs_sms_me.verbs'] = function() return {} end

local form = require('dcs_sms_me.mass_edit_forms.auto_name_units_group')
local undo = require('dcs_sms_me.undo')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- ---------------------------------------------------------------------------
-- Module shape
-- ---------------------------------------------------------------------------
do
    check('form.scope = group',         form.scope == 'group')
    check('form.title is non-empty',    type(form.title) == 'string' and #form.title > 0)
    check('form.new is a function',     type(form.new) == 'function')
    check('form._apply is a function',  type(form._apply) == 'function')
end

-- Helper: build a group with N named units.
local function build_group(group_name, unit_names)
    local g = { name = group_name, units = {} }
    for i, nm in ipairs(unit_names) do
        g.units[i] = { name = nm, unitId = 1000 + i }
    end
    return g
end

-- ---------------------------------------------------------------------------
-- Case 1: empty selection.
-- ---------------------------------------------------------------------------
do
    undo.clear()
    local result = form._apply({})
    check('empty: changed=0',                   result.changed == 0)
    check('empty: nothing_selected',            result.nothing_selected == true)
    check('empty: toast = Nothing selected',    result.toast == 'Nothing selected')
    check('empty: sev = warning',               result.sev == 'warning')
    check('empty: no undo recorded',            undo.has_record() == false)
end

-- ---------------------------------------------------------------------------
-- Case 2: single group "Viper-1" with two units already-correctly named.
-- ---------------------------------------------------------------------------
do
    undo.clear()
    local g = build_group('Viper-1', { 'Viper-1-1', 'Viper-1-2' })
    local r = form._apply({ g })
    check('already-named: changed=0',           r.changed == 0)
    check('already-named: failed=0',            r.failed == 0)
    check('already-named: toast = No changes',  r.toast == 'No changes')
    check('already-named: sev = warning',       r.sev == 'warning')
    check('already-named: u1 name unchanged',   g.units[1].name == 'Viper-1-1')
    check('already-named: u2 name unchanged',   g.units[2].name == 'Viper-1-2')
end

-- ---------------------------------------------------------------------------
-- Case 3: single group "Viper-1" with mis-named units → renames both.
-- ---------------------------------------------------------------------------
do
    undo.clear()
    local g = build_group('Viper-1', { 'Bandit-Lead', 'Bandit-2' })
    local r = form._apply({ g })
    check('rename: changed=2',                  r.changed == 2)
    check('rename: failed=0',                   r.failed == 0)
    check('rename: u1 → Viper-1-1',             g.units[1].name == 'Viper-1-1')
    check('rename: u2 → Viper-1-2',             g.units[2].name == 'Viper-1-2')
    check('rename: toast = "2 units renamed"',  r.toast == '2 units renamed')
    check('rename: sev = success',              r.sev == 'success')
    check('rename: undo recorded',              undo.has_record() == true)
end

-- ---------------------------------------------------------------------------
-- Case 4: multi-group batch — each group's units get its prefix.
-- ---------------------------------------------------------------------------
do
    undo.clear()
    local g1 = build_group('Alpha', { 'a', 'b', 'c' })
    local g2 = build_group('Bravo', { 'x' })
    local r = form._apply({ g1, g2 })
    check('multi: changed=4',                   r.changed == 4)
    check('multi: g1.u1 = Alpha-1',             g1.units[1].name == 'Alpha-1')
    check('multi: g1.u2 = Alpha-2',             g1.units[2].name == 'Alpha-2')
    check('multi: g1.u3 = Alpha-3',             g1.units[3].name == 'Alpha-3')
    check('multi: g2.u1 = Bravo-1',             g2.units[1].name == 'Bravo-1')
end

-- ---------------------------------------------------------------------------
-- Case 5: undo restores every old name.
-- ---------------------------------------------------------------------------
do
    undo.clear()
    local g = build_group('Eagle', { 'old1', 'old2' })
    form._apply({ g })
    check('pre-undo: u1 = Eagle-1',             g.units[1].name == 'Eagle-1')
    check('pre-undo: u2 = Eagle-2',             g.units[2].name == 'Eagle-2')
    local ok, _err = undo.undo()
    check('undo: ok = true',                    ok == true)
    check('undo: u1 restored',                  g.units[1].name == 'old1')
    check('undo: u2 restored',                  g.units[2].name == 'old2')
end

-- ---------------------------------------------------------------------------
-- Case 6: renameUnit refuses (collision) → counted as failed, batch continues.
-- ---------------------------------------------------------------------------
do
    undo.clear()
    -- Stub: reject when new name contains '-2'.
    local orig = mission_module.renameUnit
    mission_module.renameUnit = function(u, new_name)
        if new_name:find('-2$') then return false end
        u.name = new_name
        return true
    end

    local g = build_group('Hornet', { 'a', 'b', 'c' })
    local r = form._apply({ g })
    check('collision: changed=2 (u1 and u3)',   r.changed == 2)
    check('collision: failed=1 (u2)',           r.failed == 1)
    check('collision: u1 renamed',              g.units[1].name == 'Hornet-1')
    check('collision: u2 unchanged',            g.units[2].name == 'b')
    check('collision: u3 renamed',              g.units[3].name == 'Hornet-3')
    check('collision: toast contains "1 failed"',
          r.toast:find('1 failed') ~= nil)
    check('collision: sev = warning',           r.sev == 'warning')
    mission_module.renameUnit = orig
end

-- ---------------------------------------------------------------------------
-- Case 7: renameUnit throws → counted as failed.
-- ---------------------------------------------------------------------------
do
    undo.clear()
    local orig = mission_module.renameUnit
    mission_module.renameUnit = function() error('boom from renameUnit') end

    local g = build_group('X', { 'a' })
    local r = form._apply({ g })
    check('throw: failed=1',                    r.failed == 1)
    check('throw: changed=0',                   r.changed == 0)
    check('throw: u1 unchanged',                g.units[1].name == 'a')
    mission_module.renameUnit = orig
end

-- ---------------------------------------------------------------------------
-- Case 8: group with empty name → skipped (no rename attempted).
-- ---------------------------------------------------------------------------
do
    undo.clear()
    local g = build_group('', { 'a', 'b' })
    local r = form._apply({ g })
    check('empty-group-name: changed=0',        r.changed == 0)
    check('empty-group-name: failed=0',         r.failed == 0)
    check('empty-group-name: u1 untouched',     g.units[1].name == 'a')
end

-- ---------------------------------------------------------------------------
-- Case 9: group with no units → no rename, no failure.
-- ---------------------------------------------------------------------------
do
    undo.clear()
    local g = { name = 'NoUnits', units = {} }
    local r = form._apply({ g })
    check('no-units: changed=0',                r.changed == 0)
    check('no-units: failed=0',                 r.failed == 0)
    check('no-units: no undo recorded',         undo.has_record() == false)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All auto_name_units_group tests passed.')
