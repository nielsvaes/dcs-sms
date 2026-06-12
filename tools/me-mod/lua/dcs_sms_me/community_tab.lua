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
local paths;         do local ok, m = pcall(require, 'dcs_sms_me.paths');             if ok then paths          = m end end
local community_meta;do local ok, m = pcall(require, 'dcs_sms_me.community_meta');    if ok then community_meta = m end end
-- SkinUtils paints a picture onto a Static from a local file path (the same
-- mechanism MissionEditor/modules/imagePreview.lua uses). Guarded so the module
-- still loads in the bare test VM where dxgui is absent.
local SkinUtils;     do local ok, m = pcall(require, 'SkinUtils');                    if ok then SkinUtils      = m end end

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
        -- Image-preview panel state (right column, below the description).
        media_job     = nil,    -- in-flight meta/image fetch (separate from W.job)
        media_kind    = nil,    -- 'meta' | 'image'
        media_pending = nil,    -- { token, entry } or { token, idx, rel, path }
        media_token   = 0,      -- bumped on every selection change; stale completions skip the UI
        media_entry   = nil,    -- entry media was last started for (selection-change guard)
        cur_images    = {},     -- repo-relative image paths for the selected entry
        cur_img_idx   = 1,      -- 1-based index into cur_images
        img_state     = 'none', -- 'none' | 'loading' | 'ready' | 'failed'
        img_path      = nil,    -- absolute local path of the displayed image
        img_native_w  = nil,    -- native px dims (for aspect-correct re-fit on resize)
        img_native_h  = nil,
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

    -- Image-preview panel geometry (right column, below the description).
    local IMG_MAX_H   = 220   -- cap on displayed image height
    local DETAIL_KEEP = 80    -- description editbox never shorter than this when an image shows
    local IMG_CTRL_H  = ROW_H -- the ◀ i/N ▶ control row height
    local IMG_BTN_W   = 28    -- ◀ / ▶ button width

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
        add_count('triggers', e.triggers)
        if #counts > 0 then lines[#lines + 1] = table.concat(counts, ', ') end
        if (e.triggers or 0) > 0 then
            lines[#lines + 1] = '\226\154\145 includes ' .. e.triggers
                .. ' trigger(s) — may contain Lua that runs when the mission runs'
        end
        if type(e.required_modules) == 'table' and #e.required_modules > 0 then
            local names = {}
            for _, m in ipairs(e.required_modules) do
                names[#names + 1] = (m.display_name ~= '' and m.display_name) or m.id
            end
            lines[#lines + 1] = '\226\154\145 requires mods: ' .. table.concat(names, ', ')
                .. ' — objects from these will not load without the mod installed'
        end
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
    local start_media, sync_media, ensure_current_image, set_displayed, nav

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
        -- Re-sync the image panel to the (possibly new) selection. Guarded in
        -- case this runs before sync_media is assigned (build-time ordering).
        pcall(function() if sync_media then sync_media() end end)
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

    -- ----- Image-preview panel (right column, below the description) --------
    -- A Static showing the screenshot via a picture-skin, a counter/status
    -- label, and ◀ ▶ navigation buttons. All pcall-guarded so the module still
    -- loads in the bare test VM (Static/Button/SkinUtils absent). A hidden,
    -- untracked probe Static reads an image's native size via calcSize().
    W.image = track(Static and Static.new())
    if W.image then try_skin(W.image, 'staticSkin_ME') end
    W.img_probe = Static and Static.new()   -- NOT tracked: never shown, sizing only

    W.img_count = track(Static and Static.new())
    if W.img_count then
        try_skin(W.img_count, 'staticSkin_ME')
        pcall(function() if W.img_count.setText then W.img_count:setText('') end end)
    end

    W.img_prev = track(Button and Button.new())
    if W.img_prev then
        try_skin(W.img_prev, 'sms_button')
        pcall(function() if W.img_prev.setText then W.img_prev:setText('\226\151\128') end end)  -- ◀
        if W.img_prev.addChangeCallback then
            pcall(function() W.img_prev:addChangeCallback(function() pcall(function() nav(-1) end) end) end)
        end
    end

    W.img_next = track(Button and Button.new())
    if W.img_next then
        try_skin(W.img_next, 'sms_button')
        pcall(function() if W.img_next.setText then W.img_next:setText('\226\150\182') end end)  -- ▶
        if W.img_next.addChangeCallback then
            pcall(function() W.img_next:addChangeCallback(function() pcall(function() nav(1) end) end) end)
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

        -- Right column: chips under row 1, then the description, then the
        -- image-preview panel, with the import button pinned above the footer.
        W.chips_x = right_x
        W.chips_y = row2
        W.chips_w = detail_w
        local chips_bottom    = layout_chips()
        local import_h        = ROW_H
        local import_y        = bottom - import_h
        local top             = chips_bottom + GAP
        local content_bottom  = import_y - GAP   -- description + image panel live above this

        -- Set visibility on a media widget (set_visible / setVisible).
        local function vis(w, on)
            if not w then return end
            if w.set_visible then pcall(function() w:set_visible(on) end)
            elseif w.setVisible then pcall(function() w:setVisible(on) end) end
        end

        local n = #(W.cur_images or {})
        if n <= 0 then
            -- No images: description fills the whole right column (legacy layout).
            vis(W.image, false); vis(W.img_count, false); vis(W.img_prev, false); vis(W.img_next, false)
            local detail_h = math.max(60, content_bottom - top)
            bounds(W.detail, right_x, top, detail_w, detail_h)
            bounds(W.import_btn, right_x, import_y, detail_w, import_h)
            return
        end

        -- Aspect-correct image box (only when an image is actually ready).
        local disp_w, disp_h = 0, 0
        if W.img_state == 'ready' and W.img_native_w and W.img_native_w > 0
           and W.img_native_h and W.img_native_h > 0 then
            local avail_h = math.max(0, content_bottom - top - DETAIL_KEEP - GAP - IMG_CTRL_H)
            local box_h   = math.min(IMG_MAX_H, avail_h)
            if box_h > 20 then
                local scale = math.min(detail_w / W.img_native_w, box_h / W.img_native_h)
                disp_w = math.floor(W.img_native_w * scale)
                disp_h = math.floor(W.img_native_h * scale)
            end
        end

        local panel_h  = IMG_CTRL_H + ((disp_h > 0) and (disp_h + GAP) or 0)
        local detail_h = math.max(60, content_bottom - top - panel_h - GAP)
        bounds(W.detail, right_x, top, detail_w, detail_h)

        local panel_top = top + detail_h + GAP
        local cy = panel_top
        if disp_h > 0 then
            vis(W.image, true)
            bounds(W.image, right_x + math.floor((detail_w - disp_w) / 2), cy, disp_w, disp_h)
            -- Re-assert the picture skin so a resize rescales the image (idempotent).
            pcall(function()
                if W.image and SkinUtils and SkinUtils.setStaticPictureRect and W.img_path then
                    W.image:setSkin(SkinUtils.setStaticPictureRect(W.img_path, 0, 0,
                        W.img_native_w, W.img_native_h, W.image:getSkin()))
                end
            end)
            cy = cy + disp_h + GAP
        else
            vis(W.image, false)
        end

        -- Control row: ◀ left, ▶ right (only when >1 image), counter/status centred.
        local count_txt
        if W.img_state == 'loading'    then count_txt = 'loading\226\128\166'      -- loading…
        elseif W.img_state == 'failed' then count_txt = 'preview unavailable'
        else count_txt = string.format('%d / %d', W.cur_img_idx, n) end
        vis(W.img_count, true)
        pcall(function() if W.img_count.setText then W.img_count:setText(count_txt) end end)
        bounds(W.img_count, right_x + IMG_BTN_W + 4, cy, math.max(0, detail_w - 2 * (IMG_BTN_W + 4)), IMG_CTRL_H)
        if n > 1 then
            vis(W.img_prev, true); vis(W.img_next, true)
            bounds(W.img_prev, right_x, cy, IMG_BTN_W, IMG_CTRL_H)
            bounds(W.img_next, right_x + detail_w - IMG_BTN_W, cy, IMG_BTN_W, IMG_CTRL_H)
        else
            vis(W.img_prev, false); vis(W.img_next, false)
        end

        bounds(W.import_btn, right_x, import_y, detail_w, import_h)
    end

    -- =======================================================================
    -- Image-preview / media flows. A dedicated W.media_job slot (kinds 'meta'
    -- and 'image'), pumped alongside W.job in handle:tick(), keeps screenshot
    -- traffic independent of the manifest-refresh / import job. W.media_token
    -- (bumped on every selection change) makes a completion that lands after
    -- the selection moved on a no-op for the UI — the bytes are still cached.
    -- =======================================================================

    -- True if a regular file exists at an absolute path.
    local function file_exists(path)
        if type(path) ~= 'string' or path == '' then return false end
        local f = io.open(path, 'rb')
        if f then f:close(); return true end
        return false
    end

    -- Write raw bytes to an absolute path (binary). Returns true on success.
    local function write_file(path, bytes)
        if type(path) ~= 'string' or path == '' then return false end
        local f = io.open(path, 'wb')
        if not f then return false end
        f:write(bytes or ''); f:close()
        return true
    end

    -- Read an image file's native pixel size via the hidden probe Static.
    -- Returns (w, h), or (0, 0) when the widget stack / file is unavailable.
    local function probe_native(path)
        if not (W.img_probe and SkinUtils and SkinUtils.setStaticPicture) then return 0, 0 end
        local w, h = 0, 0
        pcall(function()
            W.img_probe:setSkin(SkinUtils.setStaticPicture(path, W.img_probe:getSkin()))
            local cw, ch = W.img_probe:calcSize()
            w, h = tonumber(cw) or 0, tonumber(ch) or 0
        end)
        return w, h
    end

    -- Apply `path` to the visible image widget + cache its native size, then
    -- relayout (which fits it to the column, aspect-preserved). Sets img_state.
    set_displayed = function(path)
        local nw, nh = probe_native(path)
        if nw > 0 and nh > 0 then
            W.img_path = path; W.img_native_w = nw; W.img_native_h = nh
            W.img_state = 'ready'
            pcall(function()
                if W.image and SkinUtils and SkinUtils.setStaticPictureRect then
                    W.image:setSkin(SkinUtils.setStaticPictureRect(path, 0, 0, nw, nh, W.image:getSkin()))
                end
            end)
        else
            W.img_path = nil; W.img_native_w = nil; W.img_native_h = nil
            W.img_state = 'failed'
        end
        relayout(W.cw, W.ch)
    end

    -- Make sure the image at cur_img_idx is on screen: show it from cache if
    -- present, else kick a lazy download. No-op-safe when there are no images.
    ensure_current_image = function()
        -- A previous image fetch may still be in flight (rapid ◀/▶). Drop it —
        -- the token guard already neutralises its UI effect; clearing the slot
        -- frees the socket promptly and mirrors start_media's own reset.
        if W.media_kind == 'image' then
            W.media_job = nil; W.media_kind = nil; W.media_pending = nil
        end
        local rel = W.cur_images and W.cur_images[W.cur_img_idx]
        if not rel then W.img_state = 'none'; relayout(W.cw, W.ch); return end
        if not (paths and paths.community_image_path) then
            W.img_state = 'failed'; relayout(W.cw, W.ch); return
        end
        local path = paths.community_image_path(rel)
        if file_exists(path) then set_displayed(path); return end
        -- Not cached → download. Degrade to 'failed' with no networking.
        if not (transport and transport.available and transport.available()
                and fetch and fetch.new and cfg and cfg.image_url) then
            W.img_state = 'failed'; relayout(W.cw, W.ch); return
        end
        W.img_state = 'loading'; W.img_path = nil; W.img_native_w = nil; W.img_native_h = nil
        relayout(W.cw, W.ch)
        W.media_job = fetch.new(transport)
        W.media_kind = 'image'
        W.media_pending = { token = W.media_token, idx = W.cur_img_idx, rel = rel, path = path }
        local ok = pcall(function() W.media_job:fetch_file(cfg.image_url(rel)) end)
        if not ok then
            W.media_job = nil; W.media_kind = nil; W.media_pending = nil
            W.img_state = 'failed'; relayout(W.cw, W.ch)
        end
    end

    -- ◀/▶: move the current image by delta (wrapping), then ensure it's shown.
    nav = function(delta)
        local n = #(W.cur_images or {})
        if n < 2 then return end
        W.cur_img_idx = ((W.cur_img_idx - 1 + delta) % n) + 1
        ensure_current_image()
    end

    -- Begin (or reset) the media flow for the currently-selected entry. Bumps
    -- the token so any in-flight completion for a previous entry is ignored.
    start_media = function()
        W.media_token = (W.media_token or 0) + 1
        W.media_job = nil; W.media_kind = nil; W.media_pending = nil
        W.cur_images = {}; W.cur_img_idx = 1
        W.img_state = 'none'; W.img_path = nil; W.img_native_w = nil; W.img_native_h = nil
        local e = selected_entry()
        W.media_entry = e
        if not (e and e.path and e.path ~= '') then relayout(W.cw, W.ch); return end
        if type(e._images) == 'table' then          -- already fetched once → reuse
            W.cur_images = e._images
            if #e._images > 0 then ensure_current_image() else relayout(W.cw, W.ch) end
            return
        end
        -- Need the sidecar meta to learn the image list.
        if not (transport and transport.available and transport.available()
                and fetch and fetch.new and cfg and cfg.meta_url) then
            relayout(W.cw, W.ch); return
        end
        W.media_job = fetch.new(transport)
        W.media_kind = 'meta'
        W.media_pending = { token = W.media_token, entry = e }
        local ok = pcall(function() W.media_job:fetch_file(cfg.meta_url(e.path)) end)
        if not ok then W.media_job = nil; W.media_kind = nil; W.media_pending = nil end
        relayout(W.cw, W.ch)
    end

    -- Re-sync the panel to the current selection. Cheap to call from
    -- update_detail (fires on every selection/sort/sync) — only (re)starts when
    -- the selected entry actually changed.
    sync_media = function()
        if selected_entry() ~= W.media_entry then start_media() end
    end

    -- Completion: parsed the sidecar meta → memoise images on the entry, and
    -- (if still selected) show the first one.
    local function on_meta_done(job, pend)
        if not pend then return end
        local e = pend.entry
        local images = {}
        if community_meta and community_meta.parse and json and json.decode and job.file_body then
            local ok, decoded = pcall(json.decode, job.file_body)
            if ok then
                local m = community_meta.parse(decoded)
                if m and type(m.images) == 'table' then images = m.images end
            end
        end
        if e then e._images = images end                 -- memoise regardless of staleness
        if pend.token ~= W.media_token then return end    -- selection moved on
        W.cur_images = images; W.cur_img_idx = 1
        if #images > 0 then ensure_current_image()
        else W.img_state = 'none'; relayout(W.cw, W.ch) end
    end

    -- Completion: downloaded an image → cache to disk; show it if still wanted.
    local function on_image_done(job, pend)
        if not pend then return end
        -- Cache the bytes regardless of staleness; the token/idx checks below
        -- only gate whether this download updates the visible panel.
        local okw = write_file(pend.path, job.file_body)
        if pend.token ~= W.media_token then return end    -- selection moved on
        if pend.idx ~= W.cur_img_idx then return end       -- navigated away
        if okw then set_displayed(pend.path)
        else W.img_state = 'failed'; relayout(W.cw, W.ch) end
    end

    -- A media fetch errored. Only touch the UI if it's still the current one.
    local function on_media_error(kind, pend)
        if not pend or pend.token ~= W.media_token then return end
        if kind == 'meta' then W.img_state = 'none' else W.img_state = 'failed' end
        relayout(W.cw, W.ch)
    end

    -- Pump the media job once per tick (mirrors the W.job pump in handle:tick).
    local function pump_media()
        if not W.media_job then return end
        local s
        local ok = pcall(function() s = W.media_job:step() end)
        if not ok then W.media_job = nil; W.media_kind = nil; W.media_pending = nil; return end
        if s == 'running' or s == 'idle' then return end
        local job, kind, pend = W.media_job, W.media_kind, W.media_pending
        W.media_job = nil; W.media_kind = nil; W.media_pending = nil
        if s == 'done' then
            if kind == 'meta' then on_meta_done(job, pend)
            elseif kind == 'image' then on_image_done(job, pend) end
        elseif s == 'error' then
            on_media_error(kind, pend)
        end
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
        -- The loop above un-hides every tracked widget, including the image
        -- panel; relayout re-asserts the panel's correct visibility for the
        -- current selection (collapsed when there's no image).
        pcall(function() relayout(W.cw, W.ch) end)
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
            pump_media()
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
