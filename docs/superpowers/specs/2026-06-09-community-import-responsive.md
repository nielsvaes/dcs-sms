# Responsive Community Prefab Import Spec

## Goal

Stop the Mission Editor from freezing when importing ("Add to my library") a
prefab from the Community tab. After this change the editor stays responsive
throughout the download and import of a multi-MB prefab.

## User value

Importing a community prefab locked up the editor for seconds (≈3 s for a 1 MB
prefab on a gigabit line). Now the download streams across frames and the import
is near-instant, so the editor never stalls.

## Root cause (found by testing, not assumption)

The freeze had two independent causes, isolated by live testing in the ME:

1. **Unbounded download read.** `community_transport` read the HTTPS response
   with `conn:receive('*a')`, which keeps draining the socket until it would
   block. On a fast/large transfer the whole body is already buffered, so a
   single `poll()` reads the entire file in one tick — `settimeout(0)` doesn't
   help because there is always more data immediately available. The editor
   froze for the whole transfer.

2. **Synchronous pure-Lua SHA-256 integrity check.** After download,
   `community_import` hashed the entire body to verify it against the manifest.
   Pure-Lua SHA-256 costs ~3.2 s of CPU for 1 MB and cannot be made smooth on
   DCS's single Lua thread (spreading it across ticks just trades a freeze for
   prolonged choppiness). There is no bundled native digest to offload to.

## Fix

1. **Bound the download read** to `RECV_CHUNK` (16 KB) per `poll()`. Each tick
   reads at most one chunk and yields, so the download spreads across ticks and
   the editor stays interactive. HTTP/1.0 `Connection: close` means the body is
   complete when the socket reports `closed`.

2. **Drop the SHA-256 integrity check entirely.** It is redundant: the prefab is
   fetched from the same catalog repo over the same cert-verified HTTPS
   (`verify='peer'`, bundled `cacert.pem`) as the manifest, so authenticity and
   transit integrity are already guaranteed by TLS. The real security boundary —
   **`safe-load`**, the data-only parse that rejects any prefab containing code —
   is cheap (~0.03 s/100 KB) and is kept. `community_import` becomes synchronous
   again (no hash to spread).

## Scope

**In:**
- `community_transport.lua`: `receive('*a')` → bounded `receive(RECV_CHUNK)` per
  poll; `'done'` now keyed on socket `closed`; `e == nil` (full chunk, more
  coming) joins the `pending` branch. Test gains a bounded-read assertion
  (`receive` called with a byte count, not `'*a'`) + a full-chunk step.
- `community_import.lua`: remove the SHA-256 verify + the `vendor.sha256`
  require; keep `safe-load` + write (synchronous, no `begin/step` machinery).
- `community_manifest.lua`: stop **requiring** a `sha256` field and stop carrying
  it on the normalized entry (nothing consumes it now). Entries without a
  `sha256` are accepted.
- Remove now-dead modules: `vendor/sha256.lua` (sole consumer was the import
  check) and `vendor/bit_compat.lua` (sole consumer was `sha256`), plus their
  tests and `run-tests.ps1` registrations.
- Tests + `tools/me-mod/AGENTS.md` updated.

**Out:**
- The catalog repo (`dcs-sms-prefabs` + `gen_index.py`) is unchanged — it may
  keep publishing `sha256` values; the mod simply ignores them. Fully retiring
  `sha256` from the catalog is a separate, coordinated follow-up.
- No change to the fetch orchestration, the Community-tab UI, or the manifest
  browse path beyond the field relaxation.

## Constraints

- Lua 5.1, in-DCS dxgui, single-threaded PUC Lua. Socket ops stay `settimeout(0)`
  and one step per tick — the bounded read preserves that contract; it only caps
  how much each step consumes.
- Security: `safe-load` remains mandatory and unchanged — a downloaded prefab can
  only be data, never code. TLS + cert verification remain the authenticity
  guarantee.

## Decisions

- **Branch:** reset the earlier `community-import-async-hash` work (which streamed
  the hash across ticks — the wrong fix, since the hash itself is unnecessary)
  and re-landed the minimal correct change on `community-import-responsive`.
- **Drop the hash rather than optimize it** — confirmed by live testing that the
  verify phase was the lock-up, and that pure-Lua hashing can't be made smooth.
  The integrity guarantee it provided is already covered by TLS + same-repo
  fetch; `safe-load` covers code-safety.
- **Decouple the manifest from `sha256`** (user-chosen scope) so the mod no longer
  depends on a field it doesn't use.
- **`RECV_CHUNK = 16384`** (≈ one TLS record) — a tunable balance of per-tick cost
  vs. total transfer ticks.

## Open questions

None. (Possible follow-up: drop `sha256` generation from the catalog repo.)
