# ME Hotkeys — User Scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users write named Lua snippets and bind each to a hotkey (Maya-style), surfaced as rows in the existing ME Hotkeys window with a dedicated editor dialog.

**Architecture:** Scripts persist to their own `me_scripts.lua` (separate from built-in key overrides). A new `me_hotkey_scripts` module does CRUD + serialize + compile + `to_actions()`; the facade merges those dynamic actions into the engine. A new `me_hotkey_script_editor` window creates/edits them. The chord-capture overlay is extracted to a shared `me_hotkey_capture` module so both the main window and the editor reuse it.

**Tech Stack:** Lua 5.1 (DCS ME GUI state), dxgui widgets (`sms_window`, `EditBox` with `setMultiline`, `Button`, `Static`), `loadstring`+`pcall` execution. Tests run via `tools/me-mod/test/run-tests.ps1` (standalone Lua 5.1).

**Spec:** [`docs/superpowers/specs/2026-06-05-me-hotkey-user-scripts-design.md`](../specs/2026-06-05-me-hotkey-user-scripts-design.md)

## File structure

| File | Status | Responsibility |
|---|---|---|
| `tools/me-mod/lua/dcs_sms_me/me_hotkey_capture.lua` | create | Shared "press a key" chord-capture overlay (extracted from the window). |
| `tools/me-mod/lua/dcs_sms_me/me_hotkey_scripts.lua` | create | Script persistence + CRUD + serialize/deserialize + compile + `to_actions()`. |
| `tools/me-mod/lua/dcs_sms_me/me_hotkey_script_editor.lua` | create | The editor window (name / hotkey / multiline code / Run / Save / Delete). |
| `tools/me-mod/test/test_hotkey_scripts.lua` | create | Standalone test for the scripts module. |
| `tools/me-mod/lua/dcs_sms_me/me_hotkey_actions.lua` | modify | Add `'Scripts'` to `M.CATEGORIES`. |
| `tools/me-mod/lua/dcs_sms_me/me_hotkey_engine.lua` | modify | Empty-string key = unbound; pass `script` flag through `rows()`. |
| `tools/me-mod/lua/dcs_sms_me/me_hotkeys.lua` | modify | Merge scripts into the engine; `scripts_changed()`; `open_script_editor()`. |
| `tools/me-mod/lua/dcs_sms_me/me_hotkey_window.lua` | modify | Use shared capture module; Scripts category render; `+ New Script`; double-click routing; `refresh()`. |
| `tools/me-mod/test/test_hotkey_engine.lua` | modify | Empty-key-is-unbound case. |
| `tools/me-mod/test/run-tests.ps1` | modify | Register `test_hotkey_scripts.lua`. |
| `tools/me-mod/lua/dcs_sms_me/version.lua` + docs | modify | Version bump + doc sync. |

**Dependency / parallelism note for the executor:** Task 1 and Task 5 both edit `me_hotkey_window.lua` — run Task 1 first. Tasks 1, 2, 3 touch disjoint files (window vs scripts/actions/runtests vs engine) and may run in parallel. Task 4 needs Task 2. Tasks 5 (window) and 6 (editor) and 7 (docs) touch disjoint files and may run in parallel after Task 4 (Task 5 also needs Task 1 done). Task 8 is last.

---

## Task 1: Extract the chord-capture overlay into a shared module

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/me_hotkey_capture.lua`
- Modify: `tools/me-mod/lua/dcs_sms_me/me_hotkey_window.lua`

- [ ] **Step 1: Create the capture module**

Create `tools/me-mod/lua/dcs_sms_me/me_hotkey_capture.lua`:

```lua
-- me_hotkey_capture.lua — the "press a key" chord-capture overlay, shared by the
-- ME Hotkeys window (rebinding a built-in action) and the script editor (its
-- hotkey field). Grabs the next chord via Gui.AddKeyboardCallback + the backend's
-- pure match_chord, then calls on_done(chord) or on_cancel().
--
-- A single capture is active at a time; M.teardown() force-closes a dangling
-- overlay (e.g. its host window was hidden mid-capture).

local Static; do local ok, m = pcall(require, 'Static'); if ok then Static = m end end
local Window; do local ok, m = pcall(require, 'Window'); if ok then Window = m end end
local Skin;   do local ok, m = pcall(require, 'Skin');   if ok then Skin   = m end end
local Gui;    do local ok, m = pcall(require, 'dxgui');  if ok then Gui    = m end end

local backend = require('dcs_sms_me.me_hotkey_backend')

local M = {}
M._teardown = nil

function M.capture(on_done, on_cancel)
    local screen_w, screen_h = 1920, 1080
    pcall(function() screen_w, screen_h = Gui.GetWindowSize() end)
    local w, h = 360, 120
    local overlay, cb
    local state = backend.new_chord_state()
    local done = false
    local function teardown()
        if done then return end
        done = true
        M._teardown = nil
        pcall(function() if cb and Gui and Gui.RemoveKeyboardCallback then Gui.RemoveKeyboardCallback(cb) end end)
        pcall(function() if overlay and overlay.setVisible then overlay:setVisible(false) end end)
    end
    M._teardown = teardown
    pcall(function()
        overlay = Window.new((screen_w - w) / 2, (screen_h - h) / 2, w, h, 'Press a key…')
        overlay:setSkin((Skin.windowSkinME and Skin.windowSkinME()) or Skin.windowSkin())
        overlay:setVisible(true); overlay:setZOrder(260)
        pcall(function() overlay.onClose = function() teardown(); pcall(on_cancel or function() end) end end)
        local lbl = Static.new()
        lbl:setBounds(16, 16, w - 32, 40)
        lbl:setText('Press a key (or Esc to cancel)…')
        pcall(function() if Skin and Skin.staticSkin_ME then lbl:setSkin(Skin.staticSkin_ME()) end end)
        overlay:insertWidget(lbl)
        cb = function(keyName, keyState)
            if keyName == 'escape' and keyState == 'down' then
                teardown(); pcall(on_cancel or function() end); return
            end
            local chord = backend.match_chord(state, keyName, keyState)
            if chord then teardown(); pcall(function() on_done(chord) end) end
        end
        if Gui and Gui.AddKeyboardCallback then Gui.AddKeyboardCallback(cb) end
    end)
