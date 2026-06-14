# Prefab triggers — save, bundle, and import mission triggers via the Prefab Manager

**Date:** 2026-06-10
**Status:** Approved design
**Area:** ME-mod (Prefab Manager), prefab data format

## Problem

The Prefab Manager can save and place nearly everything on the map — groups,
statics, zones, drawings, airbase warehouses — but **mission triggers don't
travel**. Mission logic coupled to cockpit state (radio frequencies, ICP
buttons), zone presence, or flag chains has to be rebuilt by hand or injected
with one-off scripts when moving between missions.

Two user stories:

1. **Standalone trigger export.** "I built 36 triggers reading the F-16's ICP
   and radios. I want to check them off in a list and save them to a file I
   can bring into my next mission."
2. **Bundled with a prefab.** "I saved a convoy prefab; a trigger checks
   whether that convoy is in a zone and activates a CAP flight. The trigger
   should ride along with the prefab, and placement should ask whether to
   bring it in."

## The core difficulty: non-portable references

A `mission.trigrules` entry is not self-contained. Audit of a real mission
(36 triggers) plus the descriptor machinery in `trigger_verbs.lua` gives four
reference kinds:

| Kind | Example | Portability |
|---|---|---|
| Literals + raw Lua | `a_do_script` text, `c_cockpit_param_equal_to`, coalition/unitType filters, flags | Copies verbatim (~90 % of the audited mission) |
| Entity ids | `zone = 99`, `group = 12` — numeric ids into the source mission | Dangles in any other mission |
| `DictKey_*` text | message/radio text via the dictionary | Source-mission dictionary only |
| `ResKey_*` media | `a_out_picture file = "ResKey_Action_36"` → embedded .miz file | Source-mission resources only |
| Predicate descriptor tables | `entry.predicate` is a live descriptor table | Not serializable; rebuild from target's descriptors |

## Decisions (user-confirmed)

1. **Unified format** — triggers are an optional `triggers` array in the
   existing `.prefab` table. A "trigger prefab" is a prefab with empty
   groups/statics/zones/drawings. One file type, one library, one place flow;
   Community catalog support comes for free.
2. **Unresolved references → manual map before import.** Auto-bind what we
   can; the user binds or skips the rest in the import dialog.
3. **Media is copied** — referenced pictures/sounds/script files are
   extracted at save and re-injected at import.
4. **Media storage: base64-embedded in the `.prefab` file** (preserves the
   one-file invariant: move/rename/community/Discord-bot untouched). Size
   warning above 5 MB per file.
5. **Save bundling: confirm with checklist** — detected related triggers
   appear pre-checked in a save-time dialog; user can exclude.
6. **Flag collisions: warn on overlap, never rewrite** (flags also live
   inside do-script text where rewriting is unsafe).
7. **Triggers tab layout: master–detail** (checkable grid left, detail +
   portability pane right, save form bottom).
8. **Import flow: one combined dialog** (checklist + unresolved-ref mapping
   section + flag warning, single Import button).

## Section 1 — Data model

New optional keys in the prefab table; `PREFAB_VERSION` bumps **0.3.0 →
0.4.0**. Old prefabs (no `triggers` key) load unchanged; older ME-mod
versions ignore the new keys.

```lua
triggers = {
  { name = "activate HornetCap",           -- from t.comment
    type = "once",                         -- friendly trigger-type string
    eventlist = "",
    color = "0xff8800ff",                  -- optional; ED's t.colorItem hex,
                                           -- absent = default list color
    conditions = {
      { predicate = "c_all_of_group_in_zone",
        fields = { group = { ref = "group", id = 12, name = "Enemy Convoy" },
                   zone  = { ref = "zone",  id = 99, name = "Ambush Zone" } } },
    },
    actions = {
      { predicate = "a_activate_group",
        fields = { group = { ref = "group", id = 7, name = "HornetCap" } } },
      { predicate = "a_out_picture",
        fields = { file = { res = "brief.png" }, seconds = 10 } },
    },
  },
},
meta.resources  = { { name = "brief.png", data = "<base64>" } },
meta.flags_used = { 100, 101 },   -- structured fields only, for cheap warn
```

