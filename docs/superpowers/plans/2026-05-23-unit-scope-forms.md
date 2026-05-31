# Unit-scope forms — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship nine forms for Mass Edit's Unit scope (find/replace, prefix, suffix, auto-name, skill, onboard #, livery, heading, fuel %) plus the category-aware applicability infrastructure, two new treeview columns (Category + Coalition with tinting), and a host-side observer that gates each form by applicable-unit count.

**Architecture:** Each form is a self-contained module under `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/<name>_unit.lua`, exporting `M.scope = 'unit'`, `M.title`, `M.applies_to` (optional), `M._apply(entities, args, categories)`, `M.new(parent_raw, get_checked, on_after_apply, get_categories)`. Forms wrap existing `verbs.unit_set_*` functions — no new verbs needed. A new shared module `applicability.lua` computes per-form gating state; the host observer calls `panel:set_enabled(bool)` on each panel when the checked set changes. Undo handlers are registered at module load (`mass_edit.<form>_unit` namespace) and use the same verb path for symmetric restoration.

**Tech Stack:** Lua 5.1 (test VM at `/c/Users/Niels/bin/lua51/lua5.1.exe`), dxgui (Static / Button / EditBox / ComboList / ToggleButton — all pcall-guarded so modules load in tests).

**Spec:** `docs/superpowers/specs/2026-05-23-unit-scope-forms.md`

## Execution strategy

**Phase 1 — Foundation (sequential, blocks Phase 2):**
- Task 1: `applicability.lua` helper + test
- Task 2: `SCOPE_COLUMNS.unit` + `row_values('unit', ...)` + coalition tinting on unit rows
- Task 3: Host-side applicability observer wiring in `mass_edit.lua`

**Phase 2 — Forms (parallelizable, dispatch all 9 in parallel):**
- Tasks 4–12: one module per form, fully independent. Each task: write test → run/fail → implement → run/pass → run full suite → commit.

**Phase 3 — Wiring (sequential, after Phase 2 completes):**
- Task 13: Register all 9 forms in `mass_edit_forms.lua` `by_scope.unit`; register all 10 new tests in `run-tests.ps1`; verify full suite green
- Task 14: Smoke-checklist section in `docs/release-gate/me-mod-smoke.md`

User has explicitly requested maximum parallelism: dispatch Tasks 4–12 concurrently. Each task is independent (separate file, separate test, no shared state mutations).

## Conventions used by every form

Every form module follows this skeleton (drawn from `set_country.lua`):

```lua
local M = {}
M.scope = 'unit'
M.title = '<Human-readable title>'
M.applies_to = { plane = true, helicopter = true }  -- optional; omit for universal

local undo        = require('dcs_sms_me.undo')
local skin_helper = require('dcs_sms_me.skin_helper')

local Static;       do local ok, m = pcall(require, 'Static');       if ok then Static       = m end end
local EditBox;      do local ok, m = pcall(require, 'EditBox');      if ok then EditBox      = m end end
local Button;       do local ok, m = pcall(require, 'Button');       if ok then Button       = m end end
local ComboList;    do local ok, m = pcall(require, 'ComboList');    if ok then ComboList    = m end end
local ListBoxItem;  do local ok, m = pcall(require, 'ListBoxItem');  if ok then ListBoxItem  = m end end

local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.mass_edit.<form_name>', _G.log.WARNING or 2, msg) end)
end

-- M._apply(entities, args, categories) → result table
-- M.new(parent_raw, get_checked, on_after_apply, get_categories) → panel
-- undo.register_handler('mass_edit.<form_name>', ...) at module bottom

return M
```

The panel object exports `show`, `hide`, `set_bounds(x, y, w, h)`, `get_height()`, and (NEW for this cycle) `set_enabled(bool)` — disables/enables the Apply button and all inputs.

Every test file starts with this scaffold (drawn from `test_mass_edit_set_country.lua`):

```lua
package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             dir = function() return function() return nil end end }
end
local mock = require('mock_me_mission')
package.preload['me_mission'] = function() return mock end

-- Stub verbs (one or more unit_set_* functions per form).
local verb_calls = {}
local verb_responses = {}
local verb_throws = nil
local verbs_stub = {}
function verbs_stub.unit_set_<thing>(args)
    verb_calls[#verb_calls + 1] = args
    if verb_throws then local m = verb_throws; verb_throws = nil; error(m) end
    local r = table.remove(verb_responses, 1)
    return r or { ok = false, error = 'no stubbed response' }
end
package.preload['dcs_sms_me.verbs'] = function() return verbs_stub end

package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end

local form = require('dcs_sms_me.mass_edit_forms.<module_name>')
local undo = require('dcs_sms_me.undo')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

local function reset()
    verb_calls = {}; verb_responses = {}; verb_throws = nil; undo.clear()
end

-- Test cases as `do ... end` blocks here.

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All <form> tests passed.')
```

---

## Task 1: applicability.lua helper

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/applicability.lua`
- Test: `tools/me-mod/test/test_unit_applicability.lua`

- [ ] **Step 1: Write the failing test**

Create `tools/me-mod/test/test_unit_applicability.lua`:

```lua
-- Test for applicability.lua — pure helper, no I/O.
package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

local A = require('dcs_sms_me.applicability')

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Case 1: no applies_to (universal) — every entity counts as applicable.
do
    local u1, u2, u3 = {}, {}, {}
    local cats = { [u1] = 'plane', [u2] = 'vehicle', [u3] = 'ship' }
    local applicable, total = A.compute(nil, { u1, u2, u3 }, cats)
    check('universal: applicable=3', applicable == 3, 'got ' .. tostring(applicable))
    check('universal: total=3', total == 3, 'got ' .. tostring(total))
end

-- Case 2: planes-only applies_to with mixed selection.
do
    local u1, u2, u3, u4 = {}, {}, {}, {}
    local cats = { [u1] = 'plane', [u2] = 'vehicle', [u3] = 'plane', [u4] = 'ship' }
    local applicable, total = A.compute({ plane = true }, { u1, u2, u3, u4 }, cats)
    check('planes-only mixed: applicable=2', applicable == 2, 'got ' .. tostring(applicable))
    check('planes-only mixed: total=4', total == 4, 'got ' .. tostring(total))
end

-- Case 3: planes+helos applies_to.
do
    local u1, u2, u3 = {}, {}, {}
    local cats = { [u1] = 'plane', [u2] = 'helicopter', [u3] = 'vehicle' }
    local applicable, total = A.compute({ plane = true, helicopter = true }, { u1, u2, u3 }, cats)
    check('planes+helos: applicable=2', applicable == 2, 'got ' .. tostring(applicable))
    check('planes+helos: total=3', total == 3, 'got ' .. tostring(total))
end

-- Case 4: empty checked set.
do
    local applicable, total = A.compute({ plane = true }, {}, {})
    check('empty: applicable=0', applicable == 0)
    check('empty: total=0', total == 0)
end

-- Case 5: missing category in map defaults to 'unknown' — not applicable.
do
    local u1 = {}
    local applicable, total = A.compute({ plane = true }, { u1 }, {})
    check('missing cat: applicable=0', applicable == 0)
    check('missing cat: total=1', total == 1)
end

-- Case 6: nil categories table — treat as empty (defensive).
do
    local u1 = {}
    local applicable, total = A.compute({ plane = true }, { u1 }, nil)
    check('nil cats: applicable=0', applicable == 0)
    check('nil cats: total=1', total == 1)
end

-- Case 7: is_applicable convenience for a single entity.
do
    local u = {}
    local cats = { [u] = 'plane' }
    check('is_applicable: yes', A.is_applicable({ plane = true }, u, cats) == true)
    check('is_applicable: no (vehicle)', A.is_applicable({ plane = true }, u, { [u] = 'vehicle' }) == false)
    check('is_applicable: universal yes', A.is_applicable(nil, u, cats) == true)
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All applicability tests passed.')
```

- [ ] **Step 2: Run the test, verify it fails**

```
cd /c/git/dcs-sms/.claude/worktrees/me-mass-edit/tools/me-mod/test
lua5.1 test_unit_applicability.lua
```

Expected: error along the lines of `module 'dcs_sms_me.applicability' not found`.

- [ ] **Step 3: Implement applicability.lua**

Create `tools/me-mod/lua/dcs_sms_me/applicability.lua`:

```lua
-- applicability.lua — category-aware gating helper for Mass Edit forms.
--
-- Each unit-scope form may declare M.applies_to = { plane = true,
-- helicopter = true } to restrict which categories it operates on.
-- Forms without M.applies_to apply to every category (universal).
--
-- compute() returns (applicable_count, total_count) over a checked-set
-- so the host knows whether to gray-out the form (applicable == 0) or
-- leave it interactive (applicable > 0, with skip-and-count for the
-- non-matching units inside _apply).
--
-- is_applicable() is the per-entity convenience used inside _apply to
-- decide whether to skip a row.

local M = {}

-- Compute (applicable, total) for a checked set under a form's applies_to
-- map. `applies_to` nil/false/empty → universal (every entity applicable).
function M.compute(applies_to, checked, categories)
    if type(checked) ~= 'table' then return 0, 0 end
    local total = #checked
    if not applies_to or next(applies_to) == nil then
        return total, total
    end
    local cats = categories or {}
    local applicable = 0
    for _, e in ipairs(checked) do
        local cat = cats[e] or 'unknown'
        if applies_to[cat] then applicable = applicable + 1 end
    end
    return applicable, total
