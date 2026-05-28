package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointRemoveEnrouteTaskOpts struct {
	GroupName  string
	GroupID    int
	Index      int
	Slot       int
	Timeout    time.Duration
	Pretty     bool
	SavedGames string

	indexSet bool
	slotSet  bool
}

func meWaypointRemoveEnrouteTaskFlags() (*flag.FlagSet, *meWaypointRemoveEnrouteTaskOpts) {
	opts := &meWaypointRemoveEnrouteTaskOpts{}
	fs := flag.NewFlagSet("me waypoint remove-enroute-task", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Index, "index", -1, "waypoint index (0-based; required)")
	fs.IntVar(&opts.Slot, "slot", 0, "1-based slot in wp.task.params.tasks (required)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "remove-enroute-task", cmdInfo{
		Run:      meWaypointRemoveEnrouteTaskCmd,
		Flags:    flagsOnly(meWaypointRemoveEnrouteTaskFlags),
		Synopsis: "remove an enroute-kind task by 1-based slot",
	})
}

func meWaypointRemoveEnrouteTaskCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointRemoveEnrouteTaskFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "index" {
			opts.indexSet = true
		}
		if f.Name == "slot" {
			opts.slotSet = true
		}
	})
	hasName := opts.GroupName != ""
	hasID := opts.GroupID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me waypoint remove-enroute-task: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.indexSet || opts.Index < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint remove-enroute-task: --index is required (integer >= 0)")
		return 2
	}
	if !opts.slotSet || opts.Slot < 1 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint remove-enroute-task: --slot is required (integer >= 1)")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %q", opts.GroupName)
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s, index = %d, slot = %d }",
		idClause, opts.Index, opts.Slot)
	resp, exitCode := runMeVerb("waypoint_remove_enroute_task", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
