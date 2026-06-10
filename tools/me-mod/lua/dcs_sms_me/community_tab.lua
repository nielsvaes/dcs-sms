-- community_tab.lua — the Community tab body inside the Prefab Manager.
--
-- Browses a vetted, GitHub-hosted prefab catalog over HTTPS and imports
-- prefabs into the user's library. All network + parsing happens behind the
-- already-tested community_* modules; this file owns only the widgets, their
-- layout, and the fetch/import wiring.
--
-- The fetch is non-blocking: a community_fetch job is pumped one :step() per
-- UpdateManager tick via panel_handle:tick(). The tab shows the last cached
-- catalog immediately on build so it's never empty, then auto-syncs the first
-- time it's shown in a session (and on the manual ⟳ Refresh button).
--
-- EVERYTHING here is pcall-guarded — no error may escape a callback or tick()
-- (ME-mod AGENTS.md §2.11). Even the dxgui widget requires are pcall-guarded
-- so the module at least loads in a non-DCS environment where a widget is
-- missing.
--
-- Public:
--   M.build(parent, deps) -> panel_handle
--     deps = { set_status = fn(text, severity), refresh_my_library = fn() }
--   panel_handle:show() / :hide()        — visibility
--   panel_handle:on_first_show()         — kicks the once-per-session auto-sync
--   panel_handle:tick()                  — pumps an in-flight job; no-op when idle

-- ---------------------------------------------------------------------------
-- dxgui widget requires — pcall-guarded exactly like prefab_manager.lua so a
-- missing widget never errors the module at load time.
-- ---------------------------------------------------------------------------
local Static;        do local ok, m = pcall(require, 'Static');        if ok then Static        = m end end
local Button;        do local ok, m = pcall(require, 'Button');        if ok then Button        = m end end
local Grid;          do local ok, m = pcall(require, 'Grid');          if ok then Grid          = m end end
local GridHeaderCell;do local ok, m = pcall(require, 'GridHeaderCell');if ok then GridHeaderCell = m end end
local ToggleButton;  do local ok, m = pcall(require, 'ToggleButton');  if ok then ToggleButton  = m end end

-- Text-input class: EditBox is canonical, TextBox an older alias. Mirrors
-- prefab_manager.lua's resolution so the search box works on either build.
local TextBox
do
    local ok, mod = pcall(require, 'EditBox')
    if ok then TextBox = mod
    else
        local ok2, mod2 = pcall(require, 'TextBox')
        if ok2 then TextBox = mod2 end
    end
end

-- Skin module + house skins, both guarded. try_skin below leans on these but
-- degrades silently if either is unavailable.
local Skin;      do local ok, m = pcall(require, 'Skin');                    if ok then Skin      = m end end
local sms_skins; do local ok, m = pcall(require, 'dcs_sms_me.sms_skins');    if ok then sms_skins = m end end

-- clearable_edit gives us the same EditBox + inline ×-clear used by the
-- "My Prefabs" search box; we fall back to a raw TextBox/Static if it's
-- unavailable (test VM / older dxgui).
local clearable_edit; do local ok, m = pcall(require, 'dcs_sms_me.clearable_edit'); if ok then clearable_edit = m end end

-- Vertical drag splitter (the same module the My-Prefabs tree/grid splitter
-- uses) so the Community-tab description column can be resized. Guarded so a
-- load failure in a non-DCS VM just disables it (W.splitter stays nil).
local splitter_mod; do local ok, m = pcall(require, 'dcs_sms_me.splitter'); if ok then splitter_mod = m end end

-- Themed editbox skin (house look + thin scrollbars) for the read-only,
-- multi-line detail box. Guarded; falls back to editBoxSkin_ME if unavailable.
local sms_scrollbars; do local ok, m = pcall(require, 'dcs_sms_me.sms_scrollbars'); if ok then sms_scrollbars = m end end

-- ---------------------------------------------------------------------------
-- Logic modules (all implemented + unit-tested). These are pure Lua and load
-- fine anywhere, but guard the requires too so a single missing dependency
-- can't take down the whole module load.
-- ---------------------------------------------------------------------------
local cfg;        do local ok, m = pcall(require, 'dcs_sms_me.community_config');    if ok then cfg        = m end end
local manifest;   do local ok, m = pcall(require, 'dcs_sms_me.community_manifest');  if ok then manifest   = m end end
local fetch;      do local ok, m = pcall(require, 'dcs_sms_me.community_fetch');     if ok then fetch      = m end end
local importer;   do local ok, m = pcall(require, 'dcs_sms_me.community_import');    if ok then importer   = m end end
local cache;      do local ok, m = pcall(require, 'dcs_sms_me.community_cache');     if ok then cache      = m end end
local transport;  do local ok, m = pcall(require, 'dcs_sms_me.community_transport'); if ok then transport  = m end end
local json;       do local ok, m = pcall(require, 'dcs_sms_me.vendor.json');         if ok then json       = m end end

