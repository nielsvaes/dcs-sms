package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meZoneSetPosOpts struct {
	Name		string
	ID		int
	North		float64
	East		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meZoneSetPosFlags() (*flag.FlagSet, *meZoneSetPosOpts) {
	opts := &meZoneSetPosOpts{}
	fs := flag.NewFlagSet("me zone set-pos", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "zone name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "zone id (mutually exclusive with --name)")
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin (north positive)")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin (east positive)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("zone", "set-pos", cmdInfo{
		Run:		meZoneSetPosCmd,
		Flags:		flagsOnly(meZoneSetPosFlags),
		Synopsis:	"move a zone to a new north/east coordinate",
	})
}

// meZoneSetPosCmd implements `dcs-sms me zone set-pos --name|--id <X> --north <m> --east <m>`.
//
// For circle zones, this moves the center of the zone. For quad zones, this
// also moves the center — but since the underlying points are stored relative
// to center, the quad shape moves with it (translation only, no rotation/
// scale). Use `me zone set-vertices` to reshape a quad in place.
//
// Coords use the project --north/--east meters convention (see top of
// verbs.lua). Wraps Mission.TriggerZoneData.setTriggerZonePosition.
func meZoneSetPosCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meZoneSetPosFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me zone set-pos: exactly one of --name or --id is required")
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
		fmt.Fprintln(stderr, "dcs-sms me zone set-pos: --north and --east are both required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, north = %g, east = %g }", idClause, opts.North, opts.East)

	resp, exitCode := runMeVerb("zone_set_pos", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
