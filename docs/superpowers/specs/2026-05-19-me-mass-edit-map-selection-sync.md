# ME Mass Edit — map selection sync (group scope)

**Status:** design
**Branch:** `worktree-me-mass-edit`
**Supersedes / extends:** Mass Edit rework series (PR 1–4).
This is a small follow-up that adds two map-sync buttons to the Group-scope
left pane. It does not change any form behavior.

## Goal

Let the user shuttle a group selection between the ME map and the Mass Edit
window's left-pane checkboxes, in both directions, via two explicit buttons.

## User value

The Mass Edit window already supports building a selection by clicking
checkboxes, shift-click range select, name-filter + Select all / Invert /
Clear. That works well for filter-driven selections ("all Su-25s").

It does not work well for spatial selections ("everything inside this strip
of airbases"). The ME's existing marquee tool excels at spatial selection,
but its result lives on the map, not in Mass Edit. Two manual buttons bridge
that gap:

- **From map:** marquee a region on the map → click `From map` → those
  groups are now checked in Mass Edit, ready for a form action.
- **To map:** check groups in Mass Edit (by filter, by shift-click range,
  by manual click) → click `To map` → the same groups are now marqueed on
  the map, ready for any ME-native operation that operates on the current
  selection (e.g. Ctrl+C copy).

We deliberately avoid any continuous / live-sync model — see the Decisions
section for why.

## Scope

### In scope (v1)

- Two new buttons in the bulk-selection strip on the Mass Edit window:
  `From map` and `To map`.
- Buttons are **Group scope only**. On other scope tabs they are absent.
- Both buttons use **Replace** semantics (see Decisions).
- Read side: reuse the existing `selection.snapshot()`, which already
  handles single-mode and multi-mode and statics-as-groups.
- Write side: new module `me_select_writer.lua` that isolates the
  ME-internal write logic and exposes a clean Lua API.
- Toasts via the existing `sms_window` status mechanism for empty /
  partial / failure cases.
- New smoke checklist subsection under `docs/release-gate/me-mod-smoke.md`
  § Mass Edit.

### Out of scope

- Continuous / live mirror mode. Explicitly removed during brainstorming
  after the user identified the manual-edit-during-mirror UX cliff.
- Sync for any scope other than `group`. The ME map does not select units
  or waypoints directly, and the user wants to keep the v1 surface small.
- Zone / drawing scope sync. The map can select these, but Mass Edit has
  no forms for them yet, so there's no value yet.
- Any change to existing forms, the entity tree, or the right pane.
- New CLI verbs. This is an in-ME-only feature.

## Constraints

- Must follow the **reload-safe** monkey-patch pattern in
  `marquee_hook.lua` if `me_select_writer.lua` needs to patch ME internals.
  State lives on the patched module, not in module-locals.
- Must NOT break the existing `MapWindow.unselectAll()` usage in
  `verbs._save_mission_with_reopen_dance` (file save). Whatever the writer
  does, the save path's pre-save `unselectAll` must still work afterwards.
- Lua 5.1 — no `goto`-only syntax, no integer division operator.
- Tests live under `tools/me-mod/test/` and run via
  `tools/me-mod/test/run-tests.ps1`. Real `lua5.1.exe` is at
  `/c/Users/Niels/bin/lua51/lua5.1.exe`; not on PATH.
- All ME-internal API calls (`MapWindow.*`, `me_multiSelection.*`,
  `Mission.*`) must be `pcall`-wrapped. A breaking DCS patch should
  degrade to a toast, not a crash.
- The Group-scope entity refs in `W.pool` come from
  `selection.snapshot_mission`, which uses `Mission.getGroup(id)`. The
  refs returned by `selection.snapshot()` come from the same call. They
  are identity-equal — `W.checked[W.scope][group_ref]` lookups work
  directly without an id translation step.

## Decisions

These were made during the brainstorming dialogue. They are settled — no
re-litigation in the plan or implementation.

### D1. Two-button model, no continuous sync

Original idea was hybrid (continuous map→ME + manual ME→map button). User
pulled back to two explicit buttons after we identified that "what happens
to manual checkbox edits while mirror is running?" is a UX cliff with no
clean answer (overwrite-on-poll punishes mis-toggles; smart-diff is
complex; bidirectional-on-toggle contradicts the original "explicit push"
intent). Two buttons sidestep the problem entirely.

### D2. Group scope only

User: "we're not dealing with anything but groups for the moment." Buttons
are absent (not just disabled) on Unit / Waypoint / Zone / Drawing tabs.

### D3. Replace semantics on both directions

- `From map` replaces `W.checked.group` with the current map selection
  (intersected with `W.pool` so out-of-pool refs are silently dropped).
- `To map` calls `unselectAll` first, then selects exactly the checked
  groups.

Rationale: matches the button names literally. Additive variants can be
added later if a use case emerges; they were explicitly considered and
rejected for v1.

### D4. Anchor cleared on fetch, preserved on push

- `From map`: the shift-click anchor (`W.anchor.group`) is set to `nil`
  because it pointed into the old selection state.
- `To map`: no change to `W.checked` or `W.anchor`.

### D5. Empty-input behavior

- `From map` with an empty map selection: toast `Map selection empty`,
  severity `warn`. Checkboxes unchanged. **Do not wipe** the user's
  existing checkboxes on an empty map — the user almost certainly didn't
  mean to clear.
- `To map` with no checkboxes: toast `Nothing checked to push`, severity
  `warn`. **Do not call `unselectAll`** — clearing the map on a no-op
  click would be surprising.

### D6. Failure budget for write API

The ME-internal write API for multi-selection is not yet known with
certainty. Plausible paths:

1. A function inside `me_multiSelection.lua` that the marquee handler
   calls to add a group to `selectGroups` — call it directly per group.
2. Direct mutation of `selectGroups` (and possibly the rendering hook,
   e.g. `MapWindow.show()` or a redraw call) — riskier but doable.

Implementation reconnaissance happens during the first writer task. If
both paths fail, ship the `To map` button **disabled, with a tooltip
explaining why**, and file an issue. `From map` is independent and ships
either way.

### D7. Module split

- `mass_edit.lua` — gets the two new button widgets, two new handlers,
  layout extension. No writer logic.
- `me_select_writer.lua` — new module. Public surface:
  `M.set_group_selection(group_refs) → { ok, error?, count }`. All
  ME-internal write logic lives here. Mirrors how `selection.lua`
  isolates the read side.
- `selection.lua` — unchanged. `snapshot()` already returns the data the
  fetch path needs.
- `me_refresh.lua` — only touched if the writer needs a redraw helper
  beyond what `MapWindow.show()` does. Probably not.

### D8. Button labels and placement

Labels: `From map` and `To map`. Two extra entries appended to the
existing bulk-selection strip, right-aligned to the tree's right edge:

```
[ Select all ] [ Invert ] [ Clear ]   [ From map ] [ To map ]
```

Width 70px each (matches existing bulk buttons). Same `dtc_button` skin.
On non-group scopes the buttons are not inserted at all (cleaner than
visible-but-disabled, and the strip just shows the original three).

### D9. Toast wording

Successful:
- `Fetched N groups from map`
- `Pushed N groups to map`

Edge / failure:
- `Map selection empty` (warn) — empty fetch
- `Nothing checked to push` (warn) — empty push
- `Fetched N; M map groups not in current pool` (warn) — partial fetch
- `Failed to read map: <err>` (err) — `selection.snapshot` returned `ok = false`
- `Failed to push: <err>` (err) — writer returned `ok = false`. Map may
  already be in a partially-cleared state because we ran `unselectAll`
  before the per-group selects.

### D10. Smoke checklist

Adds a new "Map selection sync" subsection under
`docs/release-gate/me-mod-smoke.md` § Mass Edit with the six scenarios
listed in the brainstorming session.

## Architecture

### Read path (From map button)

```
on_fetch_from_map():
  snap = selection.snapshot()
  if not snap.ok: toast(err, 'err'); return
  if #snap.groups == 0: toast('Map selection empty', 'warn'); return

  in_pool = { [e] = true for e in W.pool }
  new_checked = {}
  missed = 0
  for g in snap.groups:
    if in_pool[g]:
      new_checked[g] = true
    else:
      missed = missed + 1

  W.checked.group = new_checked
  W.anchor.group = nil
  M.rebuild_treeview()

  count = #new_checked
  if missed > 0:
    toast(f'Fetched {count}; {missed} map groups not in current pool', 'warn')
  else:
    toast(f'Fetched {count} groups from map', 'info')
```

### Write path (To map button)

```
on_push_to_map():
  checked = get_checked_for_active_scope()  -- group refs
  if #checked == 0: toast('Nothing checked to push', 'warn'); return

  result = me_select_writer.set_group_selection(checked)
  if not result.ok: toast(f'Failed to push: {result.error}', 'err'); return

  toast(f'Pushed {result.count} groups to map', 'info')
```

### Writer module (me_select_writer.lua)

Public:

```
M.set_group_selection(group_refs) -> { ok = bool, count = N, error? = string }
```

Behavior:
1. `pcall(MapWindow.unselectAll)` — clears `selectedGroup` / `selectedUnit`
   in single mode and the multi-selection state in multi mode (the same
   call the file-save flow uses).
2. Open / activate multi-selection mode if it's not already active. This
   is what the marquee tool does; the exact API call is the part needing
   recon (see D6).
3. For each group ref in input, add it to `multiSelection.getSelectedObjects().selectGroups`
   keyed by `group.groupId`. The exact mechanism (named ME function vs
   direct table mutation + redraw) is decided during recon.
4. Trigger a map redraw if step 3 doesn't already do so (likely
   `MapWindow.show()` or equivalent).
