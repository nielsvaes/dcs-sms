# Units & statics catalog (`sms.units`, `sms.statics`) — design spec

**Status:** approved (brainstorming complete 2026-04-30)
**Branch:** `feat/units-statics-catalog`
**Worktree:** `.worktrees/units-statics-catalog`

## Goal

Replace the magic-string DCS unit-type system (`type = "F-16C_50"`) with a discoverable, autocompleted, source-of-truth catalog of every spawnable unit and static object in DCS World, plus first-party asset packs. Mission authors and AI agents both stop guessing.

## User value

Today, calling `sms.group.create({type = "F-16C_50", ...})` requires the user to know the exact DCS spawn-string verbatim — undocumented, case-sensitive, and frequently wrong (typo "F-16A" → silent runtime spawn failure). The user's only fallback is opening the Mission Editor, placing a unit, and copying its type field by hand.

After this work:

- `sms.units.planes.F_16C_50` resolves to `"F-16C_50"`. Autocomplete in any LuaCATS-aware editor lists every plane.
- `sms.units.armor.tanks.T_72B` resolves to `"T-72B"`. The category structure mirrors how missions actually think about units.
- `sms.statics.fortifications.Bunker` resolves to `"Bunker"`. Same pattern, parallel namespace, for `coalition.addStaticObject` consumers.
- `sms.units.origin_of("Type 055")` returns `"China Asset Pack"`; pure-base-game types return nil. AI agents and humans both have an unambiguous source of truth for which DLC a mission depends on.
- A LuaCATS `---@alias sms.GroupSpawnType` makes raw string literals (`type = "F-16C_50"`) typo-checkable too — the catalog isn't the only path that gets the protection.

## Scope

### In scope

1. New module `framework/units.lua` exposing `sms.units.*`, covering every entry under `dcs-lua-datamine/_G/db/Units/{Planes,Helicopters,Cars,Ships}` and the train entries under `Units/Cars`.
2. New module `framework/statics.lua` exposing `sms.statics.*`, covering every entry under `Units/{Fortifications,Cargos,Personnel,Heliports,Warehouses,GrassAirfields,ADEquipments,Effects,Animals,LTAvehicles,GroundObjects,GT_t}`.
3. `sms.units.origin_of(type_string)` and `sms.statics.origin_of(type_string)` returning the asset-pack label string for non-base entries, `nil` for base game or unrecognized strings.
4. New Go package `tools/internal/genunits/` containing the parsing, classification, sanitization, and emission logic.
5. New `gen-units` sub-command on the existing `dcs-sms` CLI (`tools/cmd/dcs-sms/genunits.go`).
6. LuaCATS `---@alias sms.GroupSpawnType` and `---@alias sms.StaticSpawnType` emitted into the generated files.
7. Update `framework/group_spawn.lua` and `framework/static.lua` so the `type` field on `create` is annotated with the new aliases.
8. Update `framework/load_all.lua` to load `units.lua` and `statics.lua`.
9. Update `AGENTS.md` §7 module index to add `sms.units` and `sms.statics`.
10. New API doc pages `docs/api/units.md` and `docs/api/statics.md`.
11. New smoke test `framework/test/smoke_units.sh` covering catalog load + a representative subset + `origin_of`.
12. Go unit tests for the generator (`tools/internal/genunits/*_test.go`) covering sanitization, classification, collision handling, origin mapping.

### Out of scope

- Reverse queries (`sms.units.types_from(pack_name)` → list). Trivial to add later from the same data structure if needed.
- Richer per-unit metadata tables (display name, country, attributes accessible via API). The DCS data is right there in the datamine if anyone needs it; the catalog itself stays slim.
- Runtime "is this DLC installed?" probing. The existing `coalition.addGroup` failure path is sufficient.
- Auto-running the generator in CI. Initial workflow is "human runs `dcs-sms gen-units` after pulling a fresh datamine".
- Smoke-spawning every type to verify it works. Would require every paid asset pack installed on the runner; not worth the cost.

## Constraints

