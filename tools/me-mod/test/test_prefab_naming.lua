-- Standalone test for prefab_naming pipeline.
-- Tests apply() + _compute_targets() pure functions.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end
package.preload['dcs_sms_me.verbs'] = function() return {} end
package.preload['me_mission'] = function() return require('mock_me_mission') end

local naming = require('dcs_sms_me.prefab_naming')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Case A1: apply() with no opts -> no-op result.
do
    local rec = { groups = {}, zones = {}, drawings = {}, errors = {} }
    local result = naming.apply(rec, nil)
    check('A1: result is table', type(result) == 'table')
    check('A1: renamed_groups = 0', result.renamed_groups == 0)
    check('A1: renamed_units = 0', result.renamed_units == 0)
    check('A1: failed = 0', result.failed == 0)
    check('A1: toast = nil', result.toast == nil)
    check('A1: sev = nil', result.sev == nil)
end

-- Case A2: apply() with empty string opts -> no-op result.
do
    local rec = { groups = {}, zones = {}, drawings = {}, errors = {} }
    local result = naming.apply(rec, { name = '', prefix = '', suffix = '' })
    check('A2: renamed_groups = 0', result.renamed_groups == 0)
    check('A2: toast = nil', result.toast == nil)
end

local mock = require('mock_me_mission')

