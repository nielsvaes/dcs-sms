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
    { key = 'name',    label = 'Name',    width = 220 },
    { key = 'author',  label = 'Author',  width = 120 },
    { key = 'likes',   label = '\226\153\165', width = 45  },  -- ♥ (UTF-8)
    { key = 'theatre', label = 'Theatre', width = 110 },
}

-- Sort keys cycled by the sort button, in display order.
local SORT_KEYS = { 'likes', 'name', 'newest' }
local SORT_LABEL = { likes = 'Most loved', name = 'Name', newest = 'Newest' }

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
        sort_key     = 'likes',
        active_tags  = {},    -- map tag -> true
        job          = nil,   -- in-flight community_fetch job
        job_kind     = nil,   -- 'manifest' | 'file'
        pending_import = nil, -- entry awaiting a file fetch → import
        last_synced  = nil,   -- 'HH:MM' string
        did_first_sync = false,
        chips_y      = 0,     -- y baseline where chips are laid out (set below)
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
    -- Layout. Bounds are absolute within the parent window content rect. The
    -- Prefab Manager parents this panel under the shared window; we use a
    -- fixed layout tuned to the manager's ~900px-wide content area. Bounds are
    -- only applied once at build (the manager owns resize for the My-Prefabs
    -- panel; the Community panel uses a static layout — noted for smoke).
    -- -----------------------------------------------------------------------
    local PAD       = 12
    local ROW_H     = 24
    local TOP       = 44   -- below the manager's tab strip
    local GRID_X    = PAD
    local GRID_W    = 540
    local DETAIL_X  = GRID_X + GRID_W + PAD
    local DETAIL_W  = 320

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
            -- Disable when already imported (or nothing selected).
            if W.import_btn.setEnabled then
                W.import_btn:setEnabled(e ~= nil and not imported)
            end
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
        if manifest and manifest.sort then
            pcall(manifest.sort, filtered, W.sort_key)
        end
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

    -- Lay out the chip row at W.chips_y, wrapping naturally inside GRID_W.
    local function layout_chips()
        local x = GRID_X
        local y = W.chips_y
        local CHIP_H = 20
        for _, chip in ipairs(W.chips) do
            local label = '#tag'
            pcall(function() if chip.getText then label = chip:getText() or label end end)
            local cw = math.max(40, 16 + #label * 7)
            if x + cw > GRID_X + GRID_W then x = GRID_X; y = y + CHIP_H + 4 end
            bounds(chip, x, y, cw, CHIP_H)
            x = x + cw + 6
        end
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
            layout_chips()
        end)
    end

    -- =======================================================================
    -- Widget construction
    -- =======================================================================

    -- Title / "last synced" line.
    W.synced_lbl = track(Static and Static.new())
    if W.synced_lbl then
        pcall(function() if W.synced_lbl.setText then W.synced_lbl:setText('Community prefabs') end end)
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

    -- Sort cycle button. Click cycles likes → name → newest.
    W.sort_btn = track(Button and Button.new())
    local function update_sort_label()
        pcall(function()
            if W.sort_btn and W.sort_btn.setText then
                W.sort_btn:setText('Sort: ' .. (SORT_LABEL[W.sort_key] or W.sort_key))
            end
        end)
    end
    if W.sort_btn then
        try_skin(W.sort_btn, 'sms_button')
        update_sort_label()
        if W.sort_btn.addChangeCallback then
            pcall(function()
                W.sort_btn:addChangeCallback(function()
                    pcall(function()
                        -- Advance to the next sort key in SORT_KEYS.
                        local cur = 1
                        for i, k in ipairs(SORT_KEYS) do if k == W.sort_key then cur = i; break end end
                        W.sort_key = SORT_KEYS[(cur % #SORT_KEYS) + 1]
                        update_sort_label()
                        recompute_visible()
                        render_grid()
                        update_detail()
                    end)
                end)
            end)
        end
    end

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
        for _, c in ipairs(COLS) do
            local hc = GridHeaderCell.new()
            try_skin(hc, 'sms_grid_header')
            if hc and hc.setText then hc:setText(c.label) end
            W.grid:insertColumn(c.width, hc)
        end
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

    -- Detail block (multi-line Static).
    W.detail = track(Static and Static.new())
    if W.detail then
        try_skin(W.detail, 'staticSkin_ME')
        pcall(function() if W.detail.setText then W.detail:setText(entry_detail_text(nil)) end end)
    end

    -- ＋ Add to my library button.
    W.import_btn = track(Button and Button.new())
    if W.import_btn then
        try_skin(W.import_btn, 'sms_button')
        if W.import_btn.addChangeCallback then
            pcall(function()
                -- on_import_click is forward-declared above and assigned below
                -- (in the fetch/import section); the callback resolves it as an
                -- upvalue at click time, by when it's set.
                W.import_btn:addChangeCallback(function() pcall(function() on_import_click() end) end)
            end)
        end
    end

    -- -----------------------------------------------------------------------
    -- Static layout. The search row sits below the title/buttons row; chips
    -- below that; grid + detail fill the rest.
    -- -----------------------------------------------------------------------
    do
        local y = TOP
        bounds(W.synced_lbl, GRID_X, y, GRID_W, ROW_H)
        bounds(W.refresh_btn, DETAIL_X, y, 100, ROW_H)
        bounds(W.sort_btn,    DETAIL_X + 108, y, 140, ROW_H)
        y = y + ROW_H + 6
        -- Search input row. clearable_edit exposes set_bounds; raw widgets
        -- use setBounds via the bounds() helper.
        if W.search_input and W.search_input.set_bounds then
            pcall(function() W.search_input:set_bounds(GRID_X, y, GRID_W, ROW_H) end)
        else
            bounds(W.search_input, GRID_X, y, GRID_W, ROW_H)
        end
        y = y + ROW_H + 6
        W.chips_y = y
        -- Reserve up to two chip rows before the grid.
        local chip_band = (ROW_H + 4) * 2
        local grid_y = y + chip_band
        local grid_h = 360
        bounds(W.grid, GRID_X, grid_y, GRID_W, grid_h)
        bounds(W.detail, DETAIL_X, grid_y, DETAIL_W, grid_h - ROW_H - 6)
        bounds(W.import_btn, DETAIL_X, grid_y + grid_h - ROW_H, DETAIL_W, ROW_H)
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
                set_status('Community networking unavailable in this build. Showing cached catalog.', 'warning')
                return
            end
            if not transport.available() then
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
                    W.synced_lbl:setText('Community prefabs — last synced ' .. tostring(W.last_synced))
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

    local function on_file_done(job)
        pcall(function()
            local e = W.pending_import
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
            -- Clear job state BEFORE running the completion handler so a
            -- handler that kicks a new fetch (it won't today) can't be
            -- clobbered, and a re-entrant tick sees idle.
            W.job = nil
            W.job_kind = nil
            if kind == 'file' then W.pending_import = nil end
            if s == 'done' then
                if kind == 'manifest' then on_manifest_done(job)
                elseif kind == 'file' then on_file_done(job) end
            elseif s == 'error' then
                if kind == 'manifest' then on_manifest_error(job)
                elseif kind == 'file' then on_file_error(job) end
            end
            -- pending_import was consumed by on_file_done; clear defensively.
            W.pending_import = nil
        end)
    end

    -- Expose a couple of internals for the manager / future tests. Harmless in
    -- production; mirrors prefab_manager.lua's M._foo exposure convention.
    handle._W = W
    handle._do_refresh = do_refresh

    -- Initial population from cache so the tab shows the last catalog at once.
    load_from_cache()

    return handle
end

return M
