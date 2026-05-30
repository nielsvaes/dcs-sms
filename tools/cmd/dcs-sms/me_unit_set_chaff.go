package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meUnitSetChaffOpts struct {
	Name		string
	ID		int
	Count		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitSetChaffFlags() (*flag.FlagSet, *meUnitSetChaffOpts) {
	opts := &meUnitSetChaffOpts{}
	fs := flag.NewFlagSet("me unit set-chaff", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.IntVar(&opts.Count, "count", -1, "chaff count (>= 0)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "set-chaff", cmdInfo{
		Run:		meUnitSetChaffCmd,
		Flags:		flagsOnly(meUnitSetChaffFlags),
		Synopsis:	"set a unit's chaff count",
	})
}

// meUnitSetChaffCmd implements
// `dcs-sms me unit set-chaff --name|--id <X> --count <N>`.
//
// Sets unit.payload.chaff (count). Plane / helicopter only.
func meUnitSetChaffCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitSetChaffFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit set-chaff: exactly one of --name or --id is required")
		return 2
	}
	if opts.Count < 0 {
		fmt.Fprintln(stderr, "dcs-sms me unit set-chaff: --count (>= 0) is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, count = %d }", idClause, opts.Count)

	resp, exitCode := runMeVerb("unit_set_chaff", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
