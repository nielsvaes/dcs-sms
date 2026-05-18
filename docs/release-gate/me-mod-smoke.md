# ME-mod — manual smoke checklist

CI runs the parity + unit tests under `tools/me-mod/test/run-tests.ps1`. This checklist is the release-gate before tagging a `me-mod-v*` release; run by hand against a fresh DCS install.

For installation instructions and feature overview, see [`tools/me-mod/README.md`](../../tools/me-mod/README.md). This page is the release-gate procedure only.

## Setup

1. Run `tools/dcs-sms.exe install-me-mod`. Open the ME. Verify the top menu bar shows a **DCS-SMS** entry containing **Prefab Manager** and **About**. Verify the Prefab Manager window does NOT appear automatically.
2. Open **DCS-SMS → Prefab Manager**. Window appears with all panels (Save / Library / Action / Status).
3. Open **DCS-SMS → About**. Dialog appears centered with the Coconut Cockpit logo, version string, and project URLs. Close button dismisses it.

## SMSWindow + Prefab Manager refactor (added 0.5.0)

Verify the refactor preserved Prefab Manager behaviour exactly:

- [ ] Open ME with a fresh mission; click `DCS-SMS > Prefab Manager`. Window
      opens at top-right of screen, size matches pre-refactor (~720×460),
      title bar reads `Coconut Cockpit · DCS-SMS — Prefab Manager v0.5.0`.
- [ ] Drag a window edge to resize. Footer separator + status text stay
      glued to the bottom; grid stretches to fill the new content area.
- [ ] Drag a window edge inward past the minimum (~540 wide). Window
      snaps back to the minimum size.
- [ ] Click the close `[X]` in the title bar. Window hides; click the
      menu entry again — window reopens with state preserved (no widget
      reconstruction).
- [ ] In a fresh mission, save a prefab. Footer flashes green
      ("Saved <name>...") and reverts to empty after ~5s.
- [ ] Try to save with an empty name. Footer flashes yellow
      (warning); reverts after ~5s.
- [ ] Trigger an error (e.g. delete a file the mod is trying to open).
      Footer flashes red. Reverts after ~5s.
- [ ] Click "Place at click" on a saved prefab. Footer goes green and
      stays green ("PLACING ... CLICK ON MAP") until you click the map
      or press Escape — does NOT auto-revert.
- [ ] Press `Ctrl+Z` after placing a prefab. Last placement is undone
      and the footer flashes a green "Undo successful." message.
- [ ] Press `Ctrl+Z` with no placement to undo. Footer flashes a
      yellow "Nothing to undo." message.
- [ ] Click `File > New`. Prefab Manager auto-closes. Reopen via the
      menu — works.
- [ ] Click `File > Open` (load an existing mission). Prefab Manager
      auto-closes. Reopen via menu — works.
- [ ] `Ctrl+Shift+R` dev reload still works. Window closes, reload
      logged, window reopens with fresh code.

## Save flow

3. Place one A-10C in the ME. Select it. Type `test_jet` in the name field. Click **Save**. Verify file at `Saved Games\DCS\dcs-sms\prefabs\test_jet.lua` and the library refreshes to show it.
4. With nothing selected, click **Save** with name `empty`. Status: `No selection — nothing to save`. No file written.
5. With selection, click **Save** with name `test_jet` (collision). Modal appears with **Overwrite / Rename / Cancel**. Pick Cancel — no change. Pick Overwrite — file overwritten.
6. Multi-selection: select two groups + one trigger zone + one drawing. Save as `complex_test`. Open the saved file and verify all four sections are populated.

## Place flow — at click

7. Library shows `test_jet` sorted A-Z. Select it, set rotation 0, click **Place at click**. Verify the title bar text changes to `Click on map to place test_jet (Esc to cancel)` and the button text becomes `Cancel`.
8. Click somewhere on the map. Verify the A-10C appears at that location, status confirms placement, **Ctrl-Z** removes it (group disappears from the ME).
9. Re-place `test_jet`. Save the `.miz`, close the ME, reopen the `.miz`. Verify the placed group survived (no dcs-sms-specific state needed at runtime).
10. Place at click with rotation 90. Verify the group is rotated 90° from how it was saved.
11. Place at click then press **Esc**. Verify exit from place-pending, no entity injected.

