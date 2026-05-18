# ME Mass Edit — rework: immediate-action forms

**Status:** design — supersedes the action-composition design in [`2026-05-17-me-mass-edit-design.md`](2026-05-17-me-mass-edit-design.md).

**Branch:** `worktree-me-mass-edit`. The earlier design's scaffolding (property registry, plan/preview/apply pipeline, args dispatcher) is being removed in this rework.

## Motivation

The current half-built Mass Edit window models bulk editing as a *batch composer*: pick one property, pick one operation, type one args string into a generic EditBox, preview the resulting plan, click Apply. Smoke-testing surfaced that the model is harder to use than direct manipulation — the property dropdown is long, the operation dropdown is contextual, the single `args` EditBox is overloaded (`Find|Replace` for `find_replace`, just a pattern for `auto_number`, just a value for `set_all`), and the preview list adds a confirmation step that buys nothing.

We're replacing it with an *immediate-action panel*. Each individual transform lives in its own small form with its own inputs and its own button. Click the button → the change happens → the list refreshes. No plans, no preview, no Apply step.

This document describes the rework and the scope of the first PR (find-and-replace on group names).

## User flow

The target workflow is:

1. Open `DCS-SMS → Mass Edit`.
2. The entity list shows every group in the mission (filterable by name substring; no dependency on marquee selection).
3. Check the groups to operate on.
4. Locate the relevant form in the right-pane stack.
5. Fill in the form's inputs and click its button.
6. Mutation runs immediately; the list refreshes; the footer shows a toast. `Ctrl+Z` reverts.

Multi-property edits are not batched — the user repeats steps 4–6 for each form they want to run. This is intentional. The new model trades batching for immediacy.

## Interaction model

- **No dropdown for "which operation"**. The right pane shows a vertical stack of forms, all visible at once.
- **No preview list, no Apply button**. Each form has its own action button (`Rename`, `Replace`, `Set country`, etc.). Clicking it runs the mutation immediately.
- **Entity selection is via checkboxes in the left-pane list**, not via the ME's marquee tool. The list is populated from the entire mission tree.
- **Undo is per-action**. Each form pushes one undo entry on apply. `Ctrl+Z` reverts the most recent action across all forms.
- **Per-scope forms**. Each scope (group / unit / waypoint / zone / drawing) declares which forms it shows. PR 1 ships group-scope forms only; other scopes show a "No forms yet" placeholder.

## Architecture

### What stays

- `sms_window` chrome and the window lifecycle (`M.show / M.hide / M.toggle`) in `mass_edit.lua`.
- Scope tab strip across the top.
- Left pane: the Grid-based entity list with checkbox column, sortable headers, and the name-substring filter EditBox.
- `mass_edit_transforms.lua` — pure transforms (`find_replace`, `auto_number`, `set_all`, `add_prefix`, `add_suffix`, `offset`, `toggle_set`). Nothing changes here.
- `undo.lua` — generic handler bus. Each form registers its own handler under a per-form key.
- `me_refresh.lua` — group view refresh after mutation.
- `selection.lua` — but augmented (see below).

### What is removed

- `mass_edit_ops.lua` — no more `compute_plan / apply_plan` two-stage pipeline.
- `mass_edit_registry.lua` — the declarative property × operation × applies_to registry is dropped. Each form module is self-contained: it knows its target entity type, knows how to read and write its property, and knows which transform to apply.
- The property `ComboList`, operation `ComboList`, args-summary `Static`, single `set_all_edit` EditBox, and the preview `ListBox` — all gone from `mass_edit.lua`.
- The `W.source` field on the state table and the "empty-marquee mode" banner — there's no marquee dependency to track.
- `tools/me-mod/test/test_mass_edit_ops.lua` and `tools/me-mod/test/test_mass_edit_registry.lua`.

### What is added

- `dcs_sms_me/skin_helper.lua` — small shared module exporting `apply(widget, skin_name)`. Lifted from `mass_edit.lua:40-54`. Resolves `dtc_*` skins against `dtc_skins.lua` and stock skins via `Skin.<name>()`. Used by every form module and by `mass_edit.lua` itself.
- `dcs_sms_me/mass_edit_forms.lua` — loader. Maps `scope → { form_module, form_module, ... }`. For PR 1: `{ group = { find_replace_group_name } }`. Other scopes return an empty list.
- `dcs_sms_me/mass_edit_forms/find_replace_group_name.lua` — first form module, per the contract below.

### Entity pool

`selection.snapshot_drilled(scope)` currently returns the marquee selection (falling back to the whole mission when no marquee is active). Mass Edit needs the whole mission unconditionally.

Implementation: add a sibling function `selection.snapshot_mission(scope)` that always walks the full mission tree and returns the same `{ pool, parent_map, categories }` shape. `mass_edit.lua` calls this instead of `snapshot_drilled`. The existing `snapshot_drilled` and its tests are untouched (other callers — verbs, future tools — may still want marquee-aware behaviour).

The Refresh button continues to call this same function to pick up groups added or renamed via other ME actions while Mass Edit is open.

## Form module contract

Every file in `dcs_sms_me/mass_edit_forms/` exports the same shape, so adding a new form is a copy-paste-modify of an existing one.

