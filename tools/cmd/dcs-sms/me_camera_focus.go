package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

func init() {
	registerMeInfo("camera", "focus", cmdInfo{
		Run:		meCameraFocusCmd,
		Flags:		flagsOnly(meCameraFocusFlags),
		Synopsis:	"focus the ME camera on a coordinate / lat-lon / airdrome name",
	})
}

type meCameraFocusOpts struct {
	Name		string
	Lat		float64
	Lon		float64
	X		float64
	Y		float64
	Scale		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meCameraFocusFlags() (*flag.FlagSet, *meCameraFocusOpts) {
	opts := &meCameraFocusOpts{}
	fs := flag.NewFlagSet("me camera focus", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "airdrome name (case-insensitive, substring)")
	fs.Float64Var(&opts.Lat, "lat", 0, "latitude (decimal degrees)")
	fs.Float64Var(&opts.Lon, "lon", 0, "longitude (decimal degrees)")
	fs.Float64Var(&opts.X, "x", 0, "DCS world meters, north axis")
	fs.Float64Var(&opts.Y, "y", 0, "DCS world meters, east axis")
	fs.Float64Var(&opts.Scale, "scale", 0, "map scale (meters per screen unit; 0 = keep current)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

// meCameraFocusCmd implements
//
//	dcs-sms me camera focus { --name N | --lat L --lon L | --x X --y Y } [--scale S]
//
// Pans the ME map to the requested point. Exactly one of:
//   - --name        — case-insensitive airdrome name (exact match preferred,
//                     substring fallback)
//   - --lat / --lon — decimal degrees
//   - --x / --y     — DCS world meters (x = north, y = east)
//
// --scale (meters per screen unit) is optional; if given, applied before the
// camera move.
func meCameraFocusCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meCameraFocusFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	var hasLat, hasLon, hasX, hasY bool
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "lat":
			hasLat = true
		case "lon":
			hasLon = true
		case "x":
			hasX = true
		case "y":
			hasY = true
		}
	})

	modeName := opts.Name != ""
	modeLatLon := hasLat || hasLon
	modeXY := hasX || hasY
	set := 0
	if modeName {
		set++
	}
	if modeLatLon {
		set++
	}
	if modeXY {
		set++
	}
	if set != 1 {
		fmt.Fprintln(stderr, "dcs-sms me camera focus: exactly one of "+
			"--name / --lat+--lon / --x+--y is required")
		return 2
	}
	if modeLatLon && !(hasLat && hasLon) {
		fmt.Fprintln(stderr, "dcs-sms me camera focus: --lat and --lon must both be provided")
		return 2
	}
	if modeXY && !(hasX && hasY) {
		fmt.Fprintln(stderr, "dcs-sms me camera focus: --x and --y must both be provided")
		return 2
	}

	var b strings.Builder
	b.WriteString("{")
	first := true
	add := func(s string) {
		if !first {
			b.WriteString(", ")
		}
		b.WriteString(s)
		first = false
	}
	if modeName {
		add(fmt.Sprintf("name = %s", luaQuote(opts.Name)))
	}
	if modeLatLon {
		add(fmt.Sprintf("lat = %g, lon = %g", opts.Lat, opts.Lon))
	}
	if modeXY {
		add(fmt.Sprintf("x = %g, y = %g", opts.X, opts.Y))
	}
	if opts.Scale != 0 {
		add(fmt.Sprintf("scale = %g", opts.Scale))
	}
	b.WriteString(" }")

	resp, exitCode := runMeVerb("camera_focus", b.String(), opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
