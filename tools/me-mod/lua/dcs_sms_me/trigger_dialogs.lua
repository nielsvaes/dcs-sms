-- trigger_dialogs.lua — the two trigger UI overlays (spec §2/§3):
--   show_bundle_dialog: save-time "this selection has related triggers"
--   show_import_dialog: post-place "this prefab includes triggers"
-- Pure dxgui glue over data prepared by trigger_export / trigger_import.
-- All widget construction is pcall-guarded; in the test VM (no dxgui)
-- both functions degrade to invoking the affirmative callback with
-- everything checked / no bindings (mirrors prefab_manager's
-- show_overlay fallback philosophy — flows never deadlock).

local M = {}

local MAX_ROWS = 14
local ROW_H, PAD = 22, 10

-- dxgui modules. pcall-required so the module loads under plain Lua 5.1
-- (test VM) where none of these are present.
local Window;      do local ok, m = pcall(require, 'Window');      if ok then Window      = m end end
local Static;      do local ok, m = pcall(require, 'Static');      if ok then Static      = m end end
local Button;      do local ok, m = pcall(require, 'Button');      if ok then Button      = m end end
local CheckBox;    do local ok, m = pcall(require, 'CheckBox');    if ok then CheckBox    = m end end
local ComboList;   do local ok, m = pcall(require, 'ComboList');   if ok then ComboList   = m end end
local ListBoxItem; do local ok, m = pcall(require, 'ListBoxItem'); if ok then ListBoxItem = m end end
local ScrollPane;  do local ok, m = pcall(require, 'ScrollPane');  if ok then ScrollPane  = m end end
local Gui;         do local ok, m = pcall(require, 'dxgui');       if ok then Gui         = m end end
local Skin;        do local ok, m = pcall(require, 'Skin');        if ok then Skin        = m end end

local skin_helper; do local ok, m = pcall(require, 'dcs_sms_me.skin_helper'); if ok then skin_helper = m end end
local sms_skins;   do local ok, m = pcall(require, 'dcs_sms_me.sms_skins');   if ok then sms_skins   = m end end

-- UTF-8 glyphs kept as byte escapes so the source stays ASCII-safe.
local CHECK_GLYPH = '\226\156\147'             -- ✓
local FLAG_GLYPH  = '\226\154\145'             -- ⚑
local EMDASH      = '\226\128\148'             -- —
local SKIP_LABEL  = EMDASH .. ' skip this condition/action ' .. EMDASH

local function log_err(msg)
    pcall(function() _G.log.write('sms.me.trigger_dialogs', _G.log.ERROR or 1, tostring(msg)) end)
end

-- Apply a skin by name. 'sms_status_yellow' is the amber Static skin
-- sms_window's set_status maps the 'warning' severity to; everything else
-- goes through the shared skin_helper (staticSkin_ME, sms_button, ...).
local function try_skin(widget, name)
    pcall(function()
        if not (widget and widget.setSkin) then return end
        if name == 'sms_status_yellow' then
            if sms_skins and sms_skins.static_yellow then
                local s = sms_skins.static_yellow()
                if s then widget:setSkin(s) end
            end
        elseif skin_helper then
            skin_helper.apply(widget, name)
        end
    end)
end

local function truncate(s, n)
    s = tostring(s or '')
    if #s > n then return s:sub(1, n - 3) .. '...' end
    return s
end

local function close_window(win)
    pcall(function() if win and win.setVisible then win:setVisible(false) end end)
end

-- Live ME viewport size (falls back to 1600x900 outside the editor).
local function screen_size()
    local sw, sh = 1600, 900
    if Gui and Gui.GetWindowSize then
        local okk, a, b = pcall(Gui.GetWindowSize)
        if okk and type(a) == 'number' and type(b) == 'number' then sw, sh = a, b end
    end
    return sw, sh
end

-- Centered modal window: windowSkinME, zOrder 220, draggable, not
-- resizable — same construction as prefab_manager.show_rename_overlay.
-- Returns the Window or nil (caller falls back).
local function build_window(title, w, h)
    if not (Window and Window.new) then return nil end
    local win
    local ok = pcall(function()
        local sw, sh = screen_size()
        win = Window.new((sw - w) / 2, (sh - h) / 2, w, h, tostring(title or 'DCS-SMS'))
        win:setSkin((Skin and Skin.windowSkinME and Skin.windowSkinME())
                    or (Skin and Skin.windowSkin and Skin.windowSkin()))
        win:setVisible(true)
        win:setDraggable(true)
        win:setResizable(false)
        win:setZOrder(220)
    end)
    if not ok or not win then return nil end
    return win