- **No drift from DCS data.** Generator output is the single source of truth. Hand-edits to `framework/units.lua` / `framework/statics.lua` get stomped on next regen — the file's top-of-file comment says so explicitly.
- **Zero new framework runtime cost.** The catalog is plain table assignments; lookup tables for `origin_of` are plain hashes. No metatables, no lazy loading.
- **Fail-soft on classification.** If a future DCS update introduces a unit whose `category` / `attribute` / folder doesn't match any known rule, the generator emits a warning to stderr and routes the entry to a `misc` sub-bucket within the appropriate top-level (so `sms.units.armor.misc.foo` is a real possibility). Mission authors lose nothing — they can still spawn the type — and the warning surfaces the gap so we tighten classification later.
- **Lua 5.1 compatibility.** The generated files run inside the DCS mission environment.
- **Idempotent regen.** Running the generator twice in a row produces byte-identical output (sorted alphabetically within each sub-namespace; deterministic hash-table iteration).

## Decisions

These are settled — recording so future-me / future-agents don't relitigate.

### D1 — Scope: group + statics, both
Approved during brainstorming. `sms.units` covers every group-spawnable thing (`coalition.addGroup`); `sms.statics` covers every static (`coalition.addStaticObject`). Two top-level catalogs, parallel API.

### D2 — Categorization granularity: medium (two-level only where DCS itself splits)
Top-level buckets are flat where the DCS taxonomy is flat (planes, helicopters, infantry, artillery, unarmed, missiles, trains) and two-level only where DCS's own attribute tags differentiate (armor → tanks/ifv/apc; air_defence → sam/aaa/radar/manpads; ships → warships/carriers/civilian/submarines). Brainstorming option B.

### D3 — Constant naming: sanitized identifier on the left, verbatim DCS string on the right
- Replace every non-alphanumeric character with `_`.
- Collapse runs of `_` to a single `_`.
- If the result starts with a digit, prefix `_`.
- If two entries sanitize to the same identifier, append `_2`, `_3`, etc. in lexical order of the raw DCS type-string (deterministic; independent of where the source files live in `dcs-lua-datamine`).

Examples (verified against the data):

| DCS type string | Sanitized identifier |
|---|---|
| `F-16C_50` | `F_16C_50` |
| `F-16C bl.50` | `F_16C_bl_50` |
| `AV-8B N/A` | `AV_8B_N_A` |
| `Bf 109 K-4` | `Bf_109_K_4` |
| `2B11 mortar` | `_2B11_mortar` |
| `S-300PS 5P85C ln` | `S_300PS_5P85C_ln` |
| `SAM SA-19 Tunguska "Grison" ` | `SAM_SA_19_Tunguska_Grison_` (trailing `_` from the leading-quote+trailing-space pair collapses to one) |

The right-hand-side value is byte-for-byte the DCS `type` field — the only string that ever reaches `coalition.addGroup`.

### D4 — Origin handling: flat per category, comment-tagged origin
No sub-namespace per asset pack. Every entry from a non-base origin gets a one-line trailing comment naming the pack. Mission authors writing call sites never think about pack origin (autocomplete just works); reading a finished mission, `grep -- "Cold War Asset Pack"` surfaces dependencies.

`sms.units.origin_of(type_string)` provides programmatic lookup — pack name string for non-base, `nil` for base. Silent on unknown input (not API misuse, just "no recognized origin").

### D5 — Generator architecture: B-now via `dcs-sms` sub-command
Logic lives in `tools/internal/genunits/`. CLI surface is `dcs-sms gen-units --datamine <path> [--out-dir framework/]`. No standalone `gen-units` binary.

### D6 — API shape: a1 + b1
Bare strings as values (`sms.units.armor.tanks.T_72B = "T-72B"`), top-level catalogs (`sms.units`, `sms.statics`). Matches the existing `sms.targets` / `sms.options.ROE` convention exactly. No metatables, no nested tables.

### D7 — Origin friendly-name mapping
The generator maps `_origin` raw values to human-readable labels:

