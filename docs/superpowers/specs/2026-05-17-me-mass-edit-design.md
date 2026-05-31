# ME Mass Edit — Design

**Date:** 2026-05-17
**Status:** Approved (brainstorm phase, /write-it autonomy)
**Scope:** A new Mission Editor tool window (`Mass Edit`) for changing one property across many entities at once — sibling to the Prefab Manager. Window-only (no CLI half) for v1. Covers groups, units, waypoints, zones, drawings with a Maya-style scope toggle. Includes a generic property registry, a small set of plain-English named transforms (no regex), live preview, pre-flight validation, best-effort apply, and a single undo entry per Apply via a generalised undo bus.

## Goal

Ship a single window in the ME that lets a mission designer pick many entities at once and change one property on all of them — names, country, frequency, skill, callsign, fuel, waypoint altitude, waypoint speed, zone color, drawing thickness, etc. The window must work for non-technical users: every operation is named in plain English, every value is picked via a control (dropdown / spinner / color swatch / textbox), and a live "before → after" preview shows exactly what Apply will do before the user commits.

The deliverable is the ME-mod source for the window, the property registry seeded with the v1 properties, the transform primitives, the apply pipeline, a small generalisation of `undo.lua` to support multiple handler types, a menu entry, Lua mock tests, a release-gate smoke checklist, doc-sync updates, and a `version.lua` minor bump.

## User value

A mission with 30 groups already takes 30 clicks to set `frequency` one group at a time, and renaming half of them follows the same per-entity grind. Niels's typical missions are larger — 50+ groups across multiple sites. Today there is no tool for these chores; the workflow is "open each group's panel and re-type". Mass Edit replaces that with: marquee → open → pick property → pick operation → preview → Apply. Five clicks for any number of entities.

The Maya analogy from the brainstorm is load-bearing: in Maya, you marquee a mesh as an *object*, then toggle to *component mode* and the same selection becomes vertices / edges / faces. Mass Edit applies the same lens: your marquee picks groups, the scope toggle drills into units or waypoints inside those groups, properties light up per scope. Same physical selection, different editing surface — exactly the mental model mission designers already have from Maya/Blender.

## Non-goals

- **No CLI verb half for v1.** The existing per-entity verbs (`unit set-skill`, `group set-name`, ...) already let agents/scripts loop over a list. A `me bulk apply` JSON-spec verb is a plausible v2 follow-up; not in scope here.
- **No regex / Lua patterns.** Renames are built from named operations (prefix / suffix / find-and-replace plain text / auto-number / set-all). Regex would drive non-technical users off the tool. Power users can still chain per-entity verbs.
- **No multi-property batch in one Apply.** One property per Apply, one undo entry per Apply. Multi-property "recipes" wait until we know what people actually batch together.
- **No waypoint-type / waypoint-action mass edit.** These need per-category enums (`On Road` for ground vs `Turning Point` for air) and deserve their own follow-up spec. Rename + altitude + speed covers the bulk of waypoint mass-editing.
- **No persistence across DCS restarts.** The active property / operation / values / window position reset between window opens within a session (mid-session retained by `sms_window`). Cross-session memory is out of scope.
- **No "save operation as preset / recipe."** Out of scope; possibly v2.
- **No automatic re-snapshot when the user clicks the ME map.** The window has an explicit Refresh button (top-right of the scope-tab strip). Auto-refresh on map clicks would risk the user's checked rows vanishing because they accidentally clicked elsewhere.
- **No undo history beyond the single most-recent Apply.** This matches the existing `undo.lua` single-slot semantics. (Generalising to a stack is documented as a v2 follow-up in §10.)
- **No edits to triggers, conditions, actions, or trigger zones' linked-conditions.** Trigger surface is descriptor-driven and lives outside this scope.
- **No edits to airbase warehouses, resource panels, time-of-day, weather, or map-level mission settings.** Mass Edit operates on placed entities only.
- **No mixed-type loadout editing.** The `unit_loadout` property's allowed-values list depends on the unit's airframe type. If the checked unit set contains more than one airframe type, the operation is disabled with a tooltip ("Select units of a single airframe to mass-edit loadout"). This is a v1 simplification.

## Decisions (made during brainstorm or autonomously)

Numbered for reference from the plan and from future readers.

### From the brainstorm (user-approved)

1. **Selection model: hybrid marquee + browse-all.** Window opens onto the current ME marquee selection. When the marquee is empty, it opens to the same treeview populated from the whole mission. The treeview has columns and per-column filters (substring text + dropdowns).

2. **Property model: generic registry.** Each editable property is one declarative entry in `mass_edit_registry.lua`: `{id, scope, label, control, operations, reader, writer, preflight?, applies_to}`. The View renders UI from the registry. Adding a new mass-editable property is one registry entry plus, if needed, a new control kind — no UI patching.

3. **Scope toggle (Maya Object/Component-mode analogy).** Tabs at the top of the window: `Group · N`, `Unit · N`, `Waypoint · N`, `Zone · N`, `Drawing · N`. Scope is decoupled from selection — the marquee is the input, the scope is the lens. Switching scope rebuilds the treeview rows, the property dropdown, the columns, and the preview target count. Zone and Drawing tabs only appear (or are enabled) when those types are in the marquee.

4. **Named transforms (no regex).** The v1 operation primitives are:
   - `set_all` — every checked item gets the same new value.
   - `add_prefix` — prepend text to current value.
   - `add_suffix` — append text to current value.
   - `find_replace` — plain-text substring replace (case-sensitive); replaces *all* occurrences in the value, no regex, no captures.
   - `auto_number` — pattern with `{n}` token; user picks Start, Step, Pad-to-digits, and Order-by (current name alphabetical / selection order / position north→south / position west→east).
   - `offset` — for numeric properties: `current + delta`.
   - `toggle_set` — for 3-state booleans: `true` / `false` / `Leave unchanged` (the last is the default for mixed-current-value selections).

5. **One property per Apply.** Each Apply changes exactly one property. Single undo entry per Apply. Multi-property is out of scope.

6. **Window-only.** No `me bulk ...` CLI verb. Agents can still loop the existing per-entity verbs.

