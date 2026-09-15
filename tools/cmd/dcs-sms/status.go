package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"path/filepath"
	"time"

	"github.com/nielsvaes/dcs-sms/tools/internal/hookstatus"
	"github.com/nielsvaes/dcs-sms/tools/internal/ui"
)

type statusOpts struct {
	JSON       bool
	SavedGames string
}

func statusFlags() (*flag.FlagSet, *statusOpts) {
	opts := &statusOpts{}
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	fs.BoolVar(&opts.JSON, "json", false, "emit machine-readable JSON")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerInfo("status", cmdInfo{
		Run:      statusCmd,
		Flags:    flagsOnly(statusFlags),
		Synopsis: "report whether the hook is alive and a mission is loaded",
	})
}

// statusCmd prints the hook's current state. Exit codes:
//
//	0 — hook found and heartbeat is fresh
//	2 — flag parse error
//	3 — hook file missing or unreadable (DCS not running, or wrong --saved-games)
//	4 — heartbeat present but stale (DCS may be paused/hung)
func statusCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := statusFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	root, err := resolveRoot(opts.SavedGames)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms status:", err)
		return 3
	}
	stateDir := filepath.Join(root, "dcs-sms", "state")
	st, err := hookstatus.ReadMerged(stateDir)
	if err != nil {
		style := ui.For(stderr)
		fmt.Fprintln(stderr, style.Err("dcs-sms status: hook not found —"), err)
		printSavedGamesDiagnostic(stderr, root, style)
		return 3
	}
	fresh := hookstatus.IsFresh(st, 2*time.Second, time.Now())

	if opts.JSON {
		out := map[string]any{
			"hook_version":       st.HookVersion,
			"state":              st.State,
			"mission_loaded":     st.MissionLoaded,
			"mission_name":       st.MissionName,
			"gui_bridge_enabled": st.GuiBridgeEnabled,
			"tick_source":        st.TickSource,
			"last_frame":         st.LastFrame,
			"last_frame_at":      st.LastFrameAt,
			"last_tick":          st.LastTick,
			"last_tick_at":       st.LastTickAt,
			"fresh":              fresh,
		}
		data, _ := json.Marshal(out)
		fmt.Fprintln(stdout, string(data))
	} else {
		fmt.Fprintf(stdout, "hook version:       %s\n", st.HookVersion)
		if st.State != "" {
			fmt.Fprintf(stdout, "state:              %s\n", st.State)
		}
		fmt.Fprintf(stdout, "mission loaded:     %v\n", st.MissionLoaded)
		if st.MissionName != "" {
			fmt.Fprintf(stdout, "mission name:       %s\n", st.MissionName)
		}
		if st.TickSource != "" {
			fmt.Fprintf(stdout, "tick source:        %s\n", st.TickSource)
		}
		fmt.Fprintf(stdout, "gui bridge enabled: %v\n", st.GuiBridgeEnabled)
		// Prefer the new last_tick fields when populated; fall back to last_frame.
		tick := st.LastTick
		tickAt := st.LastTickAt
		if tick == 0 && tickAt == "" {
			tick = st.LastFrame
			tickAt = st.LastFrameAt
		}
		fmt.Fprintf(stdout, "last tick:          %d (%s)\n", tick, tickAt)
		fmt.Fprintf(stdout, "fresh:              %v\n", fresh)
	}

	if !fresh {
		style := ui.For(stderr)
		fmt.Fprintln(stderr, style.Warn(fmt.Sprintf("dcs-sms status: heartbeat stale (last frame at %s)", st.LastFrameAt)))
		printSavedGamesDiagnostic(stderr, root, style)
		return 4
	}
	return 0
}

// printSavedGamesDiagnostic explains which Saved Games folder was used and,
// when there is more than one on disk, what else is there and how to switch.
//
// Auto-discovery picks the first of DCS / DCS.openbeta / DCS.server that
// exists, so a stale `DCS` folder left over from a stable install shadows the
// `DCS.openbeta` the user actually flies. Without this, the failure is just
// "hook not found" and there is nothing to act on.
func printSavedGamesDiagnostic(stderr io.Writer, root string, style ui.Styler) {
	fmt.Fprintln(stderr, "  looked in:", root)
	variants, ok := listVariantsFn()
	if !ok || len(variants) < 2 {
		return
	}
	fmt.Fprintln(stderr, "  other DCS folders in Saved Games:")
	for _, line := range variantLines(variants, root, style) {
		fmt.Fprintln(stderr, "    "+line)
	}
	if alt, ok := betterCandidate(variants, root); ok {
		fmt.Fprintln(stderr, style.Warn("  That looks like the wrong folder. Pin the live one with:"))
		fmt.Fprintf(stderr, "    dcs-sms set-saved-games \"%s\"\n", alt)
	}
}
