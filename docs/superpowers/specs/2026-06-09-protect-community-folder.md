# Prefab Manager — protect the Community folder

**Status:** design — approved, ready for plan.

**Branch:** `feat/protect-community-folder`.

## Motivation

The Prefab Manager has a reserved `Community/` folder (the subfolder of the
user's prefab library where community-tab downloads land —
`community_config.COMMUNITY_FOLDER = 'Community'`; imports are written by
`community_import.import`, which `io.open`s directly into
`<PREFABS_DIR>/Community/`). It is meant to hold *only* downloaded prefabs.

Today nothing stops the user from putting their own prefabs there: the main
**Save** flow, **Update Prefab with selection**, **Move to…**, and **New
subfolder** all accept `Community` (or a path under it) as a destination, and
the folder can be **renamed** like any other — which would silently orphan the
import target (the next download recreates a fresh `Community/`).

This change makes `Community/` import-only and visually marks it as special.

## Scope

**Blocked** (user actions that would write their own content into `Community/`
or change its identity):

- **Save** a new prefab into `Community/` or any subfolder.
- **Update Prefab with selection** on a prefab that lives in `Community/`
  (this overwrites a download with the user's current selection).
- **Move to…** a prefab into `Community/` or a subfolder.
- **New subfolder** under `Community/`.
- **Rename** the `Community/` folder (or any subfolder of it).

**Still allowed** (removing community content is legitimate):

- **Delete** an individual downloaded prefab (this is how you "un-import" — the
  community tab's imported state is derived from file existence,
  `community_import.is_imported`).
- **Delete** the whole `Community/` folder.
- Community **imports** themselves (they bypass `prefab_ops` entirely).

## Design

### 1. One predicate

Add to `community_config.lua` (it already owns `COMMUNITY_FOLDER`):

```lua
-- True if rel is the Community folder or a path inside it. rel is a
-- library-relative, '/'-or-'\'-delimited folder path ('' = root).
function M.is_community_path(rel)
    local s = tostring(rel or ''):gsub('\\', '/'):gsub('^/+', ''):gsub('/+$', '')
    local lc = s:lower()
    local c  = M.COMMUNITY_FOLDER:lower()
    return lc == c or lc:sub(1, #c + 1) == c .. '/'
end
```

Every guard and the tree marker key off this one function, so "what counts as
the Community folder" has a single definition. It normalizes separators because
the codebase mixes `/`-delimited tree/ops paths with `\\`-delimited import
paths.

### 2. Block user writes — core layer (correctness)

`community_import.import` writes with `io.open` and **never** calls
`prefab_ops`, so guarding `prefab_ops` blocks user writes while leaving imports
untouched. Add an early `is_community_path` check, returning `false, <message>`
(the existing failure convention these functions already use), to:

- `prefab_ops.save_selection(name, place_at_origin, airbases, folder)` — reject
  when `is_community_path(folder)`. This single guard covers both the **Save**
  button (`prefab_manager.on_save_click` → `do_save` → `save_selection`) and
  **Update Prefab with selection** (`on_update_prefab` → `do_save` with the
  prefab's own folder).
- `prefab_ops.move_prefab(source_folder, name, target_folder)` — reject when
  `is_community_path(target_folder)`.
- `prefab_ops.rename_folder(old_rel, new_name)` — reject when
  `is_community_path(old_rel)`.

**New subfolder** is the one user write that bypasses `prefab_ops`
(`prefab_manager.on_new_folder` → `paths.ensure_prefab_folder`). Guard it at its
single UI caller with the same predicate (reject when the parent path is
Community or under it), keeping the behavior identical to the core-guarded
paths.

Blocked calls return a clear message the caller surfaces via the existing
status/toast mechanism, e.g.:

> *Community is managed automatically — it only holds downloads.*

### 3. UI affordance (clarity)

So users don't walk into a dead-end and only learn via the toast:

- **Move-to picker** (`prefab_manager.open_move_modal`): omit the Community
  subtree from the destination list. The picker is built from
  `build_tree(walk_folders(), '')` and rendered into a TreeView/ListBox; filter
  out nodes whose path `is_community_path`.
- **Right-click menu on the Community node** (`context_menu.lua` tree-node
  menu): drop **New subfolder** and **Rename** for a Community(-subtree) node.

The main **Save** into Community is left to the core guard + toast (the Save
button targets whatever folder is selected in the left tree; a full "disable
Save when Community is selected" affordance is out of scope — the toast is
enough and the write is hard-blocked).

### 4. Marker — color tint

A real icon is not available: the DCS TreeView gives each node only the
expand-checkbox (`TreeViewItem` extends `CheckListBoxItem`; `addNode(text,
parent, index)` has no image slot). A **color tint** is feasible — each node
carries `node.item` and `node.item:setSkin(...)` works, and `prefab_manager`
already clones/overrides `Skin.treeViewSkin_ME()` color tables.

- **Native TreeView** (`render_tree_native`, prefab_manager.lua ~503): after
  adding the node whose path `is_community_path`, apply a tinted item-skin to
  `node.item` — a clone of the tree's item skin with the label text color
  overridden to a distinct, legible accent (against the tree's ~`0x6d7376` grey).
- **ListBox fallback** (`render_tree_listbox` / `_listbox_tree_rows`): tint the
  Community row's `ListBoxItem` with the matching accent (a per-item skin, same
  mechanism the Mass Edit coalition columns use); if a clean per-row skin tint
  isn't reachable in this path, fall back to a short text marker on that row
  only.

Only the top-level `Community` node is tinted (its children are downloads; they
don't each need the cue).

### 5. Error / messaging

One shared message string (alongside the predicate or in `prefab_ops`) so Save,
Update, Move, New-subfolder, and Rename all say the same thing. Wording:
*"Community is managed automatically — it only holds downloads."*

## Testing

Unit tests (run under the existing `tools/me-mod/test` Lua harness):

- **`is_community_path`**: `'Community'`, `'Community/sub'`, `'Community\\sub'`,
  mixed case, `''` (root) and a normal folder like `'CAP'` /
  `'CommunityCenter'` (must NOT match the prefix without a separator).
- **`prefab_ops` guards**: `save_selection` / `move_prefab` / `rename_folder`
  reject Community targets (`ok == false`, message set) and leave a non-Community
  target working; confirm a normal save/move/rename still succeeds.
- **Imports unaffected**: `community_import.import` still writes into
  `Community/` (it bypasses the guarded functions — a direct test or an explicit
  note that its path is untouched).

Tree tint and context-menu gating are dxgui-bound and follow the repo
convention of manual smoke-testing rather than unit tests; the smoke steps:
Save/Move/New-subfolder/Rename into Community are blocked with the toast,
Community is omitted from the Move picker, its right-click menu hides
New-subfolder/Rename, and the Community node renders tinted.

## Non-goals

- No change to the import flow, the community tab, or the catalog.
- No "disable the Save button when Community is selected" affordance (toast +
  hard block suffices).
- No icon (widget can't); color tint only.
- No protection against deletion (removing downloads is allowed by design).
