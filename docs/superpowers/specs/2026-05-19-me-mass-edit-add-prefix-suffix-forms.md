# ME Mass Edit — add prefix / add suffix forms (group scope)

**Status:** design
**Branch:** `worktree-me-mass-edit`
**Supersedes / extends:** Mass Edit rework series (PRs 1–4 + map-sync follow-up).
Adds two new name-mutating forms to the Group scope right pane. Mirrors
the structure of the existing `rename_group` / `find_replace_group_name`
forms — no host changes.

## Goal

Let users append or prepend a literal string to every selected group's
name in one click.

## User value

Today the user has two ways to mutate names:

- **Rename** — overwrites the name with a pattern, optionally numbered.
  Destructive.
- **Find & replace** — substring rewrites. Requires the substring to
  already exist.

Neither covers a common workflow: "tag a group of mixed names with a
common prefix or suffix without losing the original names." E.g.
prefixing every CAP flight with `BLUE-` for a scenario, or suffixing a
batch of test units with `-DELETEME`. The two new forms close that gap.

## Scope

### In scope (v1)

- Two new form modules under
  `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/`:
  - `add_prefix_group_name.lua` (title `Add prefix to group names`)
  - `add_suffix_group_name.lua` (title `Add suffix to group names`)
- Loader registration via `mass_edit_forms.lua`'s `by_scope.group` array.
- Per-form unit tests using the same pattern as
  `test_mass_edit_rename_group.lua`.
- `test_mass_edit_forms.lua` update: expects 6 group-scope forms now (was 4).
- Test runner registration in `tools/me-mod/test/run-tests.ps1`.
- Smoke checklist subsections in `docs/release-gate/me-mod-smoke.md`
  § Mass Edit.

### Out of scope

- Combined "single form, two buttons" UI (explicitly rejected during
  brainstorming — user picked two separate forms for symmetry with the
  existing pattern and to allow parking text in each box independently).
- Token support (`{n}`, `{cat}`, etc.). The underlying
  `mass_edit_transforms.add_prefix` / `add_suffix` are plain
  concatenation — if you want sequence numbers, use `rename_group`.
- Unit-name versions. The Mass Edit window doesn't yet have unit-scope
  forms; that's a different roadmap item.
- Any change to existing forms, transforms, the entity tree, or the
  left pane.

## Constraints

- Lua 5.1; standalone-test convention; lua at
  `/c/Users/Niels/bin/lua51/lua5.1.exe`.
- `pcall`-wrap every dxgui call (`Static.new`, `EditBox.new`, etc.).
- All name writes go through `group_name_writer.write` — DCS's
  `Mission.check_group_name` adds `-1`, `-2`, … suffixes on collision
  automatically. The form must not bypass this.
- Undo handler restores names via
  `group_name_writer.write(e, old, { literal = true })` — same pattern
  as rename_group / find_replace_group_name. Literal-mode undo prevents
  the restore from itself colliding and producing `Foo-3` when the user
  is owed `Foo`.
- Tests must NOT import dxgui — `_apply` is the testable seam.

## Decisions

### D1. Two separate forms, not one combined form

User picked B (two separate forms) over A (one form with two buttons).
Rationale: matches the existing one-form-per-operation pattern, lets the
user park different text in each input between actions, no shared-input
ambiguity. The right pane is already 4 forms tall; growing to 6 is
acceptable.

### D2. Form order in the right pane

`by_scope.group` order becomes:

```
{ rename_group,
  find_replace_group_name,
  add_prefix_group_name,
  add_suffix_group_name,
  set_country,
  toggle_group_flags }
```

Rationale: all name-mutating forms contiguous at the top; side-effecting
forms (set_country flips coalition, toggle_group_flags writes visibility
fields) at the bottom. Prefix before suffix follows English reading
order.

### D3. Layout — one-row form, no hint

Layout follows `rename_group.lua` minus the hint row (no `{n}` token to
explain). Form height = `TITLE_H + GAP_Y + ROW_H + FOOTER_PAD`. Single
input on row 1, button right-anchored on the same row.

Labels: `Text:` for both forms. Button labels: `Add prefix` / `Add suffix`.

### D4. Toast wording

