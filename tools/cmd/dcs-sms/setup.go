package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"

	"github.com/nielsvaes/dcs-sms/tools/internal/dcspath"
	"github.com/nielsvaes/dcs-sms/tools/internal/ui"
)

type setupOpts struct {
	SkipUpdate bool
	DCSPath    string
	SavedGames string
	NoSave     bool
}

func setupFlags() (*flag.FlagSet, *setupOpts) {
	opts := &setupOpts{}
	fs := flag.NewFlagSet("setup", flag.ContinueOnError)
	fs.BoolVar(&opts.SkipUpdate, "skip-update", false, "skip the self-update step (used internally after re-exec)")
	fs.StringVar(&opts.DCSPath, "dcs-path", "", "override DCS install path")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	fs.BoolVar(&opts.NoSave, "no-config-save", false, "do not persist paths to config")
	return fs, opts
}

func init() {
	registerInfo("setup", cmdInfo{
		Run:      setupCmd,
		Flags:    flagsOnly(setupFlags),
		Synopsis: "update dcs-sms.exe, then install the ME mod and the hook in one shot",
	})
}

// setupHooks bundles the five operations setup composes. Real prod
// callers use realSetupHooks; tests stub via fakeSetupHooks.
type setupHooks interface {
	runUpdate(args []string, stdout, stderr io.Writer) (swapped bool, exitCode int)
	reExecSelf(args []string, stdout, stderr io.Writer) int
	installMeMod(args []string, stdout, stderr io.Writer) int
	installHook(args []string, stdout, stderr io.Writer) int
	// discoverDCSPath returns a DCS install path discovered from config
	// or env, or "" if none is configured. Injected so tests can keep
	// setupCmdWith deterministic regardless of host config state.
	discoverDCSPath() string
}

type realSetupHooks struct{}

func (realSetupHooks) runUpdate(args []string, stdout, stderr io.Writer) (bool, int) {
	return runUpdate(args, stdout, stderr)
}

func (realSetupHooks) discoverDCSPath() string {
	cfg, _ := dcspath.DefaultConfigPath()
	p, err := dcspath.DiscoverInstall("", cfg)
	if err != nil {
		return ""
	}
	return p
}

func (realSetupHooks) reExecSelf(args []string, stdout, stderr io.Writer) int {
	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintln(stderr, ui.For(stderr).Err(fmt.Sprintf("dcs-sms setup: locate running binary: %v", err)))
		return 3
	}
	cmd := exec.Command(exe, args...)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		fmt.Fprintln(stderr, ui.For(stderr).Err(fmt.Sprintf("dcs-sms setup: re-exec: %v", err)))
		return 3
	}
	return 0
}

func (realSetupHooks) installMeMod(args []string, stdout, stderr io.Writer) int {
	return installMeModCmd(args, stdout, stderr)
}

func (realSetupHooks) installHook(args []string, stdout, stderr io.Writer) int {
	return installHookCmd(args, stdout, stderr)
}

// setupCmd is the registered entry point. See setupCmdWith for the
// dependency-injected variant used by tests.
func setupCmd(args []string, stdout, stderr io.Writer) int {
	return setupCmdWith(args, stdout, stderr, realSetupHooks{})
}

// setupCmdWith orchestrates the three install steps with injectable
// hooks so tests can verify the flow without touching GitHub, the
// filesystem, or os/exec.
func setupCmdWith(args []string, stdout, stderr io.Writer, hooks setupHooks) int {
	fs, opts := setupFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	// Discover DCS install once and reuse for every step that needs it.
	// install-hook intentionally does NOT auto-discover, so this is the
	// single point where setup turns "no flag passed" into the path it
	// will forward to both install-me-mod and install-hook.
	if opts.DCSPath == "" {
		opts.DCSPath = hooks.discoverDCSPath()
	}

	// Step 1: update (unless skipped).
	if !opts.SkipUpdate {
		swapped, code := hooks.runUpdate(nil, stdout, stderr)
		if swapped {
			// Re-exec the new binary to do the install steps with the
			// freshly-embedded Lua tree. Forward all path flags so the
			// child sees exactly what the parent was given.
			childArgs := append([]string{"setup", "--skip-update"}, forwardReExecFlags(opts)...)
			return hooks.reExecSelf(childArgs, stdout, stderr)
		}
		if code != 0 {
			// Update reported a failure (e.g. network) but didn't swap.
			// Continue with the existing binary's embedded content per
			// the spec's degraded-mode behavior.
			fmt.Fprintln(stderr, ui.For(stderr).Warn("dcs-sms setup: update step failed; continuing with the currently-installed embedded content."))
		}
	}

	// Step 2: install ME mod. install-me-mod only knows --dcs-path /
	// --no-config-save; passing --saved-games would be a flag error.
	var meArgs []string
	if opts.DCSPath != "" {
		meArgs = append(meArgs, "--dcs-path", opts.DCSPath)
	}
	if opts.NoSave {
		meArgs = append(meArgs, "--no-config-save")
	}
	if code := hooks.installMeMod(meArgs, stdout, stderr); code != 0 {
		return code
	}

	// Step 3: install hook (also patches MissionScripting.lua when
	// --dcs-path is set or discoverable).
	var hookArgs []string
	if opts.SavedGames != "" {
		hookArgs = append(hookArgs, "--saved-games", opts.SavedGames)
	}
	if opts.DCSPath != "" {
		hookArgs = append(hookArgs, "--dcs-path", opts.DCSPath)
	}
	if opts.NoSave {
		hookArgs = append(hookArgs, "--no-config-save")
	}
	if code := hooks.installHook(hookArgs, stdout, stderr); code != 0 {
		return code
	}

	fmt.Fprintln(stdout, "")
	fmt.Fprintln(stdout, ui.For(stdout).OK("Setup complete.")+" Restart DCS, then open the Mission Editor.")
	return 0
}

// forwardReExecFlags rebuilds the path-override flags from opts so the
// re-execed setup child sees the same overrides the parent did.
func forwardReExecFlags(opts *setupOpts) []string {
	var out []string
	if opts.DCSPath != "" {
		out = append(out, "--dcs-path", opts.DCSPath)
	}
	if opts.SavedGames != "" {
		out = append(out, "--saved-games", opts.SavedGames)
	}
	if opts.NoSave {
		out = append(out, "--no-config-save")
	}
	return out
}
