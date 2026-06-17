package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meCoordsMagvarOpts struct {
	North      float64
	East       float64
	Lat        float64
	Lon        float64
	HasNorth   bool
	HasEast    bool
	HasLat     bool
	HasLon     bool
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
}

func meCoordsMagvarFlags() (*flag.FlagSet, *meCoordsMagvarOpts) {
	opts := &meCoordsMagvarOpts{}
	fs := flag.NewFlagSet("me coords magvar", flag.ContinueOnError)
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin (pair with --east)")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin (pair with --north)")
	fs.Float64Var(&opts.Lat, "lat", 0, "latitude in degrees (pair with --lon)")
	fs.Float64Var(&opts.Lon, "lon", 0, "longitude in degrees (pair with --lat)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("coords", "magvar", cmdInfo{
		Run:      meCoordsMagvarCmd,
		Flags:    flagsOnly(meCoordsMagvarFlags),
		Synopsis: "magnetic declination (degrees, East +) at a point for the open mission's date",
	})
}

// meCoordsMagvarCmd implements
// `dcs-sms me coords magvar (--north N --east E | --lat LA --lon LO)`.
//
// Thin wrapper over DCS's magvar module — the same one the ME waypoint panel
// uses for per-leg magnetic headings. Returns decl_deg (East positive, West
// negative). The result is date-dependent (IGRF against the open mission's
// date), so open the intended mission first.
//
// Exactly one coordinate pair is required. The flag defaults (0) are valid
// coordinates, so we use fs.Visit to tell "user passed 0" from "user omitted
// the flag".
func meCoordsMagvarCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meCoordsMagvarFlags()
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
		case "lat":
			opts.HasLat = true
		case "lon":
			opts.HasLon = true
		}
	})

	hasNE := opts.HasNorth && opts.HasEast
	hasLL := opts.HasLat && opts.HasLon
	if hasNE == hasLL {
		fmt.Fprintln(stderr, "dcs-sms me coords magvar: provide exactly one of --north/--east or --lat/--lon")
		return 2
	}
	if opts.HasNorth != opts.HasEast || opts.HasLat != opts.HasLon {
		fmt.Fprintln(stderr, "dcs-sms me coords magvar: --north/--east and --lat/--lon must each be given as a pair")
		return 2
	}

	var luaArgs string
	if hasNE {
		luaArgs = fmt.Sprintf("{ north = %g, east = %g }", opts.North, opts.East)
	} else {
		luaArgs = fmt.Sprintf("{ lat = %g, lon = %g }", opts.Lat, opts.Lon)
	}

	resp, exitCode := runMeVerb("coords_magvar", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
