-- Standalone test for prefab_ops.save_selection envelope wrapping + path logic.
-- Stubs lfs and selection to avoid DCS dependencies.
-- Run via: lua test_prefab_ops_save.lua  (cwd: tools/me-mod/test/)

-- Stub lfs (writedir + mkdir).
local fake_writedir = 'C:\\fake-saved-games\\'
package.preload['lfs'] = function()
    return {
        writedir = function() return fake_writedir end,
        mkdir = function(p) return true end,
    }
end

-- Capture io.open calls so we can inspect what the save wrote.
local captured = { path = nil, content = nil }
local real_open = io.open
io.open = function(path, mode)
    if mode == 'w' then
        return {
            write = function(self, content) captured.path = path; captured.content = content end,
            close = function(self) end,
        }
    end
    return real_open(path, mode)
end

-- Stub Mission.TheatreOfWarData.getName so save_selection captures a theatre.
-- The real module path is `Mission.TheatreOfWarData` (per MissionEditor.lua); a
-- bare `require('TheatreOfWarData')` silently fails — that was the bug.
package.preload['Mission.TheatreOfWarData'] = function()
    return { getName = function() return 'Caucasus' end }
end

-- Stub selection.snapshot.
package.preload['dcs_sms_me.selection'] = function()
    return {
        snapshot = function()
            return {
                ok = true,
                timestamp_utc = '2026-05-03T12:00:00Z',
                selection_mode = 'multi',
                groups = {
                    { name='G1', x=100, y=200,
                      units={ { name='U1', type='F-16C_50', x=100, y=200, heading=0 } },
                      boss = { id=2, name='USA' } },
                },
                statics = {},
                zones = {},
                drawings = {},
                nav_points = {},
                raw = {},
            }
        end,
    }
end

-- Empty-snapshot variant for the empty-selection case.
local empty_selection_module = {
    snapshot = function()
        return { ok=true, timestamp_utc='2026-05-03T12:00:00Z', selection_mode='multi',
                 groups={}, statics={}, zones={}, drawings={}, nav_points={}, raw={} }
    end,
}

-- Stub prefab_modules so save_selection records a deterministic required
-- module without needing DCS's setRequiredModules. Installed BEFORE the first
-- require('prefab_ops') so every (re-)require of prefab_ops sees the stub.
package.loaded['dcs_sms_me.prefab_modules'] = {
    detect = function(_dump)
        return { ['UH-60L'] = { id = 'UH-60L', display_name = 'UH-60L Black Hawk',
                                objects = { ['UH-60L'] = 1 }, count = 1 } }
    end,
    missing = function() return {} end,
}

package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local prefab_ops = require('prefab_ops')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1
    end
end

-- Case: save_selection with valid selection produces a file at the right path.
do
    captured.path, captured.content = nil, nil
    local ok, path = prefab_ops.save_selection('test_jet')
    check('save_selection returns ok', ok == true, 'got ' .. tostring(ok))
    check('save_selection returns path', path == fake_writedir .. 'dcs-sms\\prefabs\\test_jet.prefab',
          'got ' .. tostring(path))
    check('io.open was called with that path', captured.path == path, 'got ' .. tostring(captured.path))
    check('content begins with "return {"',
          type(captured.content) == 'string' and captured.content:sub(1,8) == 'return {',
          'got ' .. (captured.content and captured.content:sub(1,30) or 'nil'))
    check('content has meta.name',
          captured.content and captured.content:find('%["name"%]%s*=%s*"test_jet"', 1) ~= nil,
          'meta.name not found in content')
    check('content has meta.theatre captured from TheatreOfWarData',
          captured.content and captured.content:find('%["theatre"%]%s*=%s*"Caucasus"', 1) ~= nil,
          'meta.theatre not found in content')
end

