package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointSetEtaOpts struct {
	GroupName	string
	GroupID		int
	Index		int
	ETA		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string

	indexSet, etaSet	bool
}

func meWaypointSetEtaFlags() (*flag.FlagSet, *meWaypointSetEtaOpts) {
	opts := &meWaypointSetEtaOpts{}
	fs := flag.NewFlagSet("me waypoint set-eta", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Index, "index", -1, "waypoint index (0-based; required)")
	fs.Float64Var(&opts.ETA, "eta", 0, "ETA in seconds (>= 0; required)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "set-eta", cmdInfo{
		Run:		meWaypointSetEtaCmd,
		Flags:		flagsOnly(meWaypointSetEtaFlags),
		Synopsis:	"set a waypoint's ETA in seconds (mission-relative)",
	})
}

func meWaypointSetEtaCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointSetEtaFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "index":
			opts.indexSet = true
		case "eta":
			opts.etaSet = true
		}
	})
	hasName := opts.GroupName != ""
	hasID := opts.GroupID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-eta: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.indexSet || opts.Index < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-eta: --index is required (integer >= 0)")
		return 2
	}
	if !opts.etaSet {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-eta: --eta is required")
		return 2
	}
	if opts.ETA < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-eta: eta must be >= 0")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s, index = %d, eta = %g }", idClause, opts.Index, opts.ETA)
	resp, exitCode := runMeVerb("waypoint_set_eta", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
