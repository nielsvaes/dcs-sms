package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointSetEtaLockedOpts struct {
	GroupName	string
	GroupID		int
	Index		int
	Locked		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string

	indexSet, lockedSet	bool
}

func meWaypointSetEtaLockedFlags() (*flag.FlagSet, *meWaypointSetEtaLockedOpts) {
	opts := &meWaypointSetEtaLockedOpts{}
	fs := flag.NewFlagSet("me waypoint set-eta-locked", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Index, "index", -1, "waypoint index (0-based; required)")
	fs.StringVar(&opts.Locked, "locked", "", "true | false (required)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "set-eta-locked", cmdInfo{
		Run:		meWaypointSetEtaLockedCmd,
		Flags:		flagsOnly(meWaypointSetEtaLockedFlags),
		Synopsis:	"set a waypoint's ETA_locked flag",
	})
}

func meWaypointSetEtaLockedCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointSetEtaLockedFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "index":
			opts.indexSet = true
		case "locked":
			opts.lockedSet = true
		}
	})
	hasName := opts.GroupName != ""
	hasID := opts.GroupID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-eta-locked: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.indexSet || opts.Index < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-eta-locked: --index is required (integer >= 0)")
		return 2
	}
	if !opts.lockedSet {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-eta-locked: --locked is required (true or false)")
		return 2
	}
	v, ok := parseBoolFlag(opts.Locked)
	if !ok {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-eta-locked: --locked must be true or false")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s, index = %d, locked = %t }", idClause, opts.Index, v)
	resp, exitCode := runMeVerb("waypoint_set_eta_locked", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
