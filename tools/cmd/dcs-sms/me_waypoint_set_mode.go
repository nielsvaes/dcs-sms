package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointSetModeOpts struct {
	GroupName	string
	GroupID		int
	Index		int
	Mode		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string

	indexSet	bool
}

func meWaypointSetModeFlags() (*flag.FlagSet, *meWaypointSetModeOpts) {
	opts := &meWaypointSetModeOpts{}
	fs := flag.NewFlagSet("me waypoint set-mode", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Index, "index", -1, "waypoint index (0-based; required)")
	fs.StringVar(&opts.Mode, "mode", "",
		"ME UI mode name (case-insensitive); sets wpt.type and wpt.action together. "+
			"AIR: \"Turning point\", \"Fly over point\", \"Takeoff from runway\", "+
			"\"Takeoff from parking\", \"Takeoff from parking hot\", "+
			"\"Takeoff from ground\", \"Takeoff from ground hot\", \"Landing\", "+
			"\"LandingReFuAr\". GROUND: \"Off road\", \"On road\", \"On railroads\". "+
			"GROUND FORMATIONS: \"Rank\" (= \"Line abreast\"), \"Cone\", \"Vee\", "+
			"\"Diamond\", \"Echelon left\", \"Echelon right\", \"Custom\".")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "set-mode", cmdInfo{
		Run:		meWaypointSetModeCmd,
		Flags:		flagsOnly(meWaypointSetModeFlags),
		Synopsis:	"set a waypoint's type+action together via ME-style picker name (Landing, Takeoff from parking, Off road, Cone, …)",
	})
}

func meWaypointSetModeCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointSetModeFlags()
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
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-mode: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.indexSet || opts.Index < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-mode: --index is required (integer >= 0)")
		return 2
	}
	if opts.Mode == "" {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-mode: --mode is required")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s, index = %d, mode = %s }", idClause, opts.Index, luaQuote(opts.Mode))
	resp, exitCode := runMeVerb("waypoint_set_mode", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
