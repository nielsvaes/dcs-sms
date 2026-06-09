# Prefab Community Provenance — Manager Side Spec

## Goal

Show the original author of a downloaded community prefab in the ME Prefab
Manager's "My Prefabs" grid, by surfacing the `meta.community = { author,
source }` marker that the dcs-sms Discord catalog bot stamps into every
catalogued prefab.

## User value

When a mission maker downloads prefabs other people shared, the library
currently gives no hint of who made them — all rows look like the user's own
work. Surfacing the author turns the library into something with provenance:
you can see at a glance which entries came from the community and who to credit
(or ask about) for each one. Own prefabs stay visually clean (blank Author
cell), so nothing changes for the common case.

## Scope

**In:**
- `prefab_ops.row_from_prefab` reads `meta.community` and exposes
  `row.community` (bool) + `row.author` (string|nil) on each scanned row.
- The "My Prefabs" grid in `prefab_manager.lua` gains an **Author** column
  (inserted between Theatre and Fixed Pos), populated only for community
  imports.
- A data-path unit test for the new row fields, registered in the test runner.

**Out:**
- No change to the import path, the safe-loader, or the Community tab — the
  `meta.community` marker already rides inside the verbatim, SHA-256-checked
  prefab bytes, so it is present the moment a community prefab lands on disk.
- No new author-editing UI; the author is read-only provenance from the
  catalog.
- The bot side (which produces `meta.community`) is a separate plan/repo and is
  out of scope here.

## Constraints

- Lua 5.1 (in-DCS dxgui environment). Tests are standalone Lua scripts that
  print `PASS`/`FAIL` and `os.exit(1)` on failure, run via
  `tools/me-mod/test/run-tests.ps1` against a Lua 5.1 interpreter on PATH.
- Framework failure-mode rule: log + return safe values, never throw on bad
  data. Reading an absent `meta.community` must simply yield
  `community = false`, `author = nil`.
- The grid auto-wires columns from the `COLS` table everywhere except
  `render_grid`, which has hardcoded cell indices — that is the only place a
  new column shifts indices.

## Decisions

- **Reuse the existing validated plan.** A complete task-by-task plan already
  exists at `docs/superpowers/plans/2026-06-08-prefab-community-provenance-manager.md`
  (handed off from the bot-side session). It was reviewed line-by-line against
  the current `prefab_ops.lua`, `prefab_manager.lua`, and `run-tests.ps1` and
  matches them verbatim, so it is adopted as-is rather than regenerated.
- **Author column position:** inserted after Theatre (index 2), shifting the
  later columns' `setCell` indices by one in `render_grid`. Width 110px,
  non-numeric. Placing it next to Name/Theatre keeps provenance with the
  identity columns rather than the count columns.
- **`row.community` is a strict boolean** (`type(meta.community) == 'table'`),
  and `row.author` is `meta.community.author` only when community, else `nil`.
  This keeps `sort_rows` nil-safe (its non-numeric branch coerces with
  `tostring(av or '')`).
- **No AGENTS.md change.** `tools/me-mod/AGENTS.md` documents
  `prefab_manager.lua` as a one-line summary and does not enumerate grid
  columns or the row schema, so adding a column changes no documented surface.
- **Task 2 (UI column) is verified manually**, not by an automated test — the
  prefab manager grid has no unit-test harness in this repo. The data path it
  depends on is covered by the Task 1 automated test.
- **Tasks run in parallel.** Task 1 (`prefab_ops.lua`, new test,
  `run-tests.ps1`) and Task 2 (`prefab_manager.lua`) have disjoint file sets,
  so they are implemented concurrently.

## Open questions

None.
