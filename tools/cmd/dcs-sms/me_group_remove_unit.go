package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupRemoveUnitOpts struct {
	Name		string
	ID		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupRemoveUnitFlags() (*flag.FlagSet, *meGroupRemoveUnitOpts) {
	opts := &meGroupRemoveUnitOpts{}
	fs := flag.NewFlagSet("me group remove-unit", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "remove-unit", cmdInfo{
		Run:		meGroupRemoveUnitCmd,
		Flags:		flagsOnly(meGroupRemoveUnitFlags),
		Synopsis:	"delete a unit from its group",
	})
}

// meGroupRemoveUnitCmd implements `dcs-sms me group remove-unit --name|--id <X>`.
//
// Removes a single unit from its parent group, mirroring the ME UI's
// per-unit "x" button. Selection is by unit name or unit id (mutually
// exclusive) — the verb walks the coalition tree to find the unit and
// determine its parent.
//
// Refuses to remove the last unit in a group; use `me group remove` for
// that case (an empty group breaks the ME's Unit List panel and other
// invariants downstream). The remove dance — symbol, warehouse,
// waypoint linkChildren, trigger zone refs, panel refresh — is handled
// by Mission.remove_unit.
func meGroupRemoveUnitCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupRemoveUnitFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me group remove-unit: exactly one of --name or --id is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s }", idClause)

	resp, exitCode := runMeVerb("group_remove_unit", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
