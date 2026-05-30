package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meUnitSetAltOpts struct {
	Name		string
	ID		int
	Alt		float64
	AltType		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitSetAltFlags() (*flag.FlagSet, *meUnitSetAltOpts) {
	opts := &meUnitSetAltOpts{}
	fs := flag.NewFlagSet("me unit set-alt", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.Float64Var(&opts.Alt, "alt", 0, "altitude in meters above sea level")
	fs.StringVar(&opts.AltType, "alt-type", "BARO", "altitude type: BARO | RADIO")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "set-alt", cmdInfo{
		Run:		meUnitSetAltCmd,
		Flags:		flagsOnly(meUnitSetAltFlags),
		Synopsis:	"set a unit's altitude in meters",
	})
}

// meUnitSetAltCmd implements
// `dcs-sms me unit set-alt --name|--id <X> --alt <m> [--alt-type BARO|RADIO]`.
//
// Sets both u.alt (meters) and u.alt_type. Default --alt-type is BARO
// (most common for fixed-wing). For helicopters operating in low-level
// terrain-following, RADIO altitude is typical.
//
// Only updates the unit's altitude — not the route's. If you also need to
// update waypoint altitudes you'll have to issue a separate verb (not yet
// shipped — open question whether unit-vs-waypoint should auto-sync).
func meUnitSetAltCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitSetAltFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit set-alt: exactly one of --name or --id is required")
		return 2
	}
	altSet := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "alt" {
			altSet = true
		}
	})
	if !altSet {
		fmt.Fprintln(stderr, "dcs-sms me unit set-alt: --alt is required (meters)")
		return 2
	}
	altType := strings.ToUpper(opts.AltType)
	if altType != "BARO" && altType != "RADIO" {
		fmt.Fprintln(stderr, "dcs-sms me unit set-alt: --alt-type must be BARO or RADIO")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, alt = %g, alt_type = %s }", idClause, opts.Alt, luaQuote(altType))

	resp, exitCode := runMeVerb("unit_set_alt", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
