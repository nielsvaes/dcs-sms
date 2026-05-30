package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meZoneSetLinkOpts struct {
	Name		string
	ID		int
	Unit		string
	UnitID		int
	Clear		bool
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meZoneSetLinkFlags() (*flag.FlagSet, *meZoneSetLinkOpts) {
	opts := &meZoneSetLinkOpts{}
	fs := flag.NewFlagSet("me zone set-link", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "zone name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "zone id (mutually exclusive with --name)")
	fs.StringVar(&opts.Unit, "unit", "", "target unit name (link by name)")
	fs.IntVar(&opts.UnitID, "unit-id", 0, "target unit id (link by id)")
	fs.BoolVar(&opts.Clear, "clear", false, "unlink the zone")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("zone", "set-link", cmdInfo{
		Run:		meZoneSetLinkCmd,
		Flags:		flagsOnly(meZoneSetLinkFlags),
		Synopsis:	"link a zone to a unit so it follows the unit",
	})
}

// meZoneSetLinkCmd implements
// `dcs-sms me zone set-link --name|--id <Z> [--unit <U> | --unit-id <N> | --clear]`.
//
// Links a trigger zone to a unit (the zone's center follows the unit at
// runtime), or clears an existing link. Wraps TZD.linkToUnit /
// TZD.unlinkToUnit. Linking captures the unit's position + heading at
// the moment of the call; runtime then updates the zone as the unit
// moves. Useful for "patrol area follows AWACS" or "no-fly zone around
// this carrier" patterns.
//
// Exactly one action is required:
//   --unit <name>      link to a unit selected by name
//   --unit-id <id>     link to a unit selected by id
//   --clear            unlink the zone
func meZoneSetLinkCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meZoneSetLinkFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me zone set-link: exactly one of --name or --id is required")
		return 2
	}

	hasUnit := opts.Unit != ""
	hasUnitID := opts.UnitID != 0
	hasClear := opts.Clear
	actionCount := 0
	if hasUnit {
		actionCount++
	}
	if hasUnitID {
		actionCount++
	}
	if hasClear {
		actionCount++
	}
	if actionCount != 1 {
		fmt.Fprintln(stderr, "dcs-sms me zone set-link: exactly one of --unit, --unit-id, or --clear is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}

	var actionClause string
	switch {
	case hasUnit:
		actionClause = fmt.Sprintf("unit = %s", luaQuote(opts.Unit))
	case hasUnitID:
		actionClause = fmt.Sprintf("unit_id = %d", opts.UnitID)
	case hasClear:
		actionClause = "clear = true"
	}

	luaArgs := fmt.Sprintf("{ %s, %s }", idClause, actionClause)

	resp, exitCode := runMeVerb("zone_set_link", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
