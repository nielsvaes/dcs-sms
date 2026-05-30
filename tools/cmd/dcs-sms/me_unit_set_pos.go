package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meUnitSetPosOpts struct {
	Name		string
	ID		int
	North		float64
	East		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitSetPosFlags() (*flag.FlagSet, *meUnitSetPosOpts) {
	opts := &meUnitSetPosOpts{}
	fs := flag.NewFlagSet("me unit set-pos", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "set-pos", cmdInfo{
		Run:		meUnitSetPosCmd,
		Flags:		flagsOnly(meUnitSetPosFlags),
		Synopsis:	"move a unit to a new north/east coordinate",
	})
}

// meUnitSetPosCmd implements
// `dcs-sms me unit set-pos --name|--id <X> --north <m> --east <m>`.
//
// Moves a single unit only — does NOT translate the rest of the group. Use
// `me group set-pos` to move the whole group together. The Lua verb refreshes
// Mission.update_group_map_objects so the ME view reflects the move
// immediately.
//
// IMPORTANT for air groups: setting a per-unit position on a plane /
// helicopter unit is decorative — DCS overrides it at mission load and
// pins the unit to the group's formation_template. The new position
// shows up in the ME view and survives save, but at runtime the flight
// is laid out by the formation. For ground / ship / static units the
// position is honoured verbatim.
func meUnitSetPosCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitSetPosFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit set-pos: exactly one of --name or --id is required")
		return 2
	}
	northSet, eastSet := false, false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "north" {
			northSet = true
		}
		if f.Name == "east" {
			eastSet = true
		}
	})
	if !northSet || !eastSet {
		fmt.Fprintln(stderr, "dcs-sms me unit set-pos: --north and --east are both required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, north = %g, east = %g }", idClause, opts.North, opts.East)

	resp, exitCode := runMeVerb("unit_set_pos", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
