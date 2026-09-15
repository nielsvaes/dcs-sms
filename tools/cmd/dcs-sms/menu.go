package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/nielsvaes/dcs-sms/tools/internal/dcspath"
	"github.com/nielsvaes/dcs-sms/tools/internal/elevate"
	"github.com/nielsvaes/dcs-sms/tools/internal/ui"
)

// menuActions holds the subcommand handlers the menu invokes. Exposed
// as a struct so tests can stub them without touching real DCS install
// paths or AI-agent config dirs.
type menuActions struct {
	setup            commandFunc
	teardown         commandFunc
	installAISkill   commandFunc
	uninstallAISkill commandFunc
}

// menuDeps bundles every external dependency the menu needs.
type menuDeps struct {
	actions    menuActions
	configPath string                    // empty → resolved from dcspath.DefaultConfigPath()
	reExec     func(args []string) error // nil → real elevate.ReExecElevated
}

func defaultMenuDeps() menuDeps {
	cfg, _ := dcspath.DefaultConfigPath()
	return menuDeps{
		actions: menuActions{
			setup:            setupCmd,
			teardown:         teardownCmd,
			installAISkill:   installAISkillCmd,
			uninstallAISkill: uninstallAISkillCmd,
		},
		configPath: cfg,
		reExec:     elevate.ReExecElevated,
	}
}

// runInteractiveMenu drives the no-args double-click menu. Reads choices
// from stdin, dispatches options 1-6, and exits on `q`.
//
// Actions return to the menu when they finish, so a user can install the mod
// and then install the AI skill without relaunching the exe. The exception is
// a successful elevation re-exec, where an elevated child takes over in a new
// window and this process must close.
//
// The exit code is the last non-zero code any action returned, so looping
// never hides a failure. Three invalid inputs in a row return exit code 2 to
// guard against a closed stdin.
func runInteractiveMenu(stdin io.Reader, stdout, stderr io.Writer) int {
	return runInteractiveMenuWith(stdin, stdout, stderr, defaultMenuDeps())
}

func runInteractiveMenuWith(stdin io.Reader, stdout, stderr io.Writer, deps menuDeps) int {
	if deps.reExec == nil {
		deps.reExec = elevate.ReExecElevated
	}
	reader := bufio.NewReader(stdin)
	invalidStreak := 0
	const maxInvalid = 3
	// lastCode remembers the worst outcome so far; ranAction distinguishes
	// "stdin closed before anything happened" (a broken pipe, exit 2) from
	// "stdin ran out after the user did some work" (a normal end of session).
	lastCode := 0
	ranAction := false

	for {
		printMenuBanner(stdout, deps)
		fmt.Fprint(stdout, "Choose [1/2/3/4/5/6/q]: ")
		line, err := reader.ReadString('\n')
		if err != nil && line == "" {
			if ranAction {
				return lastCode
			}
			fmt.Fprintln(stderr, "dcs-sms: no input received")
			return 2
		}
		choice := strings.ToLower(strings.TrimSpace(line))
		// record folds an action's result into the session state and reports
		// whether the menu should stop looping.
		record := func(code int, exit bool) bool {
			ranAction = true
			if code != 0 {
				lastCode = code
			}
			invalidStreak = 0
			return exit
		}

		switch choice {
		case "q", "quit", "exit":
			return lastCode
		case "1":
			if record(runActionWithElevation(reader, stdout, stderr, deps, deps.actions.setup,
				[]string{"setup", "--skip-update"})) {
				return lastCode
			}
			continue
		case "2":
			if record(runActionWithElevation(reader, stdout, stderr, deps, deps.actions.teardown,
				[]string{"teardown"})) {
				return lastCode
			}
			continue
		case "3":
			if record(runActionAndPause(reader, stdout, stderr, func(_ []string, so, se io.Writer) int {
				return deps.actions.installAISkill([]string{"--agent", "all"}, so, se)
			})) {
				return lastCode
			}
			continue
		case "4":
			if record(runActionAndPause(reader, stdout, stderr, func(_ []string, so, se io.Writer) int {
				return deps.actions.uninstallAISkill([]string{"--agent", "all"}, so, se)
			})) {
				return lastCode
			}
			continue
		case "5":
			promptAndSaveDCSPath(reader, stdout, stderr, deps.configPath)
			invalidStreak = 0
			continue
		case "6":
			promptAndSaveSavedGames(reader, stdout, stderr, deps.configPath)
			invalidStreak = 0
			continue
		default:
			invalidStreak++
			if invalidStreak >= maxInvalid {
				fmt.Fprintln(stderr, "dcs-sms: too many invalid inputs")
				return 2
			}
			fmt.Fprintf(stdout, "Unknown choice %q.\n", choice)
		}
	}
}