-- Case: required_modules from prefab_modules.detect is recorded in the saved
-- prefab. The stub above returns a UH-60L module for any dump, so a normal save
-- (valid selection from the package.preload selection stub) must serialize it.
do
    captured.path, captured.content = nil, nil
    local ok, _ = prefab_ops.save_selection('mod_jet')
    check('save_selection with required module returns ok', ok == true,
          'got ' .. tostring(ok))
    check('saved content records required_modules id',
          captured.content and captured.content:find('"UH%-60L"', 1) ~= nil,
          'required_modules id missing from saved content')
    check('saved content records module display name',
          captured.content and captured.content:find('UH%-60L Black Hawk', 1) ~= nil,
          'display name missing')
end

-- Case: place_at_origin propagates into meta on save.
do
    captured.path, captured.content = nil, nil
    local ok, _ = prefab_ops.save_selection('fixed_jet', true)
    check('save_selection with place_at_origin=true returns ok', ok == true,
          'got ' .. tostring(ok))
    check('saved content has meta.place_at_origin = true',
          captured.content and captured.content:find('%["place_at_origin"%]%s*=%s*true', 1) ~= nil,
          'meta.place_at_origin not found in content')
end

-- Case: opts.airbases propagates into meta.airbases on save.
do
    captured.path, captured.content = nil, nil
    local airbases = {
        {
            name                    = 'Muwaffaq Salti',
            airdrome_number_at_save = 68,
            warehouse = {
                coalition = 'BLUE',
                jet_fuel  = { InitFuel = 50 },
            },
        },
    }
    local ok, _ = prefab_ops.save_selection('with_airbases', false, airbases)
    check('save_selection with airbases returns ok', ok == true, 'got ' .. tostring(ok))
    check('saved content has meta.airbases',
          captured.content and captured.content:find('%["airbases"%]', 1) ~= nil,
          'meta.airbases not in content')
    check('saved content has airbase name "Muwaffaq Salti"',
          captured.content and captured.content:find('"Muwaffaq Salti"', 1, true) ~= nil)
    check('saved content has BLUE coalition inside airbases',
          captured.content and captured.content:find('"BLUE"', 1, true) ~= nil)
    check('saved content version bumped to 0.5.0',
          captured.content and captured.content:find('"0%.5%.0"', 1) ~= nil,
          'version not 0.5.0')
end

-- Case: place_at_origin omitted (default false) does not write the field.
do
    captured.path, captured.content = nil, nil
    local ok, _ = prefab_ops.save_selection('plain_jet')
    check('save_selection without place_at_origin returns ok', ok == true,
          'got ' .. tostring(ok))
    check('saved content omits place_at_origin when false',
          captured.content and not captured.content:find('place_at_origin', 1, true),
          'unexpected place_at_origin field in content')
end

-- Case: save_selection with empty selection returns nil + reason.
do
    package.loaded['dcs_sms_me.selection'] = empty_selection_module
    package.loaded['prefab_ops'] = nil  -- force re-require so it picks up new selection module
    local prefab_ops2 = require('prefab_ops')
    local ok, err = prefab_ops2.save_selection('empty')
    check('empty save returns nil',  ok == nil, 'got ' .. tostring(ok))
    check('empty save returns error', type(err) == 'string' and err:find('selection'), 'got ' .. tostring(err))
end

-- Case: exists() with a file present, both .prefab and legacy .lua.
do
    -- Simulate file presence by stubbing io.open in read mode for specific paths.
    local prefab_target = fake_writedir .. 'dcs-sms\\prefabs\\already_here.prefab'
    local legacy_target = fake_writedir .. 'dcs-sms\\prefabs\\legacy_one.lua'
    io.open = function(path, mode)
        if mode == 'r' or mode == nil then
            if path == prefab_target or path == legacy_target then
                return { close = function() end }
            end
            return nil, 'not found'
        end
        return real_open(path, mode)
    end
    package.loaded['prefab_ops'] = nil
    local prefab_ops3 = require('prefab_ops')
    check('exists() true for .prefab file', prefab_ops3.exists('already_here') == true,
          'expected true for .prefab')
    check('exists() true for legacy .lua file', prefab_ops3.exists('legacy_one') == true,
          'expected true for legacy .lua')
    check('exists() false for absent file', prefab_ops3.exists('not_here') == false,
          'expected false')
