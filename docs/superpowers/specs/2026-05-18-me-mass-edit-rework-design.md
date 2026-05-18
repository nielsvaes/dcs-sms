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

## Future work (not in PR 1)

In rough order of expected landing:

1. `mass_edit_forms/rename_group.lua` — pattern-based rename with `auto_number` transform. Inputs: pattern text box (placeholder hint `use {n} for sequence`). Button: `Rename`. Hard-coded `start=1, step=1, pad=2, order=name_asc` to keep the form one-row; if anyone needs configurable start/step/pad later, those become additional fields in this same form.
2. `mass_edit_forms/set_country.lua` — country combo with values from a country list; button: `Set country`. Uses `verbs.group_set_country` (already exists, already has undo support).
3. `mass_edit_forms/toggle_*.lua` — hidden / late activation / uncontrolled. Three-state checkbox + button.
4. `mass_edit_forms/set_frequency.lua` — number input + `Set` button. Uses `set_all` transform.
5. Then unit-scope forms (rename, find/replace in names, set skill, set callsign, set loadout, set fuel).
6. Then waypoint / zone / drawing forms.

Once enough forms have shipped and the pattern feels stable, the first release lands as `v0.10.0`. No version bump in PR 1 — this is destructive and incomplete; release happens after critical mass of forms are smoke-tested.

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
