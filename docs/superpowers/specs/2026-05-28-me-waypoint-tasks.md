# me-mod: waypoint task / enroute-task verbs (gh #69)

**Date:** 2026-05-28
**Issue:** [#69](https://github.com/nielsvaes/dcs-sms/issues/69)
**Branch:** `worktree-feat+me-waypoint-tasks-gh69`
**Author:** Niels Vaes (with Claude)

## Goal

Add `dcs-sms me waypoint` verbs to add, remove, and clear the
**ComboTask** payload at any waypoint of any group — the "waypoint tasks"
(Bombing, Orbit, Strafing, Attack Group, Escort, …) and the "enroute
tasks" (Engage Targets, CAP, CAS, …) that DCS persists inside
`wp.task.params.tasks` of each `.miz`.

Also surface a thin discovery layer so the caller can find out what
task IDs are legal at all (`list-tasks`) and what parameters a given
task accepts (`describe-task`), mirroring the existing
`trigger list-predicates` / `trigger describe-predicate` pair.

## User value

Today the only ways to put a waypoint task on a group are (a) edit the
`.miz` zip manually or (b) click in the ME GUI. Both block scripted /
AI-driven mission generation that uses waypoint tasks — Bombing runs,
CAS assignments, Orbit patterns, Escort tasks, enroute Engage Targets,
etc. With these verbs an agent can do the full waypoint-task surface
from the CLI, the same way it already does waypoint position/action/eta
mutation.

## Scope

### In scope

8 new verbs under `me waypoint`:

| Verb | Purpose |
|---|---|
| `add-task` | Append a **waypoint-kind** task to a waypoint's ComboTask. Validates `--task` against the waypoint-task IDs the group's current main task allows. |
| `remove-task` | Remove a waypoint-kind task by `--slot <N>` (1-based index into `wp.task.params.tasks`). Renumbers `["number"]` on remaining entries. Fails if the slot holds an enroute-kind task. |
| `clear-tasks` | Drop all waypoint-kind tasks at a waypoint, leave enroute-kind tasks intact. |
| `add-enroute-task` | Same as `add-task` but validates against the enroute-task IDs allowed for the group's current main task. |
| `remove-enroute-task` | Same as `remove-task` but fails if the slot holds a waypoint-kind task. |
| `clear-enroute-tasks` | Drop all enroute-kind tasks, leave waypoint-kind tasks intact. |
| `list-tasks` | Print legal task IDs grouped by **kind** (waypoint / enroute) for the given group's main task. With `--all`, ignore the group and list every (kind × group-task) combination. |
| `describe-task` | Print the parameter descriptor for one task ID: field name, type, default, allowed values. Mirrors `trigger describe-predicate`. |

CLI shape (per verb): `--group-name <X>` or `--group-id <N>` (mutually
exclusive, matching the rest of the `waypoint` family), `--index <N>`
(0-based waypoint index, matching the rest of the `waypoint` family).
`add-*` verbs additionally take `--task <id>` and positional `k=v` task
parameter pairs, parsed by the same helper that `trigger add-action`
uses. `remove-*` verbs take `--slot <N>`. `list-tasks` / `describe-task`
take their own subset.

### Out of scope

- **Reading.** `me waypoint get` already returns the full waypoint blob
  including `task.params.tasks`. We do not add a dedicated `get-tasks`.
- **Mutating an existing task in place.** Callers can `remove-task
  --slot N` then `add-task ...`. A `set-task-field` verb may be added
  later but is not part of this change.
- **`WrappedAction` / option commands.** Waypoints also carry a separate
  family of `WrappedAction[Option/EPLRS/Script/...]` entries in the same
  `tasks` array. These are *commands*, not tasks, with their own
  descriptor space. They are tracked in a future issue, not here.
- **The framework (`sms.*`) side.** This change touches the host-side
  CLI + ME-mod only. No `sms.waypoint.addTask(...)` mission-runtime API
  is added here.
- **Task `number` resequencing semantics beyond simple 1..N.** ED itself
  accepts non-contiguous `number` fields; we always rewrite the
  remaining entries to 1..N after a remove/clear. Callers who relied on
  a specific gap pattern will see it normalized away.

## Constraints

1. **Doc-sync rule.** Every verb add must update
   `tools/me-mod/AGENTS.md` §1.4's verb namespace table and regenerate
   `docs/cli/` via `dcs-sms doc` in the same commit. The repo-level rule
   is in the root [`AGENTS.md`](../../../AGENTS.md).
2. **Failure-mode rule.** No verb may `error()` or `assert()`; every
   failure returns `{ok=false, error="..."}`. Caller validation errors
   are surfaced verbatim.
3. **No mission-runtime API.** Verbs operate on the editable
   `require('me_mission').mission` table only — no `Group.getByName`,
   no `coalition.addGroup`.
4. **Panel-refresh guarantee.** After any mutation that's visible in the
   ME GUI (route panel showing the waypoint), the verb must call
   `refresh_route_panel()` so the user sees the change without
   re-selecting the group. This already exists in `route_verbs.lua`.
5. **Versioning.** New verbs are a **minor** ME-mod version bump
   (current 0.14.3 → 0.15.0), per the root
   [`AGENTS.md`](../../../AGENTS.md#4-versioning-and-releases). Bump
   `tools/me-mod/lua/dcs_sms_me/version.lua` and add a CHANGELOG entry
   in the same change-set.
6. **`me_action_db` access.** The verbs require ED's
   `MissionEditor/modules/me_action_db.lua` to be loadable via
   `require('me_action_db')`. If ED renames or removes it in a future
   build, the verbs fail closed with a clear error pointing at the
   module rather than silently producing bad output.

## Decisions

### D1. Both task kinds share one storage array

Both waypoint tasks and enroute tasks live in
`wp.task.params.tasks` — there is no separate storage for the two
kinds. The kind is determined by **which descriptor table the task ID
appears in** (`waypointTasks` vs `enrouteTasks` inside
`me_action_db`'s per-group-task entry). `remove-task` / `clear-tasks`
walk the array and skip entries whose ID is not in the waypoint-task
descriptor; the enroute pair does the inverse. This keeps `--slot N`
semantically stable across the whole array — slot 3 is always the 3rd
entry regardless of kind.

### D2. Slot is 1-based, into the raw `tasks` array

`--slot N` indexes `wp.task.params.tasks[N]` directly (1-based to match
Lua and to match how `me waypoint get` already prints them). It is **not**
the `["number"]` field on each entry — that field is auto-rewritten to
1..N after every remove/clear, so it cannot be a stable identifier.

### D3. `add-task` defaults

When the caller doesn't override:

- `enabled = true`
- `auto = false`
- `number = #wp.task.params.tasks + 1` (appended at the end)
- All descriptor params take their `me_action_db` `default` if present,
  otherwise nothing is written for that field (ED tolerates a missing
  field by reading the per-task-type fallback at run time).

The caller can override `--enabled false` or `--auto true` via the same
positional `k=v` pair syntax (`enabled=false`, `auto=true`). Same for
`--number N` if the caller wants to inject mid-array (no array
re-shuffle is performed; ED is fine with non-contiguous numbers, even
though we normalize on remove).

### D4. CLI flag parsing — reuse trigger helpers

`add-task` / `add-enroute-task` reuse `parseTriggerFieldArgs` and
`buildLuaFieldsExpr` from `tools/cmd/dcs-sms/me_trigger_args.go`. These
already do `k=v` parsing, type-coercion of numeric literals, and quoted
strings. The Lua side does the same descriptor-driven coercion the
trigger verbs do.

Lua-side, we factor out a small `task_db.lua` helper analogous to the
trigger alias-cache code. We do **not** generalize the trigger code in
place — the two stay parallel for clarity until a third caller forces
shared abstraction.

### D5. Discovery verbs are part of v1

`list-tasks` and `describe-task` ship together with the mutators in
this change. Without them callers have no way to know what `--task`
values are legal for a given group, and the existing
`trigger list-predicates` precedent shows the value of bundling
discovery with the mutating surface.

### D6. Group-task gating

`add-task` reads `g.task` (the group's main task — "CAS", "CAP",
"Ground Attack", "Nothing", etc.) and validates `--task <id>` against
the **waypoint-task** subtree of `me_action_db[g.task]`. If the ID is
not in that subtree, the verb errors out with:

```
unknown waypoint task "X" for group task "CAS" — run `me waypoint list-tasks --group-name <G>` to see what's legal
```

`add-enroute-task` does the same against the **enroute-task** subtree.

If `g.task` is empty or `"Nothing"`, neither kind has a non-trivial
descriptor and both verbs reject with a clear "the group's main task is
set to '<X>'; set it with `me group set-task` first" error.

### D7. `list-tasks --all` shape

```
{
  "ok": true,
  "all": true,
  "categories": [
    { "group_task": "CAS",
      "waypoint": ["AttackGroup", "Bombing", "Strafing", ...],
      "enroute":  ["EngageTargets", "EngageGroup", ...] },
    { "group_task": "CAP", "waypoint": [...], "enroute": [...] },
    ...
  ]
}
```

Without `--all` (and given `--group-name`):

```
{
  "ok": true,
  "group": "Hornet-1",
  "group_task": "CAS",
  "waypoint_tasks": [...],
  "enroute_tasks": [...]
}
```

### D8. `describe-task` shape

```
{
  "ok": true,
  "task": "Bombing",
  "kind": "waypoint",          // or "enroute"
  "group_tasks": ["CAS", "Ground Attack", ...],  // where this task is legal
  "fields": [
    { "id": "weaponType",  "type": "edit",   "default": 2048 },
    { "id": "expend",      "type": "combo",  "default": "All",
      "options": ["One", "Two", "Four", "Quarter", "Half", "All"] },
    { "id": "altitude",    "type": "edit",   "default": 2000 },
    ...
  ]
}
```

(Field name, type tag, and default are direct lifts from the
`me_action_db` descriptor; `options` is the descriptor's combo list
when present.)

### D9. Where the Lua lives

- New file: `tools/me-mod/lua/dcs_sms_me/task_db.lua` — module-private
  loader for `me_action_db`, with public surface
  `task_db.resolve(task_id, group_task, kind)` returning
  `{canonical, descr, err}`, and `task_db.list(group_task)` returning
  the two name arrays for `list-tasks`.
- All 8 verbs land in
  `tools/me-mod/lua/dcs_sms_me/verbs/route_verbs.lua` (the existing
  owner of all waypoint mutations).
- `task_db` is required only at first use — same lazy-load pattern as
  trigger's `_trigger_alias_cache`.

### D10. Test surface

- **Go tests** under `tools/cmd/dcs-sms/me_waypoint_*_test.go` for each
  new verb: flag parsing, Lua-arg expression shape, exit codes.
- **Lua mock tests** under `tools/me-mod/test/test_verbs_waypoint_tasks.lua`
  using `mock_me_mission.lua` plus a small in-test `me_action_db` stub
  (real ED module is not available in the Lua mock environment). Tests
  cover: add/remove/clear round-trip on a stub waypoint, kind-gating
  enforcement, slot-out-of-range errors, group-task-gated rejection,
  default field population, list / describe shape.
- **Manual smoke item** added to
  `docs/release-gate/me-mod-smoke.md`: "add Bombing waypoint task to a
  CAS hornet, save .miz, reload, confirm bombing run executes."

## Open questions

None. Any ambiguity discovered at implementation time gets resolved
against the trigger pattern (the closest precedent in the codebase),
documented inline as a comment, and the spec is amended.

## Deviations from initial design (2026-05-28)

Live probe of ED's `me_action_db` (DCS Open Beta build, May 2026) revealed
the module's shape doesn't match either of the two shapes the spec
hypothesized. The actual layout is:

- `me_action_db.actionsData` is a 114-entry array; each entry is
  `{desc, displayName, task={id, params}, type}`.
- `type` is the discriminator: 1=waypoint task, 2=enroute task,
  3=command, 4=option. Counts at probe time: 24 / 15 / 19 / 22.
- Group-task gating ("which task ids are legal for a CAS group's
  waypoint") is NOT a static lookup — it's a runtime predicate
  `isGroupCapableOfAction(group, action)` that takes a live group
  reference.

**Consequences for the surface in this spec:**

- **D6 (group-task gating):** dropped from v1. `add-task` / `add-enroute-task`
  validate only that the task id exists and matches the requested kind;
  they do not refuse ids that ED's GUI would also have rejected for the
  group's main task. ED still enforces semantic validity at save / run
  time. Re-introducing static gating would require crawling
  `isGroupCapableOfAction` for every (group, action) pair on first use,
  or running it live at add-task time — left for a follow-up if
  user-reported.
- **D7 (list-tasks shape):** `--group-name` / `--group-id` are accepted
  by the CLI for forward-compatibility but ignored by the Lua verb;
  output is always the full waypoint + enroute lists (filtered by
  `--kind` if passed). `--all` becomes implicit.
- **D8 (describe-task shape):** the response omits `group_tasks` (no
  static index of "where is this task legal"). Keeps `task`, `kind`,
  `display_name`, `desc`, `fields`. `fields` is derived from the
  task's `params` defaults (each entry: `{id, type, default}` —
  no `options` arrays because the real descriptors don't carry them
  in `actionsData`).
