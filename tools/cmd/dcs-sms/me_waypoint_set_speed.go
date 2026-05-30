package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointSetSpeedOpts struct {
	GroupName	string
	GroupID		int
	Index		int
	Speed		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string

	indexSet, speedSet	bool
}

func meWaypointSetSpeedFlags() (*flag.FlagSet, *meWaypointSetSpeedOpts) {
	opts := &meWaypointSetSpeedOpts{}
	fs := flag.NewFlagSet("me waypoint set-speed", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Index, "index", -1, "waypoint index (0-based; required)")
	fs.Float64Var(&opts.Speed, "speed", 0, "speed in meters/sec (required, > 0)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "set-speed", cmdInfo{
		Run:		meWaypointSetSpeedCmd,
		Flags:		flagsOnly(meWaypointSetSpeedFlags),
		Synopsis:	"set a waypoint's speed (m/s)",
	})
}

func meWaypointSetSpeedCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointSetSpeedFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "index":
			opts.indexSet = true
		case "speed":
			opts.speedSet = true
		}
	})
	hasName := opts.GroupName != ""
	hasID := opts.GroupID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-speed: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.indexSet || opts.Index < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-speed: --index is required (integer >= 0)")
		return 2
	}
	if !opts.speedSet || opts.Speed <= 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-speed: --speed is required (> 0)")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s, index = %d, speed = %g }", idClause, opts.Index, opts.Speed)
	resp, exitCode := runMeVerb("waypoint_set_speed", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
