# Spec — `sms_scrollbars.lua`: shared themed scrollbar module

**Date:** 2026-06-05 · **Area:** ME-mod (`tools/me-mod/lua/dcs_sms_me`) · Lua 5.1 / dxgui

## Goal

Extract the dark, thin, ME-Unit-List-matched scrollbar skinning — currently
hand-built inline and duplicated across ME-mod windows — into a single shared
module `dcs_sms_me/sms_scrollbars.lua`, and refactor the existing call sites
onto it. Future tool windows get good scrollbars for one `require` + one call
instead of re-deriving the dxgui skin internals every time.

## User value

The user (mission maker building ME-mod tooling) gets a reusable scrollbar
helper in the same `sms_*` family as `sms_window.lua` and `splitter.lua`. The
empirical "vanilla Unit List horizontal bar" recipe (15px height, dark 9-slice
track, arrow images, polzunok thumb) lives in exactly one documented place
instead of being copy-pasted and partially re-derived per window.

## Scope

### In scope
- New module `tools/me-mod/lua/dcs_sms_me/sms_scrollbars.lua` exposing:
  - `M.apply(skin, opts)` — inject themed grid scrollbars into any widget skin
    table (editbox / tree / scrollpane / grid), mutating it in place.
  - `M.themed_editbox_skin(opts)` — convenience that returns a fresh
    `editBoxSkin_ME()` clone, themed and ready to `setSkin` (optional mono font).
- Refactor three existing call sites onto the module, **behaviour-identical**:
  1. `me_hotkey_script_editor.lua` `apply_code_skin` (full editbox treatment).
  2. `prefab_manager.lua` `apply_me_tree_skin` (simple tree scrollbar injection).
  3. `sms_skins.lua` `scroll_pane()` (vertical-only injection).
- New unit test `test/test_sms_scrollbars.lua` covering the table-mutation logic.
- Doc sync: `tools/me-mod/AGENTS.md` §2.2 file-table, `CHANGELOG.md`, me-mod
  version bump in `version.lua`.

### Out of scope
- **Part B (dividers/splitters) is dropped entirely.** Investigation showed
  Mass Edit and Prefab Manager already use the shared `splitter.lua`; the only
  remaining duplication is the trivial `Static + sms_separator + insertWidget`
  allocation, which is not worth a module. No changes to `splitter.lua`,
  `sms_separator`, or any separator call site.
- No visual/appearance changes to any window. This is a pure extraction.
- No changes to `me_hotkey_window.lua` (the handoff's mention of an inline
  `apply_tree_skin` there is stale — no such code exists anymore).

## Constraints

- **Lua 5.1**, dxgui skin tables. Everything `pcall`-guarded so a future DCS
  build with a different skin shape degrades to defaults rather than crashing.
- Skin colours MUST be **string** form `'0xRRGGBBAA'` — numeric assignments
  silently fail to parse.
- `Skin.gridSkin_Multiplayer_roleNew()` / `editBoxSkin_ME()` return a **fresh
  deep copy per call**, so mutating the returned table is widget-local and safe.
- **Ordering gotcha (script editor):** for the code `EditBox`, the call-site
  ordering `setMultiline(true)` → `setTextWrapping(false)` → apply skin →
  `setText` MUST be preserved — `setMultiline` rebuilds the scrollbar widgets
  and would wipe a skin applied earlier. The module only *builds* the skin
  table; the ordering stays at the call site.
- `sms_scrollbars.lua` requires only `Skin` (lazy `pcall`). `sms_skins.lua` may
  require `sms_scrollbars` (no cycle, since the new module does not require
  `sms_skins`).
- Lua under `tools/me-mod/lua` is `//go:embed`'d into `dcs-sms.exe`; rebuild
  before testing. Tests run via `tools/me-mod/test/run-tests.ps1` (`lua` is not
  on PATH).
- Repo doc-sync rule: public-surface changes update `tools/me-mod/AGENTS.md`
  §2.2 file-table + `CHANGELOG.md` in the same change-set.

## Module API (detail)

