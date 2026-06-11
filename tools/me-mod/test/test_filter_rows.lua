-- Smoke test for window.filter_rows: pure substring filter over rows by
-- name + theatre, case-insensitive. The window module pulls in dxgui
-- bindings that don't exist in this test VM, so we stub them via
-- package.preload before requiring it — same pattern as smoke_menu.lua.

package.path = package.path
    .. ';./?.lua;./?/init.lua'
    .. ';../lua/?.lua;../lua/?/init.lua'

local stub_widget = function()
    local M = {}
    M.new = function() return setmetatable({}, { __index = function() return function() end end }) end
    return M
end

package.preload['Window']         = stub_widget
package.preload['Static']         = stub_widget
package.preload['Button']         = stub_widget
package.preload['EditBox']        = stub_widget
package.preload['TextBox']        = stub_widget
package.preload['Grid']           = stub_widget
package.preload['GridHeaderCell'] = stub_widget
package.preload['Skin']           = function()
    return setmetatable({}, { __index = function() return function() return {} end end })
end
package.preload['dxgui']          = function() return { GetWindowSize = function() return 1920, 1080 end } end
package.preload['Gui']            = function() return { GetWindowSize = function() return 1920, 1080 end } end
package.preload['me_menubar']     = function() return {} end
package.preload['lfs']            = function() return { dir = function() return function() return nil end end, attributes = function() return nil end, mkdir = function() end } end

-- Stubs for module siblings that window.lua requires.
package.preload['dcs_sms_me.log']        = function() return { write = function() end, INFO = 0, ERROR = 0, WARNING = 0 } end
package.preload['dcs_sms_me.prefab_ops'] = function() return { scan_dir = function() return {} end, save_selection = function() return false, 'stub' end, exists = function() return false end } end
package.preload['dcs_sms_me.selection']  = function() return {} end
package.preload['dcs_sms_me.sms_skins']  = function()
    return {
        button = function() return nil end,
        grid = function() return nil end,
        grid_header = function() return nil end,
        icon_static = function() return nil end,
    }
end
package.preload['dcs_sms_me.undo']       = function() return { has_record = function() return false end, undo = function() return false end, capture_pre = function() end, record = function() end } end
package.preload['me_multiSelection']     = function() return {} end
package.preload['me_toolbar']            = function() return {} end

local window = require('dcs_sms_me.prefab_manager')
local filter_rows = window._filter_rows
assert(filter_rows, 'window._filter_rows not exposed')

local function pass(label) io.write('PASS ', label, '\n') end
local function eq(label, got, expected)
    if got == expected then pass(label) else
        io.write('FAIL ', label, ' got=', tostring(got), ' expected=', tostring(expected), '\n')
        os.exit(1)
    end
end

local rows = {
    { name = 'farp_alpha',    theatre = 'Caucasus' },
    { name = 'sam_site',      theatre = 'Syria' },
    { name = 'modern_mixed',  theatre = 'Caucasus' },
    { name = 'broken',        theatre = '?', error = 'load failed' },
}

