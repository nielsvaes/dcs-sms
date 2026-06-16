-- trigger_finder.lua — DCS-SMS "Trigger Finder" tool window.
--
-- Follows the live map selection: a left Grid tree of selected groups (→ units)
-- and statics with per-node trigger-count badges, and a right pane of one
-- Button per trigger referencing the selected node. Clicking a button selects
-- that trigger in the vanilla ME trigger panel (me_trigrules). Pure tree/bucket
-- logic lives in trigger_finder_model; this file is the dxgui shell + the
-- per-frame selection poll + the native-panel jump.
--
-- dxgui globals provided by the ME runtime: Grid, GridHeaderCell, Static,
-- Button, ScrollPane, UpdateManager.
local sms_window     = require('dcs_sms_me.sms_window')
local skin_helper    = require('dcs_sms_me.skin_helper')
local sms_skins      = require('dcs_sms_me.sms_skins')
local sms_scrollbars = require('dcs_sms_me.sms_scrollbars')
local splitter_mod   = require('dcs_sms_me.splitter')
local selection      = require('dcs_sms_me.selection')
local trigger_schema = require('dcs_sms_me.trigger_schema')
local model          = require('dcs_sms_me.trigger_finder_model')

local TAG = 'sms.me.trigfinder'
local function log_info(msg)  pcall(function() log.write(TAG, log.INFO,  tostring(msg)) end) end
local function log_warn(msg)  pcall(function() log.write(TAG, log.WARNING, tostring(msg)) end) end

local M = {}

local W = {
    sms_window   = nil,
    grid         = nil,
    splitter     = nil,
    right_header = nil,
    right_scroll = nil,
    right_parent = nil,
    right_empty  = nil,
    btn_pool     = {},     -- array of { btn=Button, sub=Static, _index=int, _wired=bool }
    right_count  = 0,
    left_w       = 364,
    collapsed    = {},     -- node key -> true when folded
    row_meta     = {},     -- grid row (0-based) -> node key
    model        = nil,
    selected_key = nil,
    last_sig     = nil,
    tick_installed = false,
}

-- Hot-reload guard: ticks from a previous load silence themselves.
_G.DCS_SMS_TF_GEN = (_G.DCS_SMS_TF_GEN or 0) + 1
local MY_GEN = _G.DCS_SMS_TF_GEN

-- ── selection → model inputs ────────────────────────────────────────────────

local function collect_static_ids()
    local ids = {}
    local ok, mission = pcall(function() return require('me_mission').mission end)
    if not ok or type(mission) ~= 'table' or type(mission.coalition) ~= 'table' then return ids end
    for _, side in pairs(mission.coalition) do
        if type(side) == 'table' and type(side.country) == 'table' then
            for _, ctry in ipairs(side.country) do
                if ctry.static and type(ctry.static.group) == 'table' then
                    for _, g in ipairs(ctry.static.group) do
                        if g.groupId then ids[g.groupId] = true end
                    end
                end
            end
        end
    end
    return ids
end