Save-time conversion (source: the resolved-get machinery already in
`trigger_verbs.lua`):

- **Entity ids** → `{ref=kind, id=N, name="..."}`. Kind classification via
  `_trigger_field_combo_kind`; name snapshotted at save.
- **DictKey text** → resolved literal string (re-`fixDict`'d at import).
- **ResKey media** → `{res="filename"}` + bytes in `meta.resources`.
- **Predicate descriptor tables** → canonical string name only; entries are
  rebuilt at import through ED's factories (`createTrigger` / `createRule` /
  `createAction`), which also absorbs cross-DCS-version descriptor drift.
- Literals, flags, do-script text → verbatim.

Base64 needs a pure-Lua encoder/decoder (~40 lines) in the ME environment.

Trigger-only prefabs omit `meta.world_anchor`; the distill "no positionable
entities" guard gets a triggers-only bypass.

## Section 2 — Save flows

### Flow A: the Triggers tab

Third tab in the Prefab Manager (`[My Prefabs] [Community] [Triggers]`),
master–detail:

- **Left:** checkable grid over `mission.trigrules` in mission order —
  checkbox | name | type | C | A | **Refs**. Refs column per trigger: `✓`
  fully portable, else badges (`group`, `zone`, `🖼 media`). Filter box,
  check-all/none, shift-click range fill (reuse Mass Edit grid patterns).
- **Right:** detail pane — conditions/actions in resolved friendly form
  (like `trigger_get`) + portability report (entity refs, media files with
  sizes, flags used).
- **Bottom:** prefab name + *Save checked → prefab*. The folder is fixed to
  the reserved `Triggers/` library folder (no picker) — the My Prefabs
  folder browser marks `Triggers/` as a special folder (gold tint, same
  treatment as `Community/`) so it reads as auto-managed. Unlike
  `Community/` it stays writable; it is not added to the import-only
  move/save guards.

The tab refreshes its grid when shown. The saved file is a normal prefab in
the normal library; importing later happens from My Prefabs via Place.

### Flow B: auto-bundling on normal prefab save

After Save (and "Update Prefab with selection"), scan `mission.trigrules`
for triggers whose condition/action fields reference a **selected** group,
unit, or zone by id. None found → save proceeds exactly as today. Found →
confirm dialog: detected triggers pre-checked, each with its Refs summary.
A detected trigger may also reference entities *outside* the selection;
those save as `{id, name}` and surface in the dialog ("also references:
JTAC-1 ⚠ not in selection") so the user can widen the selection or accept a
loose ref that will name-resolve / manual-map at import.

> **Update (2026-06-14):** the passive "also references" surface is now a
> blocking confirmation gate — see
> [`2026-06-14-prefab-trigger-dangling-ref-gate-design.md`](2026-06-14-prefab-trigger-dangling-ref-gate-design.md).
> Bundling a trigger with references outside the prefab requires an explicit
> *Save anyway*; *Cancel* aborts the save.

Detection is exactly groups + units + zones (drawings can't be referenced
by triggers; trigger→trigger references don't exist in the schema).

## Section 3 — Import / rebinding pipeline

Runs after entity placement when the placed prefab has `triggers`, or
immediately on Place for a triggers-only prefab (both place buttons skip the
map click — nothing positional).

1. **Build rebind maps.** Placement already builds `gid_map`/`uid_map`
   (old→new). Extend the place record with a **zone map**: saved zone id →
   id returned by `TriggerZoneController.addTriggerZone`.
2. **Resolve every `{ref, id, name}`:**
   1. id in placement map → rewrite to new id (rename-proof; the bundled
      happy path — survives Name/Prefix/Suffix forms and collision renames).
   2. else name lookup in target (`group_by_name` / `unit_by_name` /
      TriggerZoneData scan).
   3. else → unresolved; goes to the dialog.
3. **Combined dialog.** Checklist of incoming triggers (all checked, each
   annotated with resolution status). Unresolved-refs section (only when
   non-empty): per ref, a dropdown of existing target entities of the
   matching kind + "— skip this condition/action —". Guard: if skips would
   leave a trigger with zero actions, auto-uncheck it with a reason (ED's
   `fixTriggers` purges action-less triggers). Flag-overlap warning strip
   (`meta.flags_used` ∩ target trigrules flags). Buttons: *Import N
   triggers* / *Skip triggers* — skipping never affects the already-placed
   entities.
4. **Inject.** Rebuild each checked trigger via ED's factories from the
   target's descriptors; apply resolved fields; `dictionary.fixDict` for
   text; write each embedded media file into the target's resources and
   re-key the field. Append at end of `mission.trigrules` in saved order;
   `_trigger_unique_name` on collision; `_trigger_panel_refresh` if the
   panel is open.

**Failure containment:** unknown predicate (DCS renamed/removed it) fails
that one trigger with a named reason; never throws, never aborts the rest.

**Undo:** the placement undo record grows a `triggers` list; Ctrl+Z removes
the imported entries (by identity) along with the placed entities.

**Research flag (isolated):** the ME's resource-*write* path (filename +
bytes → ResKey in the open mission). The read side is confirmed; the write
side is what ED runs when the user picks a picture in the actions panel —
discoverable by grepping `MissionEditor/modules/` (`me_trigrules.lua`'s
action edit form). Isolate in `trigger_media.lua` so a discovery dead end
degrades media-copy to import-with-warning without touching the rest.

## Section 4 — Edge cases

- **Eventlist triggers** — literal event id, copies verbatim.
- **`a_do_script_file`** — ResKey'd script file; rides the media path.
- **Stray zone-id defaults** — ED bakes default zone ids into condition
  forms that don't semantically use them (audited: `zone = 99` on a
  DEVCODE check). A ref whose field the descriptor marks optional/defaulted
  and whose value can't resolve is **cleared to the predicate default**
  instead of nagging the user. Only load-bearing refs reach the manual map.
