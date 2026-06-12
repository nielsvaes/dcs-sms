# Spec: image previews in the Community tab

## Goal

Show a community prefab's screenshot(s) on the right side of the Prefab
Manager's **Community** tab, below the description, one image at a time with
`◀ i / N ▶` navigation. Images are fetched lazily from the catalog repo over
the existing HTTPS transport, cached to disk, and scaled to fit the column
width with aspect ratio preserved at all times.

## User value

Community prefab submissions now include screenshots (in each prefab's
`<stem>.meta.json` sidecar, e.g.
`https://github.com/nielsvaes/dcs-sms-prefabs/blob/main/prefabs/snow-city.meta.json`).
The Community tab currently shows none of them — a browsing user can't see what
a prefab looks like before importing it. This surfaces the screenshots inline.

## Scope

### In
- A new image-preview panel in the Community tab's right column, between the
  description editbox and the "Add to my library" button.
- One image shown at a time, scaled to the column width (aspect preserved),
  with `◀`/`▶` buttons and an `i / N` counter when a prefab has more than one
  image.
- Lazy, on-demand download of the currently-viewed image only, cached to disk
  so re-viewing (and re-opening) is instant.
- Live re-fit of the displayed image whenever the right-column splitter is
  dragged or the window is resized (aspect always preserved).
- Two new pure, unit-tested helper modules and one pure helper in `paths.lua`.

### Out
- No change to the catalog repo (`dcs-sms-prefabs`) or to `index.json`. The
  client reads the per-prefab `.meta.json` sidecar directly.
- No thumbnail strip, no zoom/pan, no fullscreen viewer, no captions.
- No disk-cache eviction/cleanup (cached PNGs are small; left for a future
  change).
- No new `me <noun> <verb>` CLI verb — this is purely Prefab Manager UI.

## Constraints

- **ME-mod runtime rules** (`tools/me-mod/AGENTS.md` §2.11): every dxgui /
  vanilla-ME call is `pcall`-guarded; nothing may throw out of a callback or
  `tick()`. The module must still load in the bare test VM where dxgui widgets
  are absent.
- **Non-blocking networking** (`community_transport`): single-threaded PUC Lua;
  every socket step is non-blocking and pumped one `:step()` per
  `UpdateManager` tick. Image/meta fetches reuse this; no blocking I/O.
- **Image rendering**: the ME displays an image by applying a picture-skin to a
  `Static` from a **local file path** (`SkinUtils.setStaticPicture` /
  `setStaticPictureRect`, exactly as `MissionEditor/modules/imagePreview.lua`
  does). So an image must be downloaded to disk before it can be shown.
- **Doc-sync** (root `AGENTS.md` §3): the new `community_meta.lua` module is
  added to the `tools/me-mod/AGENTS.md` §2.2 file table in the same change-set.
- **Versioning** (root `AGENTS.md` §4): a new UI feature is a **minor** bump;
  `version.lua` + `CHANGELOG.md` updated in the same change-set.
- **Test runner** (`run-tests.ps1`): does not glob — new `test_*.lua` files
  must be registered in its `$tests` array or they never run.

## Decisions

These were settled with the user, or chosen autonomously and recorded here:

1. **Image source = fetch the `.meta.json` sidecar on selection** (user
   choice). The `images` array lives only in the per-prefab sidecar, not in
   `index.json`. On selecting a prefab, derive its sidecar URL from
   `entry.path` (`prefabs/snow-city.prefab` → `prefabs/snow-city.meta.json`),
   fetch it, parse `images`. Fully self-contained in this repo; works against
   the live catalog today. The parsed list is memoised on the entry
   (`entry._images`) so re-selecting never refetches.

2. **One image at a time with `◀ ▶` cycling** (user choice). A counter shows
   `i / N`. Arrows appear only when `N > 1`. Navigation wraps around.

3. **Lazy per-index download.** Only the image currently being viewed is
   downloaded; arrows fetch neighbours on demand. Rejected prefetching all
   images on select (wastes bandwidth on images the user may never reach).

4. **Disk cache layout mirrors the repo.** Images are written to
   `<Saved Games>/DCS/dcs-sms/community-images/<thread_id>/<n>.png`, i.e. the
   repo-relative image path (`<thread_id>/<n>.png`) appended to a new
   `paths.COMMUNITY_IMAGES_DIR`. A cached file is reused as-is (existence
   check) instead of re-downloading.

5. **Dedicated media job slot.** A second job slot `W.media_job` (kinds
   `'meta'` | `'image'`), pumped alongside the existing `W.job` in `tick()`,
   keeps image traffic independent of the manifest-refresh and import jobs, so
   selecting a prefab never clobbers an in-flight import. A `W.media_token`
   generation counter (bumped on every selection change) makes a completion
   that lands after the selection moved on a no-op for the UI (the bytes are
   still cached).

6. **Fit, never stretch.** The widget renders the full image
   (`setStaticPictureRect(path, 0, 0, nativeW, nativeH, skin)`) into bounds
   sized to `nativeW*scale × nativeH*scale` where
   `scale = min(boxW/nativeW, boxH/nativeH)`. Because the destination box keeps
   the image's native aspect ratio, there is no distortion at any column width.
   Native dimensions are probed once via a hidden `Static:calcSize()` after the
   picture is applied, then cached for re-fitting on resize.

7. **Height cap.** The image display height is capped at `IMG_MAX_H = 220px`
   and the description editbox keeps a minimum of `80px`, so a tall/portrait
   screenshot can't crowd out the description. The image panel sits directly
   below the description and above the import button; the description editbox
   flexes to fill the remaining height.

8. **Degrade silently.** No images / meta fetch fails / networking (LuaSec)
   unavailable → the panel collapses to zero height and the description takes
   the full column (today's exact layout); no per-selection nagging. A single
   image that fails to download shows a small `preview unavailable` line in the
   panel while the arrows keep working.

9. **Re-fit triggers.** Image sizing happens inside `relayout(cw, ch)`, which
   already runs at build, on every window resize, and on every splitter drag —
   so the image tracks the divider and window automatically.

## Open questions

None.
