package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointAddTaskOpts struct {
	GroupName  string
	GroupID    int
	Index      int
	Task       string
	Timeout    time.Duration
	Pretty     bool
	SavedGames string

	indexSet bool
}

func meWaypointAddTaskFlags() (*flag.FlagSet, *meWaypointAddTaskOpts) {
	opts := &meWaypointAddTaskOpts{}
	fs := flag.NewFlagSet("me waypoint add-task", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Index, "index", -1, "waypoint index (0-based; required)")
	fs.StringVar(&opts.Task, "task", "", "task id from me_action_db (e.g. Bombing, AttackGroup, Orbit). "+
		"Run `me waypoint list-tasks --kind waypoint` to see legal ids.")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "add-task", cmdInfo{
		Run:      meWaypointAddTaskCmd,
		Flags:    flagsOnly(meWaypointAddTaskFlags),
		Synopsis: "append a waypoint-kind task to a waypoint's ComboTask",
	})
}

func meWaypointAddTaskCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointAddTaskFlags()
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
		fmt.Fprintln(stderr, "dcs-sms me waypoint add-task: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.indexSet || opts.Index < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint add-task: --index is required (integer >= 0)")
		return 2
	}
	if opts.Task == "" {
		fmt.Fprintln(stderr, "dcs-sms me waypoint add-task: --task is required")
		return 2
	}
	fields, err := parseTriggerFieldArgs(fs.Args())
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me waypoint add-task:", err)
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %q", opts.GroupName)
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s, index = %d, task = %q, fields = %s }",
		idClause, opts.Index, opts.Task, buildLuaFieldsExpr(fields))
	resp, exitCode := runMeVerb("waypoint_add_task", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
