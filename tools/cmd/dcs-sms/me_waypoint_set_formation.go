package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointSetFormationOpts struct {
	GroupName		string
	GroupID			int
	Index			int
	FormationTemplate	string
	Timeout			time.Duration
	Pretty			bool
	SavedGames		string

	indexSet, formationSet	bool
}

func meWaypointSetFormationFlags() (*flag.FlagSet, *meWaypointSetFormationOpts) {
	opts := &meWaypointSetFormationOpts{}
	fs := flag.NewFlagSet("me waypoint set-formation", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Index, "index", -1, "waypoint index (0-based; required)")
	fs.StringVar(&opts.FormationTemplate, "formation-template", "",
		"name of a saved CUSTOM formation template (vehicle/ship). Only meaningful "+
			"when the waypoint's --action is \"Custom\"; for preset formations like "+
			"Cone/Vee/Diamond/Rank/EchelonL/EchelonR/Off Road/On Road, use --action "+
			"directly and leave this empty. Empty string is the default and is "+
			"legal for every preset action.")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "set-formation", cmdInfo{
		Run:		meWaypointSetFormationCmd,
		Flags:		flagsOnly(meWaypointSetFormationFlags),
		Synopsis:	"set a waypoint's formation_template (name of saved Custom formation; preset formations use --action)",
	})
}

func meWaypointSetFormationCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointSetFormationFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "index":
			opts.indexSet = true
		case "formation-template":
			opts.formationSet = true
		}
	})
	hasName := opts.GroupName != ""
	hasID := opts.GroupID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-formation: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.indexSet || opts.Index < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-formation: --index is required (integer >= 0)")
		return 2
	}
	if !opts.formationSet {
		fmt.Fprintln(stderr, "dcs-sms me waypoint set-formation: --formation-template is required (empty allowed)")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.GroupName))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.GroupID)
	}
	luaArgs := fmt.Sprintf("{ %s, index = %d, formation_template = %s }", idClause, opts.Index, luaQuote(opts.FormationTemplate))
	resp, exitCode := runMeVerb("waypoint_set_formation", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
