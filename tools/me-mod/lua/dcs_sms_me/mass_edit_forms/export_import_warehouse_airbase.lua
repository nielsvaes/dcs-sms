-- mass_edit_forms/export_import_warehouse_airbase.lua -- Mass Edit form:
-- save the warehouse entry from one selected airbase to a named file under
-- paths.WAREHOUSES_DIR, then apply that saved entry to any number of other
-- selected airbases.
--
-- File format: Lua source via dcs_sms_me.serializer.serialize -- returns a
-- `return { ... }` chunk that can be loadstring-ed back into a table.
-- Each file holds one warehouse entry (NOT a list).

local M = {}

M.scope = 'airbase'
M.title = 'Export / Import warehouse'

local undo            = require('dcs_sms_me.undo')
local warehouse_ops   = require('dcs_sms_me.warehouse_ops')
local skin_helper     = require('dcs_sms_me.skin_helper')
local paths           = require('dcs_sms_me.paths')

local lfs;        do local ok, m = pcall(require, 'lfs');                       if ok then lfs        = m end end
local serializer; do local ok, m = pcall(require, 'dcs_sms_me.serializer');     if ok then serializer = m end end
local clearable_edit;do local ok, m=pcall(require, 'dcs_sms_me.clearable_edit');if ok then clearable_edit = m end end

local Static;      do local ok, m = pcall(require, 'Static');      if ok then Static      = m end end
local ComboList;   do local ok, m = pcall(require, 'ComboList');   if ok then ComboList   = m end end
local ListBoxItem; do local ok, m = pcall(require, 'ListBoxItem'); if ok then ListBoxItem = m end end
local Button;      do local ok, m = pcall(require, 'Button');      if ok then Button      = m end end

-- ---------------------------------------------------------------------------
-- Filename sanitisation. Keep [A-Za-z0-9 _-], strip others.
-- ---------------------------------------------------------------------------

local function sanitise(name)
    name = tostring(name or '')
    -- Replace disallowed chars with underscore.
    name = name:gsub('[^A-Za-z0-9 _-]', '_')
    -- Collapse runs of whitespace.
    name = name:gsub('%s+', ' ')
    -- Trim.
    name = name:gsub('^%s+', ''):gsub('%s+$', '')
    if #name > 64 then name = name:sub(1, 64) end
    return name
end

-- ---------------------------------------------------------------------------
-- File I/O.
-- ---------------------------------------------------------------------------

local function path_for(name)
    return paths.WAREHOUSES_DIR .. sanitise(name) .. '.lua'
end