end

-- Scroll viewport inside `win` (same construction Mass Edit's form pane
-- uses: ScrollPane + the lighter 'sms_scroll_pane' skin). Child widgets
-- are inserted into the returned pane with content-relative coords;
-- call pane:updateWidgetsBounds() after inserting so the scroll extent
-- is recomputed. Returns the pane or nil (caller falls back to the raw
-- window, which simply grows to fit).
local function build_scroll_pane(win, x, y, w, h)
    if not (ScrollPane and ScrollPane.new) then return nil end
    local sp
    local ok = pcall(function()
        sp = ScrollPane.new()
        if skin_helper then skin_helper.apply(sp, 'sms_scroll_pane') end
        win:insertWidget(sp)
        sp:setBounds(x, y, w, h)
    end)
    if not ok or not sp then return nil end
    return sp
end

local function make_label(win, text, x, y, w, skin)
    local s
    pcall(function()
        s = Static.new()
        s:setBounds(x, y, w, ROW_H)
        s:setText(tostring(text or ''))
    end)
    if not s then return nil end
    try_skin(s, skin or 'staticSkin_ME')
    pcall(function() win:insertWidget(s) end)
    return s
end

local function make_check(win, state, x, y)
    if not (CheckBox and CheckBox.new) then return nil end
    local ok, cb = pcall(CheckBox.new)
    if not (ok and cb) then return nil end
    try_skin(cb, 'checkBoxSkin_MENew')
    pcall(function() cb:setBounds(x, y + 2, 18, 18) end)
    if cb.setState then pcall(cb.setState, cb, state == true) end
    pcall(function() win:insertWidget(cb) end)
    return cb
end

local function make_button(win, label, x, y, w, on_click)
    local b
    pcall(function()
        b = Button.new()
        b:setBounds(x, y, w, 22)
        b:setText(tostring(label or '?'))
    end)
    if not b then return nil end
    try_skin(b, 'sms_button')
    pcall(function() b:addChangeCallback(function() pcall(on_click) end) end)
    pcall(function() win:insertWidget(b) end)
    return b
end

-- ComboList built the way prefab_manager builds W.country_combo:
-- ComboList.new() + comboListSkinNew_ skin + ListBoxItem entries.
-- entries = { {label=..., value=...}, ... }; first entry preselected.
-- Returns combo, by_text (label → value) or nil.
local function make_combo(win, x, y, w, entries)
    if not (ComboList and ComboList.new and ListBoxItem and ListBoxItem.new) then return nil end
    local combo, by_text = nil, {}
    local ok = pcall(function()
        combo = ComboList.new()
        try_skin(combo, 'comboListSkinNew_')
        combo:setBounds(x, y, w, ROW_H)
        local first
        for _, e in ipairs(entries) do
            local item = ListBoxItem.new(tostring(e.label))
            combo:insertItem(item)
            by_text[tostring(e.label)] = e.value
            first = first or item
        end
        if first and combo.selectItem then pcall(function() combo:selectItem(first) end) end
        win:insertWidget(combo)
    end)
    if not ok or not combo then return nil end
    return combo, by_text
end

local function read_combo_value(combo, by_text)
    local v
    pcall(function()
        if combo and combo.getSelectedItem then
            local item = combo:getSelectedItem()
            if item and item.getText then v = by_text[item:getText()] end
        end
    end)
    return v
end

