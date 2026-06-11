# Prefab mod dependencies — detect required community mods at save, warn on load

**Date:** 2026-06-11
**Status:** Approved design
**Area:** ME-mod (Prefab Manager), prefab data format

## Problem

A user can have third-party community mods installed (Hercules, A-4E-C, UH-60L,
AH-6J, …). If a unit or static from one of those mods is captured in a Prefab
and then placed by someone who doesn't have the same mod installed, the
mod-provided objects **don't load** — they silently vanish or get replaced by a
stand-in. The person placing the prefab gets no warning and a quietly broken
result.

We want to, **at save time**, detect which selected objects come from a mod,
**record that dependency inside the `.prefab`**, and, **at placement time**,
**warn** the user when a prefab needs a mod they don't have installed.

## What counts as a "mod" — settled empirically, not by guesswork

DCS already computes a mission's module dependencies into
`mission.requiredModules` (e.g. the Guam training mission carries
`requiredModules = { ["Hercules"] = "Hercules" }`). The logic lives in
`me_mission.lua`:

```lua
function setRequiredModules(um, a_type)
    local unitDef = me_db.unit_by_type[a_type]      -- me_db = require('me_db_api')
    if not unitDef._origin then return end          -- no provider → nothing
    if unitDef._origin == "WIP units" then return end
    if base.pluginsById[unitDef._origin].is_core then return end   -- base game → exempt
    if unitDef._replace_origin_ then                -- has a core stand-in → exempt
        for origin in base.pairs(unitDef._replace_origin_) do
            if origin == "_core_" then return end
            local p = base.pluginsById[origin]
            if p and p.is_core then return end
        end
    end
    um.requiredModules[unitDef._origin] = unitDef._origin
end
```

A live, read-only probe over this machine's full unit DB (**784 types**) via the
ME bridge produced exactly three flagged modules — **all genuine third-party
community mods**:

| `_origin` (module id) | `pluginsById[id].displayName` | types flagged |
|---|---|---|
| `UH-60L` | `UH-60L Black Hawk` | `UH-60L`, `UH-60L_DAP`, `KC130J` |
| `A-4E-C`  | `A-4E-C` | `A-4E-C` |
| `AH-6J`   | `AH-6J` | `AH-6J`, `MH-6J`, cargo helpers |

Every **official** paid module came back `is_core = true → required = {}`:
F-16C (`origin "F-16C bl.50 AI"`), A-10C II (`"A-10 Warthog"`), AH-64D, F-14B,
OH-58D. **DCS marks the AI variants of paid modules `is_core` and exempts them**,
so `setRequiredModules` naturally returns *only* the community-mod set — exactly
the "non-official mods" we care about. We therefore do **no** official-vs-mod
classification of our own; we delegate to DCS's authoritative logic.

Probe facts the design relies on (all confirmed live):

- `require('me_mission').setRequiredModules` is reachable and callable.
- The unit DB is `require('me_db_api')` (`.unit_by_type[type]._origin`), **not**
  `me_db`.
- `base.pluginsById[id]` exists for an installed mod and carries `displayName`,
  `fileMenuName`, `state`, `is_core`. It is **absent** for a mod that isn't
  installed → the load-side "is this mod missing?" check.
- Sweeping all 784 types ran in ~1 ms; over a selection it's free.

## Decisions (user-confirmed)

1. **Detect via DCS's own `setRequiredModules`** — record precisely what DCS
   would require; no official-vs-community heuristic, no online store lookup.
2. **Richer per-module record** in the prefab — id, display name, and which
   DCS types (with counts) depend on it.
3. **Both sides in this change** — save-side detection + record **and** a
   load-time warning when a required mod is missing.
4. **Include the UI surfaces** — a Community-tab "Requires:" advisory line and a
   Prefab Manager list marker for mod-dependent prefabs.
5. **Two-repo change-set** — also update the catalog generator
   (`dcs-sms-prefabs`) so `required_modules` flows into `index.json`, making the
   Community-tab line live end-to-end.

## Detection — `prefab_modules.lua` (new ME-mod module)

A new module `dcs_sms_me/prefab_modules.lua` is the **only** file that touches
the module-detection ED globals (`me_mission.setRequiredModules`, `me_db_api`,
`base.pluginsById`), mirroring how `selection.lua` is the sole owner of the
selection globals. Everything is `pcall`-guarded; any failure logs via
`log.write('sms.me.prefab', …)` and degrades to an empty result — a save or a
placement is **never** broken by mod detection (project failure model: log +
empty, never throw).