Success (any rows changed):
- `N prefixed` / `N suffixed` (sev `success`)
- with ` · M failed` appended if any writes failed
- with ` · K unchanged` appended only if K > 0 AND there were also
  changes (matches `rename_group`'s "mixed" toast)

Edge cases:
- Nothing selected → `Nothing selected` (warn)
- Empty text input → `Text is empty` (warn)
- All rows already have the prefix/suffix (no-op) →
  `Already prefixed (N unchanged)` / `Already suffixed (N unchanged)`
  (info)
- Zero changes, zero failures, but text was non-empty AND selection
  non-empty → same `Already prefixed/suffixed` (info)

"Already prefixed" detection: an entity is "unchanged" when
`add_prefix(old, { text }) == old`, which only happens when `text` is
empty (covered by the earlier empty-input branch). So in practice the
"unchanged" branch is unreachable for prefix/suffix. Still, the
counting bookkeeping mirrors rename_group's so the toast logic
generalises identically — it just always lands on the "N prefixed"
branch in practice.

### D5. Empty-text behavior

If the text input is empty, the transform is a no-op for every entity.
We short-circuit BEFORE iterating: toast `Text is empty` (warn), no
writes, no undo record. Matches find_replace_group_name's empty-find
handling.

### D6. Empty selection behavior

`Nothing selected` toast (warn), early return. Matches every other
form's contract.

### D7. Undo

Each form pushes one undo record per apply using its own key:
- `mass_edit.add_prefix_group_name`
- `mass_edit.add_suffix_group_name`

Record shape: `{ rows = [ { entity, old }, ... ] }`. Handler walks rows
and calls `name_writer.write(entity, old, { literal = true })`. Same as
rename_group / find_replace_group_name.

### D8. No CLI verbs

These are in-ME-only forms. The existing `dcs-sms me group set-name`
verb already covers prefix/suffix via shell scripting (loop +
`set-name --name <old> --new "<prefix><old>"`). No new CLI surface.

## Architecture

### Files

**New:**
- `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/add_prefix_group_name.lua`
- `tools/me-mod/lua/dcs_sms_me/mass_edit_forms/add_suffix_group_name.lua`
- `tools/me-mod/test/test_mass_edit_add_prefix_group_name.lua`
- `tools/me-mod/test/test_mass_edit_add_suffix_group_name.lua`

**Modified:**
- `tools/me-mod/lua/dcs_sms_me/mass_edit_forms.lua` — two new requires +
  inserts into `by_scope.group`.
- `tools/me-mod/test/test_mass_edit_forms.lua` — bump expected count
  from 4 to 6, update title-list assertion if any.
- `tools/me-mod/test/run-tests.ps1` — add both new test filenames to
  `$tests` array.
- `docs/release-gate/me-mod-smoke.md` — add `### Add prefix to group names`
  and `### Add suffix to group names` subsections under § Mass Edit
  after the existing form subsections.

**Not touched:**
- `mass_edit_transforms.lua` — `add_prefix` and `add_suffix` already
  exist (lines 22 and 26).
- `group_name_writer.lua` — used as-is.
- `mass_edit.lua` — no host changes; the new forms register the same
  way as existing forms.

### Module contract

Each form module exports:

```lua
M.scope    = 'group'
M.title    = 'Add prefix to group names'  -- or 'Add suffix ...'
M.new(parent_raw, get_checked, on_after_apply) → panel | nil
M._apply(entities, text) → result table
```

`result` table:

```lua
{
    changed      = N,
    failed       = N,
    changed_rows = [{ entity, old }, ...],
    nothing_selected? = bool,
    nothing_to_apply? = bool,  -- empty text case
    toast = string,
    sev   = 'success' | 'warning' | 'info' | 'error',
}
```

(No `unchanged` field — these forms follow `find_replace_group_name`'s
result shape rather than `rename_group`'s. The "unchanged" branch is
unreachable for prefix/suffix when text is non-empty, so the bookkeeping
isn't useful.)

`panel` has `show`, `hide`, `get_height`, `set_bounds` — same shape as
the existing form panels.

## Testing

### Unit tests

Per-form tests using the `mock_me_mission` shim (same as
`test_mass_edit_rename_group.lua`):

**`test_mass_edit_add_prefix_group_name.lua` cases:**

1. Empty selection → `nothing_selected`, no undo, toast.
2. Empty text → `nothing_to_apply`, no undo, toast `Text is empty`, name
   untouched.
3. Single happy: `g.name = 'Foo'` + text `'X-'` → `g.name == 'X-Foo'`,
   `changed=1`, toast `1 prefixed`, sev `success`, undo recorded.
4. Multi happy: 3 groups with distinct names + text `'TEST-'` → all 3
   prefixed, toast `3 prefixed`, undo recorded.
5. Collision: 2 groups both named `'A'` + text `'X-'` → first becomes
   `'X-A'`, second becomes `'X-A-1'` (or whatever DCS's
   `check_group_name` returns — the mock should mimic this).
6. Writer rejection: stub `renameGroup` to return false → `failed=1`,
   `changed=0`, no undo recorded.
7. Writer throws: stub `renameGroup` to error → `failed=1`,
   `changed=0`.
8. Undo restores: case 3's groups → after `undo.undo()`, names are
   restored to original.
9. Module shape assertions: `scope == 'group'`, `title` non-empty
   string, `new` is function, `_apply` is function.

**`test_mass_edit_add_suffix_group_name.lua` cases:** identical
structure with `'Foo' + '-Y' == 'Foo-Y'`, toast `1 suffixed` /
`3 suffixed`, undo key `mass_edit.add_suffix_group_name`.

### Forms-loader test update

`test_mass_edit_forms.lua` currently asserts the group scope has 4
forms (rename, find_replace, set_country, toggle_group_flags). Update
to 6 with the two new forms inserted at positions 3 and 4 per D2.

### Smoke checklist additions

Two subsections under `## Mass Edit (v0.10.0+)` after the existing
form subsections (Visibility & control / Entity list multi-select /
Map selection sync). Use the existing subsection wording style.

`### Add prefix to group names` checklist:
- Open Mass Edit on Group tab. Check 3 groups with distinct names
  (e.g. `Alpha`, `Bravo`, `Charlie`). In the Add prefix form, type
  `BLUE-`. Click `Add prefix`. All 3 names become `BLUE-Alpha`,
  `BLUE-Bravo`, `BLUE-Charlie`. Toast reads `3 prefixed`.
- Check 2 groups both named `Foo`. Type `X-`. Click `Add prefix`. The
  two names become `X-Foo` and `X-Foo-1` (DCS auto-disambiguation).
- With nothing checked, click `Add prefix`. Toast `Nothing selected`.
- With groups checked but empty text box, click `Add prefix`. Toast
  `Text is empty`. Names unchanged.
- Press `Ctrl+Z`. The prior names are restored exactly (no
  `-1` suffixes leaking through undo).

`### Add suffix to group names` checklist: identical scenarios with
suffix wording.

## Open questions

None.