7. **Failure handling: pre-flight + best-effort.** Pre-flight validation runs on every plan row before any mutation, marking incompatible rows ✗ in the preview with a hover-reason. The user can deselect offenders or adjust the operation. On Apply, the loop is best-effort: per-item `pcall`, log+continue, summary toast at the end (`"21 changed · 2 failed"` with severity matched to the result mix).

8. **Mixed-current-value display.** When checked items have different current values for the active property, the property panel's "current" field shows `Mixed (n values)` (click to expand). The Operation defaults to `Set all to…` with no pre-filled new value — user must actively pick. Toggle properties default to `Leave unchanged` for mixed selections.

9. **Category-conditional applies_to in v1.** The registry includes an `applies_to` field listing DCS categories (`plane`, `helicopter`, `vehicle`, `ship`, `static`). The View filters the property dropdown to properties that apply to at least one item in the current marquee. Per-item mismatches show ✗ in the preview with reason `"category mismatch: <category>"`.

10. **Refresh button (top-right of scope-tab strip).** Re-runs `selection.snapshot_drilled(scope)` so the user can resync after marqueeing something different. No automatic re-snapshot.

11. **Live preview debounce (~150ms).** Each control keystroke recomputes the plan; debounce input so large selections stay responsive.

12. **Single panel refresh.** The apply pipeline calls `refresh_group_view` once per affected group at the end of the loop, not per mutation.

### Autonomous decisions (not asked in conversation, recorded here)

13. **Generalise `undo.lua` to a handler-based bus while preserving the prefab path.** The existing `M.record(injection_record)` API stays working unchanged — internally it now wraps the record in a `{handler='prefab', payload=injection_record}` shape and registers a `'prefab'` handler that runs the existing remove logic. A new `M.register_handler(name, fn)` API lets `mass_edit_ops` register a `'mass_edit'` handler. `M.undo()` dispatches based on the slot's handler. This is a small, additive refactor that costs ~30 lines and avoids creating a parallel mass-edit-only undo stack. (User said "single undo step on the project-wide undo bus" in brainstorm; the bus is currently prefab-specific but the user wasn't aware of that distinction.)

14. **Per-group "tag" for waypoint scope, not flat waypoint list.** When in Waypoint scope, treeview rows are `<group-name> / WP<idx>` with the group prefix shown in a dedicated column, so users can scan-by-group. Filtering by group in waypoint scope is the high-bit use case ("set altitudes for all Hornet-* waypoints").

15. **Property dropdown grouping.** The property `<select>` groups options visually by scope category (`-- Identity --` / `-- Behaviour --` / `-- Appearance --` / `-- Geometry --`) using `<optgroup>` semantics. Not strictly required, but the unit scope has 6+ properties at v1 and grouping aids scannability.

16. **Auto-number ordering: alphabetical by current name as default.** Most rename use cases sort by current name. Selection-order / position-N→S / position-W→E are alternatives in the same control.

17. **`{n}` is the only template token in v1.** Power-user tokens (`{old}`, `{old:1}`) are deferred. `{n}` covers the dominant use case ("Hornet-{n}" → Hornet-01..05). If users miss `{old}`, we add it.

18. **Open mechanism: `DCS-SMS → Mass Edit` menu entry.** Sibling to Prefab Manager / About / External execution. Toggles the window like Prefab Manager does. No keyboard shortcut for v1.

19. **Mixed-category statics in unit scope: the scope tab still shows.** If the marquee contains 3 plane groups + 2 static groups, Unit scope shows N units total, but the property dropdown filters down to properties whose `applies_to` includes at least one of the unit categories present. Trying to set `unit_skill` (which excludes static) on the mixed selection lights up ✗ for the static rows; user can deselect them or just hit Apply with the best-effort policy.

20. **Treeview is a flat sortable table per scope** (not a recursive tree). The Maya analogy compares scopes to "object vs component mode," not to a hierarchical Outliner. A flat table per scope with filter widgets at top is simpler and more honest to the data — waypoints are not really "nested under" units, they're nested under groups, and units don't contain waypoints. The "tree" branding in the brainstorm referred to "a list with columns" — confirmed by the user mentioning "treeview as well. having columns for country, type etc."

21. **Empty-marquee mode is the same window with a "Browse mission" banner** at the top of the scope tab strip, showing total mission counts. Same treeview, same scope tabs, no separate UI. User ticks rows directly. There is no "load mission list" tab — that distinction collapses into "the treeview is populated either from your marquee or from the whole mission, depending on what's selected when the window was opened."

22. **Spec slug & folder.** `docs/superpowers/specs/2026-05-17-me-mass-edit-design.md` (this file) and `docs/superpowers/plans/2026-05-17-me-mass-edit-design.md` (forthcoming plan), matching the repo's date-prefixed file pattern.

23. **Branch name.** `feature/me-mass-edit`, worked in `.worktrees/me-mass-edit/` per repo convention.

## Architecture

The tool is a single `sms_window`-chromed window living in the ME's Lua VM. Three logical layers inside it:

```
                      ┌─────────────────────────────────┐
   user input         │ View (mass_edit.lua)            │
       │              │                                 │
       └──────────────│  - sms_window chrome            │
                      │  - scope tab strip              │
                      │  - treeview + filters           │
                      │  - property panel               │
                      │  - preview table                │
                      │  - Apply / Cancel / Refresh     │
                      └──────────┬──────────────────────┘
                                 │
                  reads          │          calls
                                 ▼
                      ┌─────────────────────────────────┐
                      │ Registry (mass_edit_registry.lua) │
                      │                                 │
                      │  pure data:                     │
                      │  {id, scope, label, control,    │
                      │   operations, reader, writer,   │
                      │   preflight?, applies_to}       │
                      └─────────────────────────────────┘
                                 ▲
                                 │ reads & dispatches
                                 │
                      ┌──────────┴──────────────────────┐
                      │ Apply pipeline                  │
                      │ (mass_edit_ops.lua)             │
                      │                                 │
                      │  1. build plan                  │
                      │  2. apply transform → new value │
                      │  3. pre-flight                  │
                      │  4. snapshot for undo           │
                      │  5. mutate (pcall per item)     │
                      │  6. single panel refresh        │
                      │  7. push to undo bus            │
                      │  8. summary toast               │
                      └─────┬─────────────────┬─────────┘
                            │                 │
                  uses primitives        registers handler
                            │                 │
                            ▼                 ▼
                ┌────────────────────┐ ┌──────────────────┐
                │ Transforms         │ │ undo.lua         │
                │ (mass_edit_        │ │ (generalised:    │
                │  transforms.lua)   │ │  handler-based)  │
                └────────────────────┘ └──────────────────┘
                            ▲
                            │ reads marquee
                            │
                ┌───────────┴────────┐
                │ selection.lua      │
                │ (extended:         │
                │  snapshot_drilled) │
                └────────────────────┘
```

