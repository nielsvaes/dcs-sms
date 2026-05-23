-- test_verbs_file.lua — Lua-side unit tests for verbs/file_verbs.lua.

local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'
package.path = here .. '?.lua;' .. package.path

local mock = require('mock_me_mission')

-- ============================================================
-- Extend mock with file-related state + stubs
-- ============================================================

-- The verb reads/writes these on the me_mission singleton.
mock.mission_modified = false
mock.saved_path = nil
mock.save_calls = 0
mock.save_should_fail = false
mock.save_should_throw = false

function mock.isMissionModified() return mock.mission_modified end
function mock.getMissionPathIsSaved()
    return type(mock.saved_path) == 'string' and mock.saved_path ~= ''
end
function mock.getDefaultDate() return { Day = 1, Month = 6, Year = 2025 } end
function mock.create_new_mission(reset_state)
    mock.create_new_mission_calls = (mock.create_new_mission_calls or 0) + 1
end
function mock.save_mission_safe(path, _showError, _noLoad)
    mock.save_calls = mock.save_calls + 1
    if mock.save_should_throw then error('boom') end
    if mock.save_should_fail then return false end
    mock.saved_path = path
    mock.mission.path = path
    return true
end

package.preload['me_mission']    = function() return mock end
package.preload['me_map_window'] = function() return mock end

-- me_map_window additions on the same singleton (mock = me_mission and me_map_window).
mock.is_empty = true
mock.unselect_calls = 0
mock.show_calls = 0
mock.init_terrain_calls = 0
function mock.isEmptyME() return mock.is_empty end
function mock.unselectAll() mock.unselect_calls = mock.unselect_calls + 1 end
function mock.show(_arg) mock.show_calls = mock.show_calls + 1 end
function mock.initTerrain(_a, _b, _c, _date)
    mock.init_terrain_calls = mock.init_terrain_calls + 1
end

-- me_toolbar stub for file_open.
local me_toolbar_stub = { load_calls = 0, last_path = nil }
function me_toolbar_stub.loadMission(path)
    me_toolbar_stub.load_calls = me_toolbar_stub.load_calls + 1
    me_toolbar_stub.last_path = path
end
package.preload['me_toolbar'] = function() return me_toolbar_stub end

-- Mission.TheatreOfWarData stub for file_new map validation.
package.preload['Mission.TheatreOfWarData'] = function()
    return {
        verifyTheatreOfWar = function(name)
            return name == 'Caucasus' or name == 'Syria' or name == 'Nevada'
        end,
        getTheatresOfWar = function()
            return {
                { name = 'Caucasus' },
                { name = 'Syria' },
                { name = 'Nevada' },
            }
        end,
    }
end

local coal_stub = { default_calls = 0, last_theatre = nil }
function coal_stub.setDefaultCoalitions() coal_stub.default_calls = coal_stub.default_calls + 1 end
function coal_stub.selectTheatreOfWar(name, _flag) coal_stub.last_theatre = name end
package.preload['Mission.CoalitionController'] = function() return coal_stub end

local pb_stub = { calls = 0, last_fn = nil }
function pb_stub.setUpdateFunction(fn)
    pb_stub.calls = pb_stub.calls + 1
    pb_stub.last_fn = fn
end
package.preload['ProgressBarDialog'] = function() return pb_stub end

-- Menubar + utilities + MeSettings stubs.
local menubar_stub = { last_filename = nil }
function menubar_stub.setFileName(n) menubar_stub.last_filename = n end
package.preload['me_menubar'] = function() return menubar_stub end

package.preload['me_utilities'] = function()
    return { extractFileName = function(path)
        return path:match('([^/\\]+)$') or path
    end }
end

local mesettings_stub = { last_path = nil }
function mesettings_stub.setMissionPath(p) mesettings_stub.last_path = p end
package.preload['MeSettings'] = function() return mesettings_stub end

-- Stubs for sibling verb modules pulled in by the aggregator.
package.preload['terrain']      = function() return { GetSurfaceType = function() return 'sea' end } end
package.preload['utils_common'] = function() return { actions = {} } end
package.preload['me_db_api']    = function() return { templates = {}, unit_by_type = {} } end
package.preload['me_payload']   = function() return { setDefaultLivery = function() end } end
package.preload['me_route']     = function()
    return { isAirfieldWaypoint = function() return false end,
             attractToAirfield = function() end, update = function() end }
end
package.preload['me_parking']   = function()
    return { getStandList = function() return {} end,
             getRightParkingAirport = function(s) return s end }
