-- me_hotkey_actions.lua — the catalog of bindable Mission-Editor actions.
--
-- Pure data + lazy `invoke` thunks. NOTHING ME-specific is required at load
-- time (every invoke requires its ME module lazily inside the closure), so
-- this module loads cleanly in the test VM. Each invoke is best-effort and
-- pcall-guarded by the engine; entry points are re-verified against the live
-- ME during the release-gate smoke (spec §9).

local M = {}

-- Display/group order for the UI.
M.CATEGORIES = { 'Map/Selection', 'Object-add', 'Panel' }

-- ED-native hotkeys we treat as "owned by the editor" when reporting what a
-- re-assignment displaces. Keys are in parseHotKey comparison form (lowercase).
-- a/h/s/u/o are ED add-tool keys but are ALSO our object-add defaults, so they
-- appear as managed actions below, not here.
M.ED_CONFLICTS = {
    ['ctrl+o'] = 'File: Open',  ['ctrl+n'] = 'File: New',   ['ctrl+s'] = 'File: Save',
    ['ctrl+p'] = 'Fly mission', ['ctrl+m'] = 'Fly (start mission)',
    ['ctrl+w'] = 'Set position',['ctrl+y'] = 'Coords info',  ['ctrl+i'] = 'Multi-template',
    ['ctrl+r'] = 'Record AVI',  ['ctrl+d'] = 'DTC manager',
    ['ctrl+c'] = 'Copy',        ['ctrl+v'] = 'Paste',        ['ctrl+x'] = 'Cut',
    ['ctrl+z'] = 'Undo',        ['c'] = 'Center on player',  ['delete'] = 'Remove',
    ['escape'] = 'Deselect',    ['alt+y'] = 'Coord system',
}

-- Normalize a hotkey string to comparison form. parseHotKey lowercases the
-- whole string and is modifier-order-independent; our defaults and capture
-- both emit a fixed 'Ctrl+/Alt+/Shift+' order, so lowercasing is sufficient
-- for equality.
function M.normalize_key(key)
    if type(key) ~= 'string' then return nil end
    return (key:gsub('%s+', '')):lower()
end

-- ---- invoke helpers (lazy; never executed at load) ----

local function call_toolbar(fn_name)
    return function()
        pcall(function() local t = require('me_toolbar'); if t[fn_name] then t[fn_name]() end end)
    end
end

local function call_map(fn_name)
    return function()
        pcall(function() local mw = require('me_map_window'); if mw[fn_name] then mw[fn_name]() end end)
    end
end

-- Panel toggle: flip visibility. Uses the panel module's isVisible() when
-- present, else a local per-id boolean as a best-effort fallback.
local panel_state = {}
local function toggle_panel(id, mod_name, show_fn)
    return function()
        pcall(function()
            local mod = require(mod_name)
            if not mod or not mod[show_fn] then return end
            local want
            if type(mod.isVisible) == 'function' then
                local v; pcall(function() v = mod.isVisible() end)
                want = not v
            else
                want = not panel_state[id]; panel_state[id] = want
            end
            mod[show_fn](want)
        end)
    end
end

local function multi_select()
    pcall(function()
        local ms = require('me_multiSelection')
        local mw = require('me_map_window')
        local on = false
        if type(ms.isVisible) == 'function' then pcall(function() on = ms.isVisible() end) end
        ms.show(not on)
        if not on then pcall(function() mw.setState(mw.getMultiSelectionState()) end)
        else pcall(function() mw.setState(mw.getPanState()) end) end
    end)
end

