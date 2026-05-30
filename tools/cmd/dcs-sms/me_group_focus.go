package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupFocusOpts struct {
	Name		string
	ID		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupFocusFlags() (*flag.FlagSet, *meGroupFocusOpts) {
	opts := &meGroupFocusOpts{}
	fs := flag.NewFlagSet("me group focus", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "group name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "group id (mutually exclusive with --name)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "focus", cmdInfo{
		Run:		meGroupFocusCmd,
		Flags:		flagsOnly(meGroupFocusFlags),
		Synopsis:	"raise the AIRPLANE/HELICOPTER GROUP and route panels for a group (same UI state as a map click)",
	})
}

// meGroupFocusCmd implements `dcs-sms me group focus --name|--id <X>`.
//
// Programmatically created groups (me group create-plane, …) never go
// through ED's MapWindow click path, so the right-side info panels stay
// hidden until the user clicks the unit icon. This verb runs the same
// panel-show sequence ED's click handler would: me_aircraft.switchView
// + setGroup + show, plus me_route.show. Plane and helicopter groups
// raise the aircraft panel; ground/ship groups raise only the route
// panel (their info panels live elsewhere and are out of scope here).
func meGroupFocusCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupFocusFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me group focus: exactly one of --name or --id is required")
		return 2
	}
	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s }", idClause)
	resp, exitCode := runMeVerb("group_focus", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
