# ME Hotkeys — custom keyboard bindings for the Mission Editor

**Date:** 2026-06-04
**Status:** Design / pre-spike
**Component:** ME-mod (`tools/me-mod/`), ships under the `me-mod-v*` track
**Scope of bump:** minor (new user-visible UI feature)

---

## 1. Motivation

The DCS Mission Editor exposes many editing modes and panels that are only
reachable by clicking a toolbar button or a menu item. The **Multi Select**
tool is the canonical example — there is no native hotkey, so activating it
always means a trip to the left toolbar. Other actions *do* have native ED
hotkeys (`a`/`h`/`s`/`u`/`o` for the add-tools, arrows for pan, `+`/`-` for
zoom) but the bindings are hardcoded in ED's Lua and not user-configurable.

This feature adds a **ME Hotkeys** tool: a window where the user can assign,
re-assign, and reset keyboard shortcuts for Mission-Editor actions — both
actions that currently have no key and (best-effort, see §6) actions that
already carry an ED default.

## 2. Goals / non-goals

**Goals (v1):**

- Bind hotkeys to **native ME actions** across three categories: Map/Selection
  tools, Object-add tools, Panel toggles.
- Every action has a **default** binding; the UI shows a **reset-to-default**
  affordance (Unreal-style "return arrow") whenever the current binding differs
  from the default.
- Bindings are **silently taken over** from ED where the engine can do so
  cleanly (gated by the spike in §6).
- Bindings **persist** across ME restarts and survive `dev-reload` hot-reloads.
- The action catalog is **data-driven and extensible** — adding a bindable
  action is one table entry.

**Non-goals (v1):**

- Surfacing our *own* dcs-sms tools (Prefab Manager, Mass Edit, External
  Execution toggle) as bindable actions. Trivial to add later via the registry,
  but not a v1 priority — v1 is about making the *vanilla* ME keyboard-drivable.
- Chord sequences (e.g. `g` then `r`). Single chords only (`Ctrl+Shift+M`).
- Per-mission or per-profile keymaps. One global user keymap.
- Rebinding actions outside the toolbar-window focus scope (modal dialogs,
  file pickers — those have their own hotkey contexts).

## 3. Verified feasibility (vanilla ME source)

