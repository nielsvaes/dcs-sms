# /gotcha

Capture a dxgui / ME-mod gotcha into `tools/me-mod/GOTCHAS.md` so future agents are warned about quirks we just hit.

## Usage

`/gotcha <brief description of the quirk>`

If invoked with no description, ask the user for one before proceeding.

## What to do

### 1. Gather context

- Read `tools/me-mod/GOTCHAS.md` so you know the existing entries and the file's format.
- Look at the recent conversation: what code did we just touch, what failed, what fixed it. Capture concrete identifiers — file names, function names, dxgui widget types, ME API calls. These belong in the entry.
- If the recent conversation has no usable context (e.g. the user is recording a known gotcha from memory), proceed using only their description, and ask 1–2 clarifying questions if the description is too thin to write a useful entry.

### 2. Check for duplicates

If the description sounds like an existing entry in `GOTCHAS.md`, surface the existing entry to the user and ask whether to:

- **Extend it** — add a note or amend a section of the existing entry.
- **Replace it** — supersede the old entry with the new one.
- **Add a new entry anyway** — these are related but distinct.

Wait for the user's choice before continuing.

### 3. Draft the entry

Format — each entry is one H2 with two or three bolded fields:

```markdown
---

## <Short title — one line, ideally a verb phrase>

**What went wrong:** <one or two sentences — what we tried, what failed, what the failure looked like>

**What works:** <the correct approach — code identifier / snippet if short>

**Why:** <optional — only when the underlying reason is knowable and non-obvious. Omit this line if you'd be guessing.>
```

Rules:

- **One H2 per entry.** No nested headings inside an entry.
- **Code identifiers in backticks** — file names, function names, dxgui widget types, ME API calls.
- **`**Why:**` is optional.** Omit it rather than guessing. Git history records when the entry was added; agents reading later will infer "why" from context if it's not authoritative.
- **Separator handling:** every entry starts with a `---` separator on its own line. The header in `GOTCHAS.md` does not end with `---`, so the first appended entry brings the first separator with it.

### 4. Show the draft

Print the drafted entry to the user. Ask:

> Append this to `tools/me-mod/GOTCHAS.md`? Or want to edit it first?

Wait for approval. If they request edits, apply them and re-show before appending.

### 5. Append

On approval, append the entry to the **bottom** of `tools/me-mod/GOTCHAS.md` (after any existing entries). Ensure exactly one blank line between the previous content and the leading `---` of the new entry. End the file with a single trailing newline.

### 6. Suggest a commit

After the append succeeds, suggest:

> Want me to commit this? Suggested message: `docs(me-mod): add gotcha — <short title>`

Do **not** run `git commit` without an explicit yes — the repo's "no silent commits" rule applies. Do not push.

## Notes

- This command is scoped to the dcs-sms repo. The target path (`tools/me-mod/GOTCHAS.md`) is hardcoded; the command is not meant to work outside this repo.
- For ME mission-table API quirks (not dxgui / runtime), the right home is `tools/me-mod/AGENTS.md` §2.7, not this file. If the gotcha is clearly a mission-table API quirk, ask the user whether they want it in `AGENTS.md` instead.