-- Apply a skin by name, fully guarded. Copied from prefab_manager.lua's
-- try_skin shape (the codebase keeps a local copy per module). Only the skin
-- names this tab actually uses are wired; anything else falls through to the
-- Skin module's generated builders.
local function try_skin(widget, skin_name)
    pcall(function()
        if not (widget and widget.setSkin) then return end
        local s
        if sms_skins then
            if     skin_name == 'sms_button'      then s = sms_skins.button()
            elseif skin_name == 'sms_grid'        then s = sms_skins.grid()
            elseif skin_name == 'sms_grid_header' then s = sms_skins.grid_header()
            elseif skin_name == 'sms_separator'   then s = sms_skins.separator()
            end
        end
        if not s and Skin then
            local fn = Skin[skin_name]
            if fn then s = fn() end
        end
        if s then widget:setSkin(s) end
    end)
end

local M = {}

-- ---------------------------------------------------------------------------
-- Grid columns. Module-level so render + selection share the layout.
-- ---------------------------------------------------------------------------
local COLS = {
    { key = 'name',    label = 'Name',    width = 220, numeric = false },
    { key = 'author',  label = 'Author',  width = 120, numeric = false },
    { key = 'likes',   label = '\226\153\165', width = 45, numeric = true },  -- ♥ (UTF-8)
    { key = 'theatre', label = 'Theatre', width = 110, numeric = false },
}

local function find_col(key)
    for i, c in ipairs(COLS) do if c.key == key then return c, i end end
end

-- Generic stable sort by a column key + direction ('asc'|'desc'). Mirrors
-- prefab_manager.sort_rows: numeric columns compare as numbers, others
-- case-insensitively as strings, with the pre-sort index as a stable
-- tiebreaker. Sorting lives here (header-click driven) rather than in
-- community_manifest because the grid sorts by any column in either
-- direction, which manifest.sort (fixed likes/name/newest) doesn't cover.
local function sort_entries(list, key, dir)
    local col = find_col(key)
    local numeric = col and col.numeric
    local asc = (dir ~= 'desc')
    for i, e in ipairs(list) do e._sidx = i end
    table.sort(list, function(a, b)
        local av, bv = a[key], b[key]
        if numeric then av, bv = tonumber(av) or 0, tonumber(bv) or 0
        else av, bv = tostring(av or ''):lower(), tostring(bv or ''):lower() end
        if av == bv then return a._sidx < b._sidx end
        if asc then return av < bv else return av > bv end
    end)
    for _, e in ipairs(list) do e._sidx = nil end
end