| Raw `_origin` | Comment label | Why |
|---|---|---|
| `ColdWarAssetsPack` | `Cold War Asset Pack` | User-requested phrasing |
| `WWII Armour and Technics`, `World War II AI Units by Eagle Dynamics`, `World War II PTO Units by Magnitude 3 LLC`, `M3 WWII PTO units` | `WWII Assets` | Consolidate four origins into one user-facing label since they all ship together as the WWII Asset Pack ecosystem |
| `China Asset Pack by Deka Ironwork Simulations and Eagle Dynamics` | `China Asset Pack` | Drop the long author tail |
| `USS_Nimitz` | `Supercarrier` | Storefront name |
| `Currenthill Assets Pack` | `Currenthill Assets` | Drop "Pack" for terseness |
| `HeavyMetalCore` | `Heavy Metal` | Storefront name |
| `Massun92-Assetpack` | `Massun92 Assets` | Spaced |
| `RailwayObjectsPack` | `Railway Objects` | Spaced |
| `South_Atlantic_Assets` | `South Atlantic Assets` | Spaced |
| `TechWeaponPack` | `Tech Weapon Pack` | Spaced |
| `C-130-Assets`, `C-130J AI` | `C-130 Assets` | Consolidate |
| `Mirage F1 Assets by Aerges` | `Mirage F1 Assets` | Drop author |
| `Animals` | `Animals` | Stays as-is (separate addon) |
| `NS430` | `NS430` | Stays |
| `WWII Units` | `WWII Assets` | Older datamine alias for the same WWII content |
| `TAVKR 1143 High Detail` | `TAVKR 1143` | Drop the "High Detail" suffix |

Anything else (per-aircraft AI mods like `F-14B AI by Heatblur Simulations`, `Mi-24P AI by Eagle Dynamics`, the dozen+ similar entries) is treated as **base-equivalent** — no comment, not surfaced in `origin_of`. Rationale: these AI variants ship with the corresponding flyable module, which most users own; treating them as a dependency adds noise without value.

### D8 — Classification rules (concrete)
Given parsed fields `folder`, `category`, `attribute[]` per entry, route as follows:

**Aircraft (folder = `Planes`):** every entry → `sms.units.planes.<sanitized>`. No sub-buckets — DCS's plane attribute tags ("Fighters", "Bombers", "Strategic bombers", "AWACS", "Tankers", "Transports", "UAVs") would fragment 140 entries into 8+ tiny buckets without practical benefit at the call site.

**Helicopters (folder = `Helicopters`):** every entry → `sms.units.helicopters.<sanitized>`. Same reasoning.

**Ground (folder = `Cars`):**

| Routing | Condition |
|---|---|
| `sms.units.armor.tanks.<x>` | `category = "Armor"` AND attributes include `"Tanks"` |
| `sms.units.armor.ifv.<x>` | `category = "Armor"` AND attributes include `"IFV"` |
| `sms.units.armor.apc.<x>` | `category = "Armor"` AND attributes include `"APC"` |
| `sms.units.armor.misc.<x>` | `category = "Armor"` AND none of the above match |
| `sms.units.air_defence.sam.<x>` | `category = "Air Defence"` AND attributes include any of `"SAM LL"`, `"SAM SR"`, `"SAM TR"`, `"AA_missile"`, `"LR SAM"`, `"SR SAM"` AND not `"AAA"`, not `"MANPADS"` |
| `sms.units.air_defence.aaa.<x>` | `category = "Air Defence"` AND attributes include `"AAA"` or `"AA_flak"` |
| `sms.units.air_defence.radar.<x>` | `category = "Air Defence"` AND attributes include `"EWR"` |
| `sms.units.air_defence.manpads.<x>` | `category = "Air Defence"` AND attributes include `"MANPADS"` or `"MANPADS AUX"` |
| `sms.units.air_defence.misc.<x>` | `category = "Air Defence"` AND none of the above (catch-all for command vehicles, generators) |

> Note: the implementation evaluates air-defence rules in the order **MANPADS → AAA → EWR (radar) → SAM → misc**, which differs from the table's listing order above (SAM → AAA → radar → MANPADS → misc). The two orderings are semantically equivalent because MANPADS-first short-circuits before the SAM check; no entry carries both `"MANPADS"` and SAM-class attributes, so the SAM rule never needs to explicitly negate MANPADS or AAA — the earlier checks already claimed those entries.

