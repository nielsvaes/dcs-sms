package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meCoordsToGeoOpts struct {
	North      float64
	East       float64
	Alt        float64
	HasNorth   bool
	HasEast    bool
	HasAlt     bool
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
}

func meCoordsToGeoFlags() (*flag.FlagSet, *meCoordsToGeoOpts) {
	opts := &meCoordsToGeoOpts{}
	fs := flag.NewFlagSet("me coords to-geo", flag.ContinueOnError)
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin (north positive)")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin (east positive)")
	fs.Float64Var(&opts.Alt, "alt", 0, "altitude in meters (optional; echoed back unchanged)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("coords", "to-geo", cmdInfo{
		Run:      meCoordsToGeoCmd,
		Flags:    flagsOnly(meCoordsToGeoFlags),
		Synopsis: "convert DCS local meters (north/east) to geographic lat/lon for the current theatre",
	})
}

// meCoordsToGeoCmd implements `dcs-sms me coords to-geo --north N --east E [--alt A]`.
//
// --north and --east are required; their flag default (0) is a valid theatre
// coord (origin), so we can't tell "user said 0" from "user forgot the flag"
// by value alone. fs.Visit reports only flags that were explicitly set,
// which is what catches the latter. --alt is genuinely optional and is
// echoed back unchanged when given so a single call can produce a complete
// coord record.
func meCoordsToGeoCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meCoordsToGeoFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "north":
			opts.HasNorth = true
		case "east":
			opts.HasEast = true
		case "alt":
			opts.HasAlt = true
		}
	})
	if !opts.HasNorth || !opts.HasEast {
		fmt.Fprintln(stderr, "dcs-sms me coords to-geo: --north and --east are required")
		return 2
	}

	luaArgs := fmt.Sprintf("{ north = %g, east = %g", opts.North, opts.East)
	if opts.HasAlt {
		luaArgs += fmt.Sprintf(", alt = %g", opts.Alt)
	}
	luaArgs += " }"

	resp, exitCode := runMeVerb("coords_to_geo", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