end

-- True iff a single entity is applicable under the given applies_to map.
function M.is_applicable(applies_to, entity, categories)
    if not applies_to or next(applies_to) == nil then return true end
    local cat = (categories or {})[entity] or 'unknown'
    return applies_to[cat] == true
end

return M
```

- [ ] **Step 4: Run the test, verify it passes**

```
cd /c/git/dcs-sms/.claude/worktrees/me-mass-edit/tools/me-mod/test
lua5.1 test_unit_applicability.lua
```

Expected: `All applicability tests passed.` and exit 0.

- [ ] **Step 5: Run the full suite to confirm no regressions**

```
cd /c/git/dcs-sms/.claude/worktrees/me-mass-edit/tools/me-mod/test
pwsh ./run-tests.ps1
```

Expected: every previously-passing test still passes. (The new test file isn't registered in run-tests.ps1 yet — that happens in Task 13.)

- [ ] **Step 6: Commit**

```
git add tools/me-mod/lua/dcs_sms_me/applicability.lua tools/me-mod/test/test_unit_applicability.lua
git commit -m "$(cat <<'EOF'
feat(me-mod): applicability helper for unit-scope form gating

Returns (applicable, total) over a checked set given a form's
applies_to map (e.g. { plane=true, helicopter=true }). Forms without
applies_to are universal. Host uses (applicable == 0) to gray-out
the form; (applicable > 0) leaves it interactive and the form's
_apply skips per-row inapplicable units with a count.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Unit-scope columns + coalition tinting

**Files:**
- Modify: `tools/me-mod/lua/dcs_sms_me/mass_edit.lua` (`SCOPE_COLUMNS.unit`, `row_values('unit', ...)`, coalition tinting branch)

This task is mostly a localized edit to three regions of `mass_edit.lua`. No test file — the column data is exercised manually when the user opens the Mass Edit window. The `row_values` change is small enough that a dedicated test is more bookkeeping than value; smoke-tested via the existing window.

- [ ] **Step 1: Replace `SCOPE_COLUMNS.unit`**

In `tools/me-mod/lua/dcs_sms_me/mass_edit.lua`, find:

```lua
    unit = {
        { key = 'check', label = '',      width = 28,  type = 'check'  },
        { key = 'name',  label = 'Name',  width = 160, type = 'string' },
        { key = 'type',  label = 'Type',  width = 110, type = 'string' },
        { key = 'skill', label = 'Skill', width = 75,  type = 'string' },
        { key = 'group', label = 'Group', width = 55,  type = 'string' },
    },
```

Replace with:

```lua
    unit = {
        { key = 'check',     label = '',          width = 28,  type = 'check'  },
        { key = 'name',      label = 'Name',      width = 140, type = 'string' },
        { key = 'type',      label = 'Type',      width = 100, type = 'string' },
        { key = 'category',  label = 'Category',  width = 70,  type = 'string' },
        { key = 'skill',     label = 'Skill',     width = 75,  type = 'string' },
        { key = 'coalition', label = 'Coalition', width = 60,  type = 'string' },
        { key = 'group',     label = 'Group',     width = 55,  type = 'string' },
    },
```

- [ ] **Step 2: Extend `row_values('unit', ...)` for new keys**

Find the unit branch in `row_values`:

```lua
    elseif scope == 'unit' then
        return { name  = tostring(entity.name or ''),
                 type  = tostring(entity.type or ''),
                 skill = tostring(entity.skill or ''),
                 group = tostring((group or {}).name or '') }
```

Replace with:

```lua
    elseif scope == 'unit' then
        local cat = W.categories[entity] or ''
        local side = (group and group.boss) and W.country_to_side[group.boss] or ''
        return { name      = tostring(entity.name or ''),
                 type      = tostring(entity.type or ''),
                 category  = tostring(cat),
                 skill     = tostring(entity.skill or ''),
                 coalition = tostring(side),
                 group     = tostring((group or {}).name or '') }
```

- [ ] **Step 3: Add unit-scope branch to the coalition-tinting code**

Find the tinting block around line 703 of `mass_edit.lua`:

```lua
                    if cell and c.key == 'coalition' then
                        local side
                        if W.scope == 'group' then
                            side = W.country_to_side[r.entity.boss]
                        elseif W.scope == 'airbase' then
                            local c_str = r.entity.coalition
                            if     c_str == 'red'  then side = 'red'
                            elseif c_str == 'blue' then side = 'blue'
                            else                       side = 'neutral' end
                        end
                        local skin = side and COALITION_CELL_SKIN[side]
                        if skin then skin_helper.apply(cell, skin) end
                    elseif cell and W.scope == 'group' and c.key == 'country' then
```

Add a `unit` branch between `airbase` and the `end`:

```lua
                    if cell and c.key == 'coalition' then
                        local side
                        if W.scope == 'group' then
                            side = W.country_to_side[r.entity.boss]
                        elseif W.scope == 'airbase' then
                            local c_str = r.entity.coalition
                            if     c_str == 'red'  then side = 'red'
                            elseif c_str == 'blue' then side = 'blue'
                            else                       side = 'neutral' end
                        elseif W.scope == 'unit' then
                            local g = W.parent_map[r.entity]
                            side = (g and g.boss) and W.country_to_side[g.boss] or nil
                        end
                        local skin = side and COALITION_CELL_SKIN[side]
                        if skin then skin_helper.apply(cell, skin) end
                    elseif cell and W.scope == 'group' and c.key == 'country' then
```

- [ ] **Step 4: Run the full suite to confirm no regressions**

```
cd /c/git/dcs-sms/.claude/worktrees/me-mass-edit/tools/me-mod/test
pwsh ./run-tests.ps1
```

Expected: all existing tests still pass. (No new test was added; this change is structural and is smoke-tested by the user when the window opens.)

- [ ] **Step 5: Commit**