| `sms.units.artillery.<x>` | `category = "Artillery"` |
| `sms.units.infantry.<x>` | `category = "Infantry"` |
| `sms.units.unarmed.<x>` | `category = "Unarmed"` |
| `sms.units.fortifications.<x>` | `category = "Fortification"` (entries in `Cars/Car/` with this category — Bunker, outpost, etc. — are group-spawnable obstacles, not statics) |
| `sms.units.missiles.<x>` | `category = "MissilesSS"` |
| `sms.units.trains.<x>` | `category = "Carriage"` or `"Locomotive"` or `"Train"` |

> Note: an earlier draft of this rule also matched on `Name` starting with `"EWR "` to catch radar-only entries lacking the `"EWR"` attribute. Verification against the dcs-lua-datamine shows every real radar entry carries the `"EWR"` attribute, so the `Name`-fallback was dropped to keep the classifier purely attribute-driven.

**Ships (folder = `Ships`):** rules evaluate in table order; first match wins.

| Routing | Condition |
|---|---|
| `sms.units.ships.carriers.<x>` | attributes include `"Aircraft Carriers"` or `"AircraftCarrier"` |
| `sms.units.ships.submarines.<x>` | attributes include `"Submarines"` |
| `sms.units.ships.civilian.<x>` | attributes do **not** include `"Armed ships"`, OR explicitly include `"Unarmed ships"` (catch-all for cargo vessels, tugboats, fishing boats) |
| `sms.units.ships.warships.<x>` | everything else (frigates, cruisers, destroyers, missile boats) |

Within ground and air-defence routing the tables follow the same first-match-wins convention.

**Statics:** routing comes from the folder, not attributes:

| Folder | Routing |
|---|---|
| `Fortifications` | `sms.statics.fortifications.<x>` |
| `Cargos` | `sms.statics.cargos.<x>` |
| `Personnel` | `sms.statics.personnel.<x>` |
| `Heliports` | `sms.statics.heliports.<x>` |
| `Warehouses` | `sms.statics.warehouses.<x>` |
| `GrassAirfields` | `sms.statics.airfields.<x>` |
| `ADEquipments` | `sms.statics.equipment.<x>` |
| `Effects` | `sms.statics.effects.<x>` |
| `Animals` | `sms.statics.animals.<x>` |
| `LTAvehicles` | `sms.statics.airships.<x>` |
| `GroundObjects` | `sms.statics.ground_objects.<x>` |
| `GT_t` | (skipped — internal/generic table; not user-facing) |

### D9 — Datamine parsing approach: regex-based, fall back to structured if it breaks
The four fields we extract (`type`, `category`, `attribute`, `_origin`) sit at the top level of each `_G["db"]["Units"][...][...]["#Index"]` table assignment. Regex extracts them directly from the source. If the spec's "fail-soft on classification" path fires for a meaningful fraction of entries (>5%), we revisit and embed a Lua VM (`gopher-lua`). Empirical check at generation time guards this.

### D10 — Module load position
`framework/units.lua` and `framework/statics.lua` slot in immediately after `utils.lua`, before `targets.lua`:

```
sms.lua → log.lua → utils.lua → units.lua → statics.lua → targets.lua → ...
```

Both are pure-data modules with no dependency beyond `sms` (the namespace), so they could load anywhere. The position is chosen so they're available as early as possible to anything else that wants them, including future cross-references from `group_spawn.lua` / `static.lua` (e.g. an internal "is this a known type?" check).

