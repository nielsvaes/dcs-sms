# ME Hotkeys — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "ME Hotkeys" Mission-Editor tool that binds keyboard shortcuts to native ME actions (Multi Select, object-add tools, panel toggles), with per-action defaults and an Unreal-style reset-to-default arrow.

**Architecture:** Four pure, unit-tested Lua layers — an **action registry** (data + lazy `invoke` thunks), a **config** module (delta-from-default persistence), an **engine** (keymap diff/state logic over an injected backend), and a **backend** (dxgui attach/detach, two interchangeable implementations) — plus one dxgui-bound **window** and a thin **facade** wired into `init.lua`/`menu.lua`. The engine never touches dxgui, so its logic is fully testable with a fake backend.

**Tech Stack:** Lua 5.1 (DCS ME state), dxgui widgets (`sms_window`, `TreeView`/`Grid`/`Static`/`Button`), the existing `paths`/`me_settings` persistence idiom. Tests run via `tools/me-mod/test/run-tests.ps1` (standalone Lua 5.1).

**Spec:** [`docs/superpowers/specs/2026-06-04-me-hotkey-binding-tool-design.md`](../specs/2026-06-04-me-hotkey-binding-tool-design.md)

---

## File structure

New files under `tools/me-mod/lua/dcs_sms_me/`:

| File | Responsibility | dxgui? | Tested |
|---|---|---|---|
| `me_hotkey_actions.lua` | Action descriptors (id/label/category/default_key/ed_key/invoke) + ED conflict map + `normalize_key` | invoke only (lazy) | yes (data shape) |
| `me_hotkey_config.lua` | `serialize`/`deserialize` + `save`/`load` of override deltas | no | yes (round-trip) |
| `me_hotkey_engine.lua` | Keymap merge, diff, bind/unbind/reset, modified-state, `rows()`, `apply()` over injected backend | no | yes (fake backend) |
| `me_hotkey_backend.lua` | `perkey` (toolbar-window `addHotKeyCallback`) + `global` (`Gui.AddKeyboardCallback`) backends; `match_chord` pure helper | yes (guarded) | yes (`match_chord` only) |
| `me_hotkey_window.lua` | `sms_window` + tree/grid UI, capture overlay, reset arrows | yes | no (manual smoke) |
| `me_hotkeys.lua` | Facade singleton: build engine from registry+config+backend, `install()`, `persist()`, `toggle_window()` | no (delegates) | no |

New tests under `tools/me-mod/test/`: `test_hotkey_actions.lua`, `test_hotkey_config.lua`, `test_hotkey_engine.lua`, `test_hotkey_backend.lua`.

Modified: `menu.lua`, `init.lua`, `version.lua`, `run-tests.ps1`, `CHANGELOG.md`, `README.md`, `docs/release-gate/me-mod-smoke.md`, `tools/me-mod/AGENTS.md`, and a new `research/me-hotkey-spike.md`.

---

## Task 1: Spike note (manual, step-0 of spec §6)

**Files:**
- Create: `research/me-hotkey-spike.md`

The spike runs on a live ME and cannot be executed in this build session; this task records it so the user (or a later session with the ME open) can run it and flip the backend mode if needed. The code defaults to the `perkey` backend, which is correct if a re-registered key replaces ED's (last-wins).

- [ ] **Step 1: Write the spike note**

Create `research/me-hotkey-spike.md`:

```markdown
# ME Hotkeys — live-ME spike

Run with the ME open and **DCS-SMS → External execution: ON**. Use
`dcs-sms exec --target gui --code '<lua>'`. Records which engine backend to use.

## Q1 — per-key replace vs stack
```lua
local w = require('me_toolbar').window
w:addHotKeyCallback('a', function() log.write('sms.me.spike', log.INFO, 'PROBE a') end)
return 'attached probe to a — now press a in the ME and check dcs.log + whether the airplane tool still opens'
```
- Airplane tool still opens → **stack** (both fire). Airplane tool does NOT open → **replace** (last-wins).

## Q2 — global chokepoint suppression
```lua
local Gui = require('dxgui')
Gui.AddKeyboardCallback(function(keyName, keyState)
  log.write('sms.me.spike', log.INFO, 'KEY '..tostring(keyName)..' '..tostring(keyState))
end)
return 'logging all key events — press keys, check dcs.log; note whether ED actions still fire'
```

## Q3 — clean removal
```lua
local w = require('me_toolbar').window
local fn = function() log.write('sms.me.spike', log.INFO, 'PROBE2') end
w:addHotKeyCallback('p', fn)
w:removeHotKeyCallback('p', fn)
return 'attached then removed p — press p; PROBE2 should NOT log'
```

## Q4 — single-letter vs text input (make-or-break)
```lua
local w = require('me_toolbar').window
w:addHotKeyCallback('m', function() log.write('sms.me.spike', log.INFO, 'PROBE m') end)
return 'now open a unit name field and type a word with m — does it type normally or fire PROBE m?'
```

## Decision
| Q1 | Q2 | Backend | Native-override quality |
|---|---|---|---|
| replace | — | `perkey` (default) | clean |
| stack | suppress works | `global` | clean |
| stack | no suppress | `global`, additive | best-effort (ED key also fires) |

If the decision is `global`, set `M.BACKEND_MODE = 'global'` in
`tools/me-mod/lua/dcs_sms_me/me_hotkey_config.lua`.
```

- [ ] **Step 2: Commit**

```bash
git add research/me-hotkey-spike.md
git commit -m "docs(me-mod): add ME Hotkeys live-ME spike note"
```

---

## Task 2: Action registry

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/me_hotkey_actions.lua`
- Test: `tools/me-mod/test/test_hotkey_actions.lua`

- [ ] **Step 1: Write the failing test**

Create `tools/me-mod/test/test_hotkey_actions.lua`:

```lua
-- Standalone test for me_hotkey_actions.lua data shape. No dxgui needed:
-- invoke thunks require ME modules lazily, so the registry loads in plain Lua.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

