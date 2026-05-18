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

## Future work (after PR 3)

In rough order of expected landing:

1. `mass_edit_forms/toggle_*.lua` — hidden / late activation / uncontrolled. Three-state checkbox + button.
2. `mass_edit_forms/set_frequency.lua` — number input + `Set` button. Uses `set_all` transform.
3. Then unit-scope forms (rename, find/replace in names, set skill, set callsign, set loadout, set fuel).
4. Then waypoint / zone / drawing forms.

Once enough forms have shipped and the pattern feels stable, the first release lands as `v0.10.0`. No version bump in PR 3 either — release happens after critical mass of forms are smoke-tested.

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