-- ---------------------------------------------------------------------------
-- M.show_bundle_dialog(opts) — save-time checklist (spec §2 Flow B).
--   opts = { related, summarize, on_confirm(checked trigrules indices),
--            on_cancel }
-- ---------------------------------------------------------------------------
function M.show_bundle_dialog(opts)
    opts = type(opts) == 'table' and opts or {}
    local related    = type(opts.related) == 'table' and opts.related or {}
    local summarize  = opts.summarize
    local name_for   = type(opts.name_for) == 'function' and opts.name_for or nil
    local on_confirm = opts.on_confirm or function() end
    local on_cancel  = opts.on_cancel or function() end

    local function all_indices()
        local out = {}
        for _, e in ipairs(related) do out[#out + 1] = e.index end
        return out
    end

    if not (Window and Window.new and Static and Static.new and Button and Button.new) then
        -- Test VM / dxgui-less build: include everything so the save flow
        -- never deadlocks.
        log_err('bundle dialog: dxgui unavailable; confirming all ' .. #related .. ' related trigger(s)')
        pcall(on_confirm, all_indices())
        return
    end

    -- Visual line budget: 1 line per entry, +1 when it has outside refs.
    -- Entries past MAX_ROWS lines stay included-by-default and are
    -- summarized by the '(+N more)' static — no scrolling in v1.
    local shown_n, n_lines = 0, 0
    for i, e in ipairs(related) do
        local need = (#((type(e) == 'table' and e.outside_refs) or {}) > 0) and 2 or 1
        if n_lines + need > MAX_ROWS then break end
        n_lines = n_lines + need
        shown_n = i
    end
    local hidden_n = #related - shown_n
    if hidden_n > 0 then n_lines = n_lines + 1 end

    local w = 560
    local rows_y = 14 + ROW_H + 6
    local buttons_y = rows_y + n_lines * ROW_H + 12
    local h = buttons_y + 92

    local win
    local checks = {}   -- i (related index) → CheckBox
    local done = false
    local function finish(cb, arg)
        if done then return end
        done = true
        close_window(win)
        pcall(cb, arg)
    end

    local ok, err = pcall(function()
        win = build_window('Related triggers', w, h)
        if not win then error('window construction failed') end
        pcall(function() win.onClose = function() finish(on_cancel) end end)

        make_label(win, 'This selection is referenced by ' .. #related
                   .. ' mission trigger(s). Include them in the prefab?',
                   PAD, 14, w - 2 * PAD)

        local y = rows_y
        for i = 1, shown_n do
            local e = related[i]
            local trig = (type(e) == 'table' and e.trigger) or {}
            checks[i] = make_check(win, true, PAD, y)
            local summary = ''
            if type(summarize) == 'function' then
                local oks, s = pcall(summarize, trig)
                if oks and s ~= nil then summary = tostring(s) end
            end
            local text = tostring(trig.comment or '?')
            if summary ~= '' then text = text .. '   [' .. summary .. ']' end
            make_label(win, truncate(text, 90), PAD + 26, y, w - PAD * 2 - 26)
            y = y + ROW_H
            local outside = (type(e) == 'table' and e.outside_refs) or {}
            if #outside > 0 then
                local seen, parts = {}, {}
                for _, r in ipairs(outside) do
                    local nm
                    if name_for then
                        local okn, n = pcall(name_for, r.kind, r.id)
                        if okn then nm = n end
                    end
                    local tag = (nm and nm ~= '')
                        and (tostring(nm) .. ' (' .. tostring(r.kind) .. ')')
                        or (tostring(r.kind) .. ' ' .. tostring(r.id))
                    if not seen[tag] then seen[tag] = true; parts[#parts + 1] = tag end
                end
                make_label(win, 'also references: ' .. truncate(table.concat(parts, ', '), 80),
                           PAD + 26, y, w - PAD * 2 - 26, 'sms_status_yellow')
                y = y + ROW_H
            end
        end
        if hidden_n > 0 then
            make_label(win, '(+' .. hidden_n .. ' more)', PAD + 26, y, w - PAD * 2 - 26)
        end

        local function checked_indices()
            local out = {}
            for i, e in ipairs(related) do
                local on = true   -- default-checked model; hidden rows too
                local cb = checks[i]
                if cb and cb.getState then
                    local oks, st = pcall(cb.getState, cb)
                    if oks then on = st == true end
                end
                if on then out[#out + 1] = e.index end
            end
            return out
        end

        make_button(win, 'Save with ' .. #related .. ' triggers',
                    w - PAD - 170 - 8 - 110, buttons_y, 170,
                    function() finish(on_confirm, checked_indices()) end)
        make_button(win, 'Save without', w - PAD - 110, buttons_y, 110,
                    function() finish(on_confirm, {}) end)
    end)
    if not ok then
        log_err('bundle dialog construction failed (' .. tostring(err)
                .. '); confirming all related triggers')
        finish(on_confirm, all_indices())
    end
end

-- ---------------------------------------------------------------------------
-- M.show_import_dialog(opts) — combined post-place dialog (spec §3).
--   opts = { plan, entity_options(kind) → {{id,name},...},
--            on_import(decisions), on_skip }
--   decisions = { checked  = { [t_idx] = false } (unchecked rows only),
--                 bindings = { [ref.key] = numeric id | 'skip' } }
-- ---------------------------------------------------------------------------
function M.show_import_dialog(opts)
    opts = type(opts) == 'table' and opts or {}
    local plan      = type(opts.plan) == 'table' and opts.plan or {}
    local triggers  = type(plan.triggers) == 'table' and plan.triggers or {}
    local overlaps  = type(plan.flag_overlaps) == 'table' and plan.flag_overlaps or {}
    local entity_options = opts.entity_options
    local on_import = opts.on_import or function() end
    local on_skip   = opts.on_skip or function() end

    if not (Window and Window.new and Static and Static.new and Button and Button.new) then
        -- Test VM / dxgui-less build: everything checked, no bindings —
        -- unresolved entries drop per the inject contract.
        log_err('import dialog: dxgui unavailable; importing with default decisions')
        pcall(on_import, {})
        return
    end

    local function default_checked(pt)
        return not (type(pt) == 'table' and pt.would_lose_all_actions)
    end

    local function status_text(pt)
        if pt.would_lose_all_actions then
            return '(would lose all actions ' .. EMDASH .. ' bind refs below to enable)'
        elseif (pt.unresolved or 0) == 0 then
            return 'all refs bound ' .. CHECK_GLYPH
        end
        return tostring(pt.unresolved) .. ' unresolved ref(s)'
    end

    -- Section 2 source rows: every unresolved ref across the plan.
    local unresolved = {}
    for _, pt in ipairs(triggers) do
        local pname = tostring((type(pt.portable) == 'table' and pt.portable.name) or 'Trigger')
        for _, r in ipairs((type(pt) == 'table' and pt.refs) or {}) do
            if type(r) == 'table' and r.resolution == 'unresolved' and r.key then
                unresolved[#unresolved + 1] = {
                    key  = r.key,
                    kind = tostring(r.kind or '?'),
                    label = pname .. ': ' .. tostring(r.kind or '?') .. ' "'
                            .. tostring(r.name or ('id ' .. tostring(r.id))) .. '"',
                }
            end
        end
    end

    local w = 660
    local PANE_Y = 14
    -- Natural height of the scrollable region (section 1 checklist +
    -- section 2 bindings), every row, no truncation.
    local natural_h = ROW_H + #triggers * ROW_H            -- intro line + checklist
    if #unresolved > 0 then
        natural_h = natural_h + 8 + ROW_H + #unresolved * ROW_H
    end

    -- Cap the viewport so the whole window (pane + flag strip + buttons +
    -- chrome) stays on screen; the rest scrolls. Without a ScrollPane the
    -- window just grows to fit (rare — real ME always has one).
    local _, sh   = screen_size()
    local flag_h  = (#overlaps > 0) and (8 + ROW_H) or 0
    local reserve = PANE_Y + flag_h + 12 + 92              -- chrome below the pane
    local max_pane = math.max(ROW_H * 4, math.floor(sh * 0.82) - reserve)
    local pane_h   = (ScrollPane and ScrollPane.new) and math.min(natural_h, max_pane)
                     or natural_h

    local content_bottom = PANE_Y + pane_h
    local flag_y
    if #overlaps > 0 then
        flag_y = content_bottom + 8
        content_bottom = flag_y + ROW_H
    end
    local buttons_y = content_bottom + 12
    local h = buttons_y + 92

    local win
    local checks = {}       -- t_idx → CheckBox
    local combo_rows = {}   -- { key, combo, by_text } for rendered section-2 rows
    local done = false
    local function finish(cb, arg)
        if done then return end
        done = true
        close_window(win)
        pcall(cb, arg)
    end

    local function options_for(kind)
        local entries = { { label = SKIP_LABEL, value = 'skip' } }
        if type(entity_options) == 'function' then
            local oks, list = pcall(entity_options, kind)
            if oks and type(list) == 'table' then
                for _, o in ipairs(list) do
                    if type(o) == 'table' and o.id ~= nil then
                        entries[#entries + 1] = {
                            label = truncate(tostring(o.name or '?'), 48)
                                    .. ' (id ' .. tostring(o.id) .. ')',
                            value = tonumber(o.id) or o.id,
                        }
                    end
                end
            end
        end
        return entries
    end

    local function gather_decisions()
        local decisions = { checked = {}, bindings = {} }
        -- (h) explicit false only for UNchecked rows; absent = import.
        for t_idx, pt in ipairs(triggers) do
            local on = default_checked(pt)
            local cb = checks[t_idx]
            if cb and cb.getState then
                local oks, st = pcall(cb.getState, cb)
                if oks then on = st == true end
            end
            if not on then decisions.checked[t_idx] = false end
        end
        -- (g) numeric id from the combo selection, or the 'skip' sentinel.
        for _, row in ipairs(combo_rows) do
            local v = read_combo_value(row.combo, row.by_text)
            if v == nil then v = 'skip' end
            decisions.bindings[row.key] = v
        end
        return decisions
    end

    local ok, err = pcall(function()
        win = build_window('Prefab triggers', w, h)
        if not win then error('window construction failed') end
        pcall(function() win.onClose = function() finish(on_skip) end end)

        -- Scrollable region: the trigger checklist (section 1) and the
        -- unresolved-ref bindings (section 2). Routed through a ScrollPane
        -- so every row stays reachable no matter how many triggers the
        -- prefab carries. Falls back to the raw window (which grew to fit)
        -- when no ScrollPane is available.
        local pane = build_scroll_pane(win, PAD, PANE_Y, w - 2 * PAD, pane_h)
        local body = pane or win
        local SCROLLBAR_W = 18
        local cx = pane and 0 or PAD                          -- content origin x
        local cw = pane and (w - 2 * PAD - SCROLLBAR_W) or (w - 2 * PAD)
        local y  = pane and 0 or PANE_Y                       -- content origin y

        -- Section 1: trigger checklist.
        make_label(body, 'This prefab includes ' .. #triggers .. ' trigger(s):',
                   cx, y, cw)
        y = y + ROW_H
        for t_idx = 1, #triggers do
            local pt = triggers[t_idx]
            local p = type(pt.portable) == 'table' and pt.portable or {}
            checks[t_idx] = make_check(body, default_checked(pt), cx, y)
            local nm = (p.name ~= nil and p.name ~= '') and tostring(p.name) or 'Trigger'
            local label = string.format('%s  (%s, %d cond / %d act)  %s',
                nm, tostring(p.type or '?'),
                #(type(p.conditions) == 'table' and p.conditions or {}),
                #(type(p.actions) == 'table' and p.actions or {}),
                status_text(pt))
            make_label(body, truncate(label, 110), cx + 26, y, cw - 26)
            y = y + ROW_H
        end

        -- Section 2: unresolved-ref bindings.
        if #unresolved > 0 then
            y = y + 8
            make_label(body, 'Unresolved references ' .. EMDASH .. ' bind each one or skip it:',
                       cx, y, cw)
            y = y + ROW_H
            local combo_x = cx + 310
            for i = 1, #unresolved do
                local ur = unresolved[i]
                make_label(body, truncate(ur.label, 56), cx, y, 300)
                local combo, by_text = make_combo(body, combo_x, y, cw - 310,
                                                  options_for(ur.kind))
                combo_rows[#combo_rows + 1] = { key = ur.key, combo = combo,
                                                by_text = by_text or {} }
                y = y + ROW_H
            end
        end

        -- ScrollPane needs an explicit nudge to recompute its scroll extent
        -- once the child bounds are set (same as mass_edit's form pane).
        if pane and pane.updateWidgetsBounds then
            pcall(pane.updateWidgetsBounds, pane)
        end

        -- Section 3: flag-overlap warning strip. Fixed below the pane so it
        -- stays visible regardless of how far the checklist is scrolled.
        if #overlaps > 0 then
            local parts = {}
            for _, fv in ipairs(overlaps) do parts[#parts + 1] = tostring(fv) end
            make_label(win, FLAG_GLYPH .. ' Flags ' .. truncate(table.concat(parts, ', '), 70)
                       .. " are already used by this mission's triggers.",
                       PAD, flag_y, w - 2 * PAD, 'sms_status_yellow')
        end

        make_button(win, 'Import triggers', w - PAD - 130 - 8 - 110, buttons_y, 130,
                    function() finish(on_import, gather_decisions()) end)
        make_button(win, 'Skip triggers', w - PAD - 110, buttons_y, 110,
                    function() finish(on_skip) end)
    end)
    if not ok then
        log_err('import dialog construction failed (' .. tostring(err)
                .. '); importing with default decisions')
        finish(on_import, {})
    end
end

return M
