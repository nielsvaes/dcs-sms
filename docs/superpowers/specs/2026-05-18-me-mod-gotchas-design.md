# ME-mod gotchas log + `/gotcha` capture command

**Date:** 2026-05-18
**Scope:** `tools/me-mod/` (in-DCS Lua, dxgui-heavy code)
**Status:** design approved, ready to plan

---

## Problem

The ME-mod uses DCS's `dxgui`, a non-vanilla GUI library with quirks that AI agents repeatedly trip over. The existing `tools/me-mod/AGENTS.md` §2.7 covers a handful of ME API quirks, but it isn't a place we keep adding to — and the dxgui-specific gotchas (skinning, widget lifecycle, undo bus, marquee, context-menu construction) don't fit the "ME API" framing of §2.7.

We need a low-friction way to capture quirks as we hit them, so future agents touching `prefab_manager.lua`, `context_menu.lua`, `sms_window.lua`, `menu.lua`, and friends can be warned in advance.

## Solution overview

Three artifacts:

1. **`tools/me-mod/GOTCHAS.md`** — a running, append-only log of ME-mod / dxgui quirks.
2. **A pointer from `tools/me-mod/AGENTS.md` §2.7** to that file, so the existing "read AGENTS.md before writing code" rule pulls future agents into it.
3. **`.claude/commands/gotcha.md`** — a project-local `/gotcha` slash command that turns a short user note plus the current conversation context into a structured entry, gets approval, and appends it.

## Artifact 1 — `tools/me-mod/GOTCHAS.md`

### Initial file contents (ships verbatim)

```markdown
# ME-mod / dxgui gotchas

Running log of non-obvious quirks in the DCS Mission Editor's `dxgui` and the
ME-mod runtime. If you're about to touch `prefab_manager.lua`,
`context_menu.lua`, `sms_window.lua`, `menu.lua`, or any other dxgui-heavy
file in `tools/me-mod/lua/dcs_sms_me/`, skim this first.

Entries are added via `/gotcha <brief description>` in Claude Code, which
expands the description using recent conversation context and asks you to
approve before writing.

Cross-reference: [`AGENTS.md`](AGENTS.md) §2.7 ("ME API quirks you'll hit")
covers ME mission-table API quirks; this file covers dxgui / runtime
quirks.
```

That is the complete starting file — header text only, no separator, no entry template, no example. Entries start being appended below it as they're captured.

### Entry format (what `/gotcha` produces; lives in the command, not in the file)

```markdown
---

## <Short title — one line, ideally a verb phrase>

**What went wrong:** <one or two sentences — what we tried, what failed,
what the failure looked like>

**What works:** <the correct approach — code identifier / snippet if short>

**Why:** <optional — only when the underlying reason is knowable and
non-obvious. If we don't know why, omit this line rather than guessing.>
```

Each entry starts with a `---` separator so entries are visually delimited; the first appended entry adds the first separator below the header.

### Conventions

- **Append at the bottom.** Newest entries last. Order = discovery order. Keeps diffs clean and avoids merge conflicts.
- **No timestamps in entries.** Git history is the source of truth for when an entry was added.
- **Code identifiers in backticks.** File names, function names, dxgui widget types, ME API calls.
- **One H2 per entry.** No nested headings inside an entry.
- **No categorization yet.** If the file grows past ~20 entries, we can re-bucket; YAGNI until then.

### Growth

Entries accrue as we encounter gotchas. The file is hand-grown via `/gotcha`; nothing autogenerates it.

## Artifact 2 — pointer from `tools/me-mod/AGENTS.md`

Add a one-sentence note at the **top of §2.7** ("ME API quirks you'll hit"), before the bullet list:

> **dxgui / runtime quirks** (skinning, widget lifecycle, undo bus, marquee, context menus) live in a separate running log: [`GOTCHAS.md`](GOTCHAS.md). Skim it before touching `prefab_manager.lua`, `context_menu.lua`, `sms_window.lua`, or `menu.lua`. The bullets below cover ME mission-table API quirks.

Single source of truth, single link, no duplication. No other AGENTS.md changes.

## Artifact 3 — `.claude/commands/gotcha.md`

A project-local slash command at `C:\git\dcs-sms\.claude\commands\gotcha.md`. Gets committed to the repo so anyone cloning has it.

### Behaviour

Invoked as `/gotcha <brief description>`. When triggered, the command instructs Claude to:

1. **Read the user's brief description** as the seed for the entry.
2. **Mine the recent conversation** for context: what file/area were we touching, what code did we try, what failure mode did we hit, what fix landed. Pull concrete identifiers (function names, widget types, file paths) where they help.
3. **Read `tools/me-mod/GOTCHAS.md`** to see the existing structure, so the new entry matches conventions and doesn't duplicate an existing gotcha.
4. **Draft a structured entry** in the format defined above (`## title`, `**What went wrong:**`, `**What works:**`, optional `**Why:**`).
5. **Show the draft to the user** and wait for approval or edits. **Never silent-append.**
6. **On approval, append** the entry to the bottom of `tools/me-mod/GOTCHAS.md`.
7. **Suggest a commit** per the repo's "no silent commits" rule. Default suggested message: `docs(me-mod): add gotcha — <short title>`. Don't run `git commit` without confirmation.

### Edge cases

- **No description supplied** (`/gotcha` with no args): prompt the user for the brief description before doing anything.
- **No relevant conversation context** (e.g., user is starting fresh and just wants to record a known gotcha): proceed using only the user's description, asking 1–2 clarifying questions if the description is too thin to write a useful entry.
- **Apparent duplicate** of an existing entry: show the user the existing entry and ask whether to extend it, replace it, or add a new one.
- **Repo guard not needed**: the command is project-local, so it only loads inside this repo. No `pwd` check required.

## Out of scope

- **Auto-categorization** by sub-area (menus / windows / undo bus / etc.). Not worth it at <20 entries.
- **Separate files** per dxgui sub-area. Single file is easier to grep and easier to maintain.
- **Structured frontmatter / YAML metadata.** Markdown headings are enough.
- **Cross-referencing** between entries. If two gotchas relate, the second can mention the first by name; no formal linking system.
- **Pointers from the framework or CLI AGENTS.md** — this is ME-mod-scoped on purpose. Framework gotchas would go in a different file if we ever need one.
- **A global `/gotcha`** that works outside this repo. Out of scope; the file path is hardcoded.

## Acceptance criteria

1. `tools/me-mod/GOTCHAS.md` exists with the seeded header and zero entries.
2. `tools/me-mod/AGENTS.md` §2.7 has the one-line pointer at the top.
3. `.claude/commands/gotcha.md` exists, is committed, and when invoked: takes a description, drafts an entry using conversation context, shows it to the user, appends on approval, and suggests a commit.
4. The slash command is discoverable as `/gotcha` in Claude Code when run inside the dcs-sms repo.
5. The new file/pointer/command land in a single commit; the first real gotcha entry is a separate later commit.