```
git add tools/me-mod/lua/dcs_sms_me/mass_edit.lua
git commit -m "$(cat <<'EOF'
feat(me-mod): unit-scope columns get Category + Coalition (tinted)

Adds two columns to SCOPE_COLUMNS.unit:
  - Category (plane/helicopter/vehicle/ship/static/train)
  - Coalition (with per-row red/blue/neutral tinting via the existing
    COALITION_CELL_SKIN map, matching group + airbase scopes)

row_values('unit', ...) populates both keys from W.categories +
W.country_to_side[group.boss].

Total left-pane width grows 428 → 528px; splitter handles it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Host-side applicability observer

**Files:**
- Modify: `tools/me-mod/lua/dcs_sms_me/mass_edit.lua` (small additions in `show_forms_for_active_scope` + `on_after_apply` + the per-row checkbox handler)

The observer's job: whenever the (scope, checked-set) changes, recompute applicable-count for each form in the active scope and call `panel:set_enabled(applicable > 0)`. Forms without `applies_to` are always enabled. Forms with `applies_to` but no checked units yet are grayed.

Each form module exports `M.applies_to` as a static table at load time. The host's per-scope form list (built when forms are mounted) carries both the module and the panel object — extend it to also carry `applies_to`.

- [ ] **Step 1: Add `applicability` require + helper at the top of mass_edit.lua**

Near the other requires (after `selection = require(...)`):

```lua
local applicability = require('dcs_sms_me.applicability')
```

- [ ] **Step 2: Track applies_to per mounted form**

Find where forms are mounted (search `mass_edit_forms.forms_for(scope)` in `mass_edit.lua`). The mount loop currently builds an array of panels. Extend it so each entry is `{ panel = ..., module = mod }` instead of just the panel. (If the mount loop already does this, skip.)

Concretely, the loop probably looks like:

```lua
for _, mod in ipairs(mass_edit_forms.forms_for(scope)) do
    local panel = mod.new(parent_raw, get_checked_for_active_scope, on_after_apply, get_categories_for_active_scope)
    if panel then
        W.form_panels[scope][#W.form_panels[scope] + 1] = panel
    end
end
```

Adjust to also remember the module so `applies_to` is reachable later. There are two options that don't require restructuring the array shape: (a) attach the module to the panel as a hidden field; (b) parallel array. Pick (a) for minimal blast radius:

```lua
for _, mod in ipairs(mass_edit_forms.forms_for(scope)) do
    local panel = mod.new(parent_raw, get_checked_for_active_scope, on_after_apply, get_categories_for_active_scope)
    if panel then
        panel._applies_to = mod.applies_to   -- nil for universal forms
        W.form_panels[scope][#W.form_panels[scope] + 1] = panel
    end
end
```

- [ ] **Step 3: Add `recompute_form_gating` host helper**

Above `show_forms_for_active_scope` add:

```lua
-- Recompute per-form gating based on the active scope's checked set.
-- Calls panel:set_enabled(applicable > 0) on every panel in the active
-- scope. Panels without set_enabled (the airbase / group forms) are
-- left untouched — only unit-scope panels implement gating today.
local function recompute_form_gating()
    local panels = W.form_panels[W.scope] or {}
    if #panels == 0 then return end
    local checked = get_checked_for_active_scope()
    local cats    = get_categories_for_active_scope()
    for _, panel in ipairs(panels) do
        if panel.set_enabled then
            local applicable = applicability.compute(panel._applies_to, checked, cats)
            pcall(panel.set_enabled, panel, applicable > 0)
        end
    end
end
```

- [ ] **Step 4: Wire `recompute_form_gating` into the three places that change checked-set or scope**

(a) At the end of `show_forms_for_active_scope`, before its closing `end`:

```lua
    recompute_form_gating()
```

(b) At the end of `on_after_apply` (after `rebuild_treeview()`):

```lua
    recompute_form_gating()
```

(c) Inside the per-row checkbox handler that mutates `W.checked[W.scope][entity]`. There are several places: the plain click branch (`W.checked[W.scope][entity] = state or nil`), the shift-click range-fill branch, and any "From map" / "Clear selection" helpers. The cleanest hook is to call `recompute_form_gating()` once at the end of every code path that mutates `W.checked`. Search `mass_edit.lua` for `W.checked[W.scope][` writes and append `recompute_form_gating()` after each (4–6 sites; pcall'd internally so safe to call repeatedly).

- [ ] **Step 5: Run the full suite to confirm no regressions**

```
cd /c/git/dcs-sms/.claude/worktrees/me-mass-edit/tools/me-mod/test
pwsh ./run-tests.ps1
```

Expected: no regressions. The observer only fires `pcall(set_enabled)` which is a no-op on existing form panels (group / airbase forms don't export `set_enabled`).

- [ ] **Step 6: Commit**

```
git add tools/me-mod/lua/dcs_sms_me/mass_edit.lua
git commit -m "$(cat <<'EOF'
feat(me-mod): per-form applicability gating observer

Adds recompute_form_gating() which iterates the active scope's
mounted panels and calls panel:set_enabled(applicable > 0) based
on the form's M.applies_to and the current checked set + category
map. Wired into show_forms_for_active_scope, on_after_apply, and
every W.checked[W.scope] mutation site.

Existing group / airbase form panels don't implement set_enabled
and are silently left untouched (pcall-guarded). New unit-scope
forms in upcoming commits all export set_enabled.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — Form template (canonical reference for Tasks 4–12)

Every form in Tasks 4–12 follows this template. The per-task "Differences"
section spells out exactly what to substitute. Subagents implementing a form
should: (1) copy this template into the target file; (2) apply the task's
substitutions; (3) write the test by mirroring the canonical test template
below with the task's specifics; (4) run tests; (5) commit.

### Form module template (`<form>_unit.lua`)

```lua
-- mass_edit_forms/<FORM_NAME>.lua — <ONE-LINE DESCRIPTION>

local M = {}
M.scope = 'unit'
M.title = '<FORM TITLE>'
-- M.applies_to = { plane = true, helicopter = true }   -- OR omit for universal

local undo        = require('dcs_sms_me.undo')
local skin_helper = require('dcs_sms_me.skin_helper')
local applicability = require('dcs_sms_me.applicability')   -- used by _apply for skip-and-count
local transforms  = require('dcs_sms_me.mass_edit_transforms')  -- ONLY for rename + auto-name forms

local Static;       do local ok, m = pcall(require, 'Static');       if ok then Static       = m end end
local EditBox;      do local ok, m = pcall(require, 'EditBox');      if ok then EditBox      = m end end
local Button;       do local ok, m = pcall(require, 'Button');       if ok then Button       = m end end
local ComboList;    do local ok, m = pcall(require, 'ComboList');    if ok then ComboList    = m end end
local ListBoxItem;  do local ok, m = pcall(require, 'ListBoxItem');  if ok then ListBoxItem  = m end end

local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.mass_edit.<FORM_NAME>', _G.log.WARNING or 2, msg) end)
end

-- _apply(entities, args, categories) — pure; no dxgui access.
function M._apply(entities, args, categories)
    if type(entities) ~= 'table' or #entities == 0 then
        return { changed=0, failed=0, not_applicable=0, changed_rows={},
                 nothing_selected=true, toast='Nothing selected', sev='warning' }
    end
    -- <ARG-GUARD>: if args (string / number / table) is missing, return early with
    -- toast='<Pick / enter X>' sev='warning'.

    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed, not_applicable = {}, 0, 0
    -- For forms with M.applies_to, skip inapplicable rows here per applicability.is_applicable.
    -- For forms without M.applies_to, apply to every row.
    -- Forms that pre-check "no-op" (already-at-target) increment `unchanged` here too.

    for idx, u in ipairs(entities) do
        if M.applies_to and not applicability.is_applicable(M.applies_to, u, categories) then
            not_applicable = not_applicable + 1
        else
            -- <PER-ROW LOGIC>: compute new_value (may use transforms.* for rename),
            --                  call verbs.unit_set_<thing>({ id = u.unitId, <field> = new_value }),
            --                  classify result into changed_rows / failed / unchanged.
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.<FORM_NAME>', { rows = changed_rows })
    end

    local result = { changed=#changed_rows, failed=failed, not_applicable=not_applicable,
                     changed_rows=changed_rows }
    -- <TOAST-BUILDER>: pick wording per the form's spec. Universal pattern:
    --   if all 0 and not_applicable > 0:  toast='Nothing applicable', sev='warning'
    --   elif changed > 0:                 toast='<N> <noun> set [· M not applicable] [· F failed]'
    --                                     sev = (failed == 0 and 'success') or 'warning'
    --   elif failed > 0:                  toast='0 <noun> set · F failed', sev='error'
    return result
end

undo.register_handler('mass_edit.<FORM_NAME>', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.<FORM_NAME> undo snapshot'
    end
    local verbs = require('dcs_sms_me.verbs')
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        -- Call verbs.unit_set_<thing> with the OLD value to restore.
        local p_ok, res = pcall(verbs.unit_set_<thing>, { id = r.unit.unitId, <field> = r.old })
        if not (p_ok and type(res) == 'table' and res.ok) then errors = errors + 1 end
    end
    return true, errors > 0 and (errors..' partial failures') or nil
end)

local LAYOUT = { PAD_X=8, LABEL_W=56, ROW_H=24, BTN_W=90, GAP_X=6, GAP_Y=4, FOOTER_PAD=6 }
local function form_height()
    -- Single-row forms: LAYOUT.ROW_H + LAYOUT.FOOTER_PAD.
    -- Two-row forms (heading absolute+delta): 2*ROW_H + GAP_Y + FOOTER_PAD.
    return LAYOUT.ROW_H + LAYOUT.FOOTER_PAD
end

function M.new(parent_raw, get_checked, on_after_apply, get_categories)
    if not parent_raw then return nil end
    local owned = {}
    local function add(w) if w then owned[#owned+1]=w; pcall(parent_raw.insertWidget, parent_raw, w) end; return w end

    -- <WIDGET-BUILD>: create label(s), input(s), apply button(s) per the form's design.
    -- Apply button callback shape (single-button forms):
    --   pcall(apply_btn.addMouseDownCallback, apply_btn, function()
    --       pcall(function()
    --           local args = <READ FROM INPUTS>
    --           local entities = (type(get_checked) == 'function') and get_checked() or {}
    --           local cats     = (type(get_categories) == 'function') and get_categories() or {}
    --           local result   = M._apply(entities, args, cats)
    --           if type(on_after_apply) == 'function' then on_after_apply(result) end
    --       end)
    --   end)

    local panel = {}
    function panel:show()         for _, w in ipairs(owned) do if w.setVisible then pcall(w.setVisible, w, true)  end end end
    function panel:hide()         for _, w in ipairs(owned) do if w.setVisible then pcall(w.setVisible, w, false) end end end
    function panel:get_height()   return form_height() end
    function panel:set_enabled(flag)
        local en = flag and true or false
        for _, w in ipairs(owned) do if w.setEnabled then pcall(w.setEnabled, w, en) end end
    end
    function panel:set_bounds(x, y, w, h)
        -- <LAYOUT>: position widgets. Right-anchor the Apply button.
    end

    return panel
end

return M
```

### Test file template (`test_mass_edit_<form_name>.lua`)

```lua
package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
package.preload['lfs'] = function() return { writedir=function() return '' end, mkdir=function() return true end, dir=function() return function() return nil end end } end
local mock = require('mock_me_mission')
package.preload['me_mission'] = function() return mock end

-- Stub each verb the form uses.
local verb_calls, verb_responses = {}, {}
local verbs_stub = {}
function verbs_stub.unit_set_<thing>(args)
    verb_calls[#verb_calls+1] = args
    local r = table.remove(verb_responses, 1)
    return r or { ok=false, error='no stubbed response' }
end
package.preload['dcs_sms_me.verbs'] = function() return verbs_stub end
package.preload['dcs_sms_me.selection'] = function() return { snapshot=function() return { ok=true, groups={}, statics={}, zones={}, drawings={} } end } end

local form = require('dcs_sms_me.mass_edit_forms.<form_name>')
local undo = require('dcs_sms_me.undo')

local failures = 0
local function check(n, ok, m) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(m)); failures = failures + 1 end end
local function reset() verb_calls = {}; verb_responses = {}; undo.clear() end

-- Required cases per form (mirror set_country test for boilerplate detail):
--   1. Module exports: scope='unit', title is string, _apply is fn, new is fn,
--      applies_to is nil (universal) OR equal to expected map.
--   2. Empty selection → nothing_selected, no verb calls.
--   3. Missing/invalid args → guard toast, no verb calls.
--   4. Single-entity success → 1 verb call, undo recorded, toast matches.
--   5. Mixed: multiple entities, some succeed, some no-op → counts + toast.
--   6. Verb rejection (ok=false) → counted as failed, sev='error'.
--   7. Mixed: some applicable + some inapplicable (for category-gated forms only)
--      → counts not_applicable, toast includes "· N not applicable".
--   8. Undo restores via verb with OLD value.

-- Case 1 (always):
do
    check('scope=unit', form.scope == 'unit')
    check('title is nonempty string', type(form.title) == 'string' and #form.title > 0)
    check('_apply is fn', type(form._apply) == 'function')
    check('new is fn', type(form.new) == 'function')
    -- For category-gated forms, additionally:
    -- check('applies_to = {plane, helicopter}', form.applies_to and form.applies_to.plane and form.applies_to.helicopter)
end

-- ... (additional cases per the list above)

if failures > 0 then print(failures..' failure(s)'); os.exit(1) end
print('All <form_name> tests passed.')
```

### Standard task steps (apply to every form task)

Each Phase 2 task has the same 6 steps:

- [ ] **Step 1: Write the failing test file** (use the test template + the task's case list and specifics)
- [ ] **Step 2: Run test, verify it fails** (`lua5.1 test_mass_edit_<form>.lua` → module-not-found)
- [ ] **Step 3: Implement the form module** (use the form template + the task's substitutions)
- [ ] **Step 4: Run test, verify it passes** (`lua5.1 test_mass_edit_<form>.lua` → "All <form> tests passed.")
- [ ] **Step 5: Run the full suite** (`pwsh ./run-tests.ps1`) — confirm no regressions
- [ ] **Step 6: Commit** with the per-task commit message at the end of the task

---

## Task 4 (parallel-eligible): set_skill_unit form

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/set_skill_unit.lua`
- Test: `tools/me-mod/test/test_mass_edit_set_skill_unit.lua`

**Substitutions:**

- `<FORM_NAME>` → `set_skill_unit`
- `<FORM TITLE>` → `'Set skill'`
- `M.applies_to` → omit (universal)
- `<thing>` (verb name) → `skill` → `verbs.unit_set_skill({ id, skill })`
- `<field>` → `skill`
- `<noun>` → `skill`
- `<ARG-GUARD>`: if `type(skill) ~= 'string' or skill == ''` → `toast='Pick a skill'`, sev='warning'
- `<PER-ROW LOGIC>`:
  ```lua
  local old = u.skill
  if old == args then
      unchanged = (unchanged or 0) + 1
  else
      local p_ok, res = pcall(verbs.unit_set_skill, { id = u.unitId, skill = args })
      if not p_ok then failed = failed + 1
      elseif type(res) ~= 'table' or not res.ok then failed = failed + 1
      else changed_rows[#changed_rows + 1] = { unit = u, old = old } end
  end
  ```
- `<TOAST-BUILDER>`: as the universal pattern (use noun "skill"). Add the
  no-op-only branch: `if changed == 0 and failed == 0 and unchanged > 0 then toast = 'Already '..args; sev = 'info' end`.
- Widget arrangement: `Skill:` label + ComboList (populated with the 7 SKILLS) + `Set` button right-anchored. Single row.

**Skill list (constant inside the module):**

```lua
local SKILLS = { 'Average', 'Good', 'High', 'Excellent', 'Random', 'Player', 'Client' }
```

**Test specifics:**

- Add `unchanged` field to the result-shape expectations.
- Required test cases: 1, 2, 3 (missing skill), 4 (success across 2 units), 5 (already-at-target → unchanged=1, toast='Already High', sev='info'), 6 (verb rejection), 8 (undo restore).
- This form has no applies_to, so case 7 (not_applicable) is omitted.

**Commit message:**

```
feat(me-mod): set_skill_unit form + undo

Combo + Apply: sets u.skill on every checked unit via
verbs.unit_set_skill. Universal applicability. Pre-checks
current skill to count "unchanged" without burning verb calls.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 5 (parallel-eligible): find_replace_unit_name form

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/find_replace_unit_name.lua`
- Test: `tools/me-mod/test/test_mass_edit_find_replace_unit_name.lua`

**Substitutions:**

- `<FORM_NAME>` → `find_replace_unit_name`
- `<FORM TITLE>` → `'Find & replace in unit names'`
- `M.applies_to` → omit (universal)
- `<thing>` → `name` → `verbs.unit_set_name({ id, new_name })`
- `<field>` → `new_name` (the verb takes `new_name`, NOT `name`)
- `<noun>` → `renamed`
- `<ARG-GUARD>`: args is `{ find=string, replace=string }`. If args missing or find is empty, return early with toast='No matches' sev='warning' (matches group-scope precedent which produces 'No matches' when the find string yields zero changes).
- `<PER-ROW LOGIC>`:
  ```lua
  local old = u.name
  local new = transforms.find_replace(old, { find = args.find, replace = args.replace }, idx)
  if new == old then
      -- silent skip (no count) — matches group-scope find_replace which only counts
      -- changed/failed; "no match" rows are invisible to the counters.
  else
      local p_ok, res = pcall(verbs.unit_set_name, { id = u.unitId, new_name = new })
      if not p_ok then failed = failed + 1
      elseif type(res) ~= 'table' or not res.ok then failed = failed + 1  -- name in use
      else changed_rows[#changed_rows + 1] = { unit = u, old = old } end
  end
  ```
- Undo restores `r.old` via `verbs.unit_set_name({ id, new_name = r.old })`.
- `<TOAST-BUILDER>`: if changed == 0 and failed == 0 → 'No matches' sev='warning'. Else format `%d renamed [· M failed]`.

**Widget arrangement:** `Find: [EditBox]   Replace: [EditBox]   [Replace]` button. Mirror `find_replace_group_name.lua` layout exactly (3-input row with right-anchored button).

**Test specifics:**

- Required cases: 1, 2, 3 (empty find), 4 (success: 3 units, all match), 5 (mixed: some match, some don't → only matches counted), 6 (verb rejection on collision → failed=1), 8 (undo restore).
- Stub `verbs.unit_set_name` and verify `args.new_name` (not `args.name`).

**Commit message:**

```
feat(me-mod): find_replace_unit_name form + undo

Find/Replace EditBoxes + Replace button: each checked unit's
name has args.find literally replaced with args.replace. Unchanged
rows are silent (matches group-scope find_replace_group_name).
Collisions (Mission.renameUnit refusal) counted as failed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 6 (parallel-eligible): add_prefix_unit_name form

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/add_prefix_unit_name.lua`
- Test: `tools/me-mod/test/test_mass_edit_add_prefix_unit_name.lua`

**Substitutions:**

- `<FORM_NAME>` → `add_prefix_unit_name`
- `<FORM TITLE>` → `'Add prefix to unit names'`
- `M.applies_to` → omit
- `<thing>` → `name`; `<field>` → `new_name`; `<noun>` → `renamed`
- `<ARG-GUARD>`: args is `{ text=string }`. If empty, return early with toast='Enter a prefix' sev='warning'.
- `<PER-ROW LOGIC>`:
  ```lua
  local old = u.name
  local new = transforms.add_prefix(old, { text = args.text }, idx)
  if new == old then
      -- silent skip
  else
      local p_ok, res = pcall(verbs.unit_set_name, { id = u.unitId, new_name = new })
      if not p_ok then failed = failed + 1
      elseif type(res) ~= 'table' or not res.ok then failed = failed + 1
      else changed_rows[#changed_rows + 1] = { unit = u, old = old } end
  end
  ```
- `<TOAST-BUILDER>`: changed > 0 → '%d renamed [· M failed]'; otherwise 'No changes' sev='warning'.

**Widget arrangement:** `Prefix:` label + EditBox + `Add prefix` button right-anchored. Mirror `add_prefix_group_name.lua` exactly.

**Test specifics:** Required cases: 1, 2, 3 (empty prefix), 4 (success on 2 units), 6 (verb collision → failed=1), 8 (undo restore).

**Commit message:**

```
feat(me-mod): add_prefix_unit_name form + undo

EditBox + Add prefix button: prepends args.text to each checked
unit's name via verbs.unit_set_name. Collisions counted as failed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 7 (parallel-eligible): add_suffix_unit_name form

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/add_suffix_unit_name.lua`
- Test: `tools/me-mod/test/test_mass_edit_add_suffix_unit_name.lua`

**Substitutions:**

- `<FORM_NAME>` → `add_suffix_unit_name`
- `<FORM TITLE>` → `'Add suffix to unit names'`
- `M.applies_to` → omit
- `<thing>` → `name`; `<field>` → `new_name`; `<noun>` → `renamed`
- `<ARG-GUARD>`: args is `{ text=string, keep_num=boolean }`. If text is empty, toast='Enter a suffix' sev='warning'.
- `<PER-ROW LOGIC>`:
  ```lua
  local old = u.name
  local new = transforms.add_suffix(old, { text = args.text, keep_num = args.keep_num }, idx)
  if new == old then
      -- silent skip
  else
      local p_ok, res = pcall(verbs.unit_set_name, { id = u.unitId, new_name = new })
      if not p_ok then failed = failed + 1
      elseif type(res) ~= 'table' or not res.ok then failed = failed + 1
      else changed_rows[#changed_rows + 1] = { unit = u, old = old } end
  end
  ```

**Widget arrangement:** `Suffix:` label + EditBox + `Keep #` ToggleButton (sticky, like the group-scope version) + `Add suffix` button right-anchored. Mirror `add_suffix_group_name.lua` widget layout exactly. The Keep# toggle's state is read in the apply callback as `args.keep_num`.

**Test specifics:** Required cases: 1, 2, 3 (empty), 4 (success on 2 units, keep_num=false), 5 (keep_num=true on "Viper-1" → "ViperX-1"), 6 (verb collision), 8 (undo).

**Commit message:**

```
feat(me-mod): add_suffix_unit_name form + undo

EditBox + Keep# toggle + Add suffix button: appends args.text to
each checked unit's name via verbs.unit_set_name. When Keep# is
on, trailing `-<digits>` blocks are preserved (suffix inserted
before them), matching the group-scope form's behavior.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 8 (parallel-eligible): auto_name_unit form

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/auto_name_unit.lua`
- Test: `tools/me-mod/test/test_mass_edit_auto_name_unit.lua`

**Substitutions:**

- `<FORM_NAME>` → `auto_name_unit`
- `<FORM TITLE>` → `'Auto-name units'`
- `M.applies_to` → omit
- `<thing>` → `name`; `<field>` → `new_name`; `<noun>` → `renamed`
- `<ARG-GUARD>`: args is `{ base=string, start=number }`. If `base` is empty,
  toast='Enter a base name' sev='warning'. `start` defaults to 1 when nil
  or non-number.
- `<PER-ROW LOGIC>`: single counter across the checked set, treeview order.
  ```lua
  local start = tonumber(args.start) or 1
  -- inside the loop, use `idx` (the 1-based loop index from `for idx, u in ipairs(entities)`):
  local old = u.name
  local new = transforms.auto_number(old,
      { pattern = args.base .. '-{n}', start = start, step = 1, pad = 1 }, idx)
  if new == old then
      -- silent skip (already matches the auto-generated name)
  else
      local p_ok, res = pcall(verbs.unit_set_name, { id = u.unitId, new_name = new })
      if not p_ok then failed = failed + 1
      elseif type(res) ~= 'table' or not res.ok then failed = failed + 1
      else changed_rows[#changed_rows + 1] = { unit = u, old = old } end
  end
  ```
- `<TOAST-BUILDER>`: changed > 0 → `'%d renamed [· M failed]'`; else `'No changes' sev='warning'`.
  When failed > 0 and changed == 0 → 'failed' sev='error'.

**Widget arrangement:** `Base:` label + EditBox + `Start at:` label + EditBox (numeric input, default '1') + `Auto-name` button right-anchored. Two label/input pairs on a single row.

**Test specifics:**
- Required cases: 1, 2, 3 (missing base), 4 (success: 3 units → Base-1, Base-2, Base-3), 5 (start=5 → Base-5, Base-6, Base-7), 6 (verb collision on one row → failed=1 + others succeed), 8 (undo).
- Verify `verb_calls[i].new_name` matches expected sequence.

**Commit message:**

```
feat(me-mod): auto_name_unit form + undo

Base + Start at + Auto-name button: renames every checked unit
to `<base>-<n>` with a single counter across the checked set
(treeview order). Reuses transforms.auto_number for the {n} →
padded-int substitution. Collisions counted as failed; rows
that would no-op (already matching name) are silently skipped.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 9 (parallel-eligible): set_heading_unit form

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/set_heading_unit.lua`
- Test: `tools/me-mod/test/test_mass_edit_set_heading_unit.lua`

Two-row form: Absolute + Delta, each with its own Apply. Universal applicability.

**Substitutions and special structure:**

- `<FORM_NAME>` → `set_heading_unit`
- `<FORM TITLE>` → `'Set heading'`
- `M.applies_to` → omit
- The form exports TWO apply functions: `M._apply_absolute(entities, deg)` and
  `M._apply_delta(entities, delta_deg)`. The widget callbacks dispatch to the
  matching one based on which row's Apply button was clicked. Both share a
  single undo handler `mass_edit.set_heading_unit` keyed by the per-row
  snapshot `{ unit, old_rad }` (old heading in radians, captured before
  mutation).

**_apply_absolute:**

```lua
function M._apply_absolute(entities, deg)
    if type(entities) ~= 'table' or #entities == 0 then
        return { changed=0, failed=0, changed_rows={}, nothing_selected=true,
                 toast='Nothing selected', sev='warning' }
    end
    if type(deg) ~= 'number' then
        return { changed=0, failed=0, changed_rows={}, toast='Enter heading (°)', sev='warning' }
    end
    local norm = ((deg % 360) + 360) % 360
    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed = {}, 0
    for _, u in ipairs(entities) do
        local old_rad = tonumber(u.heading) or 0
        local p_ok, res = pcall(verbs.unit_set_heading, { id = u.unitId, heading_deg = norm })
        if not p_ok then failed = failed + 1; log_warn('threw: '..tostring(res))
        elseif type(res) ~= 'table' or not res.ok then failed = failed + 1
        else changed_rows[#changed_rows + 1] = { unit = u, old_rad = old_rad } end
    end
    if #changed_rows > 0 then undo.record_generic('mass_edit.set_heading_unit', { rows = changed_rows }) end
    local result = { changed=#changed_rows, failed=failed, changed_rows=changed_rows }
    if #changed_rows == 0 and failed > 0 then result.toast = string.format('0 heading set · %d failed', failed); result.sev = 'error'
    elseif #changed_rows == 0 then result.toast = 'No changes'; result.sev = 'warning'
    else result.toast = string.format('%d heading set%s', #changed_rows, failed > 0 and (' · '..failed..' failed') or ''); result.sev = (failed == 0 and 'success') or 'warning' end
    return result
end
```

**_apply_delta:** same shape, but `local target_deg = math.deg(old_rad) + delta_deg; local norm = ((target_deg % 360) + 360) % 360` before the verb call. Old value captured the same way (`old_rad = tonumber(u.heading) or 0`).

**Undo handler:**

```lua
undo.register_handler('mass_edit.set_heading_unit', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then
        return nil, 'invalid mass_edit.set_heading_unit undo snapshot'
    end
    local verbs = require('dcs_sms_me.verbs')
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        local deg = math.deg(r.old_rad)
        local norm = ((deg % 360) + 360) % 360
        local p_ok, res = pcall(verbs.unit_set_heading, { id = r.unit.unitId, heading_deg = norm })
        if not (p_ok and type(res) == 'table' and res.ok) then errors = errors + 1 end
    end
    return true, errors > 0 and (errors..' partial failures') or nil
end)
```

**Widget arrangement:** two rows.
- Row 1: `Absolute:` label + EditBox (numeric) + `°` static + `Apply` button (right-anchored)
- Row 2: `Delta:` label + EditBox (numeric, allows negative) + `°` static + `Apply` button (right-anchored)

`form_height()` returns `2 * LAYOUT.ROW_H + LAYOUT.GAP_Y + LAYOUT.FOOTER_PAD`. The two Apply buttons are siblings; each callback reads its own EditBox, converts via `tonumber()` (nil → guard toast), dispatches to `M._apply_absolute` or `M._apply_delta`.

**Test specifics:**

- Required cases:
  1. Module exports (scope/title/applies_to nil/_apply_absolute fn/_apply_delta fn/new fn).
  2. _apply_absolute: empty → nothing_selected.
  3. _apply_absolute: missing/non-number deg → guard toast='Enter heading (°)'.
  4. _apply_absolute: 3 units, success, verb args `.heading_deg = normalized`. Verify normalization with `_apply_absolute(units, 450)` produces verb call with `heading_deg=90`.
  5. _apply_absolute: negative input `-30` → normalized to 330.
  6. _apply_delta: unit at heading=0 rad, delta=+90 → verb gets `heading_deg=90`.
  7. _apply_delta: unit at heading=math.rad(350), delta=+45 → verb gets `heading_deg=35` (wraps).
  8. _apply_delta: unit at heading=math.rad(10), delta=-30 → verb gets `heading_deg=340`.
  9. Undo restores via verb with old rad → deg conversion (e.g. old=math.rad(120) → undo verb arg heading_deg=120).

**Commit message:**

```
feat(me-mod): set_heading_unit form (absolute + delta) + undo

Two-row form. Absolute row sets heading_deg verbatim (normalized
to [0, 360)). Delta row reads u.heading (rad), converts to deg,
adds delta, normalizes, writes back. Both routes record per-row
old heading (radians) and share one undo handler that converts
old_rad back to deg before re-applying via verbs.unit_set_heading.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 10 (parallel-eligible): set_onboard_num_unit form

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/set_onboard_num_unit.lua`
- Test: `tools/me-mod/test/test_mass_edit_set_onboard_num_unit.lua`

**Substitutions:**

- `<FORM_NAME>` → `set_onboard_num_unit`
- `<FORM TITLE>` → `'Set onboard #'`
- `M.applies_to` → `{ plane = true }` (planes only)
- `<thing>` → `onboard_num`; `<field>` → `onboard_num`; `<noun>` → `onboard # set`

**Two _apply functions** like the heading form:

`M._apply_sequential(entities, start_str, categories)`:
- `start_str` is the raw EditBox text (e.g. "010" or "5"). Padding inferred from `#start_str`.
- `local start_n = tonumber(start_str)` → guard nil → toast='Enter a number' sev='warning'.
- `local pad = #start_str` (uses input width as zero-pad).
- Loop applicable rows only (`applicability.is_applicable(M.applies_to, u, categories)`); inapplicable rows go to `not_applicable`.
- Per applicable row at index `applicable_idx` (1-based among applicable rows):
  - `local n = start_n + (applicable_idx - 1)`
  - `local fmt = '%0'..pad..'d'`
  - `local new_str = string.format(fmt, n)`
  - Call `verbs.unit_set_onboard_num({ id = u.unitId, onboard_num = new_str })`.
  - Capture `old = u.onboard_num` for undo.

`M._apply_random(entities, categories)`:
- No input. Generates unique 3-digit `001..999` random strings, one per applicable row.
- Uniqueness within the checked applicable set (use a `taken = {}` map; loop until a new random fits).
- Per applicable row: call the verb with the generated 3-digit string.

Both share one undo handler:

```lua
undo.register_handler('mass_edit.set_onboard_num_unit', function(snapshot)
    if type(snapshot) ~= 'table' or type(snapshot.rows) ~= 'table' then return nil, 'invalid' end
    local verbs = require('dcs_sms_me.verbs')
    local errors = 0
    for _, r in ipairs(snapshot.rows) do
        local restore = r.old
        if type(restore) ~= 'string' or restore == '' then restore = '0' end  -- verb requires non-empty
        local p_ok, res = pcall(verbs.unit_set_onboard_num, { id = r.unit.unitId, onboard_num = restore })
        if not (p_ok and type(res) == 'table' and res.ok) then errors = errors + 1 end
    end
    return true, errors > 0 and (errors..' partial failures') or nil
end)
```

(Note: `unit_set_onboard_num` refuses empty strings. If a unit's original onboard_num was nil/empty, we restore as '0' rather than crashing — pragmatic; rare case.)

**Widget arrangement:** single row. `Start at:` label + EditBox (default '010') + `Apply` button + `Random` button. Two siblings on the right side. Apply button calls `_apply_sequential`; Random calls `_apply_random` ignoring the EditBox.

**Test specifics:**

- 1. Module exports including `applies_to = { plane = true }`.
- 2. _apply_sequential: empty selection → nothing_selected.
- 3. _apply_sequential: invalid start → toast='Enter a number'.
- 4. _apply_sequential: 3 planes, start_str='010' → verb args `'010', '011', '012'`.
- 5. _apply_sequential: 3 planes, start_str='5' → `'5', '6', '7'` (no padding).
- 6. _apply_sequential: 2 planes + 1 tank → tank not counted, planes get '010', '011', `not_applicable=1`, toast includes 'not applicable'.
- 7. _apply_random: 5 planes → all 5 verb calls, each with 3-char digit string, all values distinct.
- 8. Undo: restore via verb with old onboard_num string.
- Stub `verbs.unit_set_onboard_num`. Set `categories = { [u1]='plane', [u2]='vehicle', ... }` per case.

**Commit message:**

```
feat(me-mod): set_onboard_num_unit form (planes only) + undo

Start at EditBox + Apply + Random buttons. Apply auto-increments
from input, padding inferred from input width ('010' → 3 digits,
'1' → no padding). Random generates unique 3-digit 001-999 values
across the checked applicable set. Tanks/ships/etc. are silently
skipped via M.applies_to = { plane = true } gating.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 11 (parallel-eligible): set_livery_unit form

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/set_livery_unit.lua`
- Test: `tools/me-mod/test/test_mass_edit_set_livery_unit.lua`

**Substitutions:**

- `<FORM_NAME>` → `set_livery_unit`
- `<FORM TITLE>` → `'Set livery'`
- `M.applies_to` → `{ plane = true, helicopter = true }`
- `<thing>` → `livery`; `<field>` → `livery`; `<noun>` → `livery set`

**Special structure — single-airframe gating (in addition to applies_to):**

The form is grayed when (a) zero planes/helos are checked (universal applicability rule), OR (b) the checked planes/helos span more than one distinct `u.type` value. The host's `recompute_form_gating` only knows about applies_to; the airframe-uniqueness check is internal. To wire this in cleanly:

- Override `panel:set_enabled` so it ALWAYS recomputes the airframe-uniqueness gate before applying enabled-state. The host calls `set_enabled(true)` when applicable > 0; the form then checks airframe uniqueness and downgrades to `false` if mixed.

```lua
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
```

`panel:set_enabled(flag)` does:

```lua
function panel:set_enabled(flag)
    local en = flag and true or false
    if en then
        local units = checked_planes_helos(get_checked, get_categories)
        if distinct_airframes(units) > 1 or #units == 0 then en = false end
    end
    for _, w in ipairs(owned) do if w.setEnabled then pcall(w.setEnabled, w, en) end end
    -- Also: if en transitioned to true, re-populate the combo for the (single) airframe.
    if en then repopulate_combo() end
end
```

**Livery source resolution (do this at module-load time, with runtime re-resolution per repopulate_combo()):**

```lua
local function liveries_for(airframe)
    -- Preference 1: ME's own livery API. Common ED entrypoint is
    -- _G.getRegistredLiveriesNames(airframe) or Mission.getLiveriesNames(airframe).
    -- The plan implementer must spike this: grep for 'liveries' / 'liveriesNames'
    -- in the DCS install's MissionEditor/ scripts.lua first.
    do
        local ok, names = pcall(function()
            if type(_G.getRegistredLiveriesNames) == 'function' then return _G.getRegistredLiveriesNames(airframe) end
            local Mission = require('me_mission')
            if Mission and type(Mission.getLiveriesNames) == 'function' then return Mission:getLiveriesNames(airframe) end
            return nil
        end)
        if ok and type(names) == 'table' and #names > 0 then return names end
    end
    -- Preference 2: filesystem scan. Combine three roots:
    --   <Saved Games>\DCS\Liveries\<airframe>\
    --   <DCS install>\CoreMods\aircraft\<airframe>\Liveries\
    --   <DCS install>\Bazar\Liveries\<airframe>\
    -- Use lfs.dir on each; collect unique subdirectory names.
    -- (Use the existing paths.lua + lfs require pattern; see paths.lua for examples.)
    --
    -- If both fail, return an empty table → form falls back to free-text EditBox
    -- (build_widgets detects empty livery list at first repopulate_combo and
    -- swaps the ComboList for an EditBox; the apply path treats EditBox text
    -- as the livery_id verbatim).
    return {}
end
```

**_apply:**

```lua
function M._apply(entities, livery, categories)
    if type(entities) ~= 'table' or #entities == 0 then
        return { changed=0, failed=0, not_applicable=0, changed_rows={},
                 nothing_selected=true, toast='Nothing selected', sev='warning' }
    end
    if type(livery) ~= 'string' then
        return { changed=0, failed=0, not_applicable=0, changed_rows={}, toast='Pick a livery', sev='warning' }
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
                -- already at target; silent skip (no separate counter for this form)
            else
                local p_ok, res = pcall(verbs.unit_set_livery, { id = u.unitId, livery = livery })
                if not p_ok then failed = failed + 1
                elseif type(res) ~= 'table' or not res.ok then failed = failed + 1
                else changed_rows[#changed_rows + 1] = { unit = u, old = old } end
            end
        end
    end
    if #changed_rows > 0 then undo.record_generic('mass_edit.set_livery_unit', { rows = changed_rows }) end
    local result = { changed=#changed_rows, failed=failed, not_applicable=not_applicable, changed_rows=changed_rows }
    if #changed_rows == 0 and failed == 0 and not_applicable > 0 then
        result.toast = 'Nothing applicable'; result.sev = 'warning'
    elseif #changed_rows == 0 and failed > 0 then
        result.toast = string.format('0 livery set · %d failed', failed); result.sev = 'error'
    elseif #changed_rows == 0 then
        result.toast = 'No changes'; result.sev = 'warning'
    else
        local toast = string.format('%d livery set', #changed_rows)
        if not_applicable > 0 then toast = toast .. string.format(' · %d not applicable', not_applicable) end
        if failed > 0 then toast = toast .. string.format(' · %d failed', failed) end
        result.toast = toast; result.sev = (failed == 0 and 'success') or 'warning'
    end
    return result
end
```

**Undo:** restores via `verbs.unit_set_livery({ id, livery = r.old })`.

**Widget arrangement:** `Livery:` label + ComboList (populated by `repopulate_combo`) + `Set` button. Single row. If `liveries_for(airframe)` returns empty for the dominant airframe, the form mounts an EditBox in place of the ComboList — the apply callback reads either widget interchangeably (the EditBox is a fallback used when no enumeration is available).

**Test specifics:**

- 1. Module exports including `applies_to = { plane=true, helicopter=true }`.
- 2. Empty → nothing_selected.
- 3. Missing livery (nil) → toast='Pick a livery'.
- 4. 2 planes (same type), success → 2 verb calls, undo recorded.
- 5. 1 plane + 1 tank → tank counted as not_applicable, plane gets verb call, toast='1 livery set · 1 not applicable'.
- 6. Already-at-target plane → silent skip; toast='No changes' sev='warning'.
- 7. Verb rejection → failed counted, sev='error'.
- 8. Undo restores via verb with old livery_id.
- (UI-level gating — distinct_airframes > 1 → grayed — is not unit-tested; it's part of the panel's `set_enabled` and gets smoke-tested.)

**Commit message:**

```
feat(me-mod): set_livery_unit form + undo + airframe gating

Combo + Apply: sets u.livery_id on every checked plane/helo via
verbs.unit_set_livery. Form is grayed when checked planes/helos
span > 1 airframe type (single-airframe-only policy). Livery
source resolves ME API first, filesystem scan second, free-text
EditBox fallback. Inapplicable rows (vehicles/ships/etc.)
silently counted as not_applicable per the gating rule.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 12 (parallel-eligible): set_fuel_pct_unit form

**Files:**
- Create: `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/set_fuel_pct_unit.lua`
- Test: `tools/me-mod/test/test_mass_edit_set_fuel_pct_unit.lua`

**Substitutions:**

- `<FORM_NAME>` → `set_fuel_pct_unit`
- `<FORM TITLE>` → `'Set fuel %'`
- `M.applies_to` → `{ plane = true, helicopter = true }`
- Verb: `verbs.unit_set_fuel({ id, fuel = kg })` (takes KG, not %).

**max_fuel resolution — spike first, fall back if needed:**

The implementer's first step in this task: spike the ED database to find a per-airframe `fuel_max`. Grep `MissionEditor/` (in the DCS install) for `fuel_max`, `MaxFuel`, `Database.Units`. The ME's unit panel reads it from somewhere — find that source.

```lua
-- max_fuel_for — returns numeric kg for the unit's airframe, or nil if unknown.
-- Inject in tests via M._set_max_fuel_resolver(fn) so unit tests can drive
-- both the "known" and "unknown" branches deterministically.
local _max_fuel_resolver = function(u)
    -- Default production resolver. Implementer fills this in after the spike.
    -- Common entrypoint candidates (try in order):
    --   _G.db and _G.db.Units and _G.db.Units.Planes and _G.db.Units.Planes.Plane[airframe] and .fuel_max
    --   require('Database').Units... etc.
    -- If none work, return nil → form uses the fallback path.
    local airframe = u and u.type
    if not airframe then return nil end
    do
        local ok, val = pcall(function()
            local db = _G.db
            local entry = db and db.Units and db.Units.Planes and db.Units.Planes.Plane and db.Units.Planes.Plane[airframe]
            return entry and tonumber(entry.fuel_max)
        end)
        if ok and type(val) == 'number' and val > 0 then return val end
    end
    do
        local ok, val = pcall(function()
            local db = _G.db
            local entry = db and db.Units and db.Units.Helicopters and db.Units.Helicopters.Helicopter and db.Units.Helicopters.Helicopter[airframe]
            return entry and tonumber(entry.fuel_max)
        end)
        if ok and type(val) == 'number' and val > 0 then return val end
    end
    return nil
end

function M._set_max_fuel_resolver(fn) _max_fuel_resolver = fn end
```

**_apply:**

```lua
function M._apply(entities, pct, categories)
    if type(entities) ~= 'table' or #entities == 0 then
        return { changed=0, failed=0, not_applicable=0, changed_rows={},
                 nothing_selected=true, toast='Nothing selected', sev='warning' }
    end
    if type(pct) ~= 'number' or pct < 0 or pct > 100 then
        return { changed=0, failed=0, not_applicable=0, changed_rows={}, toast='Enter 0-100%', sev='warning' }
    end
    local verbs = require('dcs_sms_me.verbs')
    local changed_rows, failed, not_applicable, unresolved = {}, 0, 0, 0
    for _, u in ipairs(entities) do
        if not applicability.is_applicable(M.applies_to, u, categories) then
            not_applicable = not_applicable + 1
        else
            local max_kg = _max_fuel_resolver(u)
            local kg
            if max_kg then
                kg = (pct / 100) * max_kg
            else
                -- Fallback: % of u.payload.fuel's current value. Useful for
                -- "halve current fuel" workflows even when max_fuel isn't
                -- known for the airframe.
                local cur = (u.payload and tonumber(u.payload.fuel)) or 0
                kg = (pct / 100) * cur
                unresolved = unresolved + 1
            end
            local old = (u.payload and tonumber(u.payload.fuel)) or 0
            local p_ok, res = pcall(verbs.unit_set_fuel, { id = u.unitId, fuel = kg })
            if not p_ok then failed = failed + 1
            elseif type(res) ~= 'table' or not res.ok then failed = failed + 1
            else changed_rows[#changed_rows + 1] = { unit = u, old_kg = old } end
        end
    end
    if #changed_rows > 0 then undo.record_generic('mass_edit.set_fuel_pct_unit', { rows = changed_rows }) end
    local result = { changed=#changed_rows, failed=failed, not_applicable=not_applicable,
                     unresolved=unresolved, changed_rows=changed_rows }
    if #changed_rows == 0 and failed == 0 and not_applicable > 0 then
        result.toast = 'Nothing applicable'; result.sev = 'warning'
    elseif #changed_rows == 0 and failed > 0 then
        result.toast = string.format('0 fuel set · %d failed', failed); result.sev = 'error'
    else
        local toast = string.format('%d fuel set', #changed_rows)
        if not_applicable > 0 then toast = toast .. string.format(' · %d not applicable', not_applicable) end
        if unresolved > 0 then toast = toast .. string.format(' · %d used current-fuel fallback', unresolved) end
        if failed > 0 then toast = toast .. string.format(' · %d failed', failed) end
        result.toast = toast; result.sev = (failed == 0 and 'success') or 'warning'
    end
    return result
end
```

**Undo:** restores via `verbs.unit_set_fuel({ id, fuel = r.old_kg })`.

**Widget arrangement:** `Fuel %:` label + EditBox (numeric, default '50') + `Apply` button right-anchored. Single row. If a future cycle adds a slider, that's a polish item.

**Test specifics:**

- 1. Module exports including `applies_to = { plane=true, helicopter=true }` and `_set_max_fuel_resolver` fn.
- 2. Empty → nothing_selected.
- 3. Invalid pct (-1, 101, nil) → toast='Enter 0-100%'.
- 4. 2 planes with stubbed resolver returning 5000 kg, pct=50 → verb calls with `fuel=2500`.
- 5. 1 plane + 1 tank with cats → tank not_applicable, plane gets verb call.
- 6. Resolver returns nil → fallback path: verb call uses `(pct/100) * u.payload.fuel`. Verify `unresolved=1`, toast includes 'used current-fuel fallback'.
- 7. Verb rejection → failed counted.
- 8. Undo restores via verb with old kg.
- Inject test resolver: `form._set_max_fuel_resolver(function(u) return 5000 end)` at top of each numeric case; reset to `function() return nil end` for fallback case.

**Commit message:**

```
feat(me-mod): set_fuel_pct_unit form (planes/helos) + undo

EditBox + Apply: takes % input (0-100), converts to kg via per-
airframe max_fuel resolved from _G.db.Units (planes + helicopters),
calls verbs.unit_set_fuel with the absolute kg. Falls back to
"% of current u.payload.fuel" when max_fuel can't be resolved for
an airframe (e.g. mod aircraft); toast surfaces fallback usage.
Resolver is injectable for testing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

---

## Task 13: Register forms in mass_edit_forms.lua + run-tests.ps1

**Files:**
- Modify: `tools/me-mod/lua/dcs_sms_me/mass_edit_forms.lua`
- Modify: `tools/me-mod/test/run-tests.ps1`

- [ ] **Step 1: Register 9 forms in `by_scope.unit`**

In `tools/me-mod/lua/dcs_sms_me/mass_edit_forms.lua`, add the 9 requires near the top (after the existing requires) and replace the empty `unit = {}` block:

```lua
local find_replace_unit_name    = require('dcs_sms_me.mass_edit_forms.find_replace_unit_name')
local add_prefix_unit_name      = require('dcs_sms_me.mass_edit_forms.add_prefix_unit_name')
local add_suffix_unit_name      = require('dcs_sms_me.mass_edit_forms.add_suffix_unit_name')
local auto_name_unit            = require('dcs_sms_me.mass_edit_forms.auto_name_unit')
local set_skill_unit            = require('dcs_sms_me.mass_edit_forms.set_skill_unit')
local set_onboard_num_unit      = require('dcs_sms_me.mass_edit_forms.set_onboard_num_unit')
local set_livery_unit           = require('dcs_sms_me.mass_edit_forms.set_livery_unit')
local set_heading_unit          = require('dcs_sms_me.mass_edit_forms.set_heading_unit')
local set_fuel_pct_unit         = require('dcs_sms_me.mass_edit_forms.set_fuel_pct_unit')
```

And replace `unit = {},` with:

```lua
    unit = {
        find_replace_unit_name,
        add_prefix_unit_name,
        add_suffix_unit_name,
        auto_name_unit,
        set_skill_unit,
        set_onboard_num_unit,
        set_livery_unit,
        set_heading_unit,
        set_fuel_pct_unit,
    },
```

Order matches the form-ordering decision in the spec (names first, then identity / pose / loadout).

- [ ] **Step 2: Add 10 test files to run-tests.ps1**

In `tools/me-mod/test/run-tests.ps1`, find the `$tests = @(...)` array and insert these 10 entries (anywhere in the array — `run-tests.ps1` just iterates):

```
'test_unit_applicability.lua',
'test_mass_edit_find_replace_unit_name.lua',
'test_mass_edit_add_prefix_unit_name.lua',
'test_mass_edit_add_suffix_unit_name.lua',
'test_mass_edit_auto_name_unit.lua',
'test_mass_edit_set_skill_unit.lua',
'test_mass_edit_set_onboard_num_unit.lua',
'test_mass_edit_set_livery_unit.lua',
'test_mass_edit_set_heading_unit.lua',
'test_mass_edit_set_fuel_pct_unit.lua',
```

Maintain alphabetical sort order — slot each entry into the existing array in alphabetical position (the array is mostly-sorted today).

- [ ] **Step 3: Add a registration test to test_mass_edit_forms.lua** (optional but flagged by airbase code review)

The airbase code review flagged that `test_mass_edit_forms.lua` doesn't assert airbase-scope registration. Take this opportunity to add unit-scope registration assertions too. Open `tools/me-mod/test/test_mass_edit_forms.lua` and add:

```lua
do
    local mef = require('dcs_sms_me.mass_edit_forms')
    local unit_forms = mef.by_scope.unit
    check('unit scope has 9 forms', type(unit_forms) == 'table' and #unit_forms == 9,
          'got ' .. tostring(unit_forms and #unit_forms or 'nil'))
    local expected_titles = {
        'Find & replace in unit names',
        'Add prefix to unit names',
        'Add suffix to unit names',
        'Auto-name units',
        'Set skill',
        'Set onboard #',
        'Set livery',
        'Set heading',
        'Set fuel %',
    }
    for i, expected in ipairs(expected_titles) do
        check('unit form #'..i..' title = '..expected,
              unit_forms[i] and unit_forms[i].title == expected,
              'got ' .. tostring(unit_forms[i] and unit_forms[i].title))
    end
    -- All unit forms must have scope='unit'.
    for i, mod in ipairs(unit_forms) do
        check('unit form #'..i..' scope=unit', mod.scope == 'unit')
    end
end
```

- [ ] **Step 4: Run the full suite to confirm everything passes**

```
cd /c/git/dcs-sms/.claude/worktrees/me-mass-edit/tools/me-mod/test
pwsh ./run-tests.ps1
```

Expected: 0 failures. All 10 new tests appear in the output and report pass.

- [ ] **Step 5: Commit**

```
git add tools/me-mod/lua/dcs_sms_me/mass_edit_forms.lua tools/me-mod/test/run-tests.ps1 tools/me-mod/test/test_mass_edit_forms.lua
git commit -m "$(cat <<'EOF'
feat(me-mod): register 9 unit-scope forms + test wiring

Wires the new unit-scope forms into mass_edit_forms.by_scope.unit
in the spec's defined order (names first, then identity / pose /
loadout). Registers 10 new test files in run-tests.ps1. Extends
test_mass_edit_forms.lua to assert unit-scope registration (9 forms,
correct titles, all scope='unit') — addresses the airbase code-
review flag that registration wasn't asserted at the test layer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Smoke checklist

**Files:**
- Modify: `docs/release-gate/me-mod-smoke.md`

- [ ] **Step 1: Append "Unit scope (v0.10.0+)" section**

At the end of `docs/release-gate/me-mod-smoke.md`, append:

```markdown
## Unit scope (v0.10.0+)

Open Mass Edit, switch to the **Unit** tab. Confirm the treeview shows
Name · Type · Category · Skill · Coalition · Group with Coalition column
tinted red/blue/neutral per the unit's group country.

### Form gating

- [ ] With zero units checked: all 9 forms in the right pane are grayed out
      (Apply buttons + inputs disabled).
- [ ] Check 1 tank: planes-only forms (Set onboard #, Set fuel %) and
      planes/helos forms (Set livery) gray out. Skill, rename forms,
      heading remain interactive.
- [ ] Check 1 plane: every form is interactive.
- [ ] Check 1 plane + 1 tank: Set livery grays out because mixed-airframe
      (1 plane vs 0 helos = 1 airframe, but if it's mixed types — gray).
      The other gated forms (fuel, onboard #) stay interactive; on Apply
      the tank is silently skipped and the toast shows "· 1 not applicable".

### Per-form happy path (one tap each)

- [ ] **Find & replace in unit names:** check 2+ units, Find="-1" Replace="-A" → names update; toast "2 renamed".
- [ ] **Add prefix:** check 2 units, Prefix="[P] " → names update; toast "2 renamed".
- [ ] **Add suffix:** check 2 units, Suffix="-Lead", Keep# OFF → names get suffix appended.
- [ ] **Auto-name:** check 3 units, Base="Falcon" Start="5" → units become Falcon-5, Falcon-6, Falcon-7.
- [ ] **Set skill:** check 2 units, pick "Excellent" → skill changes; toast "2 skill set".
- [ ] **Set onboard #:** check 3 planes (only), Start="010" → 010 / 011 / 012; click Random → all change to distinct 3-digit numbers.
- [ ] **Set livery:** check 2 planes of same airframe, pick a livery → both planes update.
- [ ] **Set heading (absolute):** check 2 units, type 90 → both units face east; close + reopen ME unit panel to confirm.
- [ ] **Set heading (delta):** with the same selection, type 45 in Delta → both units now face 135°.
- [ ] **Set fuel %:** check a plane, type 50 → toast "1 fuel set". If "used current-fuel fallback" appears, max_fuel resolver didn't recognize the airframe (file a follow-up).

### Undo

For each form above: run the apply, hit Ctrl+Z (or whatever the ME's undo key is), verify the unit reverts. Single-slot undo: only the last apply is undoable (matches existing form behavior).
```

- [ ] **Step 2: Commit**

```
git add docs/release-gate/me-mod-smoke.md
git commit -m "$(cat <<'EOF'
docs(release-gate): smoke checklist for Unit scope forms

Covers form gating (empty / mixed / single-airframe), per-form
happy path for each of the 9 new forms, and per-form undo cycle.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review (run after writing, before dispatching subagents)

**Spec coverage check** — every Decision in the spec maps to a task:

| Spec section | Task(s) |
|---|---|
| Decision 1 (form universe, 9 forms)        | 4–12 |
| Decision 2 (hybrid D applicability gating) | 1 (helper) + 3 (host observer) + 4–12 (per-form `applies_to`) |
| Decision 3 (auto-name "B" + Start at)      | 8 |
| Decision 4 (heading two-mode)              | 9 |
| Decision 5 (onboard # auto-inc + random)   | 10 |
| Decision 6 (livery single-airframe gating) | 11 |
| Decision 7 (renames skip-and-count)        | 5, 6, 7 |
| Decision 8 (form ordering)                 | 13 |
| Decision 9 (column layout B)               | 2 |
| Decision 10 (fuel % + max_fuel fallback)   | 12 |
| Decision 11 (skin reuse — no new skins)    | All form tasks (use `dtc_button`, `staticSkin_ME`, `comboListSkinNew_`) |
| Decision 12 (one `_apply` test per form)   | 4–12 + helper test in 1 |
| Decision 13 (no callsign placeholder)      | (omission — confirmed by Task 13's by_scope.unit listing 9 forms, no callsign) |

All Decisions covered.

**Placeholder scan** — search for forbidden patterns:
- "TBD", "TODO", "implement later" — none found in this plan (Decision 10's "implementer spike" is concrete: grep for fuel_max with a documented fallback path, not a TBD).
- "Add appropriate X" / "handle edge cases" — none.
- "Similar to Task N" — the form template + per-task delta pattern is explicit; subagents read both the template (canonical reference) and the task's substitutions.

**Type consistency** — verb signatures used across tasks:
- `unit_set_name({ id, new_name })` — Tasks 5, 6, 7, 8 ✓
- `unit_set_skill({ id, skill })` — Task 4 ✓
- `unit_set_livery({ id, livery })` — Task 11 ✓
- `unit_set_heading({ id, heading_deg })` — Task 9 ✓
- `unit_set_onboard_num({ id, onboard_num })` — Task 10 ✓
- `unit_set_fuel({ id, fuel })` — Task 12 ✓
- All match the verb signatures observed in `verbs.lua` (verified in this conversation).

Snapshot shapes are consistent: `{ unit, old_<field> }` for every form. Undo handlers all key on `r.unit.unitId` and pass `r.old` (or `r.old_rad` / `r.old_kg`) as the verb arg.

Panel interface (every form): `show`, `hide`, `get_height`, `set_bounds(x,y,w,h)`, `set_enabled(bool)`. Consistent across the 9 forms and matches the host's expectations in Task 3.

Form metadata (every form): `M.scope = 'unit'`, `M.title = string`, `M._apply = function`, `M.new = function`. `M.applies_to` only on the gated forms (Tasks 10, 11, 12).

**No issues found.**

---

## Done — handoff back to /write-it

Plan is complete. Per `/write-it`'s instructions, skip the Execution Handoff choice and proceed directly with **superpowers:subagent-driven-development** to execute every task. User has explicitly requested maximum parallelism: dispatch Tasks 4–12 concurrently after Phase 1 completes.
