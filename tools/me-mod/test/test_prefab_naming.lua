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

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All prefab_naming tests passed.')
