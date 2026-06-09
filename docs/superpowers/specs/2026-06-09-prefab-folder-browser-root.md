# Prefab Folder Browser — Always-Visible "Prefabs" Root Spec

## Goal

The Prefab Manager's folder browser always shows a clickable **"Prefabs"** root
node representing the whole library. Clicking it — and the default selection on
open — shows every prefab, including those saved directly in the root prefabs
folder, so root-level prefabs never feel like they vanished.

## User value

Today the tree renders only subfolders (CAP, SAM, …); the root node
(`name='' path=''`) is deliberately skipped at render time. A prefab saved
directly in the prefabs root therefore disappears from the list the moment the
user clicks any subfolder, and only reappears via the **Show all** button —
which feels like the prefab magically vanished. A visible, auto-selected
**"Prefabs"** root makes "show me everything" the obvious, always-present
top of the tree: zero clicks on open, one click any time after.

## Scope

**In:**
- Render a top-level **"Prefabs"** node (mapped to folder path `''`) at the top
  of the **main** folder browser tree, with the existing subfolders as its
  children (indented one level beneath it).
- Clicking the root node selects `selected_folder = ''` → the existing recursive
  "show everything" filter. No change to that filter's behavior.
- **Auto-select / highlight** the root node when the Prefab Manager window opens
  and after each tree rebuild, with `selected_folder = ''`.
- Root node defaults to **expanded** so subfolders stay visible.
- Both render paths: native DCS `TreeView` and the `ListBox` fallback.
- Keep the existing **Show all** button (it does the same thing — deselect →
  root).

**Out:**
- No change to `compose_filter` list-filtering semantics (`''` = recursive
  show-all; `'CAP'` = folder + descendants). Unchanged.
- No change to the **Move** modal's folder-picker tree. Its destination-folder
  selection behavior must be byte-for-byte unchanged — the "Prefabs" root
  display and auto-select are scoped to the main browser tree only.
- No change to subfolder click behavior.
- No new columns, sorting, or other grid changes.

## Constraints

- Lua 5.1, in-DCS dxgui. Project failure rule: log + safe fallback, never throw;
  a missing widget method must degrade quietly (existing code already wraps tree
  ops in `pcall`).
- The tree-skin and tree-building helpers (`apply_me_tree_skin`, `build_tree`)
  are **shared** with the Move modal's folder picker. Any change must be scoped
  so the Move picker is unaffected — prefer touching the main browser's render /
  selection wiring, not `build_tree`'s data shape.
- DCS `TreeView` is node-based: `addNode(text, parent, nil)` returns a node;
  the code stamps `node._sms_path` so the selection callback can map a node back
  to a folder path. The `ListBox` fallback flattens nodes into rows and records
  `W._tree_listbox_paths[i] = node.path` for the same mapping.
- Pure-logic helpers are unit-tested (`M._build_tree`, `M._compose_filter`,
  `M._walk_folders`). UI render + selection highlight are verified manually in
  the Mission Editor (no grid/tree UI harness exists in this repo).
- Lua under `tools/me-mod/lua` is `//go:embed`'d — verifying in DCS requires
  `dcs-sms dev-reload` (or build + `install-me-mod` + `reload-me-mod`).

## Decisions

- **Branch:** continue on the existing `prefab-community-author-column` branch
  (stacks on the committed Author-column work). Both features touch
  `prefab_manager.lua`; stacking avoids a same-file cross-branch merge conflict,
  and the user has been evolving this branch without merging. Both land together
  at `/bring-it-home`.
- **Root label = "Prefabs"; keep Show all; auto-select root on open** — all per
  the user's answers during brainstorming.
- **Root maps to `selected_folder = ''`,** reusing the existing show-all
  semantics, rather than inventing a literal `''` folder predicate. They are
  equivalent through `compose_filter`, so no filter code changes.
- **Render-time label, not a data-model rename.** Keep `build_tree`'s root node
  as `name='' path=''` (so `build_tree` tests and any `build_tree` consumer,
  including the Move picker, are untouched). The main browser's render paths
  display the path-`''` node using a `ROOT_LABEL = 'Prefabs'` constant and add it
  as the top node (native) / first row (listbox) before its children.
- **Auto-select = visual highlight + `selected_folder=''`.** `selected_folder`
  already initializes to `''`, so the list already shows everything by default;
  this change adds selecting/highlighting the root *node* on open and after
  rebuilds so the state is anchored to a visible node. Native: select the root
  node; listbox: select row 0.
- **Move-picker isolation** is achieved by only altering the main browser's
  `render_tree_native` / `render_tree_listbox` / open + rebuild paths. If the
  Move picker shares those exact functions, the root rendering will be gated so
  it applies to the main tree widget only (the plan verifies the Move picker's
  render path and gates accordingly).

## Open questions

None.
