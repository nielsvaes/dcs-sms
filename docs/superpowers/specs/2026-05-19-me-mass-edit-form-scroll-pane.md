# ME Mass Edit — wrap right-pane forms in a ScrollPane

**Status:** design
**Branch:** `worktree-me-mass-edit`
**Supersedes / extends:** Mass Edit form additions (PRs 1–4, map-sync, add-prefix/add-suffix).
Small layout fix — wraps the right-pane form stack in `dxgui.ScrollPane`
so the user can reach all 6 (and future) forms without resizing the
window.

## Goal

Let the Mass Edit window's right-pane form stack scroll vertically so
forms past the visible bottom edge are reachable without window resize.

## User value

The right pane currently has 6 forms on the Group scope (rename,
find & replace, add prefix, add suffix, set country, visibility &
control). At the default window height (600px) and the current
per-form heights (~80–120px each), the last 1–2 forms can be clipped or
invisible. Resizing the window works but is a manual workaround.
Wrapping the form stack in a ScrollPane removes the workaround.

## Scope

### In scope (v1)

- One change to `tools/me-mod/lua/dcs_sms_me/mass_edit.lua`:
  - Add a `W.widgets.form_scroll` ScrollPane widget, built once in
    `build_window`.
  - Pass the ScrollPane (not `W.sms_window:raw()`) as `parent_raw` to
    every `form_module.new(...)` call.
  - Move the `empty_label` ("No forms yet for this scope") into the
    ScrollPane too.
  - Update `relayout` so the ScrollPane's outer bounds fill the right
    pane, and inner form positioning uses scroll-relative coordinates
    (`y=0, y=h1+gap, …`) instead of absolute window coordinates.
- ScrollPane is created via pcall — if dxgui's `ScrollPane` module is
  missing (older DCS builds, test VMs), fall back to using `raw` as
  parent so behavior matches today.
- Apply to all scopes uniformly (the empty-label scope also gets
  wrapped — keeps host logic branch-free).

### Out of scope

- Horizontal scroll — forms are sized to the pane width.
- Per-scope scroll position memory — switching scope resets the scroll
  to top (matches the left-pane grid's behavior on scope switch, which
  rebuilds from scratch).
- Form module changes — they already accept `parent_raw` and call
  `parent_raw:insertWidget(widget)`, an API ScrollPane provides.
- Any change to the left pane, tree, bulk buttons, or scope tabs.

## Constraints

- Lua 5.1; standalone-test convention; lua at
  `/c/Users/Niels/bin/lua51/lua5.1.exe`.
- `pcall`-wrap every dxgui call (`ScrollPane.new`, `insertWidget`,
  `setBounds`, etc.). A missing widget API degrades to a fallback —
  never crashes.
- Hot-reload survival: the ScrollPane widget is created once per window
  build (`build_window` has the `W._built` guard). Reloads don't rebuild
  the window — they just refresh form behavior via re-requiring form
  modules. The pane and its child widgets stay parented across reloads.
- Must NOT break the existing scope-switch behavior in
  `show_forms_for_active_scope` — forms hide/show via `panel:hide()` /
  `panel:show()`. Hiding a widget inside a ScrollPane removes it from
  the pane's visible height calculation only if the widget reports
  `getVisible() == false`. Verify in smoke that hidden forms don't
  leave gaps in the scroll content area.

## Decisions

### D1. Single ScrollPane for the entire right pane

The pane is one widget that contains all forms across all scopes. We
don't create a separate pane per scope. Rationale: simpler layout,
fewer widgets to track; the empty-label fallback also lives inside it.

### D2. Reset scroll on scope switch

When the user switches scope tabs, scroll the pane back to top via
`scroll:setVertScrollPosition(0)` (or whatever dxgui's API is — pcall'd
because we're not 100% sure of the method name; if absent, the pane
keeps its prior position, which is fine for v1). The left pane's grid
also rebuilds on scope switch and loses position; symmetry.

### D3. Fallback to raw when ScrollPane unavailable

If `pcall(require, 'ScrollPane')` fails or `ScrollPane.new()` returns
nil, the code falls back to passing `raw` (the sms_window's content
area) as the form parent — same as today. Behavior on supported DCS
builds: scrollable. Behavior on test VMs / older DCS: unchanged.

### D4. Inner form positioning is scroll-relative

`relayout` does two things now:
1. Sets the ScrollPane's outer bounds to the right-pane area:
   `(right_x, row1_y, right_w, body_bottom - row1_y)`.
2. Walks `W.form_panels[W.scope]` and positions each form's panel at
   `(0, y_cursor, right_w, ph)` — RELATIVE to the ScrollPane. `y_cursor`
   starts at 0, not at `row1_y`.

The `empty_label` (when shown) is positioned at `(0, 0, right_w, ROW_H)`
inside the pane.

### D5. No tests added

`mass_edit.lua` host logic is not unit-tested. The pcall-wrapped
ScrollPane usage matches every other dxgui-dependent code path in the
file. This change is covered by the existing manual smoke flow plus a
new bullet appended to the Mass Edit smoke section.

### D6. Smoke checklist additions

Append two bullets to the existing `## Mass Edit (v0.10.0+)` section
(before its first `### ` subsection) under a new
`### Right-pane scroll` subsection:

