-- prefab_manager.lua — Prefab Manager.
--
-- Single window, all panels visible. Constructed lazily on first show().
-- All callbacks are pcall-guarded so dxgui or DCS-API failures degrade to
-- a status-label message rather than crashing the editor.
--
-- Public:
--   M.show()    — idempotent
--   M.hide()    — idempotent
--   M.toggle()  — show if hidden, hide if shown

local Window  = require('Window')
local Static  = require('Static')
local Button  = require('Button')
local Gui     = require('dxgui')
local Skin    = require('Skin')

-- Text-input + list widgets vary slightly across DCS dxgui builds.
-- Real installs ship `EditBox` and `ListBox` under dxgui/bind/. We try
-- both `EditBox` (the canonical) and `TextBox` (an older alias seen in
-- the plan) so the module loads either way; whichever resolves becomes
-- our text-input class.
local TextBox
do
    local ok, mod = pcall(require, 'EditBox')
    if ok then TextBox = mod
    else
        local ok2, mod2 = pcall(require, 'TextBox')
        if ok2 then TextBox = mod2 end
    end
end
-- Grid + GridHeaderCell are the multi-column equivalents of ListBox. We use
-- Grid for the prefab library so each prefab's metadata gets its own column
-- (Name / Theatre / G / S / Z / D) instead of being stuffed into a single
-- formatted line. pcall-guarded so the module still loads in environments
-- where these widgets aren't bound (e.g. test VMs or older dxgui builds).
local Grid;            do local ok, mod = pcall(require, 'Grid');            if ok then Grid            = mod end end
local GridHeaderCell;  do local ok, mod = pcall(require, 'GridHeaderCell');  if ok then GridHeaderCell  = mod end end
-- ComboList renders the selected item with its OWN skin in the closed
-- display (so the coalition dot survives), unlike ComboBox which just
-- shows raw text. The ME's airplane-group c_country uses ComboList for
-- exactly this reason.
local ComboList;       do local ok, mod = pcall(require, 'ComboList');       if ok then ComboList       = mod end end
local ListBoxItem;     do local ok, mod = pcall(require, 'ListBoxItem');     if ok then ListBoxItem     = mod end end
local ToggleButton;    do local ok, mod = pcall(require, 'ToggleButton');    if ok then ToggleButton    = mod end end
local Dial;            do local ok, mod = pcall(require, 'Dial');            if ok then Dial            = mod end end
local SpinBox;         do local ok, mod = pcall(require, 'SpinBox');         if ok then SpinBox         = mod end end
local CheckBox;        do local ok, mod = pcall(require, 'CheckBox');        if ok then CheckBox        = mod end end
local UpdateManager;   do local ok, mod = pcall(require, 'UpdateManager');   if ok then UpdateManager   = mod end end
-- Native ME message-box dialog factory. Used by show_overlay so our
-- prompts get the same title bar / icons / button styling as the rest
-- of the editor (same module everything from me_toolbar to me_mission
-- requires). pcall-guarded so the module still loads under the test VM.
local MsgWindow;       do local ok, mod = pcall(require, 'MsgWindow');       if ok then MsgWindow       = mod end end

local prefab_ops = require('dcs_sms_me.prefab_ops')
local sms_window     = require('dcs_sms_me.sms_window')
local undo       = require('dcs_sms_me.undo')
local sms_skins  = require('dcs_sms_me.sms_skins')
local marquee_hook  = require('dcs_sms_me.marquee_hook')
local new_mission_hook = require('dcs_sms_me.new_mission_hook')
local airbase_detect = require('dcs_sms_me.airbase_detect')
local warehouse_ops = require('dcs_sms_me.warehouse_ops')
local version       = require('dcs_sms_me.version')
local splitter_mod  = require('dcs_sms_me.splitter')
local clearable_edit = require('dcs_sms_me.clearable_edit')
local prefab_naming = require('dcs_sms_me.prefab_naming')
local sms_scrollbars = require('dcs_sms_me.sms_scrollbars')
local community_config = require('dcs_sms_me.community_config')

-- Apply a skin by name. Resolves in this order:
--   * 'sms_button' / 'sms_grid' / 'sms_grid_header' → the DCS-SMS house skins
--     built at runtime in sms_skins.lua. These give the small dark-blue
--     ADD/EDIT button look + the navy grid look (cribbed from me_DTCnew.dlg).
--   * any other name → looked up in the Skin module, which auto-generates
--     one function per entry in dxgui/skins/skinME/skin_names.lua (e.g.
--     Skin.staticSkin_ME, Skin.editBoxSkin_ME).
-- Failures (missing skin builder, widget without setSkin, runtime error)
-- degrade silently so the widget keeps its default skin.
local function try_skin(widget, skin_name)
    pcall(function()
        if not (widget and widget.setSkin) then return end
        local s
        if     skin_name == 'sms_button'      then s = sms_skins.button()
        elseif skin_name == 'sms_grid'        then s = sms_skins.grid()
        elseif skin_name == 'sms_grid_header' then s = sms_skins.grid_header()
        elseif skin_name == 'icon_warning'    then s = sms_skins.icon_static('warning')
        elseif skin_name == 'icon_question'   then s = sms_skins.icon_static('question')
        elseif skin_name == 'sms_dial'        then s = sms_skins.dial()
        elseif skin_name == 'sms_separator'   then s = sms_skins.separator()
        elseif skin_name == 'sms_status_yellow' then s = sms_skins.static_yellow()
        elseif skin_name == 'sms_status_red'    then s = sms_skins.static_red()
        elseif skin_name == 'sms_status_green'  then s = sms_skins.static_green()
        elseif skin_name == 'sms_tab'         then s = sms_skins.tab()
        elseif skin_name == 'sms_tab_off'     then s = sms_skins.tab_off()
        else
            local fn = Skin[skin_name]
            if not fn then return end
            s = fn()
        end
        if s then widget:setSkin(s) end
    end)
end

-- Apply Skin.treeViewSkin_ME() to a TreeView widget with our themed overrides
-- baked in (transparent panel interior over the window's dark blue, off-white
-- text for unselected items, teal-blue bkg for selected items). Used by both
-- the main folder tree and the Move modal's folder picker so the two stay
-- visually in lock-step.
--
-- Three gotchas this helper centralises (each verified empirically against
-- live DCS; see commit history for details):
--   * Skin shape is widget-class-specific. Applying listBoxSkin_ME to a
--     TreeView causes addNode to throw on a missing `check` sub-shape, so
--     callers MUST pass a TreeView (the ListBox fallback uses
--     listBoxSkin_ME directly via try_skin).
--   * Skin.treeViewSkin_ME() returns a fresh deep table per call, so the
--     mutations below are widget-local — they don't leak to any other
--     consumer of the same skin name.
--   * DCS's skin engine parses bkg colour fields as STRINGS at render time
--     (the .skin.lua source uses "0xRRGGBBAA"). Numeric assignments silently
--     fail to parse and fall back to widget defaults (white panel, blue
--     hover text, etc). All overrides below use string form on purpose.
local function apply_me_tree_skin(widget)
    if not widget or not widget.setSkin then return end
    pcall(function()
        local Skin_mod = require('Skin')
        local s = Skin_mod.treeViewSkin_ME and Skin_mod.treeViewSkin_ME()
        if not s or not s.skinData then return end
        -- Outer panel: stock treeViewSkin_ME paints center_center 0x6d7376ff
        -- (mid-grey); listBoxSkin_ME uses 0x00000040 — a transparent overlay
        -- that lets the window's dark blue show through. Match that so the
        -- tree interior agrees with the file grid.
        if s.skinData.states then
            for _, state_name in ipairs({'released', 'disabled'}) do
                local st = s.skinData.states[state_name]
                if st and st[1] and st[1].bkg then
                    st[1].bkg.center_center = '0x00000040'
                end
            end
        end
        -- Item sub-skin: indices 1/2 (unselected) paint text in black —
        -- unreadable on the dark window. Indices 3/4 (selected) have a
        -- 0x3c3e40ff grey bkg + off-white text. Repaint unselected text
        -- white-ish and selected bkg to the same teal-blue
        -- (0x2da1beff) sms_skins.grid uses for row selection.
        local item = s.skinData.skins and s.skinData.skins.item
        local item_sd = item and item.skinData
        local rel = item_sd and item_sd.states and item_sd.states.released
        if rel then
            if rel[1] and rel[1].text then rel[1].text.color = '0xe0dedaff' end
            if rel[2] and rel[2].text then rel[2].text.color = '0xe0dedaff' end
            if rel[3] and rel[3].bkg  then rel[3].bkg.center_center = '0x2da1beff' end
            if rel[4] and rel[4].bkg  then rel[4].bkg.center_center = '0x2da1beff' end
        end
        -- Replace the stock dark-gray scrollbars with the grid's thin
        -- modern-blue ones so the folder browser matches the file browser.
        -- The tree wants the plain grid vert+horz (no editbox-style horz
        -- refinement), so refine_horz=false.
        sms_scrollbars.apply(s, { refine_horz = false })
        widget:setSkin(s)
    end)
end

local M = {}

local W = {
    sms_window = nil,  -- the SMSWindow instance owning the chrome
    -- dxgui handles
    window     = nil,
    name_input = nil,
    save_btn   = nil,
    fixed_check     = nil,        -- "Fixed location" checkbox; sets meta.place_at_origin on save
    fixed_check_lbl = nil,
    reload_btn = nil,
    grid       = nil,
    name_label     = nil,
    search_label   = nil,
    country_label  = nil,
    rotation_label = nil,
    rotation_unit  = nil,        -- fallback "°" Static (no Dial/SpinBox path)
    sep1           = nil,
    sep2           = nil,
    rotation_input = nil,        -- legacy TextBox; only used when Dial/SpinBox unavailable
    rotation_dial  = nil,
    rotation_spin  = nil,
    rotation_deg   = 0,          -- single source of truth for the place-time rotation
    preview_id     = nil,        -- mapId of the place-pending bbox preview rectangle
    preview_data   = nil,        -- the preview rectangle's mapData (mutated on mouse-move)
    preview_offset = nil,        -- {x, y} bbox-center offset in the prefab's anchor-relative frame
    preview_cursor = nil,        -- last-known cursor world position; lets the dial re-paint without a mouse-move
    country_combo      = nil,
    country_filter_btn = nil,
    place_click_btn   = nil,
    place_origin_btn  = nil,
    rename_btn = nil,
    delete_btn = nil,
    undo_btn   = nil,

    -- runtime state
    rows           = {},        -- last scan_dir result (post-sort), source of truth
    visible_rows   = {},        -- filtered subset of rows; what the grid shows
    selected_idx   = nil,        -- index into visible_rows of currently selected row
    place_pending  = false,      -- in place-pending mode (Task 12)
    place_pending_name = nil,    -- name of prefab being placed
    sort_key       = 'name',     -- column key to sort rows by
    sort_dir       = 'asc',      -- 'asc' or 'desc'
    grid_headers   = {},         -- parallel to COLS; lets us re-text headers on sort change
    filter_text    = '',         -- live filter applied to rows → visible_rows
    filter_input   = nil,        -- TextBox widget for the filter
    pending_airbases = nil,    -- set by marquee callback; consumed by on_save_click
    marquee_subscribed = false,-- one-shot guard so Ctrl+Shift+R reloads don't multi-subscribe

    -- Folder browser state (Task 12):
    selected_folder      = '',     -- '' = nothing selected → show all recursively
    folder_filter_text   = '',     -- substring filter for the tree
    folder_tree_collapse = {},     -- map folder_path -> true if collapsed
    folder_set           = {},     -- set of all folder paths (incl. empties), refreshed on scan
    folder_tree_root     = nil,    -- root node of build_tree result
    folder_search_input  = nil,    -- EditBox widget
    folder_tree          = nil,    -- TreeView widget (or ListBox fallback)
    new_folder_btn       = nil,    -- Button widget
    show_all_btn         = nil,    -- "Show all" button — deselects the tree
    folder_tree_uses_listbox = false,  -- true when TreeView is unavailable
    splitter             = nil,    -- draggable vertical splitter between tree and grid panes
    tree_w               = 200,    -- current left-column width (was constant TREE_W; now mutable via splitter)

    -- Naming forms (placement-time renames). All sticky for the session.
    naming_name_label    = nil,
    naming_name_input    = nil,    -- clearable_edit handle
    naming_prefix_label  = nil,
    naming_prefix_input  = nil,
    naming_suffix_label  = nil,
    naming_suffix_input  = nil,
    naming_keep_num_btn  = nil,    -- ToggleButton, default ON
}

-- Column definitions for the prefab grid. Module-level so refresh_list and the
-- header-click handlers can share key + numeric-flag metadata.
local COLS = {
    { key = 'name',            label = 'Name',      width = 190, numeric = false },
    { key = 'author',          label = 'Author',    width = 110, numeric = false },
    { key = 'theatre',         label = 'Theatre',   width = 90,  numeric = false },
    { key = 'place_at_origin', label = 'Fixed Pos', width = 60,  numeric = false },
    { key = 'airbase_count',   label = 'AB',        width = 50,  numeric = true  },
    { key = 'group_count',     label = 'G',         width = 35,  numeric = true  },
    { key = 'static_count',    label = 'S',         width = 35,  numeric = true  },
    { key = 'zone_count',      label = 'Z',         width = 35,  numeric = true  },
    { key = 'drawing_count',   label = 'D',         width = 35,  numeric = true  },
}

local function find_col(key)
    for i, c in ipairs(COLS) do if c.key == key then return c, i end end
end

-- Status-bar shim. The SMSWindow base owns the live Static; we forward
-- to its :flash_status (auto-reverts after 5s, matching the previous
-- tick_status_clear behaviour) or :set_status (sticky) based on context.
-- The 'placement' severity is mapped to 'success' (green) for the new
-- API — the only call site that uses it (the PLACING/CLICK-ON-MAP
-- prompt) goes through set_status_sticky below so it persists across
-- the placement.
local SEVERITY_REMAP = {
    placement = 'success',
}

local function map_severity(sev)
    if sev == nil then return 'info' end
    return SEVERITY_REMAP[sev] or sev
end

local function set_status(text, severity)
    if not W.sms_window then return end
    W.sms_window:flash_status(tostring(text or ''), map_severity(severity))
end

-- Sticky variant for the place-pending prompt — stays until placement
-- completes or is cancelled. The original code used set_status with the
-- 'placement' severity and the tick_status_clear had a `place_pending`
-- skip; this is the cleaner equivalent.
local function set_status_sticky(text, severity)
    if not W.sms_window then return end
    W.sms_window:set_status(tostring(text or ''), map_severity(severity))
end

-- Build a Static cell widget for a Grid cell. Inline helper so the cell
-- skin and the optional tooltip are applied consistently.
local function make_cell(text, tooltip)
    local s = Static.new(tostring(text or ''))
    try_skin(s, 'staticSkin_ME')
    if tooltip and s.setTooltipText then
        pcall(function() s:setTooltipText(tostring(tooltip)) end)
    end
    return s
end

-- Stable in-place sort. Lua's table.sort isn't stable by default, so we tag
-- each row with its pre-sort index and use that as the tiebreaker.
local function sort_rows(rows, key, dir)
    local col = find_col(key)
    local numeric = col and col.numeric
    local asc = (dir ~= 'desc')
    for i, r in ipairs(rows) do r._stable_idx = i end
    table.sort(rows, function(a, b)
        -- Error rows sink to the bottom regardless of direction so they
        -- don't get scattered through the list.
        if a.error and not b.error then return false end
        if b.error and not a.error then return true end
        local av, bv = a[key], b[key]
        if numeric then
            av, bv = tonumber(av) or 0, tonumber(bv) or 0
        else
            av, bv = tostring(av or ''):lower(), tostring(bv or ''):lower()
        end
        if av == bv then return a._stable_idx < b._stable_idx end
        if asc then return av < bv else return av > bv end
    end)
    for _, r in ipairs(rows) do r._stable_idx = nil end
end

-- Re-text every header so the active column gets an arrow glyph and the rest
-- are reset back to their plain label.
local function update_header_labels()
    pcall(function()
        for i, c in ipairs(COLS) do
            local hc = W.grid_headers[i]
            if hc and hc.setText then
                local label = c.label
                if c.key == W.sort_key then
                    label = label .. (W.sort_dir == 'desc' and ' ▼' or ' ▲')
                end
                hc:setText(label)
            end
        end
    end)
end

