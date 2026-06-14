# Prefab bundled-trigger dangling-reference gate

**Date:** 2026-06-14
**Status:** Approved design
**Area:** ME-mod (Prefab Manager save flow)
**Builds on:** [`2026-06-10-prefab-triggers-design.md`](2026-06-10-prefab-triggers-design.md) (Flow B)

## Problem

When you save a prefab and bundle a related trigger, the trigger may reference
groups/units/zones that are **not in your selection** — and therefore not in
the prefab. The saved trigger carries those as `{id, name}` loose refs.

Example: `viper-1` and a late-activated `help-viper`, with a trigger *"when
viper-1 dead → activate help-viper"*. Selecting only `viper-1`, the trigger is
detected (it references `viper-1`), gets bundled, and the prefab now contains a
reference to `help-viper` that the prefab does not include. On placement that
ref dangles — it only resolves if the target mission happens to have a group of
the same name.

Today this is surfaced only as a **passive amber line** in the save-time bundle
dialog (`trigger_dialogs.lua:267-276`, `also references: group 42`). It is easy
to miss, and the user can save a structurally incomplete ("broken") prefab
without making a conscious decision.

### What this is NOT

A trigger with **zero connection** to the selection's closure cannot be
detected at save time and is explicitly **out of scope** (see "Decisions"). In
the example above, a *separate* trigger *"after 10s → activate help-viper"* (no
reference to `viper-1`) is never linked to a `viper-1`-only selection — there is
no information tying it to the prefab. The fix for that case is selecting
`help-viper`; we do not chase it here.

## Decisions (user-confirmed)

1. **Warn, require a choice — do not auto-grow the prefab.** When bundled
   triggers reference entities the prefab won't include, escalate the passive
   amber line into a **blocking confirm**. We do not silently pull referenced
   groups into the prefab (that removes user control, can balloon the file, and
   breaks the legitimate "this ref resolves in the target mission" use case —
   e.g. an existing player group).
2. **No transitive closure / group-adding machinery.** Because we never grow
   the selection, there is nothing to re-scan. The feature is purely a gate.
3. **Cancel aborts the entire save.** Not "save without triggers" — the user
   reselects and saves again.
4. **Disconnected triggers are out of scope.** A trigger unreachable from the
   selection's references is the user's selection responsibility; no save-time
   nag, no opt-in audit in this change.
5. **Flow A (standalone Triggers tab) is unaffected.** A trigger-only prefab is
   *meant* to be rebound at import, so every ref is "loose" by design — warning
   there would be pure noise. Scoping falls out for free (see below).

## Design

### Single chokepoint

All three bundled-save paths — fresh save, overwrite, and "Update Prefab with
selection" — funnel through `prefab_manager.with_bundled_triggers` (call sites
~`1007`, `1018`, `1065`). The entire change lives in that function's
`on_confirm` callback. The standalone Triggers tab saves via
`prefab_ops.save_trigger_prefab` and never calls `with_bundled_triggers`, so it
is automatically excluded — no extra guard needed.

`trigger_dialogs.lua` (the presentational bundle dialog) needs **no change** for
the gate itself; the data it already carries (`related[i].outside_refs`) is the
input.

### Data flow

1. `with_bundled_triggers` already computes
   `related = export.find_related(trigrules, sel, schema)`, where each entry is
   `{ index, trigger, refs, outside_refs }` and `outside_refs = [{kind, id, field, selected=false}]`
   — references to entities **not** in the selection (`trigger_export.lua:166-190`).
2. The bundle dialog's `on_confirm(checked_indices)` returns the trigger
   indices the user kept checked.
3. New step: aggregate `outside_refs` across **only the checked** related
   triggers, dedupe by `kind+id` → the **dangling set**.
4. If the dangling set is empty → proceed exactly as today
   (`k(build_triggers_payload(checked_indices))`).
5. If non-empty → resolve each `{kind, id}` to a display name via the
   `entity_name` helper already defined in `build_triggers_payload`
   (`prefab_manager.lua:872-885`; `group_by_id` / `unit_by_id` / TZD), then show
   the gate overlay.

