# Community tab — yellow warning when a required mod isn't installed

**Date:** 2026-06-12
**Status:** Approved design
**Area:** ME-mod (Prefab Manager → Community tab), `prefab_modules.lua`

## Problem

The Community tab's detail pane already notes a prefab's third-party mod
dependencies — `entry_detail_text` appends a plain line:

```
⚑ requires mods: UH-60L Black Hawk — objects from these will not load without the mod installed
```

(`community_tab.lua` ~283–290, driven by the manifest entry's
`required_modules`, added by the [mod-dependencies change](2026-06-11-prefab-mod-dependencies-design.md)).

Two problems:

1. It's a low-contrast line buried inside a multi-line text box — **easy to
   miss**.
2. It shows for **every** required mod, even ones the user already has
   installed — noise when there's no actual risk.

We want a **high-visibility yellow warning label** that appears **only when the
selected prefab needs a mod the user doesn't have installed**, naming just the
missing one(s).

## Decisions (user-confirmed)

1. **Keep the existing info line** (lists all required mods, normal text) **and**
   add the yellow warning on top — the warning covers only the *missing* subset.
   So: installed-but-required mods still appear as plain info; missing ones also
   trigger the yellow label.
2. **Warn only on missing mods.** All required mods present (or none required) →
   no yellow label, layout unchanged.
3. **Placement:** a full-width yellow line pinned **just above the "Add to my
   library" button** — the last thing the user sees before importing.

## Detection — reuse `prefab_modules.lua`

The "is this mod installed?" logic already exists. `prefab_modules.missing(prefab)`
filters `prefab.meta.required_modules` (a **map** keyed by id) against
`_G.pluginsById`, with a fail-safe: if presence can't be determined, treat as
present (no false warning). The Community tab, however, holds the manifest
entry's `required_modules` as a **list** of `{id, display_name, count}` — a
different shape.

Add a list-shaped sibling:

```lua
-- M.absent(list [, deps]) → { {id, display_name, count}, ... }
--   list = the manifest entry's required_modules array
--          ({ {id=, display_name=, count=}, ... })
--   Returns the subset whose providing plugin is NOT installed, sorted by id.
--   Same plugin-present check + same fail-safe as M.missing
--   (can't tell → present → not reported). pcall-guarded; bad input → {}.
function M.absent(list, deps)
    if type(list) ~= 'table' then return {} end
    deps = deps or {}
    local plugin_present = deps.plugin_present or default_plugin_present
    local out = {}
    for _, rec in ipairs(list) do
        if type(rec) == 'table' and type(rec.id) == 'string' and rec.id ~= '' then
            local got, present = pcall(plugin_present, rec.id)
            if got and present == false then
                out[#out + 1] = {
                    id = rec.id,
                    display_name = (type(rec.display_name) == 'string'
                        and rec.display_name ~= '' and rec.display_name) or rec.id,
                    count = tonumber(rec.count) or 0,
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end
```

`default_plugin_present` (already in the file) is the shared check:
`_G.pluginsById[id] ~= nil`, fail-safe to present. To remove duplication,
`M.missing` may be refactored to convert its map to a list and delegate to
`M.absent` — behavior is identical (same fields, same sort), so the existing
`M.missing` tests stay green. This refactor is optional; if it risks the
existing tests it can be skipped and the small present-check loop left
duplicated.

## UI — `community_tab.lua`

- **Require the module** (top of file, pcall-guarded like every other require):
  `local prefab_modules; do local ok, m = pcall(require, 'dcs_sms_me.prefab_modules'); if ok then prefab_modules = m end end`
- **New widget** `W.mod_warn`, a `Static` created in the build section near
  `W.detail`, `track()`-ed for cleanup, skinned yellow via the existing
  `sms_skins.static_yellow()` (`0xffd700ff`). Wire a `'static_yellow'` branch
  into this file's local `try_skin`, or apply the skin directly in a guarded
  block. Starts hidden.
