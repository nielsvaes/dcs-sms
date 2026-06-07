# Community Prefab Library — Design Spec

**Date:** 2026-06-07
**Status:** Approved (brainstorm complete) — implementing client + UI plane
**Area:** `tools/me-mod` (ME-mod Prefab Manager)

## Goal

Let DCS-SMS users **browse a shared, community-contributed prefab catalog
directly inside the Prefab Manager** and pull prefabs into their own library
with one click — eliminating the current manual "download from Discord, copy
into your prefabs folder" dance. Do this **without ever executing untrusted
code**.

## User value

Today, sharing a prefab means a user downloads a `.prefab` from Discord and
hand-copies it into `Saved Games/DCS/dcs-sms/prefabs/`. That friction keeps the
community library from forming. With this feature, a "Community" tab in the
Prefab Manager shows everything that has been shared and vetted, searchable and
sortable, and "Add to my library" copies a chosen prefab into the user's own
collection where it behaves exactly like one they made.

## The three planes (whole-feature context)

This feature spans three deliverables. **Only the third (client + UI) is built
in this session and this repo.** The other two are documented here for context
and are separate follow-on efforts.

1. **Community GitHub repo + CI** *(separate repo — follow-on).* Public repo
   holding vetted `.prefab` files plus a generated `index.json` manifest. CI runs
   the data-only validator on every PR and rejects anything that is not pure
   data. A deploy/commit step keeps `index.json` current.
2. **Discord bot** *(separate hosted service — follow-on).* Watches the share
   channel, runs the validator on posted `.prefab` files, and opens a PR tagged
   with the poster's handle, the message body (→ description), `#hashtags`
   (→ tags), and a snapshot of the ♥ reaction count (→ likes). Niels reviews and
   merges.
3. **ME-mod Community tab** *(THIS session).* Fetches `index.json` over HTTPS,
   renders a browse/search/sort/filter catalog, downloads + verifies individual
   prefabs on import, and copies them into the user's `Community/` folder.

## Architecture (client plane)

```
DCS Mission Editor (LuaJIT, single-threaded)
└─ dcs_sms_me (ME-mod)
   ├─ prefab_safe_load.lua   data-only parser/validator (security keystone)
   ├─ vendor/json.lua        decode-only JSON (vendored, dependency-free)
   ├─ vendor/sha256.lua      pure-Lua SHA-256 (vendored, integrity check)
   ├─ community_manifest.lua  parse + filter + sort manifest entries
   ├─ community_cache.lua    persist/restore last manifest (offline)
   ├─ community_import.lua    download→verify→write into Community/ folder
   ├─ community_fetch.lua    async HTTP(S) orchestration (coroutine + tick)
   ├─ community_transport.lua  real LuaSec/LuaSocket transport (DCS-only)
   └─ prefab_manager.lua     + Community tab UI (dxgui)
```

- **Network is in-mod**, not via the host CLI: DCS ships LuaSocket
  (`require('socket.http')`) but **not** LuaSec, so we **bundle LuaSec +
  OpenSSL + a `cacert.pem`** with the mod and `require('ssl.https')` to reach
  GitHub over real, certificate-verified TLS.
- **Non-blocking by design.** LuaJIT is single-threaded and the high-level
  socket calls block. We drive **non-blocking sockets from a coroutine resumed
  on the ME's per-frame `UpdateManager` tick** (the same tick `bridge.lua`
  already uses), so the editor never freezes during a fetch.

## Security model (the core)

A well-formed prefab is **pure data**: a Lua chunk that `return`s a table
literal, referencing no globals and calling no functions. The only danger is a
hand-crafted file that smuggles code into the `dofile`. We neutralise this by
**parsing, never executing** community files.

- **`prefab_safe_load`** tokenises the file's source and parses it against a
  strict data-only grammar that accepts ONLY:
  - exactly one `return` of exactly one table constructor at the root;
  - nested table constructors `{ ... }`;
  - string literals, numeric literals (incl. leading `-`), `true`, `false`,
    `nil`;
  - keys as bare identifiers (`name =`), bracketed string/number keys
    (`["k"] =`, `[1] =`), or positional array entries;
  …and **rejects everything else**: any function call, function definition,
  bare global identifier (e.g. `os`), operator/expression, `loadstring`/`load`,
  `...`, method calls, metatables, comments-with-code, multiple statements.