end

-- Force-close any active capture overlay (no-op if none).
function M.teardown()
    if M._teardown then pcall(M._teardown) end
end

return M
```

- [ ] **Step 2: Point the window at the shared module**

In `tools/me-mod/lua/dcs_sms_me/me_hotkey_window.lua`, add the require alongside the other `dcs_sms_me` requires (just after `local actions = require('dcs_sms_me.me_hotkey_actions')` and the `clearable_edit` require):

```lua
local capture       = require('dcs_sms_me.me_hotkey_capture')
```

Delete the entire local `capture_chord` function (the block starting `-- ---- capture overlay: grab the next chord, then on_done(chord)/on_cancel() ----` through its closing `end`). Then in `start_capture`, replace the call `capture_chord(function(chord) … end, function() set_hint() end)` so it calls the shared module — the body is unchanged, only the function name:

```lua
    capture.capture(function(chord)
        local res = e:bind(id, chord)
        pcall(function() facade().persist() end)
        render()
        local r = rows_by_id()[id]
        local note = 'Bound ' .. (r and r.label or id) .. ' → ' .. disp_key(chord)
        if res and res.displaced and res.displaced.label then
            note = note .. ' (took it from ' .. res.displaced.label .. ')'
        elseif res and res.displaced and res.displaced.ed then
            note = note .. ' (ED: ' .. res.displaced.ed .. ')'
        end
        W.sms_window:flash_status(note, 'success')
    end, function() set_hint() end)
```

Replace the two `if W._capture_teardown then pcall(W._capture_teardown) end` lines (in `M.show` and `M.hide`) with:

```lua
    capture.teardown()
```

- [ ] **Step 3: Verify the existing suite still passes (the window isn't unit-tested, but nothing else should break)**

Run: `cd tools/me-mod/test && pwsh -File run-tests.ps1`
Expected: all existing tests pass (the four `test_hotkey_*` plus the rest). The window/capture aren't unit-tested; this confirms no require-chain breakage.

- [ ] **Step 4: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/me_hotkey_capture.lua tools/me-mod/lua/dcs_sms_me/me_hotkey_window.lua
git commit -m "refactor(me-mod): extract ME Hotkeys chord-capture overlay into shared module"
```

---

## Task 2: Scripts module (CRUD / persistence / compile / to_actions)

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/me_hotkey_scripts.lua`
- Modify: `tools/me-mod/lua/dcs_sms_me/me_hotkey_actions.lua`
- Test: `tools/me-mod/test/test_hotkey_scripts.lua`
- Modify: `tools/me-mod/test/run-tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tools/me-mod/test/test_hotkey_scripts.lua`:

```lua
-- Standalone test for me_hotkey_scripts.lua. Pure serialize/CRUD/compile/to_actions;
-- the paths/lfs requires are lazy so the module loads without disk.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
_G.log = _G.log or { write = function() end, INFO = 1, WARNING = 2, ERROR = 3 }
local S = require('dcs_sms_me.me_hotkey_scripts')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function same_script(a, b)
    return a.id == b.id and a.name == b.name and a.key == b.key and a.code == b.code
end

