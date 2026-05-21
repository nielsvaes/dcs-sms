# `dcs-sms dev-reload` — composed contributor verb

## Goal

Collapse the three-command Lua iteration loop (build the .exe, reinstall the ME mod with UAC, hot-reload the running ME) into one command: `dcs-sms dev-reload`. Source: GitHub issue [#63](https://github.com/nielsvaes/dcs-sms/issues/63).

## User value

Contributors editing `tools/me-mod/lua/dcs_sms_me/*` today run, every iteration:

```sh
cd tools && go build ./cmd/dcs-sms
powershell.exe -NoProfile -Command "Start-Process -FilePath '<repo>/tools/dcs-sms.exe' -ArgumentList 'install-me-mod' -Verb RunAs -Wait"
./dcs-sms.exe reload-me-mod
```

It's documented in [`tools/me-mod/AGENTS.md`](../../../tools/me-mod/AGENTS.md) §2.3 and copy-pasted into every handoff snapshot. After this lands, the same iteration is one command:

```sh
dcs-sms dev-reload
```

This is a developer-workflow verb. End users do not run it; it's listed in `dcs-sms --help` for contributors.

## Scope

### In scope

- New `dev-reload` subcommand in `tools/cmd/dcs-sms/dev_reload.go`.
- Behavior:
  1. Find the dcs-sms repo by walking up from cwd looking for `go.mod`. Verify the module path is `github.com/nielsvaes/dcs-sms/tools`. If not found or wrong module, exit 2 with a clear message.
  2. Run `go build ./cmd/dcs-sms` with `Dir` set to that `tools/` directory. Stream stdout/stderr to the caller. Exit 1 on build failure.
  3. Call `installMeModCmd` in-process. `install-me-mod` already prints the admin-re-launch hint to stderr when it returns `elevate.ExitCodeNeedsElevation` (5); `dev-reload` just forwards stdout/stderr and propagates the exit code unchanged.
  4. Call `reloadMeModCmd` in-process. Propagate its exit code (4 = bridge off, 2 = timeout, 1 = reload returned `ok=false`).
- Flags (all passed through to constituent steps):
  - `--dcs-path` → install-me-mod
  - `--saved-games` → reload-me-mod
  - `--timeout` → reload-me-mod (default 10s)
  - `--wait` → reload-me-mod
- `setupHooks`-style interface for testability (see Architecture).
- Registration via `registerInfo` + `flagsOnly`. Synopsis listed in `dispatch.go`'s usage block.
- `dcs-sms doc` regenerated to produce `docs/cli/dev-reload.md` and refresh `docs/cli/README.md`.
- `tools/me-mod/AGENTS.md` §2.3 updated to recommend `dev-reload` as the canonical iteration command.
- `CHANGELOG.md` entry + minor bump of `tools/me-mod/lua/dcs_sms_me/version.lua` (the me-mod track covers `dcs-sms.exe` per root [`AGENTS.md`](../../../AGENTS.md) §4).

### Out of scope

- `--skip-build` flag. `go build` is a no-op when nothing changed; the flag adds surface area without value.
- Interactive menu entry. CLI-only contributor verb; the double-click menu is for end users.
- Self-elevation. CLI users see exit code 5 and re-launch themselves. The menu's UAC-prompt path is not reused here.
- Re-installing the live-mission hook. `dev-reload` is the ME-side iteration loop; the live-mission hook rarely changes during dev. If a contributor edits the hook, they run `install-hook` manually.
- Cross-platform polish. The dev workflow is Windows-only. The Go compiles cross-platform but tests assume Windows paths.
- Removing or rewriting `install-me-mod`, `reload-me-mod`, or the standalone build step. They stay as their own verbs.

## Constraints

- Repo conventions ([`tools/cmd/dcs-sms/AGENTS.md`](../../../tools/cmd/dcs-sms/AGENTS.md) and root [`AGENTS.md`](../../../AGENTS.md)):
  - Pure handler signature: `func(args []string, stdout, stderr io.Writer) int`. No `os.Exit`.
  - No interactive prompts inside the handler.
  - Register via `registerInfo` with `flagsOnly`.
  - `cmdInfo.Synopsis` + `Flags` gate doc autogen — both must be set so the verb appears in `docs/cli/`.
- Exit code discipline (existing convention):
  - 0 success
  - 1 build failed OR reload returned `ok=false`
  - 2 bad CLI usage OR cwd not in dcs-sms repo OR reload timeout
  - 3 environment failure (cannot resolve paths, mailbox unwritable, etc.)
  - 4 gui bridge not enabled
  - 5 install needs elevation (propagated from `install-me-mod`)
- Idempotency: re-running `dev-reload` with no source changes must succeed. `go build` is a no-op when nothing changed; `install-me-mod` is already idempotent; `reload-me-mod` always succeeds if the bridge is up.
- Test discipline: stub every external dependency via the hook interface. No test may shell out to real `go`, write to a real DCS install, or talk to a real bridge.

## Decisions

These were settled in brainstorming so the implementer doesn't need to re-derive them.

1. **No `--skip-build` flag.** Per the issue's own recommendation and explicit user choice. `go build` is a no-op when the cache is warm.
2. **CLI-only, no menu entry.** Per user choice. Contributors run from a terminal in their repo checkout; the interactive menu is for end users.
3. **Exit 2 on "not in repo".** Per user choice. Treat as bad CLI usage rather than environment failure since `dev-reload` is meaningless outside the source tree.
4. **Walk up from cwd, not from `os.Executable()`.** The .exe might live in `tools/dcs-sms.exe`, in PATH, or somewhere else entirely. The right anchor is "the user has a cwd inside the dcs-sms checkout," which we detect by walking up.
5. **Verify the go.mod module path.** Walking up finds any `go.mod`; the module-path check (`github.com/nielsvaes/dcs-sms/tools`) ensures we don't accidentally match a parent Go project that happens to sit above the user's cwd.
6. **No live-mission hook reinstall.** ME iteration is the common case; the hook rarely changes during dev. If it does, `install-hook` is one extra command. Keeping `dev-reload` focused avoids re-patching `MissionScripting.lua` on every iteration.

## Architecture

`dev_reload.go` mirrors `setup.go`'s shape:

```go
type devReloadHooks interface {
    // findToolsDir walks up from cwd looking for go.mod with module path
    // "github.com/nielsvaes/dcs-sms/tools". Returns the path to the tools/
    // directory or an error if not found.
    findToolsDir(cwd string) (string, error)

    // runBuild executes `go build ./cmd/dcs-sms` with Dir=toolsDir,
    // streaming stdout/stderr to the writers. Returns the exit code.
    runBuild(toolsDir string, stdout, stderr io.Writer) int

    // installMeMod calls installMeModCmd in-process.
    installMeMod(args []string, stdout, stderr io.Writer) int

    // reloadMeMod calls reloadMeModCmd in-process.
    reloadMeMod(args []string, stdout, stderr io.Writer) int
}

type realDevReloadHooks struct{}
// ... thin impls that wrap the real calls ...

func devReloadCmd(args []string, stdout, stderr io.Writer) int {
    return devReloadCmdWith(args, stdout, stderr, realDevReloadHooks{})
}

func devReloadCmdWith(args []string, stdout, stderr io.Writer, hooks devReloadHooks) int {
    // 1. Parse flags
    // 2. Find tools dir (exit 2 if not in repo)
    // 3. Build (exit 1 on failure)
    // 4. Install (propagate exit code 5 with hint, else any non-zero)
    // 5. Reload (propagate exit code)
}
```

`findToolsDir` opens each candidate `go.mod` and reads the first non-blank line. If it matches `module github.com/nielsvaes/dcs-sms/tools` exactly, the directory containing that go.mod is the answer. If the walk reaches the filesystem root without a match, return an error naming cwd.

`runBuild` uses `exec.Command("go", "build", "./cmd/dcs-sms")`, sets `cmd.Dir = toolsDir`, wires `cmd.Stdout = stdout` and `cmd.Stderr = stderr`, and returns `cmd.Run()`'s exit code (1 on any error).

`installMeMod` and `reloadMeMod` in `realDevReloadHooks` simply call the existing `installMeModCmd(args, stdout, stderr)` and `reloadMeModCmd(args, stdout, stderr)`.

`devReloadCmdWith` orchestrates: parse flags, build per-step argument slices (forwarding `--dcs-path` to install-me-mod and `--saved-games` / `--timeout` / `--wait` to reload-me-mod), and short-circuits on any non-zero exit code.

## Flags + exit codes

```
dcs-sms dev-reload [flags]

build the .exe, reinstall the ME mod, and hot-reload it in one shot
(developer workflow; requires the dcs-sms repo checkout)

Flags:
  --dcs-path       override DCS install path (forwarded to install-me-mod)
  --saved-games    override Saved Games path (forwarded to reload-me-mod)
  --timeout        reload timeout (default 10s, forwarded to reload-me-mod)
  --wait           if bridge isn't ready, poll until it is (forwarded to reload-me-mod)
```

Exit codes:

| Code | Meaning |
|---|---|
| 0 | All three steps succeeded. |
| 1 | `go build` failed, OR `reload-me-mod` returned `ok=false`. |
| 2 | Bad CLI usage (unknown flag), OR cwd not inside the dcs-sms repo, OR reload timed out. |
| 3 | Environment failure (can't resolve Saved Games, mailbox unwritable, etc.). |
| 4 | Gui bridge isn't enabled (`DCS-SMS → External execution: OFF`). User needs to toggle it on. |
| 5 | Install step needs admin elevation. Re-run from an admin terminal. |

When exit 5 is returned, print the same hint `setup` prints: re-run from an admin terminal, or use the interactive menu's UAC prompt.

## Documentation + AGENTS.md

After implementation:

1. Run `cd tools && go build ./cmd/dcs-sms && ./dcs-sms doc` to regenerate `docs/cli/dev-reload.md` and refresh `docs/cli/README.md`. Commit those changes in the same commit as the code.
2. Update [`tools/me-mod/AGENTS.md`](../../../tools/me-mod/AGENTS.md) §2.3 ("The embed workflow"). Replace the three-step recipe's emphasis: lead with `dcs-sms dev-reload` as the canonical iteration command, keep the three-step recipe underneath as "what it does under the hood" for readers who want to debug the chain.
3. Add a CHANGELOG entry under the next `me-mod-vX.Y.Z` heading naming `dev-reload`.
4. Bump `tools/me-mod/lua/dcs_sms_me/version.lua` to the next minor (new contributor-facing feature on the me-mod track per root [`AGENTS.md`](../../../AGENTS.md) §4).

## Testing

`tools/cmd/dcs-sms/dev_reload_test.go` follows the dependency-injection style of `setup_test.go`. Tests stub `devReloadHooks` entirely; no real `go`, filesystem, or bridge calls.

| Test | Setup | Assertion |
|---|---|---|
| `TestDevReloadHappyPath` | All hooks return 0 | Each hook called once in order; exit 0; flags forwarded correctly |
| `TestDevReloadStopsOnBuildFailure` | `runBuild` returns 1 | `installMeMod` and `reloadMeMod` NOT called; exit 1 |
| `TestDevReloadStopsOnInstallFailure` | `installMeMod` returns 1 | `reloadMeMod` NOT called; exit 1 |
| `TestDevReloadPropagatesElevation` | `installMeMod` returns 5 (stub also writes a hint to stderr) | exit 5 propagates; the stub's stderr is forwarded through |
| `TestDevReloadNotInRepo` | `findToolsDir` returns error | `runBuild` NOT called; exit 2; stderr names the missing condition |
| `TestDevReloadForwardsDCSPath` | Pass `--dcs-path D:\DCS` | `installMeMod` receives `--dcs-path D:\DCS`; `reloadMeMod` does NOT |
| `TestDevReloadForwardsReloadFlags` | Pass `--saved-games X --timeout 5s --wait` | `reloadMeMod` receives those three flags; `installMeMod` does NOT |
| `TestDevReloadPropagatesReloadFailure` | `reloadMeMod` returns 4 | exit 4 (bridge off) propagates |

Additionally, a small unit test on `findToolsDir` itself can use `t.TempDir()` to stand up a fake `go.mod` tree and verify the walk + module-name check work end-to-end. That test does not need the hook interface — `findToolsDir` is a pure function over the filesystem and is small enough to test directly.

## Rollout

This is a contributor-only verb on a track that already ships frequent minor bumps. Single PR:

1. Add `dev_reload.go` + `dev_reload_test.go`.
2. Add line to `dispatch.go`'s usage block (alphabetically near `setup`).
3. Run `dcs-sms doc`, commit `docs/cli/dev-reload.md` + updated `docs/cli/README.md`.
4. Edit `tools/me-mod/AGENTS.md` §2.3.
5. CHANGELOG entry + `version.lua` bump.

No release-gate smoke needed — `dev-reload` is exercised every time a contributor uses it, and its tests cover the orchestration.