- **`["or"]` pseudo-predicate** — fieldless predicate entry; serializes and
  rebuilds like any other.
- **Same prefab placed twice** — names auto-suffix; flag warning fires (by
  construction); user decides. Warn-only per Decision 6.
- **Community prefabs with triggers** — the data-only safe-load grammar
  already accepts the new keys. But `a_do_script` is arbitrary
  mission-runtime Lua (executes when the mission runs, not in the ME — same
  trust level as a downloaded .miz). Disclosure, not silence: Community
  detail pane shows "contains N triggers, M with scripts"; catalog
  `gen_index.py` adds a `has_triggers` badge.

## Testing

- **Pure-Lua standalone** (`tools/me-mod/test/`, mock_me_mission harness):
  serialize → portable form; resolve via id-map / name / unresolved;
  zero-actions guard; default-clearing for stray refs; base64 round-trip;
  flags_used extraction; 0.3.0-file regression (no `triggers` key).
- **Manual smoke** (release gate): round-trip a 36-trigger mission into a
  fresh mission — standalone tab save + import, bundled save + placement
  dialog, media round-trip, undo. Add to `docs/release-gate/me-mod-smoke.md`.

## Scope, docs, versioning

New modules: `triggers_tab.lua` (UI), `trigger_export.lua` (serialize),
`trigger_import.lua` (rebind + inject + dialog), `trigger_media.lua`
(resource read/write + base64). Mutations to: `prefab_distill.lua`
(triggers section, anchor bypass, version bump), `prefab_ops.lua` (save
paths, scan_dir row counts gain a T column), `prefab_manager.lua` (tab,
placement hook, undo record), `community_tab.lua` + safe-load (disclosure),
Mass Edit grid helpers (extract/reuse).

Same-change-set requirements (repo doc-sync rules):
- `tools/me-mod/AGENTS.md` file-layout table — new module rows.
- `PREFAB_VERSION` → 0.4.0 (`framework/prefab_distill.lua` comment block +
  me-mod copy).
- ME-mod minor version bump + CHANGELOG.
- `tools/me-mod/README.md` — user-facing Triggers tab section.

**Out of scope (v1):** `me trigger export/import` CLI verbs (natural
follow-on; no `docs/cli` regen needed now), flag remapping, cross-trigger
dependency analysis, media dedup against target resources.
