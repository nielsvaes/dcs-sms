# Paint Statics — design brief

**Date:** 2026-06-12
**Status:** Approved design, ready to build
**Audience:** the implementing agent (overnight, autonomous)
**Area:** `tools/me-mod` (Mission Editor mod) — a new tool window alongside Prefab Manager and Mass Edit

---

## 0. How to read this brief

This is your spec. It is intentionally exhaustive so you can execute it top-to-bottom without a separate planning phase — **the milestone list in §9 is your plan**. Read the AGENTS.md for the area before writing code (`tools/me-mod/AGENTS.md`, and the cross-cutting rules in the repo-root `AGENTS.md`). Every file path and line number below was verified against the repo at the time of writing; re-confirm them as you go, since line numbers drift.

You are not flying blind: you can drive a running DCS via `dcs-sms.exe` and **take screenshots** to confirm what you build actually works. §8 explains how to use that as your verification loop. Lean on it constantly.

---

## 1. What we're building and why

A tool to **"paint" Static objects onto the DCS map** — the same workflow as foliage painting in Unreal (Foliage Mode) or detail/tree painting in Unity (Terrain Tools). You hold the left mouse button and drag across the map; static objects scatter under a circular brush according to density settings.

**The pain it solves:** placing large statics by hand in the ME is fine, but *scattering the small clutter* that makes a base or FARP feel alive — barrels, crates, sandbags, ammo boxes, tires, pallets — is tedious one-at-a-time work. Painting makes it seconds of work.

**What this is NOT:** not a terrain/texture tool, not a tool for units/vehicles/aircraft (statics only), not a replacement for precise single-object placement (the ME already does that well).

---

## 2. The decisions (already made — do not re-litigate)

