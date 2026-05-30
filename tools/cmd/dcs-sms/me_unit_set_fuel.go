package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meUnitSetFuelOpts struct {
	Name		string
	ID		int
	Fuel		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitSetFuelFlags() (*flag.FlagSet, *meUnitSetFuelOpts) {
	opts := &meUnitSetFuelOpts{}
	fs := flag.NewFlagSet("me unit set-fuel", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.Float64Var(&opts.Fuel, "fuel", -1, "fuel mass in kg (>= 0)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "set-fuel", cmdInfo{
		Run:		meUnitSetFuelCmd,
		Flags:		flagsOnly(meUnitSetFuelFlags),
		Synopsis:	"set a unit's fuel level (0..1 or absolute kg)",
	})
}

// meUnitSetFuelCmd implements
// `dcs-sms me unit set-fuel --name|--id <X> --fuel <kg>`.
//
// Sets unit.payload.fuel (kg). Plane / helicopter only. No max validation —
// per-airframe max is in DB.unit_by_type[type], but we mirror the panel's
// behavior of clamping silently rather than refusing.
func meUnitSetFuelCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitSetFuelFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit set-fuel: exactly one of --name or --id is required")
		return 2
	}
	if opts.Fuel < 0 {
		fmt.Fprintln(stderr, "dcs-sms me unit set-fuel: --fuel (>= 0 kg) is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, fuel = %g }", idClause, opts.Fuel)

	resp, exitCode := runMeVerb("unit_set_fuel", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
