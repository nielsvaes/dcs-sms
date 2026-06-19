# Design — `sms_slider`: a draggable slider widget (Paint Statics)

- **Date:** 2026-06-18
- **Status:** Approved (brainstorm complete) — ready for implementation plan
- **Branch:** `feature/paint-statics`
- **Area:** `tools/me-mod` (ME-mod Lua, `sms_*` widget surface)

## Problem

Paint Statics exposes Brush radius, Density, Min spacing, and Fixed heading as
typed `SpinBox` controls. Setting them by typing (or nudging the spin arrows) is
slow and fiddly when the user wants to *feel out* a value. A draggable slider is
the natural control for "scrub to a value, watch the brush change."

## Goals

- A new, reusable house widget `sms_slider` (a real `sms_*` member, not a
  Paint-Statics-private control): a track + draggable handle + an editable value
  box, two-way synced.
- Convert four Paint Statics rows to it: **Brush radius, Density, Min spacing,
  Fixed heading**.
- Keep precise entry: you can still *type* an exact value.
- Pure, unit-tested value↔pixel math, consistent with the repo's test culture.

## Non-goals

- Converting Weight (palette) or Seed — they stay typed `SpinBox`es. (Seed at
  0–999999 is meaningless to drag; Weight lives in the palette sub-area and was
  not requested.)
- Keyboard nudge (arrow keys to step) — YAGNI for now.
- A separate horizontal scrollbar abstraction. `sms_scrollbars` is unrelated.

## Decision: hand-rolled, not ED's native `Slider`

ED's dxgui ships a `Slider` class, but **no code in this repo uses it** — every
house widget (`sms_window`, `sms_scrollbars`, `splitter`, `tri_state_button`,
`clearable_edit`) is hand-rolled from `Static` / `EditBox` / `Button`. We
deliberately hand-roll `sms_slider` on the same pattern for: full control over
look (house skins), explicit step/range semantics, a clean single `on_change`
callback, testable pure math, and zero dependence on ED's Slider API/default
skin. The `splitter` is already a working, unit-tested drag handle and serves as
the template.