5. Return `{ ok = true, count = #group_refs }`.

All steps `pcall`-wrapped. Any failure returns `{ ok = false, error = ... }`.

If the writer cannot achieve step 2 or 3 after recon, expose a sentinel:

```
M.available = false   -- when ME internals don't permit programmatic write
```

`mass_edit.lua` reads this at button-build time; when `false`, the `To map`
button is inserted **disabled with a tooltip** `Map write API unavailable in this DCS build`.

### Layout changes in mass_edit.lua

`relayout`:
- `sel_total_w` becomes `sel_btn_w * N + L.GAP * (N - 1)` where `N = 5` for
  group scope, `N = 3` otherwise. Right-edge anchoring unchanged.
- `set(W.widgets.from_map_btn, sel_x + (sel_btn_w + L.GAP) * 3, sel_strip_y, sel_btn_w, L.BTN_H)`
- `set(W.widgets.to_map_btn,   sel_x + (sel_btn_w + L.GAP) * 4, sel_strip_y, sel_btn_w, L.BTN_H)`

`build_window`:
- Construct both buttons via `make_bulk_btn` (same skin / size as the
  existing three).
- Store in `W.widgets.from_map_btn` / `W.widgets.to_map_btn`.

Per-scope visibility: hide via `pcall(widget.setVisible, widget, false)` in
`on_scope_changed` when scope != group; show when scope == group. The
relayout already handles their positions when visible.

