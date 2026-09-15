package main

import (
	"flag"
	"fmt"
	"io"
	"path/filepath"

	"github.com/nielsvaes/dcs-sms/tools/internal/dcspath"
	"github.com/nielsvaes/dcs-sms/tools/internal/ui"
)

func setDCSPathFlags() (*flag.FlagSet, *struct{}) {
	return flag.NewFlagSet("set-dcs-path", flag.ContinueOnError), &struct{}{}
}

func init() {
	registerInfo("set-dcs-path", cmdInfo{
		Run:      setDCSPathCmd,
		Flags:    flagsOnly(setDCSPathFlags),
		Synopsis: "pin the DCS install folder in config (run bare to show the current one)",
		Examples: []string{
			`dcs-sms set-dcs-path`,
			`dcs-sms set-dcs-path "C:\Program Files\Eagle Dynamics\DCS World"`,
		},
	})
}

// setDCSPathCmd records the DCS install folder. Unlike the Saved Games
// folder, this one is never auto-discovered — DiscoverInstall reads the
// --dcs-path flag, the DCS_SMS_DCS_INSTALL env var, or config, and nothing
// else, because DCS install locations vary too much to guess. That makes a
// lost config.toml unrecoverable from the CLI without this command.
//
// Exit codes:
//
//	0 — shown, or saved successfully
//	2 — wrong number of arguments
//	3 — not a DCS install root, or the config could not be written
func setDCSPathCmd(args []string, stdout, stderr io.Writer) int {
	fs, _ := setDCSPathFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	rest := fs.Args()
	if len(rest) > 1 {
		fmt.Fprintln(stderr, "dcs-sms set-dcs-path: expected at most one path, got", len(rest))
		fmt.Fprintln(stderr, `  quote the path if it contains spaces: dcs-sms set-dcs-path "C:\Program Files\Eagle Dynamics\DCS World"`)
		return 2
	}

	cfg, err := configPathFn()
	if err != nil || cfg == "" {
		fmt.Fprintln(stderr, ui.For(stderr).Err("dcs-sms set-dcs-path: cannot determine the config file location"))
		return 3
	}
	if len(rest) == 0 {
		printDCSPathReport(stdout, cfg)
		return 0
	}
	return persistDCSInstall(dcspath.SanitizeUserPath(rest[0]), cfg, stdout, stderr)
}

func printDCSPathReport(stdout io.Writer, cfg string) {
	st := ui.For(stdout)
	path, err := dcspath.DiscoverInstall("", cfg)
	if err != nil || path == "" {
		fmt.Fprintln(stdout, st.Err("DCS install: not set"))
		fmt.Fprintln(stdout, "")
		fmt.Fprintln(stdout, "There is no auto-detection for this one — DCS install folders vary too much.")
		fmt.Fprintln(stdout, "Point it at the folder containing MissionEditor\\MissionEditor.lua:")
		fmt.Fprintln(stdout, `  dcs-sms set-dcs-path "C:\Program Files\Eagle Dynamics\DCS World"`)
		return
	}
	fmt.Fprintln(stdout, "DCS install:", st.Bold(path))
	if env, ok := dcspath.DiscoverFromInstallEnv(); ok {
		fmt.Fprintln(stdout, st.Warn("  (set by DCS_SMS_DCS_INSTALL="+env+", which overrides the config file)"))
		return
	}
	fmt.Fprintln(stdout, "  recorded in "+cfg)
}

// persistDCSInstall validates path as a DCS install root and records it as
// dcs_install. Shared with the interactive menu's option 5 so both writers
// agree on validation, on the stored path form, and on what they print.
//
// The path is stored with forward slashes, which is what option 5 has always
// written; both forms parse, but keeping one convention means a config
// written by either route looks the same.
func persistDCSInstall(path, cfg string, stdout, stderr io.Writer) int {
	st := ui.For(stdout)
	if path == "" {
		fmt.Fprintln(stderr, ui.For(stderr).Err("dcs-sms set-dcs-path: empty path"))
		return 3
	}
	if err := validateDCSInstallRoot(path); err != nil {
		fmt.Fprintln(stderr, ui.For(stderr).Err("dcs-sms set-dcs-path: "+err.Error()))
		return 3
	}
	stored := filepath.ToSlash(path)
	if err := dcspath.SaveInstallConfig(cfg, stored); err != nil {
		fmt.Fprintln(stderr, ui.For(stderr).Err(fmt.Sprintf("dcs-sms set-dcs-path: could not write %s: %v", cfg, err)))
		return 3
	}
	fmt.Fprintln(stdout, st.OK("Saved.")+" dcs_install = "+stored)
	fmt.Fprintln(stdout, "  recorded in "+cfg)
	if env, ok := dcspath.DiscoverFromInstallEnv(); ok && filepath.ToSlash(env) != stored {
		fmt.Fprintln(stdout)
		fmt.Fprintln(stdout, st.Warn("But DCS_SMS_DCS_INSTALL is set to "+env))
		fmt.Fprintln(stdout, st.Warn("  That environment variable is resolved before the config file, so commands"))
		fmt.Fprintln(stdout, st.Warn("  will keep using it. Clear it to pick up the folder you just pinned."))
	}
	return 0
}
