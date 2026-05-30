package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meRouteClearOpts struct {
	GroupName	string
	GroupID		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meRouteClearFlags() (*flag.FlagSet, *meRouteClearOpts) {
	opts := &meRouteClearOpts{}
	fs := flag.NewFlagSet("me route clear", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("route", "clear", cmdInfo{
		Run:		meRouteClearCmd,
		Flags:		flagsOnly(meRouteClearFlags),
		Synopsis:	"remove all waypoints from a group's route (air groups refused)",
	})
}

// meRouteClearCmd implements `dcs-sms me route clear --group-name|--group-id`.
// Refused for plane/helicopter groups (would leave 0 WPs; ME rejects on save).
func meRouteClearCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meRouteClearFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.GroupName != ""
	hasID := opts.GroupID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me route clear: exactly one of --group-name or --group-id is required")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s }", idClause)
	resp, exitCode := runMeVerb("route_clear", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
