# Trigger Finder — design

**Date:** 2026-06-14
**Status:** Approved (brainstorm), pending implementation plan
**Area:** `tools/me-mod` — Mission Editor mod, new standalone tool window

## Problem

Mission builders need to answer "which triggers affect *this* unit/group/static?" —
the **one-to-many** reverse of how the ME presents triggers (one trigger → its many
referenced entities). Today the only way is to trawl every trigger looking for a
reference. This is slow and error-prone, and it bites hardest in campaigns that use
persistent save-state between missions: triggered actions get wiped mission-to-mission,
so the author must repeatedly re-verify "did I wire up this CAP group or not?" across
many similarly-named groups.

The originating request (Discord): *"click on a group or unit and see which triggers
affect it … a window that auto-updates with the current selection … click a trigger and
it selects that trigger in the ME trigger panel."*

## Goals

- A standalone ME-mod tool window that **auto-follows the map selection** and shows,
  per selected entity, the triggers that reference it.
- Clicking a trigger **selects it in the vanilla ME trigger panel** (highlight + scroll
  into view + populate its conditions/actions), so the user lands on the editable trigger.
- An at-a-glance **coverage signal**: scan the selection and immediately see which
  groups/units have *zero* triggers — the core of the "did I wire this up?" audit.

## Non-goals

- **No inline trigger editing or detail duplication.** The vanilla panel already shows
  conditions/actions; reproducing it adds no value. Our window's payload is the *jump*.
- **No new CLI verb.** This is GUI-only. A `me trigger referencing --unit/--group` verb
  reusing the same core is a plausible later follow-up, explicitly out of scope here.
- **No mutation of triggers.** Read + navigate only.

## UX

A two-pane window built on `sms_window`, opened from the **DCS-SMS** menu, with the
house splitter (`sms_skins` splitter skin) between the panes so it's resizable for long
group names.

```
Coconut Cockpit · DCS-SMS — Trigger Finder v<ver>
┌──────────────── tree ────────────┬─┬──────── buttons ────────┐
│ ▾ CAP-1-Aleppo-Patrol        [3] │⋮│ Triggers referencing     │
│     Aerial-1-1               [2] │⋮│ unit "Aerial-1-1"        │
│     Aerial-1-2               [0] │⋮│ [ FIRST TRIGGER   once ] │
│ ▸ CAP-2-Hama-Patrol          [0] │⋮│   condition · unit dead  │
│ ⬛ SAM-Site-Static           [1] │⋮│ [ EXPLODE ON HIT  once ] │
└──────────────────────────────────┴─┴──────────────────────────┘
 Auto-following map selection · 3 entities
```

- **Left — selection tree.** Built from the current map selection. Groups are expandable
  (twirl arrow) → their units; statics are leaf nodes (the unit half of a static is
  noise, per the data model — see below). Themed scrollbar via `sms_scrollbars`.
- **Count badges.** Each node carries a trigger-count chip: **amber** when ≥1 trigger
  references it, **grey "0"** when none. This is the coverage audit — kept per the
  brainstorm decision.
- **Right — trigger buttons.** One button per trigger referencing the selected tree node,
  each labelled with the trigger name, its type (once / continuous / start / front), and
  a one-line "why it matched" (e.g. *condition · unit is dead*, *action · group activate*).
- **Selecting a tree node** repopulates the right pane. Selecting a **unit** node shows
  triggers that reference *that unit*; selecting its **group** node shows triggers that
  reference *the group*. The two are deliberately separate nodes (the parent group is
  always visible in the tree), which cleanly splits the unit-level vs group-level question
  the ME's hybrid unit/group panel otherwise blurs.
- **Clicking a trigger button** jumps to it in the vanilla panel (see Jump mechanism).

### Empty / edge states