// runActionWithElevation calls action and pauses for Enter. If action
// returns elevate.ExitCodeNeedsElevation, the menu prompts the user
// y/N to re-launch as admin via deps.reExec; on yes, it spawns the
// elevated child with reExecArgs and exits.
//
// Caveat: env vars like DCS_SMS_SAVED_GAMES / DCS_SMS_DCS_INSTALL are
// NOT inherited by the elevated child (Windows UAC spawns a fresh
// cmd.exe process with no env inheritance from this process). The
// child relies on its own config-file lookup. Users who need a path
// other than what's in `%AppData%\dcs-sms\config.toml` should set it
// via the menu's "Set DCS install path" option (which writes config)
// before triggering the elevation prompt — or run `dcs-sms setup`
// directly from an already-elevated terminal.
func runActionWithElevation(reader *bufio.Reader, stdout, stderr io.Writer, deps menuDeps, action commandFunc, reExecArgs []string) (int, bool) {
	st := ui.For(stdout)
	code := action(nil, stdout, stderr)
	if code == elevate.ExitCodeNeedsElevation {
		if promptElevationYesNo(reader, stdout) {
			if err := deps.reExec(reExecArgs); err != nil {
				fmt.Fprintf(stderr, "%s\n", ui.For(stderr).Err(fmt.Sprintf("dcs-sms: could not re-launch as admin: %v", err)))
				pauseForMenu(reader, stdout)
				return 3, false
			}
			fmt.Fprintln(stdout)
			fmt.Fprintln(stdout, st.OK("Elevated install started in a new window. This window will close."))
			// The elevated child owns the install from here; this window must
			// close rather than drop back to a menu the user can no longer use.
			return 0, true
		}
		fmt.Fprintln(stdout)
		fmt.Fprintln(stdout, st.Warn("Skipped. Re-run dcs-sms.exe from an admin terminal if you want to install."))
	}
	// Pause unconditionally so the user can read the action's output (or
	// the "Skipped" message above) before the banner scrolls it away.
	pauseForMenu(reader, stdout)
	return code, false
}

func promptElevationYesNo(reader *bufio.Reader, stdout io.Writer) bool {
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, "This operation needs admin permission (DCS install dir is not writable).")
	fmt.Fprint(stdout, "Re-launch with admin permission? [y/N]: ")
	line, _ := reader.ReadString('\n')
	ans := strings.ToLower(strings.TrimSpace(line))
	return ans == "y" || ans == "yes"
}

func runActionAndPause(reader *bufio.Reader, stdout, stderr io.Writer, action commandFunc) (int, bool) {
	code := action(nil, stdout, stderr)
	pauseForMenu(reader, stdout)
	return code, false
}

// pauseForMenu holds the output on screen until the user acknowledges it.
func pauseForMenu(reader *bufio.Reader, stdout io.Writer) {
	fmt.Fprintln(stdout)
	fmt.Fprint(stdout, "Press Enter to return to the menu...")
	_, _ = reader.ReadString('\n')
}

func printMenuBanner(w io.Writer, deps menuDeps) {
	st := ui.For(w)
	fmt.Fprintln(w)
	fmt.Fprintf(w, "DCS-SMS  v%s\n", version)
	fmt.Fprintln(w)
	fmt.Fprintln(w, "  "+dcsInstallLine(deps, st))
	fmt.Fprintln(w, "  "+savedGamesLine(deps, st))
	fmt.Fprintln(w)
	fmt.Fprintln(w, "  1. Install or update DCS-SMS (mod + hook + .exe)")
	fmt.Fprintln(w, "     └─ Not sure what to pick? Pick this. It makes sure you have the latest of everything.")
	fmt.Fprintln(w, "  2. Uninstall DCS-SMS (mod + hook)")
	fmt.Fprintln(w, "  3. Install AI agent skill (Claude + Codex + Gemini)")
	fmt.Fprintln(w, "  4. Uninstall AI agent skill (Claude + Codex + Gemini)")
	fmt.Fprintln(w, "  5. Set DCS install path manually")
	fmt.Fprintln(w, "  6. Set Saved Games folder manually")
	fmt.Fprintln(w, "  q. Quit")
	fmt.Fprintln(w)
}

func dcsInstallLine(deps menuDeps, st ui.Styler) string {
	path, err := dcspath.DiscoverInstall("", deps.configPath)
	if err != nil || path == "" {
		return "DCS install: " + st.Err("not detected — pick option 5 to set it")
	}
	return "DCS install: " + st.OK(path)
}

// savedGamesLine shows which Saved Games folder every command will use, and
// warns when others exist beside it. A user with a leftover `DCS` folder next
// to the `DCS.openbeta` they actually fly gets the wrong one auto-picked, and
// every bridge command then fails with an unhelpful "hook not found" — this
// line is where that becomes visible.
func savedGamesLine(deps menuDeps, st ui.Styler) string {
	path, err := resolveRootFor(deps.configPath)
	if err != nil || path == "" {
		return "Saved Games: " + st.Err("not detected — pick option 6 to set it")
	}
	line := "Saved Games: " + st.OK(path)
	variants, ok := listVariantsFn()
	if !ok {
		return line
	}
	others := 0
	for _, v := range variants {
		if !sameDir(v, path) {
			others++
		}
	}
	if others == 0 {
		return line
	}
	noun := "others"
	if others == 1 {
		noun = "other"
	}
	return line + st.Warn(fmt.Sprintf("  (%d %s found — option 6)", others, noun))
}

