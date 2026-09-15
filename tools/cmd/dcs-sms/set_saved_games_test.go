package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// withConfigSeam points the set-saved-games command at a throwaway config
// file and a fixed variant listing, so tests never touch the real
// %AppData%\dcs-sms\config.toml or the host's Saved Games folder.
func withConfigSeam(t *testing.T, cfg string, variants []string) {
	t.Helper()
	oldCfg, oldList := configPathFn, listVariantsFn
	configPathFn = func() (string, error) { return cfg, nil }
	listVariantsFn = func() ([]string, bool) { return variants, true }
	t.Cleanup(func() { configPathFn, listVariantsFn = oldCfg, oldList })
}

func TestSetSavedGamesPersists(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.toml")
	target := makeVariant(t, dir, "DCS.openbeta", true, time.Now())
	withConfigSeam(t, cfg, []string{target})

	var stdout, stderr bytes.Buffer
	if code := setSavedGamesCmd([]string{target}, &stdout, &stderr); code != 0 {
		t.Fatalf("exit %d, want 0 (stderr=%q)", code, stderr.String())
	}
	body, err := os.ReadFile(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), "saved_games") || !strings.Contains(string(body), "DCS.openbeta") {
		t.Errorf("config did not record the path, got %q", body)
	}
}

// Users paste paths straight out of Explorer, quotes and all.
func TestSetSavedGamesStripsQuotes(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.toml")
	target := makeVariant(t, dir, "DCS.openbeta", true, time.Time{})
	withConfigSeam(t, cfg, []string{target})

	var stdout, stderr bytes.Buffer
	if code := setSavedGamesCmd([]string{`"` + target + `"`}, &stdout, &stderr); code != 0 {
		t.Fatalf("exit %d, want 0 (stderr=%q)", code, stderr.String())
	}
	body, _ := os.ReadFile(cfg)
	if strings.Contains(string(body), `\"`) || strings.Count(string(body), `"`) != 2 {
		t.Errorf("quotes leaked into the saved path: %q", body)
	}
}

func TestSetSavedGamesRejectsMissingDir(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.toml")
	withConfigSeam(t, cfg, nil)

	missing := filepath.Join(dir, "DCS.nope")
	var stdout, stderr bytes.Buffer
	code := setSavedGamesCmd([]string{missing}, &stdout, &stderr)
	if code != 3 {
		t.Fatalf("exit %d, want 3", code)
	}
	if !strings.Contains(stderr.String(), missing) {
		t.Errorf("error should name the offending path, got %q", stderr.String())
	}
	if _, err := os.Stat(cfg); err == nil {
		t.Error("config must not be written when the path is invalid")
	}
}

// A real DCS Saved Games folder always has Config/ or Logs/ after first run.
// A folder without them is probably a typo — but we save anyway and warn,
// rather than blocking someone with an unusual setup.
func TestSetSavedGamesWarnsButSavesOnUnexpectedLayout(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.toml")
	odd := filepath.Join(dir, "SomewhereElse")
	if err := os.MkdirAll(odd, 0o755); err != nil {
		t.Fatal(err)
	}
	withConfigSeam(t, cfg, nil)

	var stdout, stderr bytes.Buffer
	if code := setSavedGamesCmd([]string{odd}, &stdout, &stderr); code != 0 {
		t.Fatalf("exit %d, want 0", code)
	}
	combined := stdout.String() + stderr.String()
	if !strings.Contains(strings.ToLower(combined), "doesn't look like") {
		t.Errorf("expected a warning about the folder layout, got %q", combined)
	}
	if _, err := os.Stat(cfg); err != nil {
		t.Error("config should still have been written after the warning")
	}
}

// Bare invocation is the discovery path: show what is in use and what else
// exists, so the user can see the mismatch that sent them here.
func TestSetSavedGamesListsWhenNoArgs(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "config.toml")
	a := makeVariant(t, dir, "DCS", false, time.Time{})
	b := makeVariant(t, dir, "DCS.openbeta", true, time.Now())
	withConfigSeam(t, cfg, []string{a, b})
	t.Setenv("DCS_SMS_SAVED_GAMES", a)

	var stdout, stderr bytes.Buffer
	if code := setSavedGamesCmd(nil, &stdout, &stderr); code != 0 {
		t.Fatalf("exit %d, want 0 (stderr=%q)", code, stderr.String())
	}
	out := stdout.String()
	for _, want := range []string{a, b, "no hook installed", "running now", "set-saved-games"} {
		if !strings.Contains(out, want) {
			t.Errorf("listing missing %q, got:\n%s", want, out)
		}
	}
}

func TestSetSavedGamesTooManyArgs(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if code := setSavedGamesCmd([]string{"a", "b"}, &stdout, &stderr); code != 2 {
		t.Errorf("exit %d, want 2", code)
	}
}