```lua
-- mass_edit_forms/find_replace_group_name.lua
local M = {}

M.scope = 'group'                          -- which scope tab this form belongs to
M.title = 'Find & replace in group names'  -- rendered as a heading Static above the form

-- Constructor — called once at window construction time.
--   parent_raw      sms_window:raw() — for insertWidget on each child widget
--   get_checked     fn() → array of entities — closure that returns the
--                   currently-checked entities for this scope
--   on_after_apply  fn() — host callback; the form invokes it after a
--                   successful mutation so the host can refresh the entity
--                   list, refresh scope counts, and toast the footer
function M.new(parent_raw, get_checked, on_after_apply)
    -- ... build EditBox / Button widgets, insertWidget each, register
    -- ... on_change / on_click callbacks. Register undo handler at module
    -- ... load time (above this function, not inside it).

    local panel = {}
    function panel:show()                  -- setVisible(true) on every owned widget
    function panel:hide()                  -- setVisible(false) on every owned widget
    function panel:set_bounds(x, y, w, h)  -- module owns internal layout
    function panel:get_height()            -- so the host can stack forms vertically
    return panel
end

return M
```

### Layout

The form module owns its internal layout. The host (`mass_edit.lua`) gives each form a horizontal slab `(x, y, w, h)` via `set_bounds` and the module places its title, labels, inputs, and button inside it. The host stacks forms vertically by reading each form's `get_height()` and summing.

### Apply handler (inside each form)

```lua
local function on_apply_clicked()
    local entities = get_checked()
    if #entities == 0 then
        sms_window.set_status('Nothing selected', 'warning')
        return
    end

    local find    = find_box:getText()
    local replace = replace_box:getText()

    -- Iterate, transform, write. Only entities whose name actually changes
    -- are snapshotted into the undo entry — unchanged rows are no-ops and
    -- have no business in the undo stack. Writer failures are counted
    -- separately and reported in the toast.
    local changed_rows, failed = {}, 0
    for _, e in ipairs(entities) do
        local old = e.name
        local new = transforms.find_replace(old, { find = find, replace = replace })
        if new ~= old then
            local p_ok, w_ok, w_err = pcall(write_group_name, e, new)
            if p_ok and w_ok then
                changed_rows[#changed_rows + 1] = { entity = e, old = old }
            else
                failed = failed + 1
                log_warn(tostring(p_ok and w_err or w_ok))
            end
        end
    end

    if #changed_rows > 0 then
        undo.record_generic('mass_edit.find_replace_group_name', { rows = changed_rows })
    end
    on_after_apply()
    local toast = string.format('%d renamed', #changed_rows)
    if failed > 0 then toast = toast .. string.format(' · %d failed', failed) end
    local sev = (failed == 0 and 'success') or (#changed_rows == 0 and 'error') or 'warning'
    sms_window.set_status(toast, sev)
end
```

`write_group_name(entity, new_value)` is a small private function inside the form module that mirrors the write logic from the deleted `group_name` registry entry: call `Mission.renameGroup(group, value)` if `me_mission` exports it, fall back to `group.name = value` otherwise. Each future form module replicates this pattern: a small private writer that knows the right API for its property, called from the apply loop under `pcall`.

The full apply handler body is itself wrapped in an outer `pcall` so any thrown error degrades to a footer toast (`Internal error: <msg> (logged)`) rather than crashing the editor.

### Undo handler (registered at module load)

```lua
local undo = require('dcs_sms_me.undo')
undo.register_handler('mass_edit.find_replace_group_name', function(snapshot)
    for _, r in ipairs(snapshot.rows) do
        r.entity.name = r.old
    end
    return true
end)
```

After a hot-reload, the handler is re-registered at module load and the snapshot's entity references still point at the live mission tree (mutating shared state), so undo works through reloads.

## Skinning

Every visible widget must have the correct ME-theme skin applied. No form module is allowed to ship an unskinned widget.

| Widget | Skin | Notes |
|---|---|---|
| Form title heading (`Static`) | `staticSkin_ME` | Rendered above each form |
| Field labels (`Static`) | `staticSkin_ME` | "Find:", "Replace:", "Pattern:", etc. |
| `EditBox` text input | `editBoxSkin_ME` | Matches Prefab Manager name field |
| `Button` action | `dtc_button` | Matches Prefab Manager ADD / EDIT buttons |
| Separator between forms | `dtc_separator` | From `dtc_skins.lua` |

`skin_helper.apply(widget, skin_name)` is the single entry point. Failures degrade silently (the widget keeps its default skin); this matches the existing `try_skin` in `mass_edit.lua` and the equivalent in `prefab_manager.lua`.

## First-PR scope

The first PR (and only the first PR) covers:

