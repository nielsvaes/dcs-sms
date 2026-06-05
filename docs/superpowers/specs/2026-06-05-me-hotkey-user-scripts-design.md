# ME Hotkeys — User Scripts design

> Status: approved (brainstorm 2026-06-05). Extends the ME Hotkeys tool
> (`tools/me-mod/lua/dcs_sms_me/me_hotkey_*`) shipped in ME-mod 0.18.0.

## 1. Goal

Let a user write their own Lua snippets, name them, and bind each to a hotkey —
Autodesk-Maya-style "assign a script to a key." Custom scripts appear as
first-class rows in the existing ME Hotkeys window alongside the built-in
actions, and are created/edited through a dedicated editor dialog.

This is deliberately an **advanced / power-user** feature: a script is arbitrary
Lua running in the Mission Editor's GUI Lua state.

## 2. Execution model & safety

A script's `code` runs in the **ME GUI Lua environment** — the same state the
built-in hotkey actions and `dcs-sms exec --target gui` execute in. It therefore
has full reach: `me_*` modules, the editable mission table, the dcs-sms bridge,
`log`, etc. This is intentional (the whole point is Maya-like power).

- **Compile:** `loadstring(code)` (Lua 5.1). A compile (syntax) error is surfaced
  to the user and **blocks save** / is shown by Run.
- **Run:** the compiled chunk is invoked under `pcall`. A runtime error is caught,
  logged (`log.write('sms.me.script', log.ERROR, …)`), and shown in the editor —
  it never aborts the ME. This matches the framework's log-and-continue failure
  mode.
- The invoke thunk a bound script attaches to the engine is the same
  `loadstring`+`pcall` wrapper, so a broken bound script logs and no-ops rather
  than breaking the editor.

No sandboxing in v1. The feature is opt-in (you have to write the code) and the
risk is the user's own.

## 3. Data model & storage

A script is `{ id, name, key, code }`:

- `id` — stable unique string `script.<n>` (n = max existing numeric suffix + 1).
- `name` — display label (also the row label in the Hotkeys list).
- `key` — hotkey string in the same form the rest of the tool uses
  (`"Ctrl+Shift+1"`, `"m"`, …) **or empty** (`""`) = unbound (run from the editor,
  bind later).
- `code` — the Lua source (multiline).

Scripts persist to their **own** file, separate from the built-in key-override
file:

```
Saved Games\DCS\dcs-sms\me_scripts.lua
```
```lua
-- DCS-SMS ME Hotkey user scripts (auto-generated; safe to delete).
return {
  { id = "script.1", name = "Center & log", key = "Ctrl+Shift+1", code = "local n = ...\n..." },
}
```

`code` is serialized with `string.format('%q', code)` (escapes quotes/newlines
safely). `me_hotkeys.lua` (built-in key overrides) is untouched and stays
built-in-only.

### Key management — why scripts don't use the override system

Built-in actions have a static `default_key` and a user *override* delta stored
in `me_hotkeys.lua`. A script has no static default — its key **is** user data,
so it lives with the script definition in `me_scripts.lua` and is edited **only**
through the editor dialog. Scripts therefore never create override deltas; the
two files stay cleanly separated (script key+name+code together; built-in
overrides together).

Concretely: the facade builds the engine's action list as **built-ins + one
dynamic action per script**. Each script maps to:

```lua
{ id = <script.id>, label = <name>, category = 'Scripts',
  default_key = <key or ''>, ed_key = nil, script = true, invoke = <run thunk> }
```

The engine attaches it like any keyless action. A script row is double-clicked
to open the **editor** (not the capture overlay), so script keys never flow
through `engine:bind()`.

**Edge case (accepted):** if a user captures a *built-in* onto a key a script
holds, `engine:bind`'s displacement logic writes an unbind override
(`script.id = ''`) into `me_hotkeys.lua`. The script then shows unbound until its
key is re-set in the editor. This is rare and arguably correct (the key was
reassigned); we accept it for v1. The editor's Save warns when the chosen key is
already held, reducing the chance.

## 4. Architecture — modules

New:

| File | Responsibility | Tested |
|---|---|---|
| `me_hotkey_scripts.lua` | Script persistence + CRUD: `load`/`save` (`me_scripts.lua`), pure `serialize`/`deserialize`, `add`/`update`/`remove`/`list`/`get`, `next_id`, `compile(code) -> ok, err`, `to_actions()` (script defs → engine action tables with a `loadstring`+`pcall` invoke). No dxgui at load. | yes (standalone) |
| `me_hotkey_script_editor.lua` | The editor window (`sms_window`): name field, hotkey field + Capture/Clear, multiline code EditBox, Run (+ result/error line), Save/Delete/Cancel. Calls back into the facade to persist + rebuild. | manual smoke |

