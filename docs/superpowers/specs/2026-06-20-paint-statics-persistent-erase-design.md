# Design — Paint Statics: persistent erase via the `_sms` name marker

- **Date:** 2026-06-20
- **Status:** Approved (brainstorm complete) — ready for implementation plan
- **Branch:** `feature/paint-statics`
- **Area:** `tools/me-mod` (ME-mod Lua, `paint_statics.lua`)

## Problem

Paint Statics' erase mode ("drag to delete only the statics this tool painted,
never your hand-placed ones") only works within a single editing session. The
erase registry holds live references to the mission's static-group tables. The
moment the mission is reloaded — flying then exiting a mission, File>New/Open,
or saving and reopening later — the ME rebuilds every mission table and those
references are orphaned. A prior fix stops that from **crashing** DCS (it skips
stale references), but the result is that painted statics simply become
un-erasable after the very first test-fly. Since flying to test is the constant
inner loop of mission making, single-session erase is close to useless.

We need painted statics to stay erasable-by-painting **indefinitely** — across
fly→exit, across save→reopen (even a new session or another machine).

## Goals

- Painted statics remain erasable by the erase brush after any mission reload.
- Preserve the strict guarantee: erase only ever deletes statics **this tool
  painted**, never hand-placed objects (identity, not area).
- No dependency on DCS preserving custom data: the `.miz` is regenerated from a
  fixed schema on every save, so any custom field on a unit/group/mission table
  is wiped. The marker must live in a field that survives that regeneration.

## Non-goals

- Erasing statics painted **before** this feature shipped (they carry no
  marker, so after a reload they are indistinguishable from hand-placed and are
  not erasable). Only newly-painted statics are tracked persistently.
- Making paint-stroke **undo** (Ctrl+Z of a paint) work after a reload. The
  undo record holds object references that go stale on reload; the crash-guard
  keeps that safe (no-op, no crash) but it is not re-resolved. Erase-stroke
  undo (restore) is data-driven and is unaffected.
- Hooking the fly→exit reload event. Re-resolution is lazy (on demand), so we
  never need to find that event.

## Decisions

Settled during brainstorming. Open questions: **none**.

1. **Marker = a forced `_sms` name suffix.** Every painted static's name gets
   `_sms` appended. The static *name* is part of the real mission schema, so it
   survives the save-regeneration, travels with the `.miz`, and gives exact
   per-static identity (keeps the strict guarantee). Chosen over: an in-mission
   custom field (wiped on save), and an "invisible polygon / hidden drawing"
   (area-based erase would catch hand-placed statics inside the region, and/or
   is fragile — drawing-text limits, user-deletable).
2. **Substring match.** A static is "ours" iff its name *contains* `_sms`
   (`string.find(name, '_sms', 1, true)`), not strictly ends-with — because the
   ME's uniqueness dedup can append `#2`, yielding `Barrel-01_sms #2`.
3. **Registry becomes a derived cache.** Instead of a session-only list of
   references, the erase registry is rebuilt from a live scan of the mission's
   marked statics on demand.
4. **Rebuild trigger = start of each erase stroke.** `begin_erase_stroke()`
   rebuilds the registry from the live scan, guaranteeing live references for
   that stroke. No reload-event hook needed. Cost is O(static count) per
   stroke-start — negligible for normal missions.
5. **Crash-guard stays.** The `group_is_live` guard in `batch_remove_groups`
   remains as a backstop.
6. **Marker is hardcoded `_sms`** (not user-configurable). YAGNI.

## Design

### 1. Marker on paint

The single paint path is `commit_placement(p, country, name_pattern)` →
`inject_static(expand_name(name_pattern, p.type), p, country)`. Append the
marker to the expanded name before injection:

```
inject_static(expand_name(name_pattern, p.type) .. MARKER, p, country)
```

where `local MARKER = '_sms'`. `inject_static` → `H.inject_group` runs the ME's
name-uniqueness dedup on the already-suffixed name; a collision yields
`…_sms #2`, still caught by the substring match. `expand_name`'s `{n}`
auto-indexing is unchanged — the suffix lands after the index
(`Barrel-{n}` → `Barrel-01` → `Barrel-01_sms`).

The erase-undo **restore** path (`inject_static(s.name, s, country)`) needs no
change: `s.name` was captured from a live painted static during the erase
stroke, so it already carries `_sms`, and restored statics stay erasable.

### 2. Re-resolution — rebuild the registry from marked live statics

A new local `rebuild_registry_from_marked()`:

- Walks the live mission's static groups via the coalition tree
  (`Mission.mission.coalition.<side>.country[].static.group[]`), the same walk
  `verb_helpers` / `selection` already use.
- Selects groups whose `name` contains `_sms`.
- Builds a registry entry per match, pointing at the **live** group table and
  reading attributes from it:
  `{ group = g, x = g.x or u.x, y = g.y or u.y, type = u.type,
     shape_name = u.shape_name, category = u.category, rate = u.rate,
     heading_deg = deg(u.heading or g.heading or 0), name = g.name,
     country = country.name }` where `u = g.units[1]`.
- Replaces `W.registry` wholesale.

Called at the top of `begin_erase_stroke()`. After it runs, the erase stroke
hit-tests by brush radius and `batch_remove_groups` over **live** references —
no stale references, works across every reload.

### 3. Erase / undo downstream — unchanged

`erase_step` (brush hit-test → `batch_remove_groups` → snapshot) and
`end_erase_stroke` (record undo) are unchanged; they now operate on the freshly
rebuilt live registry. Erase-undo restores from data snapshots (re-injects with
the `_sms` name). The crash-guard (`group_is_live`) remains the backstop in
`batch_remove_groups`.

### 4. Paint-time registry — still incremental

Paint still appends to `W.registry` incrementally (live ref within the session)
so cross-stroke min-spacing works during a paint session. After a reload that
incremental registry is stale, but the next erase stroke's rebuild replaces it,
and min-spacing only reads positions (never the C++ removal path), so a stale
ref there is harmless.

## Implementation touchpoints

- `tools/me-mod/lua/dcs_sms_me/paint_statics.lua`
  - `MARKER` constant (`'_sms'`).
  - `commit_placement` — append `MARKER` to the injected name.
  - new `rebuild_registry_from_marked()` — the live scan.
  - `begin_erase_stroke()` — call the rebuild first.
- `tools/me-mod/test/test_paint_registry.lua` — extend with rebuild tests.

## Testing

Extend `test_paint_registry.lua` (which already loads `paint_statics` headless):

- Expose `M._rebuild_registry_from_marked()` — it rebuilds `W.registry` from
  the live-mission scan and returns it, so the test can stub `me_mission`, call
  it, and inspect the result directly.
- Build a stub `me_mission.mission.coalition` tree containing a mix of marked
  (`Crate-01_sms`, `Barrel-02_sms #2`) and unmarked (`SAM-1`, hand-placed)
  static groups.
- Assert the rebuild selects exactly the marked groups, points `entry.group` at
  the live tables, and fills position/type/country from each.
- Assert an unmarked static is never selected (the strict guarantee).
- Keep the existing `group_is_live` predicate tests.

The end-to-end behavior (fly→exit→erase across a real reload) remains a manual
DCS check — it depends on the real ME reload cycle.

## Costs / limits

- Painted static names read `…_sms` in the ME unit list (invisible in-cockpit;
  these are scenery objects). Renaming off the suffix makes that static
  un-erasable — intentional.
- Pre-feature painted statics are not erasable after a reload (no marker).
- Live scan is O(static count) per erase-stroke-start.
- Part of the unreleased `0.27.0`; CHANGELOG note under the existing entry, no
  new version.