function M._list_files()
    if not lfs then return {} end
    paths.ensure_warehouses()
    local names = {}
    for fname in lfs.dir(paths.WAREHOUSES_DIR) do
        local base = fname:match('^(.+)%.lua$')
        if base then names[#names + 1] = base end
    end
    table.sort(names)
    return names
end

function M._save(name, entity)
    if type(entity) ~= 'table' or type(entity.id) ~= 'number' then
        return { ok = false, err = 'entity is missing id' }
    end
    local clean = sanitise(name)
    if clean == '' then return { ok = false, err = 'name is empty after sanitise' } end
    local entry = warehouse_ops.extract(entity.id)
    if not entry then return { ok = false, err = 'no warehouse for airbase id ' .. tostring(entity.id) } end

    paths.ensure_warehouses()
    local target = path_for(clean)
    -- serializer.serialize returns a complete `return <table>\n` chunk —
    -- no need to prefix `return ` ourselves. For test VMs without the
    -- serializer module loaded, fall back to a tostring (which won't
    -- round-trip cleanly but lets the test verify the file-write path).
    local body
    if serializer and serializer.serialize then
        body = serializer.serialize(entry)
    else
        body = 'return ' .. tostring(entry) .. '\n'
    end
    if type(body) ~= 'string' then
        return { ok = false, err = 'serializer.serialize returned non-string' }
    end
    local f, ferr = io.open(target, 'w')
    if not f then return { ok = false, err = 'io.open: ' .. tostring(ferr) } end
    f:write('-- airbase warehouse export\n')
    f:write(body)
    f:close()
    return { ok = true, path = target, name = clean }
end

function M._load(name)
    local target = path_for(name)
    local f = io.open(target, 'r')
    if not f then return nil end
    local body = f:read('*a')
    f:close()
    -- Trim leading `-- airbase warehouse export` comment and `return ` prefix
    -- already produced by _save. loadstring handles the whole thing.
    local chunk, err = loadstring(body)
    if not chunk then return nil, err end
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= 'table' then return nil end
    return result
end

function M._delete(name)
    local target = path_for(name)
    return os.remove(target)
end

-- ---------------------------------------------------------------------------
-- Apply loaded warehouse to selected airbases. Snapshots prior state per
-- airbase for undo.
-- ---------------------------------------------------------------------------

function M._apply_to_entities(entities, name)
    if type(entities) ~= 'table' or #entities == 0 then
        return { ok = false, toast = 'no airbases checked', sev = 'warning' }
    end
    local entry = M._load(name)
    if not entry then
        return { ok = false, toast = 'failed to load "' .. tostring(name) .. '"', sev = 'warning' }
    end

    local rows = {}
    local errors = 0
    for _, e in ipairs(entities) do
        local snap = warehouse_ops.extract(e.id)
        if snap then
            local ok = warehouse_ops.apply(e.id, entry)
            if ok then
                rows[#rows + 1] = { id = e.id, prev_entry = snap }
            else
                errors = errors + 1
            end
        else
            errors = errors + 1
        end
    end

    if #rows > 0 then
        undo.record_generic('mass_edit.import_warehouse_airbase', { rows = rows })
    end
    local toast
    if errors == 0 then
        toast = string.format('imported "%s" into %d airbase%s', name, #rows, #rows == 1 and '' or 's')
    else
        toast = string.format('%d ok, %d failed', #rows, errors)
    end
    return { ok = errors == 0, toast = toast, sev = errors == 0 and 'info' or 'warning' }
end

undo.register_handler('mass_edit.import_warehouse_airbase', function(payload)
    if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then
        return nil, 'invalid payload'
    end
    local errors = 0
    for i = #payload.rows, 1, -1 do
        local row = payload.rows[i]
        if row and row.id and row.prev_entry then
            if not warehouse_ops.apply(row.id, row.prev_entry) then errors = errors + 1 end
        end
    end
    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

-- ---------------------------------------------------------------------------
-- Mount.
-- ---------------------------------------------------------------------------

function M.mount(parent_raw, opts)
    opts = opts or {}
    local get_checked    = opts.get_checked    or function() return {} end
    local on_after_apply = opts.on_after_apply

    local owned = {}
    local function add(w) owned[#owned + 1] = w; pcall(parent_raw.insertWidget, parent_raw, w); return w end

    local name_label, name_input, save_btn
    local combo_label, combo, delete_btn, apply_btn

    if Static and Static.new then
        local ok, s = pcall(Static.new); if ok and s then
            if s.setText then pcall(s.setText, s, 'Name:') end
            skin_helper.apply(s, 'staticSkin_ME')
            name_label = add(s)
        end
    end

    if clearable_edit then
        name_input = clearable_edit.new(parent_raw, {})
        if name_input then owned[#owned + 1] = name_input end
    end

    if Button and Button.new then
        local ok, b = pcall(Button.new); if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Save') end
            save_btn = add(b)
        end
    end

    if Static and Static.new then
        local ok, s = pcall(Static.new); if ok and s then
            if s.setText then pcall(s.setText, s, 'Saved:') end
            skin_helper.apply(s, 'staticSkin_ME')
            combo_label = add(s)
        end
    end

    if ComboList and ComboList.new and ListBoxItem and ListBoxItem.new then
        local ok, c = pcall(ComboList.new); if ok and c then
            skin_helper.apply(c, 'comboListSkinNew_')
            combo = add(c)
        end
    end

    if Button and Button.new then
        local ok, b = pcall(Button.new); if ok and b then
            skin_helper.apply(b, 'dtc_button')
            if b.setText then pcall(b.setText, b, 'Delete') end
            delete_btn = add(b)
        end
        local ok2, b2 = pcall(Button.new); if ok2 and b2 then
            skin_helper.apply(b2, 'dtc_button')
            if b2.setText then pcall(b2.setText, b2, 'Apply') end
            apply_btn = add(b2)
        end
    end

    local function repopulate_combo()
        if not (combo and combo.removeAllItems) then return end
        pcall(combo.removeAllItems, combo)
        for _, name in ipairs(M._list_files()) do
            local ok, lbi = pcall(ListBoxItem.new, name)
            if ok and lbi then pcall(combo.insertItem, combo, lbi); lbi._name_value = name end
        end
    end
    repopulate_combo()

    if save_btn and save_btn.addMouseDownCallback then
        pcall(save_btn.addMouseDownCallback, save_btn, function()
            pcall(function()
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                if #entities ~= 1 then
                    if type(on_after_apply) == 'function' then
                        on_after_apply({ ok = false, toast = 'Save requires exactly one airbase checked', sev = 'warning' })
                    end
                    return
                end
                local name = (name_input and name_input.getText and name_input:getText()) or ''
                local res = M._save(name, entities[1])
                if res and res.ok then
                    repopulate_combo()
                    if type(on_after_apply) == 'function' then
                        on_after_apply({ ok = true, toast = 'saved "' .. res.name .. '"', sev = 'info' })
                    end
                else
                    if type(on_after_apply) == 'function' then
                        on_after_apply({ ok = false, toast = 'save failed: ' .. tostring(res and res.err), sev = 'warning' })
                    end
                end
            end)
        end)
    end

    if delete_btn and delete_btn.addMouseDownCallback then
        pcall(delete_btn.addMouseDownCallback, delete_btn, function()
            pcall(function()
                local picked = combo and combo.getSelectedItem and combo:getSelectedItem()
                local name = picked and picked._name_value
                if not name then return end
                M._delete(name)
                repopulate_combo()
                if type(on_after_apply) == 'function' then
                    on_after_apply({ ok = true, toast = 'deleted "' .. name .. '"', sev = 'info' })
                end
            end)
        end)
    end

    if apply_btn and apply_btn.addMouseDownCallback then
        pcall(apply_btn.addMouseDownCallback, apply_btn, function()
            pcall(function()
                local picked = combo and combo.getSelectedItem and combo:getSelectedItem()
                local name = picked and picked._name_value
                if not name then return end
                local entities = (type(get_checked) == 'function') and get_checked() or {}
                local result = M._apply_to_entities(entities, name)
                if type(on_after_apply) == 'function' then on_after_apply(result) end
            end)
        end)
    end

    local LABEL_W = 60
    local BTN_W   = 90
    local ROW_H   = 24
    local PAD     = 4

    local panel = {
        widgets = owned,
        get_height = function() return ROW_H * 2 + PAD + ROW_H end,
        set_bounds = function(_, x, y, w, _)
            local row_y = y
            -- Row 1: Name: [input] [Save]
            if name_label and name_label.setBounds then pcall(name_label.setBounds, name_label, x, row_y, LABEL_W, ROW_H) end
            local input_x = x + LABEL_W + PAD
            local save_x  = x + w - BTN_W
            local input_w = math.max(40, save_x - input_x - PAD)
            if name_input and name_input.set_bounds then pcall(name_input.set_bounds, name_input, input_x, row_y, input_w, ROW_H) end
            if save_btn and save_btn.setBounds then pcall(save_btn.setBounds, save_btn, save_x, row_y, BTN_W, ROW_H) end
            row_y = row_y + ROW_H + PAD
            -- Row 2: Saved: [combo] [Delete] [Apply]
            if combo_label and combo_label.setBounds then pcall(combo_label.setBounds, combo_label, x, row_y, LABEL_W, ROW_H) end
            local combo_x = x + LABEL_W + PAD
            local apply_x = x + w - BTN_W
            local delete_x = apply_x - PAD - BTN_W
            local combo_w  = math.max(40, delete_x - combo_x - PAD)
            if combo and combo.setBounds then pcall(combo.setBounds, combo, combo_x, row_y, combo_w, ROW_H) end
            if delete_btn and delete_btn.setBounds then pcall(delete_btn.setBounds, delete_btn, delete_x, row_y, BTN_W, ROW_H) end
            if apply_btn and apply_btn.setBounds then pcall(apply_btn.setBounds, apply_btn, apply_x, row_y, BTN_W, ROW_H) end
        end,
        show = function() for _, w in ipairs(owned) do if w.setVisible then pcall(w.setVisible, w, true) end if w.show then pcall(w.show, w) end end end,
        hide = function() for _, w in ipairs(owned) do if w.setVisible then pcall(w.setVisible, w, false) end if w.hide then pcall(w.hide, w) end end end,
    }
    return panel
end

return M
