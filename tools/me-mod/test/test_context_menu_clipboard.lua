package.path = package.path .. ';../lua/?.lua;../lua/?/init.lua'

local function check(l, ok) if ok then io.write('PASS ', l, '\n') else io.write('FAIL ', l, '\n'); os.exit(1) end end

-- Case 1: Gui.setClipboard takes priority.
do
    package.loaded['dcs_sms_me.context_menu'] = nil
    local captured
    _G.Gui = { setClipboard = function(s) captured = s; return true end }
    _G.dxgui = nil
    package.preload['Input'] = function() return { setClipboard = function() error('should not be called') end } end
    local cm = require('dcs_sms_me.context_menu')
    local ok = cm._copy_to_clipboard('hello')
    check('Gui.setClipboard chosen', ok == true and captured == 'hello')
    _G.Gui = nil
    package.preload['Input'] = nil
end

-- Case 2: falls back to dxgui.setClipboard when Gui absent.
do
    package.loaded['dcs_sms_me.context_menu'] = nil
    local captured
    _G.Gui = nil
    _G.dxgui = { setClipboard = function(s) captured = s; return true end }
    local cm = require('dcs_sms_me.context_menu')
    local ok = cm._copy_to_clipboard('world')
    check('dxgui.setClipboard chosen', ok == true and captured == 'world')
    _G.dxgui = nil
end

-- Case 3: all four strategies fail -> returns false.
do
    package.loaded['dcs_sms_me.context_menu'] = nil
    _G.Gui, _G.dxgui = nil, nil
    package.preload['Input'] = function() error('no module') end
    -- Force os.execute to fail by returning non-zero.
    local real_execute = os.execute
    os.execute = function() return 1 end
    local cm = require('dcs_sms_me.context_menu')
    local ok = cm._copy_to_clipboard('x')
    check('all-fail returns false', ok == false)
    os.execute = real_execute
    package.preload['Input'] = nil
end

-- Snippet shape check (pure-string, no dxgui needed).
do
    package.loaded['dcs_sms_me.context_menu'] = nil
    local cm = require('dcs_sms_me.context_menu')
    local s = cm._build_place_snippet('My Prefab')
    check('snippet contains call', s:match('sms%.prefab%.place') ~= nil)
    check('snippet quotes name',   s:match('"My Prefab"') ~= nil)
    check('snippet has anchor',    s:match('{x = 0, y = 0}') ~= nil)
end

