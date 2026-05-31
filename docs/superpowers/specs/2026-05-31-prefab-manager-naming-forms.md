# Prefab Manager — placement-time naming forms + right-column layout

**Date:** 2026-05-31
**Status:** approved (autonomous flow under `/write-it`)
**Worktree:** `worktree-prefab-mgr-naming-forms`

---

## Goal

Add three placement-time naming forms (Name, Prefix, Suffix) to the Prefab Manager window, reusing the Mass Edit form-apply logic verbatim, and reflow the bottom-right of the window into a vertical "controls" stack so the place buttons can remain side-by-side and the new forms fit cleanly without making the window wider.

## User value

Right now, placing a prefab gives you whatever names the prefab was distilled with. If you place a CAP prefab three times in a mission you get `Viper-1`, `Viper-1#001`, `Viper-1#002` (DCS's auto-disambiguation), and the unit names inside drift further out of sync each round. The user has to switch to Mass Edit, find each freshly-placed group, run rename/prefix/auto-name-units one at a time — friction that scales linearly with how many copies they place.

With this feature, the user fills three sticky text fields once (Name, Prefix, Suffix), then every subsequent placement of any prefab applies those renames automatically — to all groups, statics, zones, and drawings the prefab contains — and re-runs Auto Name Units on every group so unit names stay coherent with their group names. Bulk-placement workflows that previously required dozens of Mass Edit clicks become "drag the splitter, type a name pattern with `{n}`, click Place at click N times."

## Scope

### In scope

1. **Layout refactor of the Prefab Manager window:**
   - Draggable vertical splitter between the folder tree (left column) and the file grid (right column), reusing `dcs_sms_me.splitter` (the module Mass Edit already uses).
   - The existing bottom strip (Country, Combat toggle, Rotation, Place buttons) MOVES from full-window-width to right-column-only — anchored to the right of the splitter, vertically stacked.
   - Three new naming-form rows (Name, Prefix, Suffix) inserted between Rotation and Place buttons.
   - `[Reload][Undo last placement][Rename][Delete]` row stays where it is (just below the grid). The new right-column stack starts BELOW that row.
   - Folder tree + file grid stay the same height as today (their bottom Y is the same — the right column simply extends further DOWN past the grid bottom to host the new content; the left column terminates at the existing `[+New folder][Show all]` row).
   - Window minimum width drops (from 760 to ~560) because side-by-side place buttons no longer need to fit beside Rotation widgets at full-window width.
   - Window minimum height grows (from 460 to ~580) to accommodate the new vertical stack.

2. **Three new sticky form widgets** added to `prefab_manager.lua`:
   - `Name:` — single text input.
   - `Prefix:` — single text input.
   - `Suffix:` — text input + `[Keep Num]` toggle (default ON, mirrors Mass Edit's `add_suffix_group_name`).
   - All three use `dcs_sms_me.clearable_edit` (the X-button-cleared EditBox Mass Edit uses).
   - No "Apply" buttons. Values are read at placement time. Values persist across placements within a session.

3. **New `dcs_sms_me.prefab_naming` module** — pure logic, no dxgui:
   - `prefab_naming.apply(rec, opts)` runs the naming pipeline against a placement record and returns an aggregate result table.
   - `prefab_naming._compute_targets(rec, opts)` is the test-only dry-run that returns planned `{entity, old, new}` triples without writing.
   - Delegates to Mass Edit's existing `_apply` functions: `rename_group._apply`, `add_prefix_group_name._apply`, `add_suffix_group_name._apply`, `auto_name_units_group._apply`. Mass Edit form modules are NOT modified.

4. **Placement-pipeline integration** — both placement paths (`Place at original location` and the map-click handler inside `enter_place_pending`) call `prefab_naming.apply(rec, naming_opts)` right after `undo.record(rec)`.

5. **Status toast aggregation** — the existing "Placed X (Ng Mz Pd, K errors)" toast is appended with a naming summary when any naming pass ran (e.g. `"Placed snow-city (36g 3z 9d, 0 errors) — 36 renamed · 60 units renamed"`). On naming failure the toast severity drops to `'warning'`.

6. **Tests** — a new `test_prefab_naming.lua` covering the pure-logic pipeline (the four combinations of name/prefix/suffix presence, the `{n}` token, the Keep Num behavior, multi-entity collision via `{n}`, auto-name-units running last with the post-rename group name). `prefab_manager.lua` layout changes get coverage at the level the file already has — the existing test surface for it is geometry-light, so layout assertions are limited to "the splitter+naming widgets are constructed and `set_bounds` doesn't throw at min and at a representative size."

### Out of scope

- **Cross-session persistence** of form field values. Values reset on ME relaunch (no save-to-disk).
- **Per-prefab persistence** of naming defaults (the user could imagine saving a "default suffix" alongside a prefab; we deliberately don't).
- **Form re-arrangement** of any of the OTHER existing controls (Reload/Undo/Rename/Delete row stays; Save row at the top stays; folder controls stay).
- **Refactoring Mass Edit form modules.** Their `_apply` functions are public-by-convention (they're called from tests already); we treat them as a stable API.
- **Zone / Drawing scope in Mass Edit itself.** Those tabs remain "Coming soon" in Mass Edit. The Prefab Manager will become the first real caller of `name_writer.write` against zones and drawings — see Decisions § "Zone/drawing rename — empirical verification".
- **New undo records.** The existing placement-undo already removes the placed entity set wholesale; renames are part of the placed state and disappear with the placement.

## Constraints

- **Lua 5.1 (DCS Mission Editor)**: no goto, no `<const>`/`<close>` attrs, no integer division operator, no native bit ops outside `bit` lib.
- **Mass Edit `_apply` signatures must be preserved.** Changing them would force this work into the wrong PR.
- **`prefab_manager.lua` is already 2640 lines.** New widget construction is inline (≤ ~80 lines added); the naming logic lives in `prefab_naming.lua` to avoid further bloat.
- **No new dependencies on dxgui internals.** Reuse `clearable_edit`, `splitter`, `skin_helper`, `dtc_skins` — all already used elsewhere in `me-mod`.
- **Embedded Lua** — files under `tools/me-mod/lua/` are `//go:embed`'d into `dcs-sms.exe`. Rebuilding is required (`cd tools && ../dcs-sms.exe dev-reload`) — captured for the implementation prompt, not a runtime concern.
- **Backward-compatible behavior when fields are empty** — empty name/prefix/suffix is a no-op for that step. An empty placement (no naming opts set at all) is byte-identical to today's placement output.
- **AGENTS.md sync rule** (project-wide): any spec or PR that changes a `sms.*` public surface must update AGENTS.md in the same change-set. This feature doesn't add to `sms.*` (Prefab Manager is host-mod, not the in-mission framework), so the in-mod AGENTS.md (`tools/me-mod/AGENTS.md`) is what must be updated, NOT the framework one.

## Decisions

These are autonomous calls made under `/write-it`. Each can be revisited.

### D1. Reuse Mass Edit `_apply` functions; don't fork the logic.

`rename_group`, `add_prefix_group_name`, `add_suffix_group_name`, and `auto_name_units_group` each expose an `_apply(entities, ...)` function that is pure (no dxgui), already unit-tested in `test_mass_edit_forms.lua`, and already handles the cross-cutting concerns (Mass Edit's `undo.record_generic`, failure aggregation, `name_writer.write` collision tolerance). Forking would mean re-implementing all of that and accepting drift between Mass Edit's behavior and Prefab Manager's. Reusing means: if a future Mass Edit fix changes (e.g.) suffix collision behavior, Prefab Manager picks it up for free.

The minor cost: each `_apply` writes its own `undo.record_generic` entry. After a prefab placement with all three fields filled, the undo stack gains: 1 placement record + up to 3 rename records. **Per D6**, this is fine — we accept the extra undo entries because they're correct.

### D2. Order: Name → Prefix → Suffix → Auto Name Units.

User-confirmed during brainstorming. Each step reads the entity's CURRENT `.name`, so renames compose naturally. Auto-name-units runs last so unit names see the FINAL group name. If the user types `Name=Tank-{n}`, `Prefix=EAST_`, `Suffix=_alpha`, `Keep Num=ON`, then group #1 becomes `EAST_Tank_alpha-01` (suffix inserted before `-01` per Keep Num) and its units become `EAST_Tank_alpha-01-1`, `EAST_Tank_alpha-01-2`, etc.

### D3. Name applies to groups + statics; Prefix/Suffix apply to groups + statics + zones + drawings.

User explicit during brainstorming. Rationale: Name is "what is this thing called" — appropriate for entities the user thinks of as named-things (groups, statics). Prefix/Suffix are decorative tags appropriate for everything (you can usefully prefix zones too).

### D4. `{n}` token convention from Mass Edit's `rename_group`.

The Mass Edit Name form already documents `{n}` as the per-entity sequence token (1-based, name_asc sort, zero-padded to 2 digits). We reuse the same `mass_edit_transforms.auto_number` call directly, so `Tank-{n}` produces `Tank-01`, `Tank-02`, `Tank-03` for a 3-entity prefab. Names without `{n}` produce identical strings → ME / `name_writer.write` handles disambiguation per existing convention.

### D5. Form fields are sticky within a session, no persistence.

User-confirmed during brainstorming. Window-open/close preserves values. ME relaunch clears them. We deliberately don't persist to disk: this is a placement-shaping tool, not a per-prefab config; persistence would invite "why is this still applying?" surprise after a long break.

### D6. Undo strategy: rely on each `_apply`'s own `undo.record_generic` + the existing placement record.

Three rename records + one placement record on the undo stack after a fully-filled placement. The placement record removes the entities wholesale on undo, which makes the rename records moot for that placement (the entities are gone — restoring their old names is a no-op on dead handles). The Mass Edit rename `undo.register_handler` callbacks are already pcall-guarded and tolerant of stale entity references, so the dead-handle case degrades to "partial failures" in the log and an OK return. Acceptable.

Alternative considered: batch-suppress the per-form undo writes during a placement and only keep the placement record. Rejected — would require parameterizing each `_apply`, which we explicitly want to avoid (per D1).

### D7. `prefab_naming.apply` returns one aggregate result; status toast composes from it.

Shape:

```lua
{
    renamed_groups   = N,
    renamed_statics  = N,
    renamed_zones    = N,
    renamed_drawings = N,
    renamed_units    = N,   -- from auto-name-units
    failed           = N,
    toast            = '...',   -- pre-composed one-liner
    sev              = 'success' | 'warning' | 'error' | nil,
}
```

`nil` sev means "no naming ran" — caller suppresses the appended toast suffix.

### D8. Zone/drawing rename — empirical verification gate inside the implementation.

`name_writer.write` is used today for group + static + zone + drawing branches inside Mass Edit's transform forms (per its source), but Mass Edit's zone/drawing scopes are not yet user-facing. If `prefab_naming.apply` finds during implementation testing that `name_writer.write` doesn't cleanly rename a zone or drawing (e.g. ME needs a side-effect refresh call that Mass Edit's pattern doesn't currently make), the implementation plan adds a small `prefab_naming._rename_zone(z, new)` / `_rename_drawing(d, new)` adapter that writes `.name` directly and pokes the appropriate refresh hook. Verification is part of the implementation task that adds zone/drawing handling.

This is the only "could surprise us" item in the spec. Captured here so the plan task that touches it can budget for it.

### D9. Layout — splitter only spans the body (tree+grid+row3 strip).

The vertical splitter does NOT extend down into the new right-column control stack. Bottom edge of the splitter aligns with the bottom of the `[+New folder][Show all]` / `[Reload][Undo][Rename][Delete]` row. This matches the user's annotated screenshot (the pink divider stops above the red zone).

### D10. Place buttons stay side-by-side.

User-explicit. Right-column min width clamp is set so that even at the leftmost splitter position, the two place buttons still fit. Specifically: right column min ≈ 360 px (place-orig 200 + gap 6 + place-click 122 + side margins 32). Left column min ≈ 140 px ([+New folder] + [Show all] need to fit at ~64 px each + gap). Window min width = left_min + right_min + splitter gutter ≈ 506; round to a sane 560 to leave breathing room.

### D11. Naming-row LABEL_W = 56 px to match Mass Edit form internals.

Mass Edit's `rename_group`, `add_prefix_group_name`, `add_suffix_group_name` all use `LABEL_W = 56`. Matching it makes the three new rows align visually with the existing Country/Rotation row labels (which are wider — 100 and 60 respectively — but those are pre-existing labels so we don't touch them).

### D12. Status toast composition.

`set_status(...)` call site in both placement paths now composes from `prefab_naming.apply`'s `toast` field:

```lua
local naming = prefab_naming.apply(rec, naming_opts)
local placement_msg = string.format('Placed %s (%dg %dz %dd, %d errors) at (%.0f, %.0f)', ...)
if naming.toast then
    placement_msg = placement_msg .. ' — ' .. naming.toast
end
local sev = (naming.failed > 0) and 'warning' or nil
set_status(placement_msg, sev)
```

### D13. Tests live in `tools/me-mod/test/test_prefab_naming.lua`.

Follows the existing `test_mass_edit_forms.lua` pattern (mocked `me_mission`, mocked `name_writer`, asserts on `_compute_targets` and `apply` return values). Layout-side has no new geometry test — the existing prefab_manager test file doesn't assert on `set_bounds` returns and adding that would be expensive for low value. We rely on dev-reload smoke testing for the layout.

### D14. AGENTS.md sync target.

`tools/me-mod/AGENTS.md` gets a brief addition to the "Prefab Manager" section noting the new naming forms and their behavior. The framework `framework/AGENTS.md` and root `AGENTS.md` are not touched (this is host-mod work).

## Open questions

None. All ambiguities were resolved during brainstorming (multi-entity collision handling, combine order, field persistence) or are captured as Decisions above.
