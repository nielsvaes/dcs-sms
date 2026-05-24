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