1. **Strip** `mass_edit_ops.lua`, `mass_edit_registry.lua`, the property/operation ComboLists, the args panel `Static`, the preview `ListBox`, the single `set_all_edit` EditBox, the `Apply` button, the `recompute_plan` / `rebuild_preview` / `rebuild_property_panel` functions in `mass_edit.lua`, and the `W.source / W.plan / W.operation / W.op_args / W.property_id` state fields. Remove their positions from `relayout`. Remove `test_mass_edit_ops.lua` and `test_mass_edit_registry.lua`.
2. **Extract** `skin_helper.lua` from `mass_edit.lua:40-54`; update `mass_edit.lua` to use it.
3. **Add** `selection.snapshot_mission(scope)` as the always-whole-mission sibling to `snapshot_drilled`. Update `mass_edit.lua` to call it.
4. **Add** `mass_edit_forms/find_replace_group_name.lua` — the first form, per the contract above.
5. **Add** `mass_edit_forms.lua` — loader returning `{ group = { find_replace_group_name } }` and empty arrays for other scopes.
6. **Update** `mass_edit.lua` to mount the active scope's forms in the right pane on `M.show / on_scope_changed`, stack them vertically (using each form's `get_height`), call each form's `set_bounds` from `relayout`. Right pane displays a single `Static` reading "No forms yet for this scope" when the form list for the active scope is empty.
7. **Tests:**
    - `test_mass_edit_find_replace_group_name.lua` — covers the apply path: build mock groups via `mock_me_mission.lua`, invoke the form's apply handler with simulated input + simulated checked-entity list, assert that names are mutated, that the undo snapshot is recorded, and that calling the registered undo handler restores names.
    - `test_selection_snapshot_mission.lua` — covers the new sibling, asserts it always returns the full pool regardless of any (mocked) marquee state.
    - Widget-construction code is exercised only through manual smoke (no dxgui mock).
8. **Manual smoke**:
    - Open Mass Edit, ensure the window opens with the Group tab active.
    - Entity list shows every group in a mission with several groups.
    - Check 2-3 groups whose names contain a common substring.
    - In the Find & Replace form, type the substring in `Find` and a replacement in `Replace`, click `Replace`.
    - Verify the entity list refreshes with the new names.
    - Verify the footer toast reads `N renamed`.
    - Press `Ctrl+Z` while the window has focus — names revert.

### Visual reference (right pane, first PR)

```
┌─ Find & replace in group names ──────────────────┐
│                                                  │
│  Find:    [____________________]                 │
│  Replace: [____________________]      [Replace]  │
│                                                  │
└──────────────────────────────────────────────────┘
```

When the user clicks the Group scope tab with no matches in the list (mission has no groups), the entity list is empty. The form is still visible and clickable — the apply handler short-circuits with `Nothing selected` if `get_checked()` returns empty.

### Acceptance criteria

- Mass Edit opens, defaults to Group scope.
- Left pane lists every group in the mission, filterable by name substring.
- Right pane shows exactly one form: "Find & replace in group names".
- Every visible widget has its skin applied (visual match against Prefab Manager).
- With ≥1 group checked, `Find = "Foo", Replace = "Bar"` → every checked group whose name contains `Foo` is renamed; groups without `Foo` are untouched.
- Footer toast: `<N> renamed`.
- `Ctrl+Z` reverts the rename.
- `tools/me-mod/test/run-tests.ps1` passes with no failures.
- `mass_edit.lua` no longer references `mass_edit_registry`, `mass_edit_ops`, `W.property_id`, `W.operation`, `W.op_args`, or `W.plan`.

## PR 2: rename_group form

The second form. Uses `mass_edit_transforms.auto_number` so the user can substitute `{n}` for a 2-pad sequence number in the pattern. The form pattern is now a copy-paste of `find_replace_group_name` with adjusted apply logic and one fewer input row — this PR also validates that the form contract is stable enough to template.

**File:** `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/rename_group.lua`. Same contract as the find/replace form (`M.scope = 'group'`, `M.title = 'Rename groups'`, `M.new(parent_raw, get_checked, on_after_apply) → panel`, `M._apply(entities, pattern)`). Undo handler id: `mass_edit.rename_group`. Internal writer reuses the same Mission.renameGroup + fallback as find/replace.

**Layout (right pane, group scope, after this PR lands):**

```
┌─ Rename groups ──────────────────────────────────┐
│  Pattern:  [____________________]     [Rename]   │
│  (use {n} for sequence, e.g. "Foo-{n}")          │
└──────────────────────────────────────────────────┘
┌─ Find & replace in group names ──────────────────┐
│  Find:    [____________________]                 │
│  Replace: [____________________]    [Replace]    │
└──────────────────────────────────────────────────┘
```

Form order: rename on top, find/replace below. Registered in `mass_edit_forms.lua` as `group = { rename_group, find_replace_group_name }`.

**Apply behavior:**

- Pattern transform: `auto_number(old, { pattern = pattern, start = 1, step = 1, pad = 2, order = 'name_asc' })`. The `order = 'name_asc'` is honored inside the form's apply loop (entities are sorted by current name before assigning sequential numbers) so numbering is deterministic regardless of the left-pane sort or check order.
- Empty pattern: form returns `{ changed=0, failed=0, toast='Pattern is empty', sev='warning' }` and does not mutate. Different from find/replace (where empty Find is a no-op via the transform); rename's empty pattern would set every name to "", which is destructive.
- `{n}`-free pattern: every checked group gets the same name. Allowed — DCS auto-disambiguates name collisions inside the mission tree. Toast still reports `N renamed` with `success` severity.
- `{n}`-bearing pattern: substituted with the row index using the hardcoded pad/start/step. Padding of 2 means `01..99` then `100..`; users with >99 groups should pick a pad-tolerant pattern (e.g. `Group-{n}-x`) or accept the width step.
- Empty selection: `{ changed=0, failed=0, nothing_selected=true, toast='Nothing selected', sev='warning' }`.

**Acceptance criteria:**

