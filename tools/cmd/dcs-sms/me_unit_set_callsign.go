package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meUnitSetCallsignOpts struct {
	Name		string
	ID		int
	Callsign	string
	Squadron	int
	Flight		int
	Plane		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitSetCallsignFlags() (*flag.FlagSet, *meUnitSetCallsignOpts) {
	opts := &meUnitSetCallsignOpts{}
	fs := flag.NewFlagSet("me unit set-callsign", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.StringVar(&opts.Callsign, "callsign", "", "callsign label (e.g. \"Enfield11\")")
	fs.IntVar(&opts.Squadron, "squadron", 0, "squadron number (optional; preserves existing if 0)")
	fs.IntVar(&opts.Flight, "flight", 0, "flight number (optional; preserves existing if 0)")
	fs.IntVar(&opts.Plane, "plane", 0, "plane number (optional; preserves existing if 0)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "set-callsign", cmdInfo{
		Run:		meUnitSetCallsignCmd,
		Flags:		flagsOnly(meUnitSetCallsignFlags),
		Synopsis:	"set a unit's radio callsign",
	})
}

// meUnitSetCallsignCmd implements
// `dcs-sms me unit set-callsign --name|--id <X> --callsign <name>`
//   [--squadron <n>] [--flight <n>] [--plane <n>].
//
// Sets the radio-callsign struct on the unit. The internal shape DCS uses is
//
//   callsign = { squadron, flight, plane, name = "Enfield11" }
//
// The callsign name (the radio-readable label) is the most-commonly-changed
// field; --squadron/--flight/--plane indices default to leaving the existing
// numeric values untouched if not passed (current values preserved).
func meUnitSetCallsignCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitSetCallsignFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit set-callsign: exactly one of --name or --id is required")
		return 2
	}
	if opts.Callsign == "" {
		fmt.Fprintln(stderr, "dcs-sms me unit set-callsign: --callsign is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf(
		"{ %s, callsign = %s, squadron = %d, flight = %d, plane = %d }",
		idClause, luaQuote(opts.Callsign), opts.Squadron, opts.Flight, opts.Plane,
	)

	resp, exitCode := runMeVerb("unit_set_callsign", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
