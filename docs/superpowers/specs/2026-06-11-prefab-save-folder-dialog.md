# Prefab save — folder-picker dialog at save time

**Date:** 2026-06-11
**Status:** Approved design
**Area:** ME-mod (Prefab Manager)

## Problem

When a user clicks **Save** in the Prefab Manager, the prefab is written into
whichever folder is currently highlighted in the Folder Browser
(`W.selected_folder`). This is silent and non-obvious: people don't always
notice which folder is selected, so prefabs land in the wrong place (often the
root) with no chance to confirm.

We want **Save** to pop up a dialog where the user explicitly picks the
destination folder — very similar to the existing **"Move to…"** modal — so the
destination is always a deliberate choice.

## What we're building

A **Save-to folder dialog** modeled on `open_move_modal`:

- Opens on every **Save** click.
- Pre-selects the folder currently highlighted in the Folder Browser
  (`W.selected_folder`), so the common case is just confirming. Mirrors how
  Move-to pre-selects the prefab's current folder.
- Lets the user **create a new folder on the spot** (a New Folder button).
- On confirm, the prefab is saved into the chosen folder via the existing save
  path (overwrite/rename/cancel prompt + trigger bundling + `do_save`).

## Approach (and why)

A **new `open_save_modal`** modeled directly on the proven `open_move_modal`
(same `sms_window` chrome, same `TreeView`/`ListBox`-fallback picker, same
`Community/` exclusion, same pre-select logic). We do **not** generalize the
Move modal into a shared component: that would touch the working Move path, and
the New Folder button only belongs to Save, so sharing now buys little and risks
a regression.

There is some duplication in the tree build/render between the two modals. We
accept it for now and leave a comment that a future refactor could unify them.

## Detailed design

### 1. `on_save_click` flow change

Today: read name → `prefab_ops.exists(name)` check → trigger bundle →
`do_save(name, fixed, airbases, W.selected_folder, tp)`.

New:

1. Read & trim `name`; read the Fixed toggle (`read_fixed_check`) and
   `W.pending_airbases`.
2. Empty name → resolve to the timestamp fallback exactly as today
   (`prefab-<UTC timestamp>`, warning status, log line).
3. **Open `open_save_modal`**, pre-selecting `W.selected_folder`, label
   `Save "<name>" to folder:`.
4. On the dialog's **Save** button → call
   `proceed_save(name, chosen_folder, fixed, airbases)`.
5. On the dialog's **Cancel** button → status `Save cancelled.`, nothing
   written.

### 2. `proceed_save(name, target, fixed, airbases)` — extracted helper

This is the existing post-folder logic, lifted out of `on_save_click` so both
the new dialog flow and the code stay readable, and made folder-aware:

- If `prefab_ops.exists(name, target)` → show the existing
  Overwrite / Rename / Cancel overlay:
  - **Overwrite** → `with_bundled_triggers(...)` → `do_save(name, fixed,
    airbases, target, tp)`.
  - **Rename** → `focus_name_input()` + status "Type a new name and click Save."
  - **Cancel** → status "Save cancelled."
- Else → `with_bundled_triggers(...)` → `do_save(name, fixed, airbases, target,
  tp)`.

`do_save` itself is unchanged.

### 3. `open_save_modal(opts)`

Mirrors `open_move_modal`. `opts = { name = <string>, default_folder =
<string>, on_confirm = function(target_folder) ... end }`.

- Title `Save Prefab`; static label `Save "<name>" to folder:`.
- Picker built identically to Move: `walk_folders()` → `build_tree(folder_set,
  '')` → drop the `Community/` subtree (`community_config.is_community_path`).
  `Community/` is import-only and never a save destination.
- Pre-select `opts.default_folder` using the same best-effort ListBox-index /
  TreeView `findNode` logic as Move.
