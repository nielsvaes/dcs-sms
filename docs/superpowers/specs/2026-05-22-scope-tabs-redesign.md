# Scope tabs redesign — Mass Edit window

**Date:** 2026-05-22
**Branch:** `worktree-me-mass-edit`
**Spec author:** Claude (autonomous via `/write-it`)

## Goal

Replace the five scope tabs at the top of the Mass Edit window (currently flat
`Static` widgets that show `Group · 12`, `Unit · 47`, etc., with no visible
"this tab is active" affordance) with a proper toggle-button tab strip that
makes the active scope visually unambiguous, drops the count badge, and stays
anchored within the left (tree) pane's width instead of overflowing into the
right (form) pane.

## User value

- The user can tell at a glance which scope is mounted. Today they cannot —
  the active tab and the inactive tabs render identically as gray statics.
- The tab strip no longer visually spills across the splitter into form-pane
  territory; it belongs to the left pane the way the name-filter and tree
  already do.
- Visual chrome matches the rest of the Mass Edit window's navy/teal DTC
  theme (the grid, the buttons, the splitter) instead of clashing with it.

## Scope

### In

- `make_scope_tab` rewrite in `tools/me-mod/lua/dcs_sms_me/mass_edit.lua` to
  build a `ToggleButton` (not a `Static`) skinned with a new `dtc_tab`.
- New `dtc_tab` skin builder in
  `tools/me-mod/lua/dcs_sms_me/dtc_skins.lua` and the routing entry in
  `tools/me-mod/lua/dcs_sms_me/skin_helper.lua`.
- New `ToggleButton` pcall-require at module load alongside existing
  `Static`, `Button`, etc.
- State-management wiring in `on_scope_changed` (mass_edit.lua:273-291) so
  the active tab gets `setState(true)` and the rest `setState(false)` on
  every scope switch — including the very first window build.
- Re-click on the active tab is clamped to "stay active" (no scope == nil
  state).
- Layout rewrite in `relayout()` (mass_edit.lua:716-722) so the five tabs
  share `left_w` proportionally; `L.TAB_W` is removed.
- Removal of `update_scope_counts` (mass_edit.lua:658-670) and its two call
  sites (mass_edit.lua:228, mass_edit.lua:295, mass_edit.lua:880, and
  mass_edit.lua:1120 — any reference becomes dead). Per-tab label is set
  once at construction and never updated.
- Smoke-doc update in `docs/release-gate/me-mod-smoke.md` adding a smoke
  item for the new active-tab affordance.

### Out

- No new tests for the visual swap (handoff guidance — pure cosmetic +
  layout). Existing scope-switching tests already cover the `on_scope_changed`
  wiring and will continue to.
- No changes to the form-pane side of the window.
- No changes to scopes themselves (`SCOPES`, `SCOPE_LABEL`, `SCOPE_COLUMNS`)
  beyond the dead-code cleanup that falls out of removing `update_scope_counts`.
- No changes to `dtc_button`, `dtc_button_on`, etc. The new `dtc_tab` lives
  beside them as a new builder.
- No backwards-compatibility shim. Old `Static`-based tab construction path
  is deleted, not feature-flagged.

## Constraints

- **Lua 5.1.** All new code must run under Lua 5.1 (no Lua 5.3+ idioms like
  integer division, bitwise ops, goto labels with newer syntax).
- **dxgui module loading is pcall-guarded** so the file still loads in test
  VMs that don't have `ToggleButton`. Pattern matches existing `Static` /
  `Button` / `ScrollPane` requires at mass_edit.lua:31-37.
- **`W._built` guard.** The window is constructed once; hot-reload via
  `dcs-sms reload-me-mod` re-`require`s the module but doesn't tear down
  the live window. Build-time widget construction changes need the user
  to close + reopen the Mass Edit window. (Acknowledged; no new constraint.)
- **No call to `MapWindow.setScale`.** N/A here — the redesign doesn't
  touch the camera — but the user is on RDP and scale changes can leave
  them stranded.

## Decisions

### D1. Widget type: `ToggleButton`

Chosen over `Button + manual skin-swap` because `ToggleButton` has a
built-in pressed/released state with native rendering — we set state once,
the framework draws the right state. With a `Button` we'd have to swap
between `dtc_tab_active` and `dtc_tab_inactive` skins on every scope change,
which is more code and more allocations.

