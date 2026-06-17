-- test_sms_grid.lua — unit tests for the shared sortable-grid helper
-- (dcs_sms_me/sms_grid.lua, GH#75).
--
-- The dxgui Grid/GridHeaderCell globals and the skin modules are stubbed so we
-- can assert the plumbing logic (skin application, header build, the asc/desc
-- toggle state machine, the ▲/▼ re-text) without a running ME.

package.path = '../lua/?.lua;../lua/dcs_sms_me/?.lua;' .. package.path

-- ── stub the skin modules sms_grid requires ─────────────────────────────────
local scrollbars_calls = {}
package.preload['dcs_sms_me.skin_helper'] = function()
    return { apply = function(widget, name) widget._skin = name end }
end
package.preload['dcs_sms_me.sms_skins'] = function()
    return { grid = function() return { _grid_skin = true } end,
             grid_header = function() return { _header_skin = true } end }
end
package.preload['dcs_sms_me.sms_scrollbars'] = function()
    return { apply = function(sk, opts) sk._scrollbars = opts
                                        scrollbars_calls[#scrollbars_calls + 1] = opts end }
end

-- ── stub the dxgui globals ──────────────────────────────────────────────────
local function new_grid()
    local g = { _cols = {} }
    function g:setSkin(s) self._skin = s end
    function g:insertColumn(w, hc) self._cols[#self._cols + 1] = { width = w, hc = hc } end
    return g
end
Grid = { new = function() return new_grid() end }

local function new_header()
    local h = {}
    function h:setText(t) self._text = t end
    function h:addChangeCallback(fn) self._cb = fn end
    return h
end
GridHeaderCell = { new = function() return new_header() end }

local sms_grid = require('dcs_sms_me.sms_grid')

-- ── tiny harness ────────────────────────────────────────────────────────────
local passed, failed, errors = 0, 0, {}
local function assert_eq(actual, expected, name)
    if actual == expected then passed = passed + 1
    else failed = failed + 1
        table.insert(errors, string.format('%s: expected %s, got %s',
            name, tostring(expected), tostring(actual)))
    end
end
local function assert_true(c, name) assert_eq(c and true or false, true, name) end

local COLS = {
    { key = 'name',  label = 'Name',  width = 150 },
    { key = 'count', label = '#',     width = 38  },
}

-- ── build_grid ──────────────────────────────────────────────────────────────
local function test_build_grid_plain()
    scrollbars_calls = {}
    local g = sms_grid.build_grid()
    assert_true(g ~= nil, 'build_grid: returns a grid')
    assert_true(g._skin and g._skin._grid_skin == true, 'build_grid: applied house grid skin')
    assert_eq(#scrollbars_calls, 0, 'build_grid: no scrollbar refinement by default')
end

local function test_build_grid_nil_without_runtime()
    local saved = Grid
    Grid = nil
    local g = sms_grid.build_grid()
    Grid = saved
    assert_eq(g, nil, 'build_grid: returns nil when the Grid global is absent')
end

local function test_build_grid_scrollbars()
    scrollbars_calls = {}
    local g = sms_grid.build_grid({ scrollbars = { refine_horz = false } })
    assert_eq(#scrollbars_calls, 1, 'build_grid: scrollbars applied when requested')
    assert_eq(scrollbars_calls[1].refine_horz, false, 'build_grid: passes scrollbar opts through')
    assert_true(g._skin._scrollbars ~= nil, 'build_grid: refinement landed on the grid skin')
end

-- ── wire_sortable_headers ───────────────────────────────────────────────────
local function test_wire_builds_columns()
    local g = sms_grid.build_grid()
    local headers = sms_grid.wire_sortable_headers(g, COLS, {
        get_sort = function() return nil, nil end,
        on_sort  = function() end,
    })
    assert_eq(#headers, 2, 'wire: one header per column')
    assert_eq(headers[1].key, 'name', 'wire: header key preserved')
    assert_eq(headers[1].hc._text, 'Name', 'wire: header labelled')
    assert_eq(headers[1].hc._skin, 'sms_grid_header', 'wire: header skin applied')
    assert_eq(#g._cols, 2, 'wire: both columns inserted into grid')
    assert_eq(g._cols[2].width, 38, 'wire: column width forwarded')
end

local function test_toggle_state_machine()
    local state = { key = nil, dir = nil }
    local g = sms_grid.build_grid()
    local headers = sms_grid.wire_sortable_headers(g, COLS, {
        get_sort = function() return state.key, state.dir end,
        on_sort  = function(k, d) state.key, state.dir = k, d end,
    })
    -- click 'name' (was unsorted) → name asc
    headers[1].hc._cb()
    assert_eq(state.key, 'name', 'toggle: new column selected')
    assert_eq(state.dir, 'asc', 'toggle: new column ascending')
    -- click 'name' again → desc
    headers[1].hc._cb()
    assert_eq(state.dir, 'desc', 'toggle: same column flips to desc')
    -- click 'name' a third time → back to asc
    headers[1].hc._cb()
    assert_eq(state.dir, 'asc', 'toggle: same column flips back to asc')
    -- click 'count' → switches key, resets to asc
    headers[2].hc._cb()
    assert_eq(state.key, 'count', 'toggle: switching column changes key')
    assert_eq(state.dir, 'asc', 'toggle: switching column resets to asc')
end

local function test_is_sortable_opt_out()
    local CHK = {
        { key = 'check', label = '', width = 28 },
        { key = 'name',  label = 'Name', width = 130 },
    }
    local g = sms_grid.build_grid()
    local headers = sms_grid.wire_sortable_headers(g, CHK, {
        get_sort    = function() return nil, nil end,
        on_sort     = function() end,
        is_sortable = function(col) return col.key ~= 'check' end,
    })
    assert_eq(headers[1].hc._cb, nil, 'is_sortable: check column has no sort callback')
    assert_eq(headers[1].hc._skin, 'sms_grid_header', 'is_sortable: non-sortable column still skinned')
    assert_eq(headers[1].hc._text, '', 'is_sortable: non-sortable column still labelled')
    assert_true(headers[2].hc._cb ~= nil, 'is_sortable: other columns stay sortable')
    assert_eq(#g._cols, 2, 'is_sortable: all columns still inserted')
end

-- A column whose GridHeaderCell.new() fails to produce a cell is skipped
-- entirely (no header, no insertColumn) rather than crashing the build.
local function test_wire_tolerates_header_build_failure()
    local saved = GridHeaderCell
    GridHeaderCell = { new = function() return nil end }
    local g = sms_grid.build_grid()
    local headers = sms_grid.wire_sortable_headers(g, COLS, {
        get_sort = function() return nil, nil end,
        on_sort  = function() end,
    })
    GridHeaderCell = saved
    assert_eq(#headers, 0, 'wire: skips columns whose header cell fails to build')
    assert_eq(#g._cols, 0, 'wire: no columns inserted when header build fails')
end

-- ── update_header_labels ────────────────────────────────────────────────────
local function test_header_labels_arrows()
    local g = sms_grid.build_grid()
    local headers = sms_grid.wire_sortable_headers(g, COLS, {
        get_sort = function() return nil, nil end,
        on_sort  = function() end,
    })
    sms_grid.update_header_labels(headers, 'name', 'asc')
    assert_eq(headers[1].hc._text, 'Name \226\150\178', 'labels: asc column gets ▲')
    assert_eq(headers[2].hc._text, '#', 'labels: inactive column unchanged')
    sms_grid.update_header_labels(headers, 'count', 'desc')
    assert_eq(headers[2].hc._text, '# \226\150\188', 'labels: desc column gets ▼')
    assert_eq(headers[1].hc._text, 'Name', 'labels: previously-active column reverts to plain')
end

local tests = {
    test_build_grid_plain,
    test_build_grid_nil_without_runtime,
    test_build_grid_scrollbars,
    test_wire_builds_columns,
    test_toggle_state_machine,
    test_is_sortable_opt_out,
    test_wire_tolerates_header_build_failure,
    test_header_labels_arrows,
}
for _, t in ipairs(tests) do t() end

print(string.format('test_sms_grid: %d passed, %d failed', passed, failed))
for _, e in ipairs(errors) do print('  FAIL: ' .. e) end
os.exit(failed == 0 and 0 or 1)
