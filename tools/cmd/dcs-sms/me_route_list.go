package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meRouteListOpts struct {
	GroupName	string
	GroupID		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meRouteListFlags() (*flag.FlagSet, *meRouteListOpts) {
	opts := &meRouteListOpts{}
	fs := flag.NewFlagSet("me route list", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("route", "list", cmdInfo{
		Run:		meRouteListCmd,
		Flags:		flagsOnly(meRouteListFlags),
		Synopsis:	"list waypoints on a group's route (compact summary per WP). A WP's speed/ETA is the value on arrival at that WP (the inbound leg), not the departure leg; WP0 (takeoff) and the final (landing) WP carry a DCS placeholder speed, not a cruise speed.",
	})
}

// meRouteListCmd implements `dcs-sms me route list --group-name|--group-id`.
// Returns each waypoint's index, type, action, north/east, alt/alt_type, speed,
// name, eta, and a has_task flag.
func meRouteListCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meRouteListFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.GroupName != ""
	hasID := opts.GroupID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me route list: exactly one of --group-name or --group-id is required")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s }", idClause)
	resp, exitCode := runMeVerb("route_list", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