end
package.preload['me_predicates'] = function() return { rulesDescr = {} } end
package.preload['me_trigrules']  = function() return { actionsDescr = {}, triggersDescr = {} } end
package.preload['dictionary']    = function() return { fixDict = function() end, getValueDict = function() end } end
package.preload['Mission.TriggerZoneData'] = function() return { getTriggerZoneIds = function() return {} end, getTriggerZoneName = function() end } end
package.preload['Mission.AirdromeController'] = function() return { getAirdromes = function() return {} end } end
package.preload['me_draw_panel'] = function() return { saveToMission = function() return { layers = {} } end, loadFromMission = function() end, getObjects = function() return {} end, objectDelete = function() end } end
package.preload['dcs_sms_me.warehouse_ops'] = function() return { extract = function() end, apply = function() end, _deep_copy = function(t) return t end } end

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
    mock.mission_modified = false
    mock.saved_path = nil
    mock.save_calls = 0
    mock.save_should_fail = false
    mock.save_should_throw = false
    mock.is_empty = true
    mock.unselect_calls = 0
    mock.show_calls = 0
    mock.init_terrain_calls = 0
    mock.create_new_mission_calls = 0
    me_toolbar_stub.load_calls = 0
    me_toolbar_stub.last_path = nil
    coal_stub.default_calls = 0
    coal_stub.last_theatre = nil
    pb_stub.calls = 0
    pb_stub.last_fn = nil
    menubar_stub.last_filename = nil
    mesettings_stub.last_path = nil
end

-- ============================================================
-- file_open
-- ============================================================

local function test_open_happy()
    reset()
    local r = verbs.file_open({ path = 'C:/missions/test.miz' })
    assert_true(r.ok, 'open: ok')
    assert_eq(r.path, 'C:/missions/test.miz', 'open: returns path')
    assert_eq(me_toolbar_stub.load_calls, 1, 'open: loadMission called once')
    assert_eq(me_toolbar_stub.last_path, 'C:/missions/test.miz', 'open: path passed')
end

local function test_open_arg_validation()
    reset()
    assert_false(verbs.file_open(nil).ok, 'open: nil')
    assert_false(verbs.file_open({}).ok, 'open: missing path')
    assert_false(verbs.file_open({ path = '' }).ok, 'open: empty path')
    assert_false(verbs.file_open({ path = 123 }).ok, 'open: numeric path')
end

-- ============================================================
-- file_new
-- ============================================================

local function test_new_happy()
    reset()
    local r = verbs.file_new({ map = 'Caucasus' })
    assert_true(r.ok, 'new: ok')
    assert_eq(r.map, 'Caucasus', 'new: map')
    assert_eq(r.async, true, 'new: async flag')
    assert_eq(coal_stub.default_calls, 1, 'new: setDefaultCoalitions called')
    assert_eq(coal_stub.last_theatre, 'Caucasus', 'new: selectTheatreOfWar called')
    assert_eq(pb_stub.calls, 1, 'new: ProgressBarDialog scheduled')
    -- The scheduled function shouldn't run synchronously
    assert_eq(mock.init_terrain_calls, 0, 'new: initTerrain deferred (not yet called)')
end

