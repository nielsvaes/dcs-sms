package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meUnitSetHeadingOpts struct {
	Name		string
	ID		int
	Heading		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitSetHeadingFlags() (*flag.FlagSet, *meUnitSetHeadingOpts) {
	opts := &meUnitSetHeadingOpts{}
	fs := flag.NewFlagSet("me unit set-heading", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.Float64Var(&opts.Heading, "heading", 0,
		"heading in degrees (0 = north, clockwise positive)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "set-heading", cmdInfo{
		Run:		meUnitSetHeadingCmd,
		Flags:		flagsOnly(meUnitSetHeadingFlags),
		Synopsis:	"set a unit's heading in degrees",
	})
}

// meUnitSetHeadingCmd implements
// `dcs-sms me unit set-heading --name|--id <X> --heading <degrees>`.
//
// Takes degrees on the CLI (more natural than radians); the Lua verb
// converts to radians for storage. DCS uses radians internally with
// 0 = north and clockwise = positive (compass direction).
//
// Updates both u.heading and u.psi — they're stored separately but the ME
// keeps them in sync; we mirror that.
func meUnitSetHeadingCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitSetHeadingFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit set-heading: exactly one of --name or --id is required")
		return 2
	}
	headingSet := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "heading" {
			headingSet = true
		}
	})
	if !headingSet {
		fmt.Fprintln(stderr, "dcs-sms me unit set-heading: --heading is required (degrees)")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, heading_deg = %g }", idClause, opts.Heading)

	resp, exitCode := runMeVerb("unit_set_heading", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
