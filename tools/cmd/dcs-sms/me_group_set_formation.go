package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupSetFormationOpts struct {
	Name		string
	ID		int
	Formation	string
	Waypoint	int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupSetFormationFlags() (*flag.FlagSet, *meGroupSetFormationOpts) {
	opts := &meGroupSetFormationOpts{}
	fs := flag.NewFlagSet("me group set-formation", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "group name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "group id (mutually exclusive with --name)")
	fs.StringVar(&opts.Formation, "formation", "", "formation alias (vee/cone/rank/...) or a DB.templates name (Custom)")
	fs.IntVar(&opts.Waypoint, "waypoint", 1, "waypoint index (1-based); default 1")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "set-formation", cmdInfo{
		Run:		meGroupSetFormationCmd,
		Flags:		flagsOnly(meGroupSetFormationFlags),
		Synopsis:	"set a group's formation",
	})
}

// meGroupSetFormationCmd implements
// `dcs-sms me group set-formation --name|--id <X> --formation <name> [--waypoint N]`.
//
// Vehicle groups only. Sets the per-waypoint formation action.
//   --formation accepts a built-in alias (off-road, on-road, rank, cone, vee,
//   diamond, echelon-left, echelon-right, custom) or a DB.templates name
//   (e.g. "Hawk SAM Battery") which is resolved to action=customForm and
//   stored in wp.formation_template.
//
// Refused on plane / helicopter (formation is per-task, not yet exposed),
// ship (only turningPoint is valid), and static (no route).
func meGroupSetFormationCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupSetFormationFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me group set-formation: exactly one of --name or --id is required")
		return 2
	}
	if opts.Formation == "" {
		fmt.Fprintln(stderr, "dcs-sms me group set-formation: --formation is required")
		return 2
	}
	if opts.Waypoint < 1 {
		fmt.Fprintln(stderr, "dcs-sms me group set-formation: --waypoint must be >= 1")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, formation = %s, waypoint = %d }",
		idClause, luaQuote(opts.Formation), opts.Waypoint)

	resp, exitCode := runMeVerb("group_set_formation", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