-- Regression guard: build_menu must attach click handlers as item.func and
-- dispatch via onChange(item) (matches DCS Menu contract — see menu.lua:58).
-- Earlier code used onChange(label) + a by_label map, which silently no-op'd
-- every click because DCS passes the item table, not a string.
do
    package.loaded['dcs_sms_me.context_menu'] = nil

    -- Fake MenuItem: a plain table with :setText that stores the label.
    package.preload['MenuItem'] = function()
        return {
            new = function()
                return { setText = function(self, t) self.text = t end }
            end,
        }
    end

    -- Fake Menu: collects inserted items; onChange is monkey-patched by
    -- build_menu itself, so we just need :insertItem + a table to attach to.
    local fake_menu_mt = {}
    fake_menu_mt.__index = fake_menu_mt
    function fake_menu_mt:insertItem(it)
        self._items = self._items or {}
        self._items[#self._items + 1] = it
    end
    package.preload['Menu'] = function()
        return {
            new = function() return setmetatable({}, fake_menu_mt) end,
        }
    end

    _G.Gui = { setClipboard = function() return true end }

    local cm = require('dcs_sms_me.context_menu')

    -- Three entries with distinct hooks.
    local clicked = {}
    local entries = {
        { label = 'Alpha', visible = true,  on_click = function() clicked.alpha = true end },
        { label = '--',    visible = true,  on_click = function() clicked.sep   = true end },
        { label = 'Hidden', visible = false, on_click = function() clicked.hidden = true end },
        { label = 'Beta',  visible = true,  on_click = function() clicked.beta  = true end },
    }

    local menu = cm._build_menu(entries)
    check('build_menu returned a menu', menu ~= nil)
    check('build_menu honored visibility filter', #menu._items == 3)

    -- Each item must carry a func field (the click handler).
    for _, it in ipairs(menu._items) do
        check('item ' .. tostring(it.text) .. ' has func', type(it.func) == 'function')
    end

    -- Firing onChange(item) must dispatch to that item's func — this is the
    -- exact regression: pre-fix, onChange got a label string and the lookup
    -- silently no-op'd. Now it gets the item table and dispatches via .func.
    menu:onChange(menu._items[1])  -- Alpha
    check('onChange(item) dispatches Alpha', clicked.alpha == true)
    menu:onChange(menu._items[3])  -- Beta (separator was [2])
    check('onChange(item) dispatches Beta', clicked.beta == true)
    -- Separator's no-op func runs without error.
    menu:onChange(menu._items[2])
    check('separator no-op runs cleanly', clicked.sep == true)

    package.preload['Menu'] = nil
    package.preload['MenuItem'] = nil
    _G.Gui = nil
end

-- File-row menu must offer Update / Move / Rename / Delete on normal rows,
-- each wired to its hook with the row. On error rows everything hides except
-- Delete (cleaning up a broken file) and Show in Explorer, and the menu must
-- collapse to a single separator (the divider above Show in Explorer).
do
    package.loaded['dcs_sms_me.context_menu'] = nil
    local cm = require('dcs_sms_me.context_menu')

    local function find(entries, label)
        for _, e in ipairs(entries) do if e.label == label then return e end end
        return nil
    end

    local updated, renamed, deleted
    local row = { name = 'Tomcats', path = '/x/Tomcats.prefab', folder = 'CAP' }
    local entries = cm._file_row_entries(row, {
        on_update = function(r) updated = r end,
        on_rename = function(r) renamed = r end,
        on_delete = function(r) deleted = r end,
    })

    local upd = find(entries, 'Update Prefab with selection')
    check('update entry present on normal row', upd ~= nil and upd.visible ~= false)
    if upd then upd.on_click() end
    check('update entry fires on_update with row', updated == row)

    local ren = find(entries, 'Rename')
    check('rename entry present + visible on normal row', ren ~= nil and ren.visible ~= false)
    if ren then ren.on_click() end
    check('rename entry fires on_rename with row', renamed == row)

    local del = find(entries, 'Delete')
    check('delete entry present + visible on normal row', del ~= nil and del.visible ~= false)
    if del then del.on_click() end
    check('delete entry fires on_delete with row', deleted == row)

    local erow = { name = 'Broken', path = '/x/Broken.prefab', error = 'boom' }
    local ee = cm._file_row_entries(erow, {})
    check('update hidden on error row',   find(ee, 'Update Prefab with selection').visible == false)
    check('move hidden on error row',     find(ee, 'Move to...').visible == false)
    check('rename hidden on error row',   find(ee, 'Rename').visible == false)
    check('delete visible on error row',  find(ee, 'Delete').visible == true)
    check('show-in-explorer visible on error row', find(ee, 'Show in Explorer').visible ~= false)
    local nsep = 0
    for _, e in ipairs(ee) do if e.separator and e.visible ~= false then nsep = nsep + 1 end end
    check('error row collapses to a single separator', nsep == 1)
end

-- Tree-node menu: the import-managed Community node hides New subfolder +
-- Rename but keeps Delete (removing downloads is allowed). Normal folders show
-- all; the root hides Rename/Delete.
do
    package.loaded['dcs_sms_me.context_menu'] = nil
    local cm = require('dcs_sms_me.context_menu')
    local function find(entries, label)
        for _, e in ipairs(entries) do if e.label == label then return e end end
        return nil
    end

    local comm = cm._tree_node_entries({ path = 'Community' }, {})
    check('Community hides New subfolder', find(comm, 'New subfolder').visible == false)
    check('Community hides Rename',        find(comm, 'Rename').visible == false)
    check('Community keeps Delete',        find(comm, 'Delete').visible == true)

    local sub = cm._tree_node_entries({ path = 'Community/CAP' }, {})
    check('Community subfolder hides New subfolder', find(sub, 'New subfolder').visible == false)

    local normal = cm._tree_node_entries({ path = 'CAP' }, {})
    check('normal folder shows New subfolder', find(normal, 'New subfolder').visible == true)
    check('normal folder shows Rename',        find(normal, 'Rename').visible == true)

    local root = cm._tree_node_entries({ path = '' }, {})
    check('root shows New subfolder', find(root, 'New subfolder').visible == true)
    check('root hides Rename',        find(root, 'Rename').visible == false)
end

io.write('All context_menu clipboard tests passed.\n')