### D11 — Generator default datamine path
`--datamine` defaults to `D:/git/dcs-lua-datamine` (the user's machine). Configurable via flag or env var `DCS_LUA_DATAMINE_PATH` (env wins over default; flag wins over env). CI / cross-machine usage just passes the flag.

### D12 — LuaCATS aliases
The generator emits two alias blocks at the top of the generated files:

```lua
-- top of framework/units.lua
---@alias sms.GroupSpawnType
---| "F-15C"
---| "F-16C_50"
---| "T-72B"
---| ...   -- one line per known type, alphabetical
```

```lua
-- top of framework/statics.lua
---@alias sms.StaticSpawnType
---| "Bunker"
---| "Cow"
---| ...
```

`framework/group_spawn.lua` and `framework/static.lua` get one annotation update each — the `type` field on the config table annotated as `sms.GroupSpawnType` / `sms.StaticSpawnType` instead of `string`. This gives mission code typo-checking even when authors write raw string literals (`type = "F-16C_50"`) instead of using the catalog.

## Architecture

### Module map

```
framework/
├── units.lua          NEW. ~1500 lines, generated. sms.units.* + origin_of.
├── statics.lua        NEW. ~800 lines, generated. sms.statics.* + origin_of.
├── load_all.lua       MODIFIED. units.lua + statics.lua appended after utils.lua.
├── group_spawn.lua    MODIFIED. type-field LuaCATS annotation.
└── static.lua         MODIFIED. type-field LuaCATS annotation.

tools/
├── cmd/dcs-sms/
│   └── genunits.go    NEW. Sub-command registration + flag parse + delegate to internal pkg.
└── internal/genunits/
    ├── parser.go      NEW. Walk datamine, regex-extract type/category/attribute/_origin.
    ├── classify.go    NEW. Apply D8 routing rules.
    ├── sanitize.go    NEW. Apply D3 identifier rules + collision tracking.
    ├── origin.go      NEW. Apply D7 origin label mapping.
    ├── emit.go        NEW. Sort, format, write framework/units.lua + framework/statics.lua.
    ├── genunits.go    NEW. Run(opts) entry point — orchestrates the pipeline.
    └── *_test.go      NEW. Unit tests for each step.

framework/test/
└── smoke_units.sh     NEW. End-to-end load + sample lookup + origin_of.

docs/api/
├── units.md           NEW. Public reference, worked examples.
└── statics.md         NEW. Public reference, worked examples.

docs/superpowers/specs/2026-04-30-units-statics-catalog.md   NEW (this file).
docs/superpowers/plans/2026-04-30-units-statics-catalog.md   NEW (next step).

AGENTS.md              MODIFIED. §7 module index gains two rows.
```

### Generated file layout

```lua
-- framework/units.lua
-- AUTO-GENERATED by `dcs-sms gen-units`. Do not edit by hand.
-- Source: dcs-lua-datamine @ <git-sha>  (regenerated <UTC timestamp>)
-- See docs/api/units.md for usage.

assert(type(sms) == "table", "framework/sms.lua must be loaded first")
local log = sms.log.module("sms.units")

---@alias sms.GroupSpawnType
---| "A-10A"
---| "A-10C"
---| ...
---| "Yak-52"

---@class sms.units
sms.units = sms.units or {}

sms.units.planes = {
  A_10A = "A-10A",
  A_10C = "A-10C",
  -- ...
  MiG_15bis = "MiG-15bis",                -- Cold War Asset Pack
  Bf_109_K_4 = "Bf 109 K-4",              -- WWII Assets
}

sms.units.helicopters = { ... }

sms.units.armor = {
  tanks = { ... },
  ifv   = { ... },
  apc   = { ... },
  misc  = { ... },
}

sms.units.air_defence = {
  sam     = { ... },
  aaa     = { ... },
  radar   = { ... },
  manpads = { ... },
  misc    = { ... },
}

sms.units.artillery = { ... }
sms.units.infantry  = { ... }
sms.units.unarmed   = { ... }
sms.units.missiles  = { ... }

sms.units.ships = {
  warships    = { ... },
  carriers    = { ... },
  civilian    = { ... },
  submarines  = { ... },
}

sms.units.trains = { ... }

-- ============================================================
-- Origin lookup
-- ============================================================

local _origin = {
  ["MiG-15bis"]   = "Cold War Asset Pack",
  ["Bf 109 K-4"]  = "WWII Assets",
  -- ... every non-base type
}

---@param type_string string  DCS type-string to look up
---@return string|nil  pack name if non-base, nil otherwise
sms.units.origin_of = function(type_string)
  if type(type_string) ~= "string" then return nil end
  return _origin[type_string]
end
```

`framework/statics.lua` mirrors this exactly with `sms.statics` / `sms.StaticSpawnType` / `sms.statics.origin_of`.

### Generator pipeline

```
parser.Walk(datamine_root)
  → []Entry{Type, Category, Attributes, Origin, Folder}

classify.Route([]Entry)
  → map[Bucket][]Entry
    where Bucket is e.g. {"units", "armor", "tanks"}

sanitize.Identify([]Entry)
  → []Entry with sanitized Identifier set
  + collision detection (deterministic _2/_3 suffixing in lexical order)

emit.WriteUnits(out_path, buckets, datamineCommit, now)
emit.WriteStatics(out_path, buckets, datamineCommit, now)
  → framework/units.lua, framework/statics.lua

(top-level) ValidateGenerated(paths)
  → shell out to luac -p if available; on failure, error
```

### CLI

```
dcs-sms gen-units [--datamine PATH] [--out-dir DIR]

Flags:
  --datamine PATH   Path to dcs-lua-datamine repo. Defaults to
                    $DCS_LUA_DATAMINE_PATH or D:/git/dcs-lua-datamine.
  --out-dir DIR     Where to write framework/units.lua + statics.lua.
                    Defaults to ./framework/ relative to cwd.

Exit codes:
  0  success
  1  classification or emission error (entries dropped, validation failed)
  2  flag parse error or missing datamine path
```

## Failure model

`sms.units.origin_of` and `sms.statics.origin_of` follow the silent-nil pattern (similar to `sms.weapon:get_target()`):

- non-string input → `nil`
- string not in lookup table → `nil`
- never logs, never errors — "not a known type" is a normal answer to the question

The catalog tables themselves are inert data with no failure surface.

`sms.group.create` / `sms.static.create` are unchanged at runtime — their existing log+nil failure path covers "spawned a type the user doesn't have installed".

## Testing

### Generator (Go)

`tools/internal/genunits/*_test.go` — table-driven tests covering:

- **sanitize_test.go** — every weird character we saw in the data: `F-16C_50`, `F-16C bl.50`, `AV-8B N/A`, `Bf 109 K-4`, `2B11 mortar`, `SAM SA-19 Tunguska "Grison" `; collision detection (two strings sanitizing to the same identifier get `_2`, `_3` deterministically).
- **classify_test.go** — at least one entry per bucket from D8 routes correctly. Use realistic fixture entries lifted from the actual datamine.
- **origin_test.go** — every D7 mapping resolves to its expected friendly label; unknown / empty origin returns empty string (signals "no comment, no origin lookup entry").
- **emit_test.go** — output is alphabetically sorted within each sub-namespace; output is byte-identical across two runs over the same input (idempotency).
- **parser_test.go** — regex extracts the four fields from a synthetic small-but-real input file; survives quoted strings with embedded special chars.

### Framework smoke (`framework/test/smoke_units.sh`)

Driven by `tools/dcs-sms.exe` against a running mission. Modeled on existing `smoke_static.sh` etc. Verifies:

- `sms.units.planes.F_16C_50 == "F-16C_50"` and ~15 other well-known type strings spanning each top-level bucket.
- `sms.units.armor.tanks.T_72B == "T-72B"` (tests the two-level case).
- `sms.statics.fortifications.Bunker == "Bunker"`.
- `sms.units.origin_of("MiG-15bis") == "Cold War Asset Pack"` (asset-pack case).
- `sms.units.origin_of("F-16C_50") == nil` (base-game case).
- `sms.units.origin_of("definitely-not-a-type") == nil` (unknown).
- `sms.units.origin_of(nil) == nil` and `sms.units.origin_of(42) == nil` (silent on non-string).
- The catalog loads cleanly via `load_all.lua` (no errors in `dcs.log`).

### Out-of-scope tests

- Spawning every type. Requires every paid asset pack on the runner; not worth the test infrastructure.
- LuaCATS alias coverage testing. The IDE either picks them up or doesn't; covered manually during dev.

## Documentation deliverables

- **`docs/api/units.md`** — full reference: category structure, sample call sites for each top-level bucket, `origin_of` semantics, regeneration instructions, link back to the spec.
- **`docs/api/statics.md`** — same, for statics.
- **`AGENTS.md` §7 module index** — two new rows.
- **`framework/units.lua` and `framework/statics.lua`** — generator-written header points readers at `docs/api/units.md` / `docs/api/statics.md`.

## Open questions

None remaining at spec time. Any classification edge cases discovered during implementation route to the `misc` sub-bucket per D8 and surface as generator stderr warnings — those are recorded as follow-ups to refine D8, not blockers for this spec.
