package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointSetActionOpts struct {
	GroupName	string
	GroupID		int
	Index		int
	Action		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string

	indexSet	bool
}

func meWaypointSetActionFlags() (*flag.FlagSet, *meWaypointSetActionOpts) {
	opts := &meWaypointSetActionOpts{}
	fs := flag.NewFlagSet("me waypoint set-action", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Index, "index", -1, "waypoint index (0-based; required)")
	fs.StringVar(&opts.Action, "action", "",
		"waypoint action — how the unit traverses or arrives. Legal: "+
			"AIR: \"Turning Point\", \"Fly Over Point\", \"From Parking Area\", "+
			"\"From Parking Area Hot\", \"From Ground Area\", \"From Ground Area Hot\", "+
			"\"From Runway\", \"Landing\", \"LandingReFuAr\". "+
			"GROUND/SHIP TRAVERSAL: \"Off Road\", \"On Road\", \"On Railroads\". "+
			"GROUND FORMATIONS (all need --type=\"Turning Point\"): \"Rank\" (line abreast), "+
			"\"Cone\", \"Vee\", \"Diamond\", \"EchelonL\", \"EchelonR\", \"Custom\" "+
			"(pairs with --formation-template <saved-template-name>).")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "set-action", cmdInfo{
		Run:		meWaypointSetActionCmd,
		Flags:		flagsOnly(meWaypointSetActionFlags),
		Synopsis:	"set a waypoint's action (sms.waypoint.ACTION enum)",
	})
}

func meWaypointSetActionCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointSetActionFlags()
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
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-action: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.indexSet || opts.Index < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-action: --index is required (integer >= 0)")
		return 2
	}
	if opts.Action == "" {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-action: --action is required")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s, index = %d, action = %s }", idClause, opts.Index, luaQuote(opts.Action))
	resp, exitCode := runMeVerb("waypoint_set_action", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
