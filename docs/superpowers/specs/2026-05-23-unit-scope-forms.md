# Unit-scope forms for Mass Edit

**Status:** spec
**Date:** 2026-05-23
**Branch:** `worktree-me-mass-edit`

## Goal

Add the sixth content block of forms to Mass Edit's right pane — the **Unit
scope**. Today the Unit tab renders unit rows but `mass_edit_forms.by_scope.unit`
is `{}`, so the right pane shows only the "No forms yet for this scope" stub.
Ship nine forms that wrap the existing `verbs.unit_set_*` functions, plus the
category-aware applicability infrastructure needed to gate forms cleanly when
the user's checked set doesn't include any applicable unit category.

## User value

Bulk operations that today require either Lua scripts in the dcs-sms console or
clicking unit-by-unit through the ME panel:

- Set skill on every checked unit (e.g. "every Red ground unit → High").
- Find/replace, prefix, suffix, or sequential auto-number unit names across an
  ad-hoc cross-group selection.
- Set the livery on a row of identical planes without opening each unit's panel.
- Sweep heading (absolute) or rotate a formation by delta degrees.
- Set onboard numbers in sequence (`010, 011, 012…`) or randomized.
- Set fuel as a percentage of the airframe's max (the way mission designers
  think about it, not raw kg).

The Unit scope already exists in the treeview and selection plumbing — this work
fills in the form pane.

## Scope

### In

Nine forms, mirroring the established one-form-per-verb pattern used in the
group and airbase scopes:

| # | Form module | Verb | Applies to |
|---|---|---|---|
| 1 | `find_replace_unit_name` | `unit_set_name` | all categories |
| 2 | `add_prefix_unit_name` | `unit_set_name` | all categories |
| 3 | `add_suffix_unit_name` | `unit_set_name` | all categories |
| 4 | `auto_name_unit` | `unit_set_name` | all categories |
| 5 | `set_skill_unit` | `unit_set_skill` | all categories |
| 6 | `set_onboard_num_unit` | `unit_set_onboard_num` | planes only |
| 7 | `set_livery_unit` | `unit_set_livery` | planes/helos |
| 8 | `set_heading_unit` | `unit_set_heading` | all categories |
| 9 | `set_fuel_pct_unit` | `unit_set_fuel` | planes/helos |

Plus the cross-cutting work:

- `applicability.lua` helper for category-aware gating (skip-and-count in mixed
  selections, gray-out when zero applicable).
- `SCOPE_COLUMNS.unit` column additions: **Category** and **Coalition** (the
  latter with per-row coalition tinting, matching airbase scope).
- `row_values('unit', ...)` updates for the new columns.
- Host-side observer that recomputes per-form applicability state on every
  scope-or-checked-set change.
- One pure `_apply` test file per form + one for the applicability helper.
- Smoke-checklist section in `docs/release-gate/me-mod-smoke.md`.

### Out (explicit)

These were considered during brainstorming and dropped or deferred:

- **Set callsign** — deferred. Airframe-family-specific name table and the
  `[1]/[2]/[3]` index reassignment policy add complexity that isn't worth
  resolving in v1.
- **Set altitude** — out of scope at unit level. Altitude is a waypoint/group
  concern in DCS mission design; the user explicitly redirected.
- **Set chaff / flare counts** — deferred to a future "full loadout" cycle that
  will also cover gun ammo, pylon weapons, and the rest of `u.payload`.
- **Set payload / pylon loadout** — same future cycle.
- **Set parking** — almost never used as a bulk op.
- **Set country override at unit level** — group-scope only; the existing
  `set_country` group form covers this.
- **"From map" / "Highlight" buttons** on the unit scope toolbar — user
  confirmed not useful for units (those workflows live in group scope).
- **Visibility/control flags at unit level** — those are group-level fields
  (`hidden`, `lateActivation`, etc.), covered by `toggle_group_flags`.
- **A unit-scope analog of `auto_name_units_group`** driven *from groups* — the
  existing group-scope form stays where it is; the new `auto_name_unit` is
  driven from a unit selection instead and uses a single counter across the
  whole checked set rather than per-group counters.