Nothing here talks to the running mission. The tool mutates the live ME mission table via `require('me_mission').mission` — same path the Prefab Manager and verbs use. The framework runtime (`sms.*`) is uninvolved.

## Components

All paths under `tools/me-mod/lua/dcs_sms_me/` unless noted. Three new files, two existing files extended, one existing file with a one-line edit.

### `mass_edit.lua` (NEW)

The window. Single module exporting `M.show()`, `M.hide()`, `M.toggle()`. Owns the local state for the open window instance:

- `W.sms_window` — the `sms_window` handle (chrome).
- `W.scope` — active scope (`'group'` | `'unit'` | `'waypoint'` | `'zone'` | `'drawing'`).
- `W.source` — `'marquee'` or `'mission'` (where the entity pool came from).
- `W.pool` — per-scope arrays of entity refs (with parent-group back-pointers for unit/waypoint).
- `W.checked` — per-scope set of entity refs the user has ticked. Switching scope preserves the previous scope's checked set.
- `W.filters` — per-scope filter widget state (name substring, country dropdown, etc.).
- `W.property_id` — the registry entry currently picked in the dropdown (e.g. `'unit_skill'`).
- `W.operation` — the operation chosen for that property (e.g. `'set_all'`).
- `W.op_args` — operation-specific arg table (e.g. `{value='Excellent'}` or `{pattern='Hornet-{n}', start=1, step=1, pad=2, order='alpha'}`).
- `W.plan` — last-computed plan rows (cached, recomputed on debounce tick).
- `W.debounce_deadline` — wall-clock time at which to recompute the plan after the last input.

Public functions:

```
M.show()      — idempotent; instantiate sms_window if absent, otherwise call :show()
M.hide()      — idempotent; calls W.sms_window:hide() and clears transient state.
M.toggle()    — call M.hide() if open else M.show().
```

Internal helpers (`local`):

- `rebuild_pool()` — call `selection.snapshot_drilled(W.scope)` (or the mission-wide variant when `W.source == 'mission'`), refresh `W.pool`.
- `apply_filters()` — produce the filtered row list for the treeview from `W.pool` + `W.filters`.
- `rebuild_treeview()` — wipe and rebuild the treeview rows from `apply_filters()`.
- `rebuild_property_panel()` — given `W.scope`, populate the property `<select>` from the registry entries whose `scope == W.scope` and whose `applies_to` intersects the categories present in `W.pool`. Render operation `<select>` + the operation's args inputs based on the registry entry's `control` field.
- `recompute_plan()` — call `mass_edit_ops.compute_plan(W.scope, W.checked, W.property_id, W.operation, W.op_args)`. Cache in `W.plan`.
- `rebuild_preview()` — render the preview table from `W.plan`.
- `on_input_changed()` — set `W.debounce_deadline = os.clock() + 0.15`; the next `UpdateManager` tick that crosses it calls `recompute_plan()` then `rebuild_preview()`.
- `on_apply_clicked()` — call `mass_edit_ops.apply_plan(W.plan)`, render summary in footer, rebuild preview against the new state.
- `on_refresh_clicked()` — call `rebuild_pool()`, drop checked entries for items no longer in the pool, rebuild everything downstream.
- `on_scope_changed(new_scope)` — set `W.scope`, call `rebuild_pool` → `rebuild_treeview` → `rebuild_property_panel` → `recompute_plan` → `rebuild_preview`.

The dxgui widgets are constructed lazily on first show and re-used on subsequent show/hide cycles. The window is sized 900×600 by default with a `min_size` of 720×500. The split between treeview and property/preview panels is 50/50.

### `mass_edit_registry.lua` (NEW)

Pure data. Returns an array of property entries. The full v1 seed list (21 entries, organised by scope):