local A = require('dcs_sms_me.me_hotkey_actions')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local list = A.list()
check('list is a non-empty table', type(list) == 'table' and #list > 0)

local valid_cat = {}
for _, c in ipairs(A.CATEGORIES) do valid_cat[c] = true end

local seen_id, seen_default = {}, {}
local all_fields_ok, unique_ids, unique_defaults, cats_ok, invokes_ok = true, true, true, true, true
for _, a in ipairs(list) do
    if type(a.id) ~= 'string' or a.id == '' then all_fields_ok = false end
    if type(a.label) ~= 'string' or a.label == '' then all_fields_ok = false end
    if type(a.default_key) ~= 'string' or a.default_key == '' then all_fields_ok = false end
    if type(a.invoke) ~= 'function' then invokes_ok = false end
    if not valid_cat[a.category] then cats_ok = false end
    if seen_id[a.id] then unique_ids = false end
    seen_id[a.id] = true
    local nk = A.normalize_key(a.default_key)
    if seen_default[nk] then unique_defaults = false end
    seen_default[nk] = true
end
check('every action has id/label/default_key strings', all_fields_ok)
check('every invoke is a function', invokes_ok)
check('every category is one of CATEGORIES', cats_ok)
check('action ids are unique', unique_ids)
check('default keys are unique (no two actions share a default)', unique_defaults)

check('get_action returns by id', A.get_action('map.multi_select') ~= nil)
check('get_action unknown returns nil', A.get_action('nope') == nil)

check('normalize_key lowercases', A.normalize_key('Ctrl+M') == 'ctrl+m')
check('ED_CONFLICTS has ctrl+m (start mission)', A.ED_CONFLICTS['ctrl+m'] ~= nil)
check('ED_CONFLICTS has ctrl+d (DTC)', A.ED_CONFLICTS['ctrl+d'] ~= nil)

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All me_hotkey_actions tests passed.')
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd tools/me-mod/test && pwsh -File run-tests.ps1` (or directly `lua test_hotkey_actions.lua`)
Expected: FAIL — `module 'dcs_sms_me.me_hotkey_actions' not found`.

- [ ] **Step 3: Write the registry**

Create `tools/me-mod/lua/dcs_sms_me/me_hotkey_actions.lua`:

```lua
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd tools/me-mod/test && lua test_hotkey_actions.lua`
Expected: PASS for all checks, final line `All me_hotkey_actions tests passed.`

- [ ] **Step 5: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/me_hotkey_actions.lua tools/me-mod/test/test_hotkey_actions.lua
git commit -m "feat(me-mod): add ME Hotkeys action registry"
```

---

## Task 3: Config (serialize / deserialize / persist)

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/me_hotkey_config.lua`
- Test: `tools/me-mod/test/test_hotkey_config.lua`

- [ ] **Step 1: Write the failing test**

Create `tools/me-mod/test/test_hotkey_config.lua`:

```lua
-- Standalone test for me_hotkey_config.lua pure serialize/deserialize.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local C = require('dcs_sms_me.me_hotkey_config')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function same(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

-- round-trip identity
local ov = { ['object.airplane'] = 'F1', ['panel.draw'] = 'Ctrl+Shift+D', ['map.ruler'] = '' }
local s = C.serialize(ov)
check('serialize returns a string', type(s) == 'string')
check('round-trip is identity', same(C.deserialize(s), ov))

-- empty
check('serialize empty round-trips to empty', same(C.deserialize(C.serialize({})), {}))

-- malformed input
check('deserialize non-string -> {}', same(C.deserialize(nil), {}))
check('deserialize garbage -> {}', same(C.deserialize('this is not lua {{{'), {}))
check('deserialize non-table return -> {}', same(C.deserialize('return 42'), {}))

-- only string keys+values survive
check('deserialize drops non-string values', same(C.deserialize('return { x = 5, y = "ok" }'), { y = 'ok' }))

-- special characters in values survive
local ov2 = { ['k'] = 'Ctrl+Alt+Shift+["]' }
check('special chars round-trip', same(C.deserialize(C.serialize(ov2)), ov2))

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All me_hotkey_config tests passed.')
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd tools/me-mod/test && lua test_hotkey_config.lua`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the config module**

Create `tools/me-mod/lua/dcs_sms_me/me_hotkey_config.lua`:

```lua
-- me_hotkey_config.lua — persistence of ME-Hotkey override deltas.
--
-- Stores ONLY the entries that differ from registry defaults (an action at
-- its default is absent), as a Lua file under Saved Games\DCS\dcs-sms\.
-- serialize/deserialize are pure (no IO) so they unit-test without disk; the
-- paths require is lazy (mirrors me_settings.lua) so this module loads in a
-- test VM without touching lfs.

local M = {}

-- Backend selection. The spike (research/me-hotkey-spike.md) may flip this to
-- 'global'; 'perkey' is correct when a re-registered key replaces ED's.
M.BACKEND_MODE = 'perkey'

-- ---- pure serialize / deserialize ----

function M.serialize(overrides)
    if type(overrides) ~= 'table' then overrides = {} end
    local keys = {}
    for k in pairs(overrides) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = { '-- DCS-SMS ME Hotkeys overrides (auto-generated; safe to delete).\nreturn {\n' }
    for _, k in ipairs(keys) do
        parts[#parts + 1] = string.format('    [%q] = %q,\n', k, tostring(overrides[k]))
    end
    parts[#parts + 1] = '}\n'
    return table.concat(parts)
end

function M.deserialize(s)
    if type(s) ~= 'string' then return {} end
    local f = (loadstring or load)(s)
    if not f then return {} end
    local ok, t = pcall(f)
    if not ok or type(t) ~= 'table' then return {} end
    local out = {}
    for k, v in pairs(t) do
        if type(k) == 'string' and type(v) == 'string' then out[k] = v end
    end
    return out
end

-- ---- IO (lazy paths/lfs) ----

M.PATH = nil
local function config_path()
    if not M.PATH then
        M.PATH = require('dcs_sms_me.paths').ROOT .. 'me_hotkeys.lua'
    end
    return M.PATH
end

function M.load()
    local f = loadfile(config_path())
    if not f then return {} end
    local ok, t = pcall(f)
    if not ok or type(t) ~= 'table' then return {} end
    local out = {}
    for k, v in pairs(t) do
        if type(k) == 'string' and type(v) == 'string' then out[k] = v end
    end
    return out
end

function M.save(overrides)
    local path = config_path()
    pcall(function() require('lfs').mkdir(require('dcs_sms_me.paths').ROOT) end)
    local fh, err = io.open(path, 'w')
    if not fh then
        if log and log.write then
            log.write('sms.me', log.ERROR, 'me_hotkey_config save failed: ' .. tostring(err))
        end
        return false
    end
    fh:write(M.serialize(overrides))
    fh:close()
    return true
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd tools/me-mod/test && lua test_hotkey_config.lua`
Expected: PASS, final line `All me_hotkey_config tests passed.`

- [ ] **Step 5: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/me_hotkey_config.lua tools/me-mod/test/test_hotkey_config.lua
git commit -m "feat(me-mod): add ME Hotkeys config persistence"
```

---

## Task 4: Engine (the core diff/state logic)

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/me_hotkey_engine.lua`
- Test: `tools/me-mod/test/test_hotkey_engine.lua`

- [ ] **Step 1: Write the failing test**

Create `tools/me-mod/test/test_hotkey_engine.lua`:

```lua
-- Standalone test for me_hotkey_engine.lua. Pure logic with an injected fake
-- backend that records attach/detach. No dxgui, no registry — a tiny fake
-- actions list exercises the three cases: keyless, native-default, override.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local E = require('dcs_sms_me.me_hotkey_engine')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function norm(k) if type(k) ~= 'string' then return nil end return k:lower() end

local function fake_backend()
    local live = {}   -- key -> token
    return {
        live = live,
        attach = function(key, fn) live[key] = fn; return { key = key } end,
        detach = function(key, token) live[key] = nil end,
        attached = function(key) return live[key] ~= nil end,
        count = function() local n = 0; for _ in pairs(live) do n = n + 1 end; return n end,
    }
end

local function fake_actions()
    return {
        { id='a1', label='A1', category='C', default_key='m', ed_key=nil, invoke=function() end }, -- keyless
        { id='a2', label='A2', category='C', default_key='a', ed_key='a', invoke=function() end }, -- native default
        { id='a3', label='A3', category='C', default_key='+', ed_key='+', invoke=function() end }, -- native default
    }
end

local function new_engine(overrides)
    local be = fake_backend()
    local eng = E.new({
        actions = fake_actions(), backend = be, overrides = overrides or {},
        ed_conflicts = { ['delete'] = 'Remove' }, normalize = norm,
    })
    return eng, be
end

-- apply: keyless attached, native-default NOT attached
do
    local eng, be = new_engine()
    eng:apply()
    check('keyless action attached on apply', be.attached('m'))
    check('native-default action a NOT attached', not be.attached('a'))
    check('native-default action + NOT attached', not be.attached('+'))
    check('only one attachment after apply', be.count() == 1)
end

-- is_modified / current_key / default_key
do
    local eng = new_engine()
    check('current_key defaults to default_key', eng:current_key('a2') == 'a')
    check('is_modified false at default', eng:is_modified('a2') == false)
end

-- override a native action: now attached at new key, modified true
do
    local eng, be = new_engine()
    eng:apply()
    eng:bind('a2', 'z')
    check('override native: new key attached', be.attached('z'))
    check('override native: ED key not attached', not be.attached('a'))
    check('override native: modified true', eng:is_modified('a2') == true)
    check('override native: current_key is z', eng:current_key('a2') == 'z')
end

-- reset restores default and detaches the override
do
    local eng, be = new_engine()
    eng:apply()
    eng:bind('a2', 'z')
    eng:reset('a2')
    check('reset: override key detached', not be.attached('z'))
    check('reset: modified false again', eng:is_modified('a2') == false)
end

-- bind to a key held by another managed action: moves it (prior holder unbound)
do
    local eng, be = new_engine()
    eng:apply()                 -- a1 at 'm'
    local r = eng:bind('a3', 'm')  -- take 'm' from a1
    check('move: new owner attached at m', be.attached('m'))
    check('move: prior holder a1 unbound', eng:current_key('a1') == nil)
    check('move: a1 now modified', eng:is_modified('a1') == true)
    check('move: displaced reported', r and r.displaced and r.displaced.id == 'a1')
end

-- bind to an ED-owned key reports the conflict label
do
    local eng = new_engine()
    local r = eng:bind('a1', 'delete')
    check('ed-conflict reported on bind', r and r.displaced and r.displaced.ed == 'Remove')
end

-- bind back to default clears the override (no delta)
do
    local eng = new_engine()
    eng:bind('a1', 'q')
    eng:bind('a1', 'm')   -- m is a1's default
    check('rebind to default clears override', eng:is_modified('a1') == false)
    check('overrides_delta empty after rebind-to-default', next(eng:overrides_delta()) == nil)
end

-- rows() reflects state in registry order
do
    local eng = new_engine()
    local rows = eng:rows()
    check('rows has one entry per action', #rows == 3)
    check('rows[1] is a1 with current m', rows[1].id == 'a1' and rows[1].current_key == 'm')
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All me_hotkey_engine tests passed.')
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd tools/me-mod/test && lua test_hotkey_engine.lua`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the engine**

Create `tools/me-mod/lua/dcs_sms_me/me_hotkey_engine.lua`:

```lua
-- me_hotkey_engine.lua — keymap merge + diff over an injected backend.
--
-- Pure logic: the backend ({ attach(key,fn)->token, detach(key,token) }) and
-- the actions list are injected, so this unit-tests with a fake backend.
--
-- Override states per action id:
--   absent           -> action is at its registry default_key
--   '<key>'          -> overridden to that key
--   ''  (empty)      -> explicitly unbound (no key)
--
-- Attachment rule (avoids double-firing ED's native keys): an action is
-- attached to the backend UNLESS its current key equals its ed_key (the
-- editor already handles that key natively). Keyless actions (ed_key=nil) and
-- overrides are always attached. Unbound actions are never attached.

local M = {}
local Engine = {}
Engine.__index = Engine

-- deps: { actions, backend, overrides, ed_conflicts, normalize }
function M.new(deps)
    local self = setmetatable({}, Engine)
    self._actions   = deps.actions or {}
    self._backend   = deps.backend
    self._ed        = deps.ed_conflicts or {}
    self._normalize = deps.normalize or function(k) return k end
    self._by_id     = {}
    for _, a in ipairs(self._actions) do self._by_id[a.id] = a end
    -- copy overrides so callers' tables aren't mutated
    self._overrides = {}
    for k, v in pairs(deps.overrides or {}) do self._overrides[k] = v end
    self._live = {}  -- id -> { key = <key>, token = <backend token> }
    return self
end

function Engine:_action(id) return self._by_id[id] end

-- current key string, or nil when unbound.
function Engine:current_key(id)
    local ov = self._overrides[id]
    if ov == '' then return nil end
    if ov ~= nil then return ov end
    local a = self:_action(id)
    return a and a.default_key or nil
end

function Engine:default_key(id)
    local a = self:_action(id)
    return a and a.default_key or nil
end

function Engine:is_modified(id)
    return self._normalize(self:current_key(id)) ~= self._normalize(self:default_key(id))
end

-- Which managed action currently holds `key` (normalized), or nil.
function Engine:key_holder(key)
    local nk = self._normalize(key)
    for _, a in ipairs(self._actions) do
        if self._normalize(self:current_key(a.id)) == nk then return a.id end
    end
    return nil
end

-- Should this action be attached to the backend right now?
function Engine:_should_attach(a)
    local cur = self:current_key(a.id)
    if cur == nil then return false end                       -- unbound
    if a.ed_key and self._normalize(cur) == self._normalize(a.ed_key) then
        return false                                          -- ED handles it
    end
    return true
end

-- Guarded closure for a backend attachment.
local function wrap(a)
    return function() pcall(a.invoke) end
end

-- Reconcile backend attachments with desired state.
function Engine:apply()
    if not self._backend then return end
    -- desired: id -> key
    local desired = {}
    for _, a in ipairs(self._actions) do
        if self:_should_attach(a) then desired[a.id] = self:current_key(a.id) end
    end
    -- detach anything live that is gone or changed
    for id, rec in pairs(self._live) do
        if desired[id] == nil or self._normalize(desired[id]) ~= self._normalize(rec.key) then
            pcall(function() self._backend.detach(rec.key, rec.token) end)
            self._live[id] = nil
        end
    end
    -- attach anything desired that isn't already live
    for id, key in pairs(desired) do
        if not self._live[id] then
            local a = self:_action(id)
            local token
            pcall(function() token = self._backend.attach(key, wrap(a)) end)
            self._live[id] = { key = key, token = token }
        end
    end
end

-- Set override (clearing it when the key equals the default), then re-apply.
-- Returns { displaced = { id=, label= } | { ed = label } | nil }.
function Engine:bind(id, key)
    local a = self:_action(id)
    if not a then return { displaced = nil } end
    local nk = self._normalize(key)

    -- find a managed holder to displace
    local displaced
    local holder = self:key_holder(key)
    if holder and holder ~= id then
        self._overrides[holder] = ''  -- unbind the prior holder
        local ha = self:_action(holder)
        displaced = { id = holder, label = ha and ha.label or holder }
    elseif self._ed[nk] then
        displaced = { ed = self._ed[nk] }
    end

    if nk == self._normalize(a.default_key) then
        self._overrides[id] = nil      -- back to default; no delta
    else
        self._overrides[id] = key
    end
    self:apply()
    return { displaced = displaced }
end

function Engine:unbind(id)
    self._overrides[id] = ''
    self:apply()
end

function Engine:reset(id)
    self._overrides[id] = nil
    self:apply()
end

function Engine:reset_all()
    self._overrides = {}
    self:apply()
end

-- UI model: one row per action in registry order.
function Engine:rows()
    local rows = {}
    for _, a in ipairs(self._actions) do
        rows[#rows + 1] = {
            id = a.id, label = a.label, category = a.category,
            current_key = self:current_key(a.id),
            default_key = a.default_key,
            modified = self:is_modified(a.id),
        }
    end
    return rows
end

-- The persistable delta: exactly self._overrides (only non-default entries,
-- by construction — bind clears the override when the key equals the default).
function Engine:overrides_delta()
    local out = {}
    for k, v in pairs(self._overrides) do out[k] = v end
    return out
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd tools/me-mod/test && lua test_hotkey_engine.lua`
Expected: PASS, final line `All me_hotkey_engine tests passed.`

- [ ] **Step 5: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/me_hotkey_engine.lua tools/me-mod/test/test_hotkey_engine.lua
git commit -m "feat(me-mod): add ME Hotkeys binding engine"
```

---

## Task 5: Backend (dxgui attach/detach + chord matching)

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/me_hotkey_backend.lua`
- Test: `tools/me-mod/test/test_hotkey_backend.lua`

- [ ] **Step 1: Write the failing test**

Create `tools/me-mod/test/test_hotkey_backend.lua`:

```lua
-- Standalone test for me_hotkey_backend.lua. Only the pure chord-matcher is
-- tested; attach/detach are dxgui-bound and verified by manual smoke. The
-- module's dxgui requires are pcall-guarded so it loads here.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
_G.log = _G.log or { write = function() end, INFO = 1, WARNING = 2, ERROR = 3 }
local B = require('dcs_sms_me.me_hotkey_backend')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- match_chord(state, keyName, keyState) tracks modifier hold-state and emits a
-- chord string on a non-modifier key DOWN. keyState: 'down' | 'up'.
local st = B.new_chord_state()
check('plain key down -> chord', B.match_chord(st, 'm', 'down') == 'm')
check('plain key up -> nil', B.match_chord(st, 'm', 'up') == nil)

-- modifier held then a letter -> Ctrl+<letter>
local st2 = B.new_chord_state()
B.match_chord(st2, 'LCtrl', 'down')
check('Ctrl held + d -> Ctrl+d', B.match_chord(st2, 'd', 'down') == 'Ctrl+d')
B.match_chord(st2, 'LCtrl', 'up')
check('Ctrl released, then d -> d', B.match_chord(st2, 'd', 'down') == 'd')

-- Ctrl+Shift order is canonical (Ctrl before Shift before Alt)
local st3 = B.new_chord_state()
B.match_chord(st3, 'LShift', 'down')
B.match_chord(st3, 'LCtrl', 'down')
check('Ctrl+Shift canonical order', B.match_chord(st3, 'r', 'down') == 'Ctrl+Shift+r')

-- a modifier key alone never produces a chord
local st4 = B.new_chord_state()
check('modifier down alone -> nil', B.match_chord(st4, 'LAlt', 'down') == nil)

check('get returns a backend with attach/detach', (function()
    local be = B.get('perkey'); return type(be) == 'table' and type(be.attach) == 'function' and type(be.detach) == 'function'
end)())

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All me_hotkey_backend tests passed.')
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd tools/me-mod/test && lua test_hotkey_backend.lua`
Expected: FAIL — module not found.

- [ ] **Step 3: Write the backend**

Create `tools/me-mod/lua/dcs_sms_me/me_hotkey_backend.lua`:

```lua
-- me_hotkey_backend.lua — the dxgui half of the hotkey engine.
--
-- Two interchangeable backends behind { attach(key,fn)->token, detach(key,token) }:
--   perkey  — attaches to the toolbar window via addHotKeyCallback (ED's own
--             ME-wide hotkey receiver). token = fn (needed by removeHotKeyCallback).
--   global  — a single Gui.AddKeyboardCallback dispatcher consulting an internal
--             key->fn map; tracks modifier hold-state and matches chords itself.
--
-- The pure chord matcher (new_chord_state / match_chord) is shared by the
-- global backend and the window's capture overlay, and is unit-tested.

local M = {}

-- ---- pure chord matcher ----

local MODIFIERS = {
    LCtrl = 'Ctrl', RCtrl = 'Ctrl', LShift = 'Shift', RShift = 'Shift', LAlt = 'Alt', RAlt = 'Alt',
}

function M.new_chord_state()
    return { Ctrl = false, Shift = false, Alt = false }
end

-- Feed one key event. Returns a chord string ('Ctrl+Shift+r', 'm', …) on a
-- non-modifier key DOWN, else nil. Modifier order is canonical: Ctrl, Shift, Alt.
function M.match_chord(state, keyName, keyState)
    local mod = MODIFIERS[keyName]
    if mod then
        state[mod] = (keyState == 'down')
        return nil
    end
    if keyState ~= 'down' then return nil end
    local prefix = ''
    if state.Ctrl  then prefix = prefix .. 'Ctrl+'  end
    if state.Shift then prefix = prefix .. 'Shift+' end
    if state.Alt   then prefix = prefix .. 'Alt+'   end
    return prefix .. keyName
end

-- ---- dxgui-bound backends (guarded so the module loads in the test VM) ----

local function toolbar_window()
    local w
    pcall(function() w = require('me_toolbar').window end)
    return w
end

local function make_perkey()
    return {
        attach = function(key, fn)
            local w = toolbar_window()
            if w and w.addHotKeyCallback then pcall(function() w:addHotKeyCallback(key, fn) end) end
            return fn  -- removeHotKeyCallback needs the original fn
        end,
        detach = function(key, token)
            local w = toolbar_window()
            if w and w.removeHotKeyCallback and token then
                pcall(function() w:removeHotKeyCallback(key, token) end)
            end
        end,
    }
end

local function make_global()
    local map = {}            -- normalized-chord -> fn
    local state = M.new_chord_state()
    local installed = false
    local function ensure_installed()
        if installed then return end
        pcall(function()
            local Gui = require('dxgui')
            if Gui and Gui.AddKeyboardCallback then
                Gui.AddKeyboardCallback(function(keyName, keyState)
                    local chord = M.match_chord(state, keyName, keyState)
                    if chord then
                        local fn = map[chord:lower()]
                        if fn then pcall(fn) end
                    end
                end)
                installed = true
            end
        end)
    end
    return {
        attach = function(key, fn) ensure_installed(); map[key:lower()] = fn; return key:lower() end,
        detach = function(key, token) map[(token or key):lower()] = nil end,
    }
end

function M.get(mode)
    if mode == 'global' then return make_global() end
    return make_perkey()
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd tools/me-mod/test && lua test_hotkey_backend.lua`
Expected: PASS, final line `All me_hotkey_backend tests passed.`

- [ ] **Step 5: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/me_hotkey_backend.lua tools/me-mod/test/test_hotkey_backend.lua
git commit -m "feat(me-mod): add ME Hotkeys backends (perkey + global)"
```

---

## Task 6: Window UI

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/me_hotkey_window.lua`

No unit test — this module requires dxgui widgets at the top (matching
`prefab_manager.lua`, which has no unit test for the same reason). It is
verified by the release-gate manual smoke (Task 8). Follow `prefab_manager.lua`'s
widget idioms exactly (`Static.new`/`Button.new` + `:setBounds` + `:setText` +
`try_skin` + `window:insertWidget` + `:addChangeCallback`).

- [ ] **Step 1: Write the window module**

Create `tools/me-mod/lua/dcs_sms_me/me_hotkey_window.lua`:

```lua
-- me_hotkey_window.lua — the ME Hotkeys tool window.
--
-- sms_window chrome + a Grid (Action | Binding | Reset). Categories render as
-- non-interactive group rows. Clicking a binding cell starts capture: a small
-- modal overlay that grabs the next chord via Gui.AddKeyboardCallback and the
-- shared match_chord matcher. The reset arrow shows only on modified rows.
--
-- Verified by manual smoke (docs/release-gate/me-mod-smoke.md), not unit tests.

local Static  = require('Static')
local Button  = require('Button')
local Window  = require('Window')
local Skin    = require('Skin')
local Gui     = require('dxgui')
local Grid;     do local ok, m = pcall(require, 'Grid');     if ok then Grid     = m end end

local sms_window = require('dcs_sms_me.sms_window')
local backend    = require('dcs_sms_me.me_hotkey_backend')
local facade     = require('dcs_sms_me.me_hotkeys')

local M = {}
local W = { sms_window = nil }

local ROW_H = 22

local function try_skin(widget, name)
    pcall(function()
        if widget and widget.setSkin and Skin and Skin[name] then widget:setSkin(Skin[name]()) end
    end)
end

-- Capture overlay: grab the next chord, then call on_done(chord) or on_cancel().
local function capture_chord(on_done, on_cancel)
    local screen_w, screen_h = 1920, 1080
    pcall(function() screen_w, screen_h = Gui.GetWindowSize() end)
    local w, h = 360, 120
    local overlay, cb
    local state = backend.new_chord_state()
    local function teardown()
        pcall(function() if cb and Gui.RemoveKeyboardCallback then Gui.RemoveKeyboardCallback(cb) end end)
        pcall(function() if overlay and overlay.setVisible then overlay:setVisible(false) end end)
    end
    pcall(function()
        overlay = Window.new((screen_w - w) / 2, (screen_h - h) / 2, w, h, 'Press a key…')
        overlay:setSkin((Skin.windowSkinME and Skin.windowSkinME()) or Skin.windowSkin())
        overlay:setVisible(true); overlay:setZOrder(260)
        local lbl = Static.new()
        lbl:setBounds(16, 16, w - 32, 40)
        lbl:setText('Press a key (or Esc to cancel)…')
        try_skin(lbl, 'staticSkin_ME')
        overlay:insertWidget(lbl)
        cb = function(keyName, keyState)
            if keyName == 'escape' and keyState == 'down' then
                teardown(); pcall(on_cancel or function() end); return
            end
            local chord = backend.match_chord(state, keyName, keyState)
            if chord then teardown(); pcall(function() on_done(chord) end) end
        end
        if Gui.AddKeyboardCallback then Gui.AddKeyboardCallback(cb) end
    end)
end

-- Rebuild the grid body from engine:rows().
local function refresh()
    if not (W.sms_window and W.grid) then return end
    local eng = facade.engine()
    local rows = eng:rows()
    pcall(function()
        if W.grid.removeAllRows then W.grid:removeAllRows() end
    end)
    -- Render: a category header line, then its actions. Grid is 0-indexed.
    local r = 0
    local last_cat
    for _, row in ipairs(rows) do
        if row.category ~= last_cat then
            pcall(function()
                W.grid:insertRow(); W.grid:setText(0, r, '— ' .. row.category .. ' —'); W.grid:setText(1, r, '')
            end)
            last_cat = row.category; r = r + 1
        end
        local key_text = row.current_key or '(unbound)'
        if row.modified then key_text = key_text .. '  ↩' end
        pcall(function()
            W.grid:insertRow(); W.grid:setText(0, r, row.label); W.grid:setText(1, r, key_text)
        end)
        W._row_action = W._row_action or {}
        W._row_action[r] = row.id
        r = r + 1
    end
end

-- Grid row click: capture a new chord for that row's action, or reset if the
-- modified arrow region was the intent (simplest: clicking a modified row's
-- binding opens a tiny choice via flash; here we capture, and a separate
-- "Reset all" footer button handles bulk reset; per-row reset = bind to default
-- by capturing — see README. For v1, single-click = capture, Ctrl+click = reset).
local function on_row_click(row_index, ctrl_held)
    local id = W._row_action and W._row_action[row_index]
    if not id then return end
    local eng = facade.engine()
    if ctrl_held then
        eng:reset(id); facade.persist(); refresh()
        W.sms_window:flash_status('Reset ' .. id, 'info'); return
    end
    capture_chord(function(chord)
        local res = eng:bind(id, chord); facade.persist(); refresh()
        local note = 'Bound ' .. id .. ' → ' .. chord
        if res.displaced and res.displaced.label then note = note .. ' (took it from ' .. res.displaced.label .. ')'
        elseif res.displaced and res.displaced.ed then note = note .. ' (ED: ' .. res.displaced.ed .. ')' end
        W.sms_window:flash_status(note, 'success')
    end, function() end)
end

local function build_body()
    local raw = W.sms_window:raw()
    local x, y, w, h = W.sms_window:get_content_bounds()
    if Grid then
        W.grid = Grid.new()
        pcall(function()
            W.grid:setColumns(2)
            W.grid:setColumnText(0, 'Action'); W.grid:setColumnText(1, 'Binding')
            W.grid:setColumnWidth(0, math.floor(w * 0.6)); W.grid:setColumnWidth(1, math.floor(w * 0.4))
        end)
        W.grid:setBounds(x, y, w, h - 40)
        pcall(function()
            if W.grid.addMouseDownCallback then
                W.grid:addMouseDownCallback(function() end)  -- placeholder; selection callback below
            end
            if W.grid.addChangeCallback then
                W.grid:addChangeCallback(function()
                    local sel = (W.grid.getSelectedRow and W.grid:getSelectedRow()) or -1
                    local ctrl = false
                    pcall(function() ctrl = Gui.isKeyPressed and Gui.isKeyPressed('LCtrl') end)
                    if sel and sel >= 0 then on_row_click(sel, ctrl) end
                end)
            end
        end)
        raw:insertWidget(W.grid)
    else
        local lbl = Static.new(); lbl:setBounds(x, y, w, 20)
        lbl:setText('Grid widget unavailable on this DCS build.')
        try_skin(lbl, 'staticSkin_ME'); raw:insertWidget(lbl)
    end

    W.reset_all_btn = Button.new()
    W.reset_all_btn:setBounds(x, y + h - 30, 120, 22)
    W.reset_all_btn:setText('Reset all')
    try_skin(W.reset_all_btn, 'dtc_button')
    W.reset_all_btn:addChangeCallback(function()
        facade.engine():reset_all(); facade.persist(); refresh()
        W.sms_window:flash_status('All hotkeys reset to defaults.', 'info')
    end)
    raw:insertWidget(W.reset_all_btn)
end

function M.show()
    if W.sms_window then W.sms_window:show(); refresh(); return end
    W.sms_window = sms_window.new({
        title = 'ME Hotkeys',
        size = { w = 460, h = 520 },
        min_size = { w = 380, h = 320 },
        persist_across_new_mission = true,  -- hotkeys aren't mission-bound
        disable_undo_hotkey = true,
    })
    if not W.sms_window then return end
    build_body()
    W.sms_window:show()
    W.sms_window:set_status('Click a binding to capture · Ctrl+click a row to reset', 'info')
    refresh()
end

function M.hide() if W.sms_window then W.sms_window:hide() end end
function M.toggle() if W.sms_window then W.sms_window:toggle(); refresh() else M.show() end end

return M
```

> **Implementer note:** the Grid method names (`setColumns`, `setColumnText`,
> `insertRow`, `setText(col,row,...)`, `getSelectedRow`, `addChangeCallback`)
> follow the prefab_manager Grid usage — verify each against
> `prefab_manager.lua` (search `Grid`) and the live `Grid` widget during smoke,
> adjusting names/`pcall` guards as needed. The grid is best-effort; every grid
> call is already `pcall`-wrapped so a method-name mismatch degrades to an empty
> grid rather than crashing the window.

- [ ] **Step 2: Verify the module loads without crashing the require chain**

Because this requires dxgui modules, run the smoke check inside DCS later. For
now, syntax-check with luac if available:

Run: `cd tools/me-mod/lua && luac -p dcs_sms_me/me_hotkey_window.lua` (if `luac` present; otherwise skip — the build step in Task 8 compiles it via the Go embed and the manual smoke exercises it).
Expected: no output (syntax OK).

- [ ] **Step 3: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/me_hotkey_window.lua
git commit -m "feat(me-mod): add ME Hotkeys tool window"
```

---

## Task 7: Facade + bootstrap/menu wiring

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/me_hotkeys.lua`
- Modify: `tools/me-mod/lua/dcs_sms_me/init.lua`
- Modify: `tools/me-mod/lua/dcs_sms_me/menu.lua`

- [ ] **Step 1: Write the facade**

Create `tools/me-mod/lua/dcs_sms_me/me_hotkeys.lua`:

```lua
-- me_hotkeys.lua — facade/singleton tying the ME-Hotkey layers together.
--
-- Builds one engine from the registry + saved overrides + selected backend,
-- applies it on bootstrap, and exposes toggle_window() for the menu. Pure
-- delegation; no dxgui at load (the window is required lazily on toggle).

local actions    = require('dcs_sms_me.me_hotkey_actions')
local config      = require('dcs_sms_me.me_hotkey_config')
local engine_mod  = require('dcs_sms_me.me_hotkey_engine')
local backend_mod = require('dcs_sms_me.me_hotkey_backend')

local M = {}
local _engine

local function build()
    return engine_mod.new({
        actions      = actions.list(),
        backend      = backend_mod.get(config.BACKEND_MODE),
        overrides    = config.load(),
        ed_conflicts = actions.ED_CONFLICTS,
        normalize    = actions.normalize_key,
    })
end

function M.engine()
    if not _engine then _engine = build() end
    return _engine
end

-- Called from init.lua on bootstrap (and on dev-reload). Rebuilds the engine
-- from disk and attaches the bindings. Note: on dev-reload the previous
-- generation's attachments persist on the toolbar window (perkey backend can't
-- recover lost tokens), so a double-attach is possible until a full DCS
-- restart — acceptable per the spec (bootstrap-level changes may need restart).
function M.install()
    local ok, err = pcall(function()
        _engine = build()
        _engine:apply()
    end)
    if ok then
        log.write('sms.me', log.INFO, 'ME Hotkeys installed')
    else
        log.write('sms.me', log.ERROR, 'ME Hotkeys install failed: ' .. tostring(err))
    end
end

function M.persist()
    pcall(function() config.save(M.engine():overrides_delta()) end)
end

function M.toggle_window()
    local ok, err = pcall(function() require('dcs_sms_me.me_hotkey_window').toggle() end)
    if not ok then log.write('sms.me', log.ERROR, 'ME Hotkeys window failed: ' .. tostring(err)) end
end

return M
```

- [ ] **Step 2: Wire bootstrap into init.lua**

In `tools/me-mod/lua/dcs_sms_me/init.lua`, add the hotkeys install after the
bridge install. Replace this block:

```lua
    local bridge = require('dcs_sms_me.bridge')
    bridge.install()
end)
```

with:

```lua
    local bridge = require('dcs_sms_me.bridge')
    bridge.install()

    -- Install custom ME hotkeys: load saved overrides, attach bindings to the
    -- toolbar window. Independent of any tool window.
    local me_hotkeys = require('dcs_sms_me.me_hotkeys')
    me_hotkeys.install()
end)
```

- [ ] **Step 3: Add the menu entry in menu.lua**

In `tools/me-mod/lua/dcs_sms_me/menu.lua`, add a "Hotkeys" item after the Mass
Edit block. Insert the following immediately after the `else ... end` that
closes the Mass Edit item (right before the `-- Sibling "About" menu entry.`
comment near line 132):

```lua
    -- "Hotkeys" entry — opens the ME Hotkeys binding window.
    local hotkeys_item
    local ok_hk, hk_err = pcall(function() hotkeys_item = menu:newItem('Hotkeys') end)
    if ok_hk and hotkeys_item then
        pcall(function()
            local sibling_item = sibling_menu
                and (sibling_menu.missionOptions or sibling_menu.mapOptions
                     or sibling_menu.setPosition  or sibling_menu.logbook)
            if sibling_item and sibling_item.getSkin and hotkeys_item.setSkin then
                hotkeys_item:setSkin(sibling_item:getSkin())
            end
        end)
        hotkeys_item.func = function()
            local ok2, err = pcall(function() require('dcs_sms_me.me_hotkeys').toggle_window() end)
            if not ok2 then
                log.write('sms.me', log.ERROR, 'Hotkeys toggle failed: ' .. tostring(err))
            end
        end
    else
        log.write('sms.me', log.ERROR, 'Hotkeys menu:newItem failed: ' .. tostring(hk_err))
    end

```

- [ ] **Step 4: Run the full Lua test suite (no regressions)**

Run: `cd tools/me-mod/test && pwsh -File run-tests.ps1`
Expected: all existing tests still PASS; the four new hotkey tests are not yet
registered (Task 8 adds them) but the modified `init.lua`/`menu.lua` aren't unit-tested, so the suite is green.

- [ ] **Step 5: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/me_hotkeys.lua tools/me-mod/lua/dcs_sms_me/init.lua tools/me-mod/lua/dcs_sms_me/menu.lua
git commit -m "feat(me-mod): wire ME Hotkeys into bootstrap + DCS-SMS menu"
```

---

## Task 8: Register tests, docs, version bump, build

**Files:**
- Modify: `tools/me-mod/test/run-tests.ps1`
- Modify: `tools/me-mod/lua/dcs_sms_me/version.lua`
- Modify: `CHANGELOG.md`
- Modify: `tools/me-mod/README.md`
- Modify: `docs/release-gate/me-mod-smoke.md`
- Modify: `tools/me-mod/AGENTS.md`

- [ ] **Step 1: Register the new tests**

In `tools/me-mod/test/run-tests.ps1`, in the `$tests = @(...)` array, add the
four new files in alphabetical position (right after `'test_group_name_writer.lua',`):

```powershell
    'test_group_name_writer.lua', 'test_hotkey_actions.lua', 'test_hotkey_backend.lua', 'test_hotkey_config.lua', 'test_hotkey_engine.lua', 'test_marquee_hook.lua',
```

(Replace the existing `'test_group_name_writer.lua', 'test_marquee_hook.lua',`
segment with the line above — i.e. insert the four entries between them.)

- [ ] **Step 2: Run the full suite to confirm all green**

Run: `cd tools/me-mod/test && pwsh -File run-tests.ps1`
Expected: every test PASSES, including the four `test_hotkey_*` files; exit code 0.

- [ ] **Step 3: Bump the version (minor)**

Read `tools/me-mod/lua/dcs_sms_me/version.lua` to get the current value, then
increment the minor and zero the patch (e.g. `0.17.0` → `0.18.0`). Edit the
single version string accordingly.

- [ ] **Step 4: Update CHANGELOG.md**

Add a new entry at the top of the ME-mod section of `CHANGELOG.md` (match the
existing newest-on-top format):

```markdown
### ME-mod v0.18.0

- **feat(me-mod): ME Hotkeys tool** — a new DCS-SMS → Hotkeys window to assign
  keyboard shortcuts to native Mission-Editor actions (Multi Select, object-add
  tools, panel toggles). Single-letter defaults for keyless actions, native ED
  keys kept as defaults, Unreal-style reset-to-default arrow, persisted across
  sessions. Override behaviour depends on the live-ME spike
  (`research/me-hotkey-spike.md`); ships with the `perkey` backend.
```

(Use the version you set in Step 3 if it differs from `0.18.0`.)

- [ ] **Step 5: Document the tool in the ME-mod README**

In `tools/me-mod/README.md`, add a short section describing the Hotkeys tool
(find the Prefab Manager / Mass Edit section and add a sibling):

```markdown
### ME Hotkeys

**DCS-SMS → Hotkeys** opens a window listing native Mission-Editor actions
grouped by category (Map/Selection, Object-add, Panel toggles). Click a row's
binding to capture a new key; Ctrl+click a row to reset it to its default. A
reset arrow (↩) marks any binding changed from its default. Bindings persist
across sessions in `Saved Games\DCS\dcs-sms\me_hotkeys.lua`.

Defaults use single letters where free (e.g. `m` Multi Select, `d` Draw); native
actions keep their existing editor keys.
```

- [ ] **Step 6: Add release-gate smoke items (incl. the spike)**

In `docs/release-gate/me-mod-smoke.md`, add a "ME Hotkeys" checklist section:

```markdown
## ME Hotkeys

- [ ] DCS-SMS → Hotkeys opens the window; rows are grouped by category.
- [ ] Press `m` in the ME (no field focused) → Multi Select activates.
- [ ] Open a unit name field, type a word containing `m` → it types normally
      (does NOT trigger Multi Select). [spike Q4 — make-or-break]
- [ ] Click a binding, press a new key → the row updates and the reset arrow (↩) appears.
- [ ] Re-assign a key already used by another row → it moves; the old row shows (unbound).
- [ ] Ctrl+click a modified row → it resets to default; arrow disappears.
- [ ] Reset all → every row returns to its default.
- [ ] Restart the ME → bindings persist (overrides reloaded from disk).
- [ ] Spike (research/me-hotkey-spike.md): confirm Q1/Q4; if override stacks
      instead of replacing, set BACKEND_MODE = 'global' and re-test.
```

- [ ] **Step 7: Update the AGENTS.md file-layout table**

In `tools/me-mod/AGENTS.md` §2.2 (the File / Role table), add rows for the new
modules (place after the `sms_window.lua` row):

```markdown
| `me_hotkeys.lua` | Facade/singleton for the ME Hotkeys tool — builds the engine from registry + saved overrides + backend, applies bindings on bootstrap, exposes `toggle_window()`. |
| `me_hotkey_actions.lua` | Bindable-action registry: id/label/category/default_key/ed_key + lazy `invoke` thunks + the ED-native conflict map. |
| `me_hotkey_config.lua` | Override-delta persistence (`me_hotkeys.lua` file under the dcs-sms root) + `BACKEND_MODE`. |
| `me_hotkey_engine.lua` | Pure keymap diff/state engine (bind/unbind/reset/modified/rows/apply) over an injected backend. |
| `me_hotkey_backend.lua` | dxgui attach/detach backends (`perkey` toolbar-window hotkeys, `global` keyboard chokepoint) + the pure chord matcher. |
| `me_hotkey_window.lua` | The ME Hotkeys window (sms_window + grid + capture overlay + reset arrows). |
```

- [ ] **Step 8: Rebuild the binary to confirm the embed compiles**

Run: `cd tools && go build -o dcs-sms.exe ./cmd/dcs-sms`
Expected: exit 0 (the new Lua files are embedded; a Lua syntax error would not
fail the Go build, but this confirms the tree is wired — the Lua tests in
Step 2 are the real syntax gate).

- [ ] **Step 9: Commit**

```bash
git add tools/me-mod/test/run-tests.ps1 tools/me-mod/lua/dcs_sms_me/version.lua CHANGELOG.md tools/me-mod/README.md docs/release-gate/me-mod-smoke.md tools/me-mod/AGENTS.md
git commit -m "docs(me-mod): register ME Hotkeys tests, bump version, update docs"
```

---

## Done criteria

- All four `test_hotkey_*` tests pass via `run-tests.ps1` alongside the existing suite.
- `go build ./cmd/dcs-sms` succeeds.
- `DCS-SMS → Hotkeys` menu entry exists and the window opens (manual smoke).
- The spike note exists for the user to run on the live ME and flip `BACKEND_MODE` if needed.
- Version bumped (minor), CHANGELOG/README/AGENTS/release-gate updated.

**Stop here.** The user tests in the live ME, then runs `/bring-it-home`.
