package ui

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

// A bytes.Buffer is not a terminal, so everything written through a Styler
// built from one must come out byte-identical to the input. Every existing
// CLI test captures output this way, so this property is what keeps their
// string assertions working once call sites start styling their output.
func TestForNonTerminalIsPlain(t *testing.T) {
	var buf bytes.Buffer
	s := For(&buf)
	if s.Enabled() {
		t.Fatal("styler must be disabled for a non-terminal writer")
	}
	for _, got := range []string{s.OK("ok"), s.Warn("warn"), s.Err("err"), s.Bold("bold")} {
		if strings.ContainsRune(got, esc) {
			t.Errorf("escape code leaked into non-terminal output: %q", got)
		}
	}
	if got := s.OK("installed"); got != "installed" {
		t.Errorf("OK() = %q, want unchanged %q", got, "installed")
	}
}

func TestZeroStylerIsPlain(t *testing.T) {
	var s Styler // zero value must be usable
	if got := s.Err("boom"); got != "boom" {
		t.Errorf("zero Styler must not style, got %q", got)
	}
}

func TestEnabledStylerWraps(t *testing.T) {
	s := Styler{on: true}
	cases := []struct {
		name string
		got  string
		want string
	}{
		{"OK", s.OK("yes"), green + "yes" + reset},
		{"Warn", s.Warn("hmm"), yellow + "hmm" + reset},
		{"Err", s.Err("no"), red + "no" + reset},
		{"Bold", s.Bold("hi"), bold + "hi" + reset},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s = %q, want %q", c.name, c.got, c.want)
		}
	}
}

// Styling an empty string would emit a bare escape pair for nothing.
func TestEmptyStringNotWrapped(t *testing.T) {
	s := Styler{on: true}
	if got := s.OK(""); got != "" {
		t.Errorf("empty string must stay empty, got %q", got)
	}
}

func TestNoColorEnvDisables(t *testing.T) {
	for _, key := range []string{"NO_COLOR", "DCS_SMS_NO_COLOR"} {
		t.Run(key, func(t *testing.T) {
			t.Setenv(key, "1")
			if colorEnabled(os.Stdout) {
				t.Errorf("%s must disable color", key)
			}
		})
	}
}

func TestDumbTerminalDisables(t *testing.T) {
	t.Setenv("TERM", "dumb")
	if colorEnabled(os.Stdout) {
		t.Error("TERM=dumb must disable color")
	}
}

// A writer that is not an *os.File can't be probed for terminal-ness, so it
// must degrade to plain text rather than guessing.
func TestNonFileWriterDisables(t *testing.T) {
	t.Setenv("NO_COLOR", "")
	if colorEnabled(&bytes.Buffer{}) {
		t.Error("non-*os.File writer must disable color")
	}
}

func TestForceColorOverridesNonTerminal(t *testing.T) {
	t.Setenv("DCS_SMS_FORCE_COLOR", "1")
	var buf bytes.Buffer
	if !For(&buf).Enabled() {
		t.Error("DCS_SMS_FORCE_COLOR must enable color for a non-terminal writer")
	}
}

// An explicit opt-out beats an explicit opt-in — otherwise a NO_COLOR user
// who once exported FORCE_COLOR could never turn it off.
func TestNoColorBeatsForceColor(t *testing.T) {
	t.Setenv("DCS_SMS_FORCE_COLOR", "1")
	t.Setenv("NO_COLOR", "1")
	var buf bytes.Buffer
	if For(&buf).Enabled() {
		t.Error("NO_COLOR must win over DCS_SMS_FORCE_COLOR")
	}
}