- Open Mass Edit → Group tab. Rename form is visible above the Find & replace form.
- Check 3 groups. Type `Foo-{n}` in Pattern, click `Rename`. Three groups get named `Foo-01`, `Foo-02`, `Foo-03` in name-asc order. Toast: `3 renamed`.
- Click Rename with empty Pattern. Toast: `Pattern is empty` (warning). No mutation.
- Click Rename with `Foo` (no `{n}`). All three groups become `Foo` (DCS handles the collision). Toast: `3 renamed`.
- Ctrl+Z reverts the most recent rename.
- `tools/me-mod/test/run-tests.ps1` passes with the new `test_mass_edit_rename_group.lua`.

## PR 3: set_country form

The third form. First non-string property — exercises the `ComboList` widget pattern. Wraps the existing `verbs.group_set_country` so the apply path inherits all the side-effect handling (coalition flip, livery fixup, map color update, removed-from-old-country-bucket + added-to-new) the verb already does.

**File:** `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/set_country.lua`. Same contract as the other forms (`M.scope = 'group'`, `M.title = 'Set country'`, `M.new(parent_raw, get_checked, on_after_apply) → panel`, `M._apply(entities, country_name)`). Undo handler id: `mass_edit.set_country`.

**Layout (right pane stack after this PR lands):**

```
┌─ Rename groups ──────────────────────────────────┐
│  Pattern:  [____________________]     [Rename]   │
│  (use {n} for sequence, e.g. "Foo-{n}")          │
└──────────────────────────────────────────────────┘
┌─ Find & replace in group names ──────────────────┐
│  Find:    [____________________]                 │
│  Replace: [____________________]    [Replace]    │
└──────────────────────────────────────────────────┘
┌─ Set country ────────────────────────────────────┐
│  Country:  [USA              ▾]   [Set country]  │
│  (coalition will change if the country switches sides) │
└──────────────────────────────────────────────────┘
```

Loader registration: `group = { rename_group, find_replace_group_name, set_country }` — set_country at the bottom.

**Country list source.** The dropdown is populated from `me_mission.Mission.missionCountry` — the same canonical source `prefab_manager.populate_country_combo` uses. This means the list contains every country that already has at least one entity assigned somewhere in the mission. Countries not yet in the mission tree are intentionally excluded — `verbs.group_set_country` rejects them anyway (its internal `find_country_by_name` only walks the mission tree, not the full DCS country roster). Users who need to introduce a brand-new country should still do that through the ME's own group panel; Mass Edit is for bulk-editing existing assignments.

**Coalition tinting.** Each `ListBoxItem` gets a per-item skin matching its coalition: `listBoxItemCoalRedSkin` / `listBoxItemCoalBlueSkin` / `listBoxItemCoalNeutralSkin`, applied via `skin_helper.apply`. This both (a) gives a visual hint at the coalition the dropdown selection will flip the group to, and (b) survives into the `ComboList`'s closed-state rendering — fixing the "selected text invisible in closed display" rough edge that surfaced on the original v0.9 smoke (per the handoff note about ComboList's closed display using the ListBoxItem's own skin).

**Item ordering.** Alphabetical within the list. No coalition grouping or pre-sort; the per-item skin tells the user which side each country sits on.

**Apply behavior.**

