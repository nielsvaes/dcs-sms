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
	findToolsDirFn func(cwd string) (string, error)
	runBuildFn     func(toolsDir string, stdout, stderr io.Writer) int
	installMeModFn func(args []string, stdout, stderr io.Writer) int
	reloadMeModFn  func(args []string, stdout, stderr io.Writer) int
}

func (f *fakeDevReloadHooks) findToolsDir(cwd string) (string, error) {
	return f.findToolsDirFn(cwd)
}
func (f *fakeDevReloadHooks) runBuild(t string, so, se io.Writer) int {
	return f.runBuildFn(t, so, se)
}
func (f *fakeDevReloadHooks) installMeMod(a []string, so, se io.Writer) int {
	return f.installMeModFn(a, so, se)
}
func (f *fakeDevReloadHooks) reloadMeMod(a []string, so, se io.Writer) int {
	return f.reloadMeModFn(a, so, se)
}

func newFakeDevReloadHooks() *fakeDevReloadHooks {
	return &fakeDevReloadHooks{
		findToolsDirFn: func(_ string) (string, error) { return "/fake/tools", nil },
		runBuildFn:     func(_ string, _, _ io.Writer) int { return 0 },
		installMeModFn: func(_ []string, _, _ io.Writer) int { return 0 },
		reloadMeModFn:  func(_ []string, _, _ io.Writer) int { return 0 },
	}
}

func TestDevReload_HappyPath(t *testing.T) {
	hooks := newFakeDevReloadHooks()
	calls := []string{}
	hooks.findToolsDirFn = func(_ string) (string, error) { calls = append(calls, "find"); return "/fake/tools", nil }
	hooks.runBuildFn = func(_ string, _, _ io.Writer) int { calls = append(calls, "build"); return 0 }
	hooks.installMeModFn = func(_ []string, _, _ io.Writer) int { calls = append(calls, "install"); return 0 }
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
	hooks.installMeModFn = func(_ []string, _, _ io.Writer) int { installCalled = true; return 0 }
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
	hooks := newFakeDevReloadHooks()
	hooks.installMeModFn = func(_ []string, _, _ io.Writer) int { return 1 }
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
	hooks := newFakeDevReloadHooks()
	hooks.installMeModFn = func(_ []string, _, stderr io.Writer) int {
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
	hooks := newFakeDevReloadHooks()
	hooks.reloadMeModFn = func(_ []string, _, _ io.Writer) int { return 4 }

	var stdout, stderr bytes.Buffer
	code := devReloadCmdWith(nil, &stdout, &stderr, hooks)
	if code != 4 {
		t.Errorf("exit %d, want 4 (bridge off)", code)
	}
}