```lua
-- M.detect(dump) → required_modules | nil
--   dump = { groups = {...}, statics = {...}, ... } (the same envelope
--           prefab_ops builds for distill; each group/static has .units[].type)
--   returns the meta.required_modules record (below), or nil if empty.
```

Algorithm (per selected object, honoring multiplicity):

```lua
local me_mission = require('me_mission')
for each unit in every group.units and every static.units do
    local probe = { requiredModules = {} }
    pcall(me_mission.setRequiredModules, probe, unit.type)
    for module_id in pairs(probe.requiredModules) do
        local rec = acc[module_id] or { id = module_id, objects = {}, count = 0 }
        rec.objects[unit.type] = (rec.objects[unit.type] or 0) + 1
        rec.count = rec.count + 1
        acc[module_id] = rec
    end
end
```

`display_name` is resolved **at save time** (the mod is installed then) with a
fallback chain so it's stable even if the loader lacks the mod:

```
base.pluginsById[id].displayName  →  .fileMenuName
   →  me_modulesInfo.getModulDisplayNameByModulId(id)  →  id    (last resort)
```

## Record shape — `meta.required_modules`

A map keyed by module id (mirrors DCS's `requiredModules` key set), value is the
richer record:

```lua
meta.required_modules = {
  ["UH-60L"] = {
    id           = "UH-60L",
    display_name = "UH-60L Black Hawk",
    objects      = { ["UH-60L"] = 2, ["KC130J"] = 1 },  -- DCS type → count
    count        = 3,                                     -- total objects
  },
  ["A-4E-C"] = {
    id = "A-4E-C", display_name = "A-4E-C",
    objects = { ["A-4E-C"] = 1 }, count = 1,
  },
}
```

Emitted **only when non-empty**, so existing mod-free prefabs stay byte-stable on
re-save (same discipline as `meta.airbases` and the trigger keys).

## Save-side wiring

`prefab_distill.lua` stays **pure** — no DCS deps, byte-identical with
`framework/prefab_distill.lua` (the parity test stays green). Detection is
attached **post-distill** in `prefab_ops.M.save_selection`, exactly like
`ship_warehouse.attach_to_prefab` and `attach_triggers`:

```lua
local prefab = distill(dump, { ... })
...
local req = prefab_modules.detect(dump)        -- dump still has original types
if req then prefab.meta.required_modules = req end
```

Both save entry points route through `save_selection` — the Save button
(`do_save`) and the context-menu **Update Prefab with selection**
(`on_update_prefab → do_save`) — so detection covers both for free. Trigger-only
prefabs carry no units, so they record nothing.

## Load-side warning (placement)

`prefab_modules.missing(prefab) → { {id, display_name, count}, ... }` checks each
`meta.required_modules` id against `base.pluginsById[id]`: a mod whose plugin is
**absent** (or not `state == "installed"`) is reported missing. `pcall`-guarded;
on any error returns empty (no false alarms).

The check fires at the **single place-time chokepoint** — `on_place_click` in
`prefab_manager.lua`, after `prefab_ops.load` and **before** `enter_place_pending`
(so the warning shows once when the user initiates a placement, not on every
map click). If mods are missing, a modal warns and offers a choice:

> **This prefab needs mods you don't have installed:**
> • UH-60L Black Hawk — 3 objects
> • A-4E-C — 1 object
> Those objects may fail to place or be replaced by something else.
> **[ Place anyway ]   [ Cancel ]**

Non-blocking: **Place anyway** proceeds to `enter_place_pending`; **Cancel**
aborts. The missing-mod objects break regardless of our warning, and the user
may still want the rest of the prefab — so we inform rather than hard-block. This
sits alongside the existing post-place `run_airbase_apply` prompt pattern (which
likewise reads a `meta.*` key) but fires *before* placement.

## UI surfaces

- **Prefab Manager list marker.** A prefab whose loaded table carries a
  non-empty `meta.required_modules` is marked in the library list (a compact
  `(mods)` tag / column cell, following the Triggers tab's `(triggers)` /
  `Refs`-column precedent). Computed when rows are scanned/loaded.
- **Community tab advisory.** The Community detail pane is **manifest-driven**
  (`entry_detail_text` builds from the `index.json` entry — the prefab *body* is
  only fetched on import). So the **Requires:** line reads
  `entry.required_modules` from the manifest entry, which the catalog generator
  now emits (see *Catalog propagation* below). `entry_detail_text` gains a line
  listing the display names when `e.required_modules` is present and non-empty;
  absent → no line. Old catalog entries lack the field until re-generated from a
  re-saved prefab — graceful (no line, never a wrong one).

## Catalog propagation (`dcs-sms-prefabs` repo)

`index.json` is a CI build artifact regenerated by `tools/gen_index.py` (GitHub
Action on merge to `main`). It runs **without DCS**, so it can only *propagate*
the `meta.required_modules` a prefab already carries (written by the ME at
save) — it never computes mod origin itself. Two small edits mirror how
`airbases` / entity counts are already derived:

- **`tools/lua_prefab.py`** `derive()` — extract `meta.required_modules` from the
  parsed prefab (alongside the existing `theatre`, `airbases`, counts). Emit a
  catalog-friendly shape — the module ids with display names and total counts
  (e.g. `[{ "id": "UH-60L", "display_name": "UH-60L Black Hawk", "count": 3 }]`)
  — or `[]`/omitted when none.
- **`tools/gen_index.py`** `build_entry()` + `_ENTRY_ORDER` — add
  `"required_modules": derived["required_modules"]` to each entry.

Effect: prefabs saved with the new me-mod surface a Requires line in the
Community browser once CI regenerates `index.json`; pre-existing catalog prefabs
show nothing until re-saved + re-submitted. This is the same propagation shape as
the still-open triggers-count catalog item (`dcs-sms-prefabs#16`); the two can
share the `derive()` pass.

## Prefab format version

Bump to **0.5.0** — an additive, backward-compatible optional `meta` key, same
shape of change as the 0.4.0 triggers keys. Pre-0.5.0 loaders ignore
`meta.required_modules` (graceful: no marker, no warning); 0.5.0 loads older
files unchanged. Bump `PREFAB_VERSION` in **both** `prefab_distill.lua` copies
(framework + me-mod) and the mirror constant in `prefab_ops.lua`; update the
version-history comment block.

## Failure model

Every ED-global touch in `prefab_modules.lua` is `pcall`-wrapped. Detection
failure → no `meta.required_modules` written (prefab saves fine, just without
the dependency note). Missing-check failure → treated as "nothing missing" (no
false warning). Never throws out of save or place.

## Testing

- **Lua mock tests** (`tools/me-mod/test/`, registered in the `run-tests.ps1`
  `$tests` array — it doesn't glob):
  - `prefab_modules.detect` over a fake dump with an injectable
    `setRequiredModules`/DB stub: community-mod types → correct
    id/display_name/objects/count; core/exempt types → no entry; mixed
    selection aggregates and counts with multiplicity; empty selection → nil.
  - `prefab_modules.missing` with a stubbed `pluginsById`: installed id → not
    missing; absent id → missing; malformed record → empty, no throw.
  - Round-trip: a saved prefab with `meta.required_modules` survives
    serialize/`prefab_ops.load`; a mod-free save stays byte-stable (key absent).
- **Distill parity** unchanged (detection lives outside distill) — parity test
  must stay green.
- **Manual smoke** (dxgui, CI can't reach) → add to
  `docs/release-gate/me-mod-smoke.md`: place a prefab whose required mod is
  present (no warning); the warning modal + Place anyway / Cancel when a mod is
  absent; the list marker; the Community-tab Requires line.
- **Catalog (`dcs-sms-prefabs`)** — `python tools/gen_index.py` test (the repo's
  existing pytest/CLI checks): a prefab fixture carrying `meta.required_modules`
  produces an entry with the propagated `required_modules`; a mod-free prefab
  yields `[]`/omitted; `--check` stays green after regenerating.

## Docs to sync (same change-set)

- `tools/me-mod/AGENTS.md` — add `prefab_modules.lua` to the §2.2 file-layout
  table.
- `CHANGELOG.md` — me-mod **minor** bump entry; `version.lua` bumped.
- Prefab format history comment in both `prefab_distill.lua` copies.

## Out of scope / follow-ups

- **Discord submission bot** awareness of `required_modules` (e.g. badging a
  submission that needs a mod) — separate from the catalog generator, deferred.
- **Filtering/faceting** the Community browser *by* required mod (search "no
  mods" / "needs A-4E-C"). This change only displays the Requires line; the
  index now carries the data, so a filter is a later UI add.
- **Auto-substitution** of a missing mod object with a base-game stand-in — not
  attempted; we only warn.
- **Owned-but-not-installed nuance.** We key "missing" on plugin presence, which
  is the accurate predictor of "will it place." We do not separately distinguish
  "you own it but haven't installed it."