-- ---------------------------------------------------------------------------
-- Per-instance builder. Returns a panel_handle. Each call gets its own W so a
-- (hypothetical) second instance wouldn't share state.
-- ---------------------------------------------------------------------------
function M.build(parent, deps)
    deps = deps or {}
    local set_status_fn      = deps.set_status      or function() end
    local refresh_my_library = deps.refresh_my_library or function() end

    local function set_status(text, severity)
        pcall(set_status_fn, tostring(text or ''), severity)
    end

    -- Instance state — mirrors prefab_manager.lua's W pattern.
    local W = {
        widgets    = {},     -- every top-level widget, for show/hide en masse
        chips      = {},     -- tag-chip ToggleButtons (rebuilt on each sync)
        entries    = {},     -- full manifest entries
        visible    = {},     -- filtered + sorted subset shown in the grid
        selected_idx = nil,  -- index into W.visible
        search_text  = '',
        sort_key     = 'likes',  -- default: most-loved first
        sort_dir     = 'desc',   -- toggled by clicking the column header
        grid_headers = {},    -- GridHeaderCell per column, for re-texting on sort
        active_tags  = {},    -- map tag -> true
        job          = nil,   -- in-flight community_fetch job
        job_kind     = nil,   -- 'manifest' | 'file'
        pending_import = nil, -- entry awaiting a file fetch → import
        last_synced  = nil,   -- 'HH:MM' string
        did_first_sync = false,
        -- Right-column chip-band geometry, set by relayout(); layout_chips reads it.
        chips_x = 0, chips_y = 0, chips_w = 300,
        -- Right-column (detail/description) width, dragged by the splitter.
        -- Was the constant DETAIL_W; now mutable so the user can resize it.
        detail_w = 300,
    }

    -- Register a widget for bulk show/hide and parent it under the window.
    local function track(widget)
        if not widget then return widget end
        W.widgets[#W.widgets + 1] = widget
        pcall(function()
            if parent and parent.insertWidget then parent:insertWidget(widget) end
        end)
        return widget
    end

    -- Build a Static cell widget for a Grid cell (prefab_manager.make_cell).
    local function make_cell(text, tooltip)
        local s = Static and Static.new(tostring(text or ''))
        if not s then return s end
        try_skin(s, 'staticSkin_ME')
        if tooltip and s.setTooltipText then
            pcall(function() s:setTooltipText(tostring(tooltip)) end)
        end
        return s
    end

    -- -----------------------------------------------------------------------
    -- Layout spacing. The actual widget bounds are computed responsively in
    -- relayout(cw, ch) (called at build and on every window resize) from the
    -- parent window's content size, so the panel reflows like the My-Prefabs
    -- panel does.
    -- -----------------------------------------------------------------------
    local PAD   = 12
    local ROW_H = 24
    local TOP   = 44   -- below the manager's tab strip
    local GAP   = 6

    -- Splitter geometry (mirrors prefab_manager): a SPLIT-thick grab bar
    -- centered in a SPLIT_GUTTER strip with SPLITTER_MARGIN of breathing room
    -- on each side. DETAIL_MIN / GRID_MIN keep both panes usable as the
    -- splitter (and window resizes) push the boundary around.
    local SPLIT           = 6
    local SPLITTER_MARGIN = 10
    local SPLIT_GUTTER    = SPLITTER_MARGIN + SPLIT + SPLITTER_MARGIN  -- 26
    local DETAIL_MIN      = 200   -- description column never narrower than this
    local GRID_MIN        = 300   -- the entry list never narrower than this

    -- Set bounds, guarded.
    local function bounds(widget, x, y, w, h)
        if not widget then return end
        pcall(function()
            if widget.setBounds then widget:setBounds(x, y, w, h) end
        end)
    end

    -- -----------------------------------------------------------------------
    -- Detail block. Populated from the selected entry; cleared otherwise.
    -- -----------------------------------------------------------------------
    local function entry_detail_text(e)
        if not e then return 'Select a prefab to see its details.' end
        local lines = {}
        lines[#lines + 1] = e.name or ''
        if e.author and e.author ~= '' then lines[#lines + 1] = 'by ' .. e.author end
        lines[#lines + 1] = ''
        local meta = {}
        if (e.likes or 0) > 0 then meta[#meta + 1] = '\226\153\165 ' .. tostring(e.likes) end
        if e.theatre and e.theatre ~= '' then meta[#meta + 1] = e.theatre end
        if e.date and e.date ~= '' then meta[#meta + 1] = e.date end
        if #meta > 0 then lines[#lines + 1] = table.concat(meta, '   ') end
        if e.tags and #e.tags > 0 then
            lines[#lines + 1] = 'tags: ' .. table.concat(e.tags, ', ')
        end
        -- Entity counts — only show non-zero so the block stays tidy.
        local counts = {}
        local function add_count(label, n) if (n or 0) > 0 then counts[#counts + 1] = n .. ' ' .. label end end
        add_count('groups',   e.groups)
        add_count('statics',  e.statics)
        add_count('zones',    e.zones)
        add_count('drawings', e.drawings)
        add_count('airbases', e.airbases)
        if #counts > 0 then lines[#lines + 1] = table.concat(counts, ', ') end
        if e.description and e.description ~= '' then
            lines[#lines + 1] = ''
            lines[#lines + 1] = e.description
        end
        return table.concat(lines, '\n')
    end

    -- Forward decl (callbacks below reference these before assignment).
    local render_grid, recompute_visible, rebuild_chips, do_refresh
    local update_detail, update_import_btn, selected_entry, on_import_click
    local update_header_labels, on_header_click, relayout, layout_chips

    selected_entry = function()
        if not W.selected_idx then return nil end
        return W.visible[W.selected_idx]
    end

    update_import_btn = function()
        pcall(function()
            if not W.import_btn then return end
            local e = selected_entry()
            local imported = false
            if e and importer and importer.is_imported then
                local ok, res = pcall(importer.is_imported, e)
                imported = ok and res == true
            end
            if W.import_btn.setText then
                W.import_btn:setText(imported and 'Imported \226\156\147' or '\239\188\139 Add to my library')
            end
            -- NOTE: intentionally NOT using setEnabled here — a disabled dxgui
            -- Button can render with no visible label on some builds. The label
            -- conveys state ("Imported ✓" vs "Add to my library") and the click
            -- handler guards the no-selection / already-imported cases.
        end)
    end

    update_detail = function()
        pcall(function()
            if W.detail and W.detail.setText then
                W.detail:setText(entry_detail_text(selected_entry()))
            end
        end)
        update_import_btn()
    end

    -- -----------------------------------------------------------------------
    -- Grid render. Mirrors prefab_manager.render_grid (0-indexed Grid).
    -- -----------------------------------------------------------------------
    render_grid = function()
        pcall(function()
            if not (W.grid and W.grid.insertRow) then return end
            if W.grid.removeAllRows then W.grid:removeAllRows() end
            for i, e in ipairs(W.visible) do
                W.grid:insertRow(nil)
                local row = i - 1
                W.grid:setCell(0, row, make_cell(e.name, e.name))
                W.grid:setCell(1, row, make_cell(e.author))
                W.grid:setCell(2, row, make_cell(e.likes or 0))
                W.grid:setCell(3, row, make_cell(e.theatre or ''))
            end
            if W.selected_idx and W.grid.selectRow then
                pcall(function() W.grid:selectRow(W.selected_idx - 1) end)
            end
        end)
    end

    -- -----------------------------------------------------------------------
    -- Filter + sort → W.visible. Selection is dropped (the underlying set
    -- changed) unless the previously-selected entry is still present.
    -- -----------------------------------------------------------------------
    recompute_visible = function()
        local prev = selected_entry()
        local tags = {}
        for t, on in pairs(W.active_tags) do if on then tags[#tags + 1] = t end end
        local filtered = W.entries
        if manifest and manifest.filter then
            local ok, res = pcall(manifest.filter, W.entries, { text = W.search_text, tags = tags })
            if ok and type(res) == 'table' then filtered = res end
        end
        pcall(sort_entries, filtered, W.sort_key, W.sort_dir)
        W.visible = filtered
        -- Restore selection by identity (same entry table) if still visible.
        W.selected_idx = nil
        if prev then
            for i, e in ipairs(W.visible) do if e == prev then W.selected_idx = i; break end end
        end
    end

    -- -----------------------------------------------------------------------
    -- Selection callback. Grid:getSelectedRow() is 0-based / -1 for none.
    -- -----------------------------------------------------------------------
    local function on_list_select()
        pcall(function()
            if not (W.grid and W.grid.getSelectedRow) then W.selected_idx = nil; return end
            local idx = W.grid:getSelectedRow()
            if type(idx) ~= 'number' or idx < 0 then W.selected_idx = nil
            else W.selected_idx = idx + 1 end
            update_detail()
        end)
    end

    -- Re-text each header so the active sort column shows an up/down arrow.
    update_header_labels = function()
        pcall(function()
            for i, c in ipairs(COLS) do
                local hc = W.grid_headers[i]
                if hc and hc.setText then
                    local label = c.label
                    if c.key == W.sort_key then
                        -- ▼ (\226\150\188) for desc, ▲ (\226\150\178) for asc.
                        label = label .. (W.sort_dir == 'desc' and ' \226\150\188' or ' \226\150\178')
                    end
                    hc:setText(label)
                end
            end
        end)
    end

    -- Header click: same column toggles direction; a new column sorts by it
    -- (numeric columns default to desc — most-loved first — text to asc).
    on_header_click = function(key)
        pcall(function()
            local col = find_col(key)
            if not col then return end
            if W.sort_key == key then
                W.sort_dir = (W.sort_dir == 'asc') and 'desc' or 'asc'
            else
                W.sort_key = key
                W.sort_dir = col.numeric and 'desc' or 'asc'
            end
            update_header_labels()
            recompute_visible()
            render_grid()
            update_detail()
        end)
    end

    -- -----------------------------------------------------------------------
    -- Tag chips. Rebuilt whenever entries change (sync / cache load). Each is
    -- a ToggleButton; toggling updates W.active_tags then re-filters.
    -- -----------------------------------------------------------------------
    local function destroy_chips()
        -- Build a set of the chips being torn down so we can also purge them
        -- from W.widgets — otherwise a later handle:show() would resurrect a
        -- destroyed chip (it's hidden here, but show() un-hides everything in
        -- W.widgets).
        local dying = {}
        for _, chip in ipairs(W.chips) do
            dying[chip] = true
            pcall(function() if chip.setVisible then chip:setVisible(false) end end)
            -- Remove from the parent if dxgui supports it; otherwise hiding is
            -- enough (the chip won't be re-shown once dropped from W.widgets).
            pcall(function()
                if parent and parent.removeWidget then parent:removeWidget(chip) end
            end)
        end
        if next(dying) then
            local kept = {}
            for _, w in ipairs(W.widgets) do if not dying[w] then kept[#kept + 1] = w end end
            W.widgets = kept
        end
        W.chips = {}
    end

    -- Lay the tag chips out in the right column, wrapping within W.chips_w.
    -- Returns the y just below the last chip row (or W.chips_y when there are
    -- no chips) so relayout can place the detail block directly beneath them.
    layout_chips = function()
        local x0   = W.chips_x or 0
        local y0   = W.chips_y or 0
        local maxw = W.chips_w or 300
        local CHIP_H = 20
        local cx, cy = x0, y0
        for _, chip in ipairs(W.chips) do
            local label = '#tag'
            pcall(function() if chip.getText then label = chip:getText() or label end end)
            local cw = math.max(40, 16 + #label * 7)
            if cw > maxw then cw = maxw end
            if cx + cw > x0 + maxw then cx = x0; cy = cy + CHIP_H + 4 end
            bounds(chip, cx, cy, cw, CHIP_H)
            cx = cx + cw + 6
        end
        if #W.chips > 0 then return cy + CHIP_H end
        return y0
    end

    rebuild_chips = function()
        pcall(function()
            destroy_chips()
            if not (ToggleButton and manifest and manifest.all_tags) then return end
            local tags = manifest.all_tags(W.entries) or {}
            for _, tag in ipairs(tags) do
                local chip = ToggleButton.new()
                if chip then
                    pcall(function() if chip.setText then chip:setText('#' .. tag) end end)
                    try_skin(chip, 'sms_button')
                    -- Restore prior on-state if this tag was active before a sync.
                    if W.active_tags[tag] then
                        pcall(function() if chip.setState then chip:setState(true) end end)
                    end
                    if chip.addChangeCallback then
                        local this_tag = tag
                        pcall(function()
                            chip:addChangeCallback(function(self)
                                pcall(function()
                                    local on = self.getState and self:getState() or false
                                    W.active_tags[this_tag] = on and true or nil
                                    recompute_visible()
                                    render_grid()
                                    update_detail()
                                end)
                            end)
                        end)
                    end
                    track(chip)
                    W.chips[#W.chips + 1] = chip
                end
            end
            -- Re-flow the whole panel so the detail block drops below the new
            -- chip band (its height depends on how many chips wrapped).
            relayout(W.cw, W.ch)
        end)
    end

    -- =======================================================================
    -- Widget construction
    -- =======================================================================

    -- "Last synced HH:MM" label (right column, beside Refresh). Starts blank;
    -- the dead "Community prefabs" title was dropped — it added nothing.
    W.synced_lbl = track(Static and Static.new())
    if W.synced_lbl then
        pcall(function() if W.synced_lbl.setText then W.synced_lbl:setText('') end end)
        try_skin(W.synced_lbl, 'staticSkin_ME')
    end

    -- ⟳ Refresh button.
    W.refresh_btn = track(Button and Button.new())
    if W.refresh_btn then
        pcall(function() if W.refresh_btn.setText then W.refresh_btn:setText('\226\159\179 Refresh') end end)
        try_skin(W.refresh_btn, 'sms_button')
        if W.refresh_btn.addChangeCallback then
            pcall(function()
                W.refresh_btn:addChangeCallback(function() pcall(do_refresh) end)
            end)
        end
    end

    -- (Sorting is driven by clicking the grid column headers — see the Grid
    -- construction below — so there's no separate Sort button.)

    -- Search input. clearable_edit preferred; raw TextBox/Static fallback.
    do
        local function on_search_change(txt)
            pcall(function()
                txt = tostring(txt or '')
                if txt == W.search_text then return end
                W.search_text = txt
                recompute_visible()
                render_grid()
                update_detail()
            end)
        end
        local ce = clearable_edit and clearable_edit.new(parent, { on_change = on_search_change })
        if ce then
            -- clearable_edit parents its own children; just track for show/hide.
            W.search_input = ce
            W.widgets[#W.widgets + 1] = ce
            pcall(function()
                local target = (ce.widget and ce:widget()) or ce
                if target and target.setHintText then target:setHintText('Search community prefabs') end
            end)
        elseif TextBox then
            W.search_input = track(TextBox.new())
            try_skin(W.search_input, 'editBoxSkin_ME')
            if W.search_input.addChangeCallback then
                pcall(function()
                    W.search_input:addChangeCallback(function(box)
                        local txt = (box and box.getText and box:getText()) or ''
                        on_search_change(txt)
                    end)
                end)
            end
        else
            W.search_input = track(Static and Static.new())
            if W.search_input and W.search_input.setText then
                pcall(function() W.search_input:setText('(search unavailable)') end)
            end
        end
    end

    -- Grid of entries (Grid + GridHeaderCell). Static fallback otherwise.
    if Grid and GridHeaderCell then
        W.grid = track(Grid.new())
        try_skin(W.grid, 'sms_grid')
        for i, c in ipairs(COLS) do
            local hc = GridHeaderCell.new()
            try_skin(hc, 'sms_grid_header')
            if hc and hc.setText then hc:setText(c.label) end
            W.grid:insertColumn(c.width, hc)
            W.grid_headers[i] = hc
            -- Click a header to sort by that column (toggles asc/desc),
            -- mirroring the My-Prefabs grid + Mass Edit.
            if hc and hc.addChangeCallback then
                local key = c.key
                pcall(function() hc:addChangeCallback(function() on_header_click(key) end) end)
            end
        end
        update_header_labels()  -- show the initial sort arrow (likes ▼)
        -- Grid's default onMouseDown doesn't select; override like the manager.
        W.grid.onMouseDown = function(self, x, y, button)
            if button ~= 1 then return end
            pcall(function()
                local _, row = self:getMouseCursorColumnRow(x, y)
                if row and row >= 0 then
                    self:selectRow(row)
                    on_list_select()
                end
            end)
        end
        if W.grid.addSelectRowCallback then
            pcall(function()
                W.grid:addSelectRowCallback(function() on_list_select() end)
            end)
        end
    else
        W.grid = track(Static and Static.new())
        if W.grid and W.grid.setText then pcall(function() W.grid:setText('Grid widget not available') end) end
    end

    -- Detail block: a READ-ONLY, multi-line EditBox (not a Static — a plain
    -- dxgui Static renders only the first line and ignores the \n breaks, so
    -- the description never showed). setMultiline must run BEFORE setSkin (it
    -- rebuilds the scrollbar widgets); setReadOnly keeps it a display, not an
    -- input. TextBox resolves to EditBox on real DCS; nil in the test VM.
    W.detail = track(TextBox and TextBox.new())
    if W.detail then
        pcall(function() if W.detail.setMultiline then W.detail:setMultiline(true) end end)
        pcall(function() if W.detail.setTextWrapping then W.detail:setTextWrapping(true) end end)
        local skinned = false
        pcall(function()
            if sms_scrollbars and sms_scrollbars.themed_editbox_skin and W.detail.setSkin then
                W.detail:setSkin(sms_scrollbars.themed_editbox_skin({ mono = false }))
                skinned = true
            end
        end)
        if not skinned then try_skin(W.detail, 'editBoxSkin_ME') end
        pcall(function() if W.detail.setReadOnly then W.detail:setReadOnly(true) end end)
        pcall(function() if W.detail.setText then W.detail:setText(entry_detail_text(nil)) end end)
    end

    -- ＋ Add to my library button. Set the label up front so it's never blank
    -- before the first selection (update_import_btn refines it per-selection).
    W.import_btn = track(Button and Button.new())
    if W.import_btn then
        try_skin(W.import_btn, 'sms_button')
        pcall(function()
            if W.import_btn.setText then W.import_btn:setText('\239\188\139 Add to my library') end
        end)
        if W.import_btn.addChangeCallback then
            pcall(function()
                -- on_import_click is forward-declared above and assigned below
                -- (in the fetch/import section); the callback resolves it as an
                -- upvalue at click time, by when it's set.
                W.import_btn:addChangeCallback(function() pcall(function() on_import_click() end) end)
            end)
        end
    end

    -- Vertical splitter in the gutter between the entry list (left) and the
    -- detail/description column (right) — the same drag handle the My-Prefabs
    -- tree/grid use. invert=true because the tracked value is the RIGHT pane's
    -- width: dragging the handle right shrinks the description, dragging left
    -- grows it. Parented straight to the window (like the My-Prefabs splitter)
    -- and appended to W.widgets directly — NOT via track(), which would
    -- double-insert it — so the tab's show/hide toggles it with everything
    -- else. on_drag mutates W.detail_w and re-runs relayout (forward-declared
    -- above; resolved as an upvalue by drag time).
    W.splitter = splitter_mod and splitter_mod.new(parent, {
        initial = W.detail_w,
        min     = DETAIL_MIN,
        max     = 800,   -- tightened per-window in relayout via set_range
        invert  = true,
        skin    = 'sms_splitter',
        on_drag = function(new_detail_w)
            W.detail_w = new_detail_w
            relayout(W.cw, W.ch)
        end,
    })
    if W.splitter and W.splitter.widget then
        local sw = W.splitter:widget()
        if sw then W.widgets[#W.widgets + 1] = sw end
    end

    -- -----------------------------------------------------------------------
    -- Responsive layout. Left column: the search row, then the grid filling
    -- the rest of the height. Right column: Refresh + last-synced on row 1,
    -- the tag chips beneath, the detail block, and the import button pinned to
    -- the bottom. Called once at build and from the Prefab Manager on every
    -- window resize, so the panel reflows like the My-Prefabs panel.
    -- -----------------------------------------------------------------------
    relayout = function(cw, ch)
        cw = tonumber(cw) or W.cw or 920
        ch = tonumber(ch) or W.ch or 612
        W.cw, W.ch = cw, ch  -- remembered so rebuild_chips can re-flow
        -- Reserve the sms_window footer band at the bottom: the footer
        -- separator sits at h-76 and the status Static at h-73, so content
        -- must stop above ~h-80 or it spills over / gets clipped.
        local FOOTER = 82
        local bottom = ch - FOOTER

        -- The right (detail/description) column width is user-adjustable via
        -- the splitter. Clamp it to what the window can afford BEFORE reading
        -- it (mirrors prefab_manager's tree_w clamp): the grid keeps GRID_MIN,
        -- the gutter keeps SPLIT_GUTTER, and PAD sits on each outer edge.
        local max_detail = math.max(DETAIL_MIN, cw - PAD - SPLIT_GUTTER - GRID_MIN - PAD)
        if W.detail_w < DETAIL_MIN  then W.detail_w = DETAIL_MIN  end
        if W.detail_w > max_detail  then W.detail_w = max_detail  end

        local detail_w = W.detail_w
        local right_x  = cw - PAD - detail_w
        local grid_x   = PAD
        local grid_w   = math.max(GRID_MIN, right_x - SPLIT_GUTTER - grid_x)

        -- Row 1: search (left), Refresh + last-synced (right column).
        local y = TOP
        if W.search_input and W.search_input.set_bounds then
            pcall(function() W.search_input:set_bounds(grid_x, y, grid_w, ROW_H) end)
        else
            bounds(W.search_input, grid_x, y, grid_w, ROW_H)
        end
        local refresh_w = 100
        bounds(W.refresh_btn, right_x, y, refresh_w, ROW_H)
        bounds(W.synced_lbl, right_x + refresh_w + 8, y, math.max(0, detail_w - refresh_w - 8), ROW_H)

        -- Left column: grid fills from row 2 down to just above the footer,
        -- directly under the search bar.
        local row2   = y + ROW_H + GAP
        local grid_h = math.max(120, bottom - row2)
        bounds(W.grid, grid_x, row2, grid_w, grid_h)

        -- Splitter centered in the SPLIT_GUTTER strip between the grid and the
        -- right column, spanning the grid's height. Range is refreshed every
        -- relayout so a window shrink tightens the max before the user can drag
        -- the grid below GRID_MIN; set_value keeps the handle in sync if
        -- W.detail_w was clamped above.
        local splitter_x = right_x - SPLIT_GUTTER + SPLITTER_MARGIN
        local splitter_h = math.max(60, bottom - row2)
        if W.splitter then
            if W.splitter.set_bounds then W.splitter:set_bounds(splitter_x, row2, SPLIT, splitter_h) end
            if W.splitter.set_range  then W.splitter:set_range(DETAIL_MIN, max_detail) end
            if W.splitter.set_value  then W.splitter:set_value(W.detail_w) end
        end

        -- Right column: chips under row 1, detail below them, import pinned
        -- just above the footer.
        W.chips_x = right_x
        W.chips_y = row2
        W.chips_w = detail_w
        local chips_bottom = layout_chips()
        local import_h = ROW_H
        local import_y = bottom - import_h
        local detail_y = chips_bottom + GAP
        local detail_h = math.max(60, import_y - GAP - detail_y)
        bounds(W.detail, right_x, detail_y, detail_w, detail_h)
        bounds(W.import_btn, right_x, import_y, detail_w, import_h)
    end

    -- =======================================================================
    -- Fetch / cache / import flows
    -- =======================================================================

    -- Load the last cached manifest so the tab isn't empty before any sync.
    local function load_from_cache()
        pcall(function()
            if not (cache and cache.load) then return end
            local raw = cache.load()
            if not raw then return end
            if not (json and json.decode and manifest and manifest.parse) then return end
            local ok, decoded = pcall(json.decode, raw)
            if not ok then return end
            local m = manifest.parse(decoded)
            if not m then return end
            W.entries = m.entries or {}
            rebuild_chips()
            recompute_visible()
            render_grid()
            update_detail()
        end)
    end

    -- Manual / first-show refresh. Gates on transport availability; degrades
    -- to the cached catalog with a status message when LuaSec is missing.
    do_refresh = function()
        pcall(function()
            if W.job then return end  -- a fetch is already in flight
            if not (transport and transport.available and fetch and fetch.new) then
                load_from_cache()
                set_status('Community networking unavailable in this build. Showing cached catalog.', 'warning')
                return
            end
            if not transport.available() then
                load_from_cache()
                set_status('Secure networking unavailable — install LuaSec in dcs-sms\\lib. Showing cached catalog.', 'warning')
                return
            end
            W.job = fetch.new(transport)
            W.job_kind = 'manifest'
            local ok = pcall(function() W.job:start_manifest() end)
            if not ok then
                W.job = nil; W.job_kind = nil
                set_status('Refresh failed to start. Showing cached catalog.', 'error')
                return
            end
            set_status('Syncing\226\128\166', 'info')  -- "Syncing…"
        end)
    end

    -- Import button click handler (forward-declared above so the import
    -- button's addChangeCallback, wired during construction, resolves it as an
    -- upvalue at click time).
    on_import_click = function()
        pcall(function()
            local e = selected_entry()
            if not e then set_status('Select a prefab first.', 'warning'); return end
            if importer and importer.is_imported then
                local ok, res = pcall(importer.is_imported, e)
                if ok and res == true then set_status('Already imported.', 'info'); return end
            end
            if W.job then set_status('Busy — finish the current fetch first.', 'warning'); return end
            if not (transport and transport.available and fetch and fetch.new and cfg and cfg.file_url) then
                set_status('Community networking unavailable in this build.', 'warning'); return
            end
            if not transport.available() then
                set_status('Secure networking unavailable — install LuaSec in dcs-sms\\lib.', 'warning'); return
            end
            W.job = fetch.new(transport)
            W.job_kind = 'file'
            W.pending_import = e
            local ok = pcall(function() W.job:fetch_file(cfg.file_url(e.path)) end)
            if not ok then
                W.job = nil; W.job_kind = nil; W.pending_import = nil
                set_status('Import failed to start.', 'error')
                return
            end
            set_status('Downloading ' .. (e.name or '') .. '\226\128\166', 'info')
        end)
    end

    -- -----------------------------------------------------------------------
    -- Completion handlers for tick().
    -- -----------------------------------------------------------------------
    local function on_manifest_done(job)
        pcall(function()
            if job.manifest and job.manifest.entries then
                W.entries = job.manifest.entries
            end
            if cache and cache.save and job.raw then pcall(cache.save, job.raw) end
            W.last_synced = os.date('%H:%M')
            pcall(function()
                if W.synced_lbl and W.synced_lbl.setText then
                    W.synced_lbl:setText('last synced ' .. tostring(W.last_synced))
                end
            end)
            rebuild_chips()
            recompute_visible()
            render_grid()
            update_detail()
            set_status('Synced ' .. #W.entries .. ' prefabs.', 'success')
        end)
    end

    local function on_manifest_error(job)
        pcall(function()
            set_status('Refresh failed: ' .. tostring(job.error) .. ' — showing cached catalog.', 'error')
            -- If we have nothing yet, fall back to whatever's cached.
            if #W.entries == 0 then load_from_cache() end
        end)
    end

    local function on_file_done(job, e)
        pcall(function()
            if not e then return end
            if not (importer and importer.import) then
                set_status('Import unavailable in this build.', 'error'); return
            end
            local ok, path_or_err = importer.import(e, job.file_body)
            if ok then
                set_status('Imported ' .. (e.name or '') .. ' \226\134\146 Community/', 'success')
                pcall(refresh_my_library)
                update_detail()  -- flips the button to "Imported ✓"
                render_grid()
            else
                set_status('Import failed: ' .. tostring(path_or_err), 'error')
            end
        end)
    end

    local function on_file_error(job)
        pcall(function()
            set_status('Download failed: ' .. tostring(job.error), 'error')
        end)
    end

    -- =======================================================================
    -- panel_handle
    -- =======================================================================
    local handle = {}

    function handle:show()
        pcall(function()
            for _, w in ipairs(W.widgets) do
                if w.set_visible then pcall(function() w:set_visible(true) end)
                elseif w.setVisible then pcall(function() w:setVisible(true) end) end
            end
        end)
    end

    function handle:hide()
        pcall(function()
            for _, w in ipairs(W.widgets) do
                if w.set_visible then pcall(function() w:set_visible(false) end)
                elseif w.setVisible then pcall(function() w:setVisible(false) end) end
            end
        end)
    end

    function handle:on_first_show()
        if W.did_first_sync then return end
        W.did_first_sync = true
        do_refresh()
    end

    -- Pump an in-flight job once per tick. No-op when idle. Dispatches the
    -- right completion handler off W.job_kind.
    function handle:tick()
        pcall(function()
            if not W.job then return end
            local s
            local ok = pcall(function() s = W.job:step() end)
            if not ok then
                -- A step that threw despite the job's own guards: bail safely.
                W.job = nil; W.job_kind = nil; W.pending_import = nil
                return
            end
            if s == 'running' or s == 'idle' then return end
            local job = W.job
            local kind = W.job_kind
            -- Capture the pending entry, then clear ALL job state BEFORE running
            -- the completion handler so a re-entrant tick sees idle and a handler
            -- that kicks a new fetch (it won't today) can't be clobbered. The
            -- captured entry is handed to on_file_done — it must NOT read the
            -- now-cleared W.pending_import (clearing it first was the
            -- import-never-fires bug).
            local pending = W.pending_import
            W.job = nil
            W.job_kind = nil
            W.pending_import = nil
            if s == 'done' then
                if kind == 'manifest' then on_manifest_done(job)
                elseif kind == 'file' then on_file_done(job, pending) end
            elseif s == 'error' then
                if kind == 'manifest' then on_manifest_error(job)
                elseif kind == 'file' then on_file_error(job) end
            end
        end)
    end

    -- Reflow to a content size. Called by the Prefab Manager at build and on
    -- every window resize so the panel tracks the window like My-Prefabs does.
    function handle:relayout(cw, ch)
        pcall(function() relayout(cw, ch) end)
    end

    -- Expose a couple of internals for the manager / future tests. Harmless in
    -- production; mirrors prefab_manager.lua's M._foo exposure convention.
    handle._W = W
    handle._do_refresh = do_refresh

    -- Initial layout (default size; the manager re-lays-out at the real content
    -- size immediately after build) + populate from cache so the tab shows the
    -- last catalog at once. update_detail() runs unconditionally afterward so
    -- the detail block + import button start in a consistent state even when
    -- there's no cache (load_from_cache returns early in that case).
    relayout()
    load_from_cache()
    update_detail()

    return handle
end

return M