All paths below are under
`C:\Program Files\Eagle Dynamics\DCS World\`. These are the load-bearing
findings that make this feature buildable; implementers should re-verify the
exact symbols against the installed build (ED renames internals between
patches — wrap every vanilla call in `pcall`).

- **Global hotkey receiver.** `me_toolbar.lua` is `module('me_toolbar')`, so its
  toolbar `window` is reachable as `require('me_toolbar').window`. That window is
  ED's own ME-wide hotkey receiver — it carries `a`/`h`/`s`/`u`/`o`/`escape`/
  arrows/zoom (`setupKeyboard`, me_toolbar.lua:1454–1496). We attach our
  bindings to the same window.
- **Sanctioned mod extension point.** me_toolbar.lua:1488–1495 iterates
  registered ME modules and wires any `modul.addHotKeyOnMap = {{key=, fun=}}`
  onto the toolbar window at startup. Available as an alternative to
  direct-attach (direct-attach is simpler and works on hot-reload).
- **dxgui hotkey API.** `dxgui/bind/Window.lua`: `addHotKeyCallback(self, str, cb)`
  (line 281) and `removeHotKeyCallback(self, str, cb)` (line 285). `parseHotKey`
  (line 238) parses `Ctrl+Alt+Shift+<key>` strings. **Removal needs the original
  callback reference** — we hold refs to *our* wrappers (clean remove), but ED's
  native callbacks are anonymous closures we cannot reference (cannot remove).
- **Global keyboard chokepoint.** `me_toolbar.globalKeyboardCallback(keyName,
  keyState)` (me_toolbar.lua:1542) is registered via `Gui.AddKeyboardCallback`
  (line 1266) / removed via `Gui.RemoveKeyboardCallback` (line 1272). A single
  point that sees every raw key event — the basis of engine Approach B.
- **Multi Select entry point.** `module('me_multiSelection')` exposes
  `show(b)` (me_multiSelection.lua:162) and `isVisible()` (line 770).
  Activate: `require('me_multiSelection').show(true)` then
  `MapWindow.setState(MapWindow.getMultiSelectionState())`. The toolbar button's
  own handler is me_toolbar.lua:1142–1153.
- **Toolbar action pattern.** ED simulates a toolbar click via
  `button:setState(true); button:onChange()` (`toolbarCallback`,
  me_toolbar.lua:1455–1463). `onChange` runs `untoggleButtons` so the
  mutual-exclusion between tool modes is preserved — this is the faithful way to
  activate a tool mode (preferred over calling `panel_*.show(true)` directly,
  which can leave two modes visually active).
- **Menubar callback pattern.** `me_menubar.lua` wires items via
  `item.func = onX` (setMenuCallback, ~line 266) — same shape, available for a
  future menu-action category.
- **Known ED native hotkeys — authoritative conflict map** (enumerated from
  *every* `addHotKeyCallback` registration in `MissionEditor/modules`):
  - menubar (me_menubar.lua:232–249): `Ctrl+O` open, `Ctrl+N` new, `Ctrl+S` save,
    `Ctrl+P` fly-mission, `Ctrl+M` fly-prepare (start mission), `Ctrl+W`
    set-position, `Ctrl+Y` coords-info, `Ctrl+I` multi-template, `Ctrl+R`
    record-AVI, `Ctrl+D` DTC manager.
  - clipboard (me_copy_paste.lua:44–46): `Ctrl+C` / `Ctrl+V` / `Ctrl+X`.
  - toolbar / map (me_toolbar.lua:1474–1486): `a` `h` `s` `u` `o` add-tools,
    `escape`, `[\+]` / `[-]` zoom, `up`/`down`/`left`/`right` pan, `Alt+y`
    coord-system. Plus `C` center-on-player, `delete` remove, `return`, `space`,
    `F5`, `home`, `end` registered across the map/selection handlers.
  - ours, already taken: `Ctrl+Z` (sms_window undo), `Ctrl+Shift+R` (Prefab
    Manager refresh).

  **The `Ctrl+<letter>` space is effectively exhausted in the vanilla ME.**
  Keyless-action defaults must therefore live in a free space (§4.1), and the
  silent-override engine must treat this full map as "ED-owned" when reporting
  what a re-assignment displaces.

## 4. Architecture

Four modules under `tools/me-mod/lua/dcs_sms_me/`, each with one clear job.

### 4.1 Action registry — `me_hotkey_actions.lua`

Pure data + thunks. No dxgui, no key handling. Exports an ordered list of
action descriptors:

```lua
{
  id          = 'map.multi_select',
  label       = 'Multi Select',
  category    = 'Map/Selection',
  default_key = 'Ctrl+M',
  invoke      = function() -- verified-at-implement-time entry point
    local ms = require('me_multiSelection')
    ms.show(true)
    require('me_map_window').setState(require('me_map_window').getMultiSelectionState())
  end,
}
```

- `invoke` wraps a **verified native entry point** (see §3). Every `invoke`
  body is `pcall`-guarded by the engine, never by the registry.
- For mutually-exclusive **tool modes** (add-tools, multi-select, ruler,
  camera), `invoke` simulates the toolbar button (`btn:setState(true);
  btn:onChange()`) so ED's untoggle logic runs. For **panels** that stack
  independently, `invoke` may call the panel module directly.
- Adding an action = appending one descriptor. Categories are free-form strings;
  the UI groups by them.

The v1 catalog (entry points from §3; **each to be re-verified against the live
ME at implement time** and `pcall`-wrapped):

| Category | Action | Native entry point | Default key |
|---|---|---|---|
| Map/Selection | Multi Select | `me_multiSelection.show(true)` + map state | `m` |
| Map/Selection | Zoom in | `MapWindow.onChange_Plus` | `+` (ED) |
| Map/Selection | Zoom out | `MapWindow.onChange_Minus` | `-` (ED) |
| Map/Selection | Pan up/down/left/right | `MapWindow.onChange_Up/Down/Left/Right` | arrows (ED) |
| Map/Selection | Coord system | `MapWindow.onChange_CoordsSys` | `Alt+Y` (ED) |
| Map/Selection | Ruler / Tape | toolbar `toggleButtonTape` | `r` |
| Map/Selection | Camera | toolbar `toggleButtonCamera` / `freeCamera.show` | `k` |
| Object-add | Airplane | toolbar `toggleButtonAirplane` | `a` (ED) |
| Object-add | Helicopter | toolbar `toggleButtonHelicopter` | `h` (ED) |
| Object-add | Ship | toolbar `toggleButtonShip` | `s` (ED) |
| Object-add | Vehicle | toolbar `toggleButtonVehicle` | `u` (ED) |
| Object-add | Static | toolbar `toggleButtonStatic` | `o` (ED) |
| Panel | Triggers | `panel_trigrules.show` / `toggleButtonTrigRules` | `t` |
| Panel | Weather | `panel_weather.show` | `w` |
| Panel | Briefing | `panel_briefing.show` | `b` |
| Panel | Unit List | `handleUnitList` / `toggleButtonUnitList` | `l` |
| Panel | Draw | `panel_draw.show` / `toggleButtonDraw` | `d` |
| Panel | Bullseye | `panel_bullseye.show` | `e` |
| Panel | Goals | `panel_goal.showGoals` | `g` |
| Panel | Roles | `panel_roles.show` | `j` |
| Panel | Templates | toolbar `toggleButtonTemplate` / `addTemplate` | `p` |

**Default policy: single, unmodified letters for keyless actions.** Plain
single letters are almost entirely free in the vanilla ME — only `a c h o s u`
are taken (§3) — so keyless actions default to mnemonic single letters
(`m` Multi Select, `d` Draw, `w` Weather, …; `j`/`k`/`p` are the forced
non-mnemonic picks where the obvious letter was taken). **Native** actions that
already have an ED key keep that key as their default, even when it carries a
modifier (zoom `+`/`-`, pan arrows, coord-system `Alt+Y`). The engine fully
supports modifiers, so any binding can be rebound to a `Ctrl+`/`Alt+` chord
later; single-letter is only the default. The defaults table is the single
source for both "what to bind on first run" and "what the reset arrow restores
to."

### 4.2 Binding engine — `me_hotkey_engine.lua`

Owns the live `key → action_id` map and the attach/detach lifecycle. Holds a
table of *our* wrapper callbacks keyed by hotkey string, so rebind / unbind /
reset are clean (`removeHotKeyCallback` with the held ref). Public surface:

```lua
engine.apply(keymap)        -- diff against current live state, attach/detach deltas
engine.bind(action_id, key) -- rebind one action (removes its old key, adds new)
engine.unbind(action_id)    -- remove an action's current binding
engine.reset(action_id)     -- rebind to registry default_key
engine.reset_all()
engine.current_key(action_id) -> key | nil
engine.is_modified(action_id) -> bool   -- current ≠ default
```

The mechanism (per-key vs global chokepoint) sits behind a tiny internal
interface (`attach(key, fn) / detach(key, fn)`), selected by the spike (§6).
The rest of the module — diffing, ref-tracking, modified-state — is identical
regardless of which mechanism wins.

On hot-reload, `init.lua` calls `engine.apply(saved_keymap)` after clearing the
previous generation's attachments (same pattern bridge.lua uses for its tick
generation), so reloads don't double-attach.

### 4.3 Config / persistence — `me_hotkey_config.lua`

Reads/writes the user keymap via the `me_settings.lua` pattern (full `io`/`lfs`
in the ME state). **Stores only deltas from default** — an action at its default
is absent from the file, so future default changes propagate automatically and
the file stays small. Shape:

```lua
{ version = 1, overrides = { ['object.airplane'] = 'F1', ['panel.draw'] = 'Ctrl+Shift+D' } }
```

`config.load()` merges overrides onto the registry defaults to produce the live
keymap. `config.save(keymap)` writes back only the entries that differ from
default.

### 4.4 UI window — `me_hotkey_window.lua`

`sms_window`-based (branded title bar, footer status, File-New auto-hide,
resize clamp). Body = a **2-column tree**:

- **Col 1 — Action**, grouped by category as collapsible tree nodes
  (`Map/Selection`, `Object-add`, `Panel`). Leaf rows are individual actions.
- **Col 2 — Binding**, the current chord. Click a binding cell → the row enters
  **capture mode**: it shows "press a key…", grabs the next chord, validates it,
  writes it through `engine.bind`, persists via `config.save`.
- **Reset arrow**: rendered in a row only when `engine.is_modified(action_id)`.
  Click → `engine.reset(action_id)` + persist. A footer button offers
  **Reset all**.
- A footer **status line** reports the last action ("Bound Multi Select →
  Ctrl+M", "Reset Airplane → a") and any conflict warning.

Reachable from the **DCS-SMS** menubar entry, alongside Prefab Manager / Mass
Edit (menu.lua pattern, AGENTS.md §2.10).

### 4.5 Capture & conflict behavior

- **Capture** uses the global keyboard chokepoint (`Gui.AddKeyboardCallback`)
  *temporarily* while a cell is in capture mode: track modifier hold-state,
  resolve the next non-modifier key into a chord string, then detach. `Escape`
  cancels capture; a dedicated "clear" gesture unbinds.
- **Conflict / silent override.** Per the chosen model, assigning a key that an
  action already uses **takes it over silently**: the engine removes the key
  from whichever of *our* actions held it (and updates that row, which now shows
  *its* reset arrow). If the key is a **known ED default** (§3 conflict map), the
  engine attempts override per the spike result; the footer notes "took Ctrl+M
  from <ED action>" so nothing is hidden. There is no modal block — the
  reset-arrow model is the safety net (every change is one click from default).

## 5. Data flow

```
first run:        registry defaults ─► engine.apply ─► toolbar window hotkeys
user edits cell:  capture chord ─► engine.bind ─► config.save (delta) ─► tree refresh
reset arrow:      engine.reset ─► config.save ─► tree refresh
ME restart:       config.load ⨝ registry defaults ─► engine.apply
hot-reload:       clear prev gen ─► config.load ─► engine.apply
```

## 6. The spike (step 0 of implementation)

A ~30-minute investigation on the **live ME** that picks the engine core and
sets expectations for native-ED override. Run via `exec --target gui` snippets.
Resolve before building the engine; record findings in
`research/me-hotkey-spike-2026-06-XX.md`.

**Q1 — does re-registering an existing key replace or stack?**
Attach `require('me_toolbar').window:addHotKeyCallback('a', probe)` where `probe`
logs. Press `a`. Did the airplane tool still activate (stack → both fire) or not
(replace → last-wins)?

**Q2 — can the global chokepoint suppress ED handling?**
Register a `Gui.AddKeyboardCallback` that logs every `(keyName, keyState)` and
"consumes" `a`. Press `a`. Does it fire for all keys? Does any return value /
state suppress ED's native `a`?

**Q3 — clean removal.** Confirm `removeHotKeyCallback(window, 'a', probe)` with
the held ref removes only our probe and leaves ED's native `a` intact.

**Q4 — single-letter vs text input (make-or-break for the single-letter default
policy).** Attach a probe to a plain letter (e.g. `m`). Open a unit's name field
and type a word containing that letter. Does the field receive the character
normally (a focused edit box consumes it before the toolbar-window hotkey), or
does the hotkey fire mid-typing? ED's own `a/h/s/u/o` imply the former; confirm
it, and note any panel/field where it leaks so the engine can guard (or those
contexts fall back to requiring a modifier).

**Decision matrix:**

| Q1 | Q2 | Engine core | Native-ED override |
|---|---|---|---|
| replace (last-wins) | — | **Approach A** (per-key) | clean — our key wins, reset resurfaces ED's |
| stack | suppress works | **Approach B** (global hook) | clean — we route + suppress |
| stack | no suppress | **Approach B**, additive | best-effort — our key works, ED's also still fires; document the limitation |

Add-only bindings and rebinds of *our own* actions are clean in **all** rows —
only override-of-existing-ED-keys quality varies, exactly as scoped.

## 7. Testing

- **Lua mock tests** (`tools/me-mod/test/`): registry shape/uniqueness;
  config delta round-trip (`load`∘`save` = identity); engine diff logic
  (bind/unbind/reset/modified) against a fake `attach/detach` interface — no live
  dxgui. Follow the existing `test_*` + `run-tests.ps1` pattern.
- **Manual smoke** (`docs/release-gate/me-mod-smoke.md`): bind Multi Select,
  press the key, confirm activation; reassign an ED key, confirm override +
  reset-arrow appears; reset, confirm default resurfaces; restart ME, confirm
  persistence.

## 8. Docs / versioning (per repo rules)

- New tool window → **minor** bump in `tools/me-mod/lua/dcs_sms_me/version.lua` +
  `CHANGELOG.md` entry, same commit (AGENTS.md §4).
- Add the menu entry + a short user note to `tools/me-mod/README.md`.
- No new `me <noun> <verb>` CLI verbs in v1, so no `docs/cli/` regeneration and
  no AGENTS.md verb-index change. (A future `me hotkey ...` CLI surface is
  possible but out of scope.)
- Add a release-gate smoke checklist item (§7).

## 9. Risks / open questions

- **Spike outcome (§6)** is the primary risk; it only affects override *quality*,
  not whether the feature ships.
- **ED API drift** — every native entry point in §4.1 must be `pcall`-wrapped and
  re-verified per build; an action whose entry point fails to resolve is shown
  disabled rather than crashing the tool.
- **Capture-mode focus** — the temporary global keyboard grab must not leak if
  the window is closed mid-capture; tie capture teardown to the window's hide.
- **Chord coverage** — `parseHotKey` supports `Ctrl/Alt/Shift + <key>`; verify our
  capture produces strings `parseHotKey` accepts (e.g. numpad `+` is `[\\+]`).

## 9a. Decisions (autonomous, made during planning/implementation)

Recorded per the autonomous-build workflow — these are judgement calls the user
may want to revisit:

1. **Backend default = `perkey`.** The live-ME spike (§6) couldn't run in the
   build session (ME bridge was off), so the engine is built mechanism-agnostic
   with both backends and defaults to `perkey` (correct if a re-registered key
   replaces ED's). Flip `me_hotkey_config.BACKEND_MODE` to `'global'` if the
   spike shows stacking. See `research/me-hotkey-spike.md`.
2. **UI is a 2-column Grid with category *header rows*, not a collapsible
   TreeView.** dxgui's TreeView is single-column; the Grid gives the
   Action | Binding columns the spec asked for, with categories rendered as
   non-interactive group rows. Collapsibility was dropped as YAGNI for ~25 rows.
3. **Reset affordance.** The Unreal-style per-row reset is delivered as a `↩`
   glyph on modified rows + **Ctrl+click a row to reset** + a **Reset all**
   footer button, rather than an individually-clickable arrow *widget* per row
   (Grid cells aren't separate clickable widgets, and a custom scrolling
   row-of-widgets layout was judged too risky to write blind). This is the most
   likely thing to revisit after the first live look — a true per-row arrow
   button is a follow-up if wanted.
4. **dev-reload double-attach caveat.** On `dcs-sms dev-reload`, the previous
   generation's hotkey attachments persist on the toolbar window (the `perkey`
   backend can't recover lost callback refs), so a binding may fire twice until
   a full DCS restart. Normal use (cold ME start) is unaffected.

## 10. Out of scope / future

- dcs-sms own-tool actions as bindable entries (one registry block away).
- Menu-action category (file/edit/view) via the `me_menubar` `item.func` pattern.
- A `me hotkey list/bind` CLI surface.
- Import/export or shareable keymap profiles.