| # | Decision | Choice |
|---|----------|--------|
| D1 | Interaction model | **True freehand painting**: hold left mouse + drag → statics scatter under a circular brush. |
| D2 | Fallback if continuous drag can't be made to work | **Click-to-stamp**: each left-click drops one brush-circle of scatter. Same scatter core, degenerate gesture. |
| D3 | Erase | **MVP — must ship.** Hold-drag in Erase mode deletes *tool-placed* statics under the brush. |
| D4 | What gets painted | **Single statics now, prefabs later.** Build a weighted multi-type palette of single statics; design the data model so a palette entry can later be a prefab without a rewrite. |
| D5 | Palette | **Weighted multi-type**: several static types, each with a weight; each placement randomly picks a type by weight. |
| D6 | Brush controls exposed | Brush **radius**, **density**, **min-spacing (anti-overlap)**, **random heading** (toggle; off ⇒ fixed heading). Plus an optional, default-off **seed** for reproducible scatter. |
| D7 | Ownership | **Country selector** in the panel (reuse the Prefab Manager's country combo), plus a **Name field** so every painted static gets a chosen name, auto-indexed. |
| D8 | Process | No formal spec→plan→implement ceremony. This brief = spec; §9 milestones = plan; commit per milestone; verify visually via `dcs-sms` + screenshots. TDD only for the deterministic scatter core (§7). |
| D9 | Isolation | Do all work in a **fresh git worktree** branched off `main` at current HEAD. |

What we explicitly do **not** do (statics don't support it): scale randomization, pitch/roll, align-to-surface-normal. Heading is the only per-instance randomization.

---

## 3. The keystone: the map mouse-hook is already solved in this repo

The single biggest risk — "can we even paint on the ME map?" — is already answered. The **Prefab Manager's place-pending state machine** does exactly the hard parts you need. Read it first: `tools/me-mod/lua/dcs_sms_me/prefab_manager.lua:1313-1521`.

It uses `me_map_window` (aliased `MapWindow`):

- `MapWindow.getPanState()` → the default pan/zoom map state. **Capture it** so you can forward right/middle-button events to it (pan + zoom keep working while you paint) and **restore it on exit**.
- `MapWindow.setState(state)` → installs `state`, a plain table implementing the NewMapView interface: `onMouseDown(x,y,button)`, `onMouseUp(x,y,button)`, `onMouseDrag(dx,dy,button,x,y)`, `onMouseMove(x,y)`, `onMouseWheel(x,y,clicks)`. `button`: 1=LMB, 2=MMB, 3=RMB.
- `MapWindow.getMapPoint(screen_x, screen_y)` → **world (x, y)**. This is your screen→world (cursor→world) conversion. (Coordinate convention: `x` = north, `y` = east, both meters, theatre-origin-relative — see `tools/me-mod/AGENTS.md` §1.5.)
- `MapWindow.createDrawObject(data)` / `addDrawObject(id)` / `updateDrawObject(id,data)` / `removeDrawObject(id)` → draw and live-update an on-map overlay. Use this to render the **brush circle** that follows the cursor (the Prefab Manager draws a bbox rectangle the same way; mirror it with a circle/polygon).

**How painting differs from place-pending.** Place-pending commits ONE placement on `onMouseDown` and immediately exits; it deliberately ignores left-drag (`prefab_manager.lua:1446-1450`). For painting you invert that:

- `onMouseDown(button==1)` → **begin a stroke**: set a `painting=true` flag, place the first brush-blob at `getMapPoint`.
- `onMouseDrag(..., button==1, x, y)` → **continue the stroke**: place more blobs along the drag, honoring density + min-spacing. (Right/middle drag → `forward('onMouseDrag', ...)` to pan_state, exactly as place-pending does.)
- `onMouseMove(x, y)` → update the brush-circle preview overlay at the cursor.
- `onMouseUp(button==1)` → **end the stroke**: commit one undo record for the whole stroke (§6).
- `Esc` → cancel/exit paint mode and restore `getPanState()`.

**The one thing place-pending doesn't exercise** is whether `onMouseDrag` fires *continuously* during a held left-drag (place-pending never left-drags). That is your Milestone 0 spike. If `onMouseDrag` fires continuously with live `getMapPoint`, you're done. If it does **not**, fall back to sampling the cursor inside `onMouseMove` while `painting` is true (set by `onMouseDown`, cleared by `onMouseUp`). Either path yields true freehand paint; the click-to-stamp fallback (D2) is the last resort only if neither works.

---

## 4. Architecture & files

This is a **pure ME-mod tool window** — it does its work inside the editor against the live `mission` table. The core needs **no new Go CLI verbs** (placement is GUI-internal). You *may* add a tiny internal/debug entry point for your own automated verification (§8) and, optionally, a `me static paint-area` verb later — but the shipping tool is Lua-only.

### New files
| File | Role |
|------|------|
| `tools/me-mod/lua/dcs_sms_me/paint_statics.lua` | The tool window (`sms_window` subclass): palette UI, brush controls, country combo, Name field, mode toggle (Paint/Erase), and the `me_map_window` brush state machine. Mirror the structure of `prefab_manager.lua`. |
| `tools/me-mod/lua/dcs_sms_me/paint_scatter.lua` | **Pure Lua, no dxgui.** The deterministic scatter core: given a brush stroke (path of world points + radius), density, min-spacing, a weighted type palette, heading policy, and an optional seed, return the list of statics to create `{type, x, y, heading, ...}`. This is the unit-tested heart of the tool (§7). Keep it free of any ME API so it runs under the plain Lua test harness. |
| `tools/me-mod/test/test_paint_scatter.lua` | Unit tests for `paint_scatter.lua`. Register it in `run-tests.ps1`'s hardcoded `$tests` array (it does not glob — unregistered tests silently never run). |

### Files to reuse (do not reinvent)
| What | Where |
|------|-------|
| Map mouse-hook + screen→world + on-map overlay | `prefab_manager.lua:1313-1521` (pattern), `me_map_window` (`setState`/`getPanState`/`getMapPoint`/`*DrawObject`) |
| Window chrome (title bar, footer status, Ctrl+Z→undo, File-New auto-hide, resize clamp) | `sms_window.lua` — see usage example in `tools/me-mod/AGENTS.md` §2.9 |
| Country dropdown (coalition-dotted, Combat/All filter, repopulate on reload) | `prefab_manager.lua` `populate_country_combo` (~1207) + `get_country_name`/`country_coalition` (~1151-1179) |
| Name field with `{n}` index expansion (e.g. `Barrel-{n}` → `Barrel-01`) | `prefab_naming` module + Prefab Manager naming forms (`tools/me-mod/AGENTS.md` §2.12) |
| Static data model + how a static is built/injected | `verbs/group_verbs.lua` `group_create_static` (~591-676). Statics are single-unit groups under `country.static.group`; fields: `type`, `x`, `y`, `heading` (radians in the table; degrees in public API), `category` (`Cargos`/`Fortifications`/`Warehouses`/`Trucks`), `shape_name`, `canCargo`, `mass`, `rate=100`. Reuse `inject_group` from `verb_helpers.lua` and `refresh_group_view` after mutation. |
| Undo bus | `undo.lua`; the Prefab Manager records placements via `undo.record(rec)` (`prefab_manager.lua:1413`) and `sms_window` wires Ctrl+Z to it. |
| Selection snapshot (for the eyedropper + erase hit-testing) | `selection.lua` (`snapshot`/`snapshot_mission`) — already understands statics. |
| Menu wiring | `menu.lua` — add a "Paint Statics" item next to Prefab Manager; `item.func = function() require('dcs_sms_me.paint_statics').toggle() end`. Pattern in `tools/me-mod/AGENTS.md` §2.10. |
| House skins / scrollbars | `sms_skins.lua`, `sms_scrollbars.lua`. |
| dxgui / undo / marquee gotchas | `tools/me-mod/GOTCHAS.md` — skim before touching window/map code. |

---

## 5. The scatter algorithm (`paint_scatter.lua`)

Keep this module **pure** (inputs → outputs, no ME globals) so it's fully unit-testable and the agent can drive it headlessly for screenshot verification.

**Inputs:** a stroke as a list of world points `{x,y}` sampled along the drag (or a single point for click-to-stamp); `radius`; `density` (target statics per 100 m² — pick a concrete definition and document it); `min_spacing` (meters); `palette` (list of `{type, shape_name, category, weight}`); `heading` policy (`random` or a fixed degrees value); optional `seed`; and the set of already-placed points in this stroke/session (for spacing).

**Behavior:**
1. For each brush position along the stroke, compute how many candidate points the target density implies for the area newly covered (avoid re-saturating ground the brush already swept — track swept area or dedupe by a spatial grid).
2. Generate candidate points uniformly within the brush circle (radius `R`) around the cursor.
3. **Reject** any candidate closer than `min_spacing` to an already-accepted point. Use a **spatial hash / uniform grid** keyed by `floor(x/cell), floor(y/cell)` so a long drag stays O(1) per candidate — do not do an O(n²) scan.
4. For each accepted point, pick a type by **weighted random** from the palette; assign a heading (random 0–360° or the fixed value).
5. Return the list of statics to create.

**Randomness:** Lua's `math.random`. If a `seed` is provided, `math.randomseed(seed)` for reproducibility; otherwise leave it unseeded (fresh each stroke). Note: the repo's environment has quirks around time/random in some contexts — keep all randomness inside this pure module and seed explicitly in tests so they're deterministic.

**Performance is a real risk, not a hypothetical.** A long drag can imply hundreds of statics, and committing them naïvely can freeze the ME. Per the repo's standing guidance, **measure, don't assume**:
- Separate *generation* (pure, cheap) from *commit* (ME mutation, expensive).
- **Batch the commit**: inject many statics then refresh the map view once per throttled tick, rather than one inject+refresh per static. Look at how `inject_group` + `refresh_group_view` are used and whether you can defer the refresh.
- Throttle placement rate during a drag (e.g., cap blobs committed per `onMouseDrag` tick) and make a perf check an explicit milestone gate (§9, M3). Screenshot + observe; if the editor stutters, reduce per-tick work before adding features.

---

## 6. Erase, undo, naming, ownership

- **Erase (D3):** a Paint/Erase mode toggle in the panel. In Erase mode, a left-drag deletes **statics this tool placed** that fall within the brush radius. Track tool-placed statics (e.g., tag them, or keep a registry of created group ids) so erase never deletes the user's hand-placed objects. Hit-test against the brush circle using the same `getMapPoint` cursor world position; delete via the same path the `group_remove`/static-removal code uses, then refresh the view.
- **Undo (D6/D8):** one stroke (paint OR erase, mouse-down→up) = **one** record on the single-slot undo bus. Reuse the Prefab Manager's pattern (`undo.record`). Be explicit in the status/footer that only the most recent stroke is undoable (single-slot bus). A paint-stroke undo deletes everything the stroke created; an erase-stroke undo restores what it deleted.
- **Naming (D7):** every painted static gets the panel's Name, auto-indexed via the `{n}` convention (`Barrel-{n}` → `Barrel-01`, `Barrel-02`, …). Reuse `prefab_naming`. Empty name → a sensible default (e.g., the static type + index). Field is sticky for the session like the Prefab Manager's.
- **Ownership (D7):** country comes from the reused country combo; convert to the country/coalition the static table needs exactly as `group_create_static` does.

---

## 7. The palette UI and the eyedropper

The palette is a small list: each row is a static **type** + a **weight**. Painting picks a type by weight per placement.

**How types get into the palette** — build the cheapest robust path first:
1. **Primary — Eyedropper / "Add from selection":** the user selects a static in the ME, clicks "Add selected", and its `type`/`shape_name`/`category` are read from the live mission via `selection.lua` and added as a palette row. This reuses existing, tested selection code and needs no static-type database. It is also very paint-tool-idiomatic.
2. **Stretch — Browse the static catalog:** a searchable list of all static types (investigate how the ME's own static-placement panel enumerates them — likely a `me_db`/static-object table). Nice-to-have; do not block the build on it.

**Data model (future-proofing, D4):** a palette row should be a tagged record, e.g. `{ kind = 'static', type=…, shape_name=…, category=…, weight=… }`. Reserve `kind = 'prefab'` for later so adding prefab brushes is additive, not a rewrite. Only `kind='static'` ships now.

Panel layout (follow `prefab_manager.lua` conventions; use `sms_window` chrome): palette list with add/remove + per-row weight; Paint/Erase toggle; brush sliders (radius, density, min-spacing); random-heading toggle (+ fixed-heading field when off); optional seed field; country combo; Name field; and a prominent "Paint" enter/exit button that arms the map state machine (mirror the place-pending "PLACING…" affordance: title-bar hint, sticky status, Esc cancels).

---

## 8. Your verification loop (use this constantly)

You can close the loop on almost everything overnight without a human, via `dcs-sms.exe`. **Invoke the `dcs-sms` skill** for the exact connect/screenshot/launch commands — it owns DCS interaction. The shape of the loop:

1. **Drive the editor headlessly.** `dcs-sms exec --target gui --code '<lua>'` runs arbitrary Lua in the live ME state (same state the tool runs in). The gui bridge must be ON (DCS-SMS menu → *External execution: OFF→ON*); calls return exit code 4 if it's off.
2. **Self-test the scatter without a mouse.** Expose a small internal entry point on the tool (e.g. `paint_statics._debug_stroke(points, opts)`) that runs `paint_scatter` + the real commit path. Call it via `exec --target gui` with a synthetic stroke (a line, an arc, a filled circle). This exercises generation → commit → naming → undo end-to-end with **no human mouse needed**.
3. **Screenshot to confirm.** Take an F10/map screenshot after a synthetic stroke and *look*: is the density right, are statics spaced (no overlaps), are headings varied, did the right types appear, is the area correct? Iterate against what you see, not what you assume.
4. **What still needs the human (you, in the morning):** only the literal *feel* of holding the mouse and dragging — does the brush track smoothly, does Esc cancel, does pan/zoom still work mid-paint. Leave a short **manual verification checklist** in the PR/branch notes for these.

**If the bridge stops responding, DCS probably crashed.** Recovery procedure:
- Treat repeated timeouts / dead heartbeat as a crash signal.
- **Kill the DCS process and relaunch it.** The bridge installs automatically at DCS launch, so a fresh launch restores it.
- Get back into the Mission Editor and reload the working mission, then resume. Use screenshots to confirm you're actually back in the ME with the mission loaded before continuing.
- If `target=gui` calls return exit code 4 after restart, the *External execution* toggle is off for the new session — re-enable it (consult the `dcs-sms` skill for whether/how this can be done without a human; flag it in your notes if it needs a human flip).
- Log every crash + recovery in your branch notes so the morning review knows what happened.

---

## 9. Milestones (this is the plan — commit after each; cut from the end if you run low)

Build as an ever-working vertical slice. If you run out of time or tokens, ship the **lowest completed milestone** as a coherent, committed tool.

- **M0 — Brush spike (the only real unknown).** Arm a `me_map_window` brush state via `setState`; on left-down/drag, `getMapPoint`→world and drop a single hardcoded static at each sampled point; draw a cursor-following brush circle; right/middle still pan/zoom; Esc restores `getPanState()`. Confirm (screenshot) that a held left-drag paints a continuous trail. Resolve the "does onMouseDrag fire continuously?" question here and pick the drag-sampling vs move-sampling path. **Gate: a drag visibly paints a line of statics.**
- **M1 — Vertical slice.** Real tool window (`sms_window`) + menu entry; paint ONE chosen static type with the country combo and the Name field (indexed); the pure `paint_scatter` module with brush **radius** wired; per-stroke **undo**. **Gate: open tool → pick country/name → drag → named statics appear, Ctrl+Z removes the stroke.**
- **M2 — Weighted palette.** Palette list + per-row weights + eyedropper "Add from selection"; weighted random type pick per placement. **Gate: a stroke produces a mix matching the weights (verify via screenshot + counts).**
- **M3 — Density + spacing + perf.** Density control; `min_spacing` with the spatial-hash rejection; **measure** commit cost on a long drag and batch/throttle until the editor stays responsive. **Gate: a big drag is dense, non-overlapping, and does not freeze the ME (observed, not assumed).**
- **M4 — Erase (MVP).** Paint/Erase toggle; erase-drag deletes tool-placed statics under the brush; erase strokes are undoable. **Gate: paint then erase then undo all behave.**
- **M5 — Random heading + polish.** Random-heading toggle (+ fixed value), optional seed, status/affordance polish, missing-state guards (no palette types, etc.).
- **M6 — Docs, tests, version (stretch: catalog browser).** Finalize unit tests + register in `run-tests.ps1`; update `tools/me-mod/AGENTS.md` (new tool window in §2.2 file table and §2.9; mention in the menu section); bump `version.lua` (a new tool is a **minor** bump) + add a CHANGELOG entry; if you added any CLI verb, run `dcs-sms doc` and update the §1.4 verb table. Optionally add the static-catalog browse path.

---

## 10. Repo conventions you must follow (from `AGENTS.md`)

- **Worktree.** Branch off `main` at current HEAD; work there (see the repo's worktree guidance / `using-git-worktrees`).
- **Iteration loop.** After editing embedded Lua, run `dcs-sms dev-reload` (rebuild + reinstall + hot-reload; needs the gui bridge ON). Run tooling from inside `tools/` (`go.mod` lives there; `dcs-sms` isn't on PATH — use `./dcs-sms.exe`). Lua tests: `tools/me-mod/test/run-tests.ps1` (or the Lua 5.1 interpreter at `C:\Program Files (x86)\Lua\5.1\lua.exe`).
- **Failure model.** Never `error()`/`assert()` out of ME-mod code or a verb — wrap risky ME API calls in `pcall`, log via `log.write('sms.me.paint', …)`, and degrade to a status message. A bug must never break the editor.
- **Refresh after mutation.** Statics you create/delete won't show until you refresh the relevant map/group view (`refresh_group_view`, `mapObjects` lazy-creation — see `tools/me-mod/AGENTS.md` §2.7).
- **Doc-sync, versioning, CHANGELOG** updates go in the **same commit** as the code that needs them.
- **Commits:** commit at each milestone with clear messages. **Never push**, and never open a PR, without explicit human approval — the morning review decides that.

---

## 11. Definition of done

- A "Paint Statics" tool opens from the DCS-SMS menu, on the `sms_window` chrome.
- Holding left-mouse and dragging on the map scatters statics under a circular brush, controlled by radius/density/min-spacing, with weighted type selection from the palette, random (or fixed) heading, a chosen country, and an indexed Name.
- Erase mode removes tool-placed statics by dragging.
- Each stroke is a single undo.
- The pure scatter core is unit-tested and the tests are registered + green.
- A long drag does not freeze the editor (measured).
- `version.lua`, CHANGELOG, and the relevant AGENTS.md are updated in-commit.
- Branch notes include: what was built, the crash/recovery log (if any), and a short **manual verification checklist** for the human-only mouse-feel checks.
- Work is committed on its worktree branch. **Not pushed, no PR** — left for human review.