- Empty selection: `{ changed=0, failed=0, nothing_selected=true, toast='Nothing selected', sev='warning' }`. No mutation.
- No country picked (selection is empty or nil): `{ changed=0, failed=0, toast='Pick a country', sev='warning' }`. No mutation.
- Per-entity apply: `verbs.group_set_country({ id = g.groupId, country = country_name })` wrapped in `pcall`.
- Verb returns `{ ok=true, no_op=true }` when the entity is already in the target country. These rows are NOT counted as changed and do NOT enter the undo snapshot — they are an `unchanged` count surfaced in the toast.
- Verb returns `{ ok=false, error=... }` (group not found, country not in mission, etc.): counted as `failed`, error logged via `log_warn`.
- Verb returns `{ ok=true }` with a real mutation: snapshot `{ entity = g, old = old_country_name }` for undo, increment `changed`.
- Toast: `N country set` (sev='success') when changed > 0 and failed == 0. Failures or unchanged rows append ` · M failed` / ` · K unchanged` as appropriate, with sev='warning' when any failed > 0 and changed > 0, 'error' when only failures, etc. When everything is `unchanged` (changed == 0, failed == 0, but selection wasn't empty), toast `Already in <country>` / sev='info'.

**Old country capture.** The verb's return table includes `previous_country` (the country name the group used to be in) and `previous_side`. The form uses `result.previous_country` to populate the undo snapshot — no pre-verb mission walk or `g.boss` reach-in needed. This is cleaner than touching the entity's internals: the verb already does the lookup, reports it back, and is the single source of truth.

**Undo handler.** Registered at module load under id `mass_edit.set_country`. On `undo.undo()`, iterates `snapshot.rows` and calls `verbs.group_set_country({ id = entity.groupId, country = old })` for each, wrapped in `pcall`. The verb handles re-flipping the coalition back. Partial failures (e.g., the original country was deleted between apply and undo) are tolerated — handler returns `true, "<n> partial failures"`.

**Tests.** `tools/me-mod/test/test_mass_edit_set_country.lua` covers: empty selection, no-country-picked, single-entity successful set + undo round-trip, multi-entity with one no-op (already in target) and one mutation, verb-rejection failure path, verb-throw failure path, module metadata. The mock_me_mission scaffold supplies countries with `boss` back-references so `g.boss.name` works in tests; `verbs.group_set_country` is stubbed in the test to record calls and return controllable results — we test the FORM's logic (counting, toast, snapshot, undo dispatch), not the verb's internals.

**Acceptance criteria.**

- Open Mass Edit → Group tab. The Set country form is visible below Find & replace.
- The country dropdown lists every country present in the mission, each tinted with the appropriate coalition (red / blue / neutral).
- The closed-state ComboList shows the selected country's name with the correct coalition tint (no blank closed display).
- Check 2 groups currently in USA. Pick "Russia" in the dropdown. Click Set country. Both groups move to Russia (and to the red coalition). Toast: `2 country set`.
- Click Set country with nothing in the dropdown picked. Toast: `Pick a country` (warning).
- Click Set country with nothing checked. Toast: `Nothing selected` (warning).
- Check a group already in Russia, pick "Russia" again, click Set country. Toast: `Already in Russia` (info or warning), no mutation.
- Ctrl+Z reverts the most recent country-change.
- `tools/me-mod/test/run-tests.ps1` passes with the new `test_mass_edit_set_country.lua`.

## PR 4: toggle_group_flags form

The fourth form. First multi-property form — exercises a tri-state control pattern across six boolean group fields. Each control writes through a verb so the verb layer stays the single source of truth for mutations.

**File:** `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/toggle_group_flags.lua`. Same contract as the other forms (`M.scope = 'group'`, `M.title = 'Visibility & control'`, `M.new(parent_raw, get_checked, on_after_apply) → panel`, `M._apply(entities, settings) → result`). Undo handler id: `mass_edit.toggle_group_flags`.

**Properties.** The six checkboxes shown on the ME's aircraft / vehicle / ship group panels, mapped to their underlying Lua fields:

| Label (form) | Lua field | Categories where ME shows it |
|---|---|---|
| Hidden on map | `hidden` | all |
| Hidden on planner | `hiddenOnPlanner` | plane / heli |
| Hidden on MFD | `hiddenOnMFD` | plane / heli |
| Game Master Only | `uncontrollable` | plane / heli / vehicle / ship |
| Uncontrolled | `uncontrolled` | plane / heli |
| Late activation | `lateActivation` | plane / heli / vehicle / ship |

**Note on `hiddenOnMFD`.** Despite our `verbs.lua` defaulting it to `{}` on group creation, the ME GUI's checkbox handler writes a plain boolean (`vdata.group.hiddenOnMFD = self:getState()` in `me_aircraft.lua:3356`). So treat it as a boolean field — overwriting the `{}` with `true`/`false` is what the ME itself does.

**Note on `uncontrollable` (Game Master Only).** Distinct from `uncontrolled`. `g.uncontrollable` is the ME's "GAME MASTER ONLY" checkbox (confirmed in `me_aircraft.lua:417`, `me_vehicle.lua:562`, `me_ship.lua:681`). `g.uncontrolled` is the separate "UNCONTROLLED" checkbox. Both fields exist on the same group dict.

**Layout (right pane stack after this PR lands):**

```
┌─ Rename groups ──────────────────────────────────┐
│  Pattern:  [____________________]     [Rename]   │
└──────────────────────────────────────────────────┘
┌─ Find & replace in group names ──────────────────┐
│  Find:    [____________________]                 │
│  Replace: [____________________]    [Replace]    │
└──────────────────────────────────────────────────┘
┌─ Set country ────────────────────────────────────┐
│  Country:  [USA              ▾]   [Set country]  │
└──────────────────────────────────────────────────┘
┌─ Visibility & control ───────────────────────────────────────┐
│ [Hidden on map —] [Hidden on planner —] [Hidden on MFD —]    │
│ [Game Master —]   [Uncontrolled —]      [Late activation —]  │
│                                                    [ Apply ] │
└──────────────────────────────────────────────────────────────┘
```

Loader registration: `group = { rename_group, find_replace_group_name, set_country, toggle_group_flags }` — toggle at the bottom of the stack.

**Three-state control.** Each property is rendered as a single `Button` (or `ToggleButton` reused as a stateful button) whose label cycles on click through three states:

| State | Label suffix | Tint skin | Semantics on apply |
|---|---|---|---|
| `LEAVE` | `—` | `dtc_button` (default grey) | Skip this property for every selected group |
| `ON` | `ON` | `dtc_button_coal_blue` (or `dtc_button_set_on`, see Decisions) | Set the field to `true` |
| `OFF` | `OFF` | `dtc_button_coal_red` (or `dtc_button_set_off`) | Set the field to `false` |

Click cycle: `LEAVE → ON → OFF → LEAVE`. Default for every property on form mount and after each successful apply is `LEAVE`. The button's full text reads e.g. `Hidden on map —` / `Hidden on map ON` / `Hidden on map OFF` so the label communicates state in addition to the tint.

If `dtc_button_set_on` / `dtc_button_set_off` skins don't already exist, the PR creates them in `dtc_skins.lua` as static-tinted variants of `dtc_button`. If suitable existing coalition-tinted skins (`dtc_button_coal_blue` / `dtc_button_coal_red`) are visually clear enough, those are reused — the choice is settled in the implementation plan after a quick visual check during widget construction.

**Apply behavior.**

- **Form-side flow.** `M._apply` takes `(entities, settings)` where `settings` is a table keyed by Lua field name with values `true` (set ON), `false` (set OFF), or absent / `nil` (LEAVE). The form's button-click handler reads each of the six state buttons, builds `settings` containing only the keys whose state is not `LEAVE`, and calls `_apply`.
- **Empty cases.**
  - `entities` empty → `{ changed=0, failed=0, not_applicable=0, nothing_selected=true, toast='Nothing selected', sev='warning' }`. No mutation.
  - `settings` empty (every property was LEAVE) → `{ changed=0, failed=0, not_applicable=0, nothing_to_apply=true, toast='Nothing to apply', sev='warning' }`. No mutation.
- **Per-entity apply.**
  - For each entity, walk the keys in `settings`. For each `(field, target_value)`:
    - If the field is not applicable to the entity's category (table below), skip it AND count this entity as `not_applicable` *for the form-level toast only* (this counter increments once per entity that hit any inapplicable field — not once per field). Do NOT abort the entity; other applicable fields on the same entity still get applied.
    - If applicable, snapshot `{ entity = e, field = field, old = <captured before mutation> }` to a flat changed-rows list, then write `e[field] = target_value` directly. The row counts toward `changed`.
  - "Captured before mutation" is the entity's current value at the moment _apply walks it, *not* a pre-loop snapshot — so two passes applying ON then OFF in quick succession both round-trip correctly. Non-boolean current values (e.g. `hiddenOnMFD`'s initial `{}` from a freshly-created group) are normalized to `false` for the snapshot so undo can restore a boolean.
  - **Direct field writes, not verb calls.** Unlike `set_country` (which routes through `verbs.group_set_country` to inherit coalition / livery / map-color side effects), the six toggle fields have no side effects beyond their own value — the corresponding verbs would be trivial passthroughs. The form writes fields directly. The new verbs added in this PR (`group_set_hidden_on_planner` etc.) exist for **CLI scripting** of these flags, not because the form needs them.

