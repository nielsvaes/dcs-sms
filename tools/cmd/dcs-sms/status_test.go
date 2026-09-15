package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nielsvaes/dcs-sms/tools/internal/proto"
)

func TestStatusFresh(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "dcs-sms", "state")
	_ = os.MkdirAll(stateDir, 0o755)
	st := proto.HookState{
		HookVersion:   "0.1.0",
		MissionLoaded: true,
		MissionName:   "Caucasus.miz",
		LastFrame:     100,
		LastFrameAt:   time.Now().UTC().Format(time.RFC3339Nano),
	}
	data, _ := json.Marshal(st)
	_ = os.WriteFile(filepath.Join(stateDir, "hook.json"), data, 0o644)

	t.Setenv("DCS_SMS_SAVED_GAMES", root)
	var stdout, stderr bytes.Buffer
	code := statusCmd(nil, &stdout, &stderr)
	if code != 0 {
		t.Errorf("exit %d, want 0", code)
	}
	if !strings.Contains(stdout.String(), "Caucasus.miz") {
		t.Errorf("missing mission name in stdout: %s", stdout.String())
	}
}

func TestStatusJSON(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "dcs-sms", "state")
	_ = os.MkdirAll(stateDir, 0o755)
	st := proto.HookState{HookVersion: "0.1.0", LastFrameAt: time.Now().UTC().Format(time.RFC3339Nano)}
	data, _ := json.Marshal(st)
	_ = os.WriteFile(filepath.Join(stateDir, "hook.json"), data, 0o644)

	t.Setenv("DCS_SMS_SAVED_GAMES", root)
	var stdout, stderr bytes.Buffer
	code := statusCmd([]string{"--json"}, &stdout, &stderr)
	if code != 0 {
		t.Errorf("exit %d, want 0", code)
	}
	var parsed map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &parsed); err != nil {
		t.Errorf("stdout not valid JSON: %v\n%s", err, stdout.String())
	}
}

func TestStatusMissingHookFile(t *testing.T) {
	root := t.TempDir()
	t.Setenv("DCS_SMS_SAVED_GAMES", root)
	var stdout, stderr bytes.Buffer
	code := statusCmd(nil, &stdout, &stderr)
	if code != 3 {
		t.Errorf("exit %d, want 3 (hook file missing)", code)
	}
}

func TestStatusJSONShowsNewFields(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "dcs-sms", "state")
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	st := proto.HookState{
		HookVersion:      "0.2.0",
		State:            "in_mission_editor",
		MissionLoaded:    false,
		GuiBridgeEnabled: true,
		TickSource:       "update_manager",
		LastFrame:        99,
		LastFrameAt:      time.Now().UTC().Format(time.RFC3339Nano),
		LastTick:         99,
		LastTickAt:       time.Now().UTC().Format(time.RFC3339Nano),
	}
	data, _ := json.Marshal(st)
	if err := os.WriteFile(filepath.Join(stateDir, "hook.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("DCS_SMS_SAVED_GAMES", root)
	stdout := &bytes.Buffer{}
	stderr := &bytes.Buffer{}
	code := statusCmd([]string{"--json"}, stdout, stderr)
	if code != 0 {
		t.Fatalf("status exit %d, stderr=%s", code, stderr.String())
	}
	out := stdout.String()
	for _, want := range []string{`"state":"in_mission_editor"`, `"gui_bridge_enabled":true`, `"tick_source":"update_manager"`} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in JSON output, got: %s", want, out)
		}
	}
}

func TestStatusTextShowsNewFields(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "dcs-sms", "state")
	_ = os.MkdirAll(stateDir, 0o755)
	st := proto.HookState{
		HookVersion:      "0.2.0",
		State:            "in_mission_editor",
		GuiBridgeEnabled: true,
		TickSource:       "update_manager",
		LastFrameAt:      time.Now().UTC().Format(time.RFC3339Nano),
	}
	data, _ := json.Marshal(st)
	_ = os.WriteFile(filepath.Join(stateDir, "hook.json"), data, 0o644)

	t.Setenv("DCS_SMS_SAVED_GAMES", root)
	stdout := &bytes.Buffer{}
	stderr := &bytes.Buffer{}
	code := statusCmd(nil, stdout, stderr)
	if code != 0 {
		t.Fatalf("status exit %d, stderr=%s", code, stderr.String())
	}
	out := stdout.String()
	for _, want := range []string{"in_mission_editor", "update_manager"} {
		if !strings.Contains(out, want) {
			t.Errorf("expected %q in text output, got: %s", want, out)
		}
	}
}