## Testing

### Unit tests

New file `tools/me-mod/test/test_me_select_writer.lua`:
- Stubs `me_map_window` (`unselectAll`) and `me_multiSelection`
  (`isVisible`, `getSelectedObjects`, plus whichever activation call is
  used by the impl).
- Verifies the call sequence: `unselectAll` runs first; multi-mode
  activated; selected groups populated.
- `set_group_selection({})` returns `{ ok = true, count = 0 }` without
  calling `unselectAll`.
- `MapWindow.unselectAll` throws → returns `{ ok = false, error = ... }`.
- The `M.available = false` path is exercised by setting the sentinel
  manually and re-requiring (or by a `M._set_available_for_tests` helper).

Extend `tools/me-mod/test/test_mass_edit.lua` (or add a new
`test_mass_edit_map_sync.lua` if the existing file is large):
- `on_fetch_from_map`: empty snap → toast warn, checkboxes untouched.
- `on_fetch_from_map`: snap returns 3 groups all in pool → 3 checked,
  anchor cleared, toast info.
- `on_fetch_from_map`: snap returns 3 groups, 1 not in pool → 2 checked,
  toast warn with "1 not in pool" wording.
- `on_push_to_map`: no checkboxes → toast warn, writer not called.
- `on_push_to_map`: writer ok → toast info with count.
- `on_push_to_map`: writer fails → toast err.
- Scope switch hides the buttons; switching back shows them.

### Smoke checklist (live DCS)

Add a `Map selection sync` subsection to
`docs/release-gate/me-mod-smoke.md` § Mass Edit:

1. Open Mass Edit on Group tab. Select 3 groups on the map (marquee).
   Click `From map` → those 3 are checked, toast `Fetched 3 groups from map`.
2. Uncheck one, check two new ones (now 4 checked). Click `To map` → the
   4 checked groups are now marqueed on the map; right-side group panel
   reflects the new selection; toast `Pushed 4 groups to map`.
3. Switch to Unit tab → both `From map` and `To map` are gone (only the
   3 bulk buttons remain). Switch back to Group → both reappear.
4. Empty map selection + `From map` → toast `Map selection empty`,
   checkboxes unchanged.
5. Empty checkboxes + `To map` → toast `Nothing checked to push`, map
   selection unchanged (verify by selecting a group on the map first,
   then clearing in Mass Edit, then pushing — the original map
   selection must still be there).
6. Hot-reload via `dcs-sms.exe reload-me-mod` while the window is open
   → both buttons still work; writer state survives.

## Implementation outline

1. **Recon** — read `me_multiSelection.lua` source (it's required at
   `marquee_hook.lua:27`, so the ME has it loaded). Find the function the
   marquee path uses to add a group to `selectGroups`. Document the API
   choice in a top-of-file comment in `me_select_writer.lua`.
2. **`me_select_writer.lua`** — implement `set_group_selection` using the
   reconned API. Tests cover the writer in isolation with stubs.
3. **`mass_edit.lua`** — add the two buttons, handlers, layout, scope
   visibility. Tests cover the handlers with stubs for
   `selection.snapshot` and `me_select_writer`.
4. **Smoke checklist** — append the subsection to `me-mod-smoke.md`.

Each step gets its own commit, following the existing branch's per-feature
commit cadence.

## Open questions

None. Implementation recon (D6 / D7 / writer module) handles the only
remaining unknown.
