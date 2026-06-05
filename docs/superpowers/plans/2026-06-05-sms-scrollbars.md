# sms_scrollbars Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the duplicated themed-scrollbar dxgui skinning into one shared `dcs_sms_me/sms_scrollbars.lua` module and refactor the three existing call sites onto it, behaviour-identical.

**Architecture:** A new pure module exposes `M.apply(skin, opts)` (inject grid vert + optional horz + optional Unit-List refinement) and `M.themed_editbox_skin(opts)` (mono editbox convenience). The script editor, prefab-manager tree skin, and `dtc_skins.scroll_pane()` each replace their inline scrollbar injection with a call. A unit test stubs `Skin` and asserts the table mutations.

**Tech Stack:** Lua 5.1, dxgui skin tables. Tests run via `tools/me-mod/test/run-tests.ps1` (`lua` is not on PATH).

**Parallelization:** Task 1 must complete first (creates the module). Tasks 2, 3, 4, 5 touch disjoint files and may run in parallel after Task 1.

**Spec:** `docs/superpowers/specs/2026-06-05-sms-scrollbars.md`

---

### Task 1: Create `sms_scrollbars.lua` module + unit test

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/sms_scrollbars.lua`
- Create: `tools/me-mod/test/test_sms_scrollbars.lua`
- Modify: `tools/me-mod/test/run-tests.ps1` (add the new test to the `$tests` list)

- [ ] **Step 1: Write the module**

Create `tools/me-mod/lua/dcs_sms_me/sms_scrollbars.lua` with exactly this content:

```lua
-- sms_scrollbars.lua — shared themed scrollbar skinning for ME-mod tool windows.
--
-- The vanilla ME "Unit List" panel uses a thin, dark scrollbar skin that the
-- DCS-SMS tool windows want to match: the grid's thin dark vertical bar, plus a
-- horizontal bar refined to 15px tall with a dark 9-slice track, visible arrow
-- images, and a polzunok thumb that brightens on hover. This module is the one
-- home for that recipe; previously it was hand-built inline and duplicated
-- across me_hotkey_script_editor.lua, prefab_manager.lua, and dtc_skins.lua.
--
-- Skin gotchas (all guarded so a future DCS build degrades instead of crashing):
--   * Skin.gridSkin_Multiplayer_roleNew() / editBoxSkin_ME() return a FRESH deep
--     copy per call, so mutating the returned table is widget-local — safe.
--   * Colours MUST be string form '0xRRGGBBAA'; numeric assignments silently
--     fail to parse.
--   * Everything is pcall-guarded.

local Skin; do local ok, m = pcall(require, 'Skin'); if ok then Skin = m end end

local M = {}

local FONT_MONO = 'DejaVuLGCSansMono.ttf'

-- Directory holding the horizontal scrollbar images (arrows + polzunok thumb).
local HZ = 'dxgui\\skins\\skinme\\images\\buttons\\scroll\\horz\\'

local HZ_TRACK_SLICES = {
    'left_top',    'center_top',    'right_top',
    'left_center', 'center_center', 'right_center',
    'left_bottom', 'center_bottom', 'right_bottom',
}

