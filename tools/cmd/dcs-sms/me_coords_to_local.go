package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meCoordsToLocalOpts struct {
	Lat        float64
	Lon        float64
	Alt        float64
	HasLat     bool
	HasLon     bool
	HasAlt     bool
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
}

func meCoordsToLocalFlags() (*flag.FlagSet, *meCoordsToLocalOpts) {
	opts := &meCoordsToLocalOpts{}
	fs := flag.NewFlagSet("me coords to-local", flag.ContinueOnError)
	fs.Float64Var(&opts.Lat, "lat", 0, "latitude in degrees (north positive)")
	fs.Float64Var(&opts.Lon, "lon", 0, "longitude in degrees (east positive)")
	fs.Float64Var(&opts.Alt, "alt", 0, "altitude in meters (optional; echoed back unchanged)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("coords", "to-local", cmdInfo{
		Run:      meCoordsToLocalCmd,
		Flags:    flagsOnly(meCoordsToLocalFlags),
		Synopsis: "convert geographic lat/lon to DCS local meters (north/east) for the current theatre",
	})
}

// meCoordsToLocalCmd implements `dcs-sms me coords to-local --lat L --lon Lo [--alt A]`.
//
// --lat and --lon are required; their flag default (0) is a valid coord
// (off the African coast at the equator), so we can't tell "user said 0"
// from "user forgot the flag" by value alone. fs.Visit reports only flags
// that were explicitly set, which is what catches the latter.
func meCoordsToLocalCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meCoordsToLocalFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "lat":
			opts.HasLat = true
		case "lon":
			opts.HasLon = true
		case "alt":
			opts.HasAlt = true
		}
	})
	if !opts.HasLat || !opts.HasLon {
		fmt.Fprintln(stderr, "dcs-sms me coords to-local: --lat and --lon are required")
		return 2
	}

	luaArgs := fmt.Sprintf("{ lat = %g, lon = %g", opts.Lat, opts.Lon)
	if opts.HasAlt {
		luaArgs += fmt.Sprintf(", alt = %g", opts.Alt)
	}
	luaArgs += " }"

	resp, exitCode := runMeVerb("coords_to_local", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
