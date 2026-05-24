package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeDevReloadHooks implements devReloadHooks via func fields so tests can
// override step-by-step.
type fakeDevReloadHooks struct {
	findToolsDirFn       func(cwd string) (string, error)
	runBuildFn           func(toolsDir string, stdout, stderr io.Writer) int
	runInstallExternalFn func(binaryPath string, args []string, stdout, stderr io.Writer) int
	reloadMeModFn        func(args []string, stdout, stderr io.Writer) int
}

func (f *fakeDevReloadHooks) findToolsDir(cwd string) (string, error) {
	return f.findToolsDirFn(cwd)
}
func (f *fakeDevReloadHooks) runBuild(t string, so, se io.Writer) int {
	return f.runBuildFn(t, so, se)
}
func (f *fakeDevReloadHooks) runInstallExternal(bin string, a []string, so, se io.Writer) int {
	return f.runInstallExternalFn(bin, a, so, se)
}
func (f *fakeDevReloadHooks) reloadMeMod(a []string, so, se io.Writer) int {
	return f.reloadMeModFn(a, so, se)
}

// fakeToolsDirWithBinary creates a tempdir with go.mod, writes a dummy
// dcs-sms[.exe] file (so dev-reload's os.Stat guard passes), and returns
// the path. Test cleanup is handled by t.TempDir().
func fakeToolsDirWithBinary(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"),
		[]byte("module github.com/nielsvaes/dcs-sms/tools\n\ngo 1.25.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	binPath := builtBinaryPath(dir)
	if err := os.WriteFile(binPath, []byte("fake binary\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return dir
}

func newFakeDevReloadHooks() *fakeDevReloadHooks {
	return &fakeDevReloadHooks{
		findToolsDirFn:       func(_ string) (string, error) { return "/fake/tools", nil },
		runBuildFn:           func(_ string, _, _ io.Writer) int { return 0 },
		runInstallExternalFn: func(_ string, _ []string, _, _ io.Writer) int { return 0 },
		reloadMeModFn:        func(_ []string, _, _ io.Writer) int { return 0 },
	}
}

func TestDevReload_HappyPath(t *testing.T) {
	toolsDir := fakeToolsDirWithBinary(t)
	hooks := newFakeDevReloadHooks()
	calls := []string{}
	hooks.findToolsDirFn = func(_ string) (string, error) { calls = append(calls, "find"); return toolsDir, nil }
	hooks.runBuildFn = func(_ string, _, _ io.Writer) int { calls = append(calls, "build"); return 0 }
	hooks.runInstallExternalFn = func(_ string, _ []string, _, _ io.Writer) int { calls = append(calls, "install"); return 0 }
	hooks.reloadMeModFn = func(_ []string, _, _ io.Writer) int { calls = append(calls, "reload"); return 0 }

	var stdout, stderr bytes.Buffer
	code := devReloadCmdWith(nil, &stdout, &stderr, hooks)
	if code != 0 {
		t.Fatalf("exit %d, stderr: %s", code, stderr.String())
	}
	want := []string{"find", "build", "install", "reload"}
	if !stringSliceEqual(calls, want) {
		t.Errorf("call order = %v, want %v", calls, want)
	}
	if !strings.Contains(stdout.String(), "dev-reload complete") {
		t.Errorf("expected 'dev-reload complete' in stdout, got %q", stdout.String())
	}
}

// TestDevReload_InstallExecsBuiltBinary pins the core property the
// out-of-process install fix relies on: dev-reload passes the
// just-built binary path (under toolsDir, with platform-appropriate
// extension) to the install hook, NOT some other path. Regressing this
// would silently restore the embed-staleness bug.
func TestDevReload_InstallExecsBuiltBinary(t *testing.T) {
	toolsDir := fakeToolsDirWithBinary(t)
	wantBin := builtBinaryPath(toolsDir)

	hooks := newFakeDevReloadHooks()
	hooks.findToolsDirFn = func(_ string) (string, error) { return toolsDir, nil }
	var gotBin string
	hooks.runInstallExternalFn = func(bin string, _ []string, _, _ io.Writer) int {
		gotBin = bin
		return 0
	}

	var stdout, stderr bytes.Buffer
	code := devReloadCmdWith(nil, &stdout, &stderr, hooks)
	if code != 0 {
		t.Fatalf("exit %d, stderr: %s", code, stderr.String())
	}
	if gotBin != wantBin {
		t.Errorf("install binary path = %q, want %q", gotBin, wantBin)
	}
}

// TestDevReload_FailsIfBuiltBinaryMissing covers the os.Stat guard:
// if the build step succeeded but somehow no binary landed at the
// expected path, we fail loudly with the missing path instead of
// silently re-using a stale binary elsewhere on PATH.
func TestDevReload_FailsIfBuiltBinaryMissing(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"),
		[]byte("module github.com/nielsvaes/dcs-sms/tools\n\ngo 1.25.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Deliberately do NOT create the binary file.

	hooks := newFakeDevReloadHooks()
	hooks.findToolsDirFn = func(_ string) (string, error) { return dir, nil }
	installCalled := false
	hooks.runInstallExternalFn = func(_ string, _ []string, _, _ io.Writer) int {
		installCalled = true
		return 0
	}

	var stdout, stderr bytes.Buffer
	code := devReloadCmdWith(nil, &stdout, &stderr, hooks)
	if code != 1 {
		t.Errorf("exit %d, want 1", code)
	}
	if installCalled {
		t.Error("install hook was called even though built binary was missing")
	}
	if !strings.Contains(stderr.String(), "built binary not found") {
		t.Errorf("stderr does not name the condition: %q", stderr.String())
	}
}

func TestFindToolsDirImpl_MatchAtCwd(t *testing.T) {
	tmp := t.TempDir()
	mustWriteFile(t, filepath.Join(tmp, "go.mod"),
		"module github.com/nielsvaes/dcs-sms/tools\n\ngo 1.25.0\n")
	got, err := findToolsDirImpl(tmp)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != tmp {
		t.Errorf("got %q, want %q", got, tmp)
	}
}

func TestFindToolsDirImpl_MatchAtAncestor(t *testing.T) {
	tmp := t.TempDir()
	mustWriteFile(t, filepath.Join(tmp, "go.mod"),
		"module github.com/nielsvaes/dcs-sms/tools\n\ngo 1.25.0\n")
	sub := filepath.Join(tmp, "cmd", "dcs-sms")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := findToolsDirImpl(sub)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != tmp {
		t.Errorf("got %q, want %q", got, tmp)
	}
}

func TestFindToolsDirImpl_WrongModule(t *testing.T) {
	tmp := t.TempDir()
	mustWriteFile(t, filepath.Join(tmp, "go.mod"),
		"module example.com/other/project\n\ngo 1.25.0\n")
	_, err := findToolsDirImpl(tmp)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "not inside the dcs-sms repo") {
		t.Errorf("error %q does not name the missing condition", err.Error())
	}
}

func TestFindToolsDirImpl_NoGoMod(t *testing.T) {
	tmp := t.TempDir()
	_, err := findToolsDirImpl(tmp)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestDevReload_NotInRepoExits2(t *testing.T) {
	hooks := newFakeDevReloadHooks()
	hooks.findToolsDirFn = func(cwd string) (string, error) {
		return "", errors.New("not inside the dcs-sms repo (no go.mod with module \"github.com/nielsvaes/dcs-sms/tools\" found walking up from " + cwd + ")")
	}
	buildCalled := false
	hooks.runBuildFn = func(_ string, _, _ io.Writer) int { buildCalled = true; return 0 }

	var stdout, stderr bytes.Buffer
	code := devReloadCmdWith(nil, &stdout, &stderr, hooks)
	if code != 2 {
		t.Errorf("exit %d, want 2", code)
	}
	if buildCalled {
		t.Error("runBuild was called despite findToolsDir error")
	}
	if !strings.Contains(stderr.String(), "not inside the dcs-sms repo") {
		t.Errorf("stderr does not name the condition: %q", stderr.String())
	}
}

func mustWriteFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestDevReload_StopsOnBuildFailure(t *testing.T) {
	hooks := newFakeDevReloadHooks()
	hooks.runBuildFn = func(_ string, _, stderr io.Writer) int {
		stderr.Write([]byte("./cmd/dcs-sms/foo.go:1:1: syntax error\n"))
		return 1
	}
	installCalled := false
	reloadCalled := false
	hooks.runInstallExternalFn = func(_ string, _ []string, _, _ io.Writer) int { installCalled = true; return 0 }
	hooks.reloadMeModFn = func(_ []string, _, _ io.Writer) int { reloadCalled = true; return 0 }

	var stdout, stderr bytes.Buffer
	code := devReloadCmdWith(nil, &stdout, &stderr, hooks)
	if code != 1 {
		t.Errorf("exit %d, want 1", code)
	}
	if installCalled || reloadCalled {
		t.Errorf("install=%v reload=%v, want neither called", installCalled, reloadCalled)
	}
	if !strings.Contains(stderr.String(), "syntax error") {
		t.Errorf("stderr did not forward build output: %q", stderr.String())
	}
	if !strings.Contains(stderr.String(), "build failed") {
		t.Errorf("stderr missing build-failed marker: %q", stderr.String())
	}
}

func TestDevReload_StopsOnInstallFailure(t *testing.T) {
	toolsDir := fakeToolsDirWithBinary(t)
	hooks := newFakeDevReloadHooks()
	hooks.findToolsDirFn = func(_ string) (string, error) { return toolsDir, nil }
	hooks.runInstallExternalFn = func(_ string, _ []string, _, _ io.Writer) int { return 1 }
	reloadCalled := false
	hooks.reloadMeModFn = func(_ []string, _, _ io.Writer) int { reloadCalled = true; return 0 }

	var stdout, stderr bytes.Buffer
	code := devReloadCmdWith(nil, &stdout, &stderr, hooks)
	if code != 1 {
		t.Errorf("exit %d, want 1", code)
	}
	if reloadCalled {
		t.Error("reload was called despite install failure")
	}
}

func TestDevReload_PropagatesElevationExit5(t *testing.T) {
	toolsDir := fakeToolsDirWithBinary(t)
	hooks := newFakeDevReloadHooks()
	hooks.findToolsDirFn = func(_ string) (string, error) { return toolsDir, nil }
	hooks.runInstallExternalFn = func(_ string, _ []string, _, stderr io.Writer) int {
		stderr.Write([]byte("dcs-sms install-me-mod: <DCS>/MissionEditor is not writable.\n"))
		stderr.Write([]byte("  Re-run dcs-sms.exe from an admin terminal, or use the interactive menu (double-click) to be prompted.\n"))
		return 5
	}
	reloadCalled := false
	hooks.reloadMeModFn = func(_ []string, _, _ io.Writer) int { reloadCalled = true; return 0 }

	var stdout, stderr bytes.Buffer
	code := devReloadCmdWith(nil, &stdout, &stderr, hooks)
	if code != 5 {
		t.Errorf("exit %d, want 5", code)
	}
	if reloadCalled {
		t.Error("reload was called despite elevation requirement")
	}
	if !strings.Contains(stderr.String(), "admin terminal") {
		t.Errorf("stderr does not forward install hint: %q", stderr.String())
	}
}

func TestDevReload_PropagatesReloadBridgeOff(t *testing.T) {
	toolsDir := fakeToolsDirWithBinary(t)
	hooks := newFakeDevReloadHooks()
	hooks.findToolsDirFn = func(_ string) (string, error) { return toolsDir, nil }
	hooks.reloadMeModFn = func(_ []string, _, _ io.Writer) int { return 4 }

	var stdout, stderr bytes.Buffer
	code := devReloadCmdWith(nil, &stdout, &stderr, hooks)
	if code != 4 {
		t.Errorf("exit %d, want 4 (bridge off)", code)
	}
}

func TestDevReload_ForwardsDCSPathToInstall(t *testing.T) {
	toolsDir := fakeToolsDirWithBinary(t)
	hooks := newFakeDevReloadHooks()
	hooks.findToolsDirFn = func(_ string) (string, error) { return toolsDir, nil }
	var installArgs []string
	var reloadArgs []string
	hooks.runInstallExternalFn = func(_ string, a []string, _, _ io.Writer) int {
		installArgs = append([]string(nil), a...)
		return 0
	}
	hooks.reloadMeModFn = func(a []string, _, _ io.Writer) int {
		reloadArgs = append([]string(nil), a...)
		return 0
	}

	var stdout, stderr bytes.Buffer
	code := devReloadCmdWith([]string{"--dcs-path", "D:/DCS"}, &stdout, &stderr, hooks)
	if code != 0 {
		t.Fatalf("exit %d, stderr: %s", code, stderr.String())
	}
	wantInstall := []string{"--dcs-path", "D:/DCS"}
	if !stringSliceEqual(installArgs, wantInstall) {
		t.Errorf("install args = %v, want %v", installArgs, wantInstall)
	}
	for _, a := range reloadArgs {
		if a == "--dcs-path" {
			t.Error("--dcs-path leaked into reload args")
		}
	}
}

func TestDevReload_ForwardsReloadFlags(t *testing.T) {
	toolsDir := fakeToolsDirWithBinary(t)
	hooks := newFakeDevReloadHooks()
	hooks.findToolsDirFn = func(_ string) (string, error) { return toolsDir, nil }
	var installArgs []string
	var reloadArgs []string
	hooks.runInstallExternalFn = func(_ string, a []string, _, _ io.Writer) int {
		installArgs = append([]string(nil), a...)
		return 0
	}
	hooks.reloadMeModFn = func(a []string, _, _ io.Writer) int {
		reloadArgs = append([]string(nil), a...)
		return 0
	}

	var stdout, stderr bytes.Buffer
	code := devReloadCmdWith(
		[]string{"--saved-games", "D:/Saved Games", "--timeout", "5s", "--wait"},
		&stdout, &stderr, hooks,
	)
	if code != 0 {
		t.Fatalf("exit %d, stderr: %s", code, stderr.String())
	}
	wantReload := []string{"--saved-games", "D:/Saved Games", "--timeout", "5s", "--wait"}
	if !stringSliceEqual(reloadArgs, wantReload) {
		t.Errorf("reload args = %v, want %v", reloadArgs, wantReload)
	}
	for _, a := range installArgs {
		if a == "--saved-games" || a == "--timeout" || a == "--wait" {
			t.Errorf("reload flag %q leaked into install args", a)
		}
	}
}

func TestDevReload_DefaultTimeoutForwarded(t *testing.T) {
	// Even without an explicit --timeout, the default (10s) is forwarded
	// to reload-me-mod so the flag is always present in the reload call.
	toolsDir := fakeToolsDirWithBinary(t)
	hooks := newFakeDevReloadHooks()
	hooks.findToolsDirFn = func(_ string) (string, error) { return toolsDir, nil }
	var reloadArgs []string
	hooks.reloadMeModFn = func(a []string, _, _ io.Writer) int {
		reloadArgs = append([]string(nil), a...)
		return 0
	}

	var stdout, stderr bytes.Buffer
	code := devReloadCmdWith(nil, &stdout, &stderr, hooks)
	if code != 0 {
		t.Fatalf("exit %d, stderr: %s", code, stderr.String())
	}
	// Expect exactly: --timeout 10s, with no --wait, no --saved-games.
	want := []string{"--timeout", "10s"}
	if !stringSliceEqual(reloadArgs, want) {
		t.Errorf("reload args = %v, want %v", reloadArgs, want)
	}
}

func TestDevReload_BadFlagExits2(t *testing.T) {
	hooks := newFakeDevReloadHooks()
	buildCalled := false
	hooks.runBuildFn = func(_ string, _, _ io.Writer) int { buildCalled = true; return 0 }

	var stdout, stderr bytes.Buffer
	code := devReloadCmdWith([]string{"--no-such-flag"}, &stdout, &stderr, hooks)
	if code != 2 {
		t.Errorf("exit %d, want 2", code)
	}
	if buildCalled {
		t.Error("runBuild was called despite bad flag")
	}
}
