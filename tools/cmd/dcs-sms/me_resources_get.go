package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

func init() {
	registerMeInfo("resources", "get", cmdInfo{
		Run:		meResourcesGetCmd,
		Flags:		flagsOnly(meResourcesGetFlags),
		Synopsis:	"read the warehouse / resources entry for an airbase or a ship/structure unit",
	})
}

type meResourcesGetOpts struct {
	Airbase		string
	Unit		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meResourcesGetFlags() (*flag.FlagSet, *meResourcesGetOpts) {
	opts := &meResourcesGetOpts{}
	fs := flag.NewFlagSet("me resources get", flag.ContinueOnError)
	fs.StringVar(&opts.Airbase, "airbase", "", "airbase name (mutually exclusive with --unit)")
	fs.StringVar(&opts.Unit, "unit", "", "unit name or numeric unitId (mutually exclusive with --airbase)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

// meResourcesGetCmd implements `dcs-sms me resources get { --airbase N | --unit ID }`.
//
// Returns the full warehouse entry: coalition, unlimited* flags,
// OperatingLevel_*, fuel sub-tables (jet_fuel/gasoline/diesel/methanol_mixture),
// aircrafts, weapons. Airbase warehouses live at
// mission.AirportsEquipment.airports[airdrome_number]; ship/structure
// warehouses live at mission.AirportsEquipment.warehouses[unitId].
func meResourcesGetCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meResourcesGetFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if (opts.Airbase == "") == (opts.Unit == "") {
		fmt.Fprintln(stderr, "dcs-sms me resources get: exactly one of --airbase or --unit is required")
		return 2
	}

	var luaArgs string
	if opts.Airbase != "" {
		luaArgs = fmt.Sprintf("{ airbase = %s }", luaQuote(opts.Airbase))
	} else {
		luaArgs = fmt.Sprintf("{ unit = %s }", luaQuote(opts.Unit))
	}
	resp, exitCode := runMeVerb("resources_get", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
