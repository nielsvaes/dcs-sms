package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointSetPosOpts struct {
	GroupName	string
	GroupID		int
	Index		int
	North		float64
	East		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string

	indexSet, northSet, eastSet	bool
}

func meWaypointSetPosFlags() (*flag.FlagSet, *meWaypointSetPosOpts) {
	opts := &meWaypointSetPosOpts{}
	fs := flag.NewFlagSet("me waypoint set-pos", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Index, "index", -1, "waypoint index (0-based; required)")
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin (required)")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin (required)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "set-pos", cmdInfo{
		Run:		meWaypointSetPosCmd,
		Flags:		flagsOnly(meWaypointSetPosFlags),
		Synopsis:	"move a waypoint to a new north/east coordinate",
	})
}

func meWaypointSetPosCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointSetPosFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "index":
			opts.indexSet = true
		case "north":
			opts.northSet = true
		case "east":
			opts.eastSet = true
		}
	})
	hasName := opts.GroupName != ""
	hasID := opts.GroupID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-pos: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.indexSet || opts.Index < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-pos: --index is required (integer >= 0)")
		return 2
	}
	if !opts.northSet || !opts.eastSet {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-pos: --north and --east are both required")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s, index = %d, north = %g, east = %g }", idClause, opts.Index, opts.North, opts.East)
	resp, exitCode := runMeVerb("waypoint_set_pos", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