- **Applicability map** (form-side, hard-coded — mirrors the ME's per-category visibility):

  ```lua
  local APPLIES_TO = {
      hidden          = { plane=true, helicopter=true, vehicle=true, ship=true, static=true, train=true },
      hiddenOnPlanner = { plane=true, helicopter=true },
      hiddenOnMFD     = { plane=true, helicopter=true },
      uncontrollable  = { plane=true, helicopter=true, vehicle=true, ship=true },
      uncontrolled    = { plane=true, helicopter=true },
      lateActivation  = { plane=true, helicopter=true, vehicle=true, ship=true },
  }
  ```

  The form uses `e._category` (set on entities by `selection.snapshot_mission`) for the lookup. An entity whose category isn't in the inner table is skipped for that field. Static groups are accepted only by `hidden`.

- **Field write summary.**

  | Field | Form writes | Standalone CLI verb (for scripting) |
  |---|---|---|
  | `hidden` | `e.hidden = v` | `verbs.group_set_hidden` (existing) |
  | `hiddenOnPlanner` | `e.hiddenOnPlanner = v` | `verbs.group_set_hidden_on_planner` (new in this PR) |
  | `hiddenOnMFD` | `e.hiddenOnMFD = v` | `verbs.group_set_hidden_on_mfd` (new in this PR) |
  | `uncontrollable` | `e.uncontrollable = v` | `verbs.group_set_uncontrollable` (new in this PR) |
  | `uncontrolled` | `e.uncontrolled = v` | `verbs.group_set_uncontrolled` (existing) |
  | `lateActivation` | `e.lateActivation = v` | `verbs.group_set_late_activation` (existing) |

- **Toast.** Single-line summary built from the result counters:
  - All-success, nothing-not-applicable: `N flag changes` (sev=`success`). Where `N` is the count of `(entity, field)` pairs actually mutated.
  - With `not_applicable > 0` and `changed > 0`: append ` · M not applicable` (M = entities, not pairs). sev=`success`.
  - With `changed == 0, not_applicable > 0`: `Nothing applicable` (sev=`warning`).
  - There is no `failed` counter — direct field writes can't fail under normal conditions. The form module's outer `pcall` wraps the apply handler so an unexpected throw (e.g. corrupted entity table) degrades to an `Internal error (logged)` toast rather than crashing the editor.

**Undo.** Per-row snapshot: each mutated `(entity, field, old_value)` triple is appended to `changed_rows`. Undo handler iterates rows in reverse order (so multi-field changes on the same entity restore in the opposite order they applied) and writes `r.entity[r.field] = r.old` directly. This is consistent with the form's own write path; no verb roundtrip.

**Required new verbs** in `tools/me-mod/lua/dcs_sms_me/verbs.lua`:

- `group_set_hidden_on_planner(args)` — `args = { name|id, hidden=bool }`. Writes `g.hiddenOnPlanner = args.hidden`. Mirror the existing `group_set_hidden` exactly (validation, find_group_in_mission, single-field write). Return shape: `{ ok=true, id=g.groupId, name=g.name, hidden_on_planner=g.hiddenOnPlanner }`.
- `group_set_hidden_on_mfd(args)` — same shape, writes `g.hiddenOnMFD = args.hidden`. Return: `{ ok=true, id=g.groupId, name=g.name, hidden_on_mfd=g.hiddenOnMFD }`.
- `group_set_uncontrollable(args)` — `args = { name|id, enabled=bool }`. Writes `g.uncontrollable = args.enabled`. Mirror `group_set_uncontrolled`. Return: `{ ok=true, id=g.groupId, name=g.name, uncontrollable=g.uncontrollable }`.

All three follow the existing toggle-verb convention (explicit-bool arg, mutually exclusive `name`/`id`, no side effects beyond the field write — no view refresh, no coalition rewire). The form's `on_after_apply` host callback drives the `recreate_group_view` refresh once per apply, not per-verb.

**Required new CLI commands** in `tools/cmd/dcs-sms/`:

- `me_group_set_hidden_on_planner.go` — copy of `me_group_set_hidden.go` with `hidden_on_planner` naming, calls `runMeVerb("group_set_hidden_on_planner", ...)`.
- `me_group_set_hidden_on_mfd.go` — same pattern.
- `me_group_set_uncontrollable.go` — copy of `me_group_set_uncontrolled.go` with `--enabled` flag.

After adding, run `tools/dcs-sms.exe doc` to regenerate `docs/cli/`. Update the group-row in `tools/me-mod/AGENTS.md §1.4` verb table.

**Tests** in `tools/me-mod/test/test_mass_edit_toggle_group_flags.lua`:

- Module shape (`scope`, `title`, `new`, `_apply`).
- `_apply` empty selection → `nothing_selected`.
- `_apply` empty settings (all LEAVE) → `nothing_to_apply`.
- Single plane, one property ON → verb called, `changed=1`, snapshot has the row.
- Single plane, two properties (ON, OFF) → both verbs called, `changed=2`.
- Plane and vehicle, property `uncontrolled` set ON → verb called for plane only; vehicle counted as `not_applicable`.
- Plane and static, property `hidden` set ON → verb called for both; no not_applicable.
- Static and only plane-only properties → static counted as not_applicable; if it has no applicable fields and no other entity does either, `changed=0, not_applicable>0` → `Nothing applicable` toast.
- Verb returns `ok=false` → counted as `failed`; not snapshot-included.
- Verb throws → counted as `failed`; logged via `log_warn` (stub).
- Undo handler called against a snapshot of 3 rows mixing `hidden`/`uncontrolled`/`lateActivation` → reverse-order verb calls restore old values. Partial-failure case: 2 ok, 1 throws → handler returns `true, "1 partial failures"`.

The verb-stub pattern matches `test_mass_edit_set_country.lua`: monkey-patch `verbs.group_set_hidden_on_planner` (etc.) on `require('dcs_sms_me.verbs')` to record calls and return controllable results.

**Acceptance criteria.**

- Open Mass Edit → Group tab. The Visibility & control form is visible at the bottom of the right pane.
- Form shows 2 rows × 3 columns of state buttons, all defaulting to `—` (LEAVE).
- Clicking a state button cycles `— → ON → OFF → —` with the label suffix and tint updating each click.
- Apply with nothing checked → toast `Nothing selected` (warning).
- Apply with everything at LEAVE → toast `Nothing to apply` (warning).
- Check 2 plane groups. Set `Hidden on map` to ON. Apply. Both groups' `hidden = true`. Toast: `2 flag changes`. Map markers disappear (host's `recreate_group_view` ran).
- Check the same 2 planes. Set `Hidden on map` to OFF. Apply. Markers return.
- Check 1 plane + 1 vehicle. Set `Uncontrolled` to ON. Apply. Plane's `uncontrolled = true`; vehicle untouched. Toast: `1 flag changes · 1 not applicable`.
- Check 1 static group. Set `Hidden on map` to ON + `Uncontrolled` to ON. Apply. Static's `hidden = true`; `uncontrolled` skipped. Toast: `1 flag changes · 1 not applicable` (the static, hit by an inapplicable field).
- Ctrl+Z after a multi-field apply reverts all changes from the most recent apply (multi-row snapshot).
- After a successful apply, all state buttons reset to LEAVE.
- `tools/me-mod/test/run-tests.ps1` passes with the new tests.

