package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointSetAltOpts struct {
	GroupName	string
	GroupID		int
	Index		int
	Alt		float64
	AltType		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string

	indexSet, altSet, altTypeSet	bool
}

func meWaypointSetAltFlags() (*flag.FlagSet, *meWaypointSetAltOpts) {
	opts := &meWaypointSetAltOpts{}
	fs := flag.NewFlagSet("me waypoint set-alt", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Index, "index", -1, "waypoint index (0-based; required)")
	fs.Float64Var(&opts.Alt, "alt", 0, "altitude meters above sea level (required, >= 0)")
	fs.StringVar(&opts.AltType, "alt-type", "", "altitude reference: BARO or RADIO (optional)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "set-alt", cmdInfo{
		Run:		meWaypointSetAltCmd,
		Flags:		flagsOnly(meWaypointSetAltFlags),
		Synopsis:	"set a waypoint's altitude (optionally also its alt-type)",
	})
}

func meWaypointSetAltCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointSetAltFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "index":
			opts.indexSet = true
		case "alt":
			opts.altSet = true
		case "alt-type":
			opts.altTypeSet = true
		}
	})
	hasName := opts.GroupName != ""
	hasID := opts.GroupID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-alt: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.indexSet || opts.Index < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-alt: --index is required (integer >= 0)")
		return 2
	}
	if !opts.altSet {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-alt: --alt is required")
		return 2
	}
	if opts.altTypeSet && opts.AltType != "BARO" && opts.AltType != "RADIO" {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-alt: --alt-type must be BARO or RADIO")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s, index = %d, alt = %g", idClause, opts.Index, opts.Alt)
	if opts.altTypeSet {
		luaArgs += fmt.Sprintf(", alt_type = %s", luaQuote(opts.AltType))
	}
	luaArgs += " }"
	resp, exitCode := runMeVerb("waypoint_set_alt", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
