package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meUnitSetGunOpts struct {
	Name		string
	ID		int
	Percent		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitSetGunFlags() (*flag.FlagSet, *meUnitSetGunOpts) {
	opts := &meUnitSetGunOpts{}
	fs := flag.NewFlagSet("me unit set-gun", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.Float64Var(&opts.Percent, "percent", -1, "gun ammo percent (0-100)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "set-gun", cmdInfo{
		Run:		meUnitSetGunCmd,
		Flags:		flagsOnly(meUnitSetGunFlags),
		Synopsis:	"set a unit's gun ammunition percentage",
	})
}

// meUnitSetGunCmd implements
// `dcs-sms me unit set-gun --name|--id <X> --percent <0-100>`.
//
// Sets unit.payload.gun (gun ammunition percent). Plane / helicopter only.
func meUnitSetGunCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitSetGunFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit set-gun: exactly one of --name or --id is required")
		return 2
	}
	if opts.Percent < 0 || opts.Percent > 100 {
		fmt.Fprintln(stderr, "dcs-sms me unit set-gun: --percent (0-100) is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, percent = %g }", idClause, opts.Percent)

	resp, exitCode := runMeVerb("unit_set_gun", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