## Decisions (PR 4)

Best-judgement calls made autonomously and recorded here so they can be revisited if needed:

- **Single form, six tri-state buttons in 2×3** rather than per-property mini-forms. Fewer widgets, naturally grouped, one click per property to set state then one Apply for all. Chosen during brainstorming.
- **Tri-state control = single cycling button** (label suffix `—`/`ON`/`OFF` + color tint) rather than a horizontal trio of radio-style toggles or a combobox. Most compact for the 2×3 grid; clear affordance because the label IS the button.
- **Initial state always LEAVE on every mount and after every apply.** The form does NOT inspect the current selection to pre-fill checkboxes. Rationale: matches existing forms (Rename's input starts empty, Set country's combo unselected), simpler implementation, no need to refresh state when checked-set changes. Future enhancement could add a "reflect selection" mode but it's out of scope here.
- **Applicability handling = skip-and-report.** Inapplicable (field, entity) pairs are silently skipped; the *entity* is counted toward `not_applicable` once if any of its fields were skipped. Toast surfaces the count. Alternative ("reject whole batch") rejected as too restrictive for mixed-category selections.
- **Per-property applicability is hard-coded** in the form module (the `APPLIES_TO` table), not introspected from the ME. Trade-off: simpler, but tight coupling to ED's per-category visibility rules. If ED changes (e.g., adds `hiddenOnPlanner` to vehicles), the table needs an update. Acceptable — this set of fields has been stable since at least DCS 2.5.
- **New verbs follow the existing toggle convention** (`hidden_on_planner`/`hidden_on_mfd` take `args.hidden`; `uncontrollable` takes `args.enabled`). Naming asymmetry is preserved to match the existing pattern (`group_set_hidden` uses `hidden`, `group_set_uncontrolled` uses `enabled`).
- **Verb-pair completeness:** Lua verbs + Go CLI + doc updates land in the same PR. Skipping the Go side would leave 3 Lua-only verbs and break the consistent verb table; not worth the inconsistency to save ~30 min of boilerplate. These verbs exist for **CLI scripting** of the same flags — they are not called by the toggle form itself.
- **Form writes fields directly**, NOT through the new verbs. Departs from `set_country`'s verb-roundtrip pattern because the toggle verbs are trivial passthroughs (`g.field = value` with no side effects) — routing through them is overhead with no functional gain. The verbs exist for the CLI surface; the form has no reason to call them. Undo also writes fields directly for the same reason.
- **Group view refresh:** the form's `on_after_apply` callback drives `me_refresh.refresh_group_view` (lightweight) per entity. The heavyweight `recreate_group_view` is unnecessary here — these flags don't affect category, coalition, or unit composition, just visibility. Empirical verification belongs in smoke; if a flag like `lateActivation` does affect rendering (deferred icons), fall back to `recreate_group_view`.
- **State-button skin:** prefer reusing `dtc_button` (default) for LEAVE and either existing `dtc_button_coal_red/blue` skins or new `dtc_button_set_on/off` static-tinted variants for ON/OFF. The implementation plan picks one after a quick check of `dtc_skins.lua` — does not block the design.
- **No "Apply all six" shortcut button** in v1 (e.g. "Hide everywhere"). YAGNI; users can cycle three buttons faster than they'd find such a shortcut.

