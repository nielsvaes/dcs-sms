package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/nielsvaes/dcs-sms/tools/internal/dcspath"
	"github.com/nielsvaes/dcs-sms/tools/internal/ui"
)

// Seams so tests can redirect the config file and the Saved Games scan
// without touching the real %AppData%\dcs-sms\config.toml or the host's
// Saved Games folder.
var (
	configPathFn   = dcspath.DefaultConfigPath
	listVariantsFn = dcspath.ListVariantsDefault
)

func setSavedGamesFlags() (*flag.FlagSet, *struct{}) {
	return flag.NewFlagSet("set-saved-games", flag.ContinueOnError), &struct{}{}
}

func init() {
	registerInfo("set-saved-games", cmdInfo{
		Run:      setSavedGamesCmd,
		Flags:    flagsOnly(setSavedGamesFlags),
		Synopsis: "pin the DCS Saved Games folder in config (run bare to list the folders found)",
		Examples: []string{
			`dcs-sms set-saved-games`,
			`dcs-sms set-saved-games "C:\Users\you\Saved Games\DCS.openbeta"`,
		},
	})
}

// setSavedGamesCmd records which Saved Games folder every other command
// should use. Exit codes:
//
//	0 — listed, or saved successfully
//	2 — wrong number of arguments
//	3 — the path does not exist, or the config could not be written
func setSavedGamesCmd(args []string, stdout, stderr io.Writer) int {
	fs, _ := setSavedGamesFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	rest := fs.Args()
	if len(rest) > 1 {
		fmt.Fprintln(stderr, "dcs-sms set-saved-games: expected at most one path, got", len(rest))
		fmt.Fprintln(stderr, `  quote the path if it contains spaces: dcs-sms set-saved-games "C:\...\DCS.openbeta"`)
		return 2
	}
	if len(rest) == 0 {
		printSavedGamesReport(stdout)
		return 0
	}
	cfg, err := configPathFn()
	if err != nil || cfg == "" {
		fmt.Fprintln(stderr, ui.For(stderr).Err("dcs-sms set-saved-games: cannot determine the config file location"))
		return 3
	}
	return saveSavedGamesPath(dcspath.SanitizeUserPath(rest[0]), cfg, stdout, stderr)
}

// printSavedGamesReport shows the folder in use and every other variant
// found, so a user whose heartbeat is missing can see the mismatch.
func printSavedGamesReport(stdout io.Writer) {
	st := ui.For(stdout)
	current, err := resolveRootFor("")
	if err != nil {
		fmt.Fprintln(stdout, st.Err("in use: none — no DCS folder found in Saved Games"))
	} else {
		fmt.Fprintln(stdout, "in use:", st.Bold(current))
		if _, ok := dcspath.DiscoverFromEnv(); ok {
			fmt.Fprintln(stdout, st.Warn("  (set by DCS_SMS_SAVED_GAMES, which overrides the config file)"))
		}
	}
	variants, ok := listVariantsFn()
	if !ok || len(variants) == 0 {
		fmt.Fprintln(stdout)
		fmt.Fprintln(stdout, st.Warn("No DCS folders found under Saved Games."))
		fmt.Fprintln(stdout, `Pass the folder explicitly: dcs-sms set-saved-games "D:\path\to\DCS.openbeta"`)
		return
	}
	fmt.Fprintln(stdout)
	fmt.Fprintln(stdout, "DCS folders found in Saved Games:")
	for _, line := range variantLines(variants, current, st) {
		fmt.Fprintln(stdout, "  "+line)
	}
	fmt.Fprintln(stdout)
	if alt, ok := betterCandidate(variants, current); ok {
		fmt.Fprintln(stdout, st.Warn("That looks like the wrong one. Pin the live folder with:"))
		fmt.Fprintf(stdout, "  dcs-sms set-saved-games \"%s\"\n", alt)
		return
	}
	fmt.Fprintln(stdout, "To pin a different folder:")
	fmt.Fprintln(stdout, `  dcs-sms set-saved-games "<path to the folder>"`)
}

// saveSavedGamesPath validates path and records it as saved_games in the
// config file at cfg. Callers pass the config path explicitly so the menu can
// use the one injected through menuDeps rather than the process-wide default.
//
// Like persistDCSInstall its messages say plain "dcs-sms:", because menu
// option 6 uses it and that user never typed "set-saved-games". The
// command-level messages in setSavedGamesCmd keep the command name.
func saveSavedGamesPath(path, cfg string, stdout, stderr io.Writer) int {
	st := ui.For(stdout)
	if path == "" {
		fmt.Fprintln(stderr, ui.For(stderr).Err("dcs-sms: empty path"))
		return 3
	}
	info, err := os.Stat(path)
	if err != nil || !info.IsDir() {
		fmt.Fprintf(stderr, "%s\n", ui.For(stderr).Err("dcs-sms: not an existing folder: "+path))
		return 3
	}
	if !looksLikeSavedGamesDCS(path) {
		fmt.Fprintln(stdout, st.Warn("Warning: "+path+" doesn't look like a DCS Saved Games folder"))
		fmt.Fprintln(stdout, st.Warn("  (expected to find Config, Logs, Missions or Scripts inside). Saving it anyway."))
	}
	if cfg == "" {
		fmt.Fprintln(stderr, ui.For(stderr).Err("dcs-sms: cannot determine the config file location"))
		return 3
	}
	if err := dcspath.SaveConfig(cfg, path); err != nil {
		fmt.Fprintf(stderr, "%s\n", ui.For(stderr).Err(fmt.Sprintf("dcs-sms: could not write %s: %v", cfg, err)))
		return 3
	}
	fmt.Fprintln(stdout, st.OK("Saved.")+" saved_games = "+path)
	fmt.Fprintln(stdout, "  recorded in "+cfg)
	fmt.Fprintln(stdout)
	if env, shadowed := envOverrideNote(path); shadowed {
		fmt.Fprintln(stdout, st.Warn("But DCS_SMS_SAVED_GAMES is set to "+env))
		fmt.Fprintln(stdout, st.Warn("  That environment variable is resolved before the config file, so commands"))
		fmt.Fprintln(stdout, st.Warn("  will keep using it. Clear it to pick up the folder you just pinned."))
		fmt.Fprintln(stdout)
	}
	if !inspectVariant(path).HasHook {
		fmt.Fprintln(stdout, st.Warn("No hook installed in that folder yet — run `dcs-sms setup` to install it."))
		return 0
	}
	fmt.Fprintln(stdout, "Start DCS and run `dcs-sms status` to confirm the hook is alive.")
	return 0
}

// looksLikeSavedGamesDCS checks for the subfolders DCS itself creates. Used
// only to warn — an unusual-but-valid setup must still be configurable.
func looksLikeSavedGamesDCS(path string) bool {
	for _, sub := range []string{"Config", "Logs", "Missions", "Scripts"} {
		if info, err := os.Stat(filepath.Join(path, sub)); err == nil && info.IsDir() {
			return true
		}
	}
	return false
}
