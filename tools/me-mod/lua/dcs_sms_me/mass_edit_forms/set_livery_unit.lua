-- mass_edit_forms/set_livery_unit.lua -- Mass Edit form: set the livery
-- on every checked plane / helicopter via verbs.unit_set_livery.
--
-- Airframe gating: this form is grayed in two cases — (a) the universal
-- applicability rule (no checked planes/helos at all), and (b) the
-- checked planes/helos span more than one distinct airframe `type`.
-- The host's recompute_form_gating only enforces (a); we override
-- panel:set_enabled to also enforce (b) and downgrade flag→false when
-- mixed airframes are checked.
--
-- Livery source resolution preference order:
--   1. ME's loadLiveries.loadSchemes(DB.liveryEntryPoint(airframe), country) —
--      same API the stock ME aircraft / loadout dialogs use.
--   2. Filesystem scan across the standard livery roots (Saved Games,
--      CoreMods\aircraft, Bazar\Liveries).
--   3. Free-text EditBox fallback — for airframes where neither the ME
--      API nor a filesystem scan turned up anything (e.g. unregistered
--      mods); user types the livery_id verbatim.
--
-- `livery=""` is a valid value (DCS default livery). The apply guard
-- only rejects non-string args, not the empty string.

local M = {}

M.scope = 'unit'
M.title = 'Set livery'
M.applies_to = { plane = true, helicopter = true }

local undo          = require('dcs_sms_me.undo')
local skin_helper   = require('dcs_sms_me.skin_helper')
local applicability = require('dcs_sms_me.applicability')

local Static;       do local ok, m = pcall(require, 'Static');       if ok then Static       = m end end
local EditBox;      do local ok, m = pcall(require, 'EditBox');      if ok then EditBox      = m end end
local Button;       do local ok, m = pcall(require, 'Button');       if ok then Button       = m end end
local ComboList;    do local ok, m = pcall(require, 'ComboList');    if ok then ComboList    = m end end
local ListBoxItem;  do local ok, m = pcall(require, 'ListBoxItem');  if ok then ListBoxItem  = m end end

local function log_warn(msg) pcall(function() _G.log.write('sms.me.mass_edit.set_livery_unit', _G.log.WARNING or 2, msg) end) end

-- ---------------------------------------------------------------------------
-- Airframe gating helpers (used by panel:set_enabled override).
-- ---------------------------------------------------------------------------

