package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointListTasksOpts struct {
	GroupName	string
	GroupID		int
	Kind		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meWaypointListTasksFlags() (*flag.FlagSet, *meWaypointListTasksOpts) {
	opts := &meWaypointListTasksOpts{}
	fs := flag.NewFlagSet("me waypoint list-tasks", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "filter to tasks legal for this group's main task (mutually exclusive with --group-id; omit both to list all)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "filter to tasks legal for this group's main task (mutually exclusive with --group-name)")
	fs.StringVar(&opts.Kind, "kind", "", "optional filter: 'waypoint' or 'enroute' (omit for both)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "list-tasks", cmdInfo{
		Run:		meWaypointListTasksCmd,
		Flags:		flagsOnly(meWaypointListTasksFlags),
		Synopsis:	"list legal task ids from ED's me_action_db, optionally filtered by group and/or --kind",
	})
}

func meWaypointListTasksCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointListTasksFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Kind != "" && opts.Kind != "waypoint" && opts.Kind != "enroute" {
		fmt.Fprintln(stderr, "dcs-sms me waypoint list-tasks: --kind must be 'waypoint' or 'enroute' (or omitted)")
		return 2
	}
	hasName := opts.GroupName != ""
	hasID := opts.GroupID != 0
	if hasName && hasID {
		fmt.Fprintln(stderr, "dcs-sms me waypoint list-tasks: --group-name and --group-id are mutually exclusive")
		return 2
	}
	var luaArgs string
	switch {
	case hasName && opts.Kind != "":
		luaArgs = fmt.Sprintf("{ name = %s, kind = %s }", luaQuote(opts.GroupName), luaQuote(opts.Kind))
	case hasID && opts.Kind != "":
		luaArgs = fmt.Sprintf("{ id = %d, kind = %s }", opts.GroupID, luaQuote(opts.Kind))
	case hasName:
		luaArgs = fmt.Sprintf("{ name = %s }", luaQuote(opts.GroupName))
	case hasID:
		luaArgs = fmt.Sprintf("{ id = %d }", opts.GroupID)
	case opts.Kind != "":
		luaArgs = fmt.Sprintf("{ kind = %s }", luaQuote(opts.Kind))
	default:
		luaArgs = "{}"
	}
	resp, exitCode := runMeVerb("waypoint_list_tasks", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
