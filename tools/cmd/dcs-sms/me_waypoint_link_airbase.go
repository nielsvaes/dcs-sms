package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointLinkAirbaseOpts struct {
	GroupName	string
	GroupID		int
	Index		int
	Airbase		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string

	indexSet	bool
}

func meWaypointLinkAirbaseFlags() (*flag.FlagSet, *meWaypointLinkAirbaseOpts) {
	opts := &meWaypointLinkAirbaseOpts{}
	fs := flag.NewFlagSet("me waypoint link-airbase", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Index, "index", -1, "waypoint index (0-based; required)")
	fs.StringVar(&opts.Airbase, "airbase", "",
		"airbase name (case-insensitive, exact preferred, substring fallback). "+
			"Sets wpt.airdromeId, moves the waypoint to the airbase position, "+
			"and clears any conflicting helipad/grass-strip linkage. For "+
			"TakeOffParking / TakeOffParkingHot waypoints, ALSO positions each "+
			"unit at a parking stand at the airbase (via me_parking). For "+
			"TakeOff (runway), positions the group at the runway threshold. "+
			"Pair with `set-mode Landing` (or Takeoff*) to specify the flight "+
			"phase first.")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "link-airbase", cmdInfo{
		Run:		meWaypointLinkAirbaseCmd,
		Flags:		flagsOnly(meWaypointLinkAirbaseFlags),
		Synopsis:	"link a waypoint to a specific airbase (sets airdromeId + moves WP to airbase position)",
	})
}

func meWaypointLinkAirbaseCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointLinkAirbaseFlags()
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
		fmt.Fprintln(stderr, "dcs-sms me waypoint link-airbase: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.indexSet || opts.Index < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint link-airbase: --index is required (integer >= 0)")
		return 2
	}
	if opts.Airbase == "" {
		fmt.Fprintln(stderr, "dcs-sms me waypoint link-airbase: --airbase is required")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s, index = %d, airbase = %s }", idClause, opts.Index, luaQuote(opts.Airbase))
	resp, exitCode := runMeVerb("waypoint_link_airbase", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