## Constraints

- **Lua 5.1.** Test VM is the standalone Lua 5.1 binary at
  `/c/Users/Niels/bin/lua51/lua5.1.exe`. `_G.log`, `me_mission`,
  `Mission.AirdromeController`, `Static`, `Button`, `ComboList`, `ListBoxItem`,
  `EditBox`, `ToggleButton` are all dxgui/ME modules that don't exist in the
  test VM — every form must pcall-guard its `require` calls (matches the
  existing `set_coalition_airbase.lua` pattern).
- **Host convention for `M.new`.** Every form module exposes `M.new(parent_raw,
  get_checked, on_after_apply, get_categories)` — positional args, fourth arg
  is the host's accessor that returns `W.categories` (per `toggle_group_flags`
  precedent). The earlier `M.mount(parent, opts)` shape used in the initial
  airbase draft was caught at code review (commit `7f08330`); follow the
  host convention from the start.
- **Pure-`_apply` testability.** Every form must split widget construction
  from the apply loop. The `M._apply(entities, args, categories)` function
  must not touch dxgui. Tests pass plain Lua tables for `entities` and never
  touch the widget layer.
- **Verb-mediated mutations.** Forms route every mission-state change through
  `verbs.unit_set_*` (not direct field writes), so side-effects like
  `refresh_group_view` fire correctly and undo can use the same path.
- **Lua identity for checked-set membership.** `W.checked.unit[entity] = true`
  keys on the unit table reference. `selection.snapshot_mission('unit')` walks
  `g.units` and pushes references straight into the pool — references are
  stable across rebuilds for already-existing units, so checks survive a
  refresh. (Unlike airbases, no `_cache` indirection is needed here because
  the mission tree already owns the unit tables.)
- **Undo through verbs.** Each form's undo handler re-invokes the same
  `verbs.unit_set_*` with the captured old value. Partial failures on undo are
  counted, not aborted.
- **No new verbs.** All nine forms wrap existing verbs in `verbs.lua`. No
  CLI-surface changes.

## Decisions

The brainstorming dialogue resolved these. They are not open questions —
they are recorded here so the implementer doesn't relitigate them.

1. **Form universe.** Skill, find/replace, prefix, suffix, auto-name, livery,
   heading, fuel%, onboard #. Nine forms total. Callsign, altitude,
   chaff/flare, payload, parking explicitly excluded.