### Pure, testable unit

Add to `trigger_export.lua`:

```lua
-- dangling_refs(related, checked_indices) -> { {kind=, id=}, ... }
--   Deduped union of outside_refs across the related entries whose .index is
--   in checked_indices. Pure: no Mission/DCS dependency. Name resolution is
--   done by the caller at the UI boundary.
function M.dangling_refs(related, checked_indices) ... end
```

This keeps the aggregation/dedup logic unit-testable in the standalone Lua 5.1
VM. Name lookup stays out of it (it needs the live mission).

### Gate overlay + button semantics

Reuse the existing `show_overlay` confirm pattern (same one the overwrite
dialog uses). Copy:

> **Title:** Triggers reference entities not in this prefab
> These bundled triggers reference entities the prefab won't include:
> `help-viper (group)`, `Ambush Zone (zone)`.
> They will be saved as loose references and only resolve if the target mission
> has matching entities. Save anyway, or cancel and widen your selection?

Buttons:

- **Save anyway** → `k(build_triggers_payload(checked_indices))` — bundling
  proceeds with the loose refs (unchanged import behavior: resolved by id-map,
  then name, else manual-map/skip at placement).
- **Cancel** → abort the whole save. Status line: `Save cancelled — adjust your
  selection.` No file written. (Do **not** call `k(nil)`, which would save the
  prefab without triggers.)

### Incidental: friendly names in the existing amber line

Since names are resolved for the gate anyway, also feed names into the bundle
dialog's amber `also references:` line so it reads `help-viper (group)` instead
of `group 42`. Small, localized improvement to `trigger_dialogs.lua`'s
`outside`-rendering block (`:267-276`) — the dialog gains an optional
name-lookup injection (falls back to `kind id` when absent, so the test VM and
any caller without a resolver are unaffected).

### Error handling / degradation

All overlay construction is `pcall`-guarded, consistent with
`trigger_dialogs`/`show_overlay`. In the test VM (no dxgui) the gate degrades to
**proceed** (Save anyway), mirroring `show_bundle_dialog`'s "never deadlock the
save flow" fallback. Name resolution is `pcall`-guarded and degrades to
`kind id`.

## Testing

Pure-Lua standalone (`tools/me-mod/test/`):

- `dangling_refs`: empty when no checked trigger has outside refs; union across
  multiple checked triggers; **dedup** of the same `{kind,id}` referenced by two
  triggers; **respects the check state** (an unchecked trigger's outside refs
  are excluded); ignores `checked_indices` that don't match any related entry.
- Regression: a checked trigger whose refs are all in-selection yields an empty
  dangling set (no gate, no behavior change).

The overlay itself and name resolution are UI/live-mission glue (degrade in the
test VM); covered by the manual smoke step below.

Manual smoke (add to `docs/release-gate/me-mod-smoke.md`): the viper-1 /
help-viper case — bundle the "when viper-1 dead → activate help-viper" trigger
with only viper-1 selected, confirm the gate fires with the resolved name, that
**Cancel** writes no file, and that **Save anyway** produces the same prefab as
before this change.

## Scope, docs, versioning

**Touched:** `trigger_export.lua` (new pure `dangling_refs`),
`prefab_manager.lua` (`with_bundled_triggers` gate + name resolution),
`trigger_dialogs.lua` (optional name injection into the amber line).

**No change to:** the prefab data format / `PREFAB_VERSION` (this is save-flow
UX only, no new persisted keys), the import/rebind pipeline, Flow A.

Same-change-set requirements (repo doc-sync rules):

- ME-mod minor version bump + CHANGELOG entry.
- `tools/me-mod/README.md` — note the gate in the Triggers / prefab-save section.
- `2026-06-10-prefab-triggers-design.md` Flow B paragraph — update the
  "also references … ⚠ not in selection" sentence to describe the blocking gate
  rather than only the passive surface.
- `tools/me-mod/AGENTS.md` — only if a new module were added; none is, so no
  file-layout table change expected.

**Out of scope:** transitive group-adding, the disconnected-trigger tail, an
opt-in completeness audit, any import-side change.