Changed:

| File | Change |
|---|---|
| `me_hotkeys.lua` (facade) | Build the engine from `actions.list()` **+** `scripts.to_actions()`. New `scripts_changed()` → reload scripts, rebuild engine, `apply()`. Expose `open_script_editor(id?)`. |
| `me_hotkey_engine.lua` | Treat an empty-string key as unbound: `current_key`/`default_key` return `nil` when the value is `''` (so keyless scripts attach nothing and render "(unbound)"). `rows()` passes through the `script` flag. |
| `me_hotkey_window.lua` | Render a **Scripts** category (only when ≥1 script). `+ New Script` footer button → `facade.open_script_editor()`. Double-click a `script`-flagged row → `facade.open_script_editor(id)` instead of capture. Reset selected/all skip script rows. |
| `me_hotkey_config.lua` | unchanged (built-in overrides only). |
| docs | CHANGELOG / README / AGENTS / release-gate smoke updated in the same change-set (repo doc-sync rule). Version bump as part of shipping. |

### Interfaces (the seams)

- `me_hotkey_scripts.to_actions()` is the only coupling between script storage and
  the engine — it returns plain action tables, so the engine stays oblivious to
  "scripts" (it just sees actions with `script = true` passed through to rows).
- The editor talks to the world only through the facade
  (`open_script_editor`, persist via `scripts.*`, `scripts_changed`), and reuses
  the existing chord-capture overlay for the hotkey field.

## 5. UI

### Scripts category (main Hotkeys window)
- Shown only when ≥1 script exists. Rows render like built-ins (name + key,
  searchable by name/key). Scripts have no "default", so the amber-italic
  "modified" treatment doesn't apply to them.
- Footer gains **`+ New Script`** (alongside `↩ Reset selected` / `Reset all`).
- Single-click selects; **double-click a script row opens the editor**.

### Editor dialog (`me_hotkey_script_editor.lua`)
```
Name:   [ Center & log selection            ]
Hotkey: [ CTRL+SHIFT+1 ]   [ Capture ] [ Clear ]
Code:
+------------------------------------------------+
| local sel = ...                                |   multiline EditBox
| log.write('sms.me', log.INFO, #sel)            |   (setMultiline(true))
+------------------------------------------------+
[ Run ]   <result / error status line>     [ Save ] [ Delete ] [ Cancel ]
```
- **Capture** → existing chord overlay; fills the hotkey field with the chord.
- **Clear** → empties the hotkey field (script becomes unbound).
- **Run** → `compile` then `pcall`; status line shows `→ <return>` or
  `error: <msg>`.
- **Save** → `compile` first; syntax error blocks save and is shown. Warns if the
  key is already held by another action (still lets you save). Persists to
  `me_scripts.lua`, calls `facade.scripts_changed()`, closes.
- **Delete** → confirm, remove from `me_scripts.lua` (and clear any stray
  override for that id), rebuild, close. Hidden/disabled when editing a brand-new
  unsaved script.
- **Cancel** → close without saving; tears down any open capture overlay.

## 6. Testing

`me_hotkey_scripts.lua` standalone test (no dxgui):
- serialize/deserialize round-trip identity, incl. code with quotes/newlines.
- `deserialize` of garbage / non-table / wrong-shaped entries → `{}`.
- CRUD: add assigns a fresh `next_id`; update mutates by id; remove drops by id.
- `compile` returns ok for valid Lua, `(nil, err)` for a syntax error.
- `to_actions` shape: one action per script, `category='Scripts'`,
  `script=true`, `default_key` = the script's key, `invoke` is a function.

Engine: extend `test_hotkey_engine.lua` with an empty-`default_key` action →
`current_key`/`is_modified` treat it as unbound, never attached.

Editor window: manual release-gate smoke (create / run / save / rebind / delete /
persist-across-restart / broken-Lua-is-caught).

## 7. Out of scope (YAGNI)

Import/export, script parameters/arguments, multiple actions per key, syntax
highlighting / autocomplete, a separate output console, sharing/sync. A script is
name + optional key + a Lua body, full stop.

## 8. Doc sync

Public-surface change → update `tools/me-mod/AGENTS.md` (file-layout rows),
`tools/me-mod/README.md` (ME Hotkeys section), `CHANGELOG.md`, and
`docs/release-gate/me-mod-smoke.md` in the same change-set, per the repo rule.
