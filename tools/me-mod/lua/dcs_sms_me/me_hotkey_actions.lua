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
    ['escape'] = 'Deselect',
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
--
-- The Mission Editor's canonical entry point for any toolbar action is
-- me_toolbar.toolbarCallback(me_toolbar.toggleButton<X>) — it does
-- button:setState(true); button:onChange(). This is exactly how ED's own
-- a/h/s/u/o hotkeys fire (me_toolbar.lua setupKeyboard). Routing through it is
-- far more robust than poking guessed panel modules (panel_briefing, freeCamera
-- and friends are LOCALS inside me_toolbar.lua, not requirable modules — the
-- old toggle_panel/require('panel_*') approach silently no-op'd).

local function toolbar_button(button_name)
    return function()
        pcall(function()
            local t = require('me_toolbar')
            if t.toolbarCallback and t[button_name] then
                t.toolbarCallback(t[button_name])
            end
        end)
    end
end

local function call_map(fn_name)
    return function()
        pcall(function() local mw = require('me_map_window'); if mw[fn_name] then mw[fn_name]() end end)
    end
end

-- ---- the catalog ----
-- ed_key = a native ED hotkey we deliberately DON'T re-attach over (the engine
-- relies on ED's own binding so we never double-fire). Set ONLY for keys the
-- editor itself binds AND that actually fire: a/h/s/u/o (object add) and the
-- up/down/right pan arrows (me_toolbar.lua setupKeyboard). Everything else —
-- including left (ED never binds it), +/-/Alt+Y (ED binds them but they don't
-- fire reliably) and all keyless actions — gets ed_key=nil so we attach our own
-- callback and own the key outright.
local ACTIONS = {
    -- Map/Selection
    { id='map.multi_select', label='Multi Select', category='Map/Selection', default_key='m',     ed_key=nil,     invoke=toolbar_button('toggleButtonMultiSelection') },
    { id='map.zoom_in',      label='Zoom in',      category='Map/Selection', default_key='+',     ed_key=nil,     invoke=call_map('onChange_Plus') },
    { id='map.zoom_out',     label='Zoom out',     category='Map/Selection', default_key='-',     ed_key=nil,     invoke=call_map('onChange_Minus') },
    { id='map.pan_up',       label='Pan up',       category='Map/Selection', default_key='up',    ed_key='up',    invoke=call_map('onChange_Up') },
    { id='map.pan_down',     label='Pan down',     category='Map/Selection', default_key='down',  ed_key='down',  invoke=call_map('onChange_Down') },
    { id='map.pan_left',     label='Pan left',     category='Map/Selection', default_key='left',  ed_key=nil,     invoke=call_map('onChange_Left') },
    { id='map.pan_right',    label='Pan right',    category='Map/Selection', default_key='right', ed_key='right', invoke=call_map('onChange_Right') },
    { id='map.coord_system', label='Coord system', category='Map/Selection', default_key='Alt+Y', ed_key=nil,     invoke=call_map('onChange_CoordsSys') },
    { id='map.ruler',        label='Ruler / Tape', category='Map/Selection', default_key='r',     ed_key=nil,     invoke=toolbar_button('toggleButtonTape') },
    { id='map.camera',       label='Camera',       category='Map/Selection', default_key='k',     ed_key=nil,     invoke=toolbar_button('toggleButtonCamera') },

    -- Object-add (ED native single letters — kept on ED's own binding)
    { id='object.airplane',   label='Airplane',   category='Object-add', default_key='a', ed_key='a', invoke=toolbar_button('toggleButtonAirplane') },
    { id='object.helicopter', label='Helicopter', category='Object-add', default_key='h', ed_key='h', invoke=toolbar_button('toggleButtonHelicopter') },
    { id='object.ship',       label='Ship',       category='Object-add', default_key='s', ed_key='s', invoke=toolbar_button('toggleButtonShip') },
    { id='object.vehicle',    label='Vehicle',    category='Object-add', default_key='u', ed_key='u', invoke=toolbar_button('toggleButtonVehicle') },
    { id='object.static',     label='Static',     category='Object-add', default_key='o', ed_key='o', invoke=toolbar_button('toggleButtonStatic') },

    -- Panel toggles (keyless — free single letters)
    { id='panel.triggers',  label='Triggers',  category='Panel', default_key='t', ed_key=nil, invoke=toolbar_button('toggleButtonTrigRules') },
    { id='panel.weather',   label='Weather',   category='Panel', default_key='w', ed_key=nil, invoke=toolbar_button('toggleButtonWeather') },
    { id='panel.briefing',  label='Briefing',  category='Panel', default_key='b', ed_key=nil, invoke=toolbar_button('toggleButtonBriefing') },
    { id='panel.unit_list', label='Unit List', category='Panel', default_key='l', ed_key=nil, invoke=toolbar_button('toggleButtonUnitList') },
    { id='panel.draw',      label='Draw',      category='Panel', default_key='d', ed_key=nil, invoke=toolbar_button('toggleButtonDraw') },
    { id='panel.bullseye',  label='Bullseye',  category='Panel', default_key='e', ed_key=nil, invoke=toolbar_button('toggleButtonBullsEye') },
    { id='panel.goals',     label='Goals',     category='Panel', default_key='g', ed_key=nil, invoke=toolbar_button('toggleButtonGoal') },
    { id='panel.roles',     label='Roles',     category='Panel', default_key='j', ed_key=nil, invoke=toolbar_button('toggleButtonRoles') },
    { id='panel.templates', label='Templates', category='Panel', default_key='p', ed_key=nil, invoke=toolbar_button('toggleButtonTemplate') },
}

local BY_ID = {}
for _, a in ipairs(ACTIONS) do BY_ID[a.id] = a end

function M.list() return ACTIONS end
function M.get_action(id) return BY_ID[id] end

return M