-- Capture renames for assertion.
local renames = {}
local mission_mod = setmetatable({}, { __index = mock })
function mission_mod.renameGroup(g, new) renames[#renames + 1] = { g = g, new = new }; g.name = new; return true end
function mission_mod.check_group_name(desired) return desired end
function mission_mod.renameUnit(u, new) u.name = new; return true end
package.loaded['me_mission'] = mission_mod  -- override the preload registration

-- Helper: build a minimal placement record with N planes-as-groups (no
-- statics/zones/drawings). Each entry mimics prefab_ops.M.place's shape.
local function build_rec(group_names)
    local rec = { groups = {}, zones = {}, drawings = {}, errors = {} }
    for _, n in ipairs(group_names) do
        local g = mock.add_plane({ name = n })
        rec.groups[#rec.groups + 1] = {
            orig_name  = n,
            runtime_id = g.groupId,
            group_obj  = g,
        }
    end
    return rec
end

-- Case B1: Name with {n} renames groups in name_asc order.
do
    mock.new_mission(); renames = {}
    local rec = build_rec({ 'Charlie', 'Alpha', 'Bravo' })
    local result = naming.apply(rec, { name = 'Tank-{n}' })
    check('B1: renamed_groups = 3', result.renamed_groups == 3,
          'got ' .. tostring(result.renamed_groups))
    check('B1: Alpha -> Tank-01', rec.groups[2].group_obj.name == 'Tank-01',
          'got ' .. tostring(rec.groups[2].group_obj.name))
    check('B1: Bravo -> Tank-02', rec.groups[3].group_obj.name == 'Tank-02',
          'got ' .. tostring(rec.groups[3].group_obj.name))
    check('B1: Charlie -> Tank-03', rec.groups[1].group_obj.name == 'Tank-03',
          'got ' .. tostring(rec.groups[1].group_obj.name))
    check('B1: sev = success', result.sev == 'success',
          'got ' .. tostring(result.sev))
end

-- Case B2: Name without {n} -> identical names; ME collision handling
-- applies (our mock returns desired verbatim, so all three become "Tank").
do
    mock.new_mission(); renames = {}
    local rec = build_rec({ 'A', 'B' })
    local result = naming.apply(rec, { name = 'Tank' })
    check('B2: renamed_groups = 2', result.renamed_groups == 2)
    check('B2: both became Tank',
          rec.groups[1].group_obj.name == 'Tank' and rec.groups[2].group_obj.name == 'Tank')
end

-- Case B3: empty name string -> no-op (other fields nil).
do
    mock.new_mission(); renames = {}
    local rec = build_rec({ 'A' })
    local result = naming.apply(rec, { name = '', prefix = '', suffix = '' })
    check('B3: renamed_groups = 0', result.renamed_groups == 0)
    check('B3: A unchanged', rec.groups[1].group_obj.name == 'A')
end

-- Case C1: Prefix prepends to every group/static.
do
    mock.new_mission(); renames = {}
    local rec = build_rec({ 'Alpha', 'Bravo' })
    local result = naming.apply(rec, { prefix = 'EAST_' })
    check('C1: renamed_groups = 2', result.renamed_groups == 2)
    check('C1: Alpha -> EAST_Alpha', rec.groups[1].group_obj.name == 'EAST_Alpha')
    check('C1: Bravo -> EAST_Bravo', rec.groups[2].group_obj.name == 'EAST_Bravo')
end

-- Case C2: Name THEN Prefix stack: Name replaces, Prefix prepends final.
do
    mock.new_mission(); renames = {}
    local rec = build_rec({ 'Alpha' })
    local result = naming.apply(rec, { name = 'Tank-{n}', prefix = 'EAST_' })
    check('C2: result = EAST_Tank-01',
          rec.groups[1].group_obj.name == 'EAST_Tank-01',
          'got ' .. tostring(rec.groups[1].group_obj.name))
    check('C2: renamed_groups >= 1', result.renamed_groups >= 1)
end

-- Case D1: Suffix with keep_num=false -> plain append.
do
    mock.new_mission(); renames = {}
    local rec = build_rec({ 'Viper-1' })
    local result = naming.apply(rec, { suffix = '_alpha', keep_num = false })
    check('D1: Viper-1 -> Viper-1_alpha',
          rec.groups[1].group_obj.name == 'Viper-1_alpha',
          'got ' .. tostring(rec.groups[1].group_obj.name))
end

-- Case D2: Suffix with keep_num=true -> inserted before -<digits>.
do
    mock.new_mission(); renames = {}
    local rec = build_rec({ 'Viper-1' })
    local result = naming.apply(rec, { suffix = '_alpha', keep_num = true })
    check('D2: Viper-1 -> Viper_alpha-1 (keep num)',
          rec.groups[1].group_obj.name == 'Viper_alpha-1',
          'got ' .. tostring(rec.groups[1].group_obj.name))
end

-- Case D3: Full stack Name + Prefix + Suffix with keep_num=true.
do
    mock.new_mission(); renames = {}
    local rec = build_rec({ 'Foo' })
    local result = naming.apply(rec, {
        name = 'Tank-{n}', prefix = 'EAST_', suffix = '_alpha', keep_num = true,
    })
    check('D3: Foo -> EAST_Tank_alpha-01',
          rec.groups[1].group_obj.name == 'EAST_Tank_alpha-01',
          'got ' .. tostring(rec.groups[1].group_obj.name))
end

-- Helper: build a group with multiple units.
local function build_rec_with_units(group_name, unit_names)
    local rec = { groups = {}, zones = {}, drawings = {}, errors = {} }
    local g = mock.add_plane({ name = group_name })
    -- Add additional units by copying the first one's pattern.
    g.units = g.units or { { unitId = 1, name = unit_names[1] } }
    g.units[1].name = unit_names[1]
    for i = 2, #unit_names do
        g.units[i] = { unitId = i * 100, name = unit_names[i] }
    end
    rec.groups[#rec.groups + 1] = {
        orig_name = group_name, runtime_id = g.groupId, group_obj = g,
    }
    return rec
end

-- Case E1: After Name rename, units take <newGroupName>-<idx>.
do
    mock.new_mission(); renames = {}
    local rec = build_rec_with_units('Viper-1', { 'Old-1', 'Old-2' })
    local result = naming.apply(rec, { name = 'Tank-{n}' })
    local g = rec.groups[1].group_obj
    check('E1: group -> Tank-01', g.name == 'Tank-01',
          'got ' .. tostring(g.name))
    check('E1: unit[1] -> Tank-01-1', g.units[1].name == 'Tank-01-1',
          'got ' .. tostring(g.units[1].name))
    check('E1: unit[2] -> Tank-01-2', g.units[2].name == 'Tank-01-2',
          'got ' .. tostring(g.units[2].name))
    check('E1: renamed_units = 2', result.renamed_units == 2,
          'got ' .. tostring(result.renamed_units))
end

-- Case E2: No naming opts -> auto-name-units does NOT run.
do
    mock.new_mission(); renames = {}
    local rec = build_rec_with_units('Viper-1', { 'A', 'B' })
    local result = naming.apply(rec, {})
    local g = rec.groups[1].group_obj
    check('E2: unit[1] unchanged (A)', g.units[1].name == 'A')
    check('E2: renamed_units = 0', result.renamed_units == 0)
end

-- Case E3: Only Prefix -> auto-name-units uses post-prefix group name.
do
    mock.new_mission(); renames = {}
    local rec = build_rec_with_units('Viper', { 'a', 'b' })
    local result = naming.apply(rec, { prefix = 'EAST_' })
    local g = rec.groups[1].group_obj
    check('E3: group -> EAST_Viper', g.name == 'EAST_Viper')
    check('E3: unit[1] -> EAST_Viper-1', g.units[1].name == 'EAST_Viper-1',
          'got ' .. tostring(g.units[1].name))
end

-- Case F1: Prefix on a placement record with zones.
do
    mock.new_mission(); renames = {}
    local rec = {
        groups = {},
        zones = {
            { orig_name = 'ZoneA', runtime_id = 100, zone_obj = { name = 'ZoneA' } },
            { orig_name = 'ZoneB', runtime_id = 101, zone_obj = { name = 'ZoneB' } },
        },
        drawings = {},
        errors = {},
    }
    local result = naming.apply(rec, { prefix = 'P_' })
    check('F1: zone[1].name -> P_ZoneA', rec.zones[1].zone_obj.name == 'P_ZoneA',
          'got ' .. tostring(rec.zones[1].zone_obj.name))
    check('F1: zone[2].name -> P_ZoneB', rec.zones[2].zone_obj.name == 'P_ZoneB')
    check('F1: renamed_zones = 2', result.renamed_zones == 2,
          'got ' .. tostring(result.renamed_zones))
end

-- Case F2: Suffix with keep_num on drawings.
do
    mock.new_mission(); renames = {}
    local rec = {
        groups = {}, zones = {},
        drawings = {
            { orig_name = 'Mark-1', drawing_obj = { name = 'Mark-1' } },
        },
        errors = {},
    }
    local result = naming.apply(rec, { suffix = '_X', keep_num = true })
    check('F2: drawing -> Mark_X-1 (keep num)',
          rec.drawings[1].drawing_obj.name == 'Mark_X-1',
          'got ' .. tostring(rec.drawings[1].drawing_obj.name))
    check('F2: renamed_drawings = 1', result.renamed_drawings == 1)
end

-- Case F3: Name does NOT apply to zones/drawings (per spec D3).
do
    mock.new_mission(); renames = {}
    local rec = {
        groups = {},
        zones    = { { orig_name = 'Z', runtime_id = 1, zone_obj    = { name = 'Z' } } },
        drawings = { { orig_name = 'D',                 drawing_obj = { name = 'D' } } },
        errors = {},
    }
    local result = naming.apply(rec, { name = 'NEW' })
    check('F3: zone unchanged', rec.zones[1].zone_obj.name == 'Z')
    check('F3: drawing unchanged', rec.drawings[1].drawing_obj.name == 'D')
    check('F3: renamed_zones = 0', result.renamed_zones == 0)
    check('F3: renamed_drawings = 0', result.renamed_drawings == 0)
end

-- Case G1: toast composes from per-category counts.
do
    mock.new_mission(); renames = {}
    local rec = build_rec({ 'Alpha', 'Bravo' })
    local result = naming.apply(rec, { name = 'Tank-{n}' })
    check('G1: toast non-nil', type(result.toast) == 'string',
          'got ' .. tostring(result.toast))
    check('G1: toast mentions 2 renamed',
          result.toast:find('2', 1, true) ~= nil and result.toast:find('rename', 1, true) ~= nil,
          'got ' .. tostring(result.toast))
    check('G1: sev = success', result.sev == 'success')
end

-- Case G2: failure aggregates to warning sev.
do
    mock.new_mission(); renames = {}
    local rec = {
        groups = {},
        zones  = { { orig_name = 'Z', runtime_id = 99 } },  -- no zone_obj, will fail
        drawings = {}, errors = {},
    }
    local result = naming.apply(rec, { prefix = 'P_' })
    check('G2: failed >= 1', result.failed >= 1)
    check('G2: sev = warning or error', result.sev == 'warning' or result.sev == 'error',
          'got ' .. tostring(result.sev))
end

-- Case G3: _compute_targets returns planned writes without mutating.
do
    mock.new_mission()
    local rec = build_rec({ 'Foo' })
    local before = rec.groups[1].group_obj.name
    local plan = naming._compute_targets(rec, { name = 'Bar' })
    check('G3: plan is list', type(plan) == 'table')
    check('G3: plan length = 1', #plan == 1,
          'got ' .. tostring(#plan))
    check('G3: plan[1].scope = group', plan[1] and plan[1].scope == 'group')
    check('G3: plan[1].old = Foo', plan[1] and plan[1].old == 'Foo')
    check('G3: plan[1].new = Bar', plan[1] and plan[1].new == 'Bar')
    check('G3: entity untouched', rec.groups[1].group_obj.name == before)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All prefab_naming tests passed.')