- **One validator, used at every gate**: the future CI gate (reject the PR),
  the future bot pre-check, and — in scope now — the **client loader**, which
  loads every community/imported file through `prefab_safe_load` so a non-data
  file is refused **before it ever reaches `dofile`**.
- **TLS with real certificate verification** (bundled LuaSec + `cacert.pem`,
  `verify = "peer"`) → MITM-proof transport.
- **SHA-256 integrity**: the manifest carries a `sha256` per prefab; the client
  verifies a downloaded file's hash against the manifest before saving. Second
  integrity layer beneath TLS.

## Manifest format (`index.json`)

```json
{
  "schema": 1,
  "generated": "2026-06-07T12:00:00Z",
  "prefabs": [
    {
      "name": "SA-10 EWR ring",
      "author": "Niels",
      "date": "2026-06-01",
      "theatre": "Caucasus",
      "description": "Full S-300 site wired to a forward EWR feed.",
      "tags": ["sam", "ewr", "redfor"],
      "likes": 42,
      "groups": 7, "statics": 0, "zones": 1, "drawings": 0, "airbases": 0,
      "place_at_origin": false,
      "sha256": "<hex>",
      "path": "prefabs/sa-10-ewr-ring.prefab"
    }
  ]
}
```

`path` is relative to the community repo's raw base URL. The client builds the
download URL as `<RAW_BASE>/<path>`.

## UI (Community tab in the Prefab Manager)

- New `[My Prefabs] [Community]` tab strip at the top of the existing Prefab
  Manager window.
- Community view: **search** box (matches name / author / tag), **sort**
  control (♥ most loved | name | newest), **clickable tag-filter chips**, and a
  **⟳ Refresh** button with a "last synced HH:MM" label.
- A **list** (name · author · ♥) beside a **detail panel** (description, tags,
  entity counts) with **＋ Add to my library** (or **Imported ✓** when already
  present). The detail panel notes the destination (`Community/`) and that the
  file is SHA-256 verified.
- **Sync trigger:** automatic fetch on the first time the Community tab is
  opened in a session, plus manual Refresh anytime.
- **Async:** fetch runs on the tick-pumped coroutine; UI shows "Syncing…" then
  the synced time. The ME stays responsive throughout.
- **Offline:** the last manifest is cached to disk and shown when a fetch
  fails or there's no network, with a quiet "couldn't refresh" note.

## Import behaviour

- "Add to my library" downloads the `.prefab` (if not already cached),
  validates it with `prefab_safe_load`, verifies its SHA-256 against the
  manifest, then writes it into the user's **`Community/`** folder inside their
  own library (e.g. `Community/SA-10 EWR ring.prefab`).
- The dedicated folder namespaces imports away from hand-made prefabs, so name
  collisions with the user's own root prefabs don't happen.
- Re-importing an already-present community prefab is treated as "already
  imported": the entry shows **Imported ✓** and re-import simply refreshes that
  copy. Imported copies are the user's own — a later catalog sync never
  overwrites them.

## Scope

### In scope (this session)
- `prefab_safe_load` data-only validator + exhaustive unit tests.
- Vendored decode-only JSON + vendored SHA-256 + unit tests.
- `community_manifest` parse / search / sort / tag-filter + unit tests.
- `community_cache` offline persistence + unit tests.
- `community_import` download→validate→verify→write logic + unit tests
  (network behind an injectable transport so the orchestration is testable).
- `community_fetch` async coroutine/tick orchestration + unit tests against a
  **mock transport** (the testable state machine).
- `community_transport` real LuaSec/LuaSocket transport (DCS-only; manual
  smoke).
- `package.cpath`/`package.path` wiring in `init.lua` for the bundled LuaSec,
  and install-side copying of a `lib/` payload directory (the binaries
  themselves are supplied separately — see Constraints).
- Community tab UI in the Prefab Manager (dxgui; DCS-only; manual smoke).
- Menu/version/CHANGELOG/AGENTS/docs updates per repo conventions.
- A manual-smoke checklist entry in `docs/release-gate/me-mod-smoke.md`.

### Out of scope (follow-on efforts)
- The Discord bot (separate hosted service).
- The community GitHub repo and its CI workflow + manifest generator.
- Obtaining/distributing the LuaSec + OpenSSL **binaries** (native DLLs).
- v2 features: "update available" badge, nightly Discord→GitHub ♥ refresh,
  AI-generated descriptions (Claude API in the bot), screenshots/thumbnails,
  ratings.

## Constraints

