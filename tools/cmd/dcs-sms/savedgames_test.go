package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// makeVariant builds a fake <Saved Games>/<name> folder. hook installs the
// hook file; seenAt (when non-zero) writes a heartbeat that old.
func makeVariant(t *testing.T, base, name string, hook bool, seenAt time.Time) string {
	t.Helper()
	root := filepath.Join(base, name)
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if hook {
		hooksDir := filepath.Join(root, "Scripts", "Hooks")
		if err := os.MkdirAll(hooksDir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(hooksDir, "dcs-sms-hook.lua"), []byte("-- x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if !seenAt.IsZero() {
		stateDir := filepath.Join(root, "dcs-sms", "state")
		if err := os.MkdirAll(stateDir, 0o755); err != nil {
			t.Fatal(err)
		}
		body := `{"hook_version":"0.27.4","last_frame":1,"last_frame_at":"` +
			seenAt.Format(time.RFC3339Nano) + `"}`
		if err := os.WriteFile(filepath.Join(stateDir, "hook.json"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestInspectVariantDescribe(t *testing.T) {
	base := t.TempDir()
	now := time.Now()

	cases := []struct {
		name   string
		hook   bool
		seenAt time.Time
		want   string
	}{
		{"DCS", false, time.Time{}, "no hook installed"},
		{"DCS.openbeta", true, time.Time{}, "hook installed, never run"},
		{"DCS.server", true, now.Add(-1 * time.Second), "hook installed, running now"},
		{"DCS.dev", true, now.Add(-4 * time.Minute), "hook installed, last seen 4m ago"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := makeVariant(t, base, c.name, c.hook, c.seenAt)
			got := inspectVariant(p).describe(now)
			if got != c.want {
				t.Errorf("describe() = %q, want %q", got, c.want)
			}
		})
	}
}

// The whole point of the annotation is telling the user which folder DCS is
// actually writing to, so the running one must be distinguishable at a glance.
func TestVariantLinesMarksSelected(t *testing.T) {
	base := t.TempDir()
	stale := makeVariant(t, base, "DCS", false, time.Time{})
	live := makeVariant(t, base, "DCS.openbeta", true, time.Now())

	lines := variantLines([]string{stale, live}, stale, plainStyler())
	if len(lines) != 2 {
		t.Fatalf("expected 2 lines, got %d: %v", len(lines), lines)
	}
	if !strings.Contains(lines[0], "DCS") || !strings.Contains(lines[0], "in use") {
		t.Errorf("selected variant must be marked as in use, got %q", lines[0])
	}
	if strings.Contains(lines[1], "in use") {
		t.Errorf("non-selected variant must not be marked in use, got %q", lines[1])
	}
	if !strings.Contains(lines[1], "running now") {
		t.Errorf("expected live annotation on second line, got %q", lines[1])
	}
}

func TestHumanAge(t *testing.T) {
	cases := []struct {
		d    time.Duration
		want string
	}{
		{2 * time.Second, "2s"},
		{90 * time.Second, "1m"},
		{4 * time.Minute, "4m"},
		{3 * time.Hour, "3h"},
		{50 * time.Hour, "2d"},
	}
	for _, c := range cases {
		if got := humanAge(c.d); got != c.want {
			t.Errorf("humanAge(%v) = %q, want %q", c.d, got, c.want)
		}
	}
}

// Suggesting a switch is only helpful when another folder is demonstrably
// more alive than the current one. Telling someone whose setup is fine to
// move to a folder DCS has never written to is worse than saying nothing.
func TestBetterCandidate(t *testing.T) {
	now := time.Now()
	mk := func(t *testing.T, base, name string, hook bool, age time.Duration) string {
		seen := time.Time{}
		if age >= 0 {
			seen = now.Add(-age)
		}
		return makeVariant(t, base, name, hook, seen)
	}

	t.Run("current is the live one", func(t *testing.T) {
		base := t.TempDir()
		cur := mk(t, base, "DCS", true, 9*time.Hour)
		other := mk(t, base, "DCS.openbeta", true, -1) // hook, never run
		if got, ok := betterCandidate([]string{cur, other}, cur); ok {
			t.Errorf("no switch should be suggested, got %q", got)
		}
	})

	t.Run("other folder is live", func(t *testing.T) {
		base := t.TempDir()
		cur := mk(t, base, "DCS", true, 2*time.Hour)
		other := mk(t, base, "DCS.openbeta", true, 2*time.Second)
		got, ok := betterCandidate([]string{cur, other}, cur)
		if !ok || got != other {
			t.Errorf("betterCandidate = (%q,%v), want (%q,true)", got, ok, other)
		}
	})

	t.Run("current has no hook at all", func(t *testing.T) {
		base := t.TempDir()
		cur := mk(t, base, "DCS", false, -1)
		other := mk(t, base, "DCS.openbeta", true, -1)
		got, ok := betterCandidate([]string{cur, other}, cur)
		if !ok || got != other {
			t.Errorf("betterCandidate = (%q,%v), want (%q,true)", got, ok, other)
		}
	})

	t.Run("single folder", func(t *testing.T) {
		base := t.TempDir()
		cur := mk(t, base, "DCS", false, -1)
		if _, ok := betterCandidate([]string{cur}, cur); ok {
			t.Error("a single folder can never be the wrong one")
		}
	})
}