local function test_new_unknown_map()
    reset()
    local r = verbs.file_new({ map = 'Atlantis' })
    assert_false(r.ok, 'new unknown map: refused')
    assert_contains(r.error, 'unknown map', 'new: error msg')
    assert_eq(#r.available_maps, 3, 'new unknown: available_maps surfaced')
end

local function test_new_refuses_dirty_mission()
    reset()
    mock.is_empty = false
    mock.mission_modified = true
    local r = verbs.file_new({ map = 'Caucasus' })
    assert_false(r.ok, 'new dirty: refused')
    assert_contains(r.error, 'unsaved changes', 'new dirty: error msg')
end

local function test_new_force_discards_dirty()
    reset()
    mock.is_empty = false
    mock.mission_modified = true
    local r = verbs.file_new({ map = 'Caucasus', force = true })
    assert_true(r.ok, 'new force: ok despite dirty')
end

local function test_new_empty_mission_skips_dirty_check()
    reset()
    mock.is_empty = true
    mock.mission_modified = true  -- modified but empty → still OK
    local r = verbs.file_new({ map = 'Caucasus' })
    assert_true(r.ok, 'new empty+modified: ok')
end

local function test_new_arg_validation()
    reset()
    assert_false(verbs.file_new(nil).ok, 'new: nil')
    assert_false(verbs.file_new({}).ok, 'new: missing map')
    assert_false(verbs.file_new({ map = '' }).ok, 'new: empty map')
end

local function test_new_scheduled_function_does_work()
    -- Invoke the deferred update function manually to verify the steps it
    -- would run on a later UpdateManager tick.
    reset()
    verbs.file_new({ map = 'Syria' })
    assert_true(type(pb_stub.last_fn) == 'function', 'new: deferred fn captured')
    pb_stub.last_fn()
    assert_eq(mock.init_terrain_calls, 1, 'deferred: initTerrain called')
    assert_eq(mock.create_new_mission_calls, 1, 'deferred: create_new_mission called')
    assert_eq(mock.show_calls, 1, 'deferred: MapWindow.show called')
end

-- ============================================================
-- file_save
-- ============================================================

local function test_save_happy()
    reset()
    mock.saved_path = 'C:/missions/test.miz'
    mock.mission.path = 'C:/missions/test.miz'
    local r = verbs.file_save({})
    assert_true(r.ok, 'save: ok')
    assert_eq(r.path, 'C:/missions/test.miz', 'save: path returned')
    assert_eq(r.reopen, true, 'save: reopen default true')
    assert_eq(mock.save_calls, 1, 'save: save_mission_safe called')
    -- reopen=true → unselect + show called
    assert_eq(mock.unselect_calls, 1, 'save reopen: unselectAll pre-save')
    assert_eq(mock.show_calls, 1, 'save reopen: MapWindow.show post-save')
end

local function test_save_no_reopen()
    reset()
    mock.saved_path = 'C:/missions/test.miz'
    mock.mission.path = 'C:/missions/test.miz'
    local r = verbs.file_save({ reopen = false })
    assert_true(r.ok, 'save no_reopen: ok')
    assert_eq(r.reopen, false, 'save: reopen=false')
    -- no_reopen → skip selection cleanup + skip show; trigger menubar refresh
    assert_eq(mock.unselect_calls, 0, 'save no_reopen: unselectAll skipped')
    assert_eq(mock.show_calls, 0, 'save no_reopen: show skipped')
    assert_eq(menubar_stub.last_filename, 'test.miz',
              'save no_reopen: menubar manually refreshed')
end

local function test_save_no_saved_path_refused()
    reset()
    mock.saved_path = nil
    local r = verbs.file_save({})
    assert_false(r.ok, 'save no path: refused')
    assert_contains(r.error, 'save-as', 'save no path: suggests save-as')
end

local function test_save_save_returns_false()
    reset()
    mock.saved_path = 'C:/x.miz'
    mock.mission.path = 'C:/x.miz'
    mock.save_should_fail = true
    local r = verbs.file_save({})
    assert_false(r.ok, 'save returns false: surfaced')
    assert_contains(r.error, 'save failed', 'save returns false: error msg')
end

local function test_save_save_throws()
    reset()
    mock.saved_path = 'C:/x.miz'
    mock.mission.path = 'C:/x.miz'
    mock.save_should_throw = true
    local r = verbs.file_save({})
    assert_false(r.ok, 'save throws: surfaced')
    assert_contains(r.error, 'reopen=false', 'save throws: suggests --reopen=false')
end

-- ============================================================
-- file_save_as
-- ============================================================

local function test_save_as_happy()
    reset()
    local r = verbs.file_save_as({ path = 'C:/new.miz' })
    assert_true(r.ok, 'save_as: ok')
    assert_eq(r.path, 'C:/new.miz', 'save_as: path returned')
    assert_eq(mesettings_stub.last_path, 'C:/new.miz',
              'save_as: MeSettings.setMissionPath called')
end

local function test_save_as_no_reopen_updates_mission_path()
    reset()
    local r = verbs.file_save_as({ path = 'C:/new.miz', reopen = false })
    assert_true(r.ok, 'save_as no_reopen: ok')
    assert_eq(mock.mission.path, 'C:/new.miz',
              'save_as no_reopen: mission.path set manually')
    assert_eq(menubar_stub.last_filename, 'new.miz',
              'save_as no_reopen: menubar refreshed manually')
end

local function test_save_as_arg_validation()
    reset()
    assert_false(verbs.file_save_as(nil).ok, 'save_as: nil')
    assert_false(verbs.file_save_as({}).ok, 'save_as: missing path')
    assert_false(verbs.file_save_as({ path = '' }).ok, 'save_as: empty path')
end

-- ============================================================
-- Test runner
-- ============================================================

local tests = {
    test_open_happy,
    test_open_arg_validation,
    test_new_happy,
    test_new_unknown_map,
    test_new_refuses_dirty_mission,
    test_new_force_discards_dirty,
    test_new_empty_mission_skips_dirty_check,
    test_new_arg_validation,
    test_new_scheduled_function_does_work,
    test_save_happy,
    test_save_no_reopen,
    test_save_no_saved_path_refused,
    test_save_save_returns_false,
    test_save_save_throws,
    test_save_as_happy,
    test_save_as_no_reopen_updates_mission_path,
    test_save_as_arg_validation,
}

for _, t in ipairs(tests) do t() end

print(string.format('test_verbs_file: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
