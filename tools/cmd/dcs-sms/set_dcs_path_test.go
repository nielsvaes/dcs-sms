package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// errNoConfigDirForTest stands in for os.UserConfigDir failing.
var errNoConfigDirForTest = errors.New("no config dir")

func TestSetDCSPathPersists(t *testing.T) {
	root := makeFakeDCSInstall(t)
	cfg := filepath.Join(t.TempDir(), "config.toml")
	withConfigSeam(t, cfg, nil)

	var stdout, stderr bytes.Buffer
	if code := setDCSPathCmd([]string{root}, &stdout, &stderr); code != 0 {
		t.Fatalf("exit %d, want 0 (stderr=%q)", code, stderr.String())
	}
	body, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatal(err)
	}
	// Matches what menu option 5 has always written, so the two writers agree.
	if !strings.Contains(string(body), filepath.ToSlash(root)) {
		t.Errorf("config should record %q, got %q", filepath.ToSlash(root), body)
	}
	if !strings.Contains(string(body), "dcs_install") {
		t.Errorf("config should set dcs_install, got %q", body)
	}
}

// The install root is the folder containing MissionEditor/MissionEditor.lua.
// Pointing at Saved Games, or at the MissionEditor folder itself, is the
// common mistake and has to be caught rather than silently recorded.
func TestSetDCSPathRejectsNonInstallRoot(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.toml")
	notDCS := filepath.Join(dir, "SomeFolder")
	if err := os.MkdirAll(notDCS, 0o755); err != nil {
		t.Fatal(err)
	}
	withConfigSeam(t, cfg, nil)

	var stdout, stderr bytes.Buffer
	if code := setDCSPathCmd([]string{notDCS}, &stdout, &stderr); code != 3 {
		t.Fatalf("exit %d, want 3", code)
	}
	if !strings.Contains(stderr.String(), "MissionEditor.lua") {
		t.Errorf("error should explain what was missing, got %q", stderr.String())
	}
	if _, err := os.Stat(cfg); err == nil {
		t.Error("config must not be written for an invalid path")
	}
}

func TestSetDCSPathRejectsMissingDir(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.toml")
	withConfigSeam(t, cfg, nil)

	var stdout, stderr bytes.Buffer
	if code := setDCSPathCmd([]string{filepath.Join(dir, "nope")}, &stdout, &stderr); code != 3 {
		t.Fatalf("exit %d, want 3", code)
	}
}

func TestSetDCSPathStripsQuotes(t *testing.T) {
	root := makeFakeDCSInstall(t)
	cfg := filepath.Join(t.TempDir(), "config.toml")
	withConfigSeam(t, cfg, nil)

	var stdout, stderr bytes.Buffer
	if code := setDCSPathCmd([]string{`"` + root + `"`}, &stdout, &stderr); code != 0 {
		t.Fatalf("exit %d, want 0 (stderr=%q)", code, stderr.String())
	}
	body, _ := os.ReadFile(cfg)
	if strings.Count(string(body), `"`) != 2 {
		t.Errorf("quotes leaked into the saved path: %q", body)
	}
}

// Bare invocation reports what is configured — the question someone asks
// right after seeing "DCS install: not detected" in the menu banner.
func TestSetDCSPathBareShowsCurrent(t *testing.T) {
	root := makeFakeDCSInstall(t)
	cfg := filepath.Join(t.TempDir(), "config.toml")
	withConfigSeam(t, cfg, nil)
	t.Setenv("DCS_SMS_DCS_INSTALL", "")

	var stdout, stderr bytes.Buffer
	if code := setDCSPathCmd([]string{root}, &stdout, &stderr); code != 0 {
		t.Fatalf("setup save failed: %d", code)
	}
	stdout.Reset()
	if code := setDCSPathCmd(nil, &stdout, &stderr); code != 0 {
		t.Fatalf("exit %d, want 0", code)
	}
	if !strings.Contains(stdout.String(), filepath.ToSlash(root)) {
		t.Errorf("bare run should show the configured path, got:\n%s", stdout.String())
	}
}

func TestSetDCSPathBareWhenUnset(t *testing.T) {
	cfg := filepath.Join(t.TempDir(), "config.toml")
	withConfigSeam(t, cfg, nil)
	t.Setenv("DCS_SMS_DCS_INSTALL", "")

	var stdout, stderr bytes.Buffer
	if code := setDCSPathCmd(nil, &stdout, &stderr); code != 0 {
		t.Fatalf("exit %d, want 0", code)
	}
	out := stdout.String()
	if !strings.Contains(out, "not set") || !strings.Contains(out, "set-dcs-path") {
		t.Errorf("should say it is unset and how to set it, got:\n%s", out)
	}
}

