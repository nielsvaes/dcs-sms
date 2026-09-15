package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestDispatchVersion(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := dispatch([]string{"--version"}, nil, &stdout, &stderr, false)
	if code != 0 {
		t.Errorf("exit code %d, want 0", code)
	}
	if !strings.Contains(stdout.String(), version) {
		t.Errorf("expected version in stdout, got %q", stdout.String())
	}
}

func TestDispatchUnknownCommand(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := dispatch([]string{"snurfle"}, nil, &stdout, &stderr, false)
	if code == 0 {
		t.Error("expected non-zero exit for unknown command")
	}
	if !strings.Contains(stderr.String(), "unknown") {
		t.Errorf("expected 'unknown' in stderr, got %q", stderr.String())
	}
}

func TestDispatchNoArgsNonInteractiveShowsHelp(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := dispatch(nil, nil, &stdout, &stderr, false)
	if code == 0 {
		t.Error("expected non-zero exit when no command given and not interactive")
	}
	if !strings.Contains(stderr.String(), "Usage") {
		t.Errorf("expected usage banner in stderr, got %q", stderr.String())
	}
}

func TestDispatchNoArgsInteractiveShowsMenu(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := dispatch(nil, strings.NewReader("q\n"), &stdout, &stderr, true)
	if code != 0 {
		t.Errorf("exit code %d, want 0", code)
	}
	if !strings.Contains(stdout.String(), "DCS-SMS") {
		t.Errorf("expected menu banner in stdout, got %q", stdout.String())
	}
}

// Every user-facing command has to be reachable from `dcs-sms --help`; the
// list in printUsage is hand-maintained and easy to forget.
func TestUsageListsSetSavedGames(t *testing.T) {
	var buf bytes.Buffer
	printUsage(&buf)
	if !strings.Contains(buf.String(), "set-saved-games") {
		t.Errorf("printUsage should list set-saved-games, got:\n%s", buf.String())
	}
}
