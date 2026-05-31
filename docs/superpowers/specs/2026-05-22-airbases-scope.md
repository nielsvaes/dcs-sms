# Airbases scope — Mass Edit window

**Date:** 2026-05-22
**Branch:** `worktree-me-mass-edit`

## Goal

Add a new `Airbase` scope tab to the Mass Edit window that lists every map
airfield in the mission with its current coalition and (north, east) world-
plane position, lets the user check airbases in bulk (including via F10-map
marquee), and ships three forms: Set Coalition, Set Warehouse, and
Export/Import. Aim is to replace today's "click each airbase one at a time
to change coalition" workflow with a one-click bulk operation, plus surface
warehouse-pool editing (unlimited / empty per category) and disk-persisted
warehouse setups that can be saved from one airbase and splatted onto
many.

## User value

- Bulk coalition reassignment in seconds instead of one-by-one clicks
  through each airbase's properties panel.
- Per-category warehouse presets (UNLIMITED / EMPTY for Aircraft, Liquids,
  Equipment) — useful for casual training missions (everything unlimited)
  and supply-line missions (zero everything).
- A reusable, named warehouse setup ("Cold War Loadout", "Quick Patrol
  Pack") that can be exported from a hand-tuned airbase and imported onto
  any number of others in one click.
- Marquee-drag on the F10 map to select airbases by geographic region —
  matches the existing Prefab Manager UX, no second mental model.

## Scope

### In

- New scope `'airbase'` in `mass_edit.lua` — wired into `SCOPES`,
  `SCOPE_LABEL`, the per-scope state tables (`checked`, `anchor`,
  `filters`, `sort_state`, `form_panels`, `form_separators`,
  `categories`), and `SCOPE_COLUMNS`.
- New function `selection.snapshot_airbases()` (in
  `tools/me-mod/lua/dcs_sms_me/selection.lua`) — enumerates airbases via
  `Mission.AirdromeController.getAirdromes()` and reads each airbase's
  coalition from `mission.AirportsEquipment.airports[id].coalition`.
  Returns a flat array of `{ id, name, coalition, north, east }` rows.
- New columns in `SCOPE_COLUMNS.airbase`: Check / Name (180px, string) /
  Coalition (80px, string, coalition-tinted) / North (90px, number) /
  East (90px, number).
- Three new form modules under `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/`:
  - `set_coalition_airbase.lua` — ComboList (Red/Blue/Neutral) + Set button.
  - `set_warehouse_airbase.lua` — three `tri_state_button` rows (Aircraft
    / Liquids / Equipment, each LEAVE/UNLIMITED/EMPTY) + Apply button.
  - `export_import_warehouse_airbase.lua` — name input + Save (row 1),
    saved-warehouse combo + Delete + Apply (row 2). Disk-persisted.
- New constants + helper in `paths.lua`: `M.WAREHOUSES_DIR` and
  `M.ensure_warehouses()`, mirroring `PREFABS_DIR` / `ensure_prefabs`.
  Folder layout: `<Saved Games>\DCS\dcs-sms\airbase-warehouses\<name>.lua`.
- Marquee integration via `marquee_hook.subscribe(cb)` — one subscription
  per Mass Edit window (guard against double-subscribe on hot-reload via
  `W.marquee_subscribed`), callback unions detected airbases into
  `W.checked.airbase` regardless of active scope, fires
  `M.rebuild_treeview()` so the visible checkboxes update.
- New tests:
  - `test_selection_snapshot_airbases.lua` — exercises the snapshot fn
    against stubbed `Mission.AirdromeController` and
    `mission.AirportsEquipment.airports`.
  - `test_mass_edit_set_coalition_airbase.lua` — apply + undo.
  - `test_mass_edit_set_warehouse_airbase.lua` — category mapping +
    LEAVE/UNLIMITED/EMPTY semantics + undo.
  - `test_mass_edit_export_import_warehouse_airbase.lua` — file roundtrip
    via temp dir.
  - `test_mass_edit_airbase_marquee.lua` — marquee callback updates
    `W.checked.airbase` correctly.
- All new test files registered in `tools/me-mod/test/run-tests.ps1`.
- New smoke checklist item in `docs/release-gate/me-mod-smoke.md` for the
  Airbase scope (list, marquee, coalition, warehouse, export/import,
  Resource Manager refresh gotcha).

### Out

- FARPs and ships — they're units, already covered by the existing Unit
  scope. The Airbase scope is map airfields only.
- Per-airbase rename. Airbase names are fixed by the theatre map; the ME
  doesn't expose a rename in its vanilla UI either.
- Per-airbase ATC frequency editing. Useful but out of this feature's
  scope.
- Per-airbase runway / parking changes. Same reasoning.
- Subfolder hierarchy under `airbase-warehouses\`. Flat directory only.
  (Prefab Manager has folders; this can be added later if anyone asks.)
- Sharing warehouse files across users / git checkin. They live under
  Saved Games, are user-local. Cross-user sharing would be a future
  feature.

## Constraints

- **Lua 5.1.** All new code must run under Lua 5.1.
- **Pcall-guard dxgui requires.** All dxgui module requires (`ComboList`,
  `ToggleButton`, `EditBox`, etc.) are pcall-guarded so the modules load
  in test VMs.
- **Hot-reload safety.** New marquee subscription must use the same
  `mms._sms_marquee_state` table the existing prefab_manager subscription
  uses, so a `reload-me-mod` doesn't multi-subscribe.
- **W._built guard.** The Mass Edit window's `W._built` guard means
  build-time widget construction changes need the user to close + reopen
  the window. New scope tab is a build-time addition (no in-place rebuild).
- **No call to `MapWindow.setScale`.** Camera-pan only (RDP-safety, per
  existing project memory). Not directly relevant to this feature (it
  doesn't touch the camera) but recorded so future agents don't add a
  scale-on-click handler for airbases.

## Decisions

### D1. Scope name: `airbase` (singular)

Matches existing scope names (`group`, `unit`, `waypoint`, `zone`,
`drawing` are all singular). Tab label: `Airbase`. Storage keys throughout
the code use the singular form.

### D2. Treeview columns: Name / Coalition / North / East

Per user request: coalition is the property they bulk-edit; North and East
are the geographic coords (the user explicitly asked for these because
sorting by either makes regional selection by column easier than visual
F10-map hunting). Mapping: North = airdrome `x`, East = airdrome `y`,
following DCS's 2D ground-plane convention (X-axis is north-south on map
projections). If implementation reveals the axes are flipped, swap the
column-to-field mapping (the column labels stay; only the source field
changes).

### D3. Coalition form: ComboList + Apply (matching `set_country`)

Three direct-apply buttons (Red / Blue / Neutral) was the alternative —
faster (one click per bulk op vs two), and the existing coalition skins
would skin them. User picked combo for consistency with the Group scope's
`set_country` form. Familiarity wins over click count.

### D4. Warehouse form: tri-state buttons per category

Three rows (Aircraft / Liquids / Equipment), each a `tri_state_button`
with states LEAVE / UNLIMITED / EMPTY, plus an Apply button. LEAVE skips
the category (no mutation). UNLIMITED flips the matching `unlimited*`
flag(s) to true and leaves pool counts as-is. EMPTY flips the flag(s) to
false AND zeroes the pool counts. Category-to-field mapping is a module-
local constant in `set_warehouse_airbase.lua`:

- **Aircraft** → `unlimitedAircrafts` flag + zero every entry under
  `aircrafts.*.count` on EMPTY.
- **Liquids** → `unlimitedFuel` + `unlimitedAviationFuel` flags +
  `gasoline` / `diesel` / `methanol_mixture` / `jet_fuel` numeric fields
  zeroed on EMPTY. Write only over keys that already exist on the
  warehouse entry (defensive against theatre-specific schema variation).
- **Equipment** → `unlimitedMunitions` flag + zero every entry under
  `weapons.*.count` on EMPTY.

### D5. Apply button enable rule

The Apply button on Set Warehouse is disabled (greyed via skin) when all
three tri-states are LEAVE — clicking it would be a no-op. Same pattern
already used in `toggle_group_flags`.

### D6. Export/Import: disk-persisted, not in-memory clipboard

User initially might've accepted an in-memory clipboard scoped to the
window's life, but explicitly chose file-based persistence in a folder
alongside the existing `prefabs\` directory. Pros: survives DCS restart,
shareable via Saved Games copying, discoverable, deletable. Cons: needs
filesystem schema decisions (file name = warehouse name, filesystem-safe
character sanitization, overwrite confirm). The pros outweigh.

### D7. Storage path: `<Saved Games>\DCS\dcs-sms\airbase-warehouses\`

Sibling of the existing `prefabs\` directory under the same `dcs-sms\`
root. Each saved warehouse is a single `.lua` file at the top level (flat
directory — no subfolders). File name is the user-entered name, sanitized
to a filesystem-safe set (`[A-Za-z0-9 _-]`, max ~64 chars; non-conforming
chars stripped or substituted with `_`). File format: Lua source via the
existing `dcs_sms_me.serializer` module, same format family as prefabs
but containing only the airbase warehouse entry (one airbase's worth).

### D8. Marquee semantics: union, not replace

Drawing a rect on the F10 map UNIONS the detected airbases into
`W.checked.airbase` rather than REPLACING. Lets users build up multi-area
selections by drawing several rects. The existing Clear button is the
escape hatch. (DCS's vanilla map-marquee behavior is replace, but this is
a Mass Edit window concern, not a map concern — the airbases on the F10
map themselves are not "selected" in any DCS-visible sense; only the Mass
Edit treeview checkboxes flip.)

### D9. Marquee callback fires regardless of active scope

If the user marquees on the F10 map while the Group scope is mounted,
their airbase-scope checks are silently updated. Switching to the Airbase
tab later shows them already populated. The alternative — only fire when
airbase scope is active — would require the user to switch to the
airbase tab before the marquee can do anything, which is a friction we
don't want. The cost is "checks change silently while you're elsewhere",
mitigated because Clear/Invert are right there in the Airbase tab when
you arrive.

### D10. No auto-scope-switch on marquee

The marquee callback does NOT auto-switch the Mass Edit window's active
scope to airbase even if a rect contains airbases. Too magical — the user
might be deep in a Group-scope flow and not want their UI to lurch.

### D11. Tooltip on the Airbase tab advertises the marquee feature

The Airbase scope tab gets a tooltip ("Tip: drag on the F10 map to bulk-
check airbases.") since the feature is otherwise undiscoverable from the
Mass Edit UI alone. None of the other scope tabs carry tooltips today; this
is a one-off because the marquee integration is novel here.

### D12. Resource Manager auto-refresh gotcha — documented, not fixed

If the user has DCS's Resource Manager dialog open while they Apply a
warehouse change, the dialog's UI won't auto-refresh (per existing
project knowledge — this is the same gotcha the prefab placement code
deals with). Smoke-doc item flags this; no code workaround.

### D13. Undo: per-airbase snapshot, batched record

Set Coalition, Set Warehouse, and Import all snapshot the prior state
(coalition string or full warehouse entry) of every affected airbase
before mutating, then register a single batched undo entry via
`undo.record_generic`. Undo iterates the snapshot in reverse and re-
applies via the same warehouse_ops calls. Export and Delete are file-
system operations, NOT undoable (matches how prefab Save / Delete are
handled).

### D14. No new tests for the visual / chrome aspects

The new forms get behavioral tests (apply, undo, edge cases). The new
scope tab's visual appearance (it inherits the existing `dtc_tab` /
`dtc_tab_off` skin pair via the existing tab-strip code) does not get a
new test. Same rule the scope-tabs-redesign spec used (`D11` there).

## Open questions

None remaining. All design questions were surfaced and answered during
brainstorming; small implementation-time choices (exact pixel widths for
buttons, ComboList skin) are captured by existing project patterns.
