package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/nielsvaes/dcs-sms/tools/internal/dcspath"
	"github.com/nielsvaes/dcs-sms/tools/internal/hookstatus"
	"github.com/nielsvaes/dcs-sms/tools/internal/ui"
)

// Shared helpers for describing the DCS variant folders under Saved Games.
//
// Users routinely end up with more than one (a stale `DCS` left over from a
// stable install next to the `DCS.openbeta` they actually fly), and
// auto-discovery picks the first that exists. When it picks the wrong one
// every bridge command fails with an unhelpful "hook not found". These
// helpers let the menu, `status` and `set-saved-games` all show the same
// annotated picture of what is on disk.

// liveWindow is how recently a heartbeat must have been written for a folder
// to count as the one DCS is using right now. Deliberately looser than the
// 2s freshness check in `status`: here we only need "this is the live one",
// not "the mission is ticking".
const liveWindow = 30 * time.Second

type variantInfo struct {
	Path     string
	HasHook  bool
	HasState bool
	LastSeen time.Time
}

// inspectVariant reports what is installed in a single Saved Games variant
// folder without requiring DCS to be running.
func inspectVariant(path string) variantInfo {
	v := variantInfo{Path: path}
	if st, err := os.Stat(filepath.Join(path, "Scripts", "Hooks", "dcs-sms-hook.lua")); err == nil && !st.IsDir() {
		v.HasHook = true
	}
	st, err := hookstatus.ReadMerged(filepath.Join(path, "dcs-sms", "state"))
	if err != nil {
		return v
	}
	v.HasState = true
	stamp := st.LastFrameAt
	if stamp == "" {
		stamp = st.LastTickAt
	}
	if t, err := time.Parse(time.RFC3339Nano, stamp); err == nil {
		v.LastSeen = t
	}
	return v
}

// describe renders the one-phrase annotation shown next to a folder.
func (v variantInfo) describe(now time.Time) string {
	if !v.HasHook {
		return "no hook installed"
	}
	if !v.HasState || v.LastSeen.IsZero() {
		return "hook installed, never run"
	}
	age := now.Sub(v.LastSeen)
	if age < liveWindow {
		return "hook installed, running now"
	}
	return "hook installed, last seen " + humanAge(age) + " ago"
}

// live reports whether DCS wrote to this folder recently enough that it is
// almost certainly the one in use.
func (v variantInfo) live(now time.Time) bool {
	return v.HasHook && !v.LastSeen.IsZero() && now.Sub(v.LastSeen) < liveWindow
}

// humanAge renders a duration in the coarsest unit that still reads clearly.
func humanAge(d time.Duration) string {
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours())/24)
	}
}

// variantLines renders one aligned, annotated line per folder. selected is
// the path auto-discovery resolved to (may be empty); it gets an "in use"
// marker so a mismatch between "in use" and "running now" is obvious at a
// glance — that mismatch is exactly the bug users hit.
func variantLines(paths []string, selected string, st ui.Styler) []string {
	now := time.Now()
	width := 0
	for _, p := range paths {
		if n := len(filepath.Base(p)); n > width {
			width = n
		}
	}
	lines := make([]string, 0, len(paths))
	for _, p := range paths {
		v := inspectVariant(p)
		note := v.describe(now)
		switch {
		case v.live(now):
			note = st.OK(note)
		case !v.HasHook:
			note = st.Warn(note)
		}
		line := fmt.Sprintf("%-*s  %s", width, filepath.Base(p), note)
		if selected != "" && sameDir(p, selected) {
			line += st.Bold("  <- in use")
		}
		lines = append(lines, line)
	}
	return lines
}

// betterCandidate picks the folder the user should probably switch to, if
// there is one. It returns false when the current folder is already the best
// guess — a user whose setup is fine must not be told to move.
//
// Only two situations justify a suggestion:
//
//  1. Another folder is *live* — DCS wrote a heartbeat there within
//     liveWindow — while the current one is not. This is the real bug: the
//     hook is running in the folder nobody is reading.
//  2. The current folder has no hook installed at all, and another does.
//
// Deliberately NOT a reason: another folder merely having an older-but-
// non-zero heartbeat. Comparing recency against the current folder's
// LastSeen is wrong when that is the zero time, which is the normal state of
// a correct folder DCS has not been launched in since `dcs-sms setup` — an
// abandoned folder from two years ago would win. A candidate must also have a
// hook, since `teardown` removes the hook but leaves dcs-sms/state behind.
func betterCandidate(variants []string, current string) (string, bool) {
	if len(variants) < 2 || current == "" {
		return "", false
	}
	now := time.Now()
	cur := inspectVariant(current)
	if cur.live(now) {
		return "", false
	}
	for _, p := range variants {
		if sameDir(p, current) {
			continue
		}
		if inspectVariant(p).live(now) {
			return p, true
		}
	}
	if !cur.HasHook {
		for _, p := range variants {
			if !sameDir(p, current) && inspectVariant(p).HasHook {
				return p, true
			}
		}
	}
	return "", false
}

// sameDir compares two paths for equality, tolerating the separator and
// casing differences you get between a config value a user pasted and a path
// we built with filepath.Join.
func sameDir(a, b string) bool {
	ca, err1 := filepath.Abs(filepath.Clean(a))
	cb, err2 := filepath.Abs(filepath.Clean(b))
	if err1 != nil || err2 != nil {
		return filepath.Clean(a) == filepath.Clean(b)
	}
	return pathsEqual(ca, cb)
}

// resolveRootFor resolves the Saved Games folder against an explicit config
// path, falling back to the process default when none is given. The menu
// passes the path injected through menuDeps so its banner reads the same file
// option 6 writes to — resolveRoot alone always reads the process default.
func resolveRootFor(configPath string) (string, error) {
	if configPath == "" {
		configPath, _ = configPathFn()
	}
	return dcspath.Discover("", configPath)
}

// envOverrideNote reports the DCS_SMS_SAVED_GAMES value when it is set and
// points somewhere other than path. That variable is resolved ahead of the
// config file, so pinning a folder while it is set silently has no effect —
// and install-me-mod tells users to set it when discovery fails, so this is a
// trap people actually walk into.
func envOverrideNote(path string) (string, bool) {
	v, ok := dcspath.DiscoverFromEnv()
	if !ok || sameDir(v, path) {
		return "", false
	}
	return v, true
}

// plainStyler returns a never-colorizing Styler, for tests and for code
// paths that assemble strings before they know where they will be written.
func plainStyler() ui.Styler { return ui.Styler{} }
