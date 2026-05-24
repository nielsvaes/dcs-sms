-- test_bridge_gen_counter.lua — verify the generation-counter guard in
-- bridge.lua so dev-reload doesn't end up with multiple bridges racing
-- on the same inbox / heartbeat files. See bridge.lua for the bug
-- explanation; this test exercises the contract from outside.

local here = (arg and arg[0] and arg[0]:match('^(.*[\\/])')) or './'

-- ============================================================
-- Stubs for everything bridge.lua requires
-- ============================================================

-- UpdateManager: collect callbacks into a list so the test can drive them
-- manually instead of relying on a real per-frame loop.
local ticks_registered = {}
package.preload['UpdateManager'] = function()
    return {
        add = function(fn) table.insert(ticks_registered, fn) end,
    }
end

-- log: capture lines via a simple sink. bridge.lua calls log.write(tag, level, msg).
local log_lines = {}
_G.log = {
    INFO = 1, WARNING = 2, ERROR = 3,
    write = function(_, _, msg) table.insert(log_lines, msg) end,
}

-- lfs / io / os: in-memory write_atomic so write_heartbeat doesn't need
-- a real filesystem. We track every "successful" write keyed by path so
-- the test can count heartbeats.
local writes = {}
_G.lfs = {
    writedir = function() return 'C:/fake-saved-games/' end,
    mkdir = function() return true end,
    dir = function() return function() return nil end end,  -- empty iterator
    attributes = function() return nil end,
}

-- Override io.open only for files under the fake saved-games dir so we
-- don't break Lua's runtime io for printing.
local real_open = io.open
local function fake_open(path, mode)
    if path:find('fake%-saved%-games', 1) and (mode == 'wb' or mode == 'w') then
        return {
            write = function(_, data) writes[path] = data end,
            close = function() end,
        }
    end
    return real_open(path, mode)
end
io.open = fake_open

-- os.rename: pretend tmp → final always succeeds for our fake paths.
local real_rename = os.rename
os.rename = function(a, b)
    if writes[a] then writes[b] = writes[a]; writes[a] = nil; return true end
    return real_rename(a, b)
end
os.remove = function() return true end

-- version: bridge requires 'dcs_sms_me.version' for the heartbeat. We don't
-- need the real one; a string is enough.
package.preload['dcs_sms_me.version'] = function() return '0.test.0' end

-- Make the bridge's external-execution gate true so its execute_gui path
-- would proceed (we don't actually exercise it here, but matches reality).
_G.DCS_SMS_GUI_BRIDGE_ENABLED = true

package.path = here .. '../lua/?.lua;' .. here .. '../lua/?/init.lua;' .. package.path

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

local function reset_state()
    ticks_registered = {}
    log_lines = {}
    writes = {}
    package.loaded['dcs_sms_me.bridge'] = nil
    _G.DCS_SMS_BRIDGE_GEN = nil
end

-- ============================================================
-- The tests
-- ============================================================

local function test_first_install_bumps_gen_to_1()
    reset_state()
    local bridge = require('dcs_sms_me.bridge')
    bridge.install()
    assert_eq(_G.DCS_SMS_BRIDGE_GEN, 1, 'gen is 1 after first install')
    assert_eq(#ticks_registered, 1, 'tick registered with UpdateManager')
end

-- Path-fuzzy helpers because bridge.lua builds paths with `\\` separators
-- and we don't want the test to lock the exact slash mix in.
local function heartbeat_written()
    for path, _ in pairs(writes) do
        if path:find('me.json', 1, true) and not path:find('%.tmp$') then
            return true
        end
    end
    return false
end
local function clear_heartbeat()
    for path, _ in pairs(writes) do
        if path:find('me.json', 1, true) then writes[path] = nil end
    end
end

-- The tick only writes a heartbeat every HEARTBEAT_EVERY_TICKS (30) calls
-- against its own STATE counter. install() also writes one synchronously,
-- so we have to tick at least 30 times for an extra heartbeat to appear.
local function tick_n(fn, n)
    for _ = 1, n do fn() end
end

local function test_reload_bumps_gen_and_silences_old_tick()
    reset_state()
    -- First "DCS startup": load + install. install() writes the first
    -- heartbeat synchronously.
    local bridge1 = require('dcs_sms_me.bridge')
    bridge1.install()
    local tick_a = ticks_registered[1]
    assert_true(type(tick_a) == 'function', 'first tick captured')
    assert_eq(_G.DCS_SMS_BRIDGE_GEN, 1, 'gen 1 after first install')
    assert_true(heartbeat_written(), 'install() wrote initial heartbeat')

    -- Sanity: ticking the (only) bridge 35 times triggers a heartbeat
    -- rewrite once the local STATE.tick crosses HEARTBEAT_EVERY_TICKS.
    clear_heartbeat()
    tick_n(tick_a, 35)
    assert_true(heartbeat_written(),
        'first bridge wrote a heartbeat after 35 ticks (sanity)')

    -- Now simulate dev-reload: clear package.loaded, require again, install
    -- again. The OLD tick stays in ticks_registered (UpdateManager has no
    -- remove API we use); the gen counter is what stops it from doing work.
    package.loaded['dcs_sms_me.bridge'] = nil
    local bridge2 = require('dcs_sms_me.bridge')
    bridge2.install()
    local tick_b = ticks_registered[2]
    assert_true(type(tick_b) == 'function', 'second tick captured')
    assert_true(tick_a ~= tick_b, 'reload produced a distinct tick function')
    assert_eq(_G.DCS_SMS_BRIDGE_GEN, 2, 'gen bumped to 2 after reload')

    -- After the new install, the old tick must stay silent forever no
    -- matter how many times we call it: no new heartbeat, no log line.
    clear_heartbeat()
    local lines_before = #log_lines
    local rv = tick_a()
    assert_false(rv, 'old tick returns false (stays registered, but quiet)')
    tick_n(tick_a, 100)
    assert_false(heartbeat_written(),
        'old tick wrote no heartbeat after newer gen took over (100 ticks)')
    assert_eq(#log_lines, lines_before,
        'old tick produced no new log lines after gen took over')

    -- The new tick is the only one that should still drive heartbeats.
    clear_heartbeat()
    tick_n(tick_b, 35)
    assert_true(heartbeat_written(),
        'new tick wrote a heartbeat as the active generation')
end

local function test_three_reloads_only_newest_is_active()
    reset_state()
    -- Stack three installs in a row.
    local bridges = {}
    for _ = 1, 3 do
        package.loaded['dcs_sms_me.bridge'] = nil
        local b = require('dcs_sms_me.bridge')
        b.install()
        table.insert(bridges, b)
    end
    assert_eq(_G.DCS_SMS_BRIDGE_GEN, 3, 'gen reaches 3 after three installs')
    assert_eq(#ticks_registered, 3, 'three ticks registered total')

    -- Older two ticks must both be silent; only the newest writes.
    for i = 1, 2 do
        clear_heartbeat()
        tick_n(ticks_registered[i], 100)
        assert_false(heartbeat_written(),
            'older tick ' .. i .. ' is silent across 100 calls')
    end
    clear_heartbeat()
    tick_n(ticks_registered[3], 35)
    assert_true(heartbeat_written(),
        'newest tick (gen 3) still writes the heartbeat')
end

-- ============================================================
-- Test runner
-- ============================================================

local tests = {
    test_first_install_bumps_gen_to_1,
    test_reload_bumps_gen_and_silences_old_tick,
    test_three_reloads_only_newest_is_active,
}

for _, t in ipairs(tests) do t() end

print(string.format('test_bridge_gen_counter: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