```lua
return {
  -- ============================================================
  -- group scope (6 entries)
  -- ============================================================
  {
    id = 'group_name',
    scope = 'group',
    label = 'Name',
    category = 'Identity',
    control = { kind = 'string' },
    operations = { 'set_all', 'add_prefix', 'add_suffix', 'find_replace', 'auto_number' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship', 'static' },
    reader = function(g) return g.name end,
    writer = function(g, value)
      local Mission = require('me_mission')
      local ok = Mission.renameGroup(g, value)
      if not ok then return false, 'rename rejected by Mission.renameGroup' end
      return true
    end,
    preflight = function(g, new_name, ctx)
      if not new_name or new_name == '' then return false, 'name cannot be empty' end
      if ctx.names_seen[new_name] then return false, 'name collision (within batch): '..new_name end
      ctx.names_seen[new_name] = true
      return true
    end,
  },

  {
    id = 'group_country',
    scope = 'group',
    label = 'Country',
    category = 'Identity',
    control = { kind = 'enum', values_from = 'country_list' },  -- resolved at runtime from sms.countries or hardcoded list
    operations = { 'set_all' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship', 'static' },
    reader = function(g) return g.country end,
    writer = function(g, value)
      g.country = value  -- ME redraws on next panel refresh
      return true
    end,
  },

  {
    id = 'group_frequency',
    scope = 'group',
    label = 'Frequency (MHz)',
    category = 'Behaviour',
    control = { kind = 'number', min = 0.1, max = 400, step = 0.5 },
    operations = { 'set_all', 'offset' },
    applies_to = { 'plane', 'helicopter' },
    reader = function(g) return g.frequency end,
    writer = function(g, value)
      g.frequency = value
      return true
    end,
  },

  {
    id = 'group_hidden',
    scope = 'group',
    label = 'Hidden on map',
    category = 'Appearance',
    control = { kind = 'toggle' },
    operations = { 'toggle_set' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship', 'static' },
    reader = function(g) return g.hidden end,
    writer = function(g, value) g.hidden = value; return true end,
  },

  {
    id = 'group_late_activation',
    scope = 'group',
    label = 'Late activation',
    category = 'Behaviour',
    control = { kind = 'toggle' },
    operations = { 'toggle_set' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship' },
    reader = function(g) return g.lateActivation end,
    writer = function(g, value) g.lateActivation = value; return true end,
  },

  {
    id = 'group_uncontrolled',
    scope = 'group',
    label = 'Uncontrolled',
    category = 'Behaviour',
    control = { kind = 'toggle' },
    operations = { 'toggle_set' },
    applies_to = { 'plane', 'helicopter' },
    reader = function(g) return g.uncontrolled end,
    writer = function(g, value) g.uncontrolled = value; return true end,
  },

  -- ============================================================
  -- unit scope (5 entries)
  -- ============================================================
  {
    id = 'unit_name',
    scope = 'unit',
    label = 'Name',
    category = 'Identity',
    control = { kind = 'string' },
    operations = { 'set_all', 'add_prefix', 'add_suffix', 'find_replace', 'auto_number' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship', 'static' },
    reader = function(u) return u.name end,
    writer = function(u, value)
      local Mission = require('me_mission')
      local ok = Mission.renameUnit(u, value)
      if not ok then return false, 'rename rejected by Mission.renameUnit' end
      return true
    end,
    preflight = function(u, new_name, ctx)
      if not new_name or new_name == '' then return false, 'name cannot be empty' end
      if ctx.names_seen[new_name] then return false, 'name collision (within batch): '..new_name end
      ctx.names_seen[new_name] = true
      return true
    end,
  },

  {
    id = 'unit_skill',
    scope = 'unit',
    label = 'Skill',
    category = 'Behaviour',
    control = { kind = 'enum', values = { 'Average', 'Good', 'High', 'Excellent', 'Random', 'Client', 'Player' } },
    operations = { 'set_all' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship' },
    reader = function(u) return u.skill end,
    writer = function(u, value) u.skill = value; return true end,
  },

  {
    id = 'unit_callsign',
    scope = 'unit',
    label = 'Callsign',
    category = 'Identity',
    control = { kind = 'string' },
    operations = { 'set_all', 'add_prefix', 'add_suffix', 'find_replace', 'auto_number' },
    applies_to = { 'plane', 'helicopter' },
    reader = function(u) return type(u.callsign) == 'table' and u.callsign.name or u.callsign end,
    writer = function(u, value)
      -- DCS stores callsign as either a string or {name=, [1..3]=preset} table.
      -- Preserve table shape if present, else assign raw string.
      if type(u.callsign) == 'table' then u.callsign.name = value
      else u.callsign = value end
      return true
    end,
  },

  {
    id = 'unit_loadout',
    scope = 'unit',
    label = 'Loadout (named, same airframe)',
    category = 'Behaviour',
    control = { kind = 'enum', values_from = 'loadouts_for_unit_type' },  -- resolved dynamically
    operations = { 'set_all' },
    applies_to = { 'plane', 'helicopter' },
    reader = function(u) return u.payload and u.payload.name or '(none)' end,
    writer = function(u, value)
      -- Same code path as verbs.unit_set_loadout, minus arg validation.
      -- Implementation in mass_edit_ops calls into weapons_db.apply_named_loadout(u, value).
      local ok, err = require('dcs_sms_me.weapons_db').apply_named_loadout(u, value)
      if not ok then return false, err or 'loadout apply failed' end
      return true
    end,
    preflight = function(u, value, ctx)
      -- Establish ctx.unit_type on first call; reject subsequent units that differ.
      local t = u.type
      if not ctx.unit_type then ctx.unit_type = t end
      if ctx.unit_type ~= t then
        return false, 'mixed airframes (' .. ctx.unit_type .. ' and ' .. t .. ') — loadout requires single airframe'
      end
      return true
    end,
  },

  {
    id = 'unit_fuel',
    scope = 'unit',
    label = 'Fuel (kg)',
    category = 'Behaviour',
    control = { kind = 'number', min = 0, max = 200000, step = 100 },
    operations = { 'set_all', 'offset' },
    applies_to = { 'plane', 'helicopter' },
    reader = function(u) return u.payload and u.payload.fuel end,
    writer = function(u, value)
      u.payload = u.payload or {}
      u.payload.fuel = value
      return true
    end,
  },

  -- ============================================================
  -- waypoint scope (3 entries — v1)
  -- ============================================================
  {
    id = 'waypoint_name',
    scope = 'waypoint',
    label = 'Name',
    category = 'Identity',
    control = { kind = 'string' },
    operations = { 'set_all', 'add_prefix', 'add_suffix', 'find_replace', 'auto_number' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship' },
    reader = function(wp) return wp.name end,
    writer = function(wp, value) wp.name = value; return true end,
  },

  {
    id = 'waypoint_alt',
    scope = 'waypoint',
    label = 'Altitude (m)',
    category = 'Geometry',
    control = { kind = 'number', min = 0, max = 50000, step = 100 },
    operations = { 'set_all', 'offset' },
    applies_to = { 'plane', 'helicopter' },
    reader = function(wp) return wp.alt end,
    writer = function(wp, value) wp.alt = value; return true end,
  },

  {
    id = 'waypoint_speed',
    scope = 'waypoint',
    label = 'Speed (m/s)',
    category = 'Geometry',
    control = { kind = 'number', min = 0, max = 1500, step = 5 },
    operations = { 'set_all', 'offset' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship' },
    reader = function(wp) return wp.speed end,
    writer = function(wp, value) wp.speed = value; return true end,
  },

  -- ============================================================
  -- zone scope (4 entries)
  -- ============================================================
  {
    id = 'zone_name',
    scope = 'zone',
    label = 'Name',
    category = 'Identity',
    control = { kind = 'string' },
    operations = { 'set_all', 'add_prefix', 'add_suffix', 'find_replace', 'auto_number' },
    applies_to = { '*' },  -- zones have no category
    reader = function(z) return z.name end,
    writer = function(z, value) z.name = value; return true end,
    preflight = function(z, new_name, ctx)
      if not new_name or new_name == '' then return false, 'name cannot be empty' end
      if ctx.names_seen[new_name] then return false, 'name collision (within batch): '..new_name end
      ctx.names_seen[new_name] = true
      return true
    end,
  },

  {
    id = 'zone_color',
    scope = 'zone',
    label = 'Color',
    category = 'Appearance',
    control = { kind = 'color' },
    operations = { 'set_all' },
    applies_to = { '*' },
    reader = function(z) return z.color end,
    writer = function(z, value) z.color = value; return true end,
  },

  {
    id = 'zone_radius',
    scope = 'zone',
    label = 'Radius (m)',
    category = 'Geometry',
    control = { kind = 'number', min = 1, max = 500000, step = 100 },
    operations = { 'set_all', 'offset' },
    applies_to = { '*' },
    reader = function(z) return z.radius end,
    writer = function(z, value) z.radius = value; return true end,
  },

  {
    id = 'zone_hidden',
    scope = 'zone',
    label = 'Hidden on map',
    category = 'Appearance',
    control = { kind = 'toggle' },
    operations = { 'toggle_set' },
    applies_to = { '*' },
    reader = function(z) return z.hidden end,
    writer = function(z, value) z.hidden = value; return true end,
  },

  -- ============================================================
  -- drawing scope (3 entries)
  -- ============================================================
  {
    id = 'drawing_name',
    scope = 'drawing',
    label = 'Name',
    category = 'Identity',
    control = { kind = 'string' },
    operations = { 'set_all', 'add_prefix', 'add_suffix', 'find_replace', 'auto_number' },
    applies_to = { '*' },
    reader = function(d) return d.name end,
    writer = function(d, value) d.name = value; return true end,
  },

  {
    id = 'drawing_color',
    scope = 'drawing',
    label = 'Color',
    category = 'Appearance',
    control = { kind = 'color' },
    operations = { 'set_all' },
    applies_to = { '*' },
    reader = function(d) return d.colorString or d.color end,
    writer = function(d, value)
      if d.colorString ~= nil then d.colorString = value
      else d.color = value end
      return true
    end,
  },

  {
    id = 'drawing_thickness',
    scope = 'drawing',
    label = 'Line thickness',
    category = 'Appearance',
    control = { kind = 'number', min = 1, max = 20, step = 1 },
    operations = { 'set_all', 'offset' },
    applies_to = { '*' },
    reader = function(d) return d.thickness end,
    writer = function(d, value) d.thickness = value; return true end,
  },
}
```

