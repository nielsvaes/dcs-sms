package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type devReloadOpts struct {
	DCSPath    string
	SavedGames string
	Timeout    time.Duration
	Wait       bool
}

func devReloadFlags() (*flag.FlagSet, *devReloadOpts) {
	opts := &devReloadOpts{}
	fs := flag.NewFlagSet("dev-reload", flag.ContinueOnError)
	fs.StringVar(&opts.DCSPath, "dcs-path", "", "override DCS install path (forwarded to install-me-mod)")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path (forwarded to reload-me-mod)")
	fs.DurationVar(&opts.Timeout, "timeout", 10*time.Second, "reload timeout (forwarded to reload-me-mod)")
	fs.BoolVar(&opts.Wait, "wait", false, "if bridge isn't ready, poll until it is (forwarded to reload-me-mod)")
	return fs, opts
}

func init() {
	registerInfo("dev-reload", cmdInfo{
		Run:      devReloadCmd,
		Flags:    flagsOnly(devReloadFlags),
		Synopsis: "build the .exe, reinstall the ME mod, and hot-reload it in one shot (contributor workflow)",
	})
}

// devReloadHooks bundles every external operation dev-reload needs.
// Real callers use realDevReloadHooks; tests stub via fakeDevReloadHooks.
type devReloadHooks interface {
	// findToolsDir walks up from cwd looking for a go.mod whose module
	// path is "github.com/nielsvaes/dcs-sms/tools". Returns the directory
	// containing that go.mod, or an error if no matching go.mod was found.
	findToolsDir(cwd string) (string, error)

	// runBuild executes `go build ./cmd/dcs-sms` from toolsDir, streaming
	// stdout/stderr to the writers. Returns the exit code (0 on success).
	runBuild(toolsDir string, stdout, stderr io.Writer) int

	// installMeMod calls installMeModCmd in-process.
	installMeMod(args []string, stdout, stderr io.Writer) int

	// reloadMeMod calls reloadMeModCmd in-process.
	reloadMeMod(args []string, stdout, stderr io.Writer) int
}

type realDevReloadHooks struct{}

func (realDevReloadHooks) findToolsDir(cwd string) (string, error) {
	return findToolsDirImpl(cwd)
}

func (realDevReloadHooks) runBuild(toolsDir string, stdout, stderr io.Writer) int {
	cmd := exec.Command("go", "build", "./cmd/dcs-sms")
	cmd.Dir = toolsDir
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		fmt.Fprintf(stderr, "dcs-sms dev-reload: go build: %v\n", err)
		return 1
	}
	return 0
}

func (realDevReloadHooks) installMeMod(args []string, stdout, stderr io.Writer) int {
	return installMeModCmd(args, stdout, stderr)
}

func (realDevReloadHooks) reloadMeMod(args []string, stdout, stderr io.Writer) int {
	return reloadMeModCmd(args, stdout, stderr)
}

// findToolsDirImpl walks up from start looking for a go.mod whose first
// non-blank line is "module github.com/nielsvaes/dcs-sms/tools". On match,
// returns the directory containing that go.mod. Returns an error naming
// start if the walk reaches the filesystem root without a match.
func findToolsDirImpl(start string) (string, error) {
	const wantModule = "module github.com/nielsvaes/dcs-sms/tools"
	dir := start
	for {
		modPath := filepath.Join(dir, "go.mod")
		if data, err := os.ReadFile(modPath); err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				trimmed := strings.TrimSpace(line)
				if trimmed == "" {
					continue
				}
				if trimmed == wantModule {
					return dir, nil
				}
				break // first non-blank line wasn't ours; not the right go.mod
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("not inside the dcs-sms repo (no go.mod with module %q found walking up from %s)", "github.com/nielsvaes/dcs-sms/tools", start)
		}
		dir = parent
	}
}

func devReloadCmd(args []string, stdout, stderr io.Writer) int {
	return devReloadCmdWith(args, stdout, stderr, realDevReloadHooks{})
}

func devReloadCmdWith(args []string, stdout, stderr io.Writer, hooks devReloadHooks) int {
	fs, opts := devReloadFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	// Step 1: find the dcs-sms repo.
	cwd, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms dev-reload: cannot resolve cwd:", err)
		return 3
	}
	toolsDir, err := hooks.findToolsDir(cwd)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms dev-reload:", err)
		return 2
	}
	fmt.Fprintf(stdout, "==> building from %s\n", toolsDir)

	// Step 2: go build.
	if code := hooks.runBuild(toolsDir, stdout, stderr); code != 0 {
		fmt.Fprintln(stderr, "dcs-sms dev-reload: build failed")
		return 1
	}

	// Step 3: install-me-mod (forwards --dcs-path if supplied).
	var installArgs []string
	if opts.DCSPath != "" {
		installArgs = append(installArgs, "--dcs-path", opts.DCSPath)
	}
	fmt.Fprintln(stdout, "==> install-me-mod")
	if code := hooks.installMeMod(installArgs, stdout, stderr); code != 0 {
		return code
	}

	// Step 4: reload-me-mod (forwards --saved-games / --timeout / --wait).
	var reloadArgs []string
	if opts.SavedGames != "" {
		reloadArgs = append(reloadArgs, "--saved-games", opts.SavedGames)
	}
	reloadArgs = append(reloadArgs, "--timeout", opts.Timeout.String())
	if opts.Wait {
		reloadArgs = append(reloadArgs, "--wait")
	}
	fmt.Fprintln(stdout, "==> reload-me-mod")
	if code := hooks.reloadMeMod(reloadArgs, stdout, stderr); code != 0 {
		return code
	}

	fmt.Fprintln(stdout, "")
	fmt.Fprintln(stdout, "dev-reload complete.")
	return 0
}
