package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupSetPosOpts struct {
	Name		string
	ID		int
	North		float64
	East		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupSetPosFlags() (*flag.FlagSet, *meGroupSetPosOpts) {
	opts := &meGroupSetPosOpts{}
	fs := flag.NewFlagSet("me group set-pos", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "group name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "group id (mutually exclusive with --name)")
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin (north positive)")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin (east positive)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "set-pos", cmdInfo{
		Run:		meGroupSetPosCmd,
		Flags:		flagsOnly(meGroupSetPosFlags),
		Synopsis:	"move a group to a new north/east coordinate",
	})
}

// meGroupSetPosCmd implements
// `dcs-sms me group set-pos --name|--id <X> --north <m> --east <m>`.
//
// Translates the entire group — group ref + every unit + every waypoint —
// by the delta from current g.x/g.y to the new (north, east). This is what
// dragging a group does in the ME UI.
//
// For multi-unit groups, the relative offsets between units are preserved
// (CAP four-ship stays in formation; SAM ring stays as a ring). For unit-
// level moves use `me unit set-pos` instead.
func meGroupSetPosCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupSetPosFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me group set-pos: exactly one of --name or --id is required")
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
		fmt.Fprintln(stderr, "dcs-sms me group set-pos: --north and --east are both required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, north = %g, east = %g }", idClause, opts.North, opts.East)

	resp, exitCode := runMeVerb("group_set_pos", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