- **DCS Lua is LuaJIT (Lua 5.1 ABI), single-threaded.** No OS threads; async is
  cooperative via the `UpdateManager` tick + coroutines.
- **No LuaSec in DCS** — must be bundled. The native DLLs (`ssl.dll`, OpenSSL
  `libssl`/`libcrypto`) must match the LuaJIT/x64 ABI. **These binaries are NOT
  produced in this session**; the code wires up loading them and the install
  copies a `lib/` directory, but the feature only runs end-to-end once the
  binaries are present. This is the single biggest runtime prerequisite.
- **Never throw out of ME-mod code.** Every socket/parse/file step is
  `pcall`-guarded and degrades to a logged failure + safe UI state, per
  `tools/me-mod/AGENTS.md` §2.4 / §2.11.
- **Two test surfaces** (per AGENTS.md §2.8): Lua mock tests
  (`tools/me-mod/test/`) for pure logic; manual smoke
  (`docs/release-gate/me-mod-smoke.md`) for dxgui + real-network code.
- **Non-blocking TLS handshake via LuaSec is the known risk** — it needs
  LuaSec's lower-level API with `wantread`/`wantwrite` handling across ticks.
  Prototype early; documented fallback is a tight-timeout blocking fetch on an
  idle tick.

## Decisions

Choices made during the brainstorm and autonomous calls made while writing the
spec. (Brainstorm choices are marked **[B]**; autonomous calls **[A]**.)

1. **[B] Hybrid distribution**: Discord as the social/ingestion surface,
   GitHub as the vetted source of truth + index.
2. **[B] Layered safety**: data-only validator at the CI gate AND the client
   loader (defense in depth); human review on top.
3. **[B] Ingestion via Discord bot → PR** (bot validates, opens PR tagged with
   poster/description/tags/likes; Niels merges). *(Follow-on.)*
4. **[B] In-mod networking via bundled LuaSec → HTTPS to GitHub** (chosen over
   a plain-HTTP mirror and over an HTTPS→HTTP proxy). Gives MITM-proof
   transport with no server to run.
5. **[B] Metadata**: auto-derived fields + description (Discord body) + tags
   (#hashtags) + likes (♥). v1 stamps `likes` at submission; nightly refresh is
   v2.
6. **[B] Consumption = import-first**: Community tab is browse-only; "Add to my
   library" copies into the user's `Community/` folder.
7. **[B] Community tab lives inside the Prefab Manager** (tab strip), not a
   separate window or a tree root.
8. **[B] Sync = auto on first open per session + manual Refresh.**
9. **[B] Async fetch** via non-blocking sockets pumped by a coroutine on the
   `UpdateManager` tick.
10. **[B] v1 includes** integrity (SHA-256) check, offline/cached catalog, and
    tag filter chips. **v2 defers** the "update available" badge.
11. **[A] Vendor decode-only JSON and pure-Lua SHA-256** into
    `dcs_sms_me/vendor/` rather than depending on DCS's `Scripts/JSON.lua` —
    removes a runtime path dependency and makes both unit-testable in the
    standalone Lua test VM. The manifest stays JSON (natural for a
    Python/Node bot to emit).
12. **[A] Network behind an injectable transport interface.**
    `community_fetch`/`community_import` take a transport (`get(url) →
    body|nil, err` plus a non-blocking variant) so orchestration is unit-tested
    with a mock; `community_transport.lua` holds the real LuaSec implementation
    and is the only DCS-only network file.
13. **[A] Reserved `Community/` folder name.** Imports land here. The existing
    `prefab_ops` folder validation already forbids the reserved characters; no
    new collision logic needed beyond the "already imported" check.
14. **[A] Config constants** (`RAW_BASE` URL, manifest path, cache filename)
    live in a single `community_config.lua` so the repo URL is changed in one
    place.
15. **[A] LuaSec payload directory**: bundled binaries are expected under the
    mod's `lib/` directory; `init.lua` prepends that to `package.cpath`. The
    embed/install copies `lib/` if present. Absence of the binaries degrades
    gracefully: the Community tab loads, Refresh reports "secure networking
    unavailable — LuaSec not installed," and the rest of the Prefab Manager is
    unaffected.
16. **[A] Manifest schema is versioned** (`schema: 1`); the client ignores
    unknown fields and rejects an unknown major schema with a clear message.

## Open questions

None blocking. (Binary acquisition and the two follow-on planes are explicitly
out of scope, not unresolved.)
