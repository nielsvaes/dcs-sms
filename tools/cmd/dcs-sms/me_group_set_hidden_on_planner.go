package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupSetHiddenOnPlannerOpts struct {
	Name       string
	ID         int
	Hidden     bool
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
}

func meGroupSetHiddenOnPlannerFlags() (*flag.FlagSet, *meGroupSetHiddenOnPlannerOpts) {
	opts := &meGroupSetHiddenOnPlannerOpts{}
	fs := flag.NewFlagSet("me group set-hidden-on-planner", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "group name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "group id (mutually exclusive with --name)")
	fs.BoolVar(&opts.Hidden, "hidden", false, "hide on planner (true) or show (false); pass explicitly")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "set-hidden-on-planner", cmdInfo{
		Run:      meGroupSetHiddenOnPlannerCmd,
		Flags:    flagsOnly(meGroupSetHiddenOnPlannerFlags),
		Synopsis: "toggle a group's HIDDEN ON PLANNER flag",
	})
}

// meGroupSetHiddenOnPlannerCmd implements `dcs-sms me group set-hidden-on-planner --name|--id <X> --hidden=true|false`.
//
// Toggles g.hiddenOnPlanner. Same explicit-bool convention as
// `me group set-hidden`: --hidden MUST be passed (--hidden=true or
// --hidden=false) so we can distinguish "user wants false" from
// "user forgot".
//
// This is the planner-pane visibility flag, separate from g.hidden
// (the F10 map flag) and g.hiddenOnMFD (the cockpit MFD flag).
func meGroupSetHiddenOnPlannerCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupSetHiddenOnPlannerFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me group set-hidden-on-planner: exactly one of --name or --id is required")
		return 2
	}
	hiddenSet := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "hidden" {
			hiddenSet = true
		}
	})
	if !hiddenSet {
		fmt.Fprintln(stderr, "dcs-sms me group set-hidden-on-planner: --hidden=true|false is required (pass explicitly)")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %q", opts.Name)
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, hidden = %t }", idClause, opts.Hidden)

	resp, exitCode := runMeVerb("group_set_hidden_on_planner", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
