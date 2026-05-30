package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointClearEnrouteTasksOpts struct {
	GroupName	string
	GroupID		int
	Index		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string

	indexSet	bool
}

func meWaypointClearEnrouteTasksFlags() (*flag.FlagSet, *meWaypointClearEnrouteTasksOpts) {
	opts := &meWaypointClearEnrouteTasksOpts{}
	fs := flag.NewFlagSet("me waypoint clear-enroute-tasks", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Index, "index", -1, "waypoint index (0-based; required)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "clear-enroute-tasks", cmdInfo{
		Run:		meWaypointClearEnrouteTasksCmd,
		Flags:		flagsOnly(meWaypointClearEnrouteTasksFlags),
		Synopsis:	"drop all enroute-kind tasks at a waypoint (waypoint kind kept)",
	})
}

func meWaypointClearEnrouteTasksCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointClearEnrouteTasksFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "index" {
			opts.indexSet = true
		}
	})
	hasName := opts.GroupName != ""
	hasID := opts.GroupID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me waypoint clear-enroute-tasks: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.indexSet || opts.Index < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint clear-enroute-tasks: --index is required (integer >= 0)")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s, index = %d }", idClause, opts.Index)
	resp, exitCode := runMeVerb("waypoint_clear_enroute_tasks", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