### D2. Skin source: hand-rolled, not a clone of `toggleButtonTabMESkin`

The handoff suggested `toggleButtonTabMESkin` as a starting point. On
inspection (`C:/Program Files/Eagle Dynamics/DCS World/dxgui/skins/skinME/toggle_button_tab_me.skin.lua`),
that skin's `pressed` state has empty `bkg` tables and no `text` or
`picture` overrides — it doesn't actually provide a strong active visual
on its own. The simpler path is to follow the `dtc_separator` /
`dtc_splitter` idiom: build a minimal skin table from scratch with exactly
the states we want.

### D3. Active-state visual: filled teal `0x2da1beff` background, white text

This is the same teal that `dtc_grid` already uses for `selectionColor` —
visual rhyme with row selection elsewhere in the window. Active tabs read
unambiguously; the choice was approved during brainstorming.

### D4. Inactive-state visual: no background, dim grey text

`released` state defines text only (`0x9faab2ff` — dim grey, DejaVu condensed
bold 12pt) with no background. Lets inactive tabs read as flat labels
against the window's panel background. User specifically asked for "no
noise" on the inactive tabs.

### D5. Hover state: 25% alpha teal

`hover` state uses the same teal as active but at low alpha
(`0x2da1be40`). Subtle preview on mouse-over; matches the chunkier
`dtc_button` family's hover behavior. Cheap to include and the user didn't
push back on it in brainstorming.

### D6. Label content: no count, no middot

Drop the `· <count>` suffix. Tabs read `Group`, `Unit`, `Waypoint`, `Zone`,
`Drawing` — nothing else. The treeview itself shows whether a scope is
empty once you click in. User explicitly asked for "no noise". Falls out
of this: `update_scope_counts` becomes dead code and is deleted.

### D7. Re-click on active tab is a no-op (clamp to "always one selected")

Without clamping, ToggleButton's default behavior would toggle off when the
user clicks an already-active tab — leaving the Mass Edit window with no
selected scope. The change-callback detects the unwanted off-transition
and immediately re-asserts `setState(true)`. Standard pattern for "exclusive
ToggleButton group" semantics in dxgui.

### D8. Layout: each tab gets equal share of `left_w`

`tab_w = floor((left_w - GAP * (n - 1)) / n)` where `n = 5`. Tab strip
shares the left pane's width with the name-filter and tree; resizes
together when the splitter is dragged. `L.TAB_W = 100` is removed
(unused). `L.TAB_H = 28` and `L.TOP_Y = 4` remain unchanged.

### D9. Recursion guard via internal flag

`setState` fires the change callback. When `on_scope_changed` walks the tab
map and calls `setState(false)` on the de-selected tabs (and `setState(true)`
on the newly-selected one if the entry path was programmatic, e.g. the
window's initial build), those firings must not re-enter `on_scope_changed`.
A module-level `_set_state_internal` flag is set before each programmatic
`setState` and checked at the top of the change callback; if set, the
callback short-circuits.

Existing `ToggleButton` use sites in the codebase (`prefab_manager.lua`,
`mass_edit_forms/set_country.lua`, `mass_edit_forms/add_suffix_group_name.lua`)
don't need a guard because their callbacks only read state and update labels
/ lists — they never call `setState` on any toggle. This is the first
mutually-exclusive ToggleButton group in the project, hence the new pattern.

### D10. DialogLoader fallback path is removed

The current `make_scope_tab` tries `DialogLoader.spawnDialogFromString` first
and falls back to `Static.new()`. The new tab is a `ToggleButton.new()`
direct construction (pcall-guarded). The DialogLoader path existed because
of a historical concern about `Static.new()` ignoring skin XML overrides;
that concern is irrelevant here — we apply the skin programmatically via
`skin_helper.apply(tab, 'dtc_tab')` after construction.

### D11. Tests: no new tests, no test updates

Per handoff guidance, no new tests for the visual swap. Verified via grep
that no existing tests reference the `Group · 12` label format or call
`update_scope_counts` — so removing the count from the label and deleting
the function does not break the test suite. The scope-switching tests
already pass `on_scope_changed` directly (not through the tab widget), so
swapping the widget class from `Static` to `ToggleButton` does not affect
their wiring. After implementation, the full `run-tests.ps1` suite must
still pass green.

## Open questions

None remaining. All design questions surfaced during brainstorming were
answered; remaining minor judgement calls are captured in the Decisions
section.