- **Nothing selected on the map:** right pane shows a hint ("Select a unit, group, or
  static on the map"); tree is empty.
- **Node with no triggers:** right pane shows "No triggers reference this." (grey).
- **Trigger panel closed when a button is clicked:** open it first, then select.

## Architecture

New module(s) under `tools/me-mod/lua/dcs_sms_me/`:

| Module | Responsibility |
|---|---|
| `trigger_finder.lua` | The window. Owns the `sms_window` handle, the splitter, the tree widget, the button pane, the selection subscription, and render. |
| `trigger_finder_model.lua` (pure) | Selection snapshot + `find_related` results → tree model: nodes (group/unit/static), per-node trigger lists, per-node counts, level labels. No dxgui — unit-testable. |

Reused, unchanged where possible:

- `dcs_sms_me.selection` — `snapshot()` to read the current map selection (groups,
  units, statics, zones).
- `dcs_sms_me.marquee_hook` — `subscribe(cb)` to learn when a marquee selection completes.
- `dcs_sms_me.trigger_schema` — `from_editor()` for the descriptor cache + field-kind
  classifier.
- `dcs_sms_me.trigger_export` — `find_related(trigrules, sel, schema)` for the reverse
  lookup (see Data flow; statics ride the group path — see "Statics — resolved").
- `dcs_sms_me.sms_window`, `sms_skins`, `sms_scrollbars` — chrome, splitter, scrollbars.
- `menu.lua` — a new **Trigger Finder** entry under the DCS-SMS menu.

## Data flow

```
map selection change
  → marquee_hook callback  (marquee)   ┐
  → per-tick selection poll (single-click) ┘  (only while window visible)
  → selection.snapshot()  → { groups[], units[], statics[], zones[] }
  → build sel = { group_ids = {id→true}, unit_ids = {id→true}, zone_ids = {id→true} }
  → trigger_export.find_related(mission.trigrules, sel, schema)
        → [ { index, trigger, refs=[{kind,id,field,selected}], outside_refs } ]
  → trigger_finder_model: bucket each related trigger under every selected ref
        (ref.kind + ref.id → node), producing per-node trigger lists + counts + level
  → render tree (with badges) + right pane for the selected node
  → user clicks a trigger button → select_in_panel(trigger.index)
```

Because the tree *is* the selection, every node's id is in `sel`, so `find_related`
returns all the triggers we need in one call; we bucket its `refs` by `id`+`kind` to get
per-node lists. A trigger referencing both a unit and its parent group correctly appears
under both nodes.

## Jump mechanism (verified live)

Proven against a running ME via the bridge. The vanilla panel is `me_trigrules`; its
trigger listbox is `me_trigrules.triggersWindow.Box.triggersList`. The panel's own
internal `selectListBoxItem(listBox, idx)` (used after clone/delete/move) does exactly
what we need, so we replicate it:

```lua
local m  = package.loaded['me_trigrules']
-- 1. ensure the panel is open
if not m.isVisible() then m.show() end
local tl = m.triggersWindow.Box.triggersList
-- 2. find the row whose .itemId is our trigrules entry (identity match,
--    fall back to 0-based index = trigrules index - 1)
local item = find_row_for(tl, mission.trigrules[index])
-- 3. select + reveal + repopulate (this is the click path)
tl:selectItem(item)        -- highlight
tl:setItemVisible(item)    -- scroll into view
tl:onChange(item)          -- repopulate conditions/actions/args (the click handler)
```

Each list row's `.itemId` **is** the `mission.trigrules` entry table, so the row↔trigger
mapping is an identity comparison — no fragile index arithmetic. All calls wrapped in
`pcall`; on any failure, flash an error in the footer rather than throw. (DCS may rename
these internals between builds — defensive pcalls per the ME-mod rules.)

## Statics — resolved (no gap)

Verified live: a static referenced by a trigger (e.g. *ALL OF GROUP IN ZONE* targeting a
placed static) appears as a **group** field — `{ group = <groupId>, group_name =
"Static …" }` — because the ME models a static as a single-unit group. Confirmed the
static's `groupId` in the mission table matches the `group` id in the trigger field.

Consequences:

- `trigger_export.walk_refs` already classifies `group`-kind fields, so `find_related`
  **already catches** static-referencing triggers. No extension to `trigger_export` /
  `trigger_schema` is needed.
- `selection.lua` already surfaces statics: `snapshot()` includes them, and there is a
  dedicated **`static` scope** (`snapshot_drilled`/`snapshot_mission`) returning each
  static as a group-ref carrying its `groupId` (`selection.lua:92`, `:250`).

Implementation note for `trigger_finder_model`: render statics as **leaf** nodes (the
unit half is noise), and feed each static's `groupId` into `sel.group_ids` (not a
separate set) so `find_related` matches it. The unit-level set (`sel.unit_ids`) is built
only from real unit nodes under non-static groups.

## Open risks to resolve in the plan

1. **Single-click selection feed.** `marquee_hook` covers marquee completion, but
   single-click selection has no existing event. Plan to poll `selection.snapshot()` on
   the `UpdateManager` tick, **only while the window is visible**, diffing against the
   last snapshot and rebuilding the tree only on change. Verify the snapshot is cheap
   enough to run per tick (it walks selection state, not the whole mission); if not,
   throttle (every N ticks) or hook the single-select code path instead. Measure, don't
   assume (per the "measure DCS freezes" rule).

## Error handling

- Verb/UI bodies never throw; wrap ME-internal calls in `pcall`, surface failures via the
  `sms_window` footer status (`flash_status(msg, 'error')`).
- Missing/locked panel, a trigger that was deleted since the tree was built, an empty
  selection — all degrade to a status message or empty state, never a crash.
- Reload-safe: the selection subscription must survive `reload-me-mod` the way
  `marquee_hook` already persists its subscribers.

## Testing

- **Lua mock tests** (`tools/me-mod/test/`, registered in `run-tests.ps1`): the pure
  `trigger_finder_model` — bucketing refs into per-node lists, count/level computation,
  empty-selection and zero-coverage cases — against `mock_me_mission.lua` fixtures
  including unit, group, and static refs.
- **Manual smoke** (add to `docs/release-gate/me-mod-smoke.md`): open window, marquee a
  mix of CAP groups + a static, confirm badges, confirm unit vs group node lists, click a
  button and confirm the vanilla panel selects + scrolls + shows the right conditions,
  confirm auto-follow on changing the map selection, confirm panel-closed path opens it.

## Doc-sync & versioning

- **Minor** version bump (`version.lua`) — new user-facing feature.
- `CHANGELOG.md` entry, same change-set.
- `tools/me-mod/AGENTS.md` file-layout table (§2.2): add `trigger_finder.lua` and
  `trigger_finder_model.lua`. No verb-index change (GUI-only, no new verb).
- No `docs/cli/` change (no new verb).