2. **Category gating: hybrid D.** Skip-and-count in mixed selections (toast
   reads `N applied · M not applicable`); gray-out when applicable count is
   zero (Apply button disabled, inputs disabled, optional tooltip "No
   applicable units checked"). The grayed state also kicks in when nothing
   is checked at all. Implemented by a centralized `applicability.lua`
   helper rather than each form rolling its own.

3. **Auto-name: "B" + Start at.** Single counter across the whole checked
   set, treeview-order. Inputs: `Base: [____]   Start at: [1]   [Apply]`.
   Produces `<base>-<n>` (separator `-` matches `auto_name_units_group`).

4. **Heading: "C" — two-mode form.** One form with two input rows, each its
   own Apply: `Absolute: [____]° [Apply]` and `Delta: [____]° [Apply]`.
   Form normalizes input to `[0, 360)` before passing to `unit_set_heading`.
   Delta reads current `u.heading` (radians), converts to degrees, adds the
   delta, normalizes, writes back via the verb. Single undo handler covers
   both modes — the snapshot per row captures `u.heading` (radians) verbatim.

5. **Onboard #: "A" + Random button.** Inputs: `Start at: [010]   [Apply]
   [Random]`. Apply auto-increments from input, padding inferred from input
   width (`010` → `010, 011, 012`; `1` → `1, 2, 3`). Random ignores the input,
   generates 3-digit `001–999` unique within the checked set only (no mission-
   wide deconfliction). Treeview-order for both.

6. **Livery: "C" — single-airframe gating.** Form grays out (in addition to
   the universal applicability rule) when the checked set spans more than
   one distinct airframe `type` among planes/helos. Combo is populated for
   the dominant single airframe. Source-of-truth preference order: ME's
   livery API → filesystem scan (`<Saved Games>\DCS\Liveries\<type>\`,
   `<install>\CoreMods\aircraft\<type>\Liveries\`, `<install>\Bazar\Liveries\<type>\`)
   → free-text fallback EditBox. The plan must spike the ME livery API first
   and only fall back if it's not discoverable.

7. **Renames: skip-and-count per row, no pre-scan.** Mirrors group-scope
   `find_replace_group_name._apply` precedent. Each row is attempted via
   `verbs.unit_set_name`; the verb refuses on collision and we count the
   row as `failed` in the toast (`N renamed · M failed`). No batch refusal.
   `mass_edit_transforms` is reused as-is for find/replace/prefix/suffix
   string operations.

8. **Form ordering** in the right pane (names first, then everything else,
   per group-scope precedent):
   1. Find/replace name
   2. Add prefix
   3. Add suffix
   4. Auto-name
   5. Set skill
   6. Set onboard # *(planes only)*
   7. Set livery *(planes/helos only)*
   8. Set heading
   9. Set fuel % *(planes/helos only)*

9. **Column layout (Q9 answer B).** New `SCOPE_COLUMNS.unit`:
   ```
   [ ] (28) · Name (140) · Type (100) · Category (70) · Skill (75) · Coalition (60) · Group (55)
   ```
   Total: 528px. Wider than group (428) or airbase (468) — splitter handles
   it. Coalition column gets per-row tinting via the existing coalition
   skins (`listBoxItemCoalRedSkin` / `…BlueSkin` / `…NeutralSkin`), matching
   the airbase scope's Coalition column.

10. **Fuel %: kg conversion + max-fuel fallback.** Form input is `0–100`.
    Verb takes kg. Form computes `kg = (pct/100) * max_fuel` where
    `max_fuel` comes from the unit's airframe definition.

    **Risk:** there is no existing helper in this codebase that returns
    `max_fuel` for an airframe. The verb at `verbs.lua:2337` notes "No max
    validation (the panel clamps to airframe max; we let the user pass any
    non-negative number)" — so the ME's unit panel knows, but we don't.

    **Fallback strategy:** the implementer must spike `_G.db.Units.Planes`
    (or whatever ED database table the ME panel reads from) first. If a
    reliable per-airframe `fuel_max` source is found, the form uses it. If
    not, the form degrades to **"% of current `u.payload.fuel`"** with a
    visible warning tooltip on the input — still useful for "give me half
    of what each plane has right now" but not a true % of capacity.

    Either way, the form's `_apply` accepts `pct` as input and computes
    kg via an injected `max_fuel_for(unit)` function — keeps the test
    surface clean even if the production source is the rough fallback.

11. **Skin reuse.** No new skins required. Forms reuse `dtc_button` (Apply,
    Random, etc.) and `staticSkin_ME` (labels) and `comboListSkinNew_`
    (combos) and the existing EditBox skin used by the other text-input
    forms. Coalition tinting on the new Coalition column reuses the
    existing `listBoxItemCoal*Skin` skins.

12. **Test coverage.** One `_apply` test file per form + one for the
    applicability helper = 10 new test files. Each test file follows the
    existing `test_mass_edit_*.lua` pattern: stub `verbs.unit_set_*` via
    a local table so assertions can verify the verb was called with the
    correct args without touching the real Mission object. Tests register
    in `run-tests.ps1`.

13. **Out-of-scope: callsign deferral mechanism.** No placeholder, no
    feature flag, no stub form. The form simply doesn't exist in
    `by_scope.unit`. A future cycle adds it.

## Open questions

None. All design questions resolved in brainstorm (see Decisions). The one
implementation risk (max_fuel lookup) has a documented fallback that
preserves usefulness even if the spike fails.

## Files to add

```
tools/me-mod/lua/dcs_sms_me/applicability.lua                                 (NEW)
tools/me-mod/lua/dcs_sms_me/mass_edit_forms/find_replace_unit_name.lua        (NEW)
tools/me-mod/lua/dcs_sms_me/mass_edit_forms/add_prefix_unit_name.lua          (NEW)
tools/me-mod/lua/dcs_sms_me/mass_edit_forms/add_suffix_unit_name.lua          (NEW)
tools/me-mod/lua/dcs_sms_me/mass_edit_forms/auto_name_unit.lua                (NEW)
tools/me-mod/lua/dcs_sms_me/mass_edit_forms/set_skill_unit.lua                (NEW)
tools/me-mod/lua/dcs_sms_me/mass_edit_forms/set_onboard_num_unit.lua          (NEW)
tools/me-mod/lua/dcs_sms_me/mass_edit_forms/set_livery_unit.lua               (NEW)
tools/me-mod/lua/dcs_sms_me/mass_edit_forms/set_heading_unit.lua              (NEW)
tools/me-mod/lua/dcs_sms_me/mass_edit_forms/set_fuel_pct_unit.lua             (NEW)

tools/me-mod/test/test_unit_applicability.lua                                 (NEW)
tools/me-mod/test/test_mass_edit_find_replace_unit_name.lua                   (NEW)
tools/me-mod/test/test_mass_edit_add_prefix_unit_name.lua                     (NEW)
tools/me-mod/test/test_mass_edit_add_suffix_unit_name.lua                     (NEW)
tools/me-mod/test/test_mass_edit_auto_name_unit.lua                           (NEW)
tools/me-mod/test/test_mass_edit_set_skill_unit.lua                           (NEW)
tools/me-mod/test/test_mass_edit_set_onboard_num_unit.lua                     (NEW)
tools/me-mod/test/test_mass_edit_set_livery_unit.lua                          (NEW)
tools/me-mod/test/test_mass_edit_set_heading_unit.lua                         (NEW)
tools/me-mod/test/test_mass_edit_set_fuel_pct_unit.lua                        (NEW)
```

## Files to modify

```
tools/me-mod/lua/dcs_sms_me/mass_edit_forms.lua    -- register the 9 forms in by_scope.unit
tools/me-mod/lua/dcs_sms_me/mass_edit.lua          -- SCOPE_COLUMNS.unit + row_values + applicability observer + coalition tinting on unit rows
tools/me-mod/test/run-tests.ps1                    -- register the 10 new tests
docs/release-gate/me-mod-smoke.md                  -- add "Unit scope (v0.10.0+)" section
```

## Acceptance criteria

1. Opening Mass Edit, switching to the Unit tab, checking some units, and
   switching to a form: all nine forms mount and lay out cleanly without
   overflow in the right pane.
2. With ground/naval units checked, the four name forms + skill + heading
   are interactive; livery / onboard # / fuel are grayed with tooltip.
3. With mixed plane + ground selection, fuel% form applies to planes,
   reports `N applied · M not applicable` in toast.
4. Onboard # auto-increments correctly with input `010` → `010, 011, 012`
   and with input `5` → `5, 6, 7`. Random produces unique values.
5. Heading delta of `+90°` on a unit currently at `0°` writes `90°`;
   delta of `+45°` on a unit at `350°` writes `35°` (wraps).
6. Auto-name with `Base: Falcon, Start at: 5` and 3 checked units writes
   `Falcon-5, Falcon-6, Falcon-7`.
7. Find/replace with collision: 5 checked units where 2 would collide with
   existing names; toast reads `3 renamed · 2 failed`.
8. Livery form grays out when checked set spans 2+ airframe types
   among planes/helos; ungray when narrowed to 1.
9. Undo restores per-row old values for every form (smoke-tested via the
   existing undo system).
10. Test suite (`tools/me-mod/test/run-tests.ps1`) is green: previous count
    + 10 new files, 0 failures.
11. New columns (Category, Coalition) render for unit rows with correct
    values and the Coalition column applies per-row coalition tinting.
12. Smoke checklist at `docs/release-gate/me-mod-smoke.md` has a new
    "Unit scope (v0.10.0+)" section covering one happy path + one mixed-
    category case + one undo cycle per form (concise — one bullet per form).
