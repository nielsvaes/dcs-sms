package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meUnitSetLoadoutOpts struct {
	Name		string
	ID		int
	Loadout		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitSetLoadoutFlags() (*flag.FlagSet, *meUnitSetLoadoutOpts) {
	opts := &meUnitSetLoadoutOpts{}
	fs := flag.NewFlagSet("me unit set-loadout", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.StringVar(&opts.Loadout, "loadout", "", "loadout name (e.g. \"CAP\", \"CAS\", \"Empty\")")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "set-loadout", cmdInfo{
		Run:		meUnitSetLoadoutCmd,
		Flags:		flagsOnly(meUnitSetLoadoutFlags),
		Synopsis:	"apply a named loadout preset to a unit",
	})
}

// meUnitSetLoadoutCmd implements
// `dcs-sms me unit set-loadout --name|--id <X> --loadout "<name>"`.
//
// Applies a named loadout (e.g. "CAP", "CAS", "Empty") to a plane/heli unit.
// The loadout name must match one of the airframe's pre-defined loadouts —
// inspect them in MissionEditor/data/scripts/UnitPayloads/<type>.lua or the
// ME's payload-panel dropdown.
//
// Replaces all pylons. Does not touch chaff / flare / fuel / gun — use
// `me unit set-chaff` etc. for those.
func meUnitSetLoadoutCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitSetLoadoutFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit set-loadout: exactly one of --name or --id is required")
		return 2
	}
	if opts.Loadout == "" {
		fmt.Fprintln(stderr, "dcs-sms me unit set-loadout: --loadout is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, loadout = %s }", idClause, luaQuote(opts.Loadout))

	resp, exitCode := runMeVerb("unit_set_loadout", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