local function checked_planes_helos(get_checked, get_categories)
    local cats = (type(get_categories) == 'function') and get_categories() or {}
    local entities = (type(get_checked) == 'function') and get_checked() or {}
    local out = {}
    for _, u in ipairs(entities) do
        local c = cats[u]
        if c == 'plane' or c == 'helicopter' then out[#out + 1] = u end
    end
    return out
end

local function distinct_airframes(units)
    local seen, n = {}, 0
    for _, u in ipairs(units) do
        local t = u.type or ''
        if t ~= '' and not seen[t] then seen[t] = true; n = n + 1 end
    end
    return n
end

local function dominant_airframe(units)
    -- All units in `units` are guaranteed to share a type (callers gate
    -- on distinct_airframes <= 1); return whichever type is present.
    for _, u in ipairs(units) do
        if u.type and u.type ~= '' then return u.type end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Livery source resolution.
-- ---------------------------------------------------------------------------

-- Filesystem scan: enumerate subdirectories of the three standard livery
-- roots for a given airframe. Returns a deduplicated list of livery names
-- (which are themselves the subdirectory names; the directory name IS
-- the livery_id DCS stores).
local function fs_scan_liveries(airframe)
    if type(airframe) ~= 'string' or airframe == '' then return {} end
    local lfs_ok, lfs = pcall(require, 'lfs')
    if not lfs_ok or type(lfs) ~= 'table' or type(lfs.dir) ~= 'function' then return {} end

    local roots = {}
    -- Saved Games\DCS\Liveries\<airframe>\ — user-installed.
    do
        local ok, wd = pcall(lfs.writedir)
        if ok and type(wd) == 'string' and wd ~= '' then
            roots[#roots + 1] = wd .. 'Liveries\\' .. airframe .. '\\'
        end
    end
    -- DCS install — best-effort via the current working directory's
    -- usual sibling. lfs.currentdir() inside the ME points at DCS\bin
    -- on most installs; the install root is one level up. We try both
    -- the bin parent and any explicit env path.
    do
        local cd_ok, cd = pcall(lfs.currentdir)
        if cd_ok and type(cd) == 'string' and cd ~= '' then
            local install = cd:gsub('\\bin$', ''):gsub('/bin$', '')
            if install:sub(-1) ~= '\\' then install = install .. '\\' end
            roots[#roots + 1] = install .. 'CoreMods\\aircraft\\' .. airframe .. '\\Liveries\\' .. airframe .. '\\'
            roots[#roots + 1] = install .. 'Bazar\\Liveries\\' .. airframe .. '\\'
        end
    end

    local seen, names = {}, {}
    for _, root in ipairs(roots) do
        local enum_ok, iter = pcall(lfs.dir, root)
        if enum_ok and type(iter) == 'function' then
            for entry in iter do
                if entry and entry ~= '.' and entry ~= '..' then
                    local full = root .. entry
                    local at_ok, attr = pcall(lfs.attributes, full, 'mode')
                    -- If lfs.attributes is missing or fails, accept the
                    -- entry anyway — better to over-list than under-list.
                    if (not at_ok) or attr == 'directory' or attr == nil then
                        if not seen[entry] then seen[entry] = true; names[#names + 1] = entry end
                    end
                end
            end
        end
    end
    return names
end

local function liveries_for(airframe)
    if type(airframe) ~= 'string' or airframe == '' then return {} end

    -- Preference 1: ME's loadLiveries.loadSchemes — same API the stock
    -- ME aircraft + loadout dialogs use. Returns
    -- { {itemId='aggressors', name='Aggressors'}, ... }.
    do
        local ok, names = pcall(function()
            local loadLiveries = require('loadLiveries')
            local DB = _G.DB
            if not (loadLiveries and loadLiveries.loadSchemes) then return nil end
            -- liveryEntryPoint translates airframe→livery-folder name
            -- (some mods point at a different folder than their type).
            local entry = airframe
            if DB and type(DB.liveryEntryPoint) == 'function' then
                local p_ok, p = pcall(DB.liveryEntryPoint, airframe)
                if p_ok and type(p) == 'string' and p ~= '' then entry = p end
            end
            local schemes = loadLiveries.loadSchemes(entry, nil)
            if type(schemes) ~= 'table' then return nil end
            local out = {}
            for _, s in ipairs(schemes) do
                if type(s) == 'table' and type(s.itemId) == 'string' then
                    out[#out + 1] = s.itemId
                end
            end
            return out
        end)
        if ok and type(names) == 'table' and #names > 0 then return names end
    end

    -- Preference 2: filesystem scan.
    local fs_names = fs_scan_liveries(airframe)
    if #fs_names > 0 then return fs_names end

    -- Preference 3: empty → caller swaps Combo for EditBox.
    return {}
end

-- ---------------------------------------------------------------------------
-- Apply (testable; no dxgui access).
-- ---------------------------------------------------------------------------

function M._apply(entities, livery, categories)
    if type(entities) ~= 'table' or #entities == 0 then
        return {
            changed = 0, failed = 0, not_applicable = 0, changed_rows = {},
            nothing_selected = true,
            toast = 'Nothing selected', sev = 'warning',
        }
    end
    if type(livery) ~= 'string' then
        return {
            changed = 0, failed = 0, not_applicable = 0, changed_rows = {},
            toast = 'Pick a livery', sev = 'warning',
        }
    end
    -- "" is a valid livery (DCS default).

    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed, not_applicable = {}, 0, 0

    for _, u in ipairs(entities) do
        if not applicability.is_applicable(M.applies_to, u, categories) then
            not_applicable = not_applicable + 1
        else
            local old = u.livery_id or ''
            if old == livery then
                -- already at target; silent skip (no separate counter
                -- for this form per the spec).
            else
                local p_ok, res = pcall(verbs.unit_set_livery, { id = u.unitId, livery = livery })
                if not p_ok then
                    failed = failed + 1
                    log_warn('unit_set_livery threw: ' .. tostring(res))
                elseif type(res) ~= 'table' or not res.ok then
                    failed = failed + 1
                    log_warn('unit_set_livery failed: ' .. tostring(res and res.error or '?'))
                else
                    changed_rows[#changed_rows + 1] = { unit = u, old = old }
                end
            end
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.set_livery_unit', { rows = changed_rows })
    end

    local result = {
        changed        = #changed_rows,
        failed         = failed,
        not_applicable = not_applicable,
        changed_rows   = changed_rows,
    }

    if #changed_rows == 0 and failed == 0 and not_applicable > 0 then
        result.toast = 'Nothing applicable'; result.sev = 'warning'
    elseif #changed_rows == 0 and failed > 0 then
        result.toast = string.format('0 livery set · %d failed', failed)
        result.sev   = 'error'
    elseif #changed_rows == 0 then
        result.toast = 'No changes'; result.sev = 'warning'
    else
        local toast = string.format('%d livery set', #changed_rows)
        if not_applicable > 0 then toast = toast .. string.format(' · %d not applicable', not_applicable) end
        if failed > 0         then toast = toast .. string.format(' · %d failed',         failed)         end
        result.toast = toast
        result.sev   = (failed == 0 and 'success') or 'warning'
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Undo handler -- registered at module load. Restores via the same verb
-- (reverse direction) so any side effects re-run on undo.
-- ---------------------------------------------------------------------------

undo.register_handler('mass_edit.set_livery_unit', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.set_livery_unit undo snapshot'
    end
    local verbs = require('dcs_sms_me.verbs')
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        if r.unit and r.old ~= nil then
            local p_ok, res = pcall(verbs.unit_set_livery, { id = r.unit.unitId, livery = r.old })
            if not (p_ok and type(res) == 'table' and res.ok) then errors = errors + 1 end
        else
            errors = errors + 1
        end
    end
    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

-- ---------------------------------------------------------------------------
-- Widget construction.
-- ---------------------------------------------------------------------------

local LAYOUT = {
    PAD_X      = 8,
    LABEL_W    = 56,
    ROW_H      = 24,
    BTN_W      = 90,
    GAP_X      = 6,
    GAP_Y      = 4,
    FOOTER_PAD = 6,
}

local function form_height()
    return LAYOUT.ROW_H + LAYOUT.FOOTER_PAD
end

function M.new(parent_raw, get_checked, on_after_apply, get_categories)
    if not parent_raw then return nil end

    local owned = {}
    local function add(widget)
        if widget then owned[#owned + 1] = widget; pcall(parent_raw.insertWidget, parent_raw, widget) end
        return widget
    end

    local livery_lbl, livery_combo, livery_edit, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new, 'Livery:')
        if ok and s then skin_helper.apply(s, 'staticSkin_ME'); livery_lbl = add(s) end
    end

    if ComboList and ComboList.new then
        local ok, c = pcall(ComboList.new)
        if ok and c then
            skin_helper.apply(c, 'comboListSkinNew_')
            livery_combo = add(c)
        end
    end

    -- EditBox is created up-front but hidden; it becomes the active
    -- input widget if liveries_for(airframe) returns empty at
    -- repopulate time (fallback path for un-enumerable airframes).
    if EditBox and EditBox.new then
        local ok, e = pcall(EditBox.new)
        if ok and e then
            skin_helper.apply(e, 'editBoxSkin_ME')
            livery_edit = add(e)
            if e.setVisible then pcall(e.setVisible, e, false) end
        end
    end

    if Button and Button.new then
        local ok, b = pcall(Button.new)
        if ok and b then
            skin_helper.apply(b, 'sms_button')
            if b.setText then pcall(b.setText, b, 'Set') end
            apply_btn = add(b)
        end
    end

    -- Re-populate the combo (or fall back to EditBox) for the currently
    -- dominant airframe. Called whenever set_enabled transitions to true.
    -- Captures the previous combo selection so it survives the rebuild
    -- when the same item is still present.
    local fallback_active = false
    local function repopulate_combo()
        local units = checked_planes_helos(get_checked, get_categories)
        local airframe = dominant_airframe(units)
        local names = (airframe and liveries_for(airframe)) or {}

        if #names == 0 then
            -- Fallback: hide combo, show EditBox.
            fallback_active = true
            if livery_combo and livery_combo.setVisible then pcall(livery_combo.setVisible, livery_combo, false) end
            if livery_edit  and livery_edit.setVisible  then pcall(livery_edit.setVisible,  livery_edit,  true)  end
            return
        end

        fallback_active = false
        if livery_combo and livery_combo.setVisible then pcall(livery_combo.setVisible, livery_combo, true)  end
        if livery_edit  and livery_edit.setVisible  then pcall(livery_edit.setVisible,  livery_edit,  false) end

        if not (livery_combo and ListBoxItem and ListBoxItem.new) then return end

        local prev_text
        if livery_combo.getSelectedItem then
            local cur = livery_combo:getSelectedItem()
            if cur and cur.getText then prev_text = cur:getText() end
        end
        if livery_combo.removeAllItems then pcall(livery_combo.removeAllItems, livery_combo) end

        table.sort(names)
        local match_item
        for _, name in ipairs(names) do
            local ok, item = pcall(ListBoxItem.new, name)
            if ok and item then
                pcall(livery_combo.insertItem, livery_combo, item)
                if prev_text and name == prev_text then match_item = item end
            end
        end
        if match_item and livery_combo.selectItem then
            pcall(livery_combo.selectItem, livery_combo, match_item)
        end
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local picked
                if fallback_active and livery_edit and livery_edit.getText then
                    picked = livery_edit:getText() or ''
                elseif livery_combo and livery_combo.getSelectedItem then
                    local item = livery_combo:getSelectedItem()
                    if item and item.getText then picked = item:getText() or '' else picked = '' end
                else
                    picked = ''
                end
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local cats     = (type(get_categories) == 'function') and get_categories() or {}
                local result   = M._apply(entities, picked, cats)
                if type(on_after_apply) == 'function' then on_after_apply(result) end
            end)
        end)
    end

    local panel = {}

    function panel:show()
        for _, w in ipairs(owned) do
            if w.setVisible then pcall(w.setVisible, w, true) end
        end
        -- After unhiding, restore the EditBox/Combo split per the
        -- current airframe state (in case it was hidden via show/hide
        -- while a fallback was active).
        if fallback_active then
            if livery_combo and livery_combo.setVisible then pcall(livery_combo.setVisible, livery_combo, false) end
        else
            if livery_edit and livery_edit.setVisible then pcall(livery_edit.setVisible, livery_edit, false) end
        end
    end

    function panel:hide()
        for _, w in ipairs(owned) do
            if w.setVisible then pcall(w.setVisible, w, false) end
        end
    end

    function panel:get_height() return form_height() end

    -- Override: host's recompute_form_gating sets flag=true whenever
    -- applicable > 0. We additionally enforce single-airframe-only —
    -- downgrade to false if checked planes/helos span >1 distinct
    -- `type` (or if there are zero planes/helos, which mirrors the
    -- host's universal rule for safety).
    function panel:set_enabled(flag)
        local en = flag and true or false
        if en then
            local units = checked_planes_helos(get_checked, get_categories)
            if distinct_airframes(units) > 1 or #units == 0 then en = false end
        end
        for _, w in ipairs(owned) do
            if w.setEnabled then pcall(w.setEnabled, w, en) end
        end
        -- Refresh the combo for the (now-single) airframe whenever we
        -- transition into the enabled state — the airframe may have
        -- changed since the last populate.
        if en then repopulate_combo() end
    end

    function panel:set_bounds(x, y, w, h)
        local L = LAYOUT
        local function set(widget, px, py, pw, ph)
            if widget and widget.setBounds then pcall(widget.setBounds, widget, px, py, pw, ph) end
        end

        local row_y = y
        local apply_x = x + w - L.PAD_X - L.BTN_W
        local input_x = x + L.PAD_X + L.LABEL_W + L.GAP_X
        local input_w = apply_x - L.GAP_X - input_x
        if input_w < 80 then input_w = 80 end

        set(livery_lbl,   x + L.PAD_X, row_y, L.LABEL_W, L.ROW_H)
        set(livery_combo, input_x,     row_y, input_w,   L.ROW_H)
        set(livery_edit,  input_x,     row_y, input_w,   L.ROW_H)
        set(apply_btn,    apply_x,     row_y, L.BTN_W,   L.ROW_H)
    end

    return panel
end

return M