const maxPathAttempts = 2

// promptAndSaveDCSPath asks the user to paste their DCS install folder.
func promptAndSaveDCSPath(reader *bufio.Reader, stdout, stderr io.Writer, configPath string) {
	for attempt := 0; attempt < maxPathAttempts; attempt++ {
		fmt.Fprintln(stdout)
		fmt.Fprintln(stdout, `Paste your DCS install folder (the one containing MissionEditor\MissionEditor.lua).`)
		fmt.Fprintln(stdout, `Quotes are fine, they'll be stripped.`)
		fmt.Fprint(stdout, "> ")
		line, err := reader.ReadString('\n')
		if err != nil && line == "" {
			fmt.Fprintln(stderr, "dcs-sms: no path entered")
			return
		}
		path := dcspath.SanitizeUserPath(line)
		if path == "" {
			fmt.Fprintln(stdout, "Empty path — try again.")
			continue
		}
		// Validate here rather than inside persistDCSInstall so a typo can be
		// retried without leaving the prompt.
		if err := validateDCSInstallRoot(path); err != nil {
			fmt.Fprintln(stdout, ui.For(stdout).Err(err.Error()))
			continue
		}
		if configPath == "" {
			configPath, _ = configPathFn()
		}
		if configPath == "" {
			fmt.Fprintln(stderr, ui.For(stderr).Err("dcs-sms: cannot determine config file location; not saving"))
			return
		}
		persistDCSInstall(path, configPath, stdout, stderr)
		return
	}
	fmt.Fprintln(stdout, "Returning to menu without saving.")
}

// promptAndSaveSavedGames lets the user pick which Saved Games folder to
// pin. Folders found on disk are offered as a numbered list annotated with
// what is installed in each, because "which one is DCS actually writing to"
// is the question the user is really trying to answer. A pasted path is
// accepted too, for installs that live somewhere unusual.
func promptAndSaveSavedGames(reader *bufio.Reader, stdout, stderr io.Writer, configPath string) {
	st := ui.For(stdout)
	if configPath == "" {
		configPath, _ = configPathFn()
	}
	current, _ := resolveRootFor(configPath)
	variants, _ := listVariantsFn()

	fmt.Fprintln(stdout)
	if len(variants) == 0 {
		fmt.Fprintln(stdout, st.Warn("No DCS folders found under Saved Games."))
	} else {
		fmt.Fprintln(stdout, "DCS folders found in Saved Games:")
		for i, line := range variantLines(variants, current, st) {
			fmt.Fprintf(stdout, "  %d. %s\n", i+1, line)
		}
		fmt.Fprintf(stdout, "  %d. Enter a different path\n", len(variants)+1)
	}
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, "Pick a number, paste a folder, or press Enter to go back.")
	fmt.Fprint(stdout, "> ")

	line, err := reader.ReadString('\n')
	if err != nil && line == "" {
		return
	}
	choice := strings.TrimSpace(line)
	if choice == "" {
		fmt.Fprintln(stdout, "Nothing changed.")
		return
	}

	if n, convErr := strconv.Atoi(choice); convErr == nil {
		switch {
		case n >= 1 && n <= len(variants):
			saveSavedGamesPath(variants[n-1], configPath, stdout, stderr)
			return
		case n == len(variants)+1:
			promptAndSaveSavedGamesPath(reader, stdout, stderr, configPath)
			return
		default:
			fmt.Fprintln(stdout, st.Warn(fmt.Sprintf("No entry %d in that list. Nothing changed.", n)))
			return
		}
	}
	// Not a number — treat it as a pasted path.
	saveSavedGamesPath(dcspath.SanitizeUserPath(choice), configPath, stdout, stderr)
}

// promptAndSaveSavedGamesPath asks for a folder by hand, for the "Enter a
// different path" branch of the picker.
func promptAndSaveSavedGamesPath(reader *bufio.Reader, stdout, stderr io.Writer, configPath string) {
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, `Paste your DCS Saved Games folder (the one containing Config and Missions).`)
	fmt.Fprintln(stdout, `Quotes are fine, they'll be stripped.`)
	fmt.Fprint(stdout, "> ")
	line, err := reader.ReadString('\n')
	if err != nil && line == "" {
		return
	}
	path := dcspath.SanitizeUserPath(line)
	if path == "" {
		fmt.Fprintln(stdout, "Nothing entered. Nothing changed.")
		return
	}
	saveSavedGamesPath(path, configPath, stdout, stderr)
}

func validateDCSInstallRoot(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("path does not exist: %s", path)
		}
		return fmt.Errorf("could not stat %s: %v", path, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("not a directory: %s", path)
	}
	meFile := filepath.Join(path, "MissionEditor", "MissionEditor.lua")
	if _, err := os.Stat(meFile); err != nil {
		return fmt.Errorf("MissionEditor.lua not found at %s — is this really the DCS install root?", meFile)
	}
	return nil
}