## Place flow — at original

12. Save a prefab that includes a group near a specific map building. Click **Place at original location**. Verify it lands at the original `meta.world_anchor`, not at any clicked location.

## Best-effort partial-failure

13. Manually corrupt a prefab file to have one valid group + one group with a bogus DCS type. Place it. Verify status: `Placed N of M entities — see dcs.log`. The valid group is in the mission; the corrupt one is logged.

## Library

14. Save 3 prefabs with names `a`, `m`, `z`. Verify the grid is sorted A-Z and shows the documented columns (Name / Theatre / Fixed Pos / AB / G / S / Z / D).
15. Verify the **Theatre** column shows the current theatre name (e.g. `Caucasus`) for prefabs saved under this branch — *not* `?`.
16. Click a row. Verify it highlights and the status bar shows `Selected: <name>`. Click another. Selection moves.
17. Rename `m` to `middle`. Verify the file is renamed AND `meta.name` is updated inside (open the file).
18. Delete `middle`. Confirmation modal. Confirm. Verify file gone, list refreshed.
19. Manually drop a malformed `.lua` file into the prefabs dir. Click **Reload**. Verify it appears as a row with `[ERROR] <name>` in the Name column and a truncated error message in the Theatre column.

## Undo

20. Place a prefab. Press **Ctrl-Z** (window focused). Verify removal.
21. Press **Ctrl-Z** again. Status: `Nothing to undo.`
22. Place. Click somewhere outside the Prefab Manager window to remove its focus. Press **Ctrl-Z**. Verify nothing happens (window not focused — broad ME-wide undo is [issue #25](https://github.com/nielsvaes/dcs-sms/issues/25)).

## Dev reload

23. With the Prefab Manager window focused, press **Ctrl+Shift+R**. Verify the window briefly disappears and reopens (status bar shows `Ready.`). `dcs.log` should contain `dev reload triggered` → `cleared N modules from package.loaded` → `dev reload completed`. Subsequent edits to the mod's Lua files are picked up by another Ctrl+Shift+R, no DCS restart required.

## Cleanup

24. Run `tools/dcs-sms.exe uninstall-me-mod`. Verify everything removed (modules dir gone, `MissionEditor.lua` patch reverted from backup).

## Prefab Manager — folder browser + context menus

- [ ] Open Prefab Manager. Tree pane visible on the left; "+ New folder" button below the tree; "Search folders:" input above the tree.
- [ ] "Search files:" label (right of tree) renamed from "Search:".
- [ ] Click "+ New folder" with nothing selected → name prompt opens. Enter "CAP". Folder appears in tree at root level.
- [ ] Right-click "CAP" → menu shows New subfolder, Rename, Delete, Open in Explorer.
- [ ] Right-click "CAP" → New subfolder → "Tomcats". Nested folder appears.
- [ ] Select "CAP/Tomcats". Save a new prefab. Verify file lands in `<SavedGames>\DCS\dcs-sms\prefabs\CAP\Tomcats\<name>.prefab`.
- [ ] Click "Show all" button → selection clears (tree highlight gone), file pane shows all prefabs (root + nested) recursively.
- [ ] Click "CAP" parent → file pane shows prefabs from CAP and ALL its subfolders (recursive prefix match).
- [ ] Type "horn" in Search files while a folder is selected → narrows within folder.
- [ ] Type "horn" in Search files with no selection → matches across all folders.
- [ ] Type "tom" in Search folders → only tree nodes named or containing "Tom" are shown.
- [ ] Right-click a prefab row → menu shows Move to..., Copy file contents, Copy place snippet, Show in Explorer.
- [ ] Click "Show in Explorer" → Windows Explorer opens with the file selected.
- [ ] Click "Copy file contents" → paste somewhere, content matches the `.prefab` file body. Status line: "Copied X.prefab contents (N bytes)."
- [ ] Click "Copy place snippet" → paste, snippet matches `sms.prefab.place("<name>", {x = 0, y = 0})  -- rotation = 0, country = nil`. Status notes sms.prefab.place not shipped yet.
- [ ] Right-click a row with an error → only "Show in Explorer" enabled.
- [ ] Move to... opens modal; pick "SAM", click Move. Prefab now in SAM. File list and tree both refresh.
- [ ] Rename "CAP" → "Combat Air Patrol". Sub-folder "Tomcats" still inside it. Selection follows the rename.
- [ ] Delete a non-empty folder → confirmation overlay shows count. Cancel keeps it. Delete removes everything recursively.
- [ ] Folder name validation: try "CAP/x", "..", "CON" → all rejected with status message.
- [ ] Resize window → tree stays at 200 px wide; file grid widens.
- [ ] Reload (Ctrl+Shift+R) or close/re-open Prefab Manager → tree refreshes from disk.

## Mass Edit (v0.10.0+)

The Mass Edit window is being rebuilt around an action-panel model
(see `docs/superpowers/specs/2026-05-18-me-mass-edit-rework-design.md`).
PR-by-PR each form is added; this section will grow as forms land.

### Rename groups

- [ ] The Rename groups form is the topmost form in the Group scope's right pane.
- [ ] Pattern input has a sibling hint line "(use {n} for sequence, e.g. "Foo-{n}")".
- [ ] Check 3 groups, type `X-{n}` in Pattern, click Rename. Names become `X-01`, `X-02`, `X-03` in name-ascending order (alphabetical by previous name, not by check order). Footer toast: `3 renamed`.
- [ ] Type `Foo` (no `{n}` token) and click Rename with the same 3 groups checked. All three get a name based on `Foo` — DCS auto-disambiguates the collision. Toast: `3 renamed`.
- [ ] Click Rename with the pattern field empty. Toast: `Pattern is empty` (warning). No names mutate.
- [ ] Click Rename with nothing checked. Toast: `Nothing selected` (warning).
- [ ] Press `Ctrl+Z` while the window has focus. The most recent rename reverts.
- [ ] After a rename, the entity list refreshes and shows the new names.

### Find & replace in group names

- [ ] DCS-SMS → Mass Edit opens the window.
- [ ] Window title includes a `[loaded HH:MM:SS]` suffix (dev aid; remove when stable).
- [ ] The Group scope tab is active by default. The other four scope tabs (Unit, Waypoint, Zone, Drawing) are visible but render only a "No forms yet for this scope" label in the right pane when clicked.
- [ ] The left pane lists every group in the mission. Switching to a mission with several groups: the list populates with all of them. No dependency on the marquee tool.
- [ ] The name-filter EditBox above the list narrows it (case-insensitive substring match).
- [ ] Sort headers work — clicking Name / Country / Type / # Units sorts asc / desc.
- [ ] Checkboxes in column 0 toggle independently. Whole-row click also toggles.
- [ ] The right pane shows exactly one form: "Find & replace in group names".
- [ ] All widgets are skinned (visual match against Prefab Manager — same blue navy theme).
- [ ] Type `Foo` in Find, `Bar` in Replace. Check 2 groups whose names contain `Foo`. Click `Replace`. Names update to substitute Foo→Bar. Footer toast reads `2 renamed`.
- [ ] Groups whose names did NOT contain `Foo` remain unchanged.
- [ ] Press `Ctrl+Z` while the Mass Edit window has focus. The two renamed groups revert to their original names.
- [ ] Click `Refresh`. The list re-walks the mission; any external rename (e.g. via ME group panel) is picked up.
- [ ] Click `Cancel`. The window hides. DCS-SMS → Mass Edit reopens it.