> **Requirement:** this rationale MUST be recorded in the `sms_slider.lua` module
> header comment ("deliberately hand-rolled rather than using dxgui's native
> `Slider`, because …") so the choice is discoverable at the code, not only here.

## Decisions

Calls made autonomously (the user opted out of spec/plan review via
`/write-it`). Open questions: **none**.

1. **Hand-rolled, not native `Slider`** — see the Decision section above; the
   rationale is also recorded in the `sms_slider.lua` module header.
2. **Scope: four rows** — radius, density, min-spacing, heading. Weight and seed
   stay typed `SpinBox`es.
3. **Density precision** — preserve the existing `SpinBox` semantics exactly:
   `min 0.01`, `max 50`, drag `step 0.1`, value box `decimals 2`. Dragging lands
   on `0.01 + 0.1·k`; the handle endpoints map exactly to `min`/`max` (quantize
   then clamp). Typing accepts any in-range value (e.g. `1.0`). *(Chosen over a
   clean-tenths grid so no existing behavior or the sparse `0.01` floor is lost.)*
4. **Field rename** — `W.{radius,density,spacing,heading}_spin` → `*_slider`;
   weight/seed keep `_spin`. Cosmetic churn accepted for readability.
5. **Click-on-track jumps** the handle (standard slider feel) — included.
6. **Typed values clamped, not step-snapped** — matches prior `SpinBox` typing;
   canonical step-snap happens only on drag/track-click.
7. **`set_value()` does not fire `on_change`** — matches `splitter:set_value`.
8. **Defaults** — `value_w = 52` px, handle width ≈ 10 px; `decimals`: radius 0,
   density 2, spacing 0, heading 0.
9. **Graceful fallback** — `mk_slider` falls back to `mk_spin` when
   `sms_slider.new` returns `nil` (headless/stripped VM), so the readers always
   see a `getValue`.
10. **No new version** — part of the unreleased `0.27.0`; CHANGELOG line added
    under the existing entry, not a new version header.

## The widget — `sms_slider.lua`

Composite widget following the `clearable_edit` idiom: it parents **three
sibling raw widgets** to the caller's `parent_raw` container and manages their
bounds together. No nesting — siblings positioned in the parent's coordinate
space, exactly like `splitter`/`clearable_edit`.

- **Track** — a thin `Static` (the groove). Inserted first.
- **Handle** — a small `Static` (the grab knob). Inserted **after** the track so
  it renders on top. This is the dragged element; it captures the mouse.
- **Value box** — an `EditBox`, pinned at the right, showing the current value
  and accepting typed input.

### Public API

```lua
M.new(parent_raw, opts) -> panel | nil
```

`opts`:

| key         | default | meaning |
|-------------|---------|---------|
| `initial`   | `min`   | starting value |
| `min`       | `0`     | range low |
| `max`       | `1`     | range high |
| `step`      | `1`     | drag/quantization increment |
| `decimals`  | `0`     | display precision in the value box; `0` = integer |
| `value_w`   | `52`    | pixel width of the value box |
| `tooltip`   | `nil`   | tooltip on the value box and handle |
| `on_change` | `nil`   | `function(value)` — fired on drag, track-click, and typed edits |

`panel` methods (mirroring `splitter` + `clearable_edit`):

- `set_bounds(x, y, w, h)`
- `get_value()` / `set_value(v)`
- `set_range(min, max)` (re-clamps current value)
- `set_enabled(v)`
- `set_visible(v)` / `show()` / `hide()`
- `widget()` (returns the value box — the focusable element)
- `is_dragging()`
- **camelCase aliases:** `setBounds`, `setVisible`, `setEnabled`, `getValue`,
  `setValue` — so the panel drops into existing form code (and the existing
  Paint Statics readers) that call raw-widget method names. This alias set is
  what keeps the integration nearly change-free (see Integration).

Returns `nil` if `Static` or `EditBox` are unavailable (headless/stripped VM),
the same contract as `splitter`/`clearable_edit`.

### Layout (`set_bounds`)

Within the `(x, y, w, h)` box:

```
[ track .......................... ]  [ value ]
        ●handle
```

- value box: `value_w` wide, pinned at the right edge, full height.
- track: from `x` to `x + w - value_w - gap`, vertically centered, thin.
- handle: `handle_w` wide (≈10 px), full row height, left edge at
  `value_to_x(value)` over the track.

### Two-way sync semantics

- **Drag handle** → `value = quantize(x_to_value(mouse_x), min, step)`; reposition
  handle, rewrite value box (formatted to `decimals`), fire `on_change`. Uses
  `captureMouse`/`releaseMouse` and treats the move-callback `x` as already in
  window coords — the exact lesson documented in `splitter.lua`.
- **Click on track** → jump the handle to that position (same path as a drag
  step), then the user may continue dragging. Standard slider feel.
- **Type in value box** → parse; if a valid number, clamp to `[min, max]`,
  set the value, reposition the handle, fire `on_change`. Typed values are
  **clamped to range but NOT step-snapped** (so `1.0` density survives even with
  step `0.1`) — matching today's `SpinBox` typing behavior. Canonical
  step-snapping only happens on drag/track-click.
- **`set_value(v)`** (programmatic) → clamp + quantize + reposition + rewrite
  text, but does **NOT** fire `on_change` (same contract as `splitter:set_value`).

## Pure, testable math core

Following `paint_scatter.lua` (pure core, separately unit-tested), the
value↔pixel mapping is a set of pure functions with no dxgui dependency,
exposed on the module for tests (e.g. under `M._math`):

```lua
clamp(v, lo, hi)                                   -> number
quantize(v, min, step)                             -> number   -- snap to min + k*step, no range clamp
value_to_x(value, min, max, track_x, track_w, handle_w) -> number  -- handle left px
x_to_value(mouse_x, min, max, track_x, track_w, handle_w, step) -> number -- quantized value
```

Edge cases the math must handle: `min == max` (zero range → handle pinned, no
divide-by-zero); `step <= 0` (treat as continuous, no quantization);
`track_w <= handle_w` (degenerate width → clamp fraction to `[0,1]`); mouse
outside the track (clamp to endpoints).

The dxgui callbacks (`_begin_drag` / `_drag_to` / `_end_drag`, modeled on
`splitter`) are thin wrappers over these pure functions and over the
handle/value-box widget updates.

## Skins — `sms_skins.lua`

Add two builders next to `M.splitter()` / `M.separator()`:

- `M.slider_track()` — a recessed groove: a `Static` bkg fill, darker than the
  panel (like `separator()` but a couple px tall).
- `M.slider_handle()` — a small lighter neutral knob (like `splitter()`'s grab
  bar). dxgui has no `setCursor`, so the visible handle is the only affordance —
  same constraint `splitter` documents.

Value box reuses the stock `editBoxSkin_ME` (as `clearable_edit`/`mk_edit` do).

## Integration — `paint_statics.lua`

Add a local `mk_slider(value, min, max, step, decimals, tooltip, on_change)`
that calls `sms_slider.new(parent_raw, {...})`. The four converted rows use it
in place of `mk_spin`, keeping their existing ranges/steps:

| Row         | min  | max  | step | decimals |
|-------------|------|------|------|----------|
| Brush radius (m)   | 1    | 2000 | 5    | 0 |
| Density /100m²     | 0.01 | 50   | 0.1  | 2 |
| Min spacing (m)    | 0    | 500  | 1    | 0 |
| Fixed (°)          | 0    | 359  | 1    | 0 |

Field handles rename `W.radius_spin` → `W.radius_slider` (and density / spacing /
heading likewise) for clarity. Weight and Seed keep `mk_spin` / `_spin` names.

**Reader compatibility (the key simplification):** the existing readers call
`widget:getValue()` via `spin_value(widget, fallback)` —
`get_radius`/`get_density`/`get_min_spacing` and the heading reader. Because
`sms_slider` exposes a `getValue` alias, **those readers need no change**.
Likewise `_debug_set_brush` calls `widget:setValue(...)`, which works via the
`setValue` alias. So the integration is: swap the constructors, rename four
fields, and adjust `relayout`.

**`relayout`:** the four rows change from `label | spin(90px)` to
`label | slider(flex) | value_box`. The slider spans the input column width
minus the value box; exact pixel widths (input column width, gap, `value_w`)
are confirmed against the config column during planning. Weight/seed/other rows
are untouched.

## Tests & docs

- **`test_sms_slider.lua`** — pure-math unit tests (`quantize`, `value_to_x`,
  `x_to_value`, `clamp`, and the edge cases above). Modeled on
  `test_splitter.lua`'s harness; runs in the headless Lua 5.1 VM with no DCS
  modules.
- **Register it in `tools/me-mod/test/run-tests.ps1`** — the runner uses a
  hardcoded `$tests` list and does not glob; an unregistered test silently never
  runs.
- **`tools/me-mod/AGENTS.md`** — add `sms_slider.lua` to the §2.2 widget/file
  table (AGENTS-sync rule: any change to public `sms.*`/widget surface updates
  AGENTS.md in the same change-set).
- **CHANGELOG** — add a line under the **existing `[0.27.0]` Paint Statics
  entry** (slider control for radius/density/min-spacing/heading). No new version
  — this is part of the same unreleased 0.27.0.

## Failure modes

- Missing `Static`/`EditBox` → `sms_slider.new` returns `nil`; `mk_slider` falls
  back to `mk_spin` so the row still works (and readers still see a `getValue`).
- All widget calls wrapped in `pcall` (house style), so a stripped VM during
  module load never throws.

## Out of scope / future

- Reusing `sms_slider` for Weight, or anywhere else in the ME-mod — left for a
  follow-up once the widget proves itself here.
- Keyboard stepping, tick marks, log-scale ranges.