-- round-trip including quotes + newlines in code
local list = {
    { id = 'script.1', name = 'Hi "there"', key = 'Ctrl+Shift+1', code = 'local x = "a"\nreturn x' },
    { id = 'script.2', name = 'No key',      key = '',             code = 'return 1' },
}
local round = S.deserialize(S.serialize(list))
check('round-trip count', #round == 2)
check('round-trip script 1 identity', round[1] and same_script(round[1], list[1]))
check('round-trip preserves empty key', round[2] and round[2].key == '')

-- malformed input
check('deserialize non-string -> {}', #S.deserialize(nil) == 0)
check('deserialize garbage -> {}', #S.deserialize('this is not lua {{{') == 0)
check('deserialize non-table -> {}', #S.deserialize('return 42') == 0)
check('deserialize drops entries without id', #S.deserialize('return { { name = "x" } }') == 0)

-- next_id
check('next_id of empty is script.1', S.next_id({}) == 'script.1')
check('next_id of {1,2} is script.3', S.next_id(list) == 'script.3')
check('next_id ignores non-numeric ids', S.next_id({ { id = 'script.foo' } }) == 'script.1')

-- add assigns fresh id, does not mutate input
local base = {}
local added, new_id = S.add(base, { name = 'A', key = 'm', code = 'return 0' })
check('add returns new id', new_id == 'script.1')
check('add appended one', #added == 1 and added[1].name == 'A')
check('add did not mutate input', #base == 0)

-- update by id
local updated = S.update(added, 'script.1', { name = 'A2', key = 'n' })
check('update mutates name', S.get(updated, 'script.1').name == 'A2')
check('update mutates key', S.get(updated, 'script.1').key == 'n')
check('update keeps code when not given', S.get(updated, 'script.1').code == 'return 0')

-- remove by id
local removed = S.remove(updated, 'script.1')
check('remove drops the script', #removed == 0)
check('remove left input intact', #updated == 1)

-- compile
check('compile valid lua', S.compile('return 1 + 1') == true)
local ok_c, err_c = S.compile('this is not lua ===')
check('compile bad lua returns false', ok_c == false)
check('compile bad lua returns error string', type(err_c) == 'string')

-- to_actions
local acts = S.to_actions(list)
check('to_actions one per script', #acts == 2)
check('to_actions category is Scripts', acts[1].category == 'Scripts')
check('to_actions sets script flag', acts[1].script == true)
check('to_actions default_key is the key', acts[1].default_key == 'Ctrl+Shift+1')
check('to_actions invoke is a function', type(acts[1].invoke) == 'function')
check('to_actions label falls back to id when name empty',
      S.to_actions({ { id = 'script.9', name = '', key = '', code = '' } })[1].label == 'script.9')

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All me_hotkey_scripts tests passed.')
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd tools/me-mod/test && lua test_hotkey_scripts.lua` (or via `run-tests.ps1`)
Expected: FAIL — `module 'dcs_sms_me.me_hotkey_scripts' not found`.

- [ ] **Step 3: Write the scripts module**

Create `tools/me-mod/lua/dcs_sms_me/me_hotkey_scripts.lua`:

```lua
-- me_hotkey_scripts.lua — persistence + CRUD for user-defined hotkey scripts.
--
-- A script is { id, name, key, code }. Stored as a Lua list under
-- Saved Games\DCS\dcs-sms\me_scripts.lua, separate from the built-in key-override
-- file (me_hotkeys.lua). serialize/deserialize/CRUD/compile are pure (no IO) so
-- they unit-test without disk; the paths/lfs requires are lazy (mirrors
-- me_hotkey_config.lua) so this module loads in a test VM.

local M = {}

-- ---- pure serialize / deserialize ----

function M.serialize(scripts)
    if type(scripts) ~= 'table' then scripts = {} end
    local parts = { '-- DCS-SMS ME Hotkey user scripts (auto-generated; safe to delete).\nreturn {\n' }
    for _, s in ipairs(scripts) do
        if type(s) == 'table' and type(s.id) == 'string' and s.id ~= '' then
            parts[#parts + 1] = string.format(
                '    { id = %q, name = %q, key = %q, code = %q },\n',
                s.id, tostring(s.name or ''), tostring(s.key or ''), tostring(s.code or ''))
        end
    end
    parts[#parts + 1] = '}\n'
    return table.concat(parts)
end

-- Validate + clean one decoded table into a script, or nil if malformed.
local function clean_one(s)
    if type(s) ~= 'table' or type(s.id) ~= 'string' or s.id == '' then return nil end
    return {
        id   = s.id,
        name = type(s.name) == 'string' and s.name or '',
        key  = type(s.key)  == 'string' and s.key  or '',
        code = type(s.code) == 'string' and s.code or '',
    }
end

local function clean_list(t)
    local out = {}
    if type(t) == 'table' then
        for _, s in ipairs(t) do
            local c = clean_one(s)
            if c then out[#out + 1] = c end
        end
    end
    return out
end

function M.deserialize(str)
    if type(str) ~= 'string' then return {} end
    local f = (loadstring or load)(str)
    if not f then return {} end
    local ok, t = pcall(f)
    if not ok then return {} end
    return clean_list(t)
end

-- ---- ids ----

function M.next_id(scripts)
    local max = 0
    for _, s in ipairs(scripts or {}) do
        local n = tostring(s.id or ''):match('^script%.(%d+)$')
        if n then n = tonumber(n); if n and n > max then max = n end end
    end
    return 'script.' .. (max + 1)
end

-- ---- pure CRUD (returns a fresh list; never mutates input) ----

local function copy_list(scripts)
    local out = {}
    for _, s in ipairs(scripts or {}) do
        out[#out + 1] = { id = s.id, name = s.name, key = s.key, code = s.code }
    end
    return out
end

function M.add(scripts, fields)
    local list = copy_list(scripts)
    local id = M.next_id(list)
    list[#list + 1] = {
        id = id,
        name = tostring((fields and fields.name) or ''),
        key  = tostring((fields and fields.key)  or ''),
        code = tostring((fields and fields.code) or ''),
    }
    return list, id
end

function M.update(scripts, id, fields)
    local list = copy_list(scripts)
    fields = fields or {}
    for _, s in ipairs(list) do
        if s.id == id then
            if fields.name ~= nil then s.name = tostring(fields.name) end
            if fields.key  ~= nil then s.key  = tostring(fields.key)  end
            if fields.code ~= nil then s.code = tostring(fields.code) end
            break
        end
    end
    return list
end

function M.remove(scripts, id)
    local list = {}
    for _, s in ipairs(scripts or {}) do
        if s.id ~= id then list[#list + 1] = { id = s.id, name = s.name, key = s.key, code = s.code } end
    end
    return list
end

function M.get(scripts, id)
    for _, s in ipairs(scripts or {}) do if s.id == id then return s end end
    return nil
end

-- ---- compile ----

-- Returns true on success, or (false, errmsg) on a syntax error.
function M.compile(code)
    local f, err = (loadstring or load)(tostring(code or ''))
    if f then return true end
    return false, tostring(err)
end

-- ---- script -> engine action ----

-- Invoke thunk: compile + pcall the code at fire time, logging any error so a
-- broken script never aborts the ME.
local function make_invoke(name, code)
    return function()
        local f, err = (loadstring or load)(tostring(code or ''))
        if not f then
            if log and log.write then
                log.write('sms.me.script', log.ERROR, 'script "' .. tostring(name) .. '" compile error: ' .. tostring(err))
            end
            return
        end
        local ok, rerr = pcall(f)
        if not ok and log and log.write then
            log.write('sms.me.script', log.ERROR, 'script "' .. tostring(name) .. '" runtime error: ' .. tostring(rerr))
        end
    end
end

function M.to_actions(scripts)
    local actions = {}
    for _, s in ipairs(scripts or {}) do
        actions[#actions + 1] = {
            id = s.id,
            label = (s.name ~= nil and s.name ~= '') and s.name or s.id,
            category = 'Scripts',
            default_key = s.key or '',
            ed_key = nil,
            script = true,
            invoke = make_invoke(s.name, s.code),
        }
    end
    return actions
end

-- ---- IO (lazy paths/lfs) ----

M.PATH = nil
local function config_path()
    if not M.PATH then
        M.PATH = require('dcs_sms_me.paths').ROOT .. 'me_scripts.lua'
    end
    return M.PATH
end

function M.load()
    local f = loadfile(config_path())
    if not f then return {} end
    local ok, t = pcall(f)
    if not ok then return {} end
    return clean_list(t)
end

function M.save(scripts)
    local path = config_path()
    pcall(function() require('lfs').mkdir(require('dcs_sms_me.paths').ROOT) end)
    local fh, err = io.open(path, 'w')
    if not fh then
        if log and log.write then
            log.write('sms.me', log.ERROR, 'me_hotkey_scripts save failed: ' .. tostring(err))
        end
        return false
    end
    fh:write(M.serialize(scripts))
    fh:close()
    return true
end

return M
```

- [ ] **Step 4: Add `'Scripts'` to the category list**

In `tools/me-mod/lua/dcs_sms_me/me_hotkey_actions.lua`, change the `M.CATEGORIES` table to insert `'Scripts'` right after `'DCS-SMS'`:

```lua
M.CATEGORIES = {
    'DCS-SMS', 'Scripts',
    'Map/Selection', 'Object-add', 'Panel',
    'File', 'Edit', 'View', 'Flight', 'Campaign', 'Dynamic Mission', 'Misc',
}
```

- [ ] **Step 5: Register the new test**

In `tools/me-mod/test/run-tests.ps1`, find the `$tests = @(...)` array and add `'test_hotkey_scripts.lua',` immediately after `'test_hotkey_engine.lua',`.

- [ ] **Step 6: Run the suite to confirm green**

Run: `cd tools/me-mod/test && pwsh -File run-tests.ps1`
Expected: every test passes, including `All me_hotkey_scripts tests passed.`

- [ ] **Step 7: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/me_hotkey_scripts.lua tools/me-mod/lua/dcs_sms_me/me_hotkey_actions.lua tools/me-mod/test/test_hotkey_scripts.lua tools/me-mod/test/run-tests.ps1
git commit -m "feat(me-mod): add ME Hotkeys user-scripts persistence + CRUD module"
```

---

## Task 3: Engine — empty key = unbound + pass the `script` flag

**Files:**
- Modify: `tools/me-mod/lua/dcs_sms_me/me_hotkey_engine.lua`
- Test: `tools/me-mod/test/test_hotkey_engine.lua`

- [ ] **Step 1: Add the failing test**

In `tools/me-mod/test/test_hotkey_engine.lua`, add this block immediately before the final `if failures > 0 then` line:

```lua
-- empty default_key is treated as unbound (used by keyless user scripts)
do
    local be = fake_backend()
    local eng = E.new({
        actions = {
            { id='sx', label='ScriptX', category='Scripts', default_key='', ed_key=nil, script=true, invoke=function() end },
        },
        backend = be, overrides = {}, ed_conflicts = {}, normalize = norm,
    })
    eng:apply()
    check('empty default_key -> current_key nil', eng:current_key('sx') == nil)
    check('empty default_key -> not modified', eng:is_modified('sx') == false)
    check('empty default_key -> nothing attached', be.count() == 0)
    local rows = eng:rows()
    check('rows pass through script flag', rows[1].script == true)
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd tools/me-mod/test && lua test_hotkey_engine.lua`
Expected: FAIL — `current_key` returns `''` (not nil) and `rows[1].script` is nil.

- [ ] **Step 3: Implement empty-key handling + script passthrough**

In `tools/me-mod/lua/dcs_sms_me/me_hotkey_engine.lua`, replace the `current_key` and `default_key` functions with:

```lua
-- current key string, or nil when unbound. A disabled action reports no key.
-- An empty-string key (used by keyless user scripts) is also treated as unbound.
function Engine:current_key(id)
    local a = self:_action(id)
    if a and a.disabled then return nil end
    local ov = self._overrides[id]
    if ov == '' then return nil end
    if ov ~= nil then return ov end
    local dk = a and a.default_key
    if dk == nil or dk == '' then return nil end
    return dk
end

function Engine:default_key(id)
    local a = self:_action(id)
    if a and a.disabled then return nil end
    local dk = a and a.default_key
    if dk == nil or dk == '' then return nil end
    return dk
end
```

Then in `Engine:rows()`, add the `script` field to each row table (alongside `disabled`):

```lua
            disabled = a.disabled or false,
            script = a.script or false,
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd tools/me-mod/test && lua test_hotkey_engine.lua`
Expected: PASS, `All me_hotkey_engine tests passed.`

- [ ] **Step 5: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/me_hotkey_engine.lua tools/me-mod/test/test_hotkey_engine.lua
git commit -m "feat(me-mod): treat empty hotkey as unbound + pass script flag through engine rows"
```

---

## Task 4: Facade — merge scripts into the engine + editor entry points

**Files:**
- Modify: `tools/me-mod/lua/dcs_sms_me/me_hotkeys.lua`

(Depends on Task 2's `me_hotkey_scripts` module.)

- [ ] **Step 1: Require the scripts module**

In `tools/me-mod/lua/dcs_sms_me/me_hotkeys.lua`, add to the requires at the top (after `backend_mod`):

```lua
local scripts_mod = require('dcs_sms_me.me_hotkey_scripts')
```

- [ ] **Step 2: Merge built-ins + scripts when building the engine**

Replace the `build` function with one that concatenates built-in actions and the dynamic script actions:

```lua
-- Built-in registry actions + one dynamic action per saved user script.
local function all_actions()
    local list = {}
    for _, a in ipairs(actions.list()) do list[#list + 1] = a end
    for _, a in ipairs(scripts_mod.to_actions(scripts_mod.load())) do list[#list + 1] = a end
    return list
end

local function build()
    return engine_mod.new({
        actions      = all_actions(),
        backend      = backend_mod.get(config.BACKEND_MODE),
        overrides    = config.load(),
        ed_conflicts = actions.ED_CONFLICTS,
        normalize    = actions.normalize_key,
    })
end
```

- [ ] **Step 3: Add `scripts_changed()` and `open_script_editor()`**

Add these functions just before the final `return M`:

```lua
-- Called by the script editor after add/update/remove: rebuild the engine from
-- the new script set (+ overrides), re-attach, and refresh the open window.
function M.scripts_changed()
    M.install()
    pcall(function()
        local w = require('dcs_sms_me.me_hotkey_window')
        if w and w.refresh then w.refresh() end
    end)
end

-- Open the script editor (id = existing script to edit, or nil for a new one).
function M.open_script_editor(id)
    local ok, err = pcall(function() require('dcs_sms_me.me_hotkey_script_editor').open(id) end)
    if not ok then
        log.write('sms.me', log.ERROR, 'script editor failed: ' .. tostring(err))
    end
end
```

- [ ] **Step 4: Run the suite (no regressions; facade isn't unit-tested but must still load)**

Run: `cd tools/me-mod/test && pwsh -File run-tests.ps1`
Expected: all tests pass (the facade has no unit test; this confirms the require chain is intact).

- [ ] **Step 5: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/me_hotkeys.lua
git commit -m "feat(me-mod): merge user scripts into the hotkey engine + editor entry points"
```

---

## Task 5: Window — Scripts category, New Script button, double-click routing, refresh

**Files:**
- Modify: `tools/me-mod/lua/dcs_sms_me/me_hotkey_window.lua`

(Run after Task 1 — same file. Needs Task 3's `script` flag and Task 4's facade.)

- [ ] **Step 1: Route script-row double-clicks to the editor; skip disabled/empty correctly**

In `me_hotkey_window.lua`, the `render` loop stores `W._row_meta[r] = { kind = 'action', id = row.id, disabled = row.disabled }`. Change it to also carry the `script` flag:

```lua
                    W._row_meta[r] = { kind = 'action', id = row.id, disabled = row.disabled, script = row.script }
```

In the grid's `onMouseDoubleClick` handler, route script rows to the editor instead of the capture overlay:

```lua
        W.grid.onMouseDoubleClick = function(self, mx, my, button)
            if button ~= 1 then return end
            local meta = row_at(self, mx, my)
            if not (meta and meta.kind == 'action' and not meta.disabled) then return end
            if meta.script then
                facade().open_script_editor(meta.id)
            else
                start_capture(meta.id)
            end
        end
```

- [ ] **Step 2: Only render the Scripts category when it has rows**

In `render`, the per-category block already skips a category while filtering when it has no matching rows (`if not (filtering and #cat_rows == 0) then`). Add a parallel rule so the empty **Scripts** category is hidden even with no filter. Replace that line with:

```lua
        -- Hide a category with no rows: always for Scripts (it's empty until you
        -- add one), and for any category while a filter is active.
        local hide_empty = (#cat_rows == 0) and (filtering or cat == 'Scripts')
        if not hide_empty then
```

- [ ] **Step 3: Don't let "Reset selected" act on a script row**

In `reset_selected`, bail early when the selected row is a script (scripts have no default to reset to — they're edited via the editor). Replace the start of `reset_selected`:

```lua
local function reset_selected()
    if not W.selected_id then
        if W.sms_window then W.sms_window:flash_status('Select a row first.', 'info') end
        return
    end
    if tostring(W.selected_id):match('^script%.') then
        if W.sms_window then W.sms_window:flash_status('Scripts are edited from the editor (double-click).', 'info') end
        return
    end
    local e = eng(); if not e then return end
```

- [ ] **Step 4: Add the `+ New Script` footer button**

In `build_body`, after the `W.reset_all_btn` block (its `raw:insertWidget(W.reset_all_btn)` line), add:

```lua
    W.new_script_btn = Button.new()
    pcall(function() if W.new_script_btn.setBounds then W.new_script_btn:setBounds(x + 278, y + h - 28, 130, 22) end end)
    if W.new_script_btn.setText then W.new_script_btn:setText('+ New Script') end
    try_skin(W.new_script_btn, 'dtc_button')
    if W.new_script_btn.addChangeCallback then
        W.new_script_btn:addChangeCallback(function() facade().open_script_editor(nil) end)
    end
    pcall(function() if raw and raw.insertWidget then raw:insertWidget(W.new_script_btn) end end)
```

Add the matching reposition in `relayout`, after the `W.reset_all_btn` reposition line:

```lua
    if W.new_script_btn then pcall(function() W.new_script_btn:setBounds(x + 278, y + h - 28, 130, 22) end) end
```

- [ ] **Step 5: Expose `refresh()` so the facade can repaint after a script change**

Add this public function just before the final `return M`:

```lua
-- Re-render the list from the (possibly rebuilt) engine. Called by the facade
-- after a script is added/edited/deleted. No-op if the window isn't built.
function M.refresh()
    if W.sms_window and W.grid then render() end
end
```

- [ ] **Step 6: Rebuild the embed, dev-reload, and smoke the window opens**

Run:
```bash
cd tools && go build -o dcs-sms.exe ./cmd/dcs-sms
```
Expected: exit 0. (Live behaviour is covered by the manual smoke in Task 7; the Lua tests in Task 2/3 are the syntax gate.)

- [ ] **Step 7: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/me_hotkey_window.lua
git commit -m "feat(me-mod): render Scripts category + New Script button + editor routing in Hotkeys window"
```

---

## Task 6: The script editor window

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/me_hotkey_script_editor.lua`

(Needs Task 1's capture module, Task 2's scripts module, Task 4's facade.)

No unit test — like the other windows it requires dxgui widgets at load and is verified by the manual smoke (Task 7).

- [ ] **Step 1: Write the editor module**

Create `tools/me-mod/lua/dcs_sms_me/me_hotkey_script_editor.lua`:

```lua
-- me_hotkey_script_editor.lua — create/edit a single user hotkey script.
--
-- sms_window chrome + a name field, a hotkey field (Capture/Clear via the shared
-- capture overlay), a multiline code EditBox, a Run button (compile + pcall now,
-- result/error shown inline), and Save/Delete/Cancel. Persists through
-- me_hotkey_scripts and asks the facade to rebuild the engine + repaint the list.
--
-- Verified by manual smoke, not unit tests (requires real dxgui widgets).

local Static; do local ok, m = pcall(require, 'Static'); if ok then Static = m end end
local Button; do local ok, m = pcall(require, 'Button'); if ok then Button = m end end
local EditBox;do local ok, m = pcall(require, 'EditBox');if ok then EditBox= m end end
local Skin;   do local ok, m = pcall(require, 'Skin');   if ok then Skin   = m end end

local dtc_skins; do local ok, m = pcall(require, 'dcs_sms_me.dtc_skins'); if ok then dtc_skins = m end end

local sms_window  = require('dcs_sms_me.sms_window')
local scripts_mod = require('dcs_sms_me.me_hotkey_scripts')
local capture     = require('dcs_sms_me.me_hotkey_capture')

local M = {}
local W = {}  -- single editor instance

local function facade() return require('dcs_sms_me.me_hotkeys') end

local function try_skin(widget, skin_name)
    pcall(function()
        if not (widget and widget.setSkin) then return end
        local s
        if     skin_name == 'dtc_button' then s = dtc_skins and dtc_skins.button()
        else
            local fn = Skin and Skin[skin_name]
            if fn then s = fn() end
        end
        if s then widget:setSkin(s) end
    end)
end

local function disp_key(k)
    if not k or k == '' then return '(none)' end
    return tostring(k):upper()
end

local function set_result(text, sev)
    if W.win then pcall(function() W.win:flash_status(tostring(text), sev or 'info') end) end
end

local function refresh_key_label()
    if W.key_lbl and W.key_lbl.setText then pcall(function() W.key_lbl:setText('Hotkey:  ' .. disp_key(W.key)) end) end
end

local function close()
    capture.teardown()
    if W.win then pcall(function() W.win:hide() end) end
end

local function run_now()
    local code = (W.code and W.code.getText and W.code:getText()) or ''
    local f, err = (loadstring or load)(code)
    if not f then set_result('compile error: ' .. tostring(err), 'error'); return end
    local ok, rv = pcall(f)
    if ok then set_result('→ ' .. tostring(rv), 'success')
    else set_result('error: ' .. tostring(rv), 'error') end
end

local function save()
    local name = (W.name and W.name.getText and W.name:getText()) or ''
    local code = (W.code and W.code.getText and W.code:getText()) or ''
    if name == '' then set_result('Name is required.', 'warning'); return end
    local ok, cerr = scripts_mod.compile(code)
    if not ok then set_result('compile error: ' .. tostring(cerr), 'error'); return end

    local list = scripts_mod.load()
    if W.edit_id then
        list = scripts_mod.update(list, W.edit_id, { name = name, key = W.key, code = code })
    else
        local new_id
        list, new_id = scripts_mod.add(list, { name = name, key = W.key, code = code })
        W.edit_id = new_id
    end
    scripts_mod.save(list)

    -- Warn (but don't block) if another action already holds this key.
    if W.key ~= '' then
        pcall(function()
            local holder = facade().engine():key_holder(W.key)
            if holder and holder ~= W.edit_id then
                log.write('sms.me', log.WARNING, 'script key ' .. W.key .. ' also held by ' .. tostring(holder))
            end
        end)
    end

    facade().scripts_changed()
    close()
end

local function delete_script()
    if not W.edit_id then close(); return end
    local list = scripts_mod.remove(scripts_mod.load(), W.edit_id)
    scripts_mod.save(list)
    facade().scripts_changed()
    close()
end

function M.open(id)
    capture.teardown()
    local list = scripts_mod.load()
    local s = id and scripts_mod.get(list, id) or nil
    W.edit_id = s and s.id or nil
    W.key = (s and s.key) or ''

    -- Rebuild the window fresh each open (simplest; scripts editing is infrequent).
    if W.win then pcall(function() W.win:hide() end); W.win = nil end
    W.win = sms_window.new({
        title = W.edit_id and 'Edit Script' or 'New Script',
        size = { w = 540, h = 480 },
        min_size = { w = 440, h = 340 },
        persist_across_new_mission = true,
        disable_undo_hotkey = true,
    })
    if not W.win then return end
    local raw = W.win:raw()
    local x, y, w, h = W.win:get_content_bounds()

    -- Name field
    W.name = EditBox.new()
    try_skin(W.name, 'editBoxSkin_ME')
    pcall(function() W.name:setBounds(x, y, w, 22) end)
    pcall(function() W.name:setText((s and s.name) or '') end)
    pcall(function() if W.name.setHintText then W.name:setHintText('Script name') end end)
    pcall(function() raw:insertWidget(W.name) end)

    -- Hotkey row: label + Capture + Clear
    W.key_lbl = Static.new()
    try_skin(W.key_lbl, 'staticSkin_ME')
    pcall(function() W.key_lbl:setBounds(x, y + 30, w - 180, 22) end)
    pcall(function() raw:insertWidget(W.key_lbl) end)
    refresh_key_label()

    W.capture_btn = Button.new()
    pcall(function() W.capture_btn:setBounds(x + w - 170, y + 30, 90, 22) end)
    pcall(function() W.capture_btn:setText('Capture') end)
    try_skin(W.capture_btn, 'dtc_button')
    if W.capture_btn.addChangeCallback then
        W.capture_btn:addChangeCallback(function()
            capture.capture(function(chord) W.key = chord; refresh_key_label() end, function() end)
        end)
    end
    pcall(function() raw:insertWidget(W.capture_btn) end)

    W.clear_btn = Button.new()
    pcall(function() W.clear_btn:setBounds(x + w - 76, y + 30, 76, 22) end)
    pcall(function() W.clear_btn:setText('Clear') end)
    try_skin(W.clear_btn, 'dtc_button')
    if W.clear_btn.addChangeCallback then
        W.clear_btn:addChangeCallback(function() W.key = ''; refresh_key_label() end)
    end
    pcall(function() raw:insertWidget(W.clear_btn) end)

    -- Code: multiline EditBox
    W.code = EditBox.new()
    try_skin(W.code, 'editBoxSkin_ME')
    pcall(function() if W.code.setMultiline then W.code:setMultiline(true) end end)
    pcall(function() if W.code.setTextWrapping then W.code:setTextWrapping(false) end end)
    pcall(function() W.code:setBounds(x, y + 60, w, h - 120) end)
    pcall(function() W.code:setText((s and s.code) or '') end)
    pcall(function() if W.code.setHintText then W.code:setHintText('-- Lua, runs in the ME GUI env') end end)
    pcall(function() raw:insertWidget(W.code) end)

    -- Bottom row: Run | (spacer) | Save / Delete / Cancel
    W.run_btn = Button.new()
    pcall(function() W.run_btn:setBounds(x, y + h - 28, 70, 22) end)
    pcall(function() W.run_btn:setText('Run') end)
    try_skin(W.run_btn, 'dtc_button')
    if W.run_btn.addChangeCallback then W.run_btn:addChangeCallback(run_now) end
    pcall(function() raw:insertWidget(W.run_btn) end)

    W.save_btn = Button.new()
    pcall(function() W.save_btn:setBounds(x + w - 240, y + h - 28, 74, 22) end)
    pcall(function() W.save_btn:setText('Save') end)
    try_skin(W.save_btn, 'dtc_button')
    if W.save_btn.addChangeCallback then W.save_btn:addChangeCallback(save) end
    pcall(function() raw:insertWidget(W.save_btn) end)

    W.del_btn = Button.new()
    pcall(function() W.del_btn:setBounds(x + w - 160, y + h - 28, 74, 22) end)
    pcall(function() W.del_btn:setText('Delete') end)
    try_skin(W.del_btn, 'dtc_button')
    if W.del_btn.addChangeCallback then W.del_btn:addChangeCallback(delete_script) end
    pcall(function() if W.del_btn.setVisible then W.del_btn:setVisible(W.edit_id ~= nil) end end)
    pcall(function() raw:insertWidget(W.del_btn) end)

    W.cancel_btn = Button.new()
    pcall(function() W.cancel_btn:setBounds(x + w - 80, y + h - 28, 80, 22) end)
    pcall(function() W.cancel_btn:setText('Cancel') end)
    try_skin(W.cancel_btn, 'dtc_button')
    if W.cancel_btn.addChangeCallback then W.cancel_btn:addChangeCallback(close) end
    pcall(function() raw:insertWidget(W.cancel_btn) end)

    W.win:show()
    W.win:set_status(W.edit_id and 'Editing script · Run to test · Save to apply' or 'New script · Run to test · Save to apply', 'info')
end

function M.close() close() end

return M
```

- [ ] **Step 2: Syntax-gate via the Go embed build**

Run:
```bash
cd tools && go build -o dcs-sms.exe ./cmd/dcs-sms
```
Expected: exit 0 (the new Lua is embedded; a Lua syntax error wouldn't fail the Go build, but Task 8's dev-reload + live load is the real gate — the build confirms the tree wires up).

- [ ] **Step 3: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/me_hotkey_script_editor.lua
git commit -m "feat(me-mod): add ME Hotkeys user-script editor window"
```

---

## Task 7: Docs + version bump

**Files:**
- Modify: `tools/me-mod/lua/dcs_sms_me/version.lua`
- Modify: `CHANGELOG.md`, `tools/me-mod/README.md`, `tools/me-mod/AGENTS.md`, `docs/release-gate/me-mod-smoke.md`

- [ ] **Step 1: Bump the version (minor)**

Read `tools/me-mod/lua/dcs_sms_me/version.lua`; it returns `"0.18.0"`. Change it to:

```lua
return "0.19.0"
```

- [ ] **Step 2: CHANGELOG entry**

In `CHANGELOG.md`, add a new entry at the top of the ME-mod section (above `### [0.18.0]`):

```markdown
### [0.19.0] — 2026-06-05

**Added**
- **ME Hotkeys: user scripts.** Write your own Lua snippets, name them, and bind
  each to a hotkey (Maya-style). A new **Scripts** category in the Hotkeys window
  lists them; **`+ New Script`** (or double-clicking a script row) opens an editor
  with a name field, a hotkey capture field, a multiline Lua editor, and a **Run**
  button that compiles + runs the code immediately (result/error shown inline).
  Scripts run in the ME GUI Lua env under `loadstring`+`pcall` (errors are caught
  and logged, never crash the editor) and persist to
  `Saved Games\DCS\dcs-sms\me_scripts.lua`, separate from the built-in key
  overrides. A blank hotkey = unbound (run it from the editor, bind later).
```

- [ ] **Step 3: README section**

In `tools/me-mod/README.md`, in the ME Hotkeys section, add a paragraph after the search-box paragraph:

```markdown
**User scripts (advanced).** The **Scripts** category lets you bind your own Lua to a key. Click **`+ New Script`** (or double-click an existing script row) to open the editor: give it a name, capture a hotkey, and write Lua in the multiline editor. **Run** executes it immediately so you can iterate, then **Save**. The code runs in the Mission Editor's Lua environment (full access to the editor's modules and the mission) — powerful, and entirely at your own risk; errors are caught and logged, never crash the editor. Scripts are stored in `<Saved Games>\DCS\dcs-sms\me_scripts.lua`. Leave the hotkey blank to keep a script unbound (run it from the editor only).
```

- [ ] **Step 4: AGENTS file-layout rows**

In `tools/me-mod/AGENTS.md` §2.2 (the File / Role table), add these rows after the `me_hotkey_window.lua` row:

```markdown
| `me_hotkey_capture.lua` | The shared "press a key" chord-capture overlay (used by the Hotkeys window's rebind and the script editor's hotkey field). |
| `me_hotkey_scripts.lua` | User-script persistence + CRUD (`me_scripts.lua`) + pure serialize/deserialize + `compile` + `to_actions()` (script defs → dynamic engine actions, `category='Scripts'`, `script=true`). |
| `me_hotkey_script_editor.lua` | The editor window for one user script (name / hotkey-capture / multiline code / Run / Save / Delete). Persists via `me_hotkey_scripts` and calls `me_hotkeys.scripts_changed()`. |
```

Also update the `me_hotkeys.lua` row to mention scripts — change it to:

```markdown
| `me_hotkeys.lua` | Facade/singleton — builds the engine from registry actions **+ user scripts** (`me_hotkey_scripts.to_actions()`) + saved overrides + backend, applies on bootstrap, exposes `toggle_window()`, `scripts_changed()`, `open_script_editor()`. |
```

- [ ] **Step 5: Release-gate smoke**

In `docs/release-gate/me-mod-smoke.md`, in the ME Hotkeys section, add these checklist items after the search-box item:

```markdown
- [ ] **`+ New Script`** opens the editor. Enter a name, click **Run** on
      `return 1+1` → status shows `→ 2`. Capture a hotkey, **Save** → a row
      appears under the **Scripts** category with that key.
- [ ] Press the script's hotkey (no field focused) → the script runs (verify its
      effect, e.g. a `log.write` line in `dcs.log`).
- [ ] Double-click the script row → editor reopens pre-filled; edit the code,
      **Save** → behaviour updates.
- [ ] A script with a syntax error: **Save** is blocked and the error is shown;
      **Run** on broken Lua shows the error and does not crash the editor.
- [ ] **Delete** in the editor removes the row; the **Scripts** category
      disappears when the last script is gone.
- [ ] Restart the ME → scripts persist (reloaded from
      `<Saved Games>\DCS\dcs-sms\me_scripts.lua`).
```

- [ ] **Step 6: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/version.lua CHANGELOG.md tools/me-mod/README.md tools/me-mod/AGENTS.md docs/release-gate/me-mod-smoke.md
git commit -m "docs(me-mod): document ME Hotkeys user scripts; bump me-mod to 0.19.0"
```

---

## Task 8: Build, full suite, install — integration gate

**Files:** none (verification only)

- [ ] **Step 1: Run the full Lua suite**

Run: `cd tools/me-mod/test && pwsh -File run-tests.ps1`
Expected: every test passes, including `All me_hotkey_scripts tests passed.` and `All me_hotkey_engine tests passed.`, exit code 0.

- [ ] **Step 2: Build the binary**

Run: `cd tools && go build -o dcs-sms.exe ./cmd/dcs-sms`
Expected: exit 0.

- [ ] **Step 3: Load-check every new/changed Lua file in the live GUI (no syntax/require errors)**

Run (with the ME open + external execution on):
```bash
./dcs-sms.exe dev-reload
./dcs-sms.exe exec --target gui --code 'for _,m in ipairs({"me_hotkey_capture","me_hotkey_scripts","me_hotkey_script_editor","me_hotkeys","me_hotkey_window","me_hotkey_engine"}) do local ok,err=pcall(require,"dcs_sms_me."..m); if not ok then return m..": "..tostring(err) end end return "all modules load OK"'
```
Expected: `all modules load OK`.

- [ ] **Step 4: Smoke the round-trip via exec (no UI needed)**

Run:
```bash
./dcs-sms.exe exec --target gui --code 'local S=require("dcs_sms_me.me_hotkey_scripts"); local list,id=S.add(S.load(),{name="smoke",key="",code="return 7"}); local acts=S.to_actions(list); local a; for _,x in ipairs(acts) do if x.id==id then a=x end end; a.invoke(); return "added "..id.." invoke-ok category="..a.category'
```
Expected: `added script.<n> invoke-ok category=Scripts` (this exercises add → to_actions → invoke without writing to disk; it does not call S.save, so no file is created).

- [ ] **Step 5: Final commit if anything changed (none expected)**

This task is verification only; if Steps 1–4 pass with no edits, there is nothing to commit. If a fix was needed, commit it with a `fix(me-mod):` message describing it.

---

## Done criteria

- `test_hotkey_scripts.lua` + the new `test_hotkey_engine.lua` case pass alongside the existing suite via `run-tests.ps1`.
- `go build ./cmd/dcs-sms` succeeds; all six modules load in the live ME.
- The Hotkeys window shows a **Scripts** category (when ≥1 script), `+ New Script` opens the editor, scripts run on their hotkey, and survive an ME restart.
- Version bumped to `0.19.0`; CHANGELOG / README / AGENTS / smoke updated.

**Stop here.** The user tests in the live ME, then runs `/bring-it-home`.
