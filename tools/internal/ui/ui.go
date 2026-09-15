// Package ui renders short status strings in color for the human-facing
// parts of the CLI — the interactive menu, the installers, and `status`.
//
// The rule that makes this safe to sprinkle into existing code: color is
// emitted only when the destination is a real interactive terminal. Output
// captured into a buffer, piped into another process, or redirected to a
// file stays plain, so machine-readable output (and every test that asserts
// on exact strings) is unaffected.
//
// The `me <noun> <verb>` verbs deliberately do not use this — their output
// is consumed by AI agents rather than read by a person.
package ui

import (
	"io"
	"os"
	"strings"

	"golang.org/x/term"
)

const (
	esc    = '\x1b'
	reset  = "\x1b[0m"
	red    = "\x1b[31m"
	green  = "\x1b[32m"
	yellow = "\x1b[33m"
	bold   = "\x1b[1m"
)

// Styler wraps strings in ANSI color codes. The zero value is valid and
// renders everything plain, so a Styler can be embedded in an options struct
// without a constructor call.
type Styler struct{ on bool }

// For returns a Styler that colors output only if w is an interactive
// terminal and the environment hasn't opted out.
func For(w io.Writer) Styler { return Styler{on: colorEnabled(w)} }

// Enabled reports whether this Styler actually emits color.
func (s Styler) Enabled() bool { return s.on }

// OK marks something that succeeded or was found.
func (s Styler) OK(str string) string { return s.wrap(green, str) }

// Warn marks something the user should look at but that isn't fatal.
func (s Styler) Warn(str string) string { return s.wrap(yellow, str) }

// Err marks a failure or a missing prerequisite.
func (s Styler) Err(str string) string { return s.wrap(red, str) }

// Bold emphasizes without implying success or failure.
func (s Styler) Bold(str string) string { return s.wrap(bold, str) }

func (s Styler) wrap(code, str string) string {
	if !s.on || str == "" {
		return str
	}
	return code + str + reset
}

// colorEnabled applies the opt-out rules in order: the two NO_COLOR-style
// env vars, a dumb terminal, then an actual terminal check. On Windows it
// also switches the console into VT mode, without which the escape codes
// would be printed literally in the window opened by double-clicking the exe.
func colorEnabled(w io.Writer) bool {
	if os.Getenv("NO_COLOR") != "" || os.Getenv("DCS_SMS_NO_COLOR") != "" {
		return false
	}
	// Escape hatch for pipelines that do understand color (`| less -R`) and
	// for verifying the styled output by hand. Checked after the opt-outs so
	// NO_COLOR always wins.
	if os.Getenv("DCS_SMS_FORCE_COLOR") != "" {
		return true
	}
	if strings.EqualFold(os.Getenv("TERM"), "dumb") {
		return false
	}
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	if !term.IsTerminal(int(f.Fd())) {
		return false
	}
	return enableVirtualTerminal(f)
}
