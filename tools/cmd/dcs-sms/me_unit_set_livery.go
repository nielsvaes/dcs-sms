package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meUnitSetLiveryOpts struct {
	Name		string
	ID		int
	Livery		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitSetLiveryFlags() (*flag.FlagSet, *meUnitSetLiveryOpts) {
	opts := &meUnitSetLiveryOpts{}
	fs := flag.NewFlagSet("me unit set-livery", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.StringVar(&opts.Livery, "livery", "", "livery id (airframe-specific; empty = default)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "set-livery", cmdInfo{
		Run:		meUnitSetLiveryCmd,
		Flags:		flagsOnly(meUnitSetLiveryFlags),
		Synopsis:	"set a unit's livery id",
	})
}

// meUnitSetLiveryCmd implements `dcs-sms me unit set-livery --name|--id <X> --livery <L>`.
//
// Livery id is a string matching the airframe's livery folder name (e.g.
// "Aggressors USAF" / "USAF Standard" — depends on airframe). Empty string
// "" means default. The ME does not validate the value — an unknown livery
// just falls back to default at runtime.
func meUnitSetLiveryCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitSetLiveryFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit set-livery: exactly one of --name or --id is required")
		return 2
	}
	// --livery may be empty string explicitly (means "default") — require fs.Visit.
	liverySet := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "livery" {
			liverySet = true
		}
	})
	if !liverySet {
		fmt.Fprintln(stderr, "dcs-sms me unit set-livery: --livery is required (use --livery=\"\" for default)")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, livery = %s }", idClause, luaQuote(opts.Livery))

	resp, exitCode := runMeVerb("unit_set_livery", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
