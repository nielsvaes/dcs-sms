package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointSetTypeOpts struct {
	GroupName	string
	GroupID		int
	Index		int
	WpType		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string

	indexSet	bool
}

func meWaypointSetTypeFlags() (*flag.FlagSet, *meWaypointSetTypeOpts) {
	opts := &meWaypointSetTypeOpts{}
	fs := flag.NewFlagSet("me waypoint set-type", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Index, "index", -1, "waypoint index (0-based; required)")
	fs.StringVar(&opts.WpType, "type", "",
		"waypoint type — the flight-phase / arrival/departure mode. Legal: "+
			"\"Turning Point\" (used by every turning-point + ground-formation mode), "+
			"\"TakeOff\" (from runway), \"TakeOffParking\", \"TakeOffParkingHot\", "+
			"\"TakeOffGround\", \"TakeOffGroundHot\", \"Land\", \"LandingReFuAr\", "+
			"\"On Railroads\". Ground formations (Off Road, Cone, Vee, Diamond, Rank, "+
			"EchelonL/R, Custom) are NOT here — they're in --action.")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "set-type", cmdInfo{
		Run:		meWaypointSetTypeCmd,
		Flags:		flagsOnly(meWaypointSetTypeFlags),
		Synopsis:	"set a waypoint's type (sms.waypoint.TYPE enum)",
	})
}

func meWaypointSetTypeCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointSetTypeFlags()
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
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-type: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.indexSet || opts.Index < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-type: --index is required (integer >= 0)")
		return 2
	}
	if opts.WpType == "" {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-type: --type is required")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s, index = %d, wp_type = %s }", idClause, opts.Index, luaQuote(opts.WpType))
	resp, exitCode := runMeVerb("waypoint_set_type", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