- Same 360×400 `sms_window` chrome centered over the parent — no resize needed.
- Buttons: **New Folder** (left, ~x=10), **Save** + **Cancel** (right, mirroring
  Move's x=180 / x=265).
- **Save** → `target = selected_target()`; if `nil` → status "Pick a destination
  folder."; else `modal:hide()` then `opts.on_confirm(target)`.
- **Cancel** → `modal:hide()` + status "Save cancelled."

The tree build/render is factored into a re-callable local (as Move already
does) so the New Folder button can rebuild it. `folder_set`/`tree` are mutable
locals; a `rebuild_and_select(path)` re-walks, re-drops `Community/`, re-renders,
and selects `path`.

### 4. New Folder button (inside the dialog)

Mirrors the main browser's `on_new_folder`:

- Parent = the folder currently highlighted in the dialog's picker
  (`selected_target()`, defaulting to the pre-selected folder; `''` = root).
- Reuse the shared `show_rename_overlay('Folder name (under "<parent>"):', '',
  on_ok)` for the name prompt.
- `on_ok(raw_name)`: trim; `prefab_ops._validate_folder_name`; reject
  `community_config.is_community_path(rel)`; reject if the folder already exists;
  `paths.ensure_prefab_folder(rel)`.
- On success: `rebuild_and_select(rel)` so the new folder appears and is
  selected, ready to Save into.
- **The folder is created on disk immediately** — it persists even if the user
  then cancels the save, exactly like creating a folder in the main browser.
- Status feedback uses the shared `set_status` (main window status bar), same as
  Move; the picker visibly updating to the selected new folder is the primary
  feedback.

### 5. Folder-aware existence check

Extend `prefab_ops.exists`:

```lua
function M.exists(name, folder)   -- folder defaults to '' (root)
```

- `folder` defaults to `''` → checks `paths.folder_to_abs(folder) .. name ..
  '.prefab'`.
- The legacy `.lua` path is a root-only migration artifact, so the legacy check
  only runs when `folder == ''` (unchanged root behavior).
- Existing callers passing a single arg are unaffected: `triggers_tab.lua:765`
  (`exists(exists_key)`) stays root-checked; `test_prefab_ops_save.lua`'s
  `exists('…')` calls keep their meaning.

This fixes a latent bug: today's pre-save check only looks at the root prefabs
dir, so a same-name prefab inside a subfolder slips past the overwrite warning.
With the dialog, the check runs against the **chosen** folder.

### 6. Out of scope / unchanged

- **Right-click "Update Prefab with selection"** (`on_update_prefab`) keeps
  saving in place into the existing prefab's folder (`row.folder`) — no dialog;
  updating in place is the intent.
- `do_save`, `with_bundled_triggers`, `build_tree`, `walk_folders`, the prefab
  data format (stays 0.5.0 — no new prefab keys), and the catalog repo are all
  untouched.

## Decisions

Autonomous calls made while finalizing this spec (revisit any of these if
they don't match your intent):

- **D1 — Dedicated `open_save_modal`, not a generalized picker.** A new modal
  cloned from `open_move_modal` over refactoring Move into a shared component —
  keeps the working Move path untouched; the New Folder button is Save-only.
  Accepts some build/render duplication (commented for a future unify).
- **D2 — Dialog opens on every Save, pre-selecting `W.selected_folder`.** Common
  case is a one-click confirm; no "only when ambiguous" special-casing.
- **D3 — New Folder creates on disk immediately and persists on cancel**, exactly
  like the main browser's New Folder. No deferred/temp-folder bookkeeping.
- **D4 — `exists(name, folder)` extended in place**, `folder` defaulting to `''`.
  Backward compatible for the single-arg callers; also fixes the latent
  root-only overwrite-check bug.
- **D5 — "Update Prefab with selection" keeps saving in place** (no dialog).
- **D6 — Version → 0.24.0 (minor); prefab format unchanged at 0.5.0.**
- **D7 — Dialog status uses the shared main-window status bar** (mirrors Move),
  accepting that a transient message can sit behind the modal; the picker
  visibly updating is the primary feedback.

## Open questions

None.

## Testing

The modal is DCS-UI (`sms_window` + `TreeView`), so it is not headless-testable.
Automated coverage targets the one pure change:

- **`test_prefab_ops_save.lua`** — folder-aware `exists`:
  - `exists('foo', 'CAP') == true` when `CAP/foo.prefab` is present.
  - `exists('foo', 'CAP') == false` when only `foo.prefab` (root) is present —
    proving the check is now folder-scoped.
  - `exists('already_here') == true` (root, no folder arg) — unchanged.
  - legacy `.lua` still detected at root only.

Manual smoke (added to `docs/release-gate/me-mod-smoke.md`):

1. Select a subfolder in the Folder Browser, click **Save** → dialog opens with
   that folder pre-selected.
2. **New Folder** inside the dialog → creates + selects it; Save lands the
   prefab there.
3. Cancel after creating a folder → folder persists, no prefab written.
4. Saving a name that already exists in the chosen folder → Overwrite/Rename/
   Cancel prompt fires (folder-aware).

## Non-code deliverables

- `version.lua` 0.23.0 → **0.24.0** (feature; prefab format unchanged at 0.5.0).
- CHANGELOG entry.
- `tools/me-mod/AGENTS.md` — note the Save-to dialog behavior and the
  `exists(name, folder)` signature.
- `docs/release-gate/me-mod-smoke.md` — the manual steps above.
