package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointListTasksOpts struct {
	Kind       string
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
}

func meWaypointListTasksFlags() (*flag.FlagSet, *meWaypointListTasksOpts) {
	opts := &meWaypointListTasksOpts{}
	fs := flag.NewFlagSet("me waypoint list-tasks", flag.ContinueOnError)
	fs.StringVar(&opts.Kind, "kind", "", "optional filter: 'waypoint' or 'enroute' (omit for both)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "list-tasks", cmdInfo{
		Run:      meWaypointListTasksCmd,
		Flags:    flagsOnly(meWaypointListTasksFlags),
		Synopsis: "list legal task ids from ED's me_action_db, optionally filtered by --kind",
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
	var luaArgs string
	if opts.Kind == "" {
		luaArgs = "{}"
	} else {
		luaArgs = fmt.Sprintf("{ kind = %q }", opts.Kind)
	}
	resp, exitCode := runMeVerb("waypoint_list_tasks", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