-- Folder-aware filter composition (Task 12). Used by apply_filter and exposed
-- for tests as M._compose_filter. Selected-folder semantics:
--   nil or ''  → recursive show-all (legacy behaviour, all rows pass the
--                folder predicate).
--   'CAP'      → direct children only (rows whose r.folder == 'CAP'); nested
--                rows like 'CAP/Tomcats' are excluded.
-- The text filter applies after the folder predicate and matches name OR
-- theatre (case-insensitive plain substring), same as filter_rows.
local function compose_filter(rows, selected_folder, filter_text)
    local out = {}
    local text_lower = (filter_text or ''):lower()
    local prefix = (selected_folder ~= nil and selected_folder ~= '') and (selected_folder .. '/') or nil
    for _, r in ipairs(rows or {}) do
        local folder_ok
        if selected_folder == nil or selected_folder == '' then
            folder_ok = true  -- recursive show-all
        else
            -- Recursive: match the folder itself OR any descendant.
            -- (Earlier draft did exact-match only; the user wanted parent
            -- nodes to include all their subfolder prefabs.)
            local f = r.folder or ''
            folder_ok = (f == selected_folder) or (f:sub(1, #prefix) == prefix)
        end
        if folder_ok then
            if text_lower == '' then
                out[#out + 1] = r
            else
                local name_lower    = tostring(r.name    or ''):lower()
                local theatre_lower = tostring(r.theatre or ''):lower()
                if name_lower:find(text_lower, 1, true)
                    or theatre_lower:find(text_lower, 1, true) then
                    out[#out + 1] = r
                end
            end
        end
    end
    return out
end
M._compose_filter = compose_filter  -- exposed for tests

-- Legacy single-arg filter; kept for test backward-compat. New callers
-- should use compose_filter directly with the desired selected_folder.
local function filter_rows(rows, filter_text)
    return compose_filter(rows, nil, filter_text)
end
M._filter_rows = filter_rows

-- Build a nested tree node structure from a folder_set (map of folder
-- paths to true). Each node:
--   { name = 'CAP', path = 'CAP', children = { ...nodes... } }
-- Root node has name = '', path = '', children = top-level folder nodes.
-- If `name_filter` is non-empty, prunes nodes whose name (case-insensitive)
-- doesn't match AND have no matching descendant.
local function build_tree(folder_set, name_filter)
    name_filter = (name_filter or ''):lower()

    -- Step 1: collect all folder paths, ensure parent paths are present.
    local all = {}
    for path, _ in pairs(folder_set or {}) do
        if path ~= '' then
            all[path] = true
            -- Walk ancestors so the tree is connected even if a deep folder
            -- exists without its intermediate ancestors in folder_set.
            local p = path:match('^(.+)/[^/]+$')
            while p and p ~= '' do
                all[p] = true
                p = p:match('^(.+)/[^/]+$')
            end
        end
    end

    -- Step 2: build a map from parent path -> sorted list of direct children.
    local children_of = {}
    for path, _ in pairs(all) do
        local parent = path:match('^(.+)/[^/]+$') or ''
        children_of[parent] = children_of[parent] or {}
        local leaf = path:match('([^/]+)$')
        children_of[parent][#children_of[parent] + 1] = { name = leaf, path = path }
    end
    for _, list in pairs(children_of) do
        table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    end

    -- Step 3: recurse from root, attaching children. Filtering: keep a node
    -- if its name matches OR any descendant matches.
    local function attach(node)
        node.children = {}
        local raw = children_of[node.path] or {}
        for _, child in ipairs(raw) do
            attach(child)
            local self_match = (name_filter == '' or child.name:lower():find(name_filter, 1, true) ~= nil)
            if self_match or #child.children > 0 then
                node.children[#node.children + 1] = child
            end
        end
        return node
    end

    local root = attach({ name = '', path = '' })
    return root
end
M._build_tree = build_tree  -- exposed for tests

-- Walk PREFABS_DIR collecting every subfolder path (in '/'-form) into a
-- set. Used to feed build_tree so empty folders appear in the tree.
local function walk_folders()
    local paths_mod = require('dcs_sms_me.paths')
    local lfs = require('lfs')
    local set = { [''] = true }
    local function walk(abs_dir, rel)
        local ok = pcall(function()
            for entry in lfs.dir(abs_dir) do
                if entry ~= '.' and entry ~= '..' then
                    local abs = abs_dir .. entry
                    local attr = lfs.attributes(abs)
                    if attr and attr.mode == 'directory' then
                        local sub_rel = (rel == '' and entry) or (rel .. '/' .. entry)
                        set[sub_rel] = true
                        walk(abs .. '\\', sub_rel)
                    end
                end
            end
        end)
        if not ok and log and log.write then
            log.write('sms.me.prefab', log.WARNING, 'walk_folders at "' .. rel .. '" failed')
        end
    end
    walk(paths_mod.PREFABS_DIR, '')
    return set
end
M._walk_folders = walk_folders  -- exposed for tests/inspection

-- Label for the synthetic root node that always sits at the top of the folder
-- browser. It maps to selected_folder '' (recursive show-all), so clicking it
-- — or the default selection on open — shows every prefab, including those
-- saved directly in the prefabs root.
local ROOT_LABEL = 'Prefabs'

-- Pure: flatten a build_tree result into ordered ListBox rows for the folder
-- browser, with the synthetic root row (path '') first and the real folders
-- indented one level beneath it. Returns { {text=, path=}, ... } in display
-- order so row index N maps to entry N. `collapse` is a set of
-- folder_path -> true (collapsed → its children are hidden). Exposed for tests.
function M._listbox_tree_rows(tree_root, collapse, root_label)
    collapse = collapse or {}
    local rows = { { text = root_label, path = '' } }
    local function walk(node, depth)
        for _, child in ipairs((node and node.children) or {}) do
            local indent = string.rep('  ', depth)
            local glyph = (#(child.children or {}) > 0)
                and ((collapse[child.path] and '> ') or 'v ')
                or  '  '
            local marker = community_config.is_community_path(child.path) and '  (downloads)' or ''
            rows[#rows + 1] = { text = indent .. glyph .. child.name .. marker, path = child.path }
            if not collapse[child.path] then
                walk(child, depth + 1)
            end
        end
    end
    walk(tree_root, 1)
    return rows
end

-- Native-TreeView render path. DCS's TreeView is node-based — `addNode(text,
-- parentNode, index)` returns a node table; we stash `_sms_path` on it so the
-- selection callback can map back to a folder. `clear()` wipes all nodes.
-- (Earlier draft assumed an `insertItem` API that doesn't exist in DCS dxgui.)
-- Tint a folder-tree node's label to mark the import-managed Community folder.
-- Clones the tree's item sub-skin, repaints the unselected text colour to a
-- distinct accent, and applies it to the node's TreeViewItem (node.item) — the
-- same per-item skin mechanism TreeView.addNode itself uses. dxgui-bound and
-- pcall-guarded so a skin/binding gap degrades to "no tint" rather than
-- breaking the render.
local COMMUNITY_TINT = '0xf0c674ff'  -- warm gold, legible on the dark tree bkg
local function apply_community_node_tint(node)
    if type(node) ~= 'table' or not node.item or not node.item.setSkin then return end
    pcall(function()
        local Skin_mod = require('Skin')
        local s = Skin_mod.treeViewSkin_ME and Skin_mod.treeViewSkin_ME()
        local item = s and s.skinData and s.skinData.skins and s.skinData.skins.item
        local rel = item and item.skinData and item.skinData.states and item.skinData.states.released
        if not rel then return end
        if rel[1] and rel[1].text then rel[1].text.color = COMMUNITY_TINT end
        if rel[2] and rel[2].text then rel[2].text.color = COMMUNITY_TINT end
        node.item:setSkin(item)
    end)
end

local function render_tree_native()
    if not W.folder_tree or W.folder_tree_uses_listbox then return end
    if not W.folder_tree.addNode then return end
    pcall(function()
        if W.folder_tree.clear then pcall(function() W.folder_tree:clear() end) end
        local function add_node(node_data, parent_node)
            for _, child in ipairs(node_data.children or {}) do
                local n = W.folder_tree:addNode(child.name, parent_node, nil)
                if type(n) == 'table' then
                    n._sms_path = child.path
                    if community_config.is_community_path(child.path) then
                        apply_community_node_tint(n)
                    end
                end
                add_node(child, n)
            end
        end
        -- Always render a clickable root node for the whole library so prefabs
        -- saved directly in the prefabs root are never hidden behind "Show all".
        -- It maps to path '' (recursive show-all); the real folders hang under it.
        local root_node = W.folder_tree:addNode(ROOT_LABEL, nil, nil)
        if type(root_node) == 'table' then root_node._sms_path = '' end
        add_node(W.folder_tree_root, root_node)
        -- Expand everything by default so users see their structure.
        if W.folder_tree.expand then pcall(function() W.folder_tree:expand() end) end
        -- Anchor the default / show-all state to a highlighted root node so the
        -- full list (incl. root-level prefabs) reads as "selected", not hidden.
        if W.selected_folder == '' and W.folder_tree.selectNode and type(root_node) == 'table' then
            pcall(function() W.folder_tree:selectNode(root_node) end)
        end
    end)
end

-- ListBox fallback render path. Flattens the visible (non-collapsed)
-- subtree into one row per folder, indent + prefix-glyph encoded.
local function render_tree_listbox()
    if not W.folder_tree or not W.folder_tree_uses_listbox then return end
    pcall(function()
        if W.folder_tree.removeAllItems then W.folder_tree:removeAllItems()
        elseif W.folder_tree.removeAll   then W.folder_tree:removeAll()
        end
        local ListBoxItem; do local ok, m = pcall(require, 'ListBoxItem'); if ok then ListBoxItem = m end end
        -- Root row (path '') first, real folders indented beneath it. Same
        -- ordered rows the unit test pins down, so index N maps to path N.
        local rows = M._listbox_tree_rows(W.folder_tree_root, W.folder_tree_collapse, ROOT_LABEL)
        W._tree_listbox_paths = {}
        for _, r in ipairs(rows) do
            if ListBoxItem and W.folder_tree.insertItem then
                local it = ListBoxItem.new()
                it:setText(r.text)
                W.folder_tree:insertItem(it)
            end
            W._tree_listbox_paths[#W._tree_listbox_paths + 1] = r.path
        end
        -- Anchor the default / show-all state to the highlighted root row.
        if W.selected_folder == '' and W.folder_tree.setSelectedItem then
            pcall(function() W.folder_tree:setSelectedItem(0) end)
        end
    end)
end

-- Public rebuild — walks the disk, re-derives the tree, re-renders.
function M._rebuild_tree()
    W.folder_set = walk_folders()
    W.folder_tree_root = build_tree(W.folder_set, W.folder_filter_text)
    if W.folder_tree_uses_listbox then render_tree_listbox()
    else                                render_tree_native() end
end

local function apply_filter()
    W.visible_rows = compose_filter(W.rows, W.selected_folder, W.filter_text)
end

-- Restore selection by row name in the current visible_rows. Returns the
-- new W.selected_idx (1-based) or nil if the previously-selected row is no
-- longer visible.
local function restore_selection_by_name(prev_name)
    W.selected_idx = nil
    if not prev_name then return end
    for i, r in ipairs(W.visible_rows) do
        if r.name == prev_name then W.selected_idx = i; return i end
    end
end

-- The prefab count lives in the filter input's placeholder text now ("Search
-- 27 prefabs"). Hint text only renders when the input is empty — once the
-- user types, the typed text takes over, which is the right UX.
local function update_count_label()
    pcall(function()
        if not W.filter_input then return end
        -- W.filter_input is a clearable_edit panel — route setHintText
        -- to the underlying EditBox via :widget(). On the raw-TextBox
        -- fallback path, the panel IS the EditBox itself.
        local target = (W.filter_input.widget and W.filter_input:widget()) or W.filter_input
        if not (target and target.setHintText) then return end
        local total = #W.rows
        local label = (total == 1) and 'Search 1 prefab' or string.format('Search %d prefabs', total)
        target:setHintText(label)
    end)
end

-- Repopulate the grid from W.visible_rows. Caller is responsible for setting
-- W.visible_rows + W.selected_idx beforehand. Used by both refresh_list
-- (after disk rescan + sort) and on_filter_change (just after filter).
local function render_grid()
    pcall(function()
        if not W.grid then return end
        -- removeAllRows wipes both row structures and any cell widgets we
        -- inserted in the previous refresh — equivalent to ListBox's
        -- removeAllItems for our purposes.
        if W.grid.removeAllRows then W.grid:removeAllRows() end

        for i, r in ipairs(W.visible_rows) do
            -- Grid is 0-indexed for both columns and rows.
            W.grid:insertRow(nil)  -- nil → use rowHeight from gridSkin_ME (30px)
            local row = i - 1

            if r.error then
                local err_text = tostring(r.error)
                W.grid:setCell(0, row, make_cell('[ERROR] ' .. r.name, err_text))
                W.grid:setCell(1, row, make_cell(err_text:sub(1, 40), err_text))
                W.grid:setCell(2, row, make_cell(''))
                W.grid:setCell(3, row, make_cell(''))
                W.grid:setCell(4, row, make_cell(''))
                W.grid:setCell(5, row, make_cell(''))
                W.grid:setCell(6, row, make_cell(''))
                W.grid:setCell(7, row, make_cell(''))
                W.grid:setCell(8, row, make_cell(''))
            else
                local ab_text = ''
                if (r.airbase_count or 0) == 1 then ab_text = 'Yes'
                elseif (r.airbase_count or 0) > 1 then ab_text = tostring(r.airbase_count)
                end
                W.grid:setCell(0, row, make_cell(r.name, r.name))
                W.grid:setCell(1, row, make_cell(r.author or ''))
                W.grid:setCell(2, row, make_cell(r.theatre or '?'))
                W.grid:setCell(3, row, make_cell(r.place_at_origin and 'Yes' or ''))
                W.grid:setCell(4, row, make_cell(ab_text))
                W.grid:setCell(5, row, make_cell(r.group_count   or 0))
                W.grid:setCell(6, row, make_cell(r.static_count  or 0))
                W.grid:setCell(7, row, make_cell(r.zone_count    or 0))
                W.grid:setCell(8, row, make_cell(r.drawing_count or 0))
            end
        end

        if W.selected_idx and W.grid.selectRow then
            pcall(function() W.grid:selectRow(W.selected_idx - 1) end)
        end
    end)
end

local function refresh_list()
    -- Remember the selected row by name so we can restore selection across
    -- the re-sort + re-filter that scan_dir + sort_rows + apply_filter
    -- produces.
    local prev_name = nil
    if W.selected_idx and W.visible_rows[W.selected_idx] then
        prev_name = W.visible_rows[W.selected_idx].name
    end

    W.rows = prefab_ops.scan_dir() or {}
    if M._rebuild_tree then M._rebuild_tree() end
    sort_rows(W.rows, W.sort_key, W.sort_dir)
    apply_filter()
    restore_selection_by_name(prev_name)
    update_count_label()
    update_header_labels()
    render_grid()
end

-- Re-filter and re-render in response to filter_input keystrokes. Doesn't
-- rescan the disk — that's refresh_list's job.
local function on_filter_change()
    pcall(function()
        if not (W.filter_input and W.filter_input.getText) then return end
        local txt = W.filter_input:getText() or ''
        if txt == W.filter_text then return end
        local prev_name = nil
        if W.selected_idx and W.visible_rows[W.selected_idx] then
            prev_name = W.visible_rows[W.selected_idx].name
        end
        W.filter_text = txt
        apply_filter()
        restore_selection_by_name(prev_name)
        update_count_label()
        render_grid()
    end)
end
M._refresh_list = refresh_list  -- exposed for later tasks

local function selected_row()
    if not W.selected_idx then return nil end
    return W.visible_rows[W.selected_idx]
end
M._selected_row = selected_row

-- ---------------------------------------------------------------------------
-- Modal overlay helper. Wraps MsgWindow.{question,warning,info,error,text}
-- so our prompts share the native ME title bar, icon set, and button
-- styling. Buttons:
--   { {label='OK',  on_click=function() ... end}, ... }
-- icon: 'question'|'warning'|'error'|'info' or nil for the no-icon variant.
-- title: caption rendered in the window's title bar.
-- ---------------------------------------------------------------------------

local function show_overlay(message, buttons, icon, title)
    if not MsgWindow then
        -- Test VM or a DCS build that doesn't expose MsgWindow. Best-effort:
        -- fire the first button so the calling flow doesn't deadlock.
        log.write('sms.me', log.ERROR, 'MsgWindow unavailable; firing default button for "' .. tostring(title or message) .. '"')
        if buttons[1] and buttons[1].on_click then pcall(buttons[1].on_click) end
        return
    end

    local ok, err = pcall(function()
        local labels = {}
        local by_label = {}
        for i, b in ipairs(buttons) do
            local lbl = tostring(b.label or '?')
            labels[i] = lbl
            by_label[lbl] = b.on_click
        end

        -- Pick the icon variant. Native icons are baked into the dialog
        -- template — no PNG paths or skin clones needed.
        local create
        if icon == 'warning'  then create = MsgWindow.warning
        elseif icon == 'error'    then create = MsgWindow.error
        elseif icon == 'info'     then create = MsgWindow.info
        elseif icon == 'question' then create = MsgWindow.question
        else                            create = MsgWindow.text  -- no-icon
        end

        local handler = create(tostring(message or ''), tostring(title or 'DCS-SMS'), unpack(labels))

        function handler:onChange(buttonText)
            local cb = by_label[buttonText]
            if cb then pcall(cb) end
            return false  -- false → MsgWindow closes the window after our cb
        end

        handler:show()
    end)
    if not ok then
        log.write('sms.me', log.ERROR, 'MsgWindow overlay failed: ' .. tostring(err))
        if buttons[1] and buttons[1].on_click then pcall(buttons[1].on_click) end
    end
end
M._show_overlay = show_overlay  -- exposed for later tasks

local function focus_name_input()
    pcall(function()
        if W.name_input and W.name_input.setFocused then W.name_input:setFocused(true) end
    end)
end

local function read_fixed_check()
    local v = false
    pcall(function()
        if W.fixed_check and W.fixed_check.getState then
            v = W.fixed_check:getState() == true
        end
    end)
    return v
end

-- checked_indices are 1-based indices into mission.trigrules. Builds the
-- to_portable payload with the live-editor env. Returns payload | nil.
local function build_triggers_payload(checked_indices)
    local payload
    pcall(function()
        local schema_mod   = require('dcs_sms_me.trigger_schema')
        local export       = require('dcs_sms_me.trigger_export')
        local trigger_media = require('dcs_sms_me.trigger_media')
        local Mission      = require('me_mission')
        local schema = schema_mod.from_editor()
        if not schema then return end
        local trigrules = Mission.mission and Mission.mission.trigrules or {}
        local entries = {}
        for _, i in ipairs(checked_indices) do
            if trigrules[i] then entries[#entries + 1] = trigrules[i] end
        end
        local dict_get = function(key)
            local ok_d, d = pcall(require, 'dictionary')
            if ok_d and type(d.getValueDict) == 'function' then
                local ok2, v = pcall(d.getValueDict, key)
                if ok2 then return v end
            end
        end
        local entity_name = function(kind, id)
            local m = Mission
            if kind == 'group' and m.group_by_id and m.group_by_id[id] then
                return m.group_by_id[id].name
            elseif kind == 'unit' and m.unit_by_id and m.unit_by_id[id] then
                return m.unit_by_id[id].name
            elseif kind == 'zone' then
                local ok_t, TZD = pcall(require, 'Mission.TriggerZoneData')
                if ok_t and TZD and type(TZD.getTriggerZoneName) == 'function' then
                    local ok2, n = pcall(TZD.getTriggerZoneName, id)
                    if ok2 then return n end
                end
            end
        end
        payload = export.to_portable(entries, {
            schema = schema,
            dict_get = dict_get,
            entity_name = entity_name,
            media_read = function(key) return trigger_media.read(key) end,
        })
        if payload and #payload.warnings > 0 then
            set_status(payload.warnings[1]
                .. (#payload.warnings > 1
                    and (' (+' .. (#payload.warnings - 1) .. ' more — see dcs.log)') or ''),
                'warning')
            for _, w in ipairs(payload.warnings) do
                log.write('sms.me.prefab', log.WARNING, 'trigger export: ' .. w)
            end
        end
    end)
    return payload
end

-- Detect triggers related to the current selection (spec §2 Flow B) and
-- ask via the bundle checklist. Calls k(triggers_payload_or_nil);
-- payload nil = save without triggers (none detected / none checked /
-- detection unavailable). Never blocks the save on errors.
local function with_bundled_triggers(k)
    local related, env
    local ok = pcall(function()
        local schema_mod = require('dcs_sms_me.trigger_schema')
        local export     = require('dcs_sms_me.trigger_export')
        local selection  = require('dcs_sms_me.selection')
        local Mission    = require('me_mission')

        local schema = schema_mod.from_editor()
        if not schema then return end
        local snap = selection.snapshot()
        if not (snap and snap.ok) then return end

        -- Build the selected-id sets. Zones: selection objects carry no
        -- ids — map selected names → ids via TriggerZoneData.
        local sel = { group_ids = {}, unit_ids = {}, zone_ids = {} }
        for _, g in ipairs(snap.groups or {}) do
            if g.groupId then sel.group_ids[g.groupId] = true end
            for _, u in ipairs(g.units or {}) do
                if u.unitId then sel.unit_ids[u.unitId] = true end
            end
        end
        if #(snap.zones or {}) > 0 then
            local zone_id_by_name = {}
            local ok_tzd, TZD = pcall(require, 'Mission.TriggerZoneData')
            if ok_tzd and TZD and type(TZD.getTriggerZoneIds) == 'function' then
                for _, zid in ipairs(TZD.getTriggerZoneIds() or {}) do
                    local nm = TZD.getTriggerZoneName(zid)
                    if nm then zone_id_by_name[nm] = zid end
                end
            end
            for _, z in ipairs(snap.zones) do
                local zid = z.name and zone_id_by_name[z.name]
                if zid then sel.zone_ids[zid] = true end
            end
        end

        local trigrules = Mission.mission and Mission.mission.trigrules or {}
        related = export.find_related(trigrules, sel, schema)
        env = { schema = schema }
    end)
    if not ok or not related or #related == 0 then
        k(nil)
        return
    end

    local trigger_dialogs = require('dcs_sms_me.trigger_dialogs')
    local triggers_tab    = require('dcs_sms_me.triggers_tab')
    trigger_dialogs.show_bundle_dialog({
        related = related,
        summarize = function(t) return triggers_tab.refs_summary(t, env.schema) end,
        on_confirm = function(checked_indices)
            if #checked_indices == 0 then k(nil); return end
            local payload = build_triggers_payload(checked_indices)
            k(payload)
        end,
        on_cancel = function() k(nil) end,
    })
end

local function do_save(name, place_at_origin, airbases, folder, triggers_payload)
    folder = folder or ''
    local ok, path_or_err = prefab_ops.save_selection(name, place_at_origin, airbases, folder, triggers_payload)
    if ok then
        local extras = {}
        if folder ~= '' then extras[#extras + 1] = 'in ' .. folder end
        if place_at_origin then extras[#extras + 1] = 'fixed' end
        if airbases and #airbases > 0 then extras[#extras + 1] = #airbases .. ' airbase(s)' end
        if triggers_payload then extras[#extras + 1] = #triggers_payload.triggers .. ' trigger(s)' end
        local suffix = #extras > 0 and ' [' .. table.concat(extras, ', ') .. ']' or ''
        set_status('Saved ' .. name .. suffix .. ' → ' .. tostring(path_or_err))
        log.write('sms.me.prefab', log.INFO, 'saved ' .. name .. ' in folder "' .. folder .. '"')
        refresh_list()
        pcall(function()
            if W.name_input and W.name_input.setText then W.name_input:setText('') end
        end)
        W.pending_airbases = nil  -- consumed
    else
        set_status('Save failed: ' .. tostring(path_or_err), 'error')
        log.write('sms.me.prefab', log.ERROR, 'save failed: ' .. tostring(path_or_err))
    end
end

local function on_save_click()
    pcall(function()
        local name = ''
        if W.name_input and W.name_input.getText then name = W.name_input:getText() or '' end
        -- Trim leading/trailing whitespace so a stray space typed in the
        -- name input doesn't produce a file literally named " foo ".
        name = name:gsub('^%s+', ''):gsub('%s+$', '')
        local fixed = read_fixed_check()
        local airbases = W.pending_airbases
        if name == '' then
            set_status('Empty name — using timestamped fallback. See dcs.log.', 'warning')
            name = 'prefab-' .. os.date('!%Y%m%dT%H%M%SZ')
            log.write('sms.me.prefab', log.WARNING, 'save with empty name → ' .. name)
            with_bundled_triggers(function(tp)
                do_save(name, fixed, airbases, W.selected_folder, tp)
            end)
            return
        end

        if prefab_ops.exists(name) then
            show_overlay(
                'Prefab "' .. name .. '" already exists.\n\nOverwrite, rename, or cancel?',
                {
                    { label = 'Overwrite', on_click = function()
                        with_bundled_triggers(function(tp)
                            do_save(name, fixed, airbases, W.selected_folder, tp)
                        end)
                    end },
                    { label = 'Rename',    on_click = function() focus_name_input(); set_status('Type a new name and click Save.') end },
                    { label = 'Cancel',    on_click = function() set_status('Save cancelled.') end },
                },
                'question',
                'Prefab Already Exists')
            return
        end

        with_bundled_triggers(function(tp)
            do_save(name, fixed, airbases, W.selected_folder, tp)
        end)
    end)
end

-- Right-click "Update Prefab with selection": overwrite an existing prefab
-- with the current ME selection. Identical to a same-name Save (respects the
-- Fixed toggle and any captured airbases) but skips name entry and gates on a
-- prefab-specific confirm. The menu entry is hidden on error rows, so row is
-- expected to be a healthy prefab; we still guard defensively.
--
-- Trigger bundling: context_menu.lua's "Update Prefab with selection" routes
-- here (hooks.on_update → on_update_prefab → do_save), so wrapping the Update
-- button in with_bundled_triggers covers that path too — no separate hook in
-- context_menu.lua needed.
local function on_update_prefab(row)
    if not row or row.error then return end
    show_overlay(
        'This will overwrite "' .. tostring(row.name) .. '" with your current selection.',
        {
            { label = 'Update', on_click = function()
                with_bundled_triggers(function(tp)
                    do_save(row.name, read_fixed_check(), W.pending_airbases, row.folder or '', tp)
                end)
            end },
            { label = 'Cancel', on_click = function() set_status('Update cancelled.') end },
        },
        'warning',
        'Update Prefab')
end

local populate_country_combo  -- forward decl: defined below, called from on_reload_click

local function on_reload_click()
    -- Re-populate the country dropdown alongside the library so users who
    -- changed coalition assignments in the ME (Customize → Coalitions) can
    -- pick up the change without closing and reopening the window.
    pcall(function()
        refresh_list()
        populate_country_combo()
        set_status('Library and countries reloaded.')
    end)
end

local function require_selection(action_label)
    local row = selected_row()
    if not row then
        set_status('Select a prefab in the list first (' .. action_label .. ').', 'warning')
        return nil
    end
    if row.error then
        set_status('Cannot ' .. action_label .. ' — file has load error.', 'warning')
        return nil
    end
    return row
end

-- Grid-row select callback.
-- Grid:getSelectedRow() returns the 0-based row index, or -1 if nothing is
-- selected. Map to W.visible_rows[idx+1]. The callback is wired both via
-- addSelectRowCallback (fires on keyboard arrow-key changes) and via an
-- onMouseDown override that calls grid:selectRow(row) — Grid's built-in
-- mouse handler does not auto-select on click; see me_openfile.lua's
-- setupCallbacksAddGrid for the pattern we mirror.
local function on_list_select(...)
    pcall(function()
        if not (W.grid and W.grid.getSelectedRow) then
            W.selected_idx = nil
            return
        end
        local idx = W.grid:getSelectedRow()
        if type(idx) ~= 'number' or idx < 0 then
            W.selected_idx = nil
            return
        end
        W.selected_idx = idx + 1
        local row = selected_row()
        if row then
            set_status('Selected: ' .. tostring(row.name))
        end
        log.write('sms.me', log.INFO,
            'on_list_select grid row=' .. tostring(idx)
            .. ' (' .. tostring(row and row.name or '?') .. ')')
    end)
end

-- ---------------------------------------------------------------------------
-- Place-pending state machine
-- ---------------------------------------------------------------------------

local exit_place_pending           -- forward declaration; assigned below
local run_airbase_apply            -- forward decl: referenced by the click-place closure
local run_trigger_import           -- forward decl: referenced by the click-place closure
local selected_country_coalition   -- forward decl: referenced by the click-place closure
local read_naming_opts             -- forward decl: referenced by the click-place closure

-- Sentinel label for the "use prefab's saved countries" combobox entry.
-- Selected by default after every populate (so users get original-country
-- placement out of the box, supporting mixed-coalition prefabs without
-- having to know to leave the dropdown blank). get_country_name maps this
-- back to nil so the place pipeline takes the no-override branch.
local KEEP_ORIGINAL_LABEL = '<keep prefab countries>'

-- Read the currently-selected country from the dropdown. Returns nil when
-- the combo isn't built (test VM, dxgui without ComboBox), no item is
-- selected, OR the special "<keep prefab countries>" sentinel is selected
-- — caller falls back to the prefab's stored country in all three cases.
local function get_country_name()
    local name
    pcall(function()
        if not (W.country_combo and W.country_combo.getSelectedItem) then return end
        local item = W.country_combo:getSelectedItem()
        if item and item.getText then
            local txt = item:getText()
            if type(txt) == 'string' and txt ~= '' and txt ~= KEEP_ORIGINAL_LABEL then
                name = txt
            end
        end
    end)
    return name
end

-- Read the mission-defined coalition for a country name. Returns 'red',
-- 'blue', 'neutral', or nil. Mission.countryCoalition[name] is the
-- coalition *object* whose .name field carries the string ('red', 'blue',
-- 'neutrals' — note plural). The .color field is a MapColor table for
-- map rendering, NOT the coalition string, so don't read .color here.
local function country_coalition(Mission, name)
    if not (Mission and type(Mission.countryCoalition) == 'table') then return nil end
    local entry = Mission.countryCoalition[name]
    if type(entry) ~= 'table' then return nil end
    local cn = entry.name
    if cn == 'red' or cn == 'blue' then return cn end
    if cn == 'neutrals' or cn == 'neutral' then return 'neutral' end
    return nil
end

-- Map a coalition string to the canonical ME ListBoxItem skin name.
local COALITION_SKIN = {
    red     = 'listBoxItemCoalRedSkin',
    blue    = 'listBoxItemCoalBlueSkin',
    neutral = 'listBoxItemCoalNeutralSkin',
}

-- Is the Combat/All toggle currently in "All" mode? (state=true ⇒ All;
-- state=false / no widget ⇒ Combat). Mirrors me_aircraft.lua's tbFilter.
local function is_filter_all()
    local on = false
    pcall(function()
        if W.country_filter_btn and W.country_filter_btn.getState then
            on = W.country_filter_btn:getState() == true
        end
    end)
    return on
end

-- (Re-)populate the country combobox from Mission.missionCountry. Called
-- on first build, on every M.show, on Combat/All toggle, and on Reload
-- (so users who change coalition assignments in the ME pick up the change
-- without closing the window). Per-item skin shows a colored dot for the
-- country's mission coalition (red / blue / neutral). In Combat mode
-- neutral countries are hidden — same convention as the ME's airplane
-- group panel (tbFilter).
populate_country_combo = function()
    pcall(function()
        if not (W.country_combo and ListBoxItem) then return end
        local ok_req, Mission = pcall(require, 'me_mission')
        if not ok_req or type(Mission.missionCountry) ~= 'table' then
            log.write('sms.me', log.WARNING, 'Mission.missionCountry unavailable — country dropdown empty')
            return
        end

        local show_all = is_filter_all()
        local prev = get_country_name()  -- nil if "<keep prefab countries>" was active

        if W.country_combo.removeAllItems then W.country_combo:removeAllItems() end

        -- Sentinel "use prefab's saved countries" entry first. Default
        -- selection lands here unless the user previously had a real
        -- country chosen (prev is non-nil). When this is selected,
        -- get_country_name returns nil → place pipeline preserves
        -- whatever country each group/unit had at distill time, so
        -- mixed-coalition prefabs round-trip correctly.
        local keep_item = ListBoxItem.new(KEEP_ORIGINAL_LABEL)
        W.country_combo:insertItem(keep_item)
        local first_item = keep_item
        local prev_item

        local names = {}
        for name in pairs(Mission.missionCountry) do
            if type(name) == 'string' then names[#names + 1] = name end
        end
        table.sort(names)

        for _, name in ipairs(names) do
            local coalition = country_coalition(Mission, name)
            -- Combat mode: red/blue only. All mode: include neutral (and
            -- countries with no mission coalition assignment).
            local include = show_all or coalition == 'red' or coalition == 'blue'
            if include then
                local item = ListBoxItem.new(name)
                local skin_name = COALITION_SKIN[coalition or 'neutral']
                if skin_name then try_skin(item, skin_name) end
                W.country_combo:insertItem(item)
                if name == prev then prev_item = item end
            end
        end

        local pick = prev_item or first_item
        if pick and W.country_combo.selectItem then
            pcall(function() W.country_combo:selectItem(pick) end)
        end
    end)
end

-- Build a polygon-rectangle mapData ready for MapWindow.createDrawObject,
-- sized to the prefab's AABB. The center is set to (0, 0) here; the
-- mouse-move handler updates it. Caller computes bbox via
-- prefab_ops.compute_bbox. Returns nil if the bbox is empty (no entities).
local function build_preview_rect(bbox)
    if not bbox then return nil end
    local hx2 = (bbox.max_x - bbox.min_x) / 2
    local hy2 = (bbox.max_y - bbox.min_y) / 2
    -- A 5-point closed rectangle. Point order matches polygonRectMakePoints
    -- in me_draw_panel.lua so the renderer treats this like a native rect.
    local pts = {
        { x =  hx2, y = -hy2 },
        { x =  hx2, y =  hy2 },
        { x = -hx2, y =  hy2 },
        { x = -hx2, y = -hy2 },
        { x =  hx2, y = -hy2 },
    }
    return {
        objectType = 'Polygon',
        points     = pts,
        thickness  = 2,
        color      = { 1, 1, 0, 1 },         -- bright yellow outline
        fillColor  = { 1, 1, 0, 0.12 },      -- subtle yellow fill
        file       = './MissionEditor/data/NewMap/images/draw/polyline_solid.png',
        x          = 0,
        y          = 0,
        angle      = 0,
    }
end

-- Repaint the place-pending bbox preview at its last-known cursor position
-- with the current rotation. Called from place_state:onMouseMove (after
-- the cursor is updated) and from the rotation dial / spinbox onChange
-- handlers (so the rect spins under a stationary cursor as the user
-- dials it). No-op when no preview is active.
local function refresh_preview()
    pcall(function()
        if not (W.preview_id and W.preview_data and W.preview_offset and W.preview_cursor) then return end
        local rot = W.rotation_deg or 0
        local rad = rot * math.pi / 180
        local c, s = math.cos(rad), math.sin(rad)
        local ox, oy = W.preview_offset.x, W.preview_offset.y
        -- Same rotation as prefab_ops._place_xy so the rect's center
        -- tracks where the bbox center actually lands after rotation.
        W.preview_data.x = W.preview_cursor.x + (ox * c - oy * s)
        W.preview_data.y = W.preview_cursor.y + (ox * s + oy * c)
        W.preview_data.angle = rot
        local MapWindow = require('me_map_window')
        if MapWindow and MapWindow.updateDrawObject then
            MapWindow.updateDrawObject(W.preview_id, W.preview_data)
        end
    end)
end

local function enter_place_pending(prefab_name, prefab_table, rotation_deg)
    W.place_pending = true
    W.place_pending_name = prefab_name
    pcall(function()
        if W.window and W.window.setText then
            -- ALL-CAPS + arrow markers to make place-pending unmistakable
            -- without needing color (dxgui Static has no setColor API).
            W.window:setText('PLACING "' .. prefab_name .. '" — CLICK MAP (Esc cancels)')
        end
    end)
    pcall(function()
        if W.place_click_btn and W.place_click_btn.setText then W.place_click_btn:setText('Cancel') end
    end)
    -- Green status text reinforces place-pending mode visually, alongside
    -- the title-bar arrows and the "Cancel" button label. set_status('placement')
    -- swaps the skin; no need for a separate try_skin call here.
    set_status_sticky('PLACING "' .. prefab_name .. '" — CLICK ON THE MAP (Esc cancels)', 'success')

    -- Cursor-following bbox preview: a yellow polygon-rectangle sized to
    -- the prefab's AABB. Mirrors me_draw_panel's polygonRect drag-create
    -- pattern (createDrawObject + addDrawObject + updateDrawObject on
    -- every mouse-move). createDrawObject alone registers the object but
    -- doesn't show it on the map layer — addDrawObject(id) is what makes
    -- it visible.
    pcall(function()
        local MapWindow = require('me_map_window')
        local bbox = prefab_ops.compute_bbox(prefab_table)
        if not bbox or not (MapWindow and MapWindow.createDrawObject) then return end
        local data = build_preview_rect(bbox)
        if not data then return end
        W.preview_data   = data
        W.preview_offset = {
            x = (bbox.min_x + bbox.max_x) / 2,
            y = (bbox.min_y + bbox.max_y) / 2,
        }
        W.preview_id = MapWindow.createDrawObject(data)
        if W.preview_id and MapWindow.addDrawObject then
            pcall(function() MapWindow.addDrawObject(W.preview_id) end)
        end
    end)

    -- Map-click hook via me_map_window state machine.
    -- We create a plain table that satisfies the NewMapView state interface
    -- (onMouseDown / onMouseUp / onMouseDrag / onMouseMove / onMouseWheel).
    -- me_map_window.setState() installs it; exit_place_pending restores panState.
    -- Coord conversion: me_map_window.getMapPoint(screen_x, screen_y) → world x, y.
    local ok = pcall(function()
        local MapWindow = require('me_map_window')
        if not (MapWindow and MapWindow.setState and MapWindow.getPanState and MapWindow.getMapPoint) then
            error('me_map_window missing required symbols')
        end

        -- Capture the default pan/zoom state so we can forward right-drag
        -- and wheel events to it. Without this delegation, replacing the
        -- map state with our place_state kills both pan and zoom for the
        -- duration of place-pending.
        local pan_state = MapWindow.getPanState()
        local function forward(method, ...)
            if not pan_state then return end
            local fn = pan_state[method]
            if type(fn) == 'function' then pcall(fn, pan_state, ...) end
        end

        local place_state = {}

        function place_state:onMouseDown(x, y, button)
            if button ~= 1 then
                -- Right/middle click → start a pan drag (handled by pan_state).
                forward('onMouseDown', x, y, button)
                return
            end
            pcall(function()
                if not W.place_pending then return end
                local wx, wy = MapWindow.getMapPoint(x, y)
                if not (wx and wy) then
                    set_status('Place failed: getMapPoint returned nil', 'error')
                    log.write('sms.me.prefab', log.ERROR, 'place: getMapPoint returned nil')
                    exit_place_pending()
                    return
                end
                local country_name = get_country_name()
                if not country_name then
                    log.write('sms.me.prefab', log.WARNING, 'place: country dropdown empty — using prefab-stored countries')
                end
                -- Read rotation at click time so changes to the dial
                -- after pressing "Place at click" are honored. The
                -- rotation_deg captured at enter_place_pending entry is
                -- a snapshot — useful for the preview's initial paint
                -- but not authoritative. (Read W.rotation_deg directly
                -- rather than via get_rotation_deg(): that helper is
                -- defined later in the file, so this closure can't see
                -- it as an upvalue.)
                local rotation_now = W.rotation_deg or 0
                local rec, err = prefab_ops.place(prefab_table, {
                    anchor             = { x = wx, y = wy },
                    rotation           = rotation_now,
                    country_name       = country_name,
                    override_coalition = selected_country_coalition(),
                })
                if rec then
                    undo.record(rec)
                    -- record.statics doesn't exist in Task 6's shape (statics
                    -- ride inside record.groups since DCS treats them as
                    -- groups with type='static'). Sum errors instead.
                    local naming_opts = read_naming_opts()
                    local naming = prefab_naming.apply(rec, naming_opts)
                    local placement_msg = string.format(
                        'Placed %s (%dg %dz %dd, %d errors) at (%.0f, %.0f)',
                        prefab_name,
                        #(rec.groups or {}),
                        #(rec.zones or {}),
                        #(rec.drawings or {}),
                        #(rec.errors or {}),
                        wx or 0, wy or 0)
                    if naming.toast then
                        placement_msg = placement_msg .. ' — ' .. naming.toast
                    end
                    local sev = (naming.failed > 0) and 'warning' or nil
                    set_status(placement_msg, sev)
                    log.write('sms.me.prefab', log.INFO, 'placed ' .. prefab_name)
                    run_airbase_apply(prefab_table)
                    run_trigger_import(prefab_table, rec)
                else
                    set_status('Place failed: ' .. tostring(err), 'error')
                    log.write('sms.me.prefab', log.ERROR, 'place failed: ' .. tostring(err))
                end
                exit_place_pending()
            end)
        end

        function place_state:onMouseUp(x, y, button)
            if button ~= 1 then forward('onMouseUp', x, y, button) end
        end
        function place_state:onMouseDrag(dx, dy, button, x, y)
            -- Right/middle drag = pan. Left drag is meaningless here since
            -- our left-click commits the placement on mouse-down.
            if button ~= 1 then forward('onMouseDrag', dx, dy, button, x, y) end
        end
        function place_state:onMouseMove(x, y)
            -- Forward cursor tracking to pan_state too; some panState
            -- implementations stash the last cursor position for status
            -- readouts. Then update our follow-cursor preview.
            forward('onMouseMove', x, y)
            pcall(function()
                if not W.preview_id then return end
                local wx, wy = MapWindow.getMapPoint(x, y)
                if not (wx and wy) then return end
                W.preview_cursor = { x = wx, y = wy }
                refresh_preview()
            end)
        end
        function place_state:onMouseWheel(x, y, clicks)
            forward('onMouseWheel', x, y, clicks)
        end

        MapWindow.setState(place_state)
    end)
    if not ok then
        set_status('Place at click unavailable — try Place at original location. See dcs.log.', 'error')
        log.write('sms.me.prefab', log.ERROR, 'map-click hook unavailable')
        exit_place_pending()
    end
end

exit_place_pending = function()
    W.place_pending = false
    W.place_pending_name = nil
    pcall(function()
        if W.window and W.window.setText then
            W.window:setText(sms_window.compose_title('Prefab Manager', version))
        end
    end)
    pcall(function()
        if W.place_click_btn and W.place_click_btn.setText then W.place_click_btn:setText('Place at click') end
    end)
    -- Clear the sticky 'PLACING ...' baseline that enter_place_pending set
    -- via set_status_sticky. Without this, the success/cancel flash that
    -- preceded this call (set_status() above) would auto-revert to the
    -- now-stale PLACING message after its 5-second timeout — the user sees
    -- "Place: ..." for 5s, then it jumps back to the green PLACING text.
    -- clear_sticky_status() only updates the baseline; it doesn't touch
    -- the active flash, so the success/cancel message remains visible for
    -- its full duration before reverting to an empty footer.
    pcall(function()
        if W.sms_window and W.sms_window.clear_sticky_status then
            W.sms_window:clear_sticky_status()
        end
    end)
    -- Tear down the bbox preview overlay before restoring map state so the
    -- yellow rectangle doesn't briefly persist after Esc / click.
    pcall(function()
        if W.preview_id then
            local MapWindow = require('me_map_window')
            if MapWindow and MapWindow.removeDrawObject then
                MapWindow.removeDrawObject(W.preview_id)
            end
        end
    end)
    W.preview_id     = nil
    W.preview_data   = nil
    W.preview_offset = nil
    W.preview_cursor = nil
    pcall(function()
        local MapWindow = require('me_map_window')
        if MapWindow and MapWindow.setState and MapWindow.getPanState then
            MapWindow.setState(MapWindow.getPanState())
        end
    end)
end

local function get_rotation_deg()
    -- Dial+SpinBox path keeps W.rotation_deg authoritative; the legacy
    -- TextBox fallback writes its own value here too via on_rotation_text_change.
    return W.rotation_deg or 0
end

-- Re-entrance guard so spin→dial→spin (or vice versa) doesn't recurse when
-- one widget's setValue fires the other's onChange. Mirrors the implicit
-- guard me_static.lua relies on (where setValue with the same value is a
-- no-op); we make it explicit because our normalization can change the
-- value we write back, which would otherwise re-trigger.
local rotation_syncing = false

-- Normalize an arbitrary numeric input to 0..359 integer degrees. Matches
-- the convention me_static.lua's onChange_e_heading uses (-1 → 359,
-- 360 → 0), but generalized for any over/underflow.
local function normalize_deg(v)
    v = tonumber(v) or 0
    v = math.floor(v + 0.5)
    v = v % 360
    if v < 0 then v = v + 360 end
    return v
end

local function on_rotation_spin_change(self)
    if rotation_syncing then return end
    rotation_syncing = true
    pcall(function()
        local raw = (self.getValue and self:getValue()) or 0
        local v = normalize_deg(raw)
        W.rotation_deg = v
        if v ~= raw and self.setValue then self:setValue(v) end
        if W.rotation_dial and W.rotation_dial.setValue then W.rotation_dial:setValue(v) end
    end)
    rotation_syncing = false
    refresh_preview()
end

local function on_rotation_dial_change(self)
    if rotation_syncing then return end
    rotation_syncing = true
    pcall(function()
        local v = normalize_deg((self.getValue and self:getValue()) or 0)
        W.rotation_deg = v
        if W.rotation_spin and W.rotation_spin.setValue then W.rotation_spin:setValue(v) end
    end)
    rotation_syncing = false
    refresh_preview()
end

-- Read the sticky naming-form values from the widgets. Empty strings are
-- normalized to nil so prefab_naming.apply's has_any check treats them
-- correctly. Keep Num is a ToggleButton (default ON) -- we just read its
-- bool state.
read_naming_opts = function()
    local function read_text(handle)
        if not (handle and handle.getText) then return nil end
        local ok, v = pcall(handle.getText, handle)
        if not ok then return nil end
        v = tostring(v or '')
        -- Trim whitespace; empty -> nil so apply()'s emptiness check fires.
        v = v:gsub('^%s+', ''):gsub('%s+$', '')
        if v == '' then return nil end
        return v
    end
    local keep_num = false
    pcall(function()
        if W.naming_keep_num_btn and W.naming_keep_num_btn.getState then
            keep_num = W.naming_keep_num_btn:getState() == true
        end
    end)
    return {
        name     = read_text(W.naming_name_input),
        prefix   = read_text(W.naming_prefix_input),
        suffix   = read_text(W.naming_suffix_input),
        keep_num = keep_num,
    }
end

-- Triggers-only prefab: nothing positional to anchor — skip the map
-- click / place call and go straight to the import dialog (spec §3).
local function is_triggers_only(p)
    return p and type(p.triggers) == 'table' and #p.triggers > 0
       and #(p.groups or {}) == 0 and #(p.statics or {}) == 0
       and #(p.zones or {}) == 0 and #(p.drawings or {}) == 0
end

local function on_place_click()
    if W.place_pending then
        -- Acting as Cancel.
        set_status('Place cancelled.')
        exit_place_pending()
        return
    end
    local row = require_selection('place')
    if not row then return end
    local prefab, lerr = prefab_ops.load(row.path)
    if not prefab then
        set_status('Load failed: ' .. tostring(lerr), 'error')
        log.write('sms.me.prefab', log.ERROR, 'load failed for ' .. row.path .. ': ' .. tostring(lerr))
        return
    end
    if is_triggers_only(prefab) then
        undo.record({ groups = {}, zones = {}, drawings = {} })  -- slot for add_triggers
        run_trigger_import(prefab, nil)
        return
    end
    enter_place_pending(row.name, prefab, get_rotation_deg())
end

-- Read current theatre via the same API save_selection uses.
local function current_theatre()
    local th
    pcall(function()
        local TheatreOfWarData = require('Mission.TheatreOfWarData')
        if TheatreOfWarData and type(TheatreOfWarData.getName) == 'function' then
            th = TheatreOfWarData.getName()
        end
    end)
    return th
end

-- Map a 'red'/'blue'/'neutral' string (from country_coalition) to the
-- uppercase form DCS warehouse entries use. Returns nil if no mapping.
local COALITION_FROM_LOWER = { red = 'RED', blue = 'BLUE', neutral = 'NEUTRAL' }

-- Returns the warehouse-form coalition string ('RED'/'BLUE'/'NEUTRAL') for
-- whatever country the user has currently selected in the dropdown, or nil
-- if no country is selected / the country has no mission coalition entry.
-- Used as the override coalition when applying saved airbase supplies, so
-- the airbase ends up under the user's currently-selected coalition rather
-- than whatever coalition was saved into the prefab.
selected_country_coalition = function()
    local name = get_country_name()
    if not name then return nil end
    local ok_req, Mission = pcall(require, 'me_mission')
    if not ok_req or not Mission then return nil end
    local lower = country_coalition(Mission, name)
    return lower and COALITION_FROM_LOWER[lower] or nil
end

-- After a prefab places, if it carries meta.airbases, ask the user once
-- whether to apply the saved supplies. We don't try to detect whether the
-- destination airbase is already customised — the user has both names in
-- the prompt and can decide for themselves whether the overwrite is wanted.
-- The coalition override is sourced from the country dropdown so applied
-- airbases end up on the user's currently-selected coalition rather than
-- the one baked into the saved prefab.
run_airbase_apply = function(prefab)
    if not (prefab and prefab.meta and prefab.meta.airbases and #prefab.meta.airbases > 0) then
        return  -- no airbases on this prefab; nothing to do
    end

    local names = {}
    for _, ab in ipairs(prefab.meta.airbases) do
        if ab.name then names[#names + 1] = ab.name end
    end

    local override = selected_country_coalition()

    local function do_apply()
        local ok, summary = prefab_ops.apply_airbases(prefab, {
            current_theatre    = current_theatre(),
            override_coalition = override,
        })
        if ok then
            -- Hand the per-airbase pre-write snapshots to undo so a single
            -- Undo press rolls back both the placed objects AND the warehouse
            -- splices. apply_airbases captures these synchronously, so the
            -- undo slot (recorded by the place flow before this prompt fires)
            -- is still the right one to augment.
            if summary.snapshots and #summary.snapshots > 0 then
                undo.add_airbase_snapshots(summary.snapshots)
            end
            local msg = ('Airbase supplies: %d applied'):format(summary.applied)
            if summary.skipped > 0 then
                msg = msg .. (', %d skipped'):format(summary.skipped)
                if summary.missing and #summary.missing > 0 then
                    msg = msg .. ' (' .. table.concat(summary.missing, ', ') .. ')'
                end
            end
            set_status(msg)
        else
            set_status('Airbase supplies skipped: ' .. tostring(summary and summary.error or 'unknown'), 'error')
        end
    end

    -- MsgWindow's editBoxMessage wraps text, so we don't need manual line
    -- breaks — just write the message naturally. Newlines are still honoured
    -- where we want a hard break (e.g. before the coalition line).
    local prompt
    if #names == 1 then
        prompt = "The prefab you're placing has custom supplies for "
              .. names[1] .. '. Do you want to apply these?'
              .. (override and ('\n\nCoalition of the base will be set to ' .. override .. '.') or '')
    else
        prompt = "The prefab you're placing has custom supplies for these "
              .. #names .. ' airbases:\n' .. table.concat(names, ', ')
              .. '\n\nDo you want to apply them?'
              .. (override and ('\n\nCoalition of the bases will be set to ' .. override .. '.') or '')
    end

    show_overlay(prompt, {
        { label = 'Yes', on_click = do_apply },
        { label = 'No',  on_click = function() set_status('Airbase supplies not applied.') end },
    }, 'question', 'Apply Airbase Supplies')
end

-- Post-place trigger import (spec §3). Mirrors run_airbase_apply's
-- position in the flow: runs after undo.record + naming. `rec` may be
-- nil for the triggers-only path (no entities were placed).
run_trigger_import = function(prefab, rec)
    if not (prefab and type(prefab.triggers) == 'table' and #prefab.triggers > 0) then
        return
    end
    local ok, err = pcall(function()
        local schema_mod     = require('dcs_sms_me.trigger_schema')
        local timport        = require('dcs_sms_me.trigger_import')
        local export         = require('dcs_sms_me.trigger_export')
        local trigger_media  = require('dcs_sms_me.trigger_media')
        local trigger_dialogs = require('dcs_sms_me.trigger_dialogs')
        local Mission        = require('me_mission')
        local b64            = require('dcs_sms_me.base64')

        local schema = schema_mod.from_editor()
        if not schema then
            set_status('Trigger import unavailable (descriptors missing)', 'warning')
            return
        end
        local trigrules = Mission.mission and Mission.mission.trigrules
        if type(trigrules) ~= 'table' then
            Mission.mission.trigrules = {}
            trigrules = Mission.mission.trigrules
        end

        -- Rebind maps from the placement record (zone map by NAME —
        -- prefab zones carry no ids).
        local maps = { gid_map = rec and rec.gid_map or {},
                       uid_map = rec and rec.uid_map or {},
                       zone_by_name = {} }
        for _, z in ipairs(rec and rec.zones or {}) do
            if z.orig_name and z.runtime_id then
                maps.zone_by_name[z.orig_name] = z.runtime_id
            end
        end

        local find_by_name = function(kind, name)
            if kind == 'group' and Mission.group_by_name then
                local g = Mission.group_by_name[name]
                return g and g.groupId
            elseif kind == 'unit' and Mission.unit_by_name then
                local u = Mission.unit_by_name[name]
                return u and u.unitId
            elseif kind == 'zone' then
                local ok_t, TZD = pcall(require, 'Mission.TriggerZoneData')
                if ok_t and TZD and type(TZD.getTriggerZoneIds) == 'function' then
                    for _, zid in ipairs(TZD.getTriggerZoneIds() or {}) do
                        if TZD.getTriggerZoneName(zid) == name then return zid end
                    end
                end
            end
        end

        local plan = timport.resolve(prefab.triggers, maps, {
            schema = schema,
            find_by_name = find_by_name,
            target_flags = export.extract_flags(trigrules, schema),
            prefab_flags = (prefab.meta and prefab.meta.flags_used) or {},
        })

        -- Entity options for the manual-map dropdowns.
        local entity_options = function(kind)
            local out = {}
            if kind == 'group' and type(Mission.group_by_name) == 'table' then
                for name, g in pairs(Mission.group_by_name) do
                    out[#out + 1] = { id = g.groupId, name = name }
                end
            elseif kind == 'unit' and type(Mission.unit_by_name) == 'table' then
                for name, u in pairs(Mission.unit_by_name) do
                    out[#out + 1] = { id = u.unitId, name = name }
                end
            elseif kind == 'zone' then
                local ok_t, TZD = pcall(require, 'Mission.TriggerZoneData')
                if ok_t and TZD and type(TZD.getTriggerZoneIds) == 'function' then
                    for _, zid in ipairs(TZD.getTriggerZoneIds() or {}) do
                        out[#out + 1] = { id = zid, name = TZD.getTriggerZoneName(zid) or '?' }
                    end
                end
            end
            table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
            return out
        end

        -- Embedded resources indexed by short name for inject.
        local resources = {}
        for _, r in ipairs((prefab.meta and prefab.meta.resources) or {}) do
            if r.name and r.data then resources[r.name] = r.data end
        end

        trigger_dialogs.show_import_dialog({
            plan = plan,
            entity_options = entity_options,
            on_import = function(decisions)
                local result = timport.inject(plan, decisions, {
                    schema = schema,
                    create_trigger = function(d)
                        return require('me_trigrules').createTrigger(d)
                    end,
                    create_rule = function(d)
                        return require('me_predicates').createRule(d)
                    end,
                    create_action = function(d)
                        return require('me_trigrules').createAction(d)
                    end,
                    fix_dict = function(entry, field, literal, label)
                        local ok_d, dict = pcall(require, 'dictionary')
                        if ok_d and type(dict.fixDict) == 'function' then
                            pcall(dict.fixDict, entry, field, literal, label)
                        else
                            entry[field] = literal
                        end
                    end,
                    media_add = function(short, data_b64, prefix)
                        local bytes = b64.decode(data_b64)
                        if not bytes then return nil, 'bad base64' end
                        return trigger_media.add(short, bytes, { prefix = prefix })
                    end,
                    resources = resources,
                    trigrules = trigrules,
                    unique_name = function(base)
                        -- mirror trigger_verbs' _trigger_unique_name
                        local function exists(n)
                            for _, t in ipairs(trigrules) do
                                if t.comment == n then return true end
                            end
                        end
                        if not exists(base) then return base end
                        local n = 2
                        while exists(base .. '-' .. n) do n = n + 1 end
                        return base .. '-' .. n
                    end,
                })
                undo.add_triggers(result.entries)
                timport.panel_refresh()
                -- Keep the Prefab Manager's Triggers tab in step too (it
                -- shows mission.trigrules rows when built).
                pcall(function()
                    if W.triggers and W.triggers ~= false then W.triggers:refresh() end
                end)
                local msg = 'Imported ' .. result.count .. ' trigger(s)'
                if #result.skipped > 0 then
                    msg = msg .. ', ' .. #result.skipped .. ' skipped ('
                          .. tostring(result.skipped[1].reason) .. ')'
                end
                if #result.errors > 0 then
                    msg = msg .. ' — ' .. #result.errors .. ' issue(s), see dcs.log'
                    for _, e in ipairs(result.errors) do
                        log.write('sms.me.prefab', log.WARNING, 'trigger import: ' .. e)
                    end
                end
                set_status(msg, (#result.skipped + #result.errors > 0) and 'warning' or 'success')
            end,
            on_skip = function() set_status('Triggers not imported.') end,
        })
    end)
    if not ok then
        set_status('Trigger import failed: ' .. tostring(err), 'error')
        log.write('sms.me.prefab', log.ERROR, 'trigger import: ' .. tostring(err))
    end
end

local function on_place_origin_click()
    local row = require_selection('place at original location')
    if not row then return end
    local prefab, lerr = prefab_ops.load(row.path)
    if not prefab then
        set_status('Load failed: ' .. tostring(lerr), 'error')
        log.write('sms.me.prefab', log.ERROR, 'load failed for ' .. row.path .. ': ' .. tostring(lerr))
        return
    end
    if is_triggers_only(prefab) then
        undo.record({ groups = {}, zones = {}, drawings = {} })  -- slot for add_triggers
        run_trigger_import(prefab, nil)
        return
    end
    local rotation_deg = get_rotation_deg()
    local country_name = get_country_name()
    if not country_name then
        log.write('sms.me.prefab', log.WARNING, 'place at original location: country dropdown empty — using prefab-stored countries')
    end
    local rec, err = prefab_ops.place(prefab, {
        keep_position      = true,
        rotation           = rotation_deg,
        country_name       = country_name,
        override_coalition = selected_country_coalition(),
    })
    if rec then
        undo.record(rec)
        local wa = prefab.meta and prefab.meta.world_anchor or { x = 0, y = 0 }
        local naming_opts = read_naming_opts()
        local naming = prefab_naming.apply(rec, naming_opts)
        local placement_msg = string.format(
            'Placed %s at original (%dg %dz %dd, %d errors) at (%.0f, %.0f)',
            row.name,
            #(rec.groups or {}),
            #(rec.zones or {}),
            #(rec.drawings or {}),
            #(rec.errors or {}),
            wa.x or 0, wa.y or 0)
        if naming.toast then
            placement_msg = placement_msg .. ' — ' .. naming.toast
        end
        local sev = (naming.failed > 0) and 'warning' or nil
        set_status(placement_msg, sev)
        log.write('sms.me.prefab', log.INFO, 'placed ' .. row.name .. ' at original')
        run_airbase_apply(prefab)
        run_trigger_import(prefab, rec)
    else
        set_status('Place failed: ' .. tostring(err), 'error')
        log.write('sms.me.prefab', log.ERROR, 'place at original location failed: ' .. tostring(err))
    end
end

-- Show a rename overlay: prompt + text input + OK/Cancel.
-- on_ok receives the new name string; on_cancel takes no args.
local function show_rename_overlay(prompt, current_name, on_ok, on_cancel)
    local screen_w, screen_h = Gui.GetWindowSize()
    -- Slightly taller than show_overlay because rename has prompt + input
    -- stacked. Same icon convention: 64x64 question glyph at (10, 14),
    -- prompt + input shifted to x=84.
    local w, h = 460, 220
    local x = (screen_w - w) / 2
    local y = (screen_h - h) / 2
    local overlay, input = nil, nil
    local function close()
        pcall(function() if overlay and overlay.setVisible then overlay:setVisible(false) end end)
    end
    local ok, err = pcall(function()
        overlay = Window.new(x, y, w, h, 'Rename')
        overlay:setSkin((Skin.windowSkinME and Skin.windowSkinME()) or Skin.windowSkin())
        overlay:setVisible(true)
        overlay:setDraggable(true)
        overlay:setResizable(false)
        overlay:setZOrder(220)

        local ico = Static.new()
        ico:setBounds(10, 14, 48, 48)
        try_skin(ico, 'icon_question')
        overlay:insertWidget(ico)

        local lbl = Static.new()
        lbl:setBounds(68, 14, w - 78, 20)
        lbl:setText(tostring(prompt or 'New name:'))
        try_skin(lbl, 'staticSkin_ME')
        overlay:insertWidget(lbl)

        input = TextBox.new()
        input:setBounds(68, 40, w - 78, 22)
        if input.setText then input:setText(tostring(current_name or '')) end
        if input.setFocused then input:setFocused(true) end
        try_skin(input, 'editBoxSkin_ME')
        overlay:insertWidget(input)

        local ok_btn = Button.new()
        ok_btn:setBounds(w - 200, h - 92, 90, 22)
        ok_btn:setText('OK')
        try_skin(ok_btn, 'sms_button')
        ok_btn:addChangeCallback(function()
            local new_name = (input.getText and input:getText()) or ''
            close()
            pcall(function() (on_ok or function() end)(new_name) end)
        end)
        overlay:insertWidget(ok_btn)

        local cancel_btn = Button.new()
        cancel_btn:setBounds(w - 100, h - 92, 90, 22)
        cancel_btn:setText('Cancel')
        try_skin(cancel_btn, 'sms_button')
        cancel_btn:addChangeCallback(function()
            close()
            pcall(on_cancel or function() end)
        end)
        overlay:insertWidget(cancel_btn)
    end)
    if not ok then
        log.write('sms.me', log.ERROR, 'rename overlay failed: ' .. tostring(err))
        pcall(on_cancel or function() end)
    end
end

local function on_rename_click()
    local row = require_selection('rename')
    if not row then return end
    show_rename_overlay('Rename "' .. row.name .. '" to:', row.name,
        function(new_name)
            new_name = (new_name or ''):gsub('^%s+', ''):gsub('%s+$', '')
            if new_name == '' then set_status('Rename cancelled (empty name).'); return end
            if new_name == row.name then set_status('Rename cancelled (same name).'); return end
            local ok, msg = prefab_ops.rename_file(row.path, new_name)
            if ok then
                set_status('Renamed ' .. row.name .. ' → ' .. new_name)
                log.write('sms.me.prefab', log.INFO, 'renamed ' .. row.name .. ' → ' .. new_name)
                refresh_list()
            else
                set_status('Rename failed: ' .. tostring(msg), 'error')
                log.write('sms.me.prefab', log.ERROR, 'rename failed: ' .. tostring(msg))
            end
        end,
        function() set_status('Rename cancelled.') end)
end

local function on_delete_click()
    local row = require_selection('delete')
    if not row then return end
    show_overlay(
        'Delete "' .. row.name .. '"?\n\nThis cannot be undone.',
        {
            { label = 'Delete', on_click = function()
                local ok, oerr = os.remove(row.path)
                if ok then
                    set_status('Deleted ' .. row.name)
                    log.write('sms.me.prefab', log.INFO, 'deleted ' .. row.name)
                else
                    set_status('Delete failed: ' .. tostring(oerr), 'error')
                    log.write('sms.me.prefab', log.ERROR, 'delete failed for ' .. row.path .. ': ' .. tostring(oerr))
                end
                W.selected_idx = nil
                refresh_list()
            end },
            { label = 'Cancel', on_click = function() set_status('Delete cancelled.') end },
        },
        'warning',
        'Delete Prefab')
end
local function on_undo_click()
    pcall(function()
        if not undo.has_record() then set_status('Nothing to undo.', 'warning'); return end
        local ok, err = undo.undo()
        if ok then
            set_status('Undid last placement' .. (err and (' (' .. err .. ')') or ''))
            -- Undo may have removed imported triggers — keep the Triggers
            -- tab's rows in step (it shows mission.trigrules when built).
            pcall(function()
                if W.triggers and W.triggers ~= false then W.triggers:refresh() end
            end)
        else
            set_status('Undo failed: ' .. tostring(err), 'error')
        end
    end)
end

-- Tab-strip band height (Community library, Task 13). The [My Prefabs]
-- [Community] tab buttons live in the top TAB_H px of the content area; the
-- whole My-Prefabs layout (relayout below) is shifted down by TAB_H so its
-- panel looks unchanged, and the window's height/min-height grow by TAB_H so
-- the grid keeps its size rather than getting squeezed.
local TAB_H = 32

-- Min dims: width drops vs. the original full-width-bottom-strip layout
-- because side-by-side place buttons no longer constrain full window
-- width; height grows to fit the new right-column control stack
-- (3 naming rows + 1 toggle row), plus TAB_H for the tab strip.
local MIN_W, MIN_H = 580, 580 + TAB_H
-- Gutter between tree and grid panes. The splitter sits centered inside
-- it with SPLITTER_MARGIN of breathing room on each side so the grab
-- bar doesn't visually butt against either pane (matches Mass Edit).
local SPLIT           = 6   -- splitter's visual thickness
local SPLITTER_MARGIN = 10  -- breathing room each side of the grab bar
local SPLIT_GUTTER    = SPLITTER_MARGIN + SPLIT + SPLITTER_MARGIN  -- 26

-- Splitter clamps: keep left column wide enough for [+New folder][Show all]
-- to fit (min ~140), and right column wide enough for [Place at original
-- location] + [Place at click] side-by-side (min ~360).
local LEFT_MIN  = 140
local RIGHT_MIN = 360

-- Single source of truth for child geometry. Called once at construction and
-- from the Window:addSizeCallback. Top band (Name + Search) sticks to the
-- top, status sticks to the bottom, action panel anchors to the bottom too,
-- the grid in the middle stretches with both dimensions.
local function relayout(w, h)
    if not W.window then return end
    local function set(widget, x, y, ww, hh)
        if widget and widget.setBounds then
            pcall(function() widget:setBounds(x, y, ww, hh) end)
        end
    end

    -- Clamp W.tree_w to the splitter's valid range BEFORE reading it. The
    -- splitter widget's set_range/set_value below also re-clamps, but only
    -- inside the widget — it doesn't write back here. Without this, the
    -- tree pane and the splitter handle drift apart on aggressive shrink.
    local max_tree_w = math.max(LEFT_MIN, w - RIGHT_MIN - SPLIT_GUTTER - 20)
    if W.tree_w < LEFT_MIN  then W.tree_w = LEFT_MIN  end
    if W.tree_w > max_tree_w then W.tree_w = max_tree_w end

    -- Row 0: Name + Fixed checkbox + Save (spans full width). The whole top
    -- band is offset by TAB_H so the tab strip (built in M.show) sits above it.
    local top0      = 8 + TAB_H
    local check_w   = 130
    local save_x    = w - 90
    local check_x   = save_x - 6 - check_w
    local input_x   = 60
    local input_w   = math.max(60, check_x - 6 - input_x)
    set(W.name_label,      10,      top0, 50,      22)
    set(W.name_input,      input_x, top0, input_w, 22)
    set(W.fixed_check,     check_x, top0, check_w, 22)
    set(W.fixed_check_lbl, check_x, top0, check_w, 22)
    set(W.save_btn,        save_x,  top0, 80,      22)

    -- Separator below the name row (was y=40, now shifted by TAB_H).
    set(W.sep1, 10, 40 + TAB_H, w - 20, 1)

    -- Row 1: search inputs (same y for both panes). The grid (and the
    -- right-column control stack below it) starts after the full
    -- SPLIT_GUTTER strip so there's 10 px of breathing room on either
    -- side of the splitter handle.
    local left_x  = 10
    local left_w  = W.tree_w
    local right_x = 10 + W.tree_w + SPLIT_GUTTER
    local right_w = w - right_x - 10

    local search_y = 51 + TAB_H
    set(W.folder_search_label, left_x,        search_y, 100, 22)
    set(W.folder_search_input, left_x + 105,  search_y, left_w - 105, 22)

    set(W.search_label, right_x,       search_y, 80,  22)
    set(W.filter_input, right_x + 84,  search_y, right_w - 84, 22)

    -- Bottom-band offsets (anchored to h).
    -- row3 / [+New folder] / [Show all] / [Reload][Undo][Rename][Delete] row.
    -- Sits above the new right-column control stack (sep2 + country + rotation +
    -- 3 naming-row placeholder + place buttons + status bar margin).
    -- Stack content = 224 px below row3 bottom edge; status top at h - 73;
    -- row3_y <= h - 305 keeps an 8 px breath between place buttons and status bar.
    local row3_y   = h - 305

    -- Tree extends FULL height of the left column — past the grid's bottom
    -- edge — to fill the space alongside the right-column bottom stack.
    -- [+ New folder] / [Show all] sit at left_bottom_y (same y as the Place
    -- buttons row on the right), so the left column terminates at the same
    -- height as the right column.
    --
    -- left_bottom_y derivation: right-column stack from row3_y down adds
    --   row_h (row3 height) + 10 (gap below row3) + 1 (sep2) + 8 (pad)
    --   + 28 (country) + 50 (rotation) + 84 (3 naming rows)
    -- which sums to row_h + 181, landing at the place buttons row's top y.
    local body_y = 77 + TAB_H
    local left_bottom_y = row3_y + 22 + 10 + 8 + 28 + 50 + 84  -- = row3_y + 202

    local tree_h = math.max(60, left_bottom_y - body_y - 8)
    local grid_h = math.max(60, row3_y         - body_y - 8)

    set(W.folder_tree, left_x,  body_y, left_w,  tree_h)
    set(W.grid,        right_x, body_y, right_w, grid_h)

    -- Splitter sits centered in the SPLIT_GUTTER strip between tree and
    -- grid, with SPLITTER_MARGIN of breathing room on each side. Y spans
    -- from the top of the search row (51) down to the bottom of the folder
    -- tree (body_y + tree_h) so the drag handle runs the full height of the
    -- folder browser, alongside the right-column form stack — not just the
    -- grid rows. It stays in the gutter column, so it never overlaps the
    -- tree, the New folder / Show all buttons, or the right-side form
    -- widgets. Range is updated every relayout so window resizes shrink the
    -- max clamp before the user can drag past RIGHT_MIN.
    local splitter_x        = 10 + W.tree_w + SPLITTER_MARGIN
    local splitter_y_top    = 51 + TAB_H
    local splitter_y_bottom = body_y + tree_h
    local splitter_h        = math.max(60, splitter_y_bottom - splitter_y_top)
    if W.splitter and W.splitter.set_bounds then
        W.splitter:set_bounds(splitter_x, splitter_y_top, SPLIT, splitter_h)
    end
    if W.splitter and W.splitter.set_range then
        W.splitter:set_range(LEFT_MIN, math.max(LEFT_MIN, w - RIGHT_MIN - SPLIT_GUTTER - 20))
    end
    if W.splitter and W.splitter.set_value then
        W.splitter:set_value(W.tree_w)
    end

    -- Left-pane buttons at left_bottom_y so they sit alongside the Place
    -- buttons row on the right. Two equal-width buttons with a 4px gap.
    local btn_gap   = 4
    local left_btn_w = math.floor((left_w - btn_gap) / 2)
    set(W.new_folder_btn, left_x,                            left_bottom_y, left_btn_w, 22)
    set(W.show_all_btn,   left_x + left_btn_w + btn_gap,     left_bottom_y, left_w - left_btn_w - btn_gap, 22)

    if W.grid and W.grid.setColumnWidth then
        local fixed_w = 0
        for i, c in ipairs(COLS) do
            if i > 1 then fixed_w = fixed_w + c.width end
        end
        local name_w = math.max(80, right_w - fixed_w)
        pcall(function() W.grid:setColumnWidth(0, name_w) end)
    end

    -- Right-pane action buttons on row3_y. Reload + Undo last placement
    -- used to sit on the left side; they've moved here so the left side
    -- can host the folder-tree controls (New folder / Show all) without
    -- splitting the action band visually.
    local reload_w, undo_w, name_w_btn, del_w = 70, 140, 80, 80
    local btn_pad = 4
    set(W.delete_btn, w - del_w - 10,                                                 row3_y, del_w,      22)
    set(W.rename_btn, w - del_w - 10 - name_w_btn - btn_pad,                          row3_y, name_w_btn, 22)
    set(W.undo_btn,   w - del_w - 10 - name_w_btn - btn_pad - undo_w - btn_pad,       row3_y, undo_w,     22)
    set(W.reload_btn, w - del_w - 10 - name_w_btn - btn_pad - undo_w - btn_pad - reload_w - btn_pad, row3_y, reload_w, 22)

    -- Right-column control stack (below the grid + Reload/Undo/Rename/Delete row).
    -- Aligns with the grid's left edge (right_x) so all right-column
    -- content sits in the same column. Vertical stack, ~30 px per row.
    local stack_x = right_x
    local stack_w = w - stack_x - 10          -- 10 px right margin
    local row_h   = 22
    local row_gap = 6
    local row_pitch = row_h + row_gap   -- 28 px

    -- Stack y bands. Top of stack = bottom of row3 + 10 (gap for visual breath).
    -- Layout from top: sep2 -> country -> rotation -> name -> prefix -> suffix -> place buttons.
    local stack_top  = row3_y + row_h + 10

    -- sep2 is right-column-only — sits between Reload/Undo/Rename/Delete
    -- and the country/rotation/naming/place stack.
    set(W.sep2, stack_x, stack_top, stack_w, 1)
    local cur_y = stack_top + 8  -- pad below separator

    -- Country row.
    set(W.country_label, stack_x, cur_y, 100, row_h)
    local combo_x = stack_x + 110
    local filter_w = 90
    local combo_w = (W.country_filter_btn) and (stack_w - 110 - filter_w - 6) or (stack_w - 110)
    set(W.country_combo, combo_x, cur_y, combo_w, row_h)
    set(W.country_filter_btn, stack_x + stack_w - filter_w, cur_y, filter_w, row_h)
    cur_y = cur_y + row_pitch

    -- Rotation row. Dial visually overlaps the spinbox column intentionally
    -- (matches the historical layout); spin sits at +70, dial overlays at +132.
    set(W.rotation_label, stack_x,           cur_y + 10, 60, row_h)
    set(W.rotation_spin,  stack_x + 70,      cur_y + 10, 60, row_h)
    set(W.rotation_dial,  stack_x + 132,     cur_y,      47, 43)
    set(W.rotation_input, stack_x + 70,      cur_y + 10, 60, row_h)
    set(W.rotation_unit,  stack_x + 132,     cur_y + 10, 20, row_h)
    -- Rotation row eats 50 px of vertical space (dial is taller than text rows).
    cur_y = cur_y + 50

    -- Naming rows: 3x [label][input], suffix row has [Keep Num] button on the right.
    -- LABEL_W widened from 56 to 90 so 'Placed name:' / 'Add prefix:' / 'Add suffix:' fit.
    local label_w     = 90
    local keep_num_w  = 90
    local gap_x       = 6

    -- Name row.
    set(W.naming_name_label, stack_x, cur_y, label_w, row_h)
    set(W.naming_name_input, stack_x + label_w + gap_x, cur_y, stack_w - label_w - gap_x, row_h)
    cur_y = cur_y + row_pitch

    -- Prefix row.
    set(W.naming_prefix_label, stack_x, cur_y, label_w, row_h)
    set(W.naming_prefix_input, stack_x + label_w + gap_x, cur_y, stack_w - label_w - gap_x, row_h)
    cur_y = cur_y + row_pitch

    -- Suffix row.
    set(W.naming_suffix_label, stack_x, cur_y, label_w, row_h)
    local suffix_input_w = stack_w - label_w - gap_x - keep_num_w - gap_x
    if suffix_input_w < 80 then suffix_input_w = 80 end
    set(W.naming_suffix_input, stack_x + label_w + gap_x, cur_y, suffix_input_w, row_h)
    set(W.naming_keep_num_btn, stack_x + stack_w - keep_num_w, cur_y, keep_num_w, row_h)
    cur_y = cur_y + row_pitch

    -- Place buttons row -- side-by-side. Same widths as before (200 + 122).
    local place_orig_w  = 200
    local place_click_w = 122
    local place_orig_x  = stack_x + stack_w - place_click_w - 6 - place_orig_w
    local place_click_x = stack_x + stack_w - place_click_w
    set(W.place_origin_btn, place_orig_x,  cur_y, place_orig_w,  row_h)
    set(W.place_click_btn,  place_click_x, cur_y, place_click_w, row_h)

    -- Reflow the Community tab's panel to the same content size so it resizes
    -- alongside the My-Prefabs panel. Safe no-op until the panel is built
    -- (first switch to the Community tab).
    if W.community and W.community ~= false and W.community.relayout then
        pcall(function() W.community:relayout(w, h) end)
    end

    -- Same deal for the Triggers tab's panel (triggers_tab self-offsets its
    -- TOP/FOOTER bands from the full content size, like community_tab).
    if W.triggers and W.triggers ~= false and W.triggers.relayout then
        pcall(function() W.triggers:relayout(w, h) end)
    end
end

-- Folder operation handlers (Task 17). Confirmations use show_overlay;
-- name prompts reuse show_rename_overlay for consistent skinning + centering.
local function on_new_folder(parent_path)
    parent_path = parent_path or W.selected_folder or ''
    show_rename_overlay(
        'Folder name (under "' .. (parent_path == '' and '(root)' or parent_path) .. '"):',
        '',
        function(name)
            name = (name or ''):gsub('^%s+', ''):gsub('%s+$', '')
            if name == '' then return end
            local valid, why = prefab_ops._validate_folder_name(name)
            if not valid then
                set_status('Folder name rejected: ' .. tostring(why), 'error')
                return
            end
            local rel = (parent_path == '' and name) or (parent_path .. '/' .. name)
            if community_config.is_community_path(rel) then
                set_status(community_config.MANAGED_MSG, 'error')
                return
            end
            local abs = require('dcs_sms_me.paths').folder_to_abs(rel):sub(1, -2)
            if require('lfs').attributes(abs) then
                set_status('Folder already exists: ' .. rel, 'error')
                return
            end
            require('dcs_sms_me.paths').ensure_prefab_folder(rel)
            set_status('Created folder "' .. rel .. '".')
            W.selected_folder = rel
            refresh_list()
        end
    )
end

local function on_rename_folder(node)
    if not node or not node.path or node.path == '' then return end
    local current_name = node.path:match('([^/]+)$')
    show_rename_overlay(
        'New name for "' .. node.path .. '":',
        current_name,
        function(new_name)
            new_name = (new_name or ''):gsub('^%s+', ''):gsub('%s+$', '')
            if new_name == '' or new_name == current_name then return end
            local ok, new_rel = prefab_ops.rename_folder(node.path, new_name)
            if not ok then
                set_status('Rename failed: ' .. tostring(new_rel), 'error')
                return
            end
            -- If the selected folder was the renamed one (or under it), rewrite.
            if W.selected_folder == node.path then
                W.selected_folder = new_rel
            elseif W.selected_folder:sub(1, #node.path + 1) == node.path .. '/' then
                W.selected_folder = new_rel .. W.selected_folder:sub(#node.path + 1)
            end
            set_status('Renamed "' .. node.path .. '" -> "' .. new_rel .. '".')
            refresh_list()
        end
    )
end

local function on_delete_folder(node)
    if not node or not node.path or node.path == '' then return end
    local files, dirs = prefab_ops.count_folder_contents(node.path)
    local function do_delete()
        local ok, err = prefab_ops.delete_folder(node.path)
        if not ok then
            set_status('Delete failed: ' .. tostring(err), 'error')
            return
        end
        if W.selected_folder == node.path or
           W.selected_folder:sub(1, #node.path + 1) == node.path .. '/' then
            W.selected_folder = ''
        end
        set_status('Deleted folder "' .. node.path .. '".')
        refresh_list()
    end
    if files == 0 and dirs == 0 then
        do_delete()
    else
        show_overlay(
            string.format('Delete folder "%s"?\n\nContains %d file(s) and %d subfolder(s). This cannot be undone.',
                node.path, files, dirs),
            {
                { label = 'Delete', on_click = do_delete },
                { label = 'Cancel', on_click = function() set_status('Delete cancelled.') end },
            },
            'warning',
            'Confirm delete'
        )
    end
end

-- Move-prefab modal (Task 18). Reuses the sms_window factory for the chrome
-- and a TreeView (or ListBox fallback) inside as the folder picker.

local function open_move_modal(row)
    if not row or row.error then return end
    local sms_window = require('dcs_sms_me.sms_window')
    local paths_mod  = require('dcs_sms_me.paths')

    local mw, mh = 360, 400
    -- Centre the modal over the Prefab Manager window so it doesn't spawn
    -- off-screen when the parent is dragged around. SMSWindow defaults to
    -- top-right of the screen otherwise. Falls back to that default if
    -- getBounds fails for any reason.
    local position
    pcall(function()
        if W.window and W.window.getBounds then
            local px, py, pw, ph = W.window:getBounds()
            if px and py and pw and ph then
                position = {
                    x = px + math.floor((pw - mw) / 2),
                    y = py + math.floor((ph - mh) / 2),
                }
            end
        end
    end)

    local modal = sms_window.new({
        title         = 'Move Prefab',
        size          = { w = mw, h = mh },
        position      = position,
        resizable     = false,
        branded_title = false,
        modal_parent  = W.window,
    })
    if not modal then return end

    local raw = modal:raw()
    local lbl = Static.new(); lbl:setText('Move "' .. row.name .. '" to folder:')
    try_skin(lbl, 'staticSkin_ME')
    raw:insertWidget(lbl)
    lbl:setBounds(10, 10, 320, 22)

    local TreeView; do local ok, m = pcall(require, 'TreeView'); if ok then TreeView = m end end
    local picker
    local picker_uses_listbox = false
    if TreeView then
        picker = TreeView.new()
    else
        local ListBox; do local ok, m = pcall(require, 'ListBox'); if ok then ListBox = m end end
        if ListBox then picker = ListBox.new(); picker_uses_listbox = true
        else            picker = Static.new(); picker:setText('(picker unavailable)')
        end
    end
    -- Skin is widget-class specific: applying listBoxSkin_ME to a TreeView
    -- causes addNode to throw on missing `check` sub-shape. Match the main
    -- tree's skin treatment (transparent panel, white text on dark
    -- background, ME teal-blue for the selected row).
    if picker_uses_listbox then
        try_skin(picker, 'listBoxSkin_ME')
    else
        apply_me_tree_skin(picker)
    end
    raw:insertWidget(picker)
    picker:setBounds(10, 40, 340, 245)

    -- Build the folder set + tree, render into the picker.
    local folder_set = walk_folders()
    local tree = build_tree(folder_set, '')
    -- Community/ is import-only — never a move destination. Drop it (and its
    -- subtree, which hangs beneath it) from the picker.
    do
        local kept = {}
        for _, child in ipairs(tree.children or {}) do
            if not community_config.is_community_path(child.path) then
                kept[#kept + 1] = child
            end
        end
        tree.children = kept
    end
    local picker_paths = {}
    local function render_picker()
        pcall(function()
            picker_paths = {}
            if picker_uses_listbox then
                if picker.removeAllItems then picker:removeAllItems()
                elseif picker.removeAll   then picker:removeAll()
                end
                local ListBoxItem; do local ok, m = pcall(require, 'ListBoxItem'); if ok then ListBoxItem = m end end
                local function walk(node, depth)
                    for _, child in ipairs(node.children or {}) do
                        if ListBoxItem and picker.insertItem then
                            local it = ListBoxItem.new()
                            it:setText(string.rep('  ', depth) .. child.name)
                            picker:insertItem(it)
                        end
                        picker_paths[#picker_paths + 1] = child.path
                        walk(child, depth + 1)
                    end
                end
                if ListBoxItem and picker.insertItem then
                    local it = ListBoxItem.new(); it:setText('(root)'); picker:insertItem(it)
                end
                picker_paths[1] = ''
                walk(tree, 1)
            else
                -- Native TreeView is node-based — same API as the main tree:
                -- addNode(text, parentNode, nil) returns a node table that we
                -- stash _sms_path on so selected_target() can recover it.
                if picker.clear then pcall(function() picker:clear() end) end
                if picker.addNode then
                    local root_node = picker:addNode('(root)', nil, nil)
                    if type(root_node) == 'table' then root_node._sms_path = '' end
                    local function add_node(data, parent_node)
                        for _, child in ipairs(data.children or {}) do
                            local n = picker:addNode(child.name, parent_node, nil)
                            if type(n) == 'table' then n._sms_path = child.path end
                            add_node(child, n)
                        end
                    end
                    add_node(tree, root_node)
                    if picker.expand then pcall(function() picker:expand() end) end
                end
            end
        end)
    end
    render_picker()

    -- Pre-select the prefab's current folder so the user can see where it
    -- lives and (typically) just confirm a different destination. Best-effort:
    -- ListBox has a uniform setSelectedItem(index) setter; TreeView items
    -- don't expose a select-by-handle API consistently across DCS versions,
    -- so we attempt it but fall back silently if it doesn't take.
    local current = row.folder or ''
    local current_idx
    for i = 1, #picker_paths do
        if picker_paths[i] == current then current_idx = i; break end
    end
    if current_idx then
        pcall(function()
            if picker_uses_listbox then
                if picker.setSelectedItem then picker:setSelectedItem(current_idx - 1) end
            else
                -- TreeView: walk all nodes via findNode-ish search to find the
                -- one whose _sms_path matches `current`, then selectNode it.
                -- Simpler: rely on the path we built and use selectNode on the
                -- root + descent. DCS TreeView's findNode takes a text-path
                -- list; we use it when current_idx > 1 (non-root). For root,
                -- just leave the picker unselected — the user can still pick
                -- the (root) row explicitly if they want.
                if current ~= '' and picker.findNode then
                    local parts = {}
                    for part in current:gmatch('[^/]+') do parts[#parts + 1] = part end
                    local node = picker:findNode(parts)
                    if node and picker.selectNode then picker:selectNode(node) end
                end
            end
        end)
    end

    local btn_move = Button.new(); btn_move:setText('Move')
    local btn_cancel = Button.new(); btn_cancel:setText('Cancel')
    try_skin(btn_move, 'sms_button'); try_skin(btn_cancel, 'sms_button')
    raw:insertWidget(btn_move);     raw:insertWidget(btn_cancel)
    btn_move:setBounds(180, 295, 80, 22)
    btn_cancel:setBounds(265, 295, 80, 22)

    local function selected_target()
        if picker_uses_listbox then
            local idx = (picker.getSelectedItem and picker:getSelectedItem()) or -1
            if type(idx) == 'number' and idx >= 0 then
                return picker_paths[idx + 1] or ''
            end
        else
            -- TreeView: getSelectedNode returns the node table (carries _sms_path).
            local node = picker.getSelectedNode and picker:getSelectedNode()
            if node and node._sms_path ~= nil then return node._sms_path end
        end
        return nil
    end

    btn_move:addChangeCallback(function()
        local target = selected_target()
        if target == nil then set_status('Pick a destination folder.', 'warning'); return end
        if target == row.folder then set_status('Already in "' .. (target == '' and '(root)' or target) .. '".', 'warning'); return end
        -- Task 6 fix changed move_prefab to (source_folder, name, target_folder).
        local ok, new_path = prefab_ops.move_prefab(row.folder or '', row.name, target)
        if not ok then
            set_status('Move failed: ' .. tostring(new_path), 'error')
            return
        end
        set_status('Moved "' .. row.name .. '" to "' .. (target == '' and '(root)' or target) .. '".')
        pcall(function() modal:hide() end)
        -- Stay on the folder we started from — jumping to the destination was
        -- jarring per user feedback. The moved prefab disappears from the
        -- current view if the current folder no longer contains it, which is
        -- the expected signal that the move succeeded.
        refresh_list()
    end)
    btn_cancel:addChangeCallback(function() pcall(function() modal:hide() end) end)

    modal:show()
end

M._on_new_folder    = on_new_folder
M._on_rename_folder = on_rename_folder
M._on_delete_folder = on_delete_folder
M._open_move_modal  = open_move_modal

function M.show()
    log.write('sms.me', log.INFO, 'window.show() called (W.window present=' .. tostring(W.window ~= nil) .. ')')

    -- Subscribe to the marquee hook once. The hook itself was installed in
    -- init.lua on bootstrap; this just attaches our window's airbase-detect
    -- handler. Guard with a one-shot flag so multiple M.show() calls don't
    -- stack subscribers in the same session.
    --
    -- Ctrl+Shift+R is a special case: M.reload() clears every dcs_sms_me.*
    -- module from package.loaded, so a fresh marquee_hook + window pair
    -- replaces this one. The OLD window's subscriber callback persists on
    -- the me_multiSelection table (we can't clear me_multiSelection because
    -- it's outside our namespace) but bails on its own getVisible() check
    -- since the old W.window is gone. To avoid silent-dead-subscriber
    -- accumulation across many reloads, we wipe the persistent list before
    -- re-subscribing.
    if not W.marquee_subscribed then
        pcall(function() marquee_hook.reset_subscribers() end)
        marquee_hook.subscribe(function(start_xy, end_xy)
            -- Bail if the prefab manager isn't currently visible — we don't
            -- want to silently capture airbases when the user can't see the
            -- prompt.
            if not (W.window and W.window.getVisible and W.window:getVisible()) then return end

            local hits = airbase_detect.airbases_in_rect(start_xy, end_xy) or {}
            if #hits == 0 then
                W.pending_airbases = nil
                return
            end

            -- Filter out default (untouched) airbases — those have unlimited
            -- everything and the user can't have meaningfully customised them.
            -- See warehouse_ops.is_default for the exact rule.
            local non_default = {}
            for _, h in ipairs(hits) do
                local entry = warehouse_ops.extract(h.airdrome_number_at_save)
                if entry and not warehouse_ops.is_default(entry) then
                    h.warehouse = entry
                    non_default[#non_default + 1] = h
                end
            end

            if #non_default == 0 then
                W.pending_airbases = nil
                set_status('Selection covers ' .. #hits .. ' airbase(s) — all unmodified, nothing to capture.')
                return
            end

            W.pending_airbases = non_default
            if #non_default == 1 then
                set_status('Airbase in selection: ' .. non_default[1].name
                           .. '. Save will include its supplies.')
            else
                local names = {}
                for _, h in ipairs(non_default) do names[#names + 1] = h.name end
                set_status(#non_default .. ' airbases in selection: '
                           .. table.concat(names, ', ') .. '. Save will include all.')
            end
        end)
        W.marquee_subscribed = true
    end

    if W.window then
        -- Re-populate so a mission-change between hides surfaces the new
        -- country list; existing selection is preserved if still valid.
        populate_country_combo()
        pcall(function() W.window:setVisible(true) end)
        -- Reset to the My Prefabs tab on every re-show (plan: default = 'my'),
        -- so re-opening never lands on a stale Community panel.
        if M._select_tab then pcall(function() M._select_tab('my') end) end
        return
    end
    local ok, err = pcall(function()
        -- Initial dims must meet MIN_W/MIN_H to avoid a squashed first-paint
        -- before SMSWindow's resize-clamp fires. Height includes TAB_H for the
        -- tab strip so the grid keeps its pre-Community size.
        local w, h = 920, 580 + TAB_H

        W.sms_window = sms_window.new({
            title    = 'Prefab Manager',
            size     = { w = w, h = h },
            min_size = { w = MIN_W, h = MIN_H },
            -- on_undo: route Ctrl+Z to the existing on_undo_click closure
            -- so the post-undo grid refresh / status messages stay intact.
            on_undo  = function() on_undo_click() end,
            -- on_resize: forward the resize to the existing relayout
            -- closure (which expects the outer window size, not the
            -- SMSWindow content rect) and re-render the grid since
            -- column-width changes can leave cells at stale positions.
            -- Uses :raw():getSize() to read the dxgui Window's outer
            -- dimensions directly rather than reconstructing them from
            -- the content-rect arguments.
            on_resize = function(swin)
                pcall(function()
                    local cw, ch = swin:raw():getSize()
                    relayout(cw, ch)
                    render_grid()
                end)
            end,
        })
        if not W.sms_window then
            log.write('sms.me', log.ERROR, 'window construction failed: SMSWindow.new returned nil')
            return
        end
        W.window = W.sms_window:raw()  -- back-compat alias

        -- Window-specific hotkeys: Escape cancels place-pending, Ctrl+Shift+R
        -- triggers the dev-loop reload. Ctrl+Z is wired by SMSWindow via
        -- the on_undo opts callback above.
        if W.window.addHotKeyCallback then
            pcall(function()
                W.window:addHotKeyCallback('escape', function()
                    if not W.place_pending then return end
                    set_status('Place cancelled.')
                    exit_place_pending()
                end)
            end)
            pcall(function()
                W.window:addHotKeyCallback('Ctrl+Shift+R', function()
                    M.reload()
                end)
            end)
        end

        -- Build a clearable_edit (EditBox + inline X-clear button) for a
        -- text-input slot in this window, falling back to a raw TextBox /
        -- Static on test VMs that don't expose EditBox. opts pass through
        -- to clearable_edit.new (initial_text, on_change, …).
        local function make_clearable_or_fallback(opts)
            opts = opts or {}
            local ce = clearable_edit.new(W.window, opts)
            if ce then return ce end
            local fb
            if TextBox then
                fb = TextBox.new()
                try_skin(fb, 'editBoxSkin_ME')
            else
                fb = Static.new()
            end
            if fb.setText then fb:setText(tostring(opts.initial_text or '')) end
            W.window:insertWidget(fb)
            return fb
        end

        -- Row 0: Name + Save. Bounds for every widget below are set by
        -- relayout(w, h) at the end of build (and on every Window resize).
        W.name_label = Static.new()
        W.name_label:setText('Name:')
        try_skin(W.name_label, 'staticSkin_ME')
        W.window:insertWidget(W.name_label)

        W.name_input = make_clearable_or_fallback({})

        W.save_btn = Button.new()
        W.save_btn:setText('Save')
        try_skin(W.save_btn, 'sms_button')
        W.save_btn:addChangeCallback(on_save_click)
        W.window:insertWidget(W.save_btn)

        -- "Fixed location" checkbox: on save, sets meta.place_at_origin so
        -- the grid shows a check in the Orig Pos column. Purely a hint —
        -- both Place buttons remain available regardless.
        if CheckBox then
            W.fixed_check = CheckBox.new('Fixed location')
            try_skin(W.fixed_check, 'checkBoxSkin_MENew')
            pcall(function() W.fixed_check:setState(false) end)
            W.window:insertWidget(W.fixed_check)
        else
            W.fixed_check_lbl = Static.new()
            W.fixed_check_lbl:setText('Fixed location (CheckBox unavailable)')
            try_skin(W.fixed_check_lbl, 'staticSkin_ME')
            W.window:insertWidget(W.fixed_check_lbl)
        end

        W.sep1 = Static.new()
        try_skin(W.sep1, 'sms_separator')
        W.window:insertWidget(W.sep1)

        -- Row 1: "Search:" label + filter input. Count of prefabs lives in
        -- the hint/placeholder text — but if the dxgui build doesn't
        -- render hints, the label keeps the row labelled.
        W.search_label = Static.new()
        W.search_label:setText('Search:')
        try_skin(W.search_label, 'staticSkin_ME')
        W.window:insertWidget(W.search_label)

        W.filter_input = make_clearable_or_fallback({
            on_change = function() on_filter_change() end,
        })

        -- Task 14 — folder browser widgets (left pane).
        -- Folder search input (left of "Search files:" — same y row).
        do
            local lbl = Static.new()
            lbl:setText('Search folders:')
            try_skin(lbl, 'staticSkin_ME')
            W.window:insertWidget(lbl)
            W.folder_search_label = lbl
        end
        W.folder_search_input = make_clearable_or_fallback({
            on_change = function(txt)
                txt = tostring(txt or '')
                if txt == W.folder_filter_text then return end
                W.folder_filter_text = txt
                if M._rebuild_tree then M._rebuild_tree() end
            end,
        })

        -- Folder tree (TreeView preferred; ListBox fallback wired in Task 16).
        local TreeView
        do local ok, m = pcall(require, 'TreeView'); if ok then TreeView = m end end
        if TreeView then
            W.folder_tree = TreeView.new()
            W.folder_tree_uses_listbox = false
        else
            local ListBox; do local ok, m = pcall(require, 'ListBox'); if ok then ListBox = m end end
            if ListBox then
                W.folder_tree = ListBox.new()
                W.folder_tree_uses_listbox = true
            else
                W.folder_tree = Static.new()
                W.folder_tree:setText('(tree widget unavailable)')
                W.folder_tree_uses_listbox = true
            end
        end
        -- Skin selection is widget-class-specific. ListBox fallback gets the
        -- stock listBoxSkin_ME via try_skin; the native TreeView path goes
        -- through apply_me_tree_skin which clones treeViewSkin_ME, repaints
        -- the panel + item colours, then applies. See that helper's header
        -- for the three empirical gotchas it encodes.
        if W.folder_tree_uses_listbox then
            try_skin(W.folder_tree, 'listBoxSkin_ME')
        else
            apply_me_tree_skin(W.folder_tree)
        end
        W.window:insertWidget(W.folder_tree)

        -- Inter-pane splitter: thin vertical drag bar between the tree and
        -- the grid. Parented to W.window so it sits in the gutter (NOT
        -- inside either pane). Constructed AFTER the tree so it inserts
        -- later in dxgui's z-order — keeps the splitter clickable even if
        -- a future gutter tweak made its x range bleed into a neighbour.
        --
        -- on_drag mutates W.tree_w and re-runs relayout, which repositions
        -- every body widget AND the splitter itself (set_value in relayout
        -- keeps the widget consistent if anyone else mutates W.tree_w).
        W.splitter = splitter_mod.new(W.window, {
            initial  = W.tree_w,
            min      = LEFT_MIN,
            max      = 800,   -- dynamically tightened in relayout via set_range
            skin     = 'sms_splitter',
            on_drag  = function(new_left_w)
                W.tree_w = new_left_w
                pcall(function()
                    if W.window and W.window.getSize then
                        local ww, wh = W.window:getSize()
                        if ww and wh then
                            relayout(ww, wh)
                        end
                    end
                end)
            end,
        })

        -- Tree selection handler — sets W.selected_folder and re-filters.
        -- Native TreeView fires onSelect with the item; we read item._sms_path.
        -- Selection handler: native TreeView fires addSelectionChangeCallback
        -- (called with `self`) and we read the selected node via
        -- getSelectedNode() — the node table carries our `_sms_path`.
        -- ListBox fallback exposes a numeric index via getSelectedItem;
        -- we map that through W._tree_listbox_paths.
        local function on_folder_path(path)
            W.selected_folder = path or ''
            apply_filter()
            render_grid()
        end
        if W.folder_tree_uses_listbox then
            local function on_listbox_select()
                W._tree_click_hit_item = true
                local idx = -1
                pcall(function() idx = (W.folder_tree.getSelectedItem and W.folder_tree:getSelectedItem()) or -1 end)
                local path = ''
                if type(idx) == 'number' and idx >= 0 and W._tree_listbox_paths then
                    path = W._tree_listbox_paths[idx + 1] or ''
                end
                on_folder_path(path)
            end
            if W.folder_tree.addSelectionChangeCallback then
                pcall(function() W.folder_tree:addSelectionChangeCallback(on_listbox_select) end)
            elseif W.folder_tree.addChangeCallback then
                pcall(function() W.folder_tree:addChangeCallback(on_listbox_select) end)
            end
        else
            -- DCS TreeView's onSelectedNodeChange override silently never
            -- fires on click in this build (verified via event-log probe —
            -- the internal `local node = item.node` deref in the constructor's
            -- selection callback likely errors before reaching our override).
            -- onNodeMouseDown DOES fire and arrives first (before the widget
            -- mouseDown below), carrying the node with our _sms_path stash —
            -- use it as the primary click signal AND to mark the click as
            -- consumed so the widget handler skips its empty-space deselect.
            -- DCS TreeView's onSelectedNodeChange override silently never
            -- fires (the constructor's internal selection callback errors on
            -- a nil-deref before reaching the override). onNodeMouseDown DOES
            -- fire and carries our node with the _sms_path stash, so use it
            -- as the primary click signal. Note: clicks below the visible
            -- items still resolve to the closest node — DCS's TreeView
            -- doesn't surface "empty space" clicks, so deselect is driven by
            -- the explicit "Show all" button below the tree (not by clicking
            -- outside an item).
            W.folder_tree.onNodeMouseDown = function(_s, node)
                local path = (node and node._sms_path) or ''
                on_folder_path(path)
            end
        end

        -- Merged Task 15 (ListBox double-click toggles collapse) + Task 19
        -- (right-click opens tree-node context menu). Merging into one
        -- addMouseDownCallback subscription avoids the risk of dxgui only
        -- supporting a single subscriber per widget — both branches fire
        -- from the same callback and dispatch by button + isDoubleClick.
        if W.folder_tree and W.folder_tree.addMouseDownCallback then
            pcall(function()
                W.folder_tree:addMouseDownCallback(function(self, x, y, button, _, isDoubleClick)
                    -- DCS dxgui delivers right-click as button == 3 (verified
                    -- empirically; matches the me_loadout.lua:1134 pattern).
                    -- Earlier draft checked button == 2 which never fired.
                    if button == 3 then
                        -- Right-click: open context menu for the selected node.
                        local path
                        if W.folder_tree_uses_listbox then
                            local idx = (self.getSelectedItem and self:getSelectedItem()) or -1
                            if type(idx) == 'number' and idx >= 0 and W._tree_listbox_paths then
                                path = W._tree_listbox_paths[idx + 1]
                            end
                        else
                            local node = self.getSelectedNode and self:getSelectedNode()
                            if node and node._sms_path then path = node._sms_path end
                        end
                        if path == nil then return end
                        local context_menu = require('dcs_sms_me.context_menu')
                        context_menu.show_for_tree_node(x, y, { path = path }, {
                            on_new    = function(parent) on_new_folder(parent) end,
                            on_rename = function(node)   on_rename_folder(node) end,
                            on_delete = function(node)   on_delete_folder(node) end,
                        })
                        return
                    end

                    -- ListBox fallback double-click toggles collapse (Task 15).
                    if W.folder_tree_uses_listbox and isDoubleClick and button == 1 then
                        local idx = (self.getSelectedItem and self:getSelectedItem()) or -1
                        if type(idx) ~= 'number' or idx < 0 then return end
                        local path2 = W._tree_listbox_paths and W._tree_listbox_paths[idx + 1]
                        if not path2 or path2 == '' then return end
                        W.folder_tree_collapse[path2] = not W.folder_tree_collapse[path2]
                        render_tree_listbox()
                    end
                end)
            end)
        end


        -- + New folder button (below the tree, left half).
        W.new_folder_btn = Button.new()
        W.new_folder_btn:setText('+ New folder')
        try_skin(W.new_folder_btn, 'sms_button')
        W.window:insertWidget(W.new_folder_btn)
        W.new_folder_btn:addChangeCallback(function() on_new_folder(W.selected_folder) end)

        -- Show all button (right half of the bottom row). DCS's TreeView
        -- can't surface empty-space clicks (clicks below items are routed to
        -- the closest node), so this button is the explicit affordance for
        -- "clear filter, show prefabs from every folder". The click runs
        -- outside the tree's mouseDown dispatch, so selectNode(nil) — which
        -- doesn't stick when called from inside a tree click — does stick
        -- here and clears the visual highlight.
        W.show_all_btn = Button.new()
        W.show_all_btn:setText('Show all')
        try_skin(W.show_all_btn, 'sms_button')
        W.window:insertWidget(W.show_all_btn)
        W.show_all_btn:addChangeCallback(function()
            on_folder_path('')
            if not W.folder_tree_uses_listbox and W.folder_tree and W.folder_tree.selectNode then
                pcall(function() W.folder_tree:selectNode(nil) end)
            end
        end)

        -- Rename the existing "Search:" label to "Search files:" for symmetry.
        if W.search_label and W.search_label.setText then
            pcall(function() W.search_label:setText('Search files:') end)
        end

        if Grid and GridHeaderCell then
            W.grid = Grid.new()
            try_skin(W.grid, 'sms_grid')

            -- Columns sized for the 420px content area (440 - 20px padding).
            -- Numeric counter columns are tight (35px); Name gets the lion's
            -- share. Definitions live module-level in COLS so refresh_list
            -- and the header-click handlers share key/numeric metadata.
            W.grid_headers = {}
            for i, c in ipairs(COLS) do
                local hc = GridHeaderCell.new()
                try_skin(hc, 'sms_grid_header')
                if hc.setText then hc:setText(c.label) end
                if hc.addChangeCallback then
                    local idx = i
                    pcall(function()
                        hc:addChangeCallback(function()
                            local key = COLS[idx].key
                            if W.sort_key == key then
                                W.sort_dir = (W.sort_dir == 'asc') and 'desc' or 'asc'
                            else
                                W.sort_key = key
                                W.sort_dir = 'asc'
                            end
                            refresh_list()
                        end)
                    end)
                end
                W.grid_headers[i] = hc
                W.grid:insertColumn(c.width, hc)
            end

            -- Mirror me_openfile.lua: Grid's default onMouseDown is empty, so
            -- mouse clicks don't change the selected row. Override it to call
            -- selectRow(row) for the clicked row, which then triggers
            -- addSelectRowCallback. Task 19 extends this with a right-click
            -- branch that opens the file-row context menu.
            W.grid.onMouseDown = function(self, x, y, button)
                if button == 1 then
                    pcall(function()
                        local _, row = self:getMouseCursorColumnRow(x, y)
                        if row and row >= 0 then
                            self:selectRow(row)
                            on_list_select()
                        end
                    end)
                elseif button == 3 then
                    -- DCS dxgui delivers right-click as button == 3 (verified
                    -- empirically; matches me_loadout.lua:1134). Earlier
                    -- draft checked button == 2 which never matched.
                    pcall(function()
                        local _, row = self:getMouseCursorColumnRow(x, y)
                        if not (row and row >= 0) then return end
                        -- Visually select the row first so the menu acts on
                        -- the row the user just right-clicked.
                        self:selectRow(row)
                        W.selected_idx = row + 1
                        on_list_select()
                        local r = W.visible_rows[row + 1]
                        if not r then return end
                        local context_menu = require('dcs_sms_me.context_menu')
                        context_menu.show_for_file_row(x, y, r, {
                            on_update = function(rr)     on_update_prefab(rr) end,
                            on_move   = function(rr)     open_move_modal(rr) end,
                            on_status = function(t, sev) set_status(t, sev) end,
                        })
                    end)
                end
            end
            -- Double-click a row → enter Place at click mode for that prefab.
            -- Select first so on_place_click sees the right selection, then
            -- invoke the same path as the Place-at-click button.
            W.grid.onMouseDoubleClick = function(self, x, y, button)
                if button ~= 1 then return end
                pcall(function()
                    local _, row = self:getMouseCursorColumnRow(x, y)
                    if not (row and row >= 0) then return end
                    self:selectRow(row)
                    on_list_select()
                    on_place_click()
                end)
            end
            if W.grid.addSelectRowCallback then
                pcall(function()
                    W.grid:addSelectRowCallback(function(_grid, _curr, _prev)
                        on_list_select()
                    end)
                end)
            end
        else
            -- Fallback: minimal Static so the window still constructs in
            -- environments missing Grid (older dxgui builds, test VMs).
            W.grid = Static.new()
            if W.grid.setText then W.grid:setText('Grid widget not available') end
        end
        W.window:insertWidget(W.grid)

        -- Row 3: library/selection actions. Reload + Undo on the left
        -- (library-wide), Rename + Delete on the right (per-selection).
        W.reload_btn = Button.new()
        W.reload_btn:setText('Reload')
        try_skin(W.reload_btn, 'sms_button')
        W.reload_btn:addChangeCallback(on_reload_click)
        W.window:insertWidget(W.reload_btn)

        W.undo_btn = Button.new()
        W.undo_btn:setText('Undo last placement')
        try_skin(W.undo_btn, 'sms_button')
        W.undo_btn:addChangeCallback(on_undo_click)
        W.window:insertWidget(W.undo_btn)

        W.rename_btn = Button.new()
        W.rename_btn:setText('Rename')
        try_skin(W.rename_btn, 'sms_button')
        W.rename_btn:addChangeCallback(on_rename_click)
        W.window:insertWidget(W.rename_btn)

        W.delete_btn = Button.new()
        W.delete_btn:setText('Delete')
        try_skin(W.delete_btn, 'sms_button')
        W.delete_btn:addChangeCallback(on_delete_click)
        W.window:insertWidget(W.delete_btn)

        W.sep2 = Static.new()
        try_skin(W.sep2, 'sms_separator')
        W.window:insertWidget(W.sep2)

        -- Row 4: Country picker.
        W.country_label = Static.new()
        W.country_label:setText('Place as country:')
        try_skin(W.country_label, 'staticSkin_ME')
        W.window:insertWidget(W.country_label)

        -- Combat/All toggle on the right edge of the row, mirroring the
        -- ME's airplane-group panel (tbFilter). State=false → "Combat"
        -- (only red+blue countries shown). State=true → "All" (everything,
        -- including neutrals).
        if ToggleButton then
            W.country_filter_btn = ToggleButton.new()
            W.country_filter_btn:setText('Combat')
            try_skin(W.country_filter_btn, 'sms_button')
            if W.country_filter_btn.addChangeCallback then
                pcall(function()
                    W.country_filter_btn:addChangeCallback(function(self)
                        local on = self.getState and self:getState() or false
                        pcall(function() self:setText(on and 'All' or 'Combat') end)
                        populate_country_combo()
                    end)
                end)
            end
            W.window:insertWidget(W.country_filter_btn)
        end

        if ComboList then
            W.country_combo = ComboList.new()
            try_skin(W.country_combo, 'comboListSkinNew_')
            W.window:insertWidget(W.country_combo)
        else
            -- Fallback: a Static so the row still renders. populate is a
            -- no-op without ComboList; place falls back to stored country.
            W.country_combo = Static.new()
            W.country_combo:setText('(ComboList unavailable)')
            try_skin(W.country_combo, 'staticSkin_ME')
            W.window:insertWidget(W.country_combo)
        end

        -- Row 5: Rotation gizmo + place buttons. Row is 43px tall (dial
        -- height). Spinbox + label are vertically centered against the
        -- dial. Dial + SpinBox wired via W.rotation_deg, mirroring
        -- me_static.lua's d_heading / e_heading; TextBox fallback when
        -- Dial / SpinBox aren't available (test VMs).
        W.rotation_label = Static.new()
        W.rotation_label:setText('Rotation:')
        try_skin(W.rotation_label, 'staticSkin_ME')
        W.window:insertWidget(W.rotation_label)

        if SpinBox and Dial then
            W.rotation_spin = SpinBox.new()
            try_skin(W.rotation_spin, 'spinBoxSkin_MENew')
            pcall(function() W.rotation_spin:setRange(-1, 360) end)
            pcall(function() W.rotation_spin:setStep(1) end)
            pcall(function() W.rotation_spin:setPageStep(10) end)
            pcall(function() W.rotation_spin:setCheckRange(true) end)
            pcall(function() W.rotation_spin:setAcceptDecimalPoint(false) end)
            pcall(function() W.rotation_spin:setValue(0) end)
            pcall(function() W.rotation_spin:setTooltipText('Placement rotation (°, clockwise)') end)
            if W.rotation_spin.addChangeCallback then
                pcall(function() W.rotation_spin:addChangeCallback(on_rotation_spin_change) end)
            end
            W.window:insertWidget(W.rotation_spin)

            W.rotation_dial = Dial.new()
            try_skin(W.rotation_dial, 'sms_dial')
            pcall(function() W.rotation_dial:setRange(0, 359) end)
            pcall(function() W.rotation_dial:setStep(1) end)
            pcall(function() W.rotation_dial:setPageStep(10) end)
            pcall(function() W.rotation_dial:setCyclic(true) end)
            pcall(function() W.rotation_dial:setValue(0) end)
            pcall(function() W.rotation_dial:setTooltipText('Placement rotation (°, clockwise)') end)
            if W.rotation_dial.addChangeCallback then
                pcall(function() W.rotation_dial:addChangeCallback(on_rotation_dial_change) end)
            end
            W.window:insertWidget(W.rotation_dial)
        else
            -- Fallback path: legacy TextBox + ° label, same as before the
            -- Dial/SpinBox upgrade. Writes into W.rotation_deg via the
            -- change callback so get_rotation_deg() works uniformly.
            if TextBox then
                W.rotation_input = TextBox.new()
            else
                W.rotation_input = Static.new()
            end
            if W.rotation_input.setText then W.rotation_input:setText('0') end
            try_skin(W.rotation_input, 'editBoxSkin_ME')
            if W.rotation_input.addChangeCallback then
                pcall(function()
                    W.rotation_input:addChangeCallback(function(self)
                        W.rotation_deg = normalize_deg((self.getText and self:getText()) or '0')
                    end)
                end)
            end
            W.window:insertWidget(W.rotation_input)

            W.rotation_unit = Static.new()
            W.rotation_unit:setText('°')
            try_skin(W.rotation_unit, 'staticSkin_ME')
            W.window:insertWidget(W.rotation_unit)
        end

        -- Naming form widgets. Sticky values; read at placement time
        -- (wired in Task 11). Three label+input rows for Name / Prefix /
        -- Suffix, plus a default-ON "Keep Num" ToggleButton next to the
        -- suffix input that controls whether the suffix is inserted
        -- BEFORE a trailing -<n> / _<n> token so auto-numbered names
        -- stay sortable. Each widget is independently pcall-guarded so a
        -- missing dxgui binding leaves the field nil — read_naming_opts
        -- treats nil as empty.
        pcall(function()
            if Static and Static.new then
                W.naming_name_label = Static.new('Placed name:')
                try_skin(W.naming_name_label, 'staticSkin_ME')
                W.window:insertWidget(W.naming_name_label)

                W.naming_prefix_label = Static.new('Add prefix:')
                try_skin(W.naming_prefix_label, 'staticSkin_ME')
                W.window:insertWidget(W.naming_prefix_label)

                W.naming_suffix_label = Static.new('Add suffix:')
                try_skin(W.naming_suffix_label, 'staticSkin_ME')
                W.window:insertWidget(W.naming_suffix_label)
            end
        end)

        pcall(function()
            W.naming_name_input   = clearable_edit.new(W.window, {})
            W.naming_prefix_input = clearable_edit.new(W.window, {})
            W.naming_suffix_input = clearable_edit.new(W.window, {})
        end)

        pcall(function()
            if ToggleButton and ToggleButton.new then
                local t = ToggleButton.new()
                try_skin(t, 'sms_button')
                if t.setText  then pcall(t.setText,  t, 'Keep Num') end
                if t.setState then pcall(t.setState, t, true) end
                if t.setTooltipText then
                    pcall(t.setTooltipText, t,
                        'When ON, suffix is inserted BEFORE the trailing -<n>/_<n> ' ..
                        'so an auto-numbered name stays sortable.')
                end
                W.naming_keep_num_btn = t
                W.window:insertWidget(t)
            end
        end)

        -- Tooltips for the inputs. clearable_edit doesn't proxy
        -- setTooltipText, so attach to the underlying EditBox via
        -- :widget() — that's the raw control that actually renders the
        -- tooltip on hover.
        pcall(function()
            local function tip(input, text)
                if not input then return end
                local raw = (input.widget and input:widget()) or nil
                if raw and raw.setTooltipText then
                    pcall(raw.setTooltipText, raw, text)
                elseif input.setTooltipText then
                    pcall(input.setTooltipText, input, text)
                end
            end
            tip(W.naming_name_input,
                'On placement: renames every group + static. Use {n} for an ' ..
                'index (Tank-{n} -> Tank-01, Tank-02). Then runs auto-name-' ..
                'units on each group.')
            tip(W.naming_prefix_input,
                'On placement: prepends to every group, static, zone, and ' ..
                'drawing. Then runs auto-name-units on each group.')
            tip(W.naming_suffix_input,
                'On placement: appends to every group, static, zone, and ' ..
                'drawing. Then runs auto-name-units on each group. Toggle ' ..
                '"Keep Num" inserts the suffix BEFORE a trailing -<n>.')
        end)

        W.place_origin_btn = Button.new()
        W.place_origin_btn:setText('Place at original location')
        try_skin(W.place_origin_btn, 'sms_button')
        W.place_origin_btn:addChangeCallback(on_place_origin_click)
        W.window:insertWidget(W.place_origin_btn)

        W.place_click_btn = Button.new()
        W.place_click_btn:setText('Place at click')
        try_skin(W.place_click_btn, 'sms_button')
        W.place_click_btn:addChangeCallback(on_place_click)
        W.window:insertWidget(W.place_click_btn)

        relayout(w, h)

        refresh_list()
        populate_country_combo()

        -- ===================================================================
        -- Task 13: [My Prefabs] [Community] tab strip.
        --
        -- The whole existing layout above is the "My Prefabs" panel; the
        -- relayout offset (TAB_H) leaves the top band free for two tab
        -- buttons. The Community panel (community_tab.lua) is built lazily the
        -- first time its tab is selected, parented under the same window, and
        -- shown/hidden alongside the My-Prefabs widgets. Everything here is
        -- pcall-guarded: if community_tab can't build, the manager keeps
        -- working with only the My-Prefabs tab.
        -- ===================================================================
        pcall(function()
            -- Collect the top-level My-Prefabs widget handles so they can be
            -- hidden/shown en masse. Visibility-toggling (not re-parenting) is
            -- enough — these widgets are all direct children of W.window.
            W.my_prefab_widgets = {
                W.name_label, W.name_input, W.save_btn,
                W.fixed_check, W.fixed_check_lbl, W.sep1,
                W.search_label, W.filter_input,
                W.folder_search_label, W.folder_search_input,
                W.folder_tree, W.splitter,
                W.new_folder_btn, W.show_all_btn,
                W.grid,
                W.reload_btn, W.undo_btn, W.rename_btn, W.delete_btn,
                W.sep2,
                W.country_label, W.country_combo, W.country_filter_btn,
                W.rotation_label, W.rotation_spin, W.rotation_dial,
                W.rotation_input, W.rotation_unit,
                W.naming_name_label, W.naming_name_input,
                W.naming_prefix_label, W.naming_prefix_input,
                W.naming_suffix_label, W.naming_suffix_input,
                W.naming_keep_num_btn,
                W.place_origin_btn, W.place_click_btn,
            }

            -- Show/hide every My-Prefabs widget. MUST use pairs, not ipairs:
            -- the list contains conditionally-created widgets (only ONE of
            -- rotation_dial/rotation_spin/rotation_input exists; CheckBox /
            -- splitter may be absent), so it has nil holes — ipairs would stop
            -- at the first hole and leave the rest of the panel visible. pairs
            -- visits every non-nil entry regardless of holes. Handles the
            -- visibility shapes in play: raw dxgui widgets + clearable_edit
            -- (setVisible/set_visible) and the splitter (show/hide only).
            local function set_my_prefabs_visible(vis)
                for _, wdg in pairs(W.my_prefab_widgets) do
                    if wdg.setVisible then
                        pcall(function() wdg:setVisible(vis) end)
                    elseif wdg.set_visible then
                        pcall(function() wdg:set_visible(vis) end)
                    elseif vis and wdg.show then
                        pcall(function() wdg:show() end)
                    elseif (not vis) and wdg.hide then
                        pcall(function() wdg:hide() end)
                    end
                end
            end

            -- Lazily build the Community panel exactly once. Returns true on
            -- success. On failure, logs and leaves W.community nil so
            -- select_tab falls back to the My-Prefabs tab.
            local function ensure_community()
                if W.community ~= nil then return W.community ~= false end
                local ok_build, panel = pcall(function()
                    return require('dcs_sms_me.community_tab').build(W.window, {
                        set_status        = set_status,
                        refresh_my_library = refresh_list,
                    })
                end)
                if not ok_build or not panel then
                    W.community = false  -- sentinel: build failed, don't retry
                    log.write('sms.me', log.ERROR,
                        'Community tab build failed: ' .. tostring(panel))
                    return false
                end
                W.community = panel
                -- Lay the freshly-built panel out to the current content size
                -- (the manager's last relayout ran before this lazy build).
                pcall(function()
                    if W.community.relayout and W.window and W.window.getSize then
                        local ww, wh = W.window:getSize()
                        if ww and wh then W.community:relayout(ww, wh) end
                    end
                end)
                -- Panels start hidden; My Prefabs is the default tab.
                pcall(function() W.community:hide() end)
                -- Register the community tick once (guarded against double
                -- registration, mirroring the marquee-subscribe one-shot).
                if UpdateManager and UpdateManager.add and W.community.tick
                   and not W.community_tick_added then
                    pcall(function()
                        UpdateManager.add(function() pcall(W.community.tick) end)
                    end)
                    W.community_tick_added = true
                end
                return true
            end

            -- Lazy-build the Triggers tab panel (mirrors ensure_community).
            -- Returns truthy when the panel is usable; false caches a failed
            -- build for the session so we don't retry every click.
            local function ensure_triggers()
                if W.triggers ~= nil then return W.triggers end
                local ok_build, panel = pcall(function()
                    local triggers_tab = require('dcs_sms_me.triggers_tab')
                    return triggers_tab.build({
                        raw = W.window,
                        set_status = set_status,
                        refresh_library = refresh_list,
                    })
                end)
                W.triggers = (ok_build and panel) or false
                if W.triggers == false then
                    log.write('sms.me.prefab', log.ERROR,
                        'triggers tab build failed: ' .. tostring(panel))
                    return W.triggers
                end
                -- Lay the freshly-built panel out to the current content size
                -- (triggers_tab.build self-laid-out at its default size only).
                pcall(function()
                    if W.triggers.relayout and W.window and W.window.getSize then
                        local ww, wh = W.window:getSize()
                        if ww and wh then W.triggers:relayout(ww, wh) end
                    end
                end)
                return W.triggers
            end

            -- Reflect the active tab via a skin swap (mirrors Mass Edit's
            -- scope tabs): the active tab gets the gold 'sms_tab' skin, the
            -- inactive one 'sms_tab_off'. The recursion guard stops the
            -- programmatic setState below from re-entering the tab change
            -- callbacks (same pattern as mass_edit.set_tab_state).
            local _tab_set_internal = false
            local function set_tab_state(tab, on)
                if not tab then return end
                try_skin(tab, on and 'sms_tab' or 'sms_tab_off')
                if tab.setState then
                    _tab_set_internal = true
                    pcall(function() tab:setState(on) end)
                    _tab_set_internal = false
                end
            end

            local function update_tab_buttons()
                set_tab_state(W.tab_my_btn,        W.active_tab == 'my')
                set_tab_state(W.tab_community_btn, W.active_tab == 'community')
                set_tab_state(W.tab_triggers_btn,  W.active_tab == 'triggers')
            end

            -- Switch tabs. 'my' always works; 'community' and 'triggers'
            -- fall back to 'my' if their panel couldn't be built.
            local function select_tab(which)
                if which == 'community' then
                    if not ensure_community() then which = 'my' end
                elseif which == 'triggers' then
                    if not ensure_triggers() then which = 'my' end
                end
                W.active_tab = which
                if which == 'community' then
                    set_my_prefabs_visible(false)
                    pcall(function()
                        if W.triggers and W.triggers ~= false then W.triggers:hide() end
                    end)
                    pcall(function() W.community:show() end)
                    -- First switch kicks the once-per-session auto-sync.
                    if not W.community_first_shown then
                        W.community_first_shown = true
                        pcall(function() W.community:on_first_show() end)
                    end
                elseif which == 'triggers' then
                    set_my_prefabs_visible(false)
                    if W.community and W.community ~= false then
                        pcall(function() W.community:hide() end)
                    end
                    -- show() re-reads the trigger list from mission.trigrules.
                    pcall(function() W.triggers:show() end)
                else
                    if W.community and W.community ~= false then
                        pcall(function() W.community:hide() end)
                    end
                    pcall(function()
                        if W.triggers and W.triggers ~= false then W.triggers:hide() end
                    end)
                    set_my_prefabs_visible(true)
                end
                update_tab_buttons()
            end
            M._select_tab = select_tab  -- exposed for smoke/debug

            -- Tab buttons live in the top TAB_H band (above the name row).
            -- ToggleButton so the active tab can stay visually 'pressed' via
            -- the gold skin (set_tab_state); falls back to Button if the
            -- ToggleButton class isn't bound. The change callback bails when
            -- _tab_set_internal is set (our own setState echo).
            local function make_tab(label, which)
                local btn
                if ToggleButton and ToggleButton.new then
                    local ok_b, b = pcall(ToggleButton.new)
                    if ok_b then btn = b end
                end
                if not btn then btn = Button.new() end
                if btn.setText then pcall(function() btn:setText(label) end) end
                if btn.addChangeCallback then
                    btn:addChangeCallback(function()
                        if _tab_set_internal then return end
                        pcall(function() select_tab(which) end)
                    end)
                end
                W.window:insertWidget(btn)
                return btn
            end
            W.tab_my_btn        = make_tab('My Prefabs', 'my')
            W.tab_community_btn = make_tab('Community', 'community')
            W.tab_triggers_btn  = make_tab('Triggers', 'triggers')

            -- Position the three tabs at the very top, left-aligned.
            local tab_y, tab_h, tab_w, tab_gap = 4, 24, 110, 4
            pcall(function() W.tab_my_btn:setBounds(10, tab_y, tab_w, tab_h) end)
            pcall(function() W.tab_community_btn:setBounds(10 + tab_w + tab_gap, tab_y, tab_w, tab_h) end)
            pcall(function() W.tab_triggers_btn:setBounds(10 + 2 * (tab_w + tab_gap), tab_y, tab_w, tab_h) end)

            -- Default to the My Prefabs tab.
            W.active_tab = 'my'
            update_tab_buttons()
        end)
    end)
    if not ok then
        log.write('sms.me', log.ERROR, 'window construction failed: ' .. tostring(err))
        W.sms_window = nil
        W.window = nil
        return
    end
    log.write('sms.me', log.INFO, 'Prefab Manager window opened')
end

function M.hide()
    -- Route through W.sms_window:hide() so opts.on_close fires (no consumer
    -- uses it today, but the menu.lua hideME patch calls M.hide() externally
    -- and any future cleanup hook should run from that path too). Falls back
    -- to a direct dxgui call if the handle is missing — defensive only; in
    -- practice if W.sms_window is nil we never opened the window.
    if W.sms_window then
        W.sms_window:hide()
    else
        pcall(function()
            if W.window and W.window.setVisible then W.window:setVisible(false) end
        end)
    end
end

function M.toggle()
    if W.sms_window then
        W.sms_window:toggle()
    else
        M.show()
    end
end

-- Tear down the visible window. Used by the dev reload before clearing
-- package.loaded — the dxgui Lua bind has no explicit destroy(), but
-- hiding + dropping our reference removes the window from the visible
-- scene graph and lets the next module instance start from scratch.
-- The OLD W table goes away with the module when package.loaded clears.
function M.dispose()
    pcall(function()
        if W.window and W.window.setVisible then W.window:setVisible(false) end
    end)
end

-- Dev-loop helper: dispose, clear package.loaded for our modules, then
-- re-require the bootstrap. Lets you iterate on Lua without restarting
-- DCS. Works cleanly because the Customize-menu item's click callback
-- (set in menu.lua) does `require('dcs_sms_me.prefab_manager')` AT CLICK TIME,
-- not at registration — so once package.loaded is cleared, the menu
-- entry naturally picks up the new code on the next click. The menu
-- widget itself is in the dxgui scene and outlives the require, and
-- add_menu_entry's `_dcs_sms_prefab_added` idempotency flag prevents a
-- duplicate entry on the re-bootstrap.
function M.reload()
    log.write('sms.me', log.INFO, 'dev reload triggered')
    pcall(M.dispose)

    local cleared = {}
    for k in pairs(package.loaded) do
        if type(k) == 'string' and k:find('^dcs_sms_me') then
            cleared[#cleared + 1] = k
        end
    end
    for _, k in ipairs(cleared) do package.loaded[k] = nil end
    log.write('sms.me', log.INFO, 'cleared ' .. #cleared .. ' modules from package.loaded')

    -- Re-require the bootstrap. Any error surfaces in dcs.log; the old
    -- window is already gone so a failed reload leaves the user with
    -- "no Prefab Manager" rather than a half-broken one.
    local ok, err = pcall(require, 'dcs_sms_me.init')
    if not ok then
        log.write('sms.me', log.ERROR, 'reload failed: ' .. tostring(err))
        return false, tostring(err)
    end
    log.write('sms.me', log.INFO, 'dev reload completed')

    -- Show the freshly reloaded window. We have to go through the new
    -- module — our M is the OLD one; the just-required init.lua already
    -- reset package.loaded['dcs_sms_me.prefab_manager'], so a fresh require picks
    -- up the new code.
    pcall(function()
        local fresh = require('dcs_sms_me.prefab_manager')
        if fresh and fresh.show then fresh.show() end
    end)
    return true
end

return M