-- ---- the catalog ----
-- ed_key = the editor's native key for this action, or nil if it has none.
-- For native actions default_key == ed_key; keyless actions get a free letter.
local ACTIONS = {
    -- Map/Selection
    { id='map.multi_select', label='Multi Select', category='Map/Selection', default_key='m',     ed_key=nil,     invoke=multi_select },
    { id='map.zoom_in',      label='Zoom in',      category='Map/Selection', default_key='+',     ed_key='+',     invoke=call_map('onChange_Plus') },
    { id='map.zoom_out',     label='Zoom out',     category='Map/Selection', default_key='-',     ed_key='-',     invoke=call_map('onChange_Minus') },
    { id='map.pan_up',       label='Pan up',       category='Map/Selection', default_key='up',    ed_key='up',    invoke=call_map('onChange_Up') },
    { id='map.pan_down',     label='Pan down',     category='Map/Selection', default_key='down',  ed_key='down',  invoke=call_map('onChange_Down') },
    { id='map.pan_left',     label='Pan left',     category='Map/Selection', default_key='left',  ed_key='left',  invoke=call_map('onChange_Left') },
    { id='map.pan_right',    label='Pan right',    category='Map/Selection', default_key='right', ed_key='right', invoke=call_map('onChange_Right') },
    { id='map.coord_system', label='Coord system', category='Map/Selection', default_key='Alt+Y', ed_key='Alt+Y', invoke=call_map('onChange_CoordsSys') },
    { id='map.ruler',        label='Ruler / Tape', category='Map/Selection', default_key='r',     ed_key=nil,     invoke=call_map('onChange_Tape') },
    { id='map.camera',       label='Camera',       category='Map/Selection', default_key='k',     ed_key=nil,     invoke=toggle_panel('map.camera', 'freeCamera', 'show') },

    -- Object-add (ED native single letters)
    { id='object.airplane',   label='Airplane',   category='Object-add', default_key='a', ed_key='a', invoke=call_toolbar('addAirplane') },
    { id='object.helicopter', label='Helicopter', category='Object-add', default_key='h', ed_key='h', invoke=call_toolbar('addHelicopter') },
    { id='object.ship',       label='Ship',       category='Object-add', default_key='s', ed_key='s', invoke=call_toolbar('addShip') },
    { id='object.vehicle',    label='Vehicle',    category='Object-add', default_key='u', ed_key='u', invoke=call_toolbar('addVehicle') },
    { id='object.static',     label='Static',     category='Object-add', default_key='o', ed_key='o', invoke=call_toolbar('addStatic') },

    -- Panel toggles (keyless — free single letters)
    { id='panel.triggers',  label='Triggers',  category='Panel', default_key='t', ed_key=nil, invoke=toggle_panel('panel.triggers', 'panel_trigrules', 'show') },
    { id='panel.weather',   label='Weather',   category='Panel', default_key='w', ed_key=nil, invoke=toggle_panel('panel.weather',  'panel_weather',   'show') },
    { id='panel.briefing',  label='Briefing',  category='Panel', default_key='b', ed_key=nil, invoke=toggle_panel('panel.briefing', 'panel_briefing',  'show') },
    { id='panel.unit_list', label='Unit List', category='Panel', default_key='l', ed_key=nil, invoke=call_toolbar('handleUnitList') },
    { id='panel.draw',      label='Draw',      category='Panel', default_key='d', ed_key=nil, invoke=toggle_panel('panel.draw',     'panel_draw',      'show') },
    { id='panel.bullseye',  label='Bullseye',  category='Panel', default_key='e', ed_key=nil, invoke=toggle_panel('panel.bullseye', 'panel_bullseye',  'show') },
    { id='panel.goals',     label='Goals',     category='Panel', default_key='g', ed_key=nil, invoke=toggle_panel('panel.goals',    'panel_goal',      'showGoals') },
    { id='panel.roles',     label='Roles',     category='Panel', default_key='j', ed_key=nil, invoke=toggle_panel('panel.roles',    'panel_roles',     'show') },
    { id='panel.templates', label='Templates', category='Panel', default_key='p', ed_key=nil, invoke=call_toolbar('addTemplate') },
}

local BY_ID = {}
for _, a in ipairs(ACTIONS) do BY_ID[a.id] = a end

function M.list() return ACTIONS end
function M.get_action(id) return BY_ID[id] end

return M