## Future work (after PR 4)

In rough order of expected landing:

1. `mass_edit_forms/set_frequency.lua` — number input + `Set` button. Uses `set_all` transform.
2. Then unit-scope forms (rename, find/replace in names, set skill, set callsign, set loadout, set fuel).
3. Then waypoint / zone / drawing forms.
4. Possible polish on `toggle_group_flags`: per-property applicability greyout when the current checked-set has no applicable groups for a property.

Once enough forms have shipped and the pattern feels stable, the first release lands as `v0.10.0`. No version bump in PR 4 either — release happens after critical mass of forms are smoke-tested.

## Decisions (PR 3)

Best-judgement calls made autonomously and recorded here so they can be revisited if needed:

- **Country list source = `Mission.missionCountry`** (not the full DCS roster). Matches what `verbs.group_set_country` will actually accept; introducing a brand-new country still goes through the ME's own group panel.
- **No Combat/All filter toggle** (unlike prefab_manager). Mass Edit shows all coalitions including neutrals — fewer widgets, more discoverable.
- **Coalition tinting via per-item skins** (`listBoxItemCoal*Skin`). Doubles as a visual cue AND solves the "closed-display blank" rough edge.
- **Items sorted alphabetically**, not grouped by side. The tint communicates side; grouping is redundant.
- **No-op (already in target country) is its own outcome** — counted separately from `changed` and `failed`, surfaced in the toast as ` · K unchanged` or, when the whole batch is no-ops, `Already in <country>`.
- **Undo via the verb** (`verbs.group_set_country` with the old country) rather than direct field assignment. Keeps the verb as the single source of truth for the mutation + side effects (livery fixup, coalition flip, map color, etc.).
- **Form position: bottom of the group-scope stack.** rename (most active) → find/replace → set_country (least frequently used).

## Versioning

This rework lands across multiple PRs on `worktree-me-mass-edit`. No `version.lua` bump in PR 1; `CHANGELOG.md` is not touched until release. When the worktree is judged ready (find/replace + rename + at least set_country working end-to-end + smoke checklist green), a single release PR bumps `version.lua` to `0.10.0` and writes the changelog entry.

The `docs/release-gate/me-mod-smoke.md` Mass Edit section is rewritten in PR 1 to reflect the new model (find/replace only at first; later PRs append their own checks).

## Logging

All form-side log calls use `log.write('sms.me.mass_edit', log.<level>, msg)`, matching the existing taxonomy. Per-form sub-tags optional (`sms.me.mass_edit.find_replace_group_name`).

## Error handling

The contract for each form's apply handler:

- `get_checked()` returns empty → set footer toast `Nothing selected`, return without mutation.
- A writer throws → caught by an outer `pcall` in the apply loop; that row is skipped, error logged, count of failures included in the toast (`N renamed · M failed`).
- Outer `pcall` around the entire apply handler so a thrown error degrades to `Internal error: <msg> (logged)` rather than crashing the editor.

## Out of scope for this design

- Multi-property batching (a form that sets name AND country AND frequency at once). Intentionally not supported; user runs forms one at a time.
- Preview / dry-run mode. Intentionally not supported.
- Undo redo (`Ctrl+Shift+Z`). Existing undo bus has no redo; out of scope.
- Form ordering customisation by user. Forms are listed in `mass_edit_forms.lua` in a fixed order per scope.
