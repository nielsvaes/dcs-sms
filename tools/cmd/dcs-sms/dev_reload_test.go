package main

import (
	"bytes"
	"errors"
	"io"
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

// errors import is used by later tests in this file; declared here so this
// scaffolding task lands a buildable test file.
var _ = errors.New