```lua
-- M.apply(skin, opts) -> skin
--   skin : a widget skin table with skinData.skins (editbox/tree/scrollpane/grid)
--   opts.horizontal  (default true)  -- also inject the horizontal bar
--   opts.refine_horz (default false) -- apply the full vanilla Unit-List horz
--        treatment: 15px tall (maxSize/minSize.vert = 15), whole 9-slice track
--        recoloured 0x363636ff, released arrow images (down_normal.png left /
--        up_normal.png right), polzunok thumb across released/hover/pressed.
--        When false, the grid's horz bar is injected unchanged.
--   Always injects the grid's vertScrollBar. Mutates skin in place, returns it.
--   No-op (returns skin unchanged) if Skin or required sub-tables are missing.

-- M.themed_editbox_skin(opts) -> skin | nil
--   opts.mono        (default false) -- DejaVuLGCSansMono.ttf on every text state
--   opts.horizontal  (default true)  -- forwarded to M.apply
--   opts.refine_horz (default true)  -- forwarded to M.apply (editbox wants full)
--   Returns a fresh editBoxSkin_ME() clone, themed. nil if Skin unavailable.
```

The private horizontal-refinement helper (`refine_horz_bar`) carries the
empirical Unit-List recipe and its explanatory comments — sourced from
`MissionEditor/modules/dialogs/me_units_list_panel.dlg` (the `horzScrollBar`
override) — so that knowledge has one documented home.

## Refactor mapping (behaviour-preserving)

| Call site | Replace with |
|---|---|
| `me_hotkey_script_editor.lua` `apply_code_skin` | `local s = sms_scrollbars.themed_editbox_skin({ mono = true }); if s then widget:setSkin(s) end`. Keeps full vert + refined horz + mono, identical to today. Call-site `setMultiline`→…→`setText` ordering untouched. |
| `prefab_manager.lua` `apply_me_tree_skin` | Keep tree panel/item colour repaints; replace only the scrollbar-injection block with `sms_scrollbars.apply(s, { refine_horz = false })` — injects grid vert+horz unchanged, exactly as today. |
| `sms_skins.lua` `scroll_pane()` | Replace inline grid `vertScrollBar` injection with `sms_scrollbars.apply(pane, { horizontal = false })` — vertical only, identical result. |

Because the tree passes `refine_horz = false` and `scroll_pane` passes
`horizontal = false`, **neither changes appearance**. Only the editbox keeps
the full refinement, which it already has today.

## Testing

- `test/test_sms_scrollbars.lua`: stub `package.loaded['Skin']` with minimal
  fake `gridSkin_Multiplayer_roleNew` and `editBoxSkin_ME` tables (the right
  nested shape), then assert:
  - `vertScrollBar` is injected onto the target skin's `skinData.skins`.
  - `horzScrollBar` injected when `horizontal=true` (default), absent when
    `horizontal=false`.
  - `refine_horz=true` → `horzScrollBar.skinData.params.maxSize.vert == 15`,
    the 9 track slices on released `bkg` all == `'0x363636ff'`, and the thumb
    `bkg.file` is set across released/hover/pressed.
  - `refine_horz=false` → none of the refinement applied (grid horz unchanged).
  - `themed_editbox_skin({mono=true})` sets `DejaVuLGCSansMono.ttf` on text
    states and carries the refined horz bar.
  - Missing/odd skin shapes (`Skin` nil, no `skinData`) → no error, graceful
    return.
- Register the new test in `run-tests.ps1` if the runner enumerates files
  explicitly; otherwise it is auto-discovered.
- **Final visual confirmation is manual** (skin appearance needs real dxgui):
  `dcs-sms.exe dev-reload`, reopen the script editor, the Prefab Manager folder
  tree, and a scroll-pane window; confirm each looks unchanged.

## Decisions

- **Module name:** `sms_scrollbars.lua` (focused, single-purpose, `sms_*`
  family) — chosen over folding into the `sms_skins.lua` skin module or a
  broader catch-all skins module.
- **API shape:** one `M.apply(skin, opts)` doing always-inject-vert +
  optional-horz + optional-refine, plus a `themed_editbox_skin` convenience —
  chosen over "simple inject only" or "two composable functions".
- **`M.apply` default `refine_horz = false`** so the simple/tree case is the
  default; the editbox path (`themed_editbox_skin`) opts into refinement by
  defaulting `refine_horz = true`.
- **Part B dropped** (see Out of scope) — splitter already shared.
- **`sms_skins.scroll_pane()` is included** in the refactor (not just the two
  windows) to prove the module's generality and remove the duplicate
  vertScrollBar-injection knowledge; `sms_skins` gains a `require` on
  `sms_scrollbars` (no cycle).
- **Test approach:** unit-test the pure table-mutation logic via stubbed `Skin`;
  appearance verified by eye via `dev-reload`. The handoff's "skin work isn't
  unit-testable" applies to *appearance*, not to the table mutations.

## Open questions

None.