local out = filter_rows(rows, '')
eq('empty filter returns all rows', #out, 4)
assert(out ~= rows, 'empty filter should return a copy, not the same table')

out = filter_rows(rows, 'farp')
eq('substring "farp" matches 1', #out, 1)
eq('  → name', out[1].name, 'farp_alpha')

out = filter_rows(rows, 'caucasus')
eq('theatre "caucasus" matches 2', #out, 2)

out = filter_rows(rows, 'CAUCASUS')
eq('case-insensitive theatre match', #out, 2)

out = filter_rows(rows, 'nope')
eq('no match returns 0', #out, 0)

out = filter_rows(rows, 'mod')
eq('substring "mod" matches modern_mixed', #out, 1)
eq('  → name', out[1].name, 'modern_mixed')

out = filter_rows(rows, 'broken')
eq('error rows are filterable by name', #out, 1)
eq('  → has error', out[1].error, 'load failed')

-- Folder-aware composition: when selected_folder is given, rows whose
-- row.folder matches the selected folder OR is a descendant (recursive
-- prefix match — clicking "Iraq" includes prefabs in "Iraq", "Iraq/FARPs",
-- "Iraq/Planes", etc.) are kept; then the text filter applies.
local compose = window._compose_filter or window._filter_rows  -- may be a new helper
if window._compose_filter then
    local sample = {
        { name = 'root_a',  folder = '',           theatre = 'Caucasus' },
        { name = 'cap_a',   folder = 'CAP',        theatre = 'Caucasus' },
        { name = 'cap_b',   folder = 'CAP',        theatre = 'Syria' },
        { name = 'cap_nested', folder = 'CAP/Tomcats', theatre = 'Caucasus' },
        { name = 'sam_a',   folder = 'SAM',        theatre = 'Caucasus' },
    }
    local function names(rows_in)
        local s = {}; for _, r in ipairs(rows_in) do s[r.name] = true end; return s
    end

    local out = compose(sample, '', '')
    eq('folder="" + text="" returns all', #out, 5)

    out = compose(sample, 'CAP', '')
    eq('folder="CAP" returns folder + descendants', #out, 3)
    local n = names(out)
    eq('  → cap_a included',      n.cap_a      == true, true)
    eq('  → cap_b included',      n.cap_b      == true, true)
    eq('  → cap_nested included', n.cap_nested == true, true)

    out = compose(sample, 'CAP', 'cap')
    eq('folder="CAP" + text narrows by name across descendants', #out, 3)

    out = compose(sample, 'CAP/Tomcats', '')
    eq('folder="CAP/Tomcats" returns just that leaf', #out, 1)
    eq('  → cap_nested', out[1].name, 'cap_nested')

    out = compose(sample, '', 'cap')
    eq('folder="" + text="cap" matches by name across all folders', #out, 3)

    -- Prefix match must use the boundary "/" — a folder "CAPLAND" must not
    -- be claimed by "CAP" selection.
    local edge = {
        { name = 'cap_a',     folder = 'CAP',     theatre = '' },
        { name = 'capland_a', folder = 'CAPLAND', theatre = '' },
    }
    out = compose(edge, 'CAP', '')
    eq('folder="CAP" does NOT spill into sibling "CAPLAND"', #out, 1)
    eq('  → cap_a only', out[1].name, 'cap_a')
end

-- build_tree: takes (folder_set, optional name_filter) and returns a nested
-- node structure. Each node = { name, path, children = {}, expanded? }.
local build_tree = window._build_tree
if build_tree then
    local folder_set = { ['']=true, ['CAP']=true, ['CAP/Tomcats']=true, ['SAM']=true, ['Empty']=true }
    local root = build_tree(folder_set, '')
    eq('root has 3 children', #root.children, 3)  -- CAP, Empty, SAM
    -- Children are sorted alphabetically.
    eq('  -> CAP first', root.children[1].name, 'CAP')
    eq('  -> Empty second', root.children[2].name, 'Empty')
    eq('  -> SAM third', root.children[3].name, 'SAM')
    eq('  -> CAP has Tomcats child', #root.children[1].children, 1)
    eq('  -> Tomcats path', root.children[1].children[1].path, 'CAP/Tomcats')

    -- name filter hides non-matching branches.
    local filtered = build_tree(folder_set, 'tom')
    eq('filter "tom" surfaces CAP (parent) only', #filtered.children, 1)
    eq('  -> CAP visible', filtered.children[1].name, 'CAP')
    eq('  -> Tomcats visible under it', #filtered.children[1].children, 1)
end

-- _listbox_tree_rows: the folder browser's ListBox-fallback row list. It must
-- prepend a synthetic root row (path '') and indent the real folders one level
-- beneath it, keeping row index aligned to folder path so ListBox selection
-- maps to the right folder. Collapsing a folder hides its children.
local listbox_rows = window._listbox_tree_rows
assert(listbox_rows, 'window._listbox_tree_rows not exposed')
do
    local folder_set = { ['']=true, ['CAP']=true, ['CAP/Tomcats']=true, ['SAM']=true, ['Empty']=true }
    local root = window._build_tree(folder_set, '')

    local rows = listbox_rows(root, {}, 'Prefabs')
    eq('row 1 is the root label',        rows[1].text, 'Prefabs')
    eq('row 1 maps to show-all path',    rows[1].path, '')
    eq('expanded tree row count',        #rows, 5)  -- Prefabs, CAP, CAP/Tomcats, Empty, SAM
    eq('row 2 path = CAP',               rows[2].path, 'CAP')
    eq('row 3 path = CAP/Tomcats',       rows[3].path, 'CAP/Tomcats')
    eq('row 4 path = Empty',             rows[4].path, 'Empty')
    eq('row 5 path = SAM',               rows[5].path, 'SAM')
    eq('CAP row indented one level',     rows[2].text:sub(1, 2), '  ')
    eq('CAP/Tomcats indented deeper',    rows[3].text:sub(1, 4), '    ')

    -- Collapsing CAP hides CAP/Tomcats and flips its glyph to the collapsed mark.
    local collapsed = listbox_rows(root, { ['CAP'] = true }, 'Prefabs')
    eq('collapsed CAP drops its child',  #collapsed, 4)  -- Prefabs, CAP, Empty, SAM
    eq('  -> CAP still present',          collapsed[2].path, 'CAP')
    eq('  -> collapsed glyph on CAP',     collapsed[2].text:find('>', 1, true) ~= nil, true)
    eq('  -> Empty now row 3',            collapsed[3].path, 'Empty')
    local has_tomcats = false
    for _, r in ipairs(collapsed) do if r.path == 'CAP/Tomcats' then has_tomcats = true end end
    eq('  -> CAP/Tomcats hidden',         has_tomcats, false)
end

-- Community folder is marked in the ListBox-fallback rows so users can tell
-- it's the import-managed folder.
do
    local fset = { ['']=true, ['CAP']=true, ['Community']=true }
    local root = window._build_tree(fset, '')
    local rows = window._listbox_tree_rows(root, {}, 'Prefabs')
    local function row_for(path) for _, r in ipairs(rows) do if r.path == path then return r end end end
    local comm = row_for('Community')
    local cap  = row_for('CAP')
    eq('Community row carries marker', comm.text:find('(downloads)', 1, true) ~= nil, true)
    eq('normal row has no marker',     cap.text:find('(downloads)', 1, true) == nil, true)
end

-- Triggers/ is the reserved trigger-prefab folder — marked as special in the
-- ListBox-fallback rows just like Community/, so it reads as auto-managed.
do
    local fset = { ['']=true, ['CAP']=true, ['Triggers']=true }
    local root = window._build_tree(fset, '')
    local rows = window._listbox_tree_rows(root, {}, 'Prefabs')
    local function row_for(path) for _, r in ipairs(rows) do if r.path == path then return r end end end
    local trig = row_for('Triggers')
    local cap  = row_for('CAP')
    eq('Triggers row carries marker', trig.text:find('(triggers)', 1, true) ~= nil, true)
    eq('normal row has no marker',    cap.text:find('(triggers)', 1, true) == nil, true)
end

io.write('All filter_rows tests passed.\n')
