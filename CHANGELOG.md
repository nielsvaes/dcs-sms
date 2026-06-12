# Changelog

This project ships two parallel components on independent semver tracks:

- **Framework** (`framework/`) — the runtime `sms.*` API loaded into mission scripts. Tags: `framework-v0.X.Y`. Canonical version: `sms.version` in `framework/sms.lua`.
- **ME-mod** (`tools/me-mod/`) — the Mission Editor extension. Tags: `me-mod-v0.X.Y`. Canonical version: `tools/me-mod/lua/dcs_sms_me/version.lua`.

Format loosely follows [Keep a Changelog](https://keepachangelog.com). Both tracks live in 0.x — minor bumps may include breaking changes; major bump (1.0) is reserved for the moment the public surface stabilises.

---

## Framework

### [0.11.0] — 2026-05-07

**Changed**
- `sms.prefab.load_dir` now accepts both `.prefab` and `.lua` files. Saves still go through `sms.prefab.save` with whatever path you pass; the canonical extension going forward is `.prefab`.

### [0.10.0] — 2026-05-05

This is the first tag after a long quiet period — `sms.version` had been frozen at `"0.1.0"` while nine `framework-v0.x.0` tags shipped through April 27. 0.10.0 catches the in-source string up to reality and folds in everything added since `framework-v0.9.0`.

**Added**
- `sms.task` — task spec builders covering move-to, attack, orbit, escort, refueling, and more, with per-category adaptation.
- `sms.options` — group options (ROE, alarm state, formation, …) wired through `sms.K` enums.
- `sms.commands` — runtime commands: start/stop firing, set frequency, set callsign.
- `sms.rule` — declarative AI rule API.
- `sms.K` — central enum namespace. Subsumes the previous standalone `sms.countries` / `sms.skill` / `sms.alt_type` / `sms.waypoint` / `sms.targets` / `sms.designations` modules and adds `sms.K.coalition`, `sms.K.category`, `sms.K.roe`, `sms.K.alarm_state`, `sms.K.formation`.
- `sms.K.units` and `sms.K.statics` — generated catalogs of every DCS unit and static type, written by `tools/dcs-sms.exe gen-units`.
- `sms.utils.serialize` — byte-stable Lua-data serializer; shared with the ME-mod's prefab format.
- `sms.prefab` — load and spawn prefabs from a mission script (rotation, country override, injection record).

**Changed**
- Country resolution now reads `boss.id` from the real ME selection shape (replaces an earlier heuristic).
- Drawing serialization preserves vertex deltas instead of absolute coords; place applies drawing rotation.

**Internal**
- Smoke test suite ported from bash to PowerShell.
- ACE skill level added to `sms.K.skill`.

### [0.9.0] — 2026-04-27
**Added**
- `sms.weapon` — wrapper with snapshot, polled tracker, impact extrapolation, `on_impact` and `WEAPON_IMPACT` bus delivery, destroy semantics.

### [0.8.0] — 2026-04-27
**Added**
- `sms.events` — pub/sub bus with entity-handle sugar, destroy emit, group-fully-dead semantic.

### [0.7.0] — 2026-04-27
**Added**
- `sms.static` — entity wrapper, `create`, `clone`.
- `sms.area:is_static_in`.

### [0.6.0] — 2026-04-26
**Added**
- `sms.group.create`, `sms.group.clone`.
- `sms.utils` conversions.

### [0.5.0] — 2026-04-26
**Added**
- `sms.area`.
- `_make_callable_handle` factory (internal).

### [0.4.0] — 2026-04-26
**Added**
- `sms.unit`.
- `sms.group:get_units()`.

### [0.3.0] — 2026-04-26
**Added**
- `sms.timer`.

### [0.2.0] — 2026-04-26
**Added**
- `sms.group`.

### [0.1.0] — 2026-04-25
**Added**
- `sms.log` (logger module).
- `sms.utils`.

---

## Tools / Hook

### [hook 0.2.0] — 2026-05-08

**Added**
- `target` field on requests: `"mission"` (default — runs in the in-mission scripting env via `net.dostring_in`) or `"gui"` (handed off to the ME-mod's bridge — runs in the shared GUI/ME Lua state and reaches the editable mission table).
- `dcs-sms exec --target gui|mission|auto`. Default is `auto` — picks `mission` if a sim is running, `gui` if the user is in the ME / main menu (and the ME-mod toggle is on).
- New heartbeat fields: `state`, `gui_bridge_enabled`, `tick_source`, plus `last_tick`/`last_tick_at` aliasing `last_frame`/`last_frame_at`.
- ME-mod writes its own heartbeat to `state/me.json`. CLI's `hookstatus.ReadMerged` fuses both heartbeats so the routing layer sees a unified view (mission state from the hook, gui state from the ME-mod).
- New CLI exit code 4 (`exec`): `target=gui` requested but the ME-mod's "External execution" toggle is off.

**Changed**
- `dcs-sms exec` no longer rejects `mission_loaded=false` outright — `--target gui` works in the ME without a running mission. Routing decisions live in `RouteForTarget`.
- The hook itself stays single-tick (`onSimulationFrame` only — Hooks/ env has no per-frame tick outside sim, runtime-tested). The `target=gui` poller lives in the ME-mod's `bridge.lua`, driven by `UpdateManager.add` in the ME env where it's actually wired.
- The hook now skips `target=gui` requests in the inbox (leaves them for the ME-mod's poller to pick up) instead of trying to handle them itself.

**Compatibility**
- Heartbeat keeps `last_frame` / `last_frame_at` populated alongside `last_tick` / `last_tick_at` for one release.
- Requests without a `target` field are treated as `target=mission` (today's behavior).

---

## ME-mod

### [0.25.1] — 2026-06-12

**Added**
- `prefab_modules.absent(list)` — list-shaped sibling of `missing()` that filters a Community manifest entry's `required_modules` array to the not-installed subset.

**Changed**
- Community tab: a prefab's third-party mod dependency now surfaces as a **yellow warning line above the "Add to my library" button**, shown **only** when you don't have that mod installed. The existing plain "requires mods" info line (which lists all required mods) is unchanged.

**Fixed**
- Community tab: the image preview and missing-mod warning no longer "show through" onto the My Prefabs page. The Community panel's `relayout` (run on every window resize for *all* tabs, so each stays sized) re-asserted those widgets' visibility from the current selection regardless of which tab was active; it now respects the panel's hidden state and never reveals widgets while another tab is showing. Leaving the Community tab also closes the pop-out image viewer if it was open (previously it lingered over the other tab with a stale screenshot).
- Importing a trigger whose condition is a **Lua Predicate** (`c_predicate`) no longer loses the Lua code on save. The condition's `text` field is now dictionary-keyed (`KeyDict_text`) on import, matching ED's native on-disk shape — previously it was written as a raw literal, and ED's `saveTriggers` (which routes every condition's `text` through `textToMis`) wiped it to `nil`, leaving an empty predicate box after save. The same fix is applied to the `trigger add-condition` CLI verb, which had the identical flaw.

### [0.25.0] — 2026-06-12

**Added**
- Community tab image previews: selecting a community prefab now shows its
  screenshots on the right, below the description. Images come from the
  prefab's `<stem>.meta.json` sidecar (`images` array), are downloaded lazily
  over the existing HTTPS transport, and cached under
  `Saved Games/DCS/dcs-sms/community-images/`. One image shows at a time with
  `◀ i / N ▶` navigation; it scales to the column width with aspect ratio
  preserved and re-fits live as the splitter or window is resized. Degrades
  silently (panel collapses, description fills the column) when a prefab has no
  images or networking is unavailable. The preview scales the whole screenshot
  to fit the column (aspect preserved), and clicking it opens a larger,
  resizable window showing the image with the same `◀ i / N ▶` navigation kept
  in sync with the inline thumbnail.

### [0.24.1] — 2026-06-11

**Fixed**
- Drawings vanished on save. A drawing added by the Prefab Manager (placing a
  prefab that contains a drawing) or by the `me drawing create-*` / `set-*`
  verbs rendered on the map but was dropped when the mission was saved — unless
  you first clicked the drawing in the Draw panel. Root cause: the ME serializer
  reads a cached `mission.drawings` table, not the live draw panel, and these
  paths updated the live panel (`copyObjToCoord` / `loadFromMission`) without
  refreshing that cache. ED itself only resyncs the cache on draw-panel events
  (objectDelete / onClose), so an automated edit fired none of them. Both the
  placement path (`prefab_ops.place`) and the drawing verbs now commit the live
  draw state back into `mission.drawings` after the edit, mirroring ED's own
  `mission.drawings = saveToMission()`. (`drawing remove` was already correct —
  it goes through `objectDelete`, which ED resyncs.)

### [0.24.0] — 2026-06-11

**Added**
- Save-to folder dialog: clicking **Save** in the Prefab Manager now opens a
  folder picker (modeled on the Move-to dialog) pre-selecting the currently
  highlighted folder, with an inline **New Folder** button — so the save
  destination is always a deliberate choice rather than whatever folder
  happened to be selected.

**Changed**
- Prefab **Rename** and **Delete** moved off the row-3 buttons and onto the
  file-row right-click menu (they now act on the right-clicked prefab, like
  Move/Update). Delete is also available on broken (load-error) rows so you can
  clean them up; Rename is not.

**Fixed**
- The pre-save overwrite check is now scoped to the chosen folder
  (`prefab_ops.exists(name, folder)`); it previously only looked at the prefabs
  root, so a same-name prefab inside a subfolder could be overwritten without
  the Overwrite/Rename/Cancel prompt.

### [0.23.0] — 2026-06-11

**Added**
- Prefab mod dependencies: saving a prefab now records the community mods its
  units/statics require (`meta.required_modules`); placing a prefab warns when a
  required mod isn't installed; the Prefab Manager shows an `M` column and the
  Community browser a "requires mods" line. Prefab format bumped to 0.5.0.

### [0.22.0] — 2026-06-10

**Added**
- **Triggers in prefabs** — new Triggers tab in the Prefab Manager (check
  mission triggers → save to a prefab); normal saves offer to bundle
  triggers that reference the selection; placement imports bundled
  triggers with reference rebinding, embedded media (pictures/sounds/
  script files), a manual-map dialog for unresolved references, and a
  flag-overlap warning. The trigger-list color set in the vanilla Trigger
  panel is preserved through save and re-applied on import. The import
  dialog's trigger checklist now scrolls, so every trigger stays reachable
  no matter how many the prefab carries. Trigger prefabs always save to the
  reserved `Triggers/` folder, which the My Prefabs folder browser marks as
  a special folder (gold tint, same as `Community/`). Prefab format 0.4.0
  (older files load unchanged).

### [0.21.0] — 2026-06-10

**Changed**
- **Resizable description column in the Community tab.** Added the same draggable
  vertical splitter the My Prefabs tab uses, sitting in the gutter between the
  entry list and the detail/description column — drag it left to widen the
  description, right to give the list more room. The width clamps so neither pane
  collapses, and the boundary survives window resizes.

### [0.20.0] — 2026-06-09

**Added**
- **Community prefab library (browse + import).** New **Community** tab in the
  Prefab Manager browses a vetted, GitHub-hosted catalog over HTTPS, with
  search, sort (most-loved / name / newest), tag filters, and one-click
  "Add to my library" (imports land in a `Community/` folder). Community files
  are loaded **parse-don't-execute** through a strict data-only validator
  before they ever touch disk or `dofile`; authenticity comes from the
  cert-verified HTTPS fetch from the catalog repo. Both the catalog fetch and
  the import run non-blocking on the editor tick (the download streams in
  bounded chunks), so the editor stays responsive even on large prefabs; the
  last catalog is cached for offline use. Requires the bundled LuaSec payload in
  `<Saved Games>/DCS/dcs-sms/lib/` for HTTPS (see README) — without it, the tab
  shows the cached catalog and reports that secure networking is unavailable.
- **Author column** in the My Prefabs grid — downloaded community prefabs show
  their original author (blank for your own hand-made prefabs).
- **Always-visible "Prefabs" root** in the folder browser, so prefabs saved
  directly in the prefabs root never appear to vanish behind "Show all".

### [0.19.1] — 2026-06-05

**Changed**
- Renamed the **Hotkeys** tool to **Hotkey Manager** (menu entry, window title,
  and the bindable action), matching the "Prefab Manager" / "Mass Edit" naming.
- Internal: extracted the themed scrollbar skinning (the thin dark vertical bar
  + the ME-Unit-List-matched horizontal bar) into a shared
  `dcs_sms_me/sms_scrollbars.lua` module. The script editor, the Prefab Manager
  folder tree, and the scroll-pane skin now share one implementation. No
  visible change — future tool windows get matching scrollbars from one call.
- Internal: renamed `dtc_skins` → `sms_skins` and its skin-name prefix
  `dtc_*` → `sms_*` (`sms_button`, `sms_grid`, …). The module was never
  DTC-specific — it is the native-editor skin set the tool windows use
  throughout; the old name was a historical artifact. No behaviour change.

**Fixed**
- **ME Hotkeys: creating or editing a user script no longer breaks every hotkey.**
  Saving a script rebuilt the hotkey engine from scratch and re-registered every
  binding on the Mission Editor's toolbar window on top of the previous
  registrations (the old engine held the detach tokens and was discarded), which
  corrupted the shared hotkey surface so *all* hotkeys — built-ins included —
  stopped firing. The facade now reconciles the live engine in place (only the
  changed script's key is touched), and bindings late-bind to the current action
  so editing a script's code takes effect without a re-register.
- `install-me-mod` (and therefore `dev-reload`) now **prunes** files left in the
  installed module directory that are no longer part of the mod, so a file
  renamed or removed between versions (e.g. `dtc_skins.lua` → `sms_skins.lua`)
  no longer lingers in the DCS install. Each removal is reported as
  `removed stale <path>`.
- **ME Hotkeys: capturing a new key no longer also fires an action.** The
  "press a key" overlay left hotkeys live during capture *and* finalized the new
  binding on key-down, so the key you pressed to assign a binding also fired an
  action — either whatever that key was already bound to, or (when rebinding an
  action like Multi Select) the freshly-created binding firing for that very
  keypress. Now all managed hotkeys are suspended for the duration of a capture,
  and the chord is finalized on key-**up**, so the assigning keypress is fully
  consumed before any binding goes live. (ED's own native keys — `a/h/s/u/o`,
  the pan arrows — are outside the mod's control and may still fire if pressed
  mid-capture.)
- The **Hotkey Manager** window (and its script editor) now auto-close on
  **File ▸ New / Open**, like the Prefab Manager and Mass Edit windows. They
  had opted out of the shared `sms_window` close-on-new-mission behaviour.

### [0.19.0] — 2026-06-05

**Added**
- **ME Hotkeys: user scripts.** Write your own Lua snippets, name them, and bind
  each to a hotkey (Maya-style). A new **Scripts** category in the Hotkeys window
  lists them; **`+ New Script`** (or double-clicking a script row) opens an editor
  with a name field, a hotkey capture field, a multiline Lua editor, and a **Run**
  button that compiles + runs the code immediately (result/error shown inline).
  Scripts run in the ME GUI Lua env under `loadstring`+`pcall` (errors are caught
  and logged, never crash the editor) and persist to
  `Saved Games\DCS\dcs-sms\me_scripts.lua`, separate from the built-in key
  overrides. A blank hotkey = unbound (run it from the editor, bind later).

### [0.18.0] — 2026-06-04

**Added**
- **ME Hotkeys tool** — a new **DCS-SMS → Hotkeys** window to bind keyboard
  shortcuts to native Mission-Editor actions (Multi Select, the object-add
  tools, map navigation, panel toggles). An **Action | Binding** table groups
  actions under collapsible category rows: single-click a row to select it,
  double-click to capture a new key, **↩ Reset selected** reverts one row and
  **Reset all** reverts everything. Keyless actions get single-letter defaults;
  the object-add and pan keys keep their native ED bindings. Overrides persist across sessions in
  `Saved Games\DCS\dcs-sms\me_hotkeys.lua`. Uses the `perkey` backend — typing a
  bound letter inside an ME text field types normally (verified live), so it
  never hijacks keyboard input.
  - Every action fires through the editor's own
    `me_toolbar.toolbarCallback(toggleButton…)` / `me_map_window.onChange_…`
    entry points (the same path ED's native a/h/s/u/o hotkeys use), rather than
    poking guessed panel modules.
  - Key combinations (Ctrl/Shift/Alt + key) are supported, both in the capture
    overlay and as defaults.
  - A **DCS-SMS** category for the mod's own tools — Prefab Manager (`Alt+P`),
    Mass Edit (`Alt+E`), Hotkeys (`Alt+K`), About (`Alt+I`).
  - Covers the whole **main-menu bar** too — File / Edit / View / Flight /
    Campaign / Dynamic Mission / Misc categories, firing each entry's menu func.
    New/Open/Save/Fly/Record/DTC/Center/Remove ride ED's existing keys; the rest
    (Save As, Open Backup, Prepare Mission, the static-template load/save, …) get
    modifier-combo defaults. (Exit is intentionally not bindable.)
  - The **Dynamic Mission** entries ship **disabled** (greyed out, no key,
    not bindable) since ED's Dynamic Campaign is still in development — their
    defaults are pre-wired so dropping the `disabled` flag re-enables them.
  - A **search box** filters the list by name, category or bound key
    (`ctrl`, `shift+s`, `pan`, …); an active filter force-expands the
    categories so matches inside collapsed groups still show.

### [0.17.0] — 2026-06-04

**Added**
- Prefab Manager: right-clicking a prefab row now offers **Update Prefab with
  selection**, which overwrites that prefab with the current ME selection
  after a confirm (`This will overwrite "<name>" with your current selection.`).
  It's equivalent to saving under the same name — it respects the *Fixed (place
  at origin)* toggle and any captured airbase data — but skips name entry. The
  entry is hidden on rows with a load error.
- Mass Edit footer now shows **Selected: N** whenever the checked count
  changes (click, shift-range, marquee, Select all / Invert / Clear, scope
  switch). Zero selected blanks the indicator rather than showing
  "Selected: 0". Action messages that carry their own count (apply,
  Fetch from map) still take precedence over the bare count.

**Changed**
- Prefab Manager: the draggable tree/grid divider now runs the full height of
  the folder browser instead of stopping at the Reload / Undo row, giving a
  much larger drag target.

**Fixed**
- Mass Edit airbase marquee no longer freezes the ME for several seconds on
  dense maps (e.g. Germany Cold War). The marquee callback used to call
  `rebuild_treeview`, which tore down and reallocated a checkbox plus a
  cell-per-column for *every* airbase in the pool on each drag-release —
  hundreds of dxgui widgets synchronously. It now flips the affected rows'
  existing checkboxes in place (`setState`), matching the per-click path. Row
  order is name-based and unaffected by checked state, so no re-sort is needed;
  a full rebuild only happens on the cold-start case where no live checkboxes
  exist yet.

### [0.16.0] — 2026-05-31

Closes the remaining gaps from gh #68 (items 1, 3, 4, 5; item 2 shipped in
0.15.1). A parking-started aircraft with fuzed bombs can now be built end to
end from the CLI without hand-editing the `.miz`.

**Added**
- `me unit payload set-fuze --name <X> --pylon <N> --set "<key>=<value>" [...]`
  sets per-pylon weapon settings (fuze type, function delay, presets, …).
  Keys and values are validated against the weapon's own descriptor
  (`me_loadoututils.getLauncherSettings`): `--set` keys match a setting `id`
  or `label` (case-insensitive; ambiguous labels are refused with the
  candidate ids), values match a combo `id`/display name or a numeric spinbox
  value. Starts from the weapon's defaults so the `NFP_PRESID`/`NFP_PRESVER`
  preset metadata and sibling keys are always written. Optional `--weapon`
  arms the pylon first. gh #68 item 1.
- `me unit payload list-settings --name <X> (--pylon <N> | --weapon <CLSID>)`
  dumps a weapon's configurable-settings descriptor — id, label, control
  type, combo values, min/max, read-only flag, visibility conditions, and the
  preset id/version — so callers can discover legal `set-fuze` keys (mirrors
  `me trigger list-predicates`). gh #68 item 1.
- `me group create-plane` / `create-helicopter` / `create-vehicle` /
  `create-ship` accept `--task` to set the group task at create-time instead
  of requiring a follow-up `me group set-task`. gh #68 item 3.

**Changed**
- `me waypoint set-action` now pairs the waypoint type with the action the
  way ED's action combo does: an airfield action (`From Parking Area`,
  `From Parking Area Hot`, `From Ground Area[ Hot]`, `From Runway`, `Landing`,
  `LandingReFuAr`) flips the type to its paired airfield type
  (`TakeOffParking`, …); choosing a non-airfield action while the type is an
  airfield type reverts it to `Turning Point` and clears the airfield linkage
  fields. Plain action/type combinations (formations, ground traversal) are
  left untouched. Previously the type stayed stale, producing an invalid
  parking-start waypoint. gh #68 item 4.
- `me waypoint link-airbase` preserves an explicit parking stand: when the
  waypoint is a parking-start type already linked to the target airbase and
  the lead unit has a stand assigned (via `me unit set-parking`), the verb no
  longer drags the group to the airbase centre and re-selects a stand — it
  re-asserts `airdromeId` and leaves the unit on its stand. Linking to a
  different airbase still reshuffles. The response carries
  `parking_preserved`. gh #68 item 5.

**Internal**
- `dcs-sms doc` now documents sub-verbs: a `cmdInfo` can declare
  `SubCommands`, and the generator renders one flags table per sub-verb
  (so `me unit payload set` / `clear` / `set-fuze` / `list-settings` each
  get their own flags section instead of a single representative table).
  Repeatable `flag.Value` flags now render as type `string (repeatable)`,
  which also fixes the `me trigger create` `--condition` / `--action` rows.

### [0.15.1] — 2026-05-30

**Fixed**
- `me-mod` CLI now emits Lua-syntax string literals for non-printable
  codepoints when shelling commands into the Mission Editor. Go's
  `%q` (via `strconv.Quote`) uses `\uXXXX` escapes that Lua 5.1
  silently drops, corrupting the C1 control range (U+0080..U+009F),
  ZWJ/ZWNJ, BOM, and bidi marks on round-trip — a group rename that
  fed in `U+008F` came back with literal `u008F` baked into the
  mission. New `luaQuote()` helper escapes only the necessary bytes
  (`\`, `"`, ASCII control 0x00-0x1F + 0x7F) using Lua's `\ddd`
  decimal form; bytes 0x80-0xFF pass through verbatim so UTF-8
  sequences (CJK, emoji, accented Latin, Cyrillic) survive intact.
  Sweep-rewrote 208 `fmt.Sprintf`/`Fprintf` call sites across 118
  `me_*.go` verb files (`fmt.Errorf`, stderr writes, and tests left
  alone). Closes #70.
- `me file save` and `me file save-as` now surface DCS's per-group
  validation errors instead of the useless generic `save failed
  (mission validation or I/O); enable showError to see details`
  message. DCS's `check_mission` builds the per-group error string
  in a chunk-local `showErrorMessageBox` closure that can't be
  intercepted from outside the `me_mission` chunk (the bare-name
  call resolves through upvalues and `debug.setupvalue` is sandboxed
  in the ME env). New `_verify_mission` helper re-implements the
  loop using the globally-accessible `panel_route.verify` and
  `panel_aircraft.verify` (the latter only for Player/Client skill
  strings, matching `check_mission`). E.g. a route with no
  locked-time waypoints now returns `save failed (mission validation):
  26JG:\nRoute has no waypoints with locked time!` instead of the
  generic message. Closes part of #68.

### [0.15.0] — 2026-05-28

**Added**
- `me waypoint add-task`, `remove-task`, `clear-tasks` and the enroute
  trio (`add-enroute-task`, `remove-enroute-task`, `clear-enroute-tasks`)
  for managing per-waypoint ComboTask payloads from the CLI (gh #69).
- `me waypoint list-tasks` and `me waypoint describe-task` to introspect
  legal task ids and their parameter schemas from ED's `me_action_db`.
- `me group focus --name <X>` (or `--id <N>`) — raises the AIRPLANE /
  HELICOPTER GROUP panel and the route panel for a programmatically
  created group, mirroring what ED's `MapWindow` click handler does
  when the user clicks a group on the F10 map. No-op (returns
  `focused=false`) for vehicle / ship / static groups.
- `me waypoint describe-task` now returns a `variants` field for
  pattern-conditional tasks (currently Orbit, where `pattern` controls
  which of `altitude` / `speed` / `point` / `point2` are meaningful).
  Backed by a new `tools/me-mod/lua/dcs_sms_me/task_extras.lua`
  supplementary descriptor file that holds the variant data
  `actionsData` doesn't carry — hand-curated against ED's runtime.
- `me waypoint add-task` / `add-enroute-task` k=v field args now
  coerce to typed Lua values: numeric strings become numbers, `"true"`
  / `"false"` become booleans. Descriptor type (from `actionsData` /
  `task_extras`) wins when known; heuristic fallback (clean number
  parse, literal `"true"`/`"false"`) covers descriptor-less fields.
  Without coercion ED silently substitutes defaults at run time for
  string-typed numeric fields.

**Changed**
- `me waypoint list-tasks` re-accepts `--group-name` / `--group-id` and
  filters returned task ids to those legal per
  `me_action_db.availableActions[group_type][<kind>][group_task]`. The
  initial /write-it pass dropped this on the (incorrect) assumption
  that no static index existed; a follow-up probe found
  `availableActions` is exactly that index. `--all` continues to dump
  the full unfiltered matrix.
- Task entries copy `task.key` when the descriptor carries one — this
  covers the CAS / CAP / SEAD / FighterSweep / AntiShip variants of
  `EngageTargets`, which share an action id but differ by `key`.
  Without copying `key`, ED silently filters the entry from the
  group's task listbox.

**Fixed**
- `me waypoint add-task` / `add-enroute-task` now gate against
  `me_action_db.availableActions[group_type][<kind>][group_task]` and
  refuse `--task <id>` if the id isn't legal for the group's main
  task. The error names the offending combo and points the caller at
  `me waypoint list-tasks --group-name <X>` for the legal set. The
  initial /write-it pass left this gate open and relied on ED to
  reject at save / run time — which it does silently for some
  combinations, so the bad assignment looked successful from the CLI.

**Internal**
- New `H.new_combo_task()` helper in `verb_helpers.lua`. Collapses
  9 sites of the `{ id = 'ComboTask', params = { tasks = {} } }`
  literal across `verbs/group_verbs.lua` (5 create-* paths) and
  `verbs/route_verbs.lua` (4 waypoint paths). Future schema changes
  to the ComboTask block land in one place.
- TODO marker next to `H.new_combo_task()` flagging a future
  consolidation: `_coerce_field_value` (route_verbs) and
  `_trigger_coerce_value` (trigger_verbs) share the same
  `'true'/'false'/tonumber/fallback` ladder and could become a
  shared `H.coerce_scalar(v, descr_default)` next time either site
  is changed.

### [0.14.3] — 2026-05-26

**Fixed**
- `me group create-{plane,helicopter,vehicle,ship,static}` and `me group add-unit` now reject unknown unit types up front instead of producing a group that crashes File→Save. Root cause: DCS's `me_mission.lua:setRequiredModules` derefs `unitDef._origin` without nil-checking, so any type string that isn't in `me_db.unit_by_type` (typos like `M2A2 Bradley` instead of `M-2 Bradley`, or `HMMWV M1043 HMG Armament` instead of `M1043 HMMWV Armament`) freezes the ME on the "Saving..." dialog with no way to recover the unsaved mission. The verbs previously accepted any non-empty string and trusted DCS to validate at spawn time — DCS doesn't validate until save. The rejection error names the bad type and points at `framework/constants/units.lua` as the canonical list to check spelling against. `group_add_unit` validates only when `--type` is passed explicitly; inheriting the last unit's type skips the check, since validating an already-existing type can't fix it.

### [0.14.2] — 2026-05-23

**Fixed**
- `dcs-sms dev-reload`'s install step now execs the **freshly-built** binary as a child process instead of calling `install-me-mod` in-process. The dev-reload process was started from the *previous* build's binary and still holds that build's `embed.FS` in memory, so the in-process install was silently copying the old embedded Lua tree to disk — every Lua change required two consecutive `dev-reload` runs (or a manual rebuild + install) before it actually landed. The child process gets the fresh embed; one `dev-reload` is now enough. A defensive `os.Stat` guard fails fast with the missing path if `go build` somehow didn't produce the expected binary, rather than silently falling back to a different `dcs-sms` on `$PATH`.

### [0.14.1] — 2026-05-23

**Fixed**
- `dcs-sms dev-reload` no longer stacks ghost bridge instances. The hot-reload step clears `package.loaded.dcs_sms_me.bridge` and re-dofiles `init.lua`, but the previous bridge's tick callback stays registered with `UpdateManager` (no public unregister API across DCS builds). Without a guard, you ended up with N+1 ticks racing on the same inbox / heartbeat files after N reloads — symptom was `dcs-sms status` reporting a stale `hook_version` (older bridge's heartbeat wins the write race) plus occasional spurious "gui bridge is disabled" errors on requests a stale tick happened to pick up. `bridge.install()` now bumps a `_G.DCS_SMS_BRIDGE_GEN` counter and stamps it into the new tick's closure; older ticks check the global on every call and silently return early when they're no longer the active generation, so there's a single source of truth for heartbeat + inbox processing across any number of dev-reloads. The install log line now includes `gen <N>` so it's visible in `dcs.log` how many reloads have stacked since DCS startup.

### [0.14.0] — 2026-05-23

**Added**
- `lat` and `lon` are now included alongside `north` / `east` in the responses from `me unit list`, `me unit get`, `me group list`, `me group get`, `me zone list`, and `me zone get`. The fields are populated best-effort via the same `Terrain.convertMetersToLatLon` call that `me coords to-geo` uses; if the helper can't reach Terrain (no theatre loaded, called from a non-mission ME state) the fields are omitted instead of failing the whole response. Quad-zone vertices each get their own `lat`/`lon` too, so iterating a zone's corners no longer needs a per-vertex `me coords to-geo` round-trip. Closes [#66](https://github.com/nielsvaes/dcs-sms/issues/66) (request 4).

  Pure additive change to existing JSON responses — callers that don't read `lat`/`lon` are unaffected.

### [0.13.0] — 2026-05-23

**Added**
- New `coords` noun with two verbs that convert between DCS theatre-local meters and geographic lat/lon for the open mission's theatre:
  - `dcs-sms me coords to-geo --north N --east E [--alt A]` — returns `{ lat, lon, north, east[, alt] }`.
  - `dcs-sms me coords to-local --lat L --lon Lo [--alt A]` — returns `{ north, east, lat, lon[, alt] }`.

  Both wrap the ME-side `Terrain.convertMetersToLatLon` / `Terrain.convertLatLonToMeters` calls already used internally by `camera_focus`, `airbase_list`, `airbase_get`. The mission-env `coord.LOtoLL` (which is what most documentation references) isn't available in the GUI exec context — these verbs surface the right ME-side API so callers don't have to discover that. `--alt` is conversion-free and passed through unchanged in either direction, so a single call can produce a complete coord record. Closes [#66](https://github.com/nielsvaes/dcs-sms/issues/66) (request 3).

### [0.12.0] — 2026-05-23

**Added**
- `dcs-sms me unit get` accepts two new selectors: `--group-name <name>` and `--group-id <n>`, each returning the first unit (`units[1]`) of the matched group. Callers that hold a group reference (e.g. from `me group list`) no longer need a round-trip through `me unit list --group <n>` to discover a unit id before they can call `unit get`. The four selectors (`--name`, `--id`, `--group-name`, `--group-id`) are mutually exclusive; passing zero or more than one exits 2 with a usage message. Closes [#66](https://github.com/nielsvaes/dcs-sms/issues/66) (request 5).

### [0.11.2] — 2026-05-23

**Fixed**
- `me group get` / `me unit get` no longer time out on units that own a beacon-style zone. ME-side beacon units carry a `unit.zones[1].userObject` back-reference that points at the unit (and `userObject.zones[1]` back at the zone), forming a direct cycle. The previous `H.strip_back_refs` only excluded `boss` and `mapObjects`; its depth-32 fallback returned the live cyclic table into the clone, so the bridge's JSON encoder walked into the cycle and the request hit the CLI's 30 s timeout. `strip_back_refs` now also drops `userObject` and tracks the current ancestor chain via a visited-set, so cycles are broken regardless of which key creates them. Regression tests in `test_verbs_group.lua` / `test_verbs_unit.lua` reconstruct the cycle and assert `_get` returns cleanly. Closes [#66](https://github.com/nielsvaes/dcs-sms/issues/66) (bug #1).

### [0.11.1] — 2026-05-23

Internal-only release. No user-facing behavior changes; the bump exists so the in-source `version.lua` reflects the test + refactor groundwork that's landed since `0.11.0`.

**Internal**
- `tools/me-mod/lua/dcs_sms_me/verbs.lua` (~6950 lines, ~80 verbs) split into one file per noun group under `dcs_sms_me/verbs/<noun>_verbs.lua`, with shared cross-noun helpers in `dcs_sms_me/verb_helpers.lua`. `verbs.lua` itself collapsed to a 49-line aggregator with a duplicate-key guard. `unit_set_parking` lives in `route_verbs.lua` (depends on route-block locals) but is still surfaced as a unit verb by the aggregator. Closes [#54](https://github.com/nielsvaes/dcs-sms/issues/54).
- 1015 new Lua unit-test assertions across 9 noun-group test files (group, unit, zone, drawing, trigger, airbase, resources, camera, file). `mock_me_mission.lua` extended with the in-process `me_mission` API surface used by inject-group, payload, zone TZD, drawing-panel, trigger-rules, and airbase-warehouse plumbing. Closes [#55](https://github.com/nielsvaes/dcs-sms/issues/55).

### [0.11.0] — 2026-05-22

**Added**
- New `dcs-sms dev-reload` subcommand (CLI only, not in the interactive menu): contributor convenience verb that chains `go build ./cmd/dcs-sms` + `install-me-mod` + `reload-me-mod` into one command. Run from anywhere inside the dcs-sms checkout. Replaces the three-command manual iteration recipe in `tools/me-mod/AGENTS.md` §2.3. Closes [#63](https://github.com/nielsvaes/dcs-sms/issues/63).

**Fixed**
- Flaky exec tests on Windows that intermittently failed with `ERROR_SHARING_VIOLATION` when a reader opened a file that a writer was atomically renaming. New `tools/internal/fileutil.ReadFileRetry` retries reads up to 4 times (2/4/8 ms backoff) on the sharing-violation errno; plumbed into `hookstatus.readOne` (state/hook.json + state/me.json) and `mailbox.ReadResponse` (outbox/*.res.json). Failure rate measured: ~40% → ~0% across 115 test runs.

### [0.10.0] — 2026-05-18

Closes part of [#60](https://github.com/nielsvaes/dcs-sms/issues/60) — gaps found in AI-assisted mission scripting. Six existing verbs get filters / batch / file-input ergonomics; one new verb lands. Gaps 1, 8, 10 (waypoint_get red-side bug, route-overlay composite, polygon-union) remain open for a follow-up session.

**Added**
- **`me drawing create-chevron`** — new verb. V-shape / directional tick mark at `--north/--east` pointing in `--bearing` direction, arms of length `--size`, opening configurable via `--arm-angle` (default 100° — matches Mav's flight-plan tick style; 150° gives a tight arrowhead). Replaces hand-rolled trig in calling scripts. Closes Mav's gap 9.
- **`me drawing list --name-prefix <P>`** — anchored prefix match alongside the existing case-insensitive `--name` substring. One targeted call instead of list + filter in the caller. Mav's gap 2.
- **`me drawing remove --name-prefix <P>` / `--layer <L>` / `--all`** — batch delete by name prefix, optional layer scope, or full-layer wipe (`--all` guard required). Returns `{removed=[...], count=N}`. Single `--name` form unchanged. Mav's gap 3.
- **`me drawing create-polygon --vertices-file <path>`** and **`me drawing create-line --vertices-file <path>`** — read one `north,east` per line (blanks and `#` comments ignored, CRLF tolerant). Sidesteps the Windows `CreateProcess` ~32 KB arg-length limit for Shapely-sized polygons. Mutually exclusive with `--vertices`. Mav's gap 5.
- **`me drawing get` returns `points_absolute`** — sibling to the existing anchor-relative `points[]`, summed with `mapX/mapY` so callers don't have to redo the math when round-tripping geometry. Emitted only when the drawing has a `points` array. Mav's gap 4.
- **`me unit list --type` accepts a comma-separated any-of list** — e.g. `--type flak18,flak36,bofors40`. Single-value form unchanged. Mav's gap 7.
- **Color flags accept `0x`-prefixed hex** on every drawing `--color` / `--fill-color` — `0x000000aa` round-trips cleanly from `drawing get` output. `#rrggbb` / `#rrggbbaa` / named colors still work. Mav's gap 6.

### [0.9.0] — 2026-05-18

**Added**
- New `dcs-sms setup` subcommand: orchestrates the .exe update + ME mod install + hook install in one shot. After a binary swap the new dcs-sms.exe re-execs itself with `--skip-update` so the freshly-embedded Lua tree is what reaches DCS.
- New `dcs-sms teardown` subcommand: removes the ME mod and the hook in one shot.
- New `dcs-sms uninstall-hook` subcommand: peer to `install-hook`; removes `Scripts/Hooks/dcs-sms-hook.lua` and (when `--dcs-path` is known) reverts the `MissionScripting.lua` patch.
- New `dcs-sms reload-me-mod` subcommand (CLI only, not in the interactive menu): hot-reloads the installed ME mod via the gui bridge. Closes [#59](https://github.com/nielsvaes/dcs-sms/issues/59).
- Interactive menu detects when DCS lives under `Program Files` (or any other admin-only path) and prompts the user to re-launch with admin permission via Windows UAC.
- **`MissionScripting.lua` auto-patch.** `install-hook --dcs-path <PATH>` (and `setup`, which forwards the path automatically) comments out `sanitizeModule('os'|'io'|'lfs')` so the in-mission hook can talk to the bridge. Idempotent across DCS game updates (DCS rewrites the file → next `setup` re-patches). `uninstall-hook` reverts the lines it owns via a `-- dcs-sms` trailing tag; commented-by-hand lines and other tools' edits are left alone.

**Changed**
- Interactive menu collapses to five flat options: install-or-update / uninstall / install-AI-skill / uninstall-AI-skill / set-DCS-path. The previous AI-agent picker submenu (Claude / Codex / Gemini / All) is gone — entries 3 and 4 always install or uninstall the skill for all three agents. Option 1 now carries a "Not sure what to pick? Pick this." sub-line.
- `runUpdate` refuses to swap when the running binary's version ends in `-dev`. Prevents the dev workflow from downgrading the local build to the latest release when testing in-flight subcommands.
- New exit code `5` reserved for "operation needs admin privileges" (see [`tools/cmd/dcs-sms/AGENTS.md`](tools/cmd/dcs-sms/AGENTS.md#4-exit-codes-conventional)).

### [0.8.1] — 2026-05-17

**Fixed**
- Renaming a prefab from a subfolder placed the renamed file at the `prefabs/` root instead of keeping it in its original subfolder. The collision check was also rooted, producing wrong false positives (a same-named prefab at root blocked a safe subfolder rename) and false negatives (a same-named prefab already in the destination subfolder was missed). `rename_file` now lives in `prefab_ops` alongside `move_prefab` / `rename_folder`, derives the destination by basename swap on `old_path`, and checks collisions at the actual destination (plus the legacy `.lua` sibling).

### [0.8.0] — 2026-05-13

**Added**
- **Prefab Manager folder browser.** Real filesystem subfolders under `<SavedGames>\DCS\dcs-sms\prefabs\`. Two-pane layout — folder tree on the left (with its own search), prefab list on the right. New Folder button below the tree; right-click on a tree node → New subfolder / Rename / Delete. Saves write to the currently selected folder. Filter on the right is scoped to the selected folder (or recursive when nothing is selected).
- **Right-click context menu on prefab rows (closes [#50](https://github.com/nielsvaes/dcs-sms/issues/50)).** Move to… · Copy file contents · Copy place snippet · Show in Explorer. Error rows expose only Show in Explorer.

**Changed**
- `prefab_ops.scan_dir` now recurses; rows carry a new `folder` field.
- `prefab_ops.save_selection` gains an optional `folder` argument (default `""`).
- `paths.lua` gains `folder_to_abs` and `ensure_prefab_folder` helpers — the single seam between in-memory `/` and on-disk `\`.
- Prefab Manager minimum window size bumps from 540 × 460 → 760 × 460 to accommodate the tree pane.
- "Search:" label renamed to "Search files:".

**Internal**
- New `context_menu.lua` module with lazy clipboard probe (`Gui.setClipboard` → `dxgui.setClipboard` → `Input.setClipboard` → `clip` last resort).
- New `prefab_ops.move_prefab`, `prefab_ops.rename_folder`, `prefab_ops.delete_folder`, `prefab_ops.count_folder_contents`.
- Path-traversal validator `prefab_ops._validate_folder_path` rejects `.`, `..`, backslash, reserved characters.

### [0.7.3] — 2026-05-13

**Fixed**
- Placed prefabs were partially un-pickable by the ME's marquee multi-select tool: a subset of statics (~10% on real prefabs) rendered correctly on the F10 map but the drag walked right over them, and clicking elsewhere on the same prefab selected the wrong group. Root cause was inside `prefab_ops._remap_ids`: the idempotency guard short-circuited every value that happened to also be a freshly-allocated destination id, which is the rule (not the exception) when placing into a fresh mission — `Mission.getNewUnitId` starts at 1 and source-mission unit ids do too. Skipped units kept their source unitId, while other units in the same prefab were correctly remapped to that same value, collapsing two distinct units onto one entry in `Mission.unit_by_id`. Whichever was injected last won the registry slot; the other became a "ghost" group — present in `Mission.group_by_id`, drawn on the map, but invisible to `me_multiSelection`'s rect hit-test (which iterates `Mission.unit_by_id`). The guard now distinguishes source-side keys from already-allocated destination values via two separate sets, so source ids that happen to coincide with dest values still get rewritten while genuinely already-fresh values on a re-walk are preserved. Closes [#57](https://github.com/nielsvaes/dcs-sms/issues/57).

### [0.7.2] — 2026-05-12

Major release. Folds the entire `feat/me-execution-bridge` body of work (in-flight as 0.7.0 and 0.7.1) into this tag, plus the prefab Search-Then-Engage fix.

**Added**

ME execution bridge:
- `bridge.lua` — an inbox poller running in the ME's Lua state, driven by `UpdateManager.add`. Handles `target=gui` execution requests from the `dcs-sms.exe` CLI: runs the user's Lua snippet directly via `loadstring + xpcall`, captures `print` output, returns results through the standard file-mailbox protocol. Writes its own heartbeat to `<SavedGames>/DCS/dcs-sms/state/me.json`.
- "External execution: ON/OFF" item under the DCS-SMS top menu. Flipping it on enables the bridge's `target=gui` path so external tools (the `dcs-sms exec --target gui` CLI, Claude, etc.) can run Lua against the editable mission table from outside DCS. Default off at every DCS launch (session-only; no persistence).

`me <noun> <verb>` namespace:
- `me trigger reorder` — move a trigger to a new position in `mission.trigrules` (by name).
- `me trigger reorder-condition` — move a condition to a new position in a trigger's `rules` list.
- `me trigger reorder-action` — move an action to a new position in a trigger's `actions` list.
- `me trigger add-condition --predicate or` — pseudo-predicate that connects two surrounding conditions with logical OR. Discoverable via `me trigger list-predicates` / `describe-predicate or`.
- `me camera focus { --name N | --lat L --lon L | --x X --y Y } [--scale S]` — pan the ME map to a point, optionally setting zoom (meters per screen unit). `--name` resolves against `Mission.AirdromeController.getAirdromes()` (case-insensitive, exact match preferred, substring fallback).
- `me camera get` — return the current map center as `{ x, y, lat, lon, scale }`.
- `me airbase list [--coalition all|red|blue|neutrals]` — list every airbase on the current theatre.
- `me airbase get --name N [--filter plane|helicopter]` — full info for one airbase: position, coalition, frequencies, parking stands, runways, warehouse / fueldepot counts.
- `me airbase set-coalition --name N --coalition red|blue|neutral` — change an airbase's coalition. Updates the warehouse entry AND pushes through `AirdromeController.setAirdromeCoalition` so the live map display refreshes.
- `me resources get { --airbase N | --unit ID }` — read a warehouse / resources entry. Airbase mode reads `mission.AirportsEquipment.airports[airdrome_number]`; unit mode reads `mission.AirportsEquipment.warehouses[unitId]`.
- `me resources set { --airbase N | --unit ID } [mods]` — atomic warehouse mutation. Mods (any combination): `--clear` / `--unlimited`, per-category `--clear-aircrafts` / `--clear-fuel` / `--clear-munitions` and `--unlimited-*`, `--operating-level-air` / `--operating-level-fuel` / `--operating-level-eqp` (0..100 percent), repeatable `--fuel TYPE=N`, `--aircraft "DISPLAY NAME"=N`, `--weapon "FRAGMENT"=N` (substring via the new `dcs_sms_me/weapons_db` index, or full CLSID in `{...}` form). Atomic: validates all mods before mutating; ambiguous weapon fragment fails the whole call.
- `me route list` — compact per-waypoint summary for a group's route.
- `me route get` — full route table including each waypoint's complete field set; per-waypoint `task` subtree preserved verbatim.
- `me route clear` — strip all waypoints from a group's route (refused for plane / helicopter groups).
- `me waypoint add` — append a waypoint with `--north / --east` required; optional `--alt / --alt-type / --speed / --type / --action / --name / --eta / --speed-locked / --eta-locked / --formation-template`. Unset fields inherit from the previous waypoint.
- `me waypoint insert` — insert at index `--before N`.
- `me waypoint remove` — delete the waypoint at `--index N`; refused for air groups if it would leave 0 waypoints.
- `me waypoint get` — full field set of a single waypoint.
- `me waypoint set-pos / set-alt / set-speed / set-type / set-action / set-name / set-eta / set-speed-locked / set-eta-locked / set-formation` — per-field setters.

Host-side tooling:
- `dcs-sms screenshot [--out PATH] [--title SUBSTR]` — capture the running DCS window to a PNG via `PrintWindow + PW_RENDERFULLCONTENT`. Works in windowed, borderless windowed, and (verified) true exclusive fullscreen. Windows-only.
- `dcs-sms install-ai-skill --agent=claude|codex|gemini|all` and matching `uninstall-ai-skill`. Drops a short `SKILL.md` (and a Gemini slash-command TOML) into the user's AI agent config dir so Claude Code, Codex CLI, and Gemini CLI all know `dcs-sms.exe` is on PATH. After install, `/dcs-sms` works as a slash command on Claude and Gemini; on Codex use `$dcs-sms` or `/skills`. Interactive menu option 5 wires up the same install/uninstall flow.
- `dcs_sms_me/weapons_db.lua` — new internal module; lazy index of ED's `DB.weapon_by_CLSID` keyed by lowercase displayName + CLSID. Used by `me resources set` for `--weapon` resolution.

**Fixed**
- Prefabs with a Search Then Engage In Zone (or any other zone-bearing enroute task) placed two zone widgets per task, and dragging the triangle moved the parent waypoint instead of the zone (GH#56). The bug had two render-side caches feeding into it — `group.mapObjects` (the group-level widget cache) and `wpt.targets` (the per-waypoint mark cache for zone tasks). `prefab_distill` now strips both during save (mirroring how it already strips `boss` back-refs), and `inject_group` resets both unconditionally on placement so prefabs that pre-date this fix sanitise on the way in. After placement, the ME's own `me_action_map_objects.onTaskShow` is replayed for every sub-task so zone widgets appear immediately and the per-task `elements[task].mark` linkage is in place — meaning a later double-click in the actions panel moves the existing widget instead of inserting a second one.
- `dcs_sms_me/warehouse_ops.lua` — coalition-string mapping in `apply()` was keyed on `BLUE`/`RED`/`NEUTRAL` (uppercase singular), but ED emits lowercase strings (`blue`/`red`/`neutrals`) via `CoalitionController.*CoalitionName()`. The lookup never matched, so the AirdromeController push silently no-op'd: the warehouse table updated, but the live map display only refreshed after save + reopen. Now keyed on the canonical lowercase strings; map redraws immediately.
- Trigger ref fields (unit / vehicle / aircarrier / drawObject combos) now resolve names to numeric ids before storage. Previously, `me trigger add-condition --predicate unit-altitude-lower unit=b1-1 ...` stored `entry.unit = "b1-1"` (a string), which the ME panel's combo couldn't match — and a subsequent panel interaction would nil the field via the bound `onChange` callback. Closes [#45](https://github.com/nielsvaes/dcs-sms/issues/45).

Notes:
- All three trigger reorder verbs accept the same five mutually-exclusive position flags: `--to-index N`, `--before X`, `--after X`, `--to-start`, `--to-end`. For `me trigger reorder`, `X` is a trigger name; for `reorder-condition` / `reorder-action`, `X` is a 1-based index into the parent trigger's list. Self-targeting is an idempotent no-op (`moved: false`), not an error.
- Route-geometry verbs total 18. Indices are 0-based on the wire to match what the ME UI displays as "Waypoint 0, 1, 2 …"; Lua internals work in their native 1-based world. Speeds are in meters/sec (DCS native). Per-waypoint `task` fields are never mutated by these verbs — task assignment is the next sub-project.

### 0.6.0 — 2026-05-09

**Added**
- **Interactive menu** for `dcs-sms.exe`. Double-clicking the binary (or
  running it with no arguments from a real terminal) now opens a numbered
  menu with Install / Uninstall / Update options, plus an option to set
  a custom DCS install path. Pasted paths are sanitized — surrounding
  ASCII / smart quotes are stripped so `"D:\Program Files\…"` works
  without manual editing. All existing CLI invocations
  (`dcs-sms.exe install-me-mod`, etc.) are unchanged; the menu only
  triggers when `stdin` is a TTY.
- **`dcspath.SanitizeUserPath`** helper for any future callers that
  accept paths from user input.

Spec: `docs/superpowers/specs/2026-05-09-dcs-sms-interactive-menu-design.md`.

### 0.5.0 — 2026-05-08

> **Note:** This release is an internal refactor. No user-facing behavior
> changes — the Prefab Manager looks and works the same as 0.4.2. The
> changes below are scaffolding for future tool windows (Group Tools,
> etc.) so they can share consistent chrome instead of each re-implementing
> the title bar / footer / hotkeys / resize handling.

- **`sms_window` factory** introduced for ME-mod tool windows
  (`tools/me-mod/lua/dcs_sms_me/sms_window.lua`). Owns the title-bar
  branding, footer separator + colored status Static, close-on-File>New
  hook, Ctrl+Z hotkey, and the resize-clamp + footer-reposition
  plumbing that every tool window needs. Lightweight handle / factory
  pattern (composition only, no inheritance) — see the spec's
  Decisions section for the rationale.
- **Prefab Manager refactored** onto `SMSWindow` via composition. File
  renamed `window.lua` → `prefab_manager.lua` (blame preserved via
  `git mv`). Net diff in the file: ~80 lines removed (duplicated
  chrome plumbing), ~30 lines added (SMSWindow.new opts + status shim).
- **Status bar gains `flash_status`** semantics. `set_status` is now
  sticky; `flash_status(text, severity, [timeout])` overlays for N
  seconds (default 5) then auto-reverts to the sticky baseline.
- **Severity vocabulary unified.** Standard set: `info` (gray),
  `success` (green), `warning` (yellow), `error` (red). The Prefab
  Manager's previous `'placement'` severity is mapped to `success`.
- Group Tools migration onto `SMSWindow` is **deferred** until the
  Group Tools branch (`worktree-me-mod-group-tools-bulk-rename`)
  ships or is reconciled.

Spec: `docs/superpowers/specs/2026-05-08-me-sms-window-base-class.md`.

### [0.4.2] — 2026-05-07

**Changed**
- Prefab files are saved with a `.prefab` extension instead of `.lua`. Existing `.lua` files in your prefabs directory are silently renamed to `.prefab` the first time the Prefab Manager scans the directory; the file content is unchanged. Both extensions remain readable indefinitely.

### [0.4.1] — 2026-05-07

Adds an OVGME-friendly install path for users whose browser blocks `dcs-sms.exe` as "unsigned" (Edge SmartScreen / Windows Defender). No runtime mod changes — packaging only.

**Added**
- The `Release ME-mod` GitHub Actions workflow now also builds and uploads `dcs-sms-me-mod-vX.Y.Z.zip` alongside the existing `dcs-sms.exe`. The zip contains the OVGME-shaped `dcs-sms-me-mod/MissionEditor/modules/dcs_sms_me/` mod tree plus a `README.md` walking the user through the install. Because the mod needs one line appended to `MissionEditor.lua` and OVGME can't surgically edit files, the README instructs the user to do that one-line edit by hand on their own copy. We deliberately do *not* ship a pre-patched `MissionEditor.lua` — DCS EULA §3.1(a) prohibits redistributing modified ED files; users editing their own copy on their own machine is permitted.
- Release notes now include an "Alternative install (OVGME / no .exe)" section pointing at the zip and summarising the four install steps.

The `dcs-sms.exe install-me-mod` path remains the recommended install — it patches `MissionEditor.lua` automatically and supports `update` / `uninstall` subcommands. The OVGME zip is the fallback for users who can't run unsigned binaries.

### [0.4.0] — 2026-05-07

Three Prefab Manager fixes / UX improvements driven by [#37](https://github.com/nielsvaes/dcs-sms/issues/37) and follow-up testing feedback.

**Fixed**
- `Place at original location` now preserves the source unit's `parking` / `parking_id` / `parking_landing` / `parking_landing_id` instead of stripping them. The on-disk prefab format already carried these fields; the place pipeline was unconditionally nilling them — mirroring vanilla ME's `me_copy_paste.lua:331-334` strip — but skipping vanilla's compensating call to `panel_route.attractToAirfield(wpt, group)` (`me_copy_paste.lua:393-398`). Result was a unit with the right `(x, y)` for the editor display but no parking binding for DCS at mission start, so DCS picked the nearest free slot at runtime instead of the one the user originally chose.
- Placements at a non-original anchor now run a "Pass F" that mirrors vanilla ME's airfield re-attraction: for every placed group's airfield-type waypoints (`TakeOffParking` / `TakeOff` / `Landing` / `LandingReFuAr`) without a live `linkUnit`, `panel_route.attractToAirfield(wpt, group)` is called to assign a free parking/runway slot at the destination airfield. Carrier-deck takeoffs are detected by their live `linkUnit` and left to Pass E's `linkWaypoint` dance — Pass F skips them so the unlink/relink dance isn't clobbered.
- Pass F also fires when a placed group has any unit with `parking_id == nil`, even at the original anchor. This handles prefabs distilled from pre-mid-2024 source missions: ED started writing `parking_id` on parked aircraft around then, and ME doesn't migrate the field at load time — only at save time. A 2024 `.miz` opened in current ME and turned into a prefab without an intervening File → Save inherits the un-migrated shape, so Prong 1 has nothing to preserve and the place pipeline must run `attractToAirfield` to assign a spot at the unit's saved `(x, y)`. The fast user-side workaround remains "open the source mission in current DCS, save, re-make the prefab" — that bakes `parking_id` into the prefab data and lets Prong 1 preserve the exact original spot rather than relying on attract's nearest-free-spot heuristic.
- Trigger zone color is now preserved through the prefab round-trip. ME's `TriggerZone` class stores color as four separate fields (`red` / `green` / `blue` / `alpha` — `Mission/TriggerZone.lua:38`) but the `.miz` save format and `addTriggerZone` API expect a single `color = {r, g, b, a}` table (`Mission/TriggerZoneData.lua:559`). `selection.lua` captures the live zone object, `prefab_distill` walks it via `pairs()`, so the four separate fields landed in the prefab but `inject_zone` reads `zone.color` and got `nil`. Distill now synthesizes the `color` table during normalisation; `inject_zone` carries a backward-compat fallback that synthesises from `red/green/blue/alpha` for prefabs saved by ME-mod ≤ v0.3.2.

**Added**
- New `<keep prefab countries>` entry in the country dropdown, selected by default. When this entry is active, place uses each unit's stored country verbatim — supporting mixed-coalition prefabs (e.g. an airbase package with US, UK, and CJTF Blue units in one save) without forcing the user to leave the dropdown blank. Picking any other dropdown entry continues to override every unit to that country, matching the old behavior.

### [0.3.2] — 2026-05-06

Two small UX fixes for the Prefab Manager.

**Changed**
- The Reload button now also re-populates the country dropdown. Users who change coalition assignments mid-session in `Customize → Coalitions` can pick up the change without closing and reopening the window. Status bar message updated to "Library and countries reloaded."
- The Prefab Manager now auto-closes when the current mission is torn down — `File → New` or `File → Open` — matching the behavior of the ME's own panels (`coords_info`, `flightPlans`, `multiTemplate`, `managerDTC`). Wraps `me_toolbar.newMission` and `me_toolbar.loadMission` via a small `new_mission_hook` module that mirrors `marquee_hook`'s reload-safe subscriber pattern.

### [0.3.1] — 2026-05-06

Fixes a placement bug where intra-prefab unit/group references were destroyed: statics linked to a carrier no longer followed the AC after spawn, aircraft set to start on a carrier deck spawned at world coordinates instead, and the carrier's own TACAN / ICLS / Link 4 task params, Link 16 datalinks, and Escort / EPLRS task references all kept the source-mission ids and broke at runtime.

**Fixed**
- `Place` now does a four-pass injection (allocate → remap → inject → relink). A prefab-wide old→new id map is built across every group BEFORE any insertion, then every known id-bearing field (`linkUnit.unitId`, `helipadId`, `missionUnitId`, ActivateBeacon / ActivateICLS / ActivateLink4 `unitId`, Escort / EPLRS `groupId`) is rewritten via the map. Ids that don't resolve in-prefab are nilled (matches the pre-fix safety for cross-mission references). `airdromeId` is preserved when placing at the original anchor (`Place at original location`) and nilled otherwise (would otherwise bind aircraft to a far-away airbase at click-anchor placements).
- After insertion, every linked waypoint has its runtime link re-established via `Mission.linkWaypoint` — same dance `me_copy_paste.duplicateGroup` does. This populates the host unit's `linkChildren` list, which is what the ME's delete-cascade walks. Without this step, the data on disk was correct but the runtime didn't know about the link: moving the host unit didn't move its dependents until the mission was saved (forcing a re-parse), and deleting the host left orphans that broke `File > New`. `helipadId` / `airdromeId` are stashed around the relink because `unlinkWaypoint` clears them as a side effect.
- `unit.linkChildren` and `unit.linkChildrenTZone` are now cleared on every placed unit before relinking. The source mission may have populated them with live runtime waypoint references; distill strips the `boss` back-refs, so the entries survive into the placed unit half-dead. ME's drag handler walks the list and nil-indexes on `wpt.boss`, breaking ME state to the point where `File > New` errors out. Mirrors `me_copy_paste.duplicateGroup` lines 337–338.

### [0.3.0] — 2026-05-06

The mod's chrome now identifies the project. New About dialog with the Coconut Cockpit logo, plus a branded window title.

**Added**
- `Tools → DCS-SMS → About` menu entry — opens a small dialog with the 128×128 Coconut Cockpit logo, the mod version, and the project's GitHub and Discord URLs. The logo PNG is bundled into the mod and rendered via the existing `staticSkin` + `picture` override pattern (the same trick `dtc_skins.icon_static` already uses for warning/question glyphs).

**Changed**
- Prefab Manager window title now reads `Coconut Cockpit · DCS-SMS — Prefab Manager v0.3.0` instead of `dcs-sms — Prefab Manager v…`.

### [0.2.0] — 2026-05-06

The marquee feature: `dcs-sms.exe update`. Self-updates the host-side binary in place from GitHub Releases, so users never have to manually re-download `dcs-sms.exe` again — and never accidentally regress their installed mod by running `install-me-mod` from a stale older binary.

**Added**
- `dcs-sms.exe update` — fetches the latest release from GitHub and replaces the running binary in place (Windows only). The previous binary is renamed to `dcs-sms.exe.old`.
- `dcs-sms.exe update --check` — reports whether an update is available without downloading.

**Fixed**
- Released binaries now embed their tag version (e.g. `0.2.0`) via `-ldflags="-X main.version=$VERSION"` at build time. Previously every released binary identified as `0.1.0-dev`, which broke version comparison for the new `update` command.

**Internal**
- Inline semver comparator (no new module dependency — stdlib only).
- GitHub Releases API helper, asset-based release filter (robust to future release-track changes — only releases that actually ship `dcs-sms.exe` are considered).
- Binary-swap helper with rename-and-rollback safety on mid-write failures.

### [0.1.0] — 2026-05-05

First tracked ME-mod release. Wraps everything shipped to date into a single point-in-time tag.

**Added**
- Prefab Manager window: name + Save row, search/filter, sortable grid (Name / Theatre / Fixed Pos / AB / G / S / Z / D), action buttons (Reload / Undo / Rename / Delete), country dropdown with Combat/All toggle and coalition-colored dots, rotation dial + spinbox, Place at original location + Place at click, status bar.
- Save flow: distill the current selection (groups, statics, zones, drawings) into a prefab file under `<saved-games>/dcs-sms/prefabs/<name>.lua`. Prefab format at `PREFAB_VERSION = "0.3.0"`.
- Place flow: both Place-at-original-location and click-to-place. Cursor-following yellow bbox preview during click-place; right-drag pan, mouse-wheel zoom, Esc cancel; double-click a row to enter click-place for that prefab.
- Single-slot Undo for placed prefabs (groups + zones + drawings + airbase warehouse splices restored together).
- Airbase supplies: marquee-detect customised airbases inside a rect and bundle their warehouse data (coalition, fuel, aircrafts, weapons, operating levels) into the prefab. Apply on Place to the same-named airbase, with theatre-mismatch refusal and country-coalition override. Refuses to apply if the prefab predates theatre capture (older `0.2.0` saves).
- Per-ship warehouse capture + apply, ride inline on `unit._sms_warehouse` through serialization.
- Country override at place time with **catalog validation** — refuses placement if any prefab unit's type is missing from the chosen country's catalog (avoids the silent fallback to "Boat Armed Hi-Speed" for ships under unsupported countries).
- Rename, Delete, Reload-library actions.
- Live name+theatre search and click-to-sort grid columns.
- Native ME `MsgWindow` for confirmation prompts (Save-overwrite / Apply-airbase-supplies / Delete) — title bar, icons, button styling all match the editor.
- Severity-coloured status bar: info (white), warning (yellow), error (red), placement (green). Auto-clears info/warning after 6 s; the placement message stays for the duration of the mode.

**Tools**
- `tools/dcs-sms.exe install-me-mod` — copies the ME-mod into `<DCS install>/MissionEditor/modules/dcs_sms_me/` and patches `MissionEditor.lua` with a sentinel-marker `require` block. Idempotent; backs up `MissionEditor.lua` first.
- `tools/dcs-sms.exe uninstall-me-mod` — reverses the install.
