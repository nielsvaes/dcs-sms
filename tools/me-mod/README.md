<p align="center">
  <img src="../../assets/logo.png" alt="Coconut Cockpit" width="160">
</p>

# dcs-sms — Mission Editor mod

[![Latest ME-mod release](https://img.shields.io/github/v/release/nielsvaes/dcs-sms?filter=me-mod-v*&label=latest&color=blue)](https://github.com/nielsvaes/dcs-sms/releases/latest)
[![Release ME-mod](https://github.com/nielsvaes/dcs-sms/actions/workflows/release-me-mod.yml/badge.svg)](https://github.com/nielsvaes/dcs-sms/actions/workflows/release-me-mod.yml)
[![Discord — Coconut Cockpit](https://img.shields.io/badge/discord-Coconut_Cockpit-5865F2?logo=discord&logoColor=white)](https://discord.gg/8tbdGY45hM)
[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/F1F4PYTO7)

> **🚀 Quick start:**
>
> 1. [**Download `dcs-sms.exe`**](https://github.com/nielsvaes/dcs-sms/releases/latest/download/dcs-sms.exe) — save it anywhere (Downloads is fine).
> 2. **Double-click `dcs-sms.exe`** — a small menu opens. Pick **1** to install. (Prefer the command line? Open a CMD/PowerShell in that folder and run `dcs-sms.exe install-me-mod` — same result.)
> 3. **Fully quit DCS** (not just the Mission Editor) and start it again.
> 4. Open the Mission Editor — **DCS-SMS** will appear in the top menu bar.
>
> Hit a snag? Jump to [Troubleshooting](#troubleshooting).

Custom in-editor extension that adds a **Prefab Manager** to DCS World's Mission Editor. Save a selection of groups / statics / zones / drawings to a reusable prefab; place them later by click or at their original location. Supports rotation, country override, airbase warehouse capture, per-ship warehouses, and undo.

<p align="center">
  <img src="../../assets/prefab-manager.png" alt="dcs-sms Prefab Manager — library on the left, click-to-place in progress on the map" width="900">
</p>

## 🎯 Audience

You design DCS missions in the Mission Editor and want to reuse pieces of one mission in another.

## ✨ Features

### Scope

- Single unit, single static, or any selection up to a full FOB / airbase complex.
- Drawings (lines, polygons, circles, arcs) saved with vertex deltas relative to the polygon anchor.
- Trigger zones saved with name, position, radius, properties, color, type, and points.
- Per-ship warehouses captured inline on each ship unit (coalition, jet fuel, aircraft, weapons, operating levels).
- Per-airbase warehouses captured by marquee-selecting around the airbase: same data the `.miz` `warehouses` file holds.
- Theatre captured at save time, used to refuse cross-theatre airbase apply.

### Group fidelity

- All waypoints preserved with route geometry, altitude, speed, ETA, formation template.
- All waypoint actions / tasks preserved, including nested ComboTasks, conditions, and any Lua.
- All group options preserved: ROE, alarm state, formations, callsigns, frequencies, payloads, liveries.
- Aircraft-specific: Link 16 datalink network with team members, AIC/FF/VOC channels, STN codes, voice callsign labels, onboard numbers.
- Naval-specific: TACAN, ICLS, Link 4 task params bound to the placed ship unit.

### Cross-unit references

- Statics linked to a host unit are preserved.
- Aircraft set to start on a ship deck keep their parking binding.
- Escort, EPLRS, and other group-id-bearing task params are remapped to the placed group.
- Link 16 references preserverd.
- References to units not present in the prefab are nil'd (cross-mission references that wouldn't resolve).

## 📥 Install

Save `dcs-sms.exe` anywhere convenient (Downloads, Desktop, `C:\Tools`, wherever — the .exe doesn't write anything to that folder; it just needs to be where you can run it from). Then **double-click it**. A console window opens with a small menu — type `1` and press Enter to install:

<p align="center">
  <img src="../../assets/dcs-sms-doubleclick.png" alt="dcs-sms.exe interactive menu — 'DCS install: ...' line plus four numbered options (Install / Uninstall / Update / Set DCS install path) and 'q. Quit'" width="780">
</p>

The menu shows the auto-detected DCS install path at the top. If it says **"not detected"**, type `4` first to paste the full path to your DCS install folder (the menu will strip surrounding quotes for you, so `"D:\Program Files\Eagle Dynamics\DCS World"` from Explorer's address-bar copy works as-is).

**Prefer the command line?** Open a **CMD** or **PowerShell** terminal in the folder where you saved `dcs-sms.exe` and run:

```powershell
dcs-sms.exe install-me-mod
```

> 💡 Easiest way to open a terminal in a specific folder: in File Explorer, click the address bar, type `cmd`, and press Enter. The terminal opens with that folder as the working directory.

A successful CLI run looks like this:

<p align="center">
  <img src="../../assets/cmd.png" alt="dcs-sms.exe install-me-mod running in a CMD window — output shows 'copied', 'patched', 'Install complete. Restart DCS.'" width="780">
</p>

> 🛡️ **First-run Windows warning:** `dcs-sms.exe` is unsigned (signing certs cost money this project doesn't have), so Windows / Edge / Chrome may flag it as "unrecognised" on download or first run. Tell the warning to keep going — see [Troubleshooting → SmartScreen](#windows-smartscreen-says-windows-protected-your-pc) for the click path. If your environment refuses to let you run unsigned binaries at all, the [OVGME-friendly install](#alternative-install-ovgme-no-exe) is a fallback.

That's the whole command. It auto-detects DCS at the standard install path (`C:\Program Files\Eagle Dynamics\DCS World` and similar locations).

If your DCS lives somewhere non-standard, pass `--dcs-path` once — it's cached to `%AppData%\dcs-sms\config.toml`, so subsequent installs/uninstalls don't need the flag again:

```powershell
dcs-sms.exe install-me-mod --dcs-path "D:\Program Files\Eagle Dynamics\DCS World"
```

You can also set the `DCS_SMS_DCS_INSTALL` environment variable instead of the flag.

What this does:

1. Backs up `<DCS>\MissionEditor\MissionEditor.lua` → `MissionEditor.lua.dcs-sms.bak`. Refuses if a backup already exists (run `dcs-sms uninstall-me-mod` first to clean up).
2. Appends a `require('dcs_sms_me.init')` block (delimited by sentinel comments) to `MissionEditor.lua`.
3. Copies the mod files to `<DCS>\MissionEditor\modules\dcs_sms_me\`.

Re-running the install is safe — it re-copies module files, but does not re-patch `MissionEditor.lua` if the markers are already present.

After installing, **restart DCS** (a full restart, not just closing the Mission Editor — Lua files in `MissionEditor.lua` load once at DCS start). Open the Mission Editor; you should see **DCS-SMS** in the top menu bar.

For the binary itself, see [`tools/cmd/dcs-sms/README.md`](../cmd/dcs-sms/README.md).

## 🔧 Alternative install: OVGME (no `.exe`)

If your environment refuses to run unsigned binaries (e.g. corporate machine, locked-down browser), each release also ships an OVGME-friendly zip — `dcs-sms-me-mod-vX.Y.Z.zip` — alongside `dcs-sms.exe` on the [Releases page](https://github.com/nielsvaes/dcs-sms/releases/latest).

The runtime mod is identical to what the `.exe` installs. The trade-off: OVGME can only copy files, so you handle the one-line `MissionEditor.lua` patch by hand. (We'd ship a pre-patched copy in the zip, but that file belongs to ED and the [DCS EULA §3.1(a)](https://www.digitalcombatsimulator.com/en/support/license/) prohibits redistributing modified ED files. Editing your own copy on your own machine is permitted, hence the manual step.)

1. Download **`dcs-sms-me-mod-vX.Y.Z.zip`** from the latest release; extract it.
2. Drop the `dcs-sms-me-mod` folder into your OVGME mods directory and enable it in OVGME — that copies our Lua module files into `<DCS install>\MissionEditor\modules\dcs_sms_me\`.
3. Open `<DCS install>\MissionEditor\MissionEditor.lua` in a text editor (Notepad is fine — run it as Administrator if your DCS sits under Program Files), append this single line at the very end of the file, save:
   ```lua
   require('dcs_sms_me.init')
   ```
4. Fully quit DCS and start it again. Open the Mission Editor — **DCS-SMS** appears in the top menu bar.

Updates: replace the OVGME mod folder with the new release's contents and re-enable. The `MissionEditor.lua` patch line stays where you put it; no re-edit needed unless DCS itself replaced your `MissionEditor.lua` during a DCS update (in which case re-apply step 3).

Uninstall: disable the mod in OVGME (removes the Lua files), and delete the `require('dcs_sms_me.init')` line from `MissionEditor.lua` if you want a fully clean uninstall.

The `dcs-sms.exe install-me-mod` path is still the recommended install when you can use it — it patches `MissionEditor.lua` automatically and supports `dcs-sms.exe update` / `dcs-sms.exe uninstall-me-mod`. The OVGME zip is the fallback.

## ⬆️ Update

The `dcs-sms.exe` you have can update itself in place — no manual re-download needed:

```powershell
dcs-sms.exe update
dcs-sms.exe install-me-mod
```

The first command pulls the newest release from GitHub and replaces this `dcs-sms.exe` (the previous binary is renamed to `dcs-sms.exe.old`, which is harmless and safe to delete). The second command applies the new ME-mod files to your DCS install. Re-running `install-me-mod` is idempotent — the patch line in `MissionEditor.lua` stays put; only the Lua files under `MissionEditor/modules/dcs_sms_me/` get overwritten.

After updating, **fully quit DCS and start it again** — Lua files in `MissionEditor.lua` load once at DCS start.

> 💡 Curious whether there's actually anything new? `dcs-sms.exe update --check` reports the available version without downloading.

If you'd rather grab the binary by hand: [download the new `dcs-sms.exe`](https://github.com/nielsvaes/dcs-sms/releases/latest/download/dcs-sms.exe) directly, drop it over the old one, and run `dcs-sms.exe install-me-mod`. Same end state.

## 🗑️ Uninstall

```powershell
dcs-sms.exe uninstall-me-mod
```

Removes the patch block from `MissionEditor.lua` (surgically, by markers; falls back to backup-restore if the markers were edited away), deletes the modules directory, and deletes the backup.

## 🛟 Troubleshooting

### Windows SmartScreen says "Windows protected your PC"

`dcs-sms.exe` is unsigned, so Windows treats it as suspicious by default. You'll see this in two places:

- **On download** — Edge / Chrome may warn that the file "might be dangerous" or block it. Click **Keep** (Edge) or the **^** menu → **Keep anyway** (Chrome).

<img width="562" height="337" alt="image" src="https://github.com/user-attachments/assets/5ddc331e-b57f-40df-9477-1a019a2b069e" />

- **On first run** — Windows may show a blue dialog titled **"Windows protected your PC"**. Click **More info** (small text in the dialog) → **Run anyway**.

You only have to do this once per binary. Subsequent runs of the same .exe go through silently.

If your environment refuses to let you bypass this at all (locked-down corporate machine, group policy blocking unsigned binaries, etc.), use the [OVGME-friendly install](#alternative-install-ovgme-no-exe) instead. It uses the OVGME zip from the same release and skips the `.exe` entirely.

### I ran the .exe and nothing happened

Two possibilities:

- **The terminal window closed before you read it.** If you double-clicked and the menu flashed by, it's because something inside the menu (an error, or you typed something it didn't expect) returned and the window closed before you could see it. Run it again — the menu prints "Press Enter to exit..." after every action so you can read what happened.
- **Windows blocked the .exe entirely.** SmartScreen may have killed the process before the menu could open. See [Windows SmartScreen says "Windows protected your PC"](#windows-smartscreen-says-windows-protected-your-pc) above.

If you'd rather avoid the menu altogether: open a terminal *in the folder where you saved the .exe* (File Explorer → click the address bar → type `cmd` → Enter), then run `dcs-sms.exe install-me-mod` from there. Output stays visible until you close the terminal.

### Install said "Install complete" but DCS-SMS isn't in the Mission Editor menu

Almost always: you closed and re-opened the Mission Editor without restarting DCS itself. The patched `MissionEditor.lua` loads exactly once when DCS starts; closing-and-reopening the ME doesn't re-load it.

Quit DCS World entirely (close it from the main menu, or kill it via Steam → right-click DCS → Manage → Stop). Start it again. Open the Mission Editor — the **DCS-SMS** menu should now be there.

### Install failed with "Access is denied"

If the installer prints something like:

```
dcs-sms install-me-mod: mkdir modules: mkdir C:\Program Files\Eagle Dynamics\DCS World\MissionEditor\modules\dcs_sms_me: Access is denied.
```

your DCS lives under `C:\Program Files\...`, and Windows requires Administrator rights to write there. The installer itself isn't doing anything privileged — it's just creating a folder and copying files into the DCS install directory — but Windows protects everything under `Program Files` by default.

Two options:

- **Run as Administrator.** Right-click `dcs-sms.exe` → **Run as administrator**, then pick **1** from the menu. (CLI equivalent: open CMD/PowerShell *as Administrator* in the folder where `dcs-sms.exe` lives, then `dcs-sms.exe install-me-mod`.)
- **Use the [OVGME-friendly install](#alternative-install-ovgme-no-exe) instead.** You'll still need to run Notepad as Administrator for the one-line edit to `MissionEditor.lua` in step 3, but the rest is handled by OVGME.

If your DCS is installed *outside* `Program Files` (e.g. `D:\Eagle Dynamics\DCS World`), elevation is not required — the install runs fine as a normal user.

### "DCS install path not found"

Auto-detect couldn't find DCS at the standard path. Pass `--dcs-path` once with the full path to your DCS install folder (the one containing `bin/`, `MissionEditor/`, and `Scripts/`):

```powershell
dcs-sms.exe install-me-mod --dcs-path "D:\Program Files\Eagle Dynamics\DCS World"
```

The path is cached to `%AppData%\dcs-sms\config.toml` for next time, so you only need this once.

### Something else broke

Check `<Saved Games>\DCS\Logs\dcs.log` for any `[sms.me]` lines around the time of the issue, then [open a bug report](https://github.com/nielsvaes/dcs-sms/issues/new?template=bug_report.yml) — paste the relevant log lines and the version number from the Prefab Manager title bar.

## 🏗️ Prefab Manager

The mod is one floating window — the **Prefab Manager** — opened from **DCS-SMS → Prefab Manager** in the editor's top menu bar.

### Saving a prefab

Select what you want to capture (groups, statics, zones, drawings, airbases), type a name in the **Name** field, click **Save**. The prefab is written to:

```
<Saved Games>\DCS\dcs-sms\prefabs\<name>.lua
```

These are plain Lua tables — readable, editable in any text editor, version-controllable.

> 💡 **Always marquee-select when saving a prefab — even for a single group.** Drawing a selection rectangle grabs every entity inside it (groups, statics, zones, drawings, airbases). Click-to-select grabs one entity at a time, which works fine for a lone group but quietly misses linked pieces — the parented aircraft on an aircraft carrier, the deck crew statics next to it, an airbase you wanted bundled. Get into the habit of marquee and you'll never wonder "why isn't my stuff there?" after placing.

**Marquee-selecting over an airbase** puts the airbase into the selection too, alongside any groups / zones / drawings inside the rect. This is how you capture airbase customisations (warehouse contents, coalition) into a prefab — there's no other way to add an airbase by clicking it directly.

<p align="center">
  <img src="../../assets/airbase-in-selection.png" alt="Marquee selection in the editor — the 'Snow city' airbase appears in the multi-selection panel alongside groups and zones" width="900">
</p>

**Ships save with their custom loadouts.** A ship's warehouse (fuel, weapons, aircraft inventory, operating levels) is captured per-vessel and re-applied when you place. If you edited a Stennis to carry custom Hornets on deck and a non-default fuel state, that's exactly what you get back when the prefab is placed.

**Aircraft carriers travel with their deck setup — if you marquee around everything.** Clicking the carrier alone saves the hull and that's it. Drawing the marquee around the carrier *and* its parented aircraft, deck crew statics, helicopters on the well deck, refuelling tankers etc. captures the whole package; placement brings the entire air wing back intact instead of you rebuilding the deck by hand each time.

### Placing a prefab — two modes

**Place at original location** drops the prefab back at the exact world coordinates it was saved from. Useful when the prefab was saved on this same theatre and you want it back where it was.

**Place at click** enters cursor-following placement. The yellow preview rectangle tracks your mouse; left-click to commit, right-drag to pan the map, mouse-wheel to zoom, Esc to cancel.

<p align="center">
  <img src="../../assets/placement-mode.png" alt="Place-at-click mode — yellow preview rectangle following the cursor on an empty map" width="900">
</p>

> 💡 **Shortcut:** double-click any row in the library to jump straight into Place-at-click mode for that prefab. Saves the row-then-button click.

Rotation, country override, and the airbase-supplies prompt all happen at place time — set them in the controls before clicking Place.

### Library columns

| Column | Meaning |
|---|---|
| **Name** | The prefab's filename (without `.lua`). Click the header to sort. |
| **Theatre** | The map the prefab was saved on. Place-at-original-location refuses across theatres. |
| **Fixed Pos** | `Yes` if the prefab is meant to live at one specific spot on its theatre (e.g. a SAM site defending a specific airfield). You can still Place-at-click it elsewhere — just know you're going off-script. |
| **AB** | `Yes` if the prefab includes airbase warehouse data (see below). |
| **G** / **S** / **Z** / **D** | Counts of groups / statics / zones / drawings inside. |

The **Fixed Pos** column at a glance:

<p align="center">
  <img src="../../assets/save-at-orig.png" alt="Library grid with the Fixed Pos column highlighted on a row that has Yes" width="900">
</p>

### Airbase supplies (AB column)

When a prefab has `Yes` in the **AB** column, it's bundled with custom warehouse data for one or more airbases (coalition, fuel stocks, aircraft inventory, weapons inventory, operating levels). Placing the prefab pops a confirmation asking whether you want to apply those supplies to the destination airbase:

<p align="center">
  <img src="../../assets/airbase-supplies.png" alt="Apply Airbase Supplies confirmation dialog over the editor — 'The prefab you're placing has custom supplies for Ramat David. Apply?'" width="900">
</p>

Apply is refused across theatres (a Caucasus airbase prefab can't be applied on Syria) and the destination airbase's coalition is forced to match the place-time country.

### Other actions

- **Rotation** — dial + spinbox at the bottom-left. Rotation applies to all entities in the prefab together (groups, statics, drawings, zones).
- **Country override** — dropdown with a Combat/All toggle and coalition-coloured dots. Placement is refused if any unit type isn't in the chosen country's catalog (no silent ship-becomes-fast-boat fallbacks).
- **Undo** — `Ctrl-Z` with the Manager window focused undoes the most recent placement (groups, zones, drawings, and airbase splices all restored together).
- **Library** — Reload (rescan disk), Rename, Delete, live name+theatre search, click-to-sort columns.

### Community prefabs

The Prefab Manager has a **Community** tab that browses prefabs shared by other
players and pulls them into your own library with one click. Imported prefabs
land in a `Community/` folder and behave like any prefab you made.

Browsing fetches over HTTPS, which DCS can't do on its own, so the mod uses a
bundled **LuaSec** package. Drop the LuaSec payload (`ssl.dll`, the OpenSSL
DLLs, `ssl.lua`, `https.lua`, and `cacert.pem`) into
`Saved Games/DCS/dcs-sms/lib/`. Without it, the Community tab still opens and
shows the last catalog it cached, but Refresh will report that secure
networking is unavailable.

Everything in the catalog is vetted: community files are validated as pure data
and never run as code, and each download is checked against a SHA-256 hash
before it's saved.

### Triggers

The **Triggers tab** (third tab in the Prefab Manager) lists every trigger in the open mission with its condition and action counts. Check the ones you want to keep, give the prefab a name, and click **Save triggers** — a triggers-only prefab is written to your library just like a regular prefab, but with no map footprint.

When you save a **normal prefab** (groups, zones, drawings), the manager scans for triggers that reference the selection. If it finds any, a checklist overlay appears with those triggers pre-checked — confirm to bundle them into the prefab alongside the entities.

**Placing a prefab with triggers** shows an import dialog before anything lands in your mission:

- References to groups, zones, and units placed by the prefab are resolved automatically from the placement id-map.
- Unresolved references (entities that aren't in the prefab) get a manual-map dropdown so you can point them at an existing group or zone in the current mission.
- Embedded media — pictures, sounds, and do-script files — is decoded from the prefab and registered into the mission automatically; no manual file copying needed.
- If any trigger flags overlap with flags already in use in the target mission, a warning lists the conflicts before you import.

**Triggers-only prefabs** skip the map-click step entirely — the import dialog appears immediately when you click Place.

**Undo** (`Ctrl-Z`) after a triggered placement removes both the placed entities and the imported triggers, and refreshes the Triggers panel if it's open.

Community prefabs that contain triggers show a trigger count in their detail panel so you know what you're importing before you click **Add to my library**.

## ⌨️ Hotkey Manager

<img width="474" height="945" alt="image" src="https://github.com/user-attachments/assets/f6608859-6781-4ed2-a052-2207cb7822d0" />


**DCS-SMS → Hotkey Manager** opens a window with an **Action | Binding** table of native Mission-Editor actions grouped under collapsible category rows (Map/Selection, Object-add, Panel toggles) — click a category row to fold it away. **Single-click** a row to select it, **double-click** to capture a new key. The footer has **↩ Reset selected** (reverts the selected row) and **Reset all** (reverts everything); any binding changed from its default shows in **amber italic**. Bindings persist across sessions in `<Saved Games>\DCS\dcs-sms\me_hotkeys.lua`.

Defaults use single letters where free (e.g. `m` for Multi Select, `d` for Draw); the object-add and pan keys keep their existing editor keys. Every action fires through the editor's own toolbar/map entry points, so a bound key does exactly what clicking the matching toolbar button does.

The list leads with a **DCS-SMS** category for this mod's own tools (Prefab Manager `Alt+P`, Mass Edit `Alt+E`, Hotkeys `Alt+K`, About `Alt+I`), then covers the whole **main-menu bar** — File, Edit, View, Flight, Campaign, Dynamic Mission and Misc categories — so menu entries that ship without a shortcut (Save As, Open Backup, Prepare Mission, the static-template load/save, …) get one. Key combinations work too: capture `Ctrl+Shift+S`, `Alt+3`, etc. by holding the modifier(s) and pressing the key. (Exit is deliberately not bindable, to avoid an accidental editor exit.)

The **search box** at the top filters the list by name, category, or bound key — type `ctrl` to see everything on a Ctrl combo, `shift+s` to find Save As, `pan` for the pan actions. A filter force-expands the categories so matches inside collapsed groups still show.

**User scripts (advanced).** The **Scripts** category lets you bind your own Lua to a key. Click **`+ New Script`** (or double-click an existing script row) to open the editor: give it a name, capture a hotkey, and write Lua in the multiline editor. **Run** executes it immediately so you can iterate, then **Save**. The code runs in the Mission Editor's Lua environment (full access to the editor's modules and the mission) — powerful, and entirely at your own risk; errors are caught and logged, never crash the editor. Scripts are stored in `<Saved Games>\DCS\dcs-sms\me_scripts.lua`. Leave the hotkey blank to keep a script unbound (run it from the editor only).

## 🔌 External execution toggle

Under the **DCS-SMS** top menu in the Mission Editor, a third item "External execution: ON/OFF" controls whether the dcs-sms hook honors `--target gui` requests from the `dcs-sms.exe` CLI (or any other external tool writing to the mailbox).

- **Default is OFF** at every DCS launch — session-only, no persistence.
- Toggle ON when you want Claude (or any external tool) to run Lua directly against the editable mission. Click the menu item again to toggle back OFF.
- The hook's heartbeat exposes `gui_bridge_enabled` so the CLI can fail fast (`dcs-sms exec` exit code 4) instead of timing out.
- The toggle only affects requests with `target=gui`; `target=mission` requests run in the sandboxed mission env regardless and are always allowed.

## 📜 License

The ME-mod is licensed under the [GNU General Public License, version 3](../LICENSE) (covering everything under `tools/`). You may use, modify, and distribute it, but derivative works must also be GPL v3 and ship with source.

The framework (`framework/`) is MIT-licensed separately so mission makers can embed it freely. See [`LICENSE.md`](../../LICENSE.md) at the repo root for the full rationale.

## 🏷️ Versioning

The ME-mod ships under tags `me-mod-v0.x.y`. The canonical version string lives at [`lua/dcs_sms_me/version.lua`](lua/dcs_sms_me/version.lua). See [`AGENTS.md` §4](../../AGENTS.md#4-versioning-and-releases) for the full rules.

- [`CHANGELOG.md`](../../CHANGELOG.md) — release history; the **ME-mod** section tracks `me-mod-v*` tags.

## ✅ Manual smoke checklist

For the release-gate procedure (run before tagging a `me-mod-v*` release), see [`docs/release-gate/me-mod-smoke.md`](../../docs/release-gate/me-mod-smoke.md).
