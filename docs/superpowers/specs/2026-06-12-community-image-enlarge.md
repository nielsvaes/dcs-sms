# Spec: scaled thumbnail + click-to-enlarge image window

## Goal

Two changes to the Community tab's image preview (a follow-up to the
just-built `2026-06-12-community-tab-image-previews` feature, still unreleased
on the same branch):

1. **Fix the scaling.** The thumbnail currently shows the native-resolution
   top-left corner of the image clipped to the widget, not a scaled-down whole
   image. Render the whole image scaled to fit, aspect preserved.
2. **Click to enlarge.** Clicking the thumbnail opens a larger, resizable
   `sms_window` showing the same image scaled to fit the window, with `◀ ▶`
   navigation through the prefab's images that stays in sync with the
   thumbnail.

## User value

The right-column thumbnail is small and was showing a useless cropped corner.
After the fix it shows the whole screenshot; clicking it gives a proper
large, resizable view so the user can actually see what a community prefab
looks like before importing.

## Root cause of the scaling bug

DCS scales a `Static`'s picture only when `picture.size` (the destination
render size) is set — see the ME's own `me_loadout_vehicles.lua`
(`picture.size = Size.new(h*ratio, h)`) and `imagePreview.lua` (via
`SkinUtils.setStaticPictureSize`). The current code set `picture.rect`
instead, which is a *source crop* drawn at native resolution → the clipped
top-left corner. The fix is to set the destination size with
`SkinUtils.setStaticPictureSize(dispW, dispH)` and size the widget to match.

## Scope

### In
- Switch image rendering from `setStaticPictureRect` to `setStaticPicture` +
  `setStaticPictureSize` in the Community tab thumbnail, so the whole image
  scales to fit (aspect preserved) and re-fits on splitter/window resize.
- A shared pure `community_image_fit.lua` (`fit(nW, nH, boxW, boxH) → w, h`)
  used by both thumbnail and popup, unit-tested.
- A new `community_image_window.lua`: a singleton, resizable `sms_window`
  image viewer with `◀ i / N ▶` navigation, image scaled to fit the window
  body, re-fit on resize.
- Make the thumbnail clickable (mouse-down) to open the popup, with a "Click
  to enlarge" tooltip.
- The popup's `◀ ▶` drive the **same** image index as the thumbnail (shared
  state); thumbnail and popup stay in sync; the tab's existing media
  controller serves both (one cache, one fetch path, no duplication).

### Out
- No second media/fetch controller — the popup never downloads; it displays a
  cached path the tab's controller produced (and shows a "loading…" state when
  navigating to an image the tab is still fetching).
- No zoom/pan inside the popup, no thumbnail strip, no captions, no slideshow.
- No version bump — this folds into the unreleased 0.25.0 (expand its existing
  CHANGELOG entry).
- No new CLI verb.

## Constraints

- ME-mod runtime rules (`tools/me-mod/AGENTS.md` §2.11): every dxgui call
  pcall-guarded; nothing throws out of a callback; the modules must still load
  in the bare test VM where dxgui widgets and `sms_window`'s `Window` are nil
  (so `sms_window.new` returns nil — the popup must degrade to a no-op).
- Reuse `sms_window` for the popup (don't roll new chrome): `sms_window.new`
  gives a resizable window with `on_resize(self, x, y, w, h)` (content rect),
  `get_content_bounds()`, `raw()` (for `insertWidget`), and `show/hide`. It
  auto-hides on File > New / Open.
- Image scaling uses `picture.size` (the fix). Native dimensions are probed
  once via a hidden `Static:calcSize()` after `setStaticPicture`.
- Doc-sync: new module rows in the `tools/me-mod/AGENTS.md` §2.2 table; new
  tests registered in `run-tests.ps1` (it does not glob).

## Decisions

1. **Shared image index.** The popup is a synchronized *view* of the tab's
   current image, not an independent browser. Its `◀ ▶` call the tab's `nav`
   (passed in as `on_prev`/`on_next` callbacks); `nav` updates the shared
   `cur_img_idx`, ensures the image is cached (existing logic), and on ready
   the tab pushes the new path to the popup via `community_image_window.set_image`.
   So thumbnail and popup never disagree, and there is exactly one fetch path.

2. **Popup is a singleton, hidden not destroyed.** One viewer reused across
   opens. It hides (not destroys) on close, and the tab hides it on a prefab
   selection change (`start_media`) so it never shows a stale cross-prefab
   image. Re-opened by clicking the thumbnail again.

3. **Loading state in the popup.** Navigating in the popup to an image the tab
   hasn't cached shows a "loading…" line; when the tab's media job completes,
   `set_image` replaces it. (Same lazy behavior the thumbnail already has.)

4. **Initial popup size fits the image.** Opens sized to show the image
   comfortably — the image's native size fit into ~1100×750 (capped), with a
   minimum (~400×320), resizable. Falls back to a fixed default if native dims
   are unknown.

5. **Fit, never stretch, everywhere.** `fit(nW, nH, boxW, boxH)` returns
   `nW*scale × nH*scale`, `scale = min(boxW/nW, boxH/nH)`; the widget/box keeps
   the image's aspect ratio so there is no distortion at any size. The
   thumbnail additionally caps box height at `IMG_MAX_H`; the popup uses the
   window body as the box.

6. **Folds into unreleased 0.25.0.** Version stays `0.25.0`; the CHANGELOG
   entry for it is expanded to mention the scaled thumbnail + enlarge window.

## Open questions

None.