func TestStatusStaleHeartbeat(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "dcs-sms", "state")
	_ = os.MkdirAll(stateDir, 0o755)
	// 10 seconds in the past — well outside the 2s freshness window.
	st := proto.HookState{
		HookVersion: "0.1.0",
		LastFrameAt: time.Now().UTC().Add(-10 * time.Second).Format(time.RFC3339Nano),
	}
	data, _ := json.Marshal(st)
	_ = os.WriteFile(filepath.Join(stateDir, "hook.json"), data, 0o644)

	t.Setenv("DCS_SMS_SAVED_GAMES", root)
	var stdout, stderr bytes.Buffer
	code := statusCmd(nil, &stdout, &stderr)
	if code != 4 {
		t.Errorf("exit %d, want 4 (stale heartbeat)", code)
	}
	if !strings.Contains(stderr.String(), "stale") {
		t.Errorf("expected 'stale' in stderr, got %q", stderr.String())
	}
}

// The bug this diagnostic exists for: a leftover `DCS` folder sits next to
// the `DCS.openbeta` the user actually flies, auto-discovery picks `DCS`, and
// every command fails with a bare "hook not found". The failure has to name
// the folder it looked in and point at the one that is alive.
func TestStatusMissingHookNamesFolderAndAlternatives(t *testing.T) {
	base := t.TempDir()
	picked := makeVariant(t, base, "DCS", false, time.Time{})
	live := makeVariant(t, base, "DCS.openbeta", true, time.Now())
	withConfigSeam(t, filepath.Join(base, "config.toml"), []string{picked, live})
	t.Setenv("DCS_SMS_SAVED_GAMES", picked)

	var stdout, stderr bytes.Buffer
	if code := statusCmd(nil, &stdout, &stderr); code != 3 {
		t.Fatalf("exit %d, want 3", code)
	}
	out := stderr.String()
	for _, want := range []string{"looked in", picked, "DCS.openbeta", "running now", "set-saved-games"} {
		if !strings.Contains(out, want) {
			t.Errorf("diagnostic missing %q, got:\n%s", want, out)
		}
	}
}

// With only one folder there is no ambiguity to explain — don't pad the
// error with a pick-list of one.
func TestStatusMissingHookSingleFolderStaysQuiet(t *testing.T) {
	base := t.TempDir()
	only := makeVariant(t, base, "DCS", false, time.Time{})
	withConfigSeam(t, filepath.Join(base, "config.toml"), []string{only})
	t.Setenv("DCS_SMS_SAVED_GAMES", only)

	var stdout, stderr bytes.Buffer
	if code := statusCmd(nil, &stdout, &stderr); code != 3 {
		t.Fatalf("exit %d, want 3", code)
	}
	out := stderr.String()
	if !strings.Contains(out, "looked in") {
		t.Errorf("should still name the folder it looked in, got:\n%s", out)
	}
	if strings.Contains(out, "set-saved-games") {
		t.Errorf("should not suggest switching folders when there is only one, got:\n%s", out)
	}
}

// A stale heartbeat is the same ambiguity wearing a different hat: DCS may be
// writing to the other folder.
func TestStatusStaleHeartbeatSuggestsOtherFolder(t *testing.T) {
	base := t.TempDir()
	picked := makeVariant(t, base, "DCS", true, time.Now().Add(-2*time.Hour))
	live := makeVariant(t, base, "DCS.openbeta", true, time.Now())
	withConfigSeam(t, filepath.Join(base, "config.toml"), []string{picked, live})
	t.Setenv("DCS_SMS_SAVED_GAMES", picked)

	var stdout, stderr bytes.Buffer
	if code := statusCmd(nil, &stdout, &stderr); code != 4 {
		t.Fatalf("exit %d, want 4", code)
	}
	if !strings.Contains(stderr.String(), "set-saved-games") {
		t.Errorf("stale heartbeat should point at the live folder, got:\n%s", stderr.String())
	}
}

// --json is consumed by scripts and agents: the diagnostic prose goes to
// stderr, and stdout must stay parseable.
func TestStatusJSONStaysCleanWhenStale(t *testing.T) {
	base := t.TempDir()
	picked := makeVariant(t, base, "DCS", true, time.Now().Add(-2*time.Hour))
	withConfigSeam(t, filepath.Join(base, "config.toml"), []string{picked})
	t.Setenv("DCS_SMS_SAVED_GAMES", picked)

	var stdout, stderr bytes.Buffer
	statusCmd([]string{"--json"}, &stdout, &stderr)
	var parsed map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(stdout.String())), &parsed); err != nil {
		t.Fatalf("stdout is not valid JSON (%v): %q", err, stdout.String())
	}
}
