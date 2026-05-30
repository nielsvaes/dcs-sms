package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meRouteGetOpts struct {
	GroupName	string
	GroupID		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meRouteGetFlags() (*flag.FlagSet, *meRouteGetOpts) {
	opts := &meRouteGetOpts{}
	fs := flag.NewFlagSet("me route get", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("route", "get", cmdInfo{
		Run:		meRouteGetCmd,
		Flags:		flagsOnly(meRouteGetFlags),
		Synopsis:	"get a group's full route table (waypoints with all fields, task subtrees preserved)",
	})
}

func meRouteGetCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meRouteGetFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.GroupName != ""
	hasID := opts.GroupID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me route get: exactly one of --group-name or --group-id is required")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s }", idClause)
	resp, exitCode := runMeVerb("route_get", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