end

-- New: folder-aware exists() scopes the check to the given subfolder, while a
-- nil/'' folder keeps the historical root + legacy behavior.
do
    local root_prefab   = fake_writedir .. 'dcs-sms\\prefabs\\already_here.prefab'
    local folder_prefab = fake_writedir .. 'dcs-sms\\prefabs\\CAP\\in_folder.prefab'
    local legacy_target = fake_writedir .. 'dcs-sms\\prefabs\\legacy_one.lua'
    io.open = function(path, mode)
        if mode == 'r' or mode == nil then
            if path == root_prefab or path == folder_prefab or path == legacy_target then
                return { close = function() end }
            end
            return nil, 'not found'
        end
        return real_open(path, mode)
    end
    package.loaded['prefab_ops'] = nil
    local po = require('prefab_ops')
    check('exists(name, folder) true when file is in that subfolder',
          po.exists('in_folder', 'CAP') == true, 'expected true in CAP')
    check('exists(name) false for a file that only exists in a subfolder',
          po.exists('in_folder') == false, 'root check must not see CAP/in_folder')
    check('exists(name, folder) false when file is only at root',
          po.exists('already_here', 'CAP') == false, 'already_here is at root, not CAP')
    check('exists(name, "") matches root (back-compat)',
          po.exists('already_here', '') == true, 'expected true at root')
    check('exists(name) still true at root (no folder arg)',
          po.exists('already_here') == true, 'expected true at root')
    check('legacy .lua NOT consulted for a subfolder',
          po.exists('legacy_one', 'CAP') == false, 'legacy is root-only')
    check('legacy .lua still consulted at root',
          po.exists('legacy_one') == true, 'legacy should resolve at root')
end

-- New: save with a folder argument writes under the subfolder and
-- mkdir-s segments top-down.
do
    -- Re-install the capturing io.open stub (the exists() case above
    -- replaced it with a read-mode-only stub that routes writes to
    -- real_open, which would fail on the fake writedir path).
    captured.path, captured.content = nil, nil
    io.open = function(path, mode)
        if mode == 'w' then
            return {
                write = function(self, content) captured.path = path; captured.content = content end,
                close = function(self) end,
            }
        end
        return real_open(path, mode)
    end
    -- Reset mkdir tracking on the lfs stub if available; otherwise this
    -- test just verifies the path computation since the lfs stub already
    -- swallows mkdir calls.
    local ok, _ = pcall(function()
        -- Re-require with a non-empty selection so save_selection succeeds.
        package.preload['dcs_sms_me.selection'] = function()
            return {
                snapshot = function()
                    return {
                        ok = true,
                        timestamp_utc = '2026-05-03T12:00:00Z',
                        selection_mode = 'multi',
                        groups = {
                            { name='G1', x=100, y=200,
                              units={ { name='U1', type='F-16C_50', x=100, y=200, heading=0 } },
                              boss = { id=2, name='USA' } },
                        },
                        statics = {}, zones = {}, drawings = {}, nav_points = {}, raw = {},
                    }
                end,
            }
        end
        package.loaded['dcs_sms_me.selection'] = nil
        package.loaded['prefab_ops'] = nil
        local prefab_ops_f = require('prefab_ops')
        local result, path_or_err = prefab_ops_f.save_selection('nested_test', false, nil, 'CAP/Tomcats')
        check('folder save: succeeded', result == true, tostring(path_or_err))
        check('folder save: path contains CAP\\Tomcats',
              tostring(path_or_err):match('CAP\\Tomcats\\nested_test%.prefab') ~= nil,
              'got path: ' .. tostring(path_or_err))
    end)
    check('folder save: no Lua error', ok)
end

if failures > 0 then
    print(string.format('%d failure(s)', failures))
    os.exit(1)
end
print('All prefab_ops save tests passed.')