// Same trap as DCS_SMS_SAVED_GAMES: DiscoverInstall checks the env var before
// the config file, so pinning under it has no effect.
func TestSetDCSPathWarnsWhenEnvOverrides(t *testing.T) {
	root := makeFakeDCSInstall(t)
	other := makeFakeDCSInstall(t)
	cfg := filepath.Join(t.TempDir(), "config.toml")
	withConfigSeam(t, cfg, nil)
	t.Setenv("DCS_SMS_DCS_INSTALL", other)

	var stdout, stderr bytes.Buffer
	if code := setDCSPathCmd([]string{root}, &stdout, &stderr); code != 0 {
		t.Fatalf("exit %d, want 0", code)
	}
	if !strings.Contains(stdout.String()+stderr.String(), "DCS_SMS_DCS_INSTALL") {
		t.Errorf("saving under an env override must say so, got:\n%s", stdout.String())
	}
}

func TestSetDCSPathTooManyArgs(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := setDCSPathCmd([]string{"a", "b"}, &stdout, &stderr); code != 2 {
		t.Errorf("exit %d, want 2", code)
	}
}

func TestUsageListsSetDCSPath(t *testing.T) {
	var buf bytes.Buffer
	printUsage(&buf)
	if !strings.Contains(buf.String(), "set-dcs-path") {
		t.Errorf("printUsage should list set-dcs-path, got:\n%s", buf.String())
	}
}

// Review finding: the env-override warning compared paths as raw strings, so
// a DCS_SMS_DCS_INSTALL naming the very same folder with a trailing separator
// or different casing produced "clear it to pick up the folder you just
// pinned" — about a variable pointing at that exact folder.
func TestSetDCSPathNoFalseEnvWarning(t *testing.T) {
	root := makeFakeDCSInstall(t)
	for name, env := range map[string]string{
		"trailing separator": root + string(filepath.Separator),
		"different case":     strings.ToLower(root),
		"forward slashes":    filepath.ToSlash(root),
	} {
		t.Run(name, func(t *testing.T) {
			cfg := filepath.Join(t.TempDir(), "config.toml")
			withConfigSeam(t, cfg, nil)
			t.Setenv("DCS_SMS_DCS_INSTALL", env)

			var stdout, stderr bytes.Buffer
			if code := setDCSPathCmd([]string{root}, &stdout, &stderr); code != 0 {
				t.Fatalf("exit %d, want 0", code)
			}
			if strings.Contains(stdout.String(), "Clear it") {
				t.Errorf("env names the same folder, so no warning expected, got:\n%s", stdout.String())
			}
		})
	}
}

// Review finding: the bare report resolved the config path first and bailed
// out, so the one command whose job is "show me what's configured" refused to
// answer on a box where the config dir can't be resolved but the env var can.
func TestSetDCSPathBareReportsWithoutConfigPath(t *testing.T) {
	root := makeFakeDCSInstall(t)
	oldCfg := configPathFn
	configPathFn = func() (string, error) { return "", errNoConfigDirForTest }
	t.Cleanup(func() { configPathFn = oldCfg })
	t.Setenv("DCS_SMS_DCS_INSTALL", root)

	var stdout, stderr bytes.Buffer
	if code := setDCSPathCmd(nil, &stdout, &stderr); code != 0 {
		t.Fatalf("exit %d, want 0 (stderr=%q)", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), root) {
		t.Errorf("should still report the env-provided path, got:\n%s", stdout.String())
	}
}

// Review finding: persistDCSInstall is the writer for interactive menu option
// 5 too, so its errors must not name a subcommand the user never typed.
func TestPersistDCSInstallErrorIsCommandNeutral(t *testing.T) {
	root := makeFakeDCSInstall(t)
	// Make the config path unwritable by putting a *file* where its parent
	// directory would have to be.
	dir := t.TempDir()
	blocker := filepath.Join(dir, "blocker")
	if err := os.WriteFile(blocker, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(blocker, "config.toml")

	var stdout, stderr bytes.Buffer
	if code := persistDCSInstall(root, cfg, &stdout, &stderr); code != 3 {
		t.Fatalf("exit %d, want 3", code)
	}
	if strings.Contains(stderr.String(), "set-dcs-path") {
		t.Errorf("shared writer must not name a command the menu user never typed, got:\n%s", stderr.String())
	}
	if !strings.Contains(stderr.String(), "dcs-sms:") {
		t.Errorf("expected a neutral dcs-sms: prefix, got:\n%s", stderr.String())
	}
}