- **Compute + render in `update_detail`** (runs on every selection change):
  ```lua
  local e = selected_entry()
  local miss = (e and prefab_modules and prefab_modules.absent
                and prefab_modules.absent(e.required_modules)) or {}
  if #miss > 0 then
      local names = {}
      for _, m in ipairs(miss) do names[#names+1] = m.display_name end
      W.mod_warn:setText('\226\154\160 You don\'t have: ' .. table.concat(names, ', '))
      W.mod_warn_on = true ; show W.mod_warn
  else
      W.mod_warn_on = false ; hide W.mod_warn
  end
  relayout(W.cw, W.ch)   -- reserved row appears/disappears
  ```
  (`\226\154\160` = ⚠ U+26A0, matching the file's UTF-8-byte-escape convention.)
  All pcall-guarded per `community_tab.lua`'s no-error-escapes rule.
- **Layout** (`relayout`): when `W.mod_warn_on`, reserve one `ROW_H`-tall band
  immediately above the import button and pull the content area up by that band
  + a `GAP`:
  ```lua
  local import_y       = bottom - import_h
  local warn_h         = (W.mod_warn_on) and ROW_H or 0
  local warn_y         = import_y - GAP - warn_h           -- only used when on
  local content_bottom = import_y - GAP - (warn_h > 0 and (warn_h + GAP) or 0)
  if warn_h > 0 then bounds(W.mod_warn, right_x, warn_y, detail_w, warn_h) end
  vis(W.mod_warn, W.mod_warn_on)
  ```
  Both layout branches (the no-image early-return path and the
  image-panel path) consume `content_bottom`, so the reserve applies to both.
  When hidden, `warn_h = 0` → today's geometry is byte-for-byte unchanged.

Long lists clip to one line (the authoritative full list still lives in the
detail box's info line). No wrapping — keep the band a single `ROW_H`.

## Failure model

Consistent with both files: every ED-global touch stays inside
`prefab_modules`'s existing pcall guards; `M.absent` returns `{}` on bad input
and never throws. In `community_tab.lua` the compute + widget calls are
pcall-guarded so no error escapes a callback. If `prefab_modules` failed to
load (test VM), `prefab_modules` is nil → no warning, no crash.

## Testing

- **Lua mock test** (`tools/me-mod/test/`, registered in `run-tests.ps1`'s
  `$tests` array — it does not glob):
  - `prefab_modules.absent` with an injected `plugin_present`:
    - all-present list → `{}`.
    - mixed → only the absent ids, sorted, with `display_name` (falling back to
      id) and `count` carried through.
    - non-table / empty / malformed entries → `{}`, no throw.
  - If `M.missing` is refactored to delegate, its existing test must stay green.
- **UI** (dxgui, CI can't reach) → one line in
  `docs/release-gate/me-mod-smoke.md`: select a community prefab that needs a mod
  you don't have → yellow line above the Add button names it; one you do have →
  no yellow line (info line still present); a mod-free prefab → neither.

## Docs to sync (same change-set)

- `tools/me-mod/AGENTS.md` — note `M.absent` in the `prefab_modules.lua` row and
  the missing-mod warning in the `community_tab.lua` row (§2.2).
- `CHANGELOG.md` entry + `version.lua` bump (me-mod **patch** — a UI refinement
  on the existing mod-dependency surface, no new verb or data-format change).
- No CLI verb touched → no `docs/cli` regeneration.

## Out of scope / follow-ups

- Filtering the Community browser *by* missing mod (already noted as a follow-up
  in the mod-dependencies spec).
- Mirroring this missing-only treatment into the **place-time** dialog or the
  My-Prefabs list marker — those already warn via `prefab_modules.missing`; this
  change is the Community **browse** surface only.
- Multi-line / wrapping warning text for very long missing lists — single line
  with clip is sufficient given the info line backs it up.
