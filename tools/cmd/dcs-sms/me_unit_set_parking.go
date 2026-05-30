package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meUnitSetParkingOpts struct {
	Name		string
	ID		int
	Airbase		string
	Stand		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitSetParkingFlags() (*flag.FlagSet, *meUnitSetParkingOpts) {
	opts := &meUnitSetParkingOpts{}
	fs := flag.NewFlagSet("me unit set-parking", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.StringVar(&opts.Airbase, "airbase", "",
		"airbase name (case-insensitive, exact preferred, substring fallback). "+
			"The stand is looked up within this airbase's parking list.")
	fs.StringVar(&opts.Stand, "stand", "",
		"stand name as shown in the ME (e.g. \"08\", \"21A\"). Use "+
			"`dcs-sms me airbase get --name <X> --filter plane|helicopter` to "+
			"list available stands. Validates that the stand's category "+
			"matches the unit's group category — refuses on mismatch.")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "set-parking", cmdInfo{
		Run:		meUnitSetParkingCmd,
		Flags:		flagsOnly(meUnitSetParkingFlags),
		Synopsis:	"pin a unit to a specific named parking stand at an airbase (sets parking + parking_id, moves the unit to the stand)",
	})
}

func meUnitSetParkingCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitSetParkingFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit set-parking: exactly one of --name or --id is required")
		return 2
	}
	if opts.Airbase == "" {
		fmt.Fprintln(stderr, "dcs-sms me unit set-parking: --airbase is required")
		return 2
	}
	if opts.Stand == "" {
		fmt.Fprintln(stderr, "dcs-sms me unit set-parking: --stand is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, airbase = %s, stand = %s }",
		idClause, luaQuote(opts.Airbase), luaQuote(opts.Stand))

	resp, exitCode := runMeVerb("unit_set_parking", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