- Open Mass Edit on Group tab. Verify all 6 forms are accessible by
  scrolling — the bottom form (`Visibility & control`) is reachable
  without resizing the window.
- Switch to Unit tab and back to Group. The scroll position resets to
  top.
- Resize the window taller until all forms fit. The scrollbar
  disappears.

## Architecture

### Files

**Modified:**
- `tools/me-mod/lua/dcs_sms_me/mass_edit.lua`:
  - Add `form_scroll = nil` slot to `W.widgets`.
  - In `build_window`, between widget construction and form mounting,
    create the ScrollPane:
    ```lua
    local ScrollPane; do local ok, m = pcall(require, 'ScrollPane'); if ok then ScrollPane = m end end
    local scroll
    if ScrollPane and ScrollPane.new then
        local ok, sp = pcall(ScrollPane.new)
        if ok and sp then
            skin_helper.apply(sp, 'scrollPaneSkin_ME')  -- or whatever the right skin is; see recon below
            pcall(raw.insertWidget, raw, sp)
            scroll = sp
        end
    end
    W.widgets.form_scroll = scroll
    local form_parent = scroll or raw
    ```
  - In the form-mounting loop, change `form_module.new(raw, ...)` to
    `form_module.new(form_parent, ...)`.
  - In the empty-label construction, change `pcall(raw.insertWidget, raw, s)` to `pcall(form_parent.insertWidget, form_parent, s)`.
- `relayout`:
  - Reserve the right-pane area for the ScrollPane:
    ```lua
    if W.widgets.form_scroll then
        set(W.widgets.form_scroll, right_x, row1_y, right_w, body_bottom - row1_y)
    end
    ```
  - Form positioning loop uses scroll-relative coordinates:
    ```lua
    local active = W.form_panels[W.scope] or {}
    local pane_x = W.widgets.form_scroll and 0       or right_x
    local pane_y = W.widgets.form_scroll and 0       or row1_y
    local pane_w = W.widgets.form_scroll and right_w or right_w
    local y_cursor = pane_y
    for _, panel in ipairs(active) do
        local ph = (panel.get_height and panel:get_height()) or 80
        if panel.set_bounds then panel:set_bounds(pane_x, y_cursor, pane_w, ph) end
        y_cursor = y_cursor + ph + L.FORM_GAP
    end
    ```
  - Empty-label positioning gets the same dual-mode treatment.
- In `on_scope_changed`, after the relayout call, reset scroll position
  if the ScrollPane is present:
  ```lua
  if W.widgets.form_scroll and W.widgets.form_scroll.setVertScrollPosition then
      pcall(W.widgets.form_scroll.setVertScrollPosition, W.widgets.form_scroll, 0)
  end
  ```

**Smoke checklist:**
- `docs/release-gate/me-mod-smoke.md` — new `### Right-pane scroll`
  subsection under `## Mass Edit (v0.10.0+)`.

**Not touched:**
- Form modules (`mass_edit_forms/*.lua`) — they already work with any
  parent that has `insertWidget`.
- Test files — host-level scroll behavior isn't unit-tested.
- `mass_edit_forms.lua` — unchanged.

### Recon findings (locked)

1. **Skin:** `scrollPaneSkin_ME` exists in
   `dxgui/skins/skinME/scrollPaneSkin_ME.skin.lua`. Apply via
   `skin_helper.apply(scroll, 'scrollPaneSkin_ME')`.
2. **Scroll reset:** the ScrollPane API exposes `setVertScrollValue(v)`,
   NOT `setVertScrollPosition` (which is the Grid API). Use
   `setVertScrollValue(0)` in `on_scope_changed`.
3. **Content extent refresh:** ScrollPane DOES NOT auto-detect child
   bounds changes. The API has `updateWidgetsBounds(self)` documented
   as "if one of the widget sizes has been changed, call this function
   to update scrollbars." Call it once at the end of `relayout` after
   positioning all forms so the vertical scroll range matches the
   actual content height.

## Testing

### Unit tests
None added. Host logic is not unit-tested; the layout change matches
every other pcall-wrapped widget access in the file.

### Smoke checklist additions

In `docs/release-gate/me-mod-smoke.md`, under `## Mass Edit (v0.10.0+)`,
insert a new subsection BEFORE the first existing `### ` subheading:

```markdown
### Right-pane scroll (v0.10.0+)

The right pane is wrapped in a ScrollPane so all stacked forms are
reachable regardless of window height.

- [ ] Open Mass Edit on Group tab at the default window height. Verify
      a scrollbar appears on the right pane and all 6 forms (Rename,
      Find & replace, Add prefix, Add suffix, Set country, Visibility &
      control) can be reached by scrolling.
- [ ] Switch to Unit tab, then back to Group. The right pane scroll
      position resets to top.
- [ ] Resize the window taller until all 6 forms fit. The scrollbar
      disappears.
- [ ] Hide a form (e.g. via Ctrl+Shift+R reload while the window is
      open) and verify no empty gap is left in the scroll content area.
      (If gaps appear, hidden forms still contribute to the pane's
      content height — file as a follow-up.)
```

## Open questions

None — recon items above are bounded discoveries during impl, not
unresolved design choices.