-- Apply the vanilla ME Unit List horizontal-bar refinement to a horzScrollBar
-- sub-skin (sourced from gridSkin_Multiplayer_roleNew). Replicates the override
-- in MissionEditor/modules/dialogs/me_units_list_panel.dlg:
--   * 15px tall (maxSize/minSize.vert) → thin, not the stock thick bar
--   * whole 9-slice track recoloured 0x363636ff to match the vertical bar (a
--     center-only recolour leaves the lighter edges as an outline the vert lacks)
--   * visible released arrow images (the grid's own only render on hover)
--   * polzunok thumb across released/hover/pressed so it brightens on hover
-- Mutates hz in place. Guarded so a different skin shape degrades quietly.
local function refine_horz_bar(hz)
    if not (hz and hz.skinData) then return end
    pcall(function()
        local sd = hz.skinData
        sd.params = sd.params or {}
        sd.params.maxSize = { vert = 15 }
        sd.params.minSize = { vert = 15 }
        -- Darken the WHOLE 9-slice track (not just center) — the grid horz bar
        -- is uniformly light, so a center-only recolour leaves the lighter
        -- edges as an outline the vertical bar lacks.
        local relbar = sd.states and sd.states.released and sd.states.released[1]
        if relbar and relbar.bkg then
            for _, k in ipairs(HZ_TRACK_SLICES) do
                relbar.bkg[k] = '0x363636ff'
            end
        end
        local function set_pic(btn, fname)
            local r = btn and btn.skinData and btn.skinData.states
                      and btn.skinData.states.released and btn.skinData.states.released[1]
            if r then r.picture = r.picture or {}; r.picture.file = HZ .. fname end
        end
        local sk = sd.skins or {}
        set_pic(sk.decreaseButton, 'down_normal.png')   -- left arrow
        set_pic(sk.increaseButton, 'up_normal.png')     -- right arrow
        -- Skin the thumb across ALL states with the polzunok image set so hover
        -- brightens (like the vertical bar) instead of the grid's faded
        -- horzscroll hover image.
        local function set_thumb(state, fname)
            local r = sk.thumb and sk.thumb.skinData and sk.thumb.skinData.states
                      and sk.thumb.skinData.states[state] and sk.thumb.skinData.states[state][1]
            if r then r.bkg = r.bkg or {}; r.bkg.file = HZ .. fname end
        end
        set_thumb('released', 'polzunok_normal.png')
        set_thumb('hover',    'polzunok_hover.png')
        set_thumb('pressed',  'polzunok_pressed.png')
    end)
end

-- Inject the themed grid scrollbars into a widget skin table.
--   skin : a skin table with skinData.skins (editbox / tree / scrollpane / grid)
--   opts.horizontal  (default true)  — also inject the horizontal bar
--   opts.refine_horz (default false) — apply the full Unit-List horz refinement
-- Always injects the grid's vertScrollBar. Mutates skin in place, returns it.
-- No-op (returns skin unchanged) if Skin or the required sub-tables are missing.
function M.apply(skin, opts)
    opts = opts or {}
    if not (skin and skin.skinData and skin.skinData.skins) then return skin end
    local horizontal = opts.horizontal ~= false
    pcall(function()
        local grid = Skin and Skin.gridSkin_Multiplayer_roleNew
                     and Skin.gridSkin_Multiplayer_roleNew()
        local gs = grid and grid.skinData and grid.skinData.skins
        if not gs then return end
        if gs.vertScrollBar then
            skin.skinData.skins.vertScrollBar = gs.vertScrollBar
        end
        if horizontal and gs.horzScrollBar then
            if opts.refine_horz then refine_horz_bar(gs.horzScrollBar) end
            skin.skinData.skins.horzScrollBar = gs.horzScrollBar
        end
    end)
    return skin
end

-- Convenience: a fresh editBoxSkin_ME() clone, themed and ready to setSkin.
--   opts.mono        (default false) — DejaVuLGCSansMono.ttf on every text state
--   opts.horizontal  (default true)  — forwarded to M.apply
--   opts.refine_horz (default true)  — forwarded to M.apply (editbox wants full)
-- Returns the themed skin, or nil if Skin/editBoxSkin_ME is unavailable.
function M.themed_editbox_skin(opts)
    opts = opts or {}
    if not (Skin and Skin.editBoxSkin_ME) then return nil end
    local s = Skin.editBoxSkin_ME()
    if not (s and s.skinData) then return nil end
    if opts.mono and s.skinData.states then
        pcall(function()
            for _, st in pairs(s.skinData.states) do
                if st[1] and st[1].text then st[1].text.font = FONT_MONO end
            end
        end)
    end
    local refine = opts.refine_horz
    if refine == nil then refine = true end
    M.apply(s, {
        horizontal  = opts.horizontal ~= false,
        refine_horz = refine,
    })
    return s
end

return M
```

- [ ] **Step 2: Write the unit test**

Create `tools/me-mod/test/test_sms_scrollbars.lua` with exactly this content:

```lua
-- Standalone test for sms_scrollbars (themed scrollbar skin injection).

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Fake Skin module: returns freshly-built skin tables with the nested shape the
-- module mutates. Each builder returns a NEW table per call (mirrors the real
-- Skin module's fresh-deep-copy-per-call contract).
local function fresh_grid()
    return {
        skinData = {
            skins = {
                vertScrollBar = { __id = 'grid_vert' },
                horzScrollBar = {
                    __id = 'grid_horz',
                    skinData = {
                        states = {
                            released = { [1] = { bkg = {
                                left_top='x', center_top='x', right_top='x',
                                left_center='x', center_center='x', right_center='x',
                                left_bottom='x', center_bottom='x', right_bottom='x',
                            } } },
                        },
                        skins = {
                            decreaseButton = { skinData = { states = { released = { [1] = {} } } } },
                            increaseButton = { skinData = { states = { released = { [1] = {} } } } },
                            thumb = { skinData = { states = {
                                released = { [1] = { bkg = {} } },
                                hover    = { [1] = { bkg = {} } },
                                pressed  = { [1] = { bkg = {} } },
                            } } },
                        },
                    },
                },
            },
        },
    }
end

local function fresh_editbox()
    return {
        skinData = {
            states = {
                released = { [1] = { text = { font = 'default.ttf' } } },
                hover    = { [1] = { text = { font = 'default.ttf' } } },
            },
            skins = {},
        },
    }
end

package.preload['Skin'] = function()
    return {
        gridSkin_Multiplayer_roleNew = fresh_grid,
        editBoxSkin_ME = fresh_editbox,
    }
end

local sms_scrollbars = require('dcs_sms_me.sms_scrollbars')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function target()
    return { skinData = { skins = {} } }
end

-- Case 1: vertScrollBar injected.
do
    local t = target()
    sms_scrollbars.apply(t)
    check('apply injects vertScrollBar', t.skinData.skins.vertScrollBar ~= nil)
end

-- Case 2: horizontal default true injects horzScrollBar.
do
    local t = target()
    sms_scrollbars.apply(t)
    check('apply injects horzScrollBar by default', t.skinData.skins.horzScrollBar ~= nil)
end

-- Case 3: horizontal=false skips horzScrollBar.
do
    local t = target()
    sms_scrollbars.apply(t, { horizontal = false })
    check('horizontal=false: vert injected', t.skinData.skins.vertScrollBar ~= nil)
    check('horizontal=false: horz NOT injected', t.skinData.skins.horzScrollBar == nil)
end

-- Case 4: refine_horz default false leaves grid horz unrefined.
do
    local t = target()
    sms_scrollbars.apply(t)
    local hz = t.skinData.skins.horzScrollBar
    check('default refine_horz=false: no 15px maxSize',
          hz and hz.skinData and (hz.skinData.params == nil or hz.skinData.params.maxSize == nil))
end

-- Case 5: refine_horz=true applies the full Unit-List treatment.
do
    local t = target()
    sms_scrollbars.apply(t, { refine_horz = true })
    local hz = t.skinData.skins.horzScrollBar
    local sd = hz and hz.skinData
    check('refine: 15px maxSize', sd and sd.params and sd.params.maxSize and sd.params.maxSize.vert == 15)
    check('refine: 15px minSize', sd and sd.params and sd.params.minSize and sd.params.minSize.vert == 15)
    local relbkg = sd and sd.states and sd.states.released and sd.states.released[1]
                   and sd.states.released[1].bkg
    local all_dark = relbkg ~= nil
    for _, k in ipairs({'left_top','center_top','right_top','left_center','center_center',
                        'right_center','left_bottom','center_bottom','right_bottom'}) do
        if not relbkg or relbkg[k] ~= '0x363636ff' then all_dark = false end
    end
    check('refine: all 9 track slices 0x363636ff', all_dark)
    local sk = sd and sd.skins
    check('refine: left arrow picture set',
          sk and sk.decreaseButton.skinData.states.released[1].picture
          and sk.decreaseButton.skinData.states.released[1].picture.file:find('down_normal.png') ~= nil)
    check('refine: right arrow picture set',
          sk and sk.increaseButton.skinData.states.released[1].picture
          and sk.increaseButton.skinData.states.released[1].picture.file:find('up_normal.png') ~= nil)
    local th = sk and sk.thumb.skinData.states
    check('refine: thumb released image',
          th and th.released[1].bkg.file and th.released[1].bkg.file:find('polzunok_normal.png') ~= nil)
    check('refine: thumb hover image',
          th and th.hover[1].bkg.file and th.hover[1].bkg.file:find('polzunok_hover.png') ~= nil)
    check('refine: thumb pressed image',
          th and th.pressed[1].bkg.file and th.pressed[1].bkg.file:find('polzunok_pressed.png') ~= nil)
end

-- Case 6: themed_editbox_skin({mono=true}) sets mono font + refined horz + vert.
do
    local s = sms_scrollbars.themed_editbox_skin({ mono = true })
    check('editbox skin returned', s ~= nil)
    local font_ok = s and s.skinData and s.skinData.states
        and s.skinData.states.released[1].text.font == 'DejaVuLGCSansMono.ttf'
        and s.skinData.states.hover[1].text.font == 'DejaVuLGCSansMono.ttf'
    check('editbox mono font on text states', font_ok)
    local hz = s and s.skinData and s.skinData.skins and s.skinData.skins.horzScrollBar
    check('editbox has refined horz (15px)',
          hz and hz.skinData and hz.skinData.params and hz.skinData.params.maxSize
          and hz.skinData.params.maxSize.vert == 15)
    check('editbox has vertScrollBar', s and s.skinData.skins.vertScrollBar ~= nil)
end

-- Case 7: graceful on odd input.
do
    local ok1 = pcall(sms_scrollbars.apply, nil)
    check('apply(nil) does not throw', ok1)
    local ok2 = pcall(sms_scrollbars.apply, { skinData = {} })
    check('apply(skin without skins) does not throw', ok2)
end

-- Case 8: the refactored call-site files still parse (syntax gate for the
-- refactor tasks; loadfile compiles without running their requires).
do
    for _, rel in ipairs({
        '../lua/dcs_sms_me/sms_scrollbars.lua',
        '../lua/dcs_sms_me/me_hotkey_script_editor.lua',
        '../lua/dcs_sms_me/prefab_manager.lua',
        '../lua/dcs_sms_me/dtc_skins.lua',
    }) do
        local fn, err = loadfile(rel)
        check('parses: ' .. rel, fn ~= nil, err)
    end
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All sms_scrollbars tests passed.')
```

- [ ] **Step 3: Register the test in the runner**

In `tools/me-mod/test/run-tests.ps1`, find this fragment inside the `$tests = @(...)` array (around line 27):

```
'test_sms_window.lua', 'test_splitter.lua',
```

Replace it with (insert `test_sms_scrollbars.lua` immediately before `test_sms_window.lua`):

```
'test_sms_scrollbars.lua', 'test_sms_window.lua', 'test_splitter.lua',
```

Note: the actual line is one long single-line array; match the exact substring `'test_sms_window.lua', 'test_splitter.lua',` and replace as above.

- [ ] **Step 4: Run the new test and verify it passes**

Run: `cd tools/me-mod/test && pwsh -File run-tests.ps1 2>&1 | Select-String -Pattern 'sms_scrollbars'`

Expected: a `=== test_sms_scrollbars.lua ===` header followed by `All sms_scrollbars tests passed.` and no `FAIL` lines.

- [ ] **Step 5: Run the full suite to confirm no regression**

Run: `cd tools/me-mod/test && pwsh -File run-tests.ps1 2>&1 | Select-String -Pattern '^FAIL|failure\(s\)'`

Expected: no output (no `FAIL` lines, no `N failure(s)` summary). The runner exits 0.

- [ ] **Step 6: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/sms_scrollbars.lua tools/me-mod/test/test_sms_scrollbars.lua tools/me-mod/test/run-tests.ps1
git commit -m "$(cat <<'EOF'
feat(me-mod): add shared sms_scrollbars module + tests

Extracts the dark, thin, ME-Unit-List-matched scrollbar recipe (grid vert
bar + 15px refined horz bar with 0x363636 track, arrow images, polzunok
thumb) into one reusable module. M.apply(skin, opts) injects into any widget
skin; M.themed_editbox_skin({mono=true}) returns a ready code-editor skin.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Refactor `me_hotkey_script_editor.lua` onto the module

**Files:**
- Modify: `tools/me-mod/lua/dcs_sms_me/me_hotkey_script_editor.lua`

**Depends on:** Task 1.

- [ ] **Step 1: Add the require**

Find this line (around line 19):

```lua
local capture     = require('dcs_sms_me.me_hotkey_capture')
```

Add a new line immediately after it:

```lua
local sms_scrollbars = require('dcs_sms_me.sms_scrollbars')
```

- [ ] **Step 2: Replace the inline skin builder with a call to the module**

Find the whole block from the `FONT_MONO` constant through the end of `apply_code_skin` — it begins at:

```lua
local FONT_MONO = 'DejaVuLGCSansMono.ttf'
```

and ends at the `end` closing `apply_code_skin` (the line `end` right before the `-- Reposition every widget to the current content rect.` comment). Replace that entire block (the `FONT_MONO` local, the descriptive comment, and the full `apply_code_skin` function) with exactly:

```lua
-- Skin for the code editor: the shared themed editbox skin (monospace font +
-- the main window's thin Unit-List scrollbars). themed_editbox_skin returns a
-- fresh editBoxSkin_ME() clone per call, so this is widget-local. The call-site
-- ordering (setMultiline BEFORE setSkin) still matters and lives at the EditBox
-- construction below — setMultiline rebuilds the scrollbar widgets.
local function apply_code_skin(widget)
    if not (widget and widget.setSkin) then return end
    local s = sms_scrollbars.themed_editbox_skin({ mono = true })
    if s then pcall(function() widget:setSkin(s) end) end
end
```

Note: do NOT touch the EditBox construction block (`W.code = EditBox.new()` … `setMultiline` … `apply_code_skin(W.code)` … `setText`). The `setMultiline`-before-skin ordering there is intentional and must stay.

- [ ] **Step 3: Verify the file still parses + suite green**

Run: `cd tools/me-mod/test && pwsh -File run-tests.ps1 2>&1 | Select-String -Pattern 'me_hotkey_script_editor|^FAIL|failure\(s\)'`

Expected: a `PASS parses: ../lua/dcs_sms_me/me_hotkey_script_editor.lua` line (from test_sms_scrollbars Case 8) and no `FAIL` lines, no `failure(s)`.

- [ ] **Step 4: Verify the build still compiles**

Run: `cd tools && go build -o dcs-sms.exe ./cmd/dcs-sms`

Expected: exits 0, no output.

- [ ] **Step 5: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/me_hotkey_script_editor.lua
git commit -m "$(cat <<'EOF'
refactor(me-mod): script editor uses sms_scrollbars.themed_editbox_skin

Replaces the inline editbox/mono/scrollbar skin builder with the shared
module. Behaviour-identical; the setMultiline-before-skin ordering stays at
the call site.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Refactor `prefab_manager.lua` tree skin onto the module

**Files:**
- Modify: `tools/me-mod/lua/dcs_sms_me/prefab_manager.lua`

**Depends on:** Task 1.

- [ ] **Step 1: Add the require**

Find this line (around line 67):

```lua
local prefab_naming = require('dcs_sms_me.prefab_naming')
```

Add a new line immediately after it:

```lua
local sms_scrollbars = require('dcs_sms_me.sms_scrollbars')
```

- [ ] **Step 2: Replace the inline scrollbar-injection block inside `apply_me_tree_skin`**

Find this exact block (inside `apply_me_tree_skin`, around lines 152–167):

```lua
        -- Replace the stock dark-gray scrollbars with the grid's thin
        -- modern-blue ones so the folder browser matches the file
        -- browser. Same trick dtc_skins.scroll_pane uses: clone the
        -- vertScrollBar sub-skin from gridSkin_Multiplayer_roleNew and
        -- inject it over the tree's default vertScrollBar.
        local grid_skin = Skin_mod.gridSkin_Multiplayer_roleNew
                          and Skin_mod.gridSkin_Multiplayer_roleNew()
        if grid_skin and grid_skin.skinData and grid_skin.skinData.skins
           and s.skinData.skins then
            if grid_skin.skinData.skins.vertScrollBar then
                s.skinData.skins.vertScrollBar = grid_skin.skinData.skins.vertScrollBar
            end
            if grid_skin.skinData.skins.horzScrollBar then
                s.skinData.skins.horzScrollBar = grid_skin.skinData.skins.horzScrollBar
            end
        end
```

Replace it with exactly:

```lua
        -- Replace the stock dark-gray scrollbars with the grid's thin
        -- modern-blue ones so the folder browser matches the file browser.
        -- The tree wants the plain grid vert+horz (no editbox-style horz
        -- refinement), so refine_horz=false.
        sms_scrollbars.apply(s, { refine_horz = false })
```

Note: leave the rest of `apply_me_tree_skin` untouched — the `Skin_mod` local (still used for `treeViewSkin_ME`), the panel/item colour repaints, and the final `widget:setSkin(s)`.

- [ ] **Step 3: Verify the file still parses + suite green**

Run: `cd tools/me-mod/test && pwsh -File run-tests.ps1 2>&1 | Select-String -Pattern 'prefab_manager.lua|^FAIL|failure\(s\)'`

Expected: a `PASS parses: ../lua/dcs_sms_me/prefab_manager.lua` line and no `FAIL` lines, no `failure(s)`. (Note: existing `test_prefab_ops_*` tests target `prefab_ops`, not this UI file; they should stay green.)

- [ ] **Step 4: Verify the build still compiles**

Run: `cd tools && go build -o dcs-sms.exe ./cmd/dcs-sms`

Expected: exits 0, no output.

- [ ] **Step 5: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/prefab_manager.lua
git commit -m "$(cat <<'EOF'
refactor(me-mod): prefab manager tree skin uses sms_scrollbars.apply

Replaces the inline grid vert+horz scrollbar injection in apply_me_tree_skin
with sms_scrollbars.apply(s, {refine_horz=false}). Behaviour-identical.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Refactor `dtc_skins.scroll_pane()` onto the module

**Files:**
- Modify: `tools/me-mod/lua/dcs_sms_me/dtc_skins.lua`

**Depends on:** Task 1.

- [ ] **Step 1: Add the require**

Find this line near the top (around line 17):

```lua
local Skin;  do local ok, m = pcall(require, 'Skin'); if ok then Skin = m end end
```

Add a new line immediately after it:

```lua
local sms_scrollbars = require('dcs_sms_me.sms_scrollbars')
```

- [ ] **Step 2: Replace the body of `scroll_pane()`**

Find this exact function (around lines 133–142):

```lua
function M.scroll_pane()
    local pane = Skin.scrollPane_modul_noinserts and Skin.scrollPane_modul_noinserts() or nil
    if not (pane and pane.skinData and pane.skinData.skins) then return pane end

    local grid = Skin.gridSkin_Multiplayer_roleNew and Skin.gridSkin_Multiplayer_roleNew() or nil
    if grid and grid.skinData and grid.skinData.skins and grid.skinData.skins.vertScrollBar then
        pane.skinData.skins.vertScrollBar = grid.skinData.skins.vertScrollBar
    end
    return pane
end
```

Replace it with exactly:

```lua
function M.scroll_pane()
    local pane = Skin.scrollPane_modul_noinserts and Skin.scrollPane_modul_noinserts() or nil
    if not (pane and pane.skinData and pane.skinData.skins) then return pane end

    -- Inject the grid's thin vertScrollBar (vertical only — scroll panes have no
    -- horizontal bar) so the pane's bar matches the rest of the tool windows.
    return sms_scrollbars.apply(pane, { horizontal = false })
end
```

- [ ] **Step 3: Verify the file still parses + suite green**

Run: `cd tools/me-mod/test && pwsh -File run-tests.ps1 2>&1 | Select-String -Pattern 'dtc_skins.lua|skin_helper|^FAIL|failure\(s\)'`

Expected: a `PASS parses: ../lua/dcs_sms_me/dtc_skins.lua` line, the `test_skin_helper` suite still passing, and no `FAIL` lines, no `failure(s)`.

- [ ] **Step 4: Verify the build still compiles**

Run: `cd tools && go build -o dcs-sms.exe ./cmd/dcs-sms`

Expected: exits 0, no output.

- [ ] **Step 5: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/dtc_skins.lua
git commit -m "$(cat <<'EOF'
refactor(me-mod): dtc_skins.scroll_pane delegates to sms_scrollbars

Replaces the inline grid vertScrollBar injection with
sms_scrollbars.apply(pane, {horizontal=false}). Vertical-only, identical
result; removes the duplicated injection knowledge.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Doc sync + version bump

**Files:**
- Modify: `tools/me-mod/lua/dcs_sms_me/version.lua`
- Modify: `CHANGELOG.md`
- Modify: `tools/me-mod/AGENTS.md`

**Depends on:** Task 1 (the module must exist for the docs to describe it). Disjoint from Tasks 2–4.

- [ ] **Step 1: Bump the me-mod version (patch — internal refactor, no user-facing change)**

In `tools/me-mod/lua/dcs_sms_me/version.lua`, replace:

```lua
return "0.19.0"
```

with:

```lua
return "0.19.1"
```

- [ ] **Step 2: Add the CHANGELOG entry**

In `CHANGELOG.md`, find:

```markdown
## ME-mod

### [0.19.0] — 2026-06-05
```

Insert a new entry between `## ME-mod` and `### [0.19.0] — 2026-06-05`, so it reads:

```markdown
## ME-mod

### [0.19.1] — 2026-06-05

**Changed**
- Internal: extracted the themed scrollbar skinning (the thin dark vertical bar
  + the ME-Unit-List-matched horizontal bar) into a shared
  `dcs_sms_me/sms_scrollbars.lua` module. The script editor, the Prefab Manager
  folder tree, and the DTC scroll-pane skin now share one implementation. No
  visible change — future tool windows get matching scrollbars from one call.

### [0.19.0] — 2026-06-05
```

- [ ] **Step 3: Add the AGENTS.md §2.2 file-table row**

In `tools/me-mod/AGENTS.md`, find the `sms_window.lua` row:

```markdown
| `sms_window.lua` | Reusable handle/factory for tool windows — branded title bar, footer status bar, resize clamp, Ctrl+Z to undo bus, File-New auto-hide. The Prefab Manager rides on it; future tool windows should too. |
```

Insert a new row immediately after it:

```markdown
| `sms_scrollbars.lua` | Reusable themed-scrollbar skin helper. `M.apply(skin, opts)` injects the grid's thin dark vertScrollBar (+ optional horzScrollBar, optionally refined to the vanilla ME Unit-List look) into any widget skin; `M.themed_editbox_skin({mono=true})` returns a ready code-editor skin. Used by `me_hotkey_script_editor.lua`, `prefab_manager.lua` (tree), and `dtc_skins.scroll_pane()`. |
```

- [ ] **Step 4: Verify the docs are coherent (no build/test needed)**

Run: `git diff --stat`

Expected: shows `tools/me-mod/lua/dcs_sms_me/version.lua`, `CHANGELOG.md`, and `tools/me-mod/AGENTS.md` modified.

- [ ] **Step 5: Commit**

```bash
git add tools/me-mod/lua/dcs_sms_me/version.lua CHANGELOG.md tools/me-mod/AGENTS.md
git commit -m "$(cat <<'EOF'
docs(me-mod): document sms_scrollbars; bump me-mod to 0.19.1

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- New module `sms_scrollbars.lua` with `M.apply` + `M.themed_editbox_skin` → Task 1. ✓
- Refactor script editor → Task 2. ✓
- Refactor prefab manager tree → Task 3. ✓
- Refactor `dtc_skins.scroll_pane()` → Task 4. ✓
- Unit test → Task 1 (Steps 2–5). ✓
- Doc sync (AGENTS.md §2.2, CHANGELOG, version bump) → Task 5. ✓
- Part B dropped → not in plan. ✓
- `setMultiline`-before-skin ordering preserved → Task 2 Step 2 note. ✓
- No-cycle require (`sms_scrollbars` requires only Skin) → Task 1 module; Task 4 require. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to". Every code step shows full code. ✓

**Type/name consistency:** `M.apply(skin, opts)`, `opts.horizontal`, `opts.refine_horz`, `M.themed_editbox_skin(opts)`, `opts.mono` used identically across the module, the test, and all three call sites. Default `refine_horz=false` in `M.apply`; `themed_editbox_skin` defaults it to `true`. The test asserts both defaults (Case 4 = false, Case 6 = true). ✓
