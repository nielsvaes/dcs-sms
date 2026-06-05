-- me_hotkey_actions.lua — the catalog of bindable Mission-Editor actions.
--
-- Pure data + lazy `invoke` thunks. NOTHING ME-specific is required at load
-- time (every invoke requires its ME module lazily inside the closure), so
-- this module loads cleanly in the test VM. Each invoke is best-effort and
-- pcall-guarded by the engine; entry points are re-verified against the live
-- ME during the release-gate smoke (spec §9).

local M = {}

-- Display/group order for the UI. DCS-SMS (this mod's own tools) leads; the next
-- three are toolbar-driven; the rest mirror the ME main-menu bar (File / Edit …).
M.CATEGORIES = {
    'DCS-SMS',
    'Map/Selection', 'Object-add', 'Panel',
    'File', 'Edit', 'View', 'Flight', 'Campaign', 'Dynamic Mission', 'Misc',
}

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

-- Main-menu item: fire the func attached to a menu-bar entry, exactly as the
-- menubar's onChange does (me_menubar.menuBar.<menu>.menu.<item>.func()). Lazy
-- require keeps this loadable before the menubar is constructed.
local function menu_item(menu_name, item_name)
    return function()
        pcall(function()
            local mb = require('me_menubar').menuBar
            local top = mb and mb[menu_name]
            local item = top and top.menu and top.menu[item_name]
            if item and type(item.func) == 'function' then item.func() end
        end)
    end
end

-- DCS-SMS tool: open one of this mod's own windows/dialogs by requiring its
-- module and calling the method the DCS-SMS menu uses (see menu.lua).
local function sms_tool(module_name, method)
    return function()
        pcall(function()
            local m = require('dcs_sms_me.' .. module_name)
            if m and type(m[method]) == 'function' then m[method]() end
        end)
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
    -- DCS-SMS (this mod's own tool windows — same entry points as the menu)
    { id='sms.prefab_manager', label='Prefab Manager', category='DCS-SMS', default_key='Alt+P', ed_key=nil, invoke=sms_tool('prefab_manager', 'toggle') },
    { id='sms.mass_edit',      label='Mass Edit',      category='DCS-SMS', default_key='Alt+E', ed_key=nil, invoke=sms_tool('mass_edit', 'toggle') },
    { id='sms.hotkeys',        label='Hotkeys',        category='DCS-SMS', default_key='Alt+K', ed_key=nil, invoke=sms_tool('me_hotkeys', 'toggle_window') },
    { id='sms.about',          label='About',          category='DCS-SMS', default_key='Alt+I', ed_key=nil, invoke=sms_tool('about', 'show') },

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
    -- Camera: disabled for now. toggleButtonCamera (free-camera mode) freezes the
    -- ME when you fly the mission and then return to the editor. Left here in case
    -- the underlying issue gets sorted — re-enable by uncommenting.
    -- { id='map.camera',    label='Camera',       category='Map/Selection', default_key='k',     ed_key=nil,     invoke=toolbar_button('toggleButtonCamera') },

    -- Object-add (ED native single letters — kept on ED's own binding)
    { id='object.airplane',   label='Airplane',   category='Object-add', default_key='a', ed_key='a', invoke=toolbar_button('toggleButtonAirplane') },
    { id='object.helicopter', label='Helicopter', category='Object-add', default_key='h', ed_key='h', invoke=toolbar_button('toggleButtonHelicopter') },
    { id='object.ship',       label='Ship',       category='Object-add', default_key='s', ed_key='s', invoke=toolbar_button('toggleButtonShip') },
    { id='object.vehicle',    label='Vehicle',    category='Object-add', default_key='u', ed_key='u', invoke=toolbar_button('toggleButtonVehicle') },
    { id='object.static',     label='Static',     category='Object-add', default_key='o', ed_key='o', invoke=toolbar_button('toggleButtonStatic') },
    { id='object.trigger_zone', label='Create Trigger Zone', category='Object-add', default_key='z', ed_key=nil, invoke=toolbar_button('toggleButtonZone') },

    -- Panel toggles (keyless — free single letters)
    { id='panel.triggers',     label='Triggers',              category='Panel', default_key='t', ed_key=nil, invoke=toolbar_button('toggleButtonTrigRules') },
    { id='panel.weather',      label='Weather',               category='Panel', default_key='w', ed_key=nil, invoke=toolbar_button('toggleButtonWeather') },
    { id='panel.briefing',     label='Briefing',              category='Panel', default_key='b', ed_key=nil, invoke=toolbar_button('toggleButtonBriefing') },
    { id='panel.unit_list',    label='Unit List',             category='Panel', default_key='l', ed_key=nil, invoke=toolbar_button('toggleButtonUnitList') },
    { id='panel.draw',         label='Draw',                  category='Panel', default_key='d', ed_key=nil, invoke=toolbar_button('toggleButtonDraw') },
    { id='panel.bullseye',     label='Bullseye',              category='Panel', default_key='e', ed_key=nil, invoke=toolbar_button('toggleButtonBullsEye') },
    { id='panel.goals',        label='Goals',                 category='Panel', default_key='g', ed_key=nil, invoke=toolbar_button('toggleButtonGoal') },
    { id='panel.roles',        label='Roles',                 category='Panel', default_key='j', ed_key=nil, invoke=toolbar_button('toggleButtonRoles') },
    { id='panel.templates',    label='Templates',             category='Panel', default_key='p', ed_key=nil, invoke=toolbar_button('toggleButtonTemplate') },
    { id='panel.map_options',  label='Map Options',           category='Panel', default_key='n', ed_key=nil, invoke=toolbar_button('toggleButtonMap') },
    { id='panel.zone_list',    label='View Trigger Zone List', category='Panel', default_key='v', ed_key=nil, invoke=toolbar_button('toggleButtonTrigZonesList') },

    -- ---- main-menu bar items ----
    -- These fire the menu-bar entries' own funcs. Where the editor already binds
    -- a working key (New/Open/Save = Ctrl+N/O/S, Fly = Ctrl+P, Record = Ctrl+R,
    -- DTC = Ctrl+D, Center = c, Remove = delete) we keep ed_key set so we ride
    -- ED's binding (no double-fire); the rest get free modifier combos we attach.
    -- Exit is intentionally NOT bindable (an accidental ME exit loses unsaved
    -- work). The Edit > Add* items are omitted — they're already under Object-add.

    -- File
    { id='file.new',         label='New',          category='File', default_key='Ctrl+N',       ed_key='Ctrl+N', invoke=menu_item('file', 'new') },
    { id='file.open',        label='Open',         category='File', default_key='Ctrl+O',       ed_key='Ctrl+O', invoke=menu_item('file', 'open') },
    { id='file.open_backup', label='Open Backup',  category='File', default_key='Ctrl+Shift+O', ed_key=nil,      invoke=menu_item('file', 'openBackup') },
    { id='file.save',        label='Save',         category='File', default_key='Ctrl+S',       ed_key='Ctrl+S', invoke=menu_item('file', 'save') },
    { id='file.save_as',     label='Save As',      category='File', default_key='Ctrl+Shift+S', ed_key=nil,      invoke=menu_item('file', 'saveAs') },

    -- Edit (Add* items live under Object-add)
    { id='edit.center',      label='Center on Player',     category='Edit', default_key='c',            ed_key='c',      invoke=menu_item('edit', 'centerOnPlayer') },
    { id='edit.remove',      label='Remove',               category='Edit', default_key='delete',       ed_key='delete', invoke=menu_item('edit', 'remove') },
    { id='edit.dtc',         label='DTC Manager',          category='Edit', default_key='Ctrl+D',       ed_key='Ctrl+D', invoke=menu_item('edit', 'managerDTC') },
    { id='edit.load_static', label='Load Static Template', category='Edit', default_key='Ctrl+Shift+L', ed_key=nil,      invoke=menu_item('edit', 'loadStaticTemplate') },
    { id='edit.save_static', label='Save Static Template', category='Edit', default_key='Ctrl+Alt+L',   ed_key=nil,      invoke=menu_item('edit', 'saveStaticTemplate') },

    -- View
    { id='view.beacons',  label='Beacons Info', category='View', default_key='Ctrl+Shift+B', ed_key=nil, invoke=menu_item('view', 'beaconsInfo') },
    { id='view.imperial', label='Imperial',     category='View', default_key='Ctrl+Shift+I', ed_key=nil, invoke=menu_item('view', 'mrImperial') },
    { id='view.metric',   label='Metric',       category='View', default_key='Ctrl+Alt+M',   ed_key=nil, invoke=menu_item('view', 'mrMetric') },
    { id='view.nato',     label='Icons NATO',   category='View', default_key='Ctrl+Alt+N',   ed_key=nil, invoke=menu_item('view', 'mrNato') },
    { id='view.russia',   label='Icons Russia', category='View', default_key='Ctrl+Alt+R',   ed_key=nil, invoke=menu_item('view', 'mrRussia') },

    -- Flight
    { id='flight.fly',     label='Fly Mission',      category='Flight', default_key='Ctrl+P',       ed_key='Ctrl+P', invoke=menu_item('flight', 'flyMission') },
    { id='flight.prepare', label='Prepare Mission',  category='Flight', default_key='Ctrl+Shift+P', ed_key=nil,      invoke=menu_item('flight', 'prepareMission') },
    { id='flight.record',  label='Record AVI',       category='Flight', default_key='Ctrl+R',       ed_key='Ctrl+R', invoke=menu_item('flight', 'recordAvi') },
    { id='flight.replay',  label='Replay',           category='Flight', default_key='Ctrl+Shift+R', ed_key=nil,      invoke=menu_item('flight', 'replay') },
    { id='flight.server',  label='Launch MP Server', category='Flight', default_key='Ctrl+Shift+E', ed_key=nil,      invoke=menu_item('flight', 'startServer') },

    -- Campaign
    { id='campaign.run',     label='Campaign',         category='Campaign', default_key='Ctrl+Shift+C', ed_key=nil, invoke=menu_item('campaign', 'campaign') },
    { id='campaign.builder', label='Campaign Builder', category='Campaign', default_key='Ctrl+Alt+C',   ed_key=nil, invoke=menu_item('campaign', 'campaignEditor') },

    -- Dynamic Mission — ED's Dynamic Campaign is still in development, so these
    -- are shipped DISABLED: greyed out, no key attached, not bindable. The
    -- default_key values are pre-wired so re-enabling (drop `disabled=true`) lights
    -- them up on Alt+digit once the feature lands.
    { id='dym.generate', label='Generate', category='Dynamic Mission', default_key='Alt+6', ed_key=nil, disabled=true, invoke=menu_item('dymMission', 'generate') },
    { id='dym.rts_on',   label='RTS On',   category='Dynamic Mission', default_key='Alt+1', ed_key=nil, disabled=true, invoke=menu_item('dymMission', 'rts_on') },
    { id='dym.rts_off',  label='RTS Off',  category='Dynamic Mission', default_key='Alt+2', ed_key=nil, disabled=true, invoke=menu_item('dymMission', 'rts_off') },
    { id='dym.open_dcm', label='Open DCM', category='Dynamic Mission', default_key='Alt+3', ed_key=nil, disabled=true, invoke=menu_item('dymMission', 'rts_openDCM') },
    { id='dym.open_trk', label='Open TRK', category='Dynamic Mission', default_key='Alt+4', ed_key=nil, disabled=true, invoke=menu_item('dymMission', 'rts_openTRK') },
    { id='dym.save_dcm', label='Save DCM', category='Dynamic Mission', default_key='Alt+5', ed_key=nil, disabled=true, invoke=menu_item('dymMission', 'rts_saveDCM') },

    -- Misc
    { id='misc.credits',      label='Credits',      category='Misc', default_key='Ctrl+Alt+A', ed_key=nil, invoke=menu_item('help', 'about') },
    { id='misc.encyclopedia', label='Encyclopedia', category='Misc', default_key='Ctrl+Alt+E', ed_key=nil, invoke=menu_item('help', 'encyclopedia') },
}

local BY_ID = {}
for _, a in ipairs(ACTIONS) do BY_ID[a.id] = a end

function M.list() return ACTIONS end
function M.get_action(id) return BY_ID[id] end

return M
