package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/nielsvaes/dcs-sms/tools/internal/dcspath"
	"github.com/nielsvaes/dcs-sms/tools/internal/ui"
	hookpkg "github.com/nielsvaes/dcs-sms/tools/lua"
)

type installHookOpts struct {
	SavedGames string
	DCSPath    string
	NoSave     bool
}

func installHookFlags() (*flag.FlagSet, *installHookOpts) {
	opts := &installHookOpts{}
	fs := flag.NewFlagSet("install-hook", flag.ContinueOnError)
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	fs.StringVar(&opts.DCSPath, "dcs-path", "", "DCS install path (used to patch MissionScripting.lua)")
	fs.BoolVar(&opts.NoSave, "no-config-save", false, "do not persist --saved-games to config")
	return fs, opts
}

func init() {
	registerInfo("install-hook", cmdInfo{
		Run:      installHookCmd,
		Flags:    flagsOnly(installHookFlags),
		Synopsis: "install/update the Lua hook + patch MissionScripting.lua to allow it",
	})
}

func installHookCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := installHookFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	root, err := resolveRoot(opts.SavedGames)
	if err != nil {
		fmt.Fprintln(stderr, ui.For(stderr).Err("dcs-sms install-hook:"), err)
		return 3
	}
	hooksDir := filepath.Join(root, "Scripts", "Hooks")
	if err := os.MkdirAll(hooksDir, 0o755); err != nil {
		fmt.Fprintln(stderr, ui.For(stderr).Err("dcs-sms install-hook: mkdir:"), err)
		return 3
	}
	dst := filepath.Join(hooksDir, "dcs-sms-hook.lua")
	if err := os.WriteFile(dst, hookpkg.Source, 0o644); err != nil {
		fmt.Fprintln(stderr, ui.For(stderr).Err("dcs-sms install-hook: write:"), err)
		return 3
	}
	style := ui.For(stdout)
	fmt.Fprintf(stdout, "%s %s (%d bytes)\n", style.OK("installed hook to"), dst, len(hookpkg.Source))

	if !opts.NoSave {
		if cfg, _ := dcspath.DefaultConfigPath(); cfg != "" {
			if err := dcspath.SaveConfig(cfg, root); err != nil {
				fmt.Fprintln(stderr, ui.For(stderr).Warn("dcs-sms install-hook: warning: could not save config:"), err)
			} else {
				fmt.Fprintf(stdout, "saved saved_games = %q to %s\n", root, cfg)
			}
		}
	}

	sanitized := false
	if opts.DCSPath != "" {
		sanitized = tryPatchMissionScripting(opts.DCSPath, stdout, stderr)
	} else {
		fmt.Fprintln(stdout, "")
		fmt.Fprintln(stdout, style.Warn("Skipping MissionScripting.lua patch: --dcs-path not set."))
		fmt.Fprintln(stdout, "  Use `dcs-sms setup` (or pass --dcs-path here) to patch it automatically.")
	}

	fmt.Fprintln(stdout, "")
	fmt.Fprintln(stdout, "Next steps:")
	if !sanitized {
		fmt.Fprintln(stdout, "  1. In your DCS install dir, edit Scripts/MissionScripting.lua and comment out")
		fmt.Fprintln(stdout, "     the sanitizeModule('os'), ('io'), and ('lfs') lines so the hook can talk to")
		fmt.Fprintln(stdout, "     the mission environment.")
		fmt.Fprintln(stdout, "  2. Start DCS and load any mission.")
		fmt.Fprintln(stdout, "  3. Run `dcs-sms status` to confirm the hook is alive.")
	} else {
		fmt.Fprintln(stdout, "  1. Start DCS and load any mission.")
		fmt.Fprintln(stdout, "  2. Run `dcs-sms status` to confirm the hook is alive.")
	}
	return 0
}

// tryPatchMissionScripting comments out the three sandboxing calls in
// <dcsInstall>/Scripts/MissionScripting.lua. Returns true if the file is
// now sanitized (whether by this call or a prior idempotent run) so the
// caller can shorten the next-steps message.
//
// dcsInstall must be a non-empty, explicitly-supplied path. install-hook
// does NOT auto-discover the DCS install — that responsibility lives in
// `setup`, which discovers once and forwards via --dcs-path. This keeps
// install-hook's behavior predictable for direct CLI use and tests:
// no --dcs-path = no file system access against an install dir.
//
// Best-effort: any failure (file missing, write error) degrades to a
// printed warning and returns false. install-hook itself stays exit-0,
// since the hook file was successfully written.
func tryPatchMissionScripting(dcsInstall string, stdout, stderr io.Writer) bool {
	msPath := filepath.Join(dcsInstall, "Scripts", "MissionScripting.lua")
	if _, err := os.Stat(msPath); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			fmt.Fprintf(stdout, "Skipping MissionScripting.lua patch: %s not found.\n", msPath)
		} else {
			fmt.Fprintf(stderr, "dcs-sms install-hook: stat %s: %v\n", msPath, err)
		}
		return false
	}

	result, err := patchMissionScripting(msPath)
	if err != nil {
		fmt.Fprintf(stderr, "dcs-sms install-hook: patch %s: %v\n", msPath, err)
		return false
	}
	if len(result.Changed) == 0 {
		fmt.Fprintf(stdout, "%s already sanitized for dcs-sms\n", msPath)
	} else {
		fmt.Fprintf(stdout, "patched %s: commented out sanitizeModule(%s)\n",
			msPath, strings.Join(result.Changed, ", "))
	}
	return true
}