-- Cheap O(1) count of the mission's triggers. Folded into the selection
-- fingerprint so adding/deleting a trigger in the vanilla panel (which
-- doesn't touch the map selection) still bumps the signature and forces a
-- rebuild — otherwise the badges/lists would silently go stale. Read every
-- poll, so it stays cheap: the length operator only, never a walk.
local function live_trigger_count()
    local n = 0
    pcall(function() n = #(require('me_mission').mission.trigrules or {}) end)
    return n
end

-- The poll loop's change-detection fingerprint is the pure, unit-tested
-- model.selection_signature(snap, trig_count): '' = no selection = HOLD the
-- current tree (a trigger-button jump clears the marquee; the hold prevents
-- the window from blanking), otherwise selection keys + the live trigger count.

local function build_model(snap)
    local groups_in = {}
    if snap and snap.ok and type(snap.groups) == 'table' then
        local static_ids = collect_static_ids()
        for _, g in ipairs(snap.groups) do
            local gid = g.groupId
            local is_static = (gid ~= nil) and static_ids[gid] or false
            local units = {}
            if not is_static and type(g.units) == 'table' then
                for _, u in ipairs(g.units) do units[#units + 1] = { id = u.unitId, name = u.name } end
            end
            groups_in[#groups_in + 1] = {
                id    = gid,
                name  = g.name or '?',
                kind  = is_static and 'static' or 'group',
                units = units,
            }
        end
    end

    -- Selected zone objects carry no id — only a name. Map name → zoneId via
    -- TriggerZoneData (same approach the Prefab Manager uses).
    -- TODO(cleanup): this TriggerZoneData name→id walk is duplicated across
    -- prefab_manager.lua (3×), verbs/zone_verbs.lua, verbs/trigger_verbs.lua,
    -- and triggers_tab.lua. Fold every site onto one shared zone-lookup helper
    -- in a dedicated cleanup PR on top of main — deliberately kept out of this
    -- feature branch to avoid touching shipped files and overlapping main's
    -- prefab_manager changes.
    local zones_in = {}
    if snap and snap.ok and type(snap.zones) == 'table' and #snap.zones > 0 then
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
            if zid then zones_in[#zones_in + 1] = { id = zid, name = z.name } end
        end
    end

    local schema = trigger_schema.from_editor()
    local trigrules = {}
    pcall(function() trigrules = require('me_mission').mission.trigrules or {} end)

    local field_kind = function(predicate, key)
        if not schema then return nil end
        local _, _, descr = schema:resolve(schema.predicate_name(predicate))
        if not descr then return nil end
        return schema:field_kind_for(descr, key)
    end
    local type_label = function(predicate)
        if not schema then return '' end
        return schema.make_alias(schema.predicate_name(predicate)) or ''
    end

    W.model = model.build({
        groups = groups_in, zones = zones_in, trigrules = trigrules,
        field_kind = field_kind, type_label = type_label,
    })
end

-- ── jump to vanilla trigger panel ───────────────────────────────────────────

local function jump_to_trigger(index)
    local ok, err = pcall(function()
        local m = package.loaded['me_trigrules'] or require('me_trigrules')
        if not m then error('trigger panel module unavailable') end
        local vis = false
        pcall(function() vis = m.isVisible() end)
        if not vis then
            -- Open the panel the way the toolbar does, so the Triggers
            -- toolbar button state stays in sync. toolbarCallback toggles,
            -- so only call it while the panel is closed.
            pcall(function()
                local tb = require('me_toolbar')
                if tb and tb.toolbarCallback and tb.toggleButtonTrigRules then
                    tb.toolbarCallback(tb.toggleButtonTrigRules)
                end
            end)
            local now = false
            pcall(function() now = m.isVisible() end)
            if not now then pcall(function() m.show(true) end) end  -- fallback: show(true) opens + wires callbacks
        end
        local box = m.triggersWindow and m.triggersWindow.Box
        local tl = box and box.triggersList
        if not tl then error('trigger list not found') end
        local entry
        pcall(function() entry = require('me_mission').mission.trigrules[index] end)
        local item
        local count = tl:getItemCount()
        for i = 0, count - 1 do
            local it = tl:getItem(i)
            if it and entry and it.itemId == entry then item = it; break end
        end
        if not item then item = tl:getItem(index - 1) end   -- fallback: list order == trigrules order
        if not item then error('trigger row not found') end
        tl:selectItem(item)
        tl:setItemVisible(item)
        tl:onChange(item)
        -- Selecting the trigger makes the ME synchronously repopulate the
        -- Conditions (rulesList) and Actions (goalsList) columns. Auto-select
        -- the first row of each so the click lands on a fully drilled-in view
        -- instead of only the trigger row. Optional per list: a trigger with no
        -- conditions or no actions leaves that list empty, so we skip it. Each
        -- is self-guarded so a failure here never undoes the trigger selection.
        local function select_first(list)
            if type(list) ~= 'table' or type(list.getItem) ~= 'function' then return end
            pcall(function()
                local it0 = list:getItem(0)
                if it0 then
                    list:selectItem(it0)
                    if list.setItemVisible then list:setItemVisible(it0) end
                    list:onChange(it0)
                end
            end)
        end
        select_first(box.rulesList)   -- first condition
        select_first(box.goalsList)   -- first action
    end)
    if not ok then
        log_warn('jump failed: ' .. tostring(err))
        if W.sms_window then W.sms_window:flash_status('Could not select trigger: ' .. tostring(err), 'error') end
    end
end

-- ── render: right pane (trigger buttons) ────────────────────────────────────

local function node_title(node)
    if not node then return 'Select a unit, group, zone, or static on the map' end
    local what = (node.kind == 'unit') and 'unit'
              or (node.kind == 'static') and 'static'
              or (node.kind == 'zone') and 'zone'
              or 'group'
    return 'Triggers referencing ' .. what .. ' "' .. node.name .. '"'
end

local function get_slot(i)
    local slot = W.btn_pool[i]
    if slot then return slot end
    local btn = Button.new()
    skin_helper.apply(btn, 'sms_button')
    local sub = Static.new('')
    skin_helper.apply(sub, 'staticSkin_ME')
    pcall(function() if W.right_parent and W.right_parent.insertWidget then W.right_parent:insertWidget(btn) end end)
    pcall(function() if W.right_parent and W.right_parent.insertWidget then W.right_parent:insertWidget(sub) end end)
    slot = { btn = btn, sub = sub, _index = nil, _wired = false }
    if btn.addMouseDownCallback then
        pcall(function()
            btn:addMouseDownCallback(function(_, _, _, button)
                if button == 1 and slot._index then jump_to_trigger(slot._index) end
            end)
        end)
        slot._wired = true
    end
    W.btn_pool[i] = slot
    return slot
end

-- Button skins keyed by trigger color hex ('0xRRGGBBAA'); '' = the default
-- uncolored sms_button. Built once per distinct color and reused across
-- renders/pooled slots rather than recloning a skin per button per paint.
local btn_skin_cache = {}
local function button_skin_for(hex)
    local key = hex or ''
    local cached = btn_skin_cache[key]
    if cached == nil then
        cached = (hex and sms_skins.button_colored(hex)) or sms_skins.button()
        btn_skin_cache[key] = cached or false
    end
    return cached or nil
end

local function render_right(node)
    if W.right_header then pcall(function() W.right_header:setText(node_title(node)) end) end
    local trigs = (node and node.triggers) or {}
    -- hide all pooled slots first
    for _, slot in ipairs(W.btn_pool) do
        pcall(function() slot.btn:setVisible(false) end)
        pcall(function() slot.sub:setVisible(false) end)
    end
    if W.right_empty then pcall(function() W.right_empty:setVisible(node ~= nil and #trigs == 0) end) end
    for i, tr in ipairs(trigs) do
        local slot = get_slot(i)
        slot._index = tr.index
        -- Tint the button label to the trigger's vanilla-panel color, or reset
        -- to the default skin when it has none (or this pooled slot showed a
        -- colored trigger last render).
        local bskin = button_skin_for(tr.color)
        if bskin then pcall(function() slot.btn:setSkin(bskin) end) end
        local label = (tr.name ~= '' and tr.name) or ('Trigger #' .. tostring(tr.index))
        -- Visible sub-line is just the "why" (source · predicate) — short enough
        -- not to clip in a narrow pane. Full detail (incl. trigger type) on hover.
        local sub  = tr.why
        local full = tr.type .. '  ·  ' .. tr.why
        pcall(function() slot.btn:setText(label) end)
        pcall(function() if slot.btn.setTooltipText then slot.btn:setTooltipText(full) end end)
        pcall(function() slot.sub:setText(sub) end)
        pcall(function() if slot.sub.setTooltipText then slot.sub:setTooltipText(full) end end)
        pcall(function() slot.btn:setVisible(true) end)
        pcall(function() slot.sub:setVisible(true) end)
    end
    W.right_count = #trigs
    M._relayout()
end

-- ── render: left tree (Grid) ────────────────────────────────────────────────

local function make_static(text, skin_name)
    local s = Static.new(tostring(text or ''))
    skin_helper.apply(s, skin_name or 'staticSkin_ME')
    return s
end

local function make_badge(count)
    local s = Static.new(tostring(count or 0))
    if (count or 0) > 0 then
        pcall(function() s:setSkin(sms_skins.static_yellow()) end)
    else
        skin_helper.apply(s, 'staticSkin_ME')
    end
    return s
end

local function render_tree()
    if not (W.grid and W.model) then return end
    local scroll
    pcall(function() scroll = W.grid:getVertScrollPosition() end)
    pcall(function() W.grid:removeAllRows() end)
    W.row_meta = {}
    local r, sel_row = 0, nil
    for _, n in ipairs(W.model.nodes) do
        local hidden = (n.depth == 1) and n.parent and W.collapsed[n.parent]
        if not hidden then
            local glyph = ''
            if n.expandable then glyph = (W.collapsed[n.key] and '\226\150\182 ' or '\226\150\188 ') end -- ▶ / ▼
            local indent = (n.depth == 1) and '       ' or ''
            pcall(function()
                W.grid:insertRow(nil)
                W.grid:setCell(0, r, make_static(indent .. glyph .. n.name, 'staticSkin_ME'))
                W.grid:setCell(1, r, make_badge(n.count))
            end)
            W.row_meta[r] = n.key
            if n.key == W.selected_key then sel_row = r end
            r = r + 1
        end
    end
    if sel_row then pcall(function() W.grid:selectRow(sel_row) end) end
    pcall(function() if scroll then W.grid:setVertScrollPosition(scroll) end end)
end

-- ── rebuild (model + both panes) ────────────────────────────────────────────

local function rebuild(snap)
    snap = snap or selection.snapshot()
    build_model(snap)
    render_tree()
    if W.selected_key and W.model.by_key[W.selected_key] then
        render_right(W.model.by_key[W.selected_key])
    else
        W.selected_key = nil
        render_right(nil)
    end
    if W.sms_window then
        local n = #(W.model.nodes or {})
        local txt = (n > 0) and ('Following selection · ' .. n .. ' node' .. (n == 1 and '' or 's'))
                            or 'No selection — click a unit, group, or static'
        W.sms_window:set_status(txt, 'info')
    end
end

-- Paint immediately from the current selection (used on open / manual refresh),
-- seeding last_sig so the tick only fires on subsequent changes.
local function paint_now()
    local snap = selection.snapshot()
    W.last_sig = model.selection_signature(snap, live_trigger_count())
    rebuild(snap)
end

-- ── per-frame selection poll ────────────────────────────────────────────────

local function tick()
    if MY_GEN ~= _G.DCS_SMS_TF_GEN then return end          -- a newer reload owns the tick
    if not (W.sms_window and W.sms_window:raw()) then return end
    local visible = false
    pcall(function() visible = W.sms_window:raw():isVisible() end)
    if not visible then return end
    local snap = selection.snapshot()
    local sig = model.selection_signature(snap, live_trigger_count())
    -- Keep the last populated tree when the live selection goes empty — clicking
    -- a trigger button opens the vanilla panel, which clears the map's
    -- multi-selection. Only rebuild on a NEW, non-empty selection, so multi-select
    -- survives a jump and the window "holds" your selection instead of blanking.
    -- (Single-select already survived because its selection isn't cleared.) Use
    -- M.refresh() / reopen to deliberately resync to an empty selection.
    if sig ~= '' and sig ~= W.last_sig then
        W.last_sig = sig
        -- Never let a rebuild error throw into the ME's UpdateManager loop.
        local ok, err = pcall(rebuild, snap)
        if not ok then log_warn('rebuild failed: ' .. tostring(err)) end
    end
end

local function install_tick()
    if W.tick_installed then return end
    local ok, UM = pcall(require, 'UpdateManager')
    if ok and UM and UM.add then
        pcall(function() UM.add(tick) end)
        W.tick_installed = true
    else
        log_warn('UpdateManager unavailable; selection auto-follow disabled')
    end
end

-- ── layout ──────────────────────────────────────────────────────────────────

local LAYOUT = { GAP = 6, HEADER_H = 20, SPLIT_W = 6, SPLIT_GUTTER = 14,
                 BTN_H = 24, SUB_H = 16, ENTRY_GAP = 8, MIN_LEFT = 140, MIN_RIGHT = 200 }

local function relayout(x, y, w, h)
    if not (W.sms_window and W.grid) then return end
    local L = LAYOUT
    local avail = w - L.SPLIT_GUTTER
    local max_left = math.max(L.MIN_LEFT, avail - L.MIN_RIGHT)
    if W.left_w < L.MIN_LEFT then W.left_w = L.MIN_LEFT end
    if W.left_w > max_left then W.left_w = max_left end
    local left_w = W.left_w
    local right_x = x + left_w + L.SPLIT_GUTTER
    local right_w = (x + w) - right_x

    pcall(function() W.grid:setBounds(x, y, left_w, h) end)

    if W.splitter then
        W.splitter:set_bounds(x + left_w + math.floor((L.SPLIT_GUTTER - L.SPLIT_W) / 2), y, L.SPLIT_W, h)
        W.splitter:set_range(L.MIN_LEFT, max_left)
        W.splitter:set_value(left_w)
    end

    if W.right_header then pcall(function() W.right_header:setBounds(right_x, y, right_w, L.HEADER_H) end) end

    local scroll_y = y + L.HEADER_H + L.GAP
    local scroll_h = (y + h) - scroll_y
    if W.right_scroll then pcall(function() W.right_scroll:setBounds(right_x, scroll_y, right_w, scroll_h) end) end
    if W.right_empty then pcall(function() W.right_empty:setBounds(right_x + 4, scroll_y + 2, right_w - 8, L.HEADER_H) end) end

    -- buttons inside the scroll pane use pane-relative coordinates (0,0 origin)
    local in_pane = (W.right_parent == W.right_scroll)
    local bx = in_pane and 0 or right_x
    local cy = in_pane and 0 or scroll_y
    local bw = right_w - 16
    for i = 1, (W.right_count or 0) do
        local slot = W.btn_pool[i]
        if slot then
            pcall(function() slot.btn:setBounds(bx, cy, bw, L.BTN_H) end)
            cy = cy + L.BTN_H
            pcall(function() slot.sub:setBounds(bx + 6, cy, bw - 6, L.SUB_H) end)
            cy = cy + L.SUB_H + L.ENTRY_GAP
        end
    end
    if W.right_scroll and W.right_scroll.updateWidgetsBounds then
        pcall(function() W.right_scroll:updateWidgetsBounds() end)
    end
end
M._relayout = function()
    if not W.sms_window then return end
    local x, y, w, h = W.sms_window:get_content_bounds()
    relayout(x, y, w, h)
end

-- ── build the window body ───────────────────────────────────────────────────

local function build_body(raw)
    -- Left: Grid tree with themed scrollbars.
    W.grid = Grid.new()
    pcall(function()
        local sk = sms_skins.grid()
        sms_scrollbars.apply(sk, { refine_horz = false })
        W.grid:setSkin(sk)
    end)
    local function header(label)
        local hc = GridHeaderCell.new()
        skin_helper.apply(hc, 'sms_grid_header')
        pcall(function() hc:setText(label) end)
        return hc
    end
    pcall(function() W.grid:insertColumn(150, header('Selection')) end)
    pcall(function() W.grid:insertColumn(38, header('#')) end)
    pcall(function() raw:insertWidget(W.grid) end)

    W.grid.onMouseDown = function(self, mx, my, button)
        if button ~= 1 then return end
        local row
        pcall(function() local _, rr = self:getMouseCursorColumnRow(mx, my); row = rr end)
        if not row or row < 0 then return end
        local key = W.row_meta[row]
        local node = key and W.model and W.model.by_key[key]
        if not node then return end
        W.selected_key = key
        pcall(function() self:selectRow(row) end)
        render_right(node)
    end
    W.grid.onMouseDoubleClick = function(self, mx, my, button)
        if button ~= 1 then return end
        local row
        pcall(function() local _, rr = self:getMouseCursorColumnRow(mx, my); row = rr end)
        if not row or row < 0 then return end
        local key = W.row_meta[row]
        local node = key and W.model and W.model.by_key[key]
        if node and node.expandable then
            W.collapsed[node.key] = not W.collapsed[node.key]
            render_tree()
        end
    end

    -- Splitter between the panes.
    W.splitter = splitter_mod.new(raw, {
        initial = W.left_w, min = LAYOUT.MIN_LEFT, max = 800, skin = 'sms_splitter',
        on_drag = function(new_left_w)
            W.left_w = new_left_w
            M._relayout()
        end,
    })

    -- Right: header + scroll pane (button list) + empty hint.
    W.right_header = Static.new(node_title(nil))
    skin_helper.apply(W.right_header, 'staticSkin_ME')
    pcall(function() raw:insertWidget(W.right_header) end)

    W.right_parent = raw
    if ScrollPane and ScrollPane.new then
        local ok_sp, sp = pcall(ScrollPane.new)
        if ok_sp and sp then
            skin_helper.apply(sp, 'sms_scroll_pane')
            pcall(function() raw:insertWidget(sp) end)
            W.right_scroll = sp
            W.right_parent = sp
        end
    end

    W.right_empty = Static.new('No triggers reference this.')
    skin_helper.apply(W.right_empty, 'staticSkin_ME')
    pcall(function() raw:insertWidget(W.right_empty) end)
    pcall(function() W.right_empty:setVisible(false) end)
end

-- ── public surface ──────────────────────────────────────────────────────────

function M.show()
    if W.sms_window and W.sms_window:raw() then
        W.sms_window:show()
        install_tick()
        pcall(paint_now)
        return
    end
    W.sms_window = sms_window.new({
        title    = 'Trigger Finder',
        size     = { w = 820, h = 440 },
        min_size = { w = 420, h = 260 },
        disable_undo_hotkey = true,
        on_resize = function(_, x, y, w, h) relayout(x, y, w, h) end,
    })
    if not W.sms_window then log_warn('sms_window.new returned nil'); return end
    build_body(W.sms_window:raw())
    install_tick()
    M._relayout()
    W.sms_window:show()
    pcall(paint_now)    -- initial populate from the current selection
    log_info('Trigger Finder opened')
end

function M.hide()
    if W.sms_window then W.sms_window:hide() end
end

function M.toggle()
    if W.sms_window and W.sms_window:raw() and W.sms_window:raw():isVisible() then
        M.hide()
    else
        M.show()
    end
end

function M.refresh()
    pcall(paint_now)
end

return M