**Notes on the registry:**

- `category` groups the property dropdown into `<optgroup>` headers (`-- Identity --`, `-- Behaviour --`, `-- Appearance --`, `-- Geometry --`).
- `applies_to = { '*' }` means "no DCS category filter" — used for zones/drawings/waypoints where the entity type doesn't subdivide by DCS unit category.
- `control.values_from` is a string token that the View resolves to a values-source function at panel build time. Two tokens in v1: `'country_list'` (returns the standard DCS country list) and `'loadouts_for_unit_type'` (returns named loadouts known for the current unit's type, looked up via `weapons_db`). Resolution is lazy so the registry doesn't need to import live ME modules at load time.
- `preflight(entity, new_value, ctx)` is optional. `ctx` is a per-batch table shared across all rows; entries seed it with their own keys (`names_seen`, `unit_type`, ...). Returning `false, 'reason'` marks the row ✗.
- `reader`/`writer` are simple field assignments where possible. Name properties go through `Mission.renameGroup` / `Mission.renameUnit` to leverage the ME's collision check.

### `mass_edit_ops.lua` (NEW)

The apply pipeline. Stateless functions:

```
mass_edit_ops.compute_plan(scope, checked_entities, property_id, operation, op_args) → plan
mass_edit_ops.apply_plan(plan) → { changed=N, failed=M, errors=[{name, reason}], affected_groups=[g,...] }
```

`plan` shape:

```
plan = {
  property_id = 'unit_skill',
  operation   = 'set_all',
  op_args     = { value = 'Excellent' },
  rows        = [
    { entity = unit_ref, group = group_ref, old = 'Average', new = 'Excellent', ok = true, error = nil },
    { entity = unit_ref, group = group_ref, old = 'High',    new = 'Excellent', ok = true, error = nil },
    { entity = unit_ref, group = group_ref, old = 'Average', new = nil,         ok = false, error = 'category mismatch: static' },
    ...
  ],
}
```

Inside `compute_plan`:

1. Look up the registry entry for `property_id`.
2. Initialise `ctx = {}` for cross-row pre-flight state.
3. For each checked entity:
   - Check `applies_to` against the entity's category (resolved via `entity.category` for groups, looking up the parent group for units/waypoints). Mismatch → `ok=false, error='category mismatch: <cat>'`.
   - Read `old = registry.reader(entity)`.
   - Apply the transform: `new = transforms.<operation>(old, op_args, row_index)`.
   - If registry has `preflight`, call it with `(entity, new, ctx)`; failure → `ok=false, error=<reason>`.
   - Else `ok=true`.
   - Append row.

Inside `apply_plan`:

1. Build `undo_snapshot = { rows = [{ entity, property_id, old }, ...] }` from `ok=true` rows. (Freshness is the View's concern — `on_apply_clicked` always calls `recompute_plan` synchronously before `apply_plan`, so by the time we land here the plan reflects the current inputs.)
2. For each `ok=true` row:
   - `ok, err = pcall(registry.writer, entity, new_value)`.
   - On failure, flip row to `ok=false, error=err`.
3. Collect `affected_groups`: for each successfully-mutated row, the unique parent group set.
4. For each affected group, `refresh_group_view(g)` once. (`refresh_group_view` is `local` inside `verbs.lua` today; the plan extracts it into a tiny shared module `me_refresh.lua` that both `verbs.lua` and `mass_edit_ops.lua` require — see plan tasks.)
5. If any rows succeeded, push the `undo_snapshot` (including `affected_groups`, so undo can refresh them too) to the generalised undo bus with handler `'mass_edit'`.
6. Return summary: `{ changed, failed, errors, affected_groups }`.

### `mass_edit_transforms.lua` (NEW)

Pure functions, one per operation. Heavy unit-test target.

```
M.set_all(old, args, idx)       → returns args.value
M.add_prefix(old, args, idx)    → returns args.text .. (old or '')
M.add_suffix(old, args, idx)    → returns (old or '') .. args.text
M.find_replace(old, args, idx)  → string.gsub(old or '', escape_pattern(args.find), args.replace)
M.auto_number(old, args, idx)   → render(args.pattern, args.start + (idx-1)*args.step, args.pad)
                                  -- idx is 1-based; ordering is decided in compute_plan, not here.
M.offset(old, args, idx)        → (old or 0) + args.delta
M.toggle_set(old, args, idx)    → args.value   -- args.value is true | false | nil ('leave unchanged')
                                  -- nil tells compute_plan to skip the row (effectively a no-op).
```

`escape_pattern` is a small helper that escapes Lua-pattern metacharacters in `args.find` so users can paste any literal substring (`-`, `.`, `+`, `(`, `)`, etc.) without surprise matches.

`render(pattern, n, pad)` substitutes `{n}` in `pattern` with `string.format('%0'..pad..'d', n)`. Multiple `{n}` tokens in a pattern all expand to the same number (rare case, but cheap to support).

### `selection.lua` (EXISTING, extended)

Today `selection.snapshot()` returns groups / zones / drawings / nav_points from the current marquee. Add:

```
M.snapshot_drilled(scope) → {
  ok           = boolean,
  scope        = '<scope>',
  source       = 'marquee' | 'mission',
  pool         = [entity_ref, ...],
  parent_map   = { [entity_ref] = group_ref }  -- for unit / waypoint scope; identity-mapped for group scope
}
```

Behaviour:

- `scope='group'` — call existing `snapshot()`, return `snap.groups` as `pool`, identity `parent_map`. If `snap.groups` is empty, switch `source = 'mission'` and walk `require('me_mission').mission.coalition` for every group.
- `scope='unit'` — same group source as above; flatten `g.units` into `pool`, mapping each unit → its group in `parent_map`.
- `scope='waypoint'` — same group source; flatten `g.route.points` into `pool`, mapping each waypoint → its group. Skip groups whose route is absent (statics).
- `scope='zone'` — call `snapshot()`; return `snap.zones`. Empty → fall back to mission-wide zone list.
- `scope='drawing'` — call `snapshot()`; return `snap.drawings`. Empty → fall back to mission-wide drawing list.

`pool` ordering: stable (insertion order from the mission walk). The treeview can re-sort by column header.

### `undo.lua` (EXISTING, generalised)

Refactor to a handler-based slot while preserving the existing prefab API.

New shape:

```lua
local M = {}
local handlers = {}      -- name → fn(payload) -> ok, err
local slot = nil         -- { handler='<name>', payload=<...> } or nil

function M.register_handler(name, fn)
  handlers[name] = fn
end

-- New, generic record API.
function M.record_generic(handler_name, payload)
  if not handlers[handler_name] then
    log.write('sms.me.undo', log.ERROR, 'unknown handler: '..tostring(handler_name))
    return
  end
  slot = { handler = handler_name, payload = payload }
end

-- Old prefab-only API — preserved verbatim. Internally now records via the
-- generic path with handler='prefab'.
function M.record(injection_record)
  slot = { handler = 'prefab', payload = injection_record }
end

function M.add_airbase_snapshots(snaps)
  if slot == nil or slot.handler ~= 'prefab' or type(snaps) ~= 'table' then return end
  slot.payload.airbase_snapshots = slot.payload.airbase_snapshots or {}
  for _, s in ipairs(snaps) do
    slot.payload.airbase_snapshots[#slot.payload.airbase_snapshots + 1] = s
  end
end

function M.has_record() return slot ~= nil end
function M.clear() slot = nil end

function M.undo()
  if slot == nil then return nil, 'nothing to undo' end
  local s = slot
  slot = nil
  local fn = handlers[s.handler]
  if not fn then return nil, 'no handler for '..tostring(s.handler) end
  return fn(s.payload)
end

-- Register the prefab handler on module load — preserves the existing
-- behaviour exactly (the function body is the current undo() body).
M.register_handler('prefab', function(r)
  -- ... [existing remove_groups/remove_zones/remove_drawings/restore_airbases logic] ...
end)

return M
```

`mass_edit_ops` then calls:

```lua
require('dcs_sms_me.undo').register_handler('mass_edit', function(snapshot)
  local errors = 0
  for _, row in ipairs(snapshot.rows) do
    local entry = registry.find(row.property_id)
    if entry then
      local ok = pcall(entry.writer, row.entity, row.old)
      if not ok then errors = errors + 1 end
    end
  end
  -- Refresh once per affected group on undo too.
  for _, g in ipairs(snapshot.affected_groups) do
    pcall(refresh_group_view, g)
  end
  return true, errors > 0 and (errors .. ' partial failures') or nil
end)
```

The registration happens during `mass_edit_ops` module load. `mass_edit_ops` is required by `mass_edit.lua` when the window first opens; by then the prefab handler is already registered via `undo.lua`'s own module load.

### `menu.lua` (EXISTING, one-line edit)

Add a `Mass Edit` entry under the `DCS-SMS` menu, sibling to `Prefab Manager`. Single line in the existing install function:

```lua
local mass_edit_item = menu:newItem('Mass Edit')
mass_edit_item:setSkin(prefab_item_skin)  -- reuse sibling skin
mass_edit_item.func = function() require('dcs_sms_me.mass_edit').toggle() end
menu:insertSubItem(mass_edit_item, <position>)
```

Position: directly below `Prefab Manager`, above `About`.

### `init.lua` (EXISTING, no edit needed)

`init.lua` already calls `menu.install` — the new menu entry is added inside that. `init.lua` does *not* need to require `mass_edit.lua` at boot — the `menu_item.func` defers loading until the user clicks the menu entry. This keeps the boot path slim.

## Apply pipeline (detailed walkthrough)

User clicks **Apply** with `property_id='unit_skill'`, `operation='set_all'`, `op_args={value='Excellent'}`, and 23 checked unit refs in `W.checked.unit`:

1. **`compute_plan`** (already running on debounce — but called again at click time to guarantee freshness):
   - For each checked unit, check `applies_to` (the unit's parent-group `category`). 21 of 23 are `plane` (pass); 2 are `static` (`unit_skill.applies_to` excludes static → `ok=false, error='category mismatch: static'`).
   - For each passing unit, `old = u.skill`, `new = 'Excellent'`. No `preflight` on `unit_skill` (enum is constrained by the dropdown).
   - 21 rows `ok=true`, 2 rows `ok=false`. Plan is built.

2. **Pre-Apply UI gate.** Apply button enabled iff `plan.ok_count > 0`. With 21 ok rows, it's enabled. Footer shows `21 to apply · 2 mismatched (hover preview for reasons)`.

3. **`apply_plan`**:
   - Stale check: plan timestamp < 5s old → proceed.
   - Snapshot: for each `ok=true` row, capture `{entity=u, property_id='unit_skill', old='Average'|'High'|...}`. 21 snapshots.
   - Mutate loop: `pcall(registry.find('unit_skill').writer, u, 'Excellent')` for each. Any throws flip the row to `ok=false`. None throw in this run.
   - Collect `affected_groups`: 5 unique groups (the parent groups of the 21 units).
   - Refresh: call `refresh_group_view(g)` once per affected group.
   - Push undo: `undo.record_generic('mass_edit', { rows=snapshots, affected_groups=affected_groups })`.
   - Return `{ changed=21, failed=2, errors=[<reasons>], affected_groups=5 }`.

4. **Footer toast.** `sms_window:set_status('21 changed · 2 mismatched (category=static)', 'warning')`. (`'success'` if `failed==0`, `'error'` if `changed==0`.)

5. **Post-apply state.** `recompute_plan()` re-reads `reader()` for the now-mutated entities; preview now shows all 21 rows as `Excellent → Excellent` (no diff, suppressed from view), and the 2 static rows still show ✗. User can pick a different property and continue editing.

6. **Ctrl+Z while window has focus.** Calls `sms_window`'s `on_undo` handler, which by default calls `require('dcs_sms_me.undo').undo()`. The dispatch lands on the `'mass_edit'` handler, restoring the 21 skill values. Single keystroke reverts the whole batch.

## UX details

### Window layout

`sms_window` chrome around a `Group` widget split vertically:

- **Top band (~32px):** scope tab strip + Refresh button.
- **Body (split 50/50 horizontally):**
  - **Left:** filter row + treeview (sortable columns).
  - **Right:** property panel (property `<select>`, operation `<select>`, op-arg inputs) + preview table + Apply/Cancel.
- **Footer:** `sms_window` standard status band.

Min size 720×500. Default size 900×600. The Apply button is right-aligned in the bottom-right of the right panel, always visible.

### Per-scope column sets

| Scope | Columns (left to right) | Sort default | Filter widgets |
|---|---|---|---|
| Group | ☐, Name, Country, Type, # Units | Name asc | Name substring, Country dropdown, Type dropdown |
| Unit | ☐, Name, Type, Skill, Group | Name asc | Name substring, Type dropdown, Skill dropdown |
| Waypoint | ☐, Group, #, Type, Alt, Speed | Group asc, # asc | Group dropdown, Type dropdown |
| Zone | ☐, Name, Radius | Name asc | Name substring |
| Drawing | ☐, Name, Layer | Name asc | Name substring, Layer dropdown |

`Type` for unit scope is the DCS airframe / vehicle / ship type id (`F/A-18C`, `T-90`, ...). For group scope, it's the DCS category (`plane`, `helicopter`, `vehicle`, `ship`, `static`).

### Property panel layout

Three rows:

- **Property** `<select>` — registry entries with `scope == active_scope`, filtered to those whose `applies_to` intersects the categories in `W.pool`. Grouped by `category` via `<optgroup>`.
- **Operation** `<select>` — entries from the picked property's `operations` list, rendered with human labels (`set_all → "Set all to one value"`, `add_prefix → "Add prefix"`, etc.).
- **Args** — operation-specific. `set_all` → a single value input matching the property's control kind (textbox / dropdown / spinner / color swatch / 3-state toggle). `auto_number` → pattern textbox + Start + Step + Pad + Order dropdown. `offset` → delta spinner. `find_replace` → Find + Replace textboxes. `add_prefix` / `add_suffix` → text textbox.

Mixed-current-value sentinel: above the Args row, a small label says `Current: <value>` or `Current: Mixed (n different values)`. For toggle controls in mixed state, the 3-state defaults to `Leave unchanged`.

### Preview table layout

Three columns: `Name`, `→ Before`, `After`. ✗ marker (red) next to `After` when row is `ok=false`, with the error in a tooltip. Sortable by Name. Footer of the preview shows `N to apply · M mismatched`.

### Apply button behaviour

- Disabled when `plan.ok_count == 0`.
- Tooltip on hover when disabled: e.g. `"No rows match this property's allowed categories. Switch scope or pick another property."`
- Click → `apply_plan` → toast in footer. The button stays enabled if the plan still has ok rows after (useful for re-applying after a partial failure).

### Refresh button behaviour

- Top-right of the scope tab strip. Re-runs `selection.snapshot_drilled(W.scope)`, recomputes `W.pool`, drops `W.checked` entries for items no longer in the pool, rebuilds treeview / property panel / preview.
- No confirmation dialog — Refresh is non-destructive (doesn't mutate the mission, just re-reads it).

### Empty-marquee mode

When `selection.snapshot()` returns empty groups/zones/drawings:
- `W.source = 'mission'`.
- Pool is filled from the whole mission table.
- A small banner above the scope tab strip reads `Browsing whole mission (no marquee)`.
- Otherwise the UI is identical.

## Error handling & failure model

Three layers:

1. **Pre-flight (in `compute_plan`).** Static, category, name-collision, mixed-airframe failures land here. Rows show ✗ in the preview before the user clicks Apply. The user can deselect offenders, narrow the filter, or change the operation.

2. **Runtime (in `apply_plan`).** Each `writer(entity, new_value)` runs under `pcall`. A throw → row flips to `ok=false, error=<message>`. Loop continues. Failed rows do NOT get pushed to the undo snapshot — only the succeeded ones do.

3. **Undo runtime (in the `'mass_edit'` handler).** Each `writer(entity, old_value)` runs under `pcall`. Per-item failures are counted; the function returns `true, "<n> partial failures"`. `sms_window`'s `default_on_undo` flashes the message in the footer.

### Logging tags

All log calls use `log.write('sms.me.mass_edit', log.<level>, msg)`. `sms.me.mass_edit.transforms`, `sms.me.mass_edit.ops`, `sms.me.mass_edit.registry` for sub-tags. Consistent with the existing `sms.me.*` taxonomy.

### Never throw out of public functions

`M.show / M.hide / M.toggle / mass_edit_ops.compute_plan / mass_edit_ops.apply_plan` all wrap their bodies in outer `pcall`. A thrown error degrades to a footer toast `"Internal error: <msg> (logged)"` rather than crashing the user's editor session.

## Testing

### Lua mock tests (`tools/me-mod/test/`)

New harness file: `test_mass_edit.lua`. Coverage:

- **`mass_edit_transforms.lua`** — pure functions, easy. For each transform:
  - `set_all`, `add_prefix`, `add_suffix`, `find_replace` (incl. metachar-escape via the `.` and `-` test), `auto_number` (incl. pad and step), `offset` (incl. starting from nil), `toggle_set` (incl. `nil`/"leave unchanged" path).
- **`mass_edit_registry.lua`** — load the module, assert:
  - Every entry has the required keys (`id`, `scope`, `label`, `control`, `operations`, `applies_to`, `reader`, `writer`).
  - All `scope` values are in the allowed set.
  - All `operations` values exist in `mass_edit_transforms`.
  - All `applies_to` values are in the allowed category set or `'*'`.
- **`mass_edit_ops.compute_plan`** — using `mock_me_mission.lua`:
  - 5 plane units, set skill to Excellent → 5 ok rows.
  - 3 plane + 2 static units, set skill to Excellent → 3 ok + 2 ✗ (category mismatch).
  - 3 plane units, set fuel to 10000 → 3 ok rows.
  - Auto-number rename over 5 groups with collision (two ids would resolve to the same new name) → ok rows except the collisions.
- **`mass_edit_ops.apply_plan`** — mock mission with 3 units; apply skill change; assert each unit's `.skill` updated; assert undo snapshot has 3 entries.
- **`undo.register_handler / record_generic / undo`** — register a fake handler, record, dispatch undo, assert handler called with the payload.
- **Preserved prefab path** — call `undo.record(<fake injection_record>)`, then `undo.undo()`; the existing prefab handler should still run (mocked to set a flag). Confirms generalisation didn't break the existing path.

Target test count: ~25 cases across the suite.

### Manual smoke (release-gate checklist)

Append to `docs/release-gate/me-mod-smoke.md`:

```
## Mass Edit (v0.X.Y+)

- [ ] DCS-SMS → Mass Edit opens the window. Closes via X.
- [ ] Marquee 3 groups → window opens to Group scope with 3 rows checked.
- [ ] Switch to Unit scope → rows now show all units within the 3 groups.
- [ ] Pick property Skill → Set all to Excellent → Apply → footer shows "N changed".
- [ ] Ctrl+Z (window focused) reverts the skill change. Footer flashes "undone".
- [ ] Auto-number rename over 5 groups: pattern "Hornet-{n}", start 1, pad 2, order Name asc. Preview matches. Apply succeeds. Ctrl+Z reverts.
- [ ] Mixed plane + static marquee, scope=Unit, pick Skill. Static rows show ✗ in preview. Apply runs on the plane rows only.
- [ ] Marquee 1 zone, scope=Zone, Set color → red. Apply. Map redraws.
- [ ] Marquee 0 things, open window → "Browsing whole mission" banner shows.
- [ ] After applying a Mass Edit then placing a prefab, Ctrl+Z reverts the prefab placement (most recent action) — single-slot bus semantics preserved.
```

### Go tests

None — no CLI surface.

## Performance budget

- **Plan computation** on 500 rows should complete in < 50ms (pure-table walk, no I/O). Preview render dominates; that's a dxgui concern handled by debouncing input at 150ms.
- **Apply** on 500 rows: per-row `pcall + writer + field write` is microseconds; the `refresh_group_view` call per affected group is the cost — but it's once per group, not per row. For 5 groups: < 100ms total. Acceptable.
- **Undo** is symmetric — same cost as Apply.

If profiling shows the preview rebuild on a 500-row plan is the bottleneck, V2 can cap the visible rows to the first 100 with an "… N more" footer (mirroring what the Prefab Manager does for prefab lists). Out of scope for v1.

## Doc-sync + version

### Doc updates landing in the same commit-set

- **`tools/me-mod/AGENTS.md` §2.9** — the existing "sms_window chrome (for new tool windows)" section names "mass-rename tool, force-build tool, etc." as plausible follow-ups. Update to mention `mass_edit.lua` as the second concrete user (Prefab Manager being the first), with the same require-pattern note. One-paragraph addition.
- **`tools/me-mod/AGENTS.md` Part 1 §1.4 verb namespace table** — NO CHANGE. We're not adding CLI verbs.
- **`docs/cli/`** — NO REGEN. No new verbs.
- **`docs/superpowers/specs/`** — this file.
- **`docs/superpowers/plans/`** — the forthcoming plan.
- **`docs/release-gate/me-mod-smoke.md`** — append the Mass Edit checklist (above).
- **`CHANGELOG.md`** — new entry under ME-mod section: `feat(me-mod): Mass Edit tool window (v0.X.Y) — bulk-edit names / country / skill / waypoint altitude / etc. across selections`.
- **`tools/me-mod/lua/dcs_sms_me/version.lua`** — bump.

### Version bump

New public UI feature → **minor** bump under semver-0.x rules. Current version is `0.8.1` (per recent commit `release(me-mod): v0.8.1 ...`). New version: **`0.9.0`**. Tag name: `me-mod-v0.9.0`.

The version bump lands in the *final* implementation commit (the doc-sync + version commit), per `AGENTS.md` §4 "in-source first."

## Open questions

None blocking v1 ship. Items deferred to v2 explicitly enumerated in §Non-goals (waypoint type/action mass-edit, multi-property batch, CLI half, undo stack beyond single-slot, regex / Lua patterns, recipes, persistence across DCS restarts).
