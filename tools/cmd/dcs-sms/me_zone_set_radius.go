package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meZoneSetRadiusOpts struct {
	Name		string
	ID		int
	Radius		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meZoneSetRadiusFlags() (*flag.FlagSet, *meZoneSetRadiusOpts) {
	opts := &meZoneSetRadiusOpts{}
	fs := flag.NewFlagSet("me zone set-radius", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "zone name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "zone id (mutually exclusive with --name)")
	fs.Float64Var(&opts.Radius, "radius", 0, "radius in meters")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("zone", "set-radius", cmdInfo{
		Run:		meZoneSetRadiusCmd,
		Flags:		flagsOnly(meZoneSetRadiusFlags),
		Synopsis:	"change a zone's radius in meters",
	})
}

// meZoneSetRadiusCmd implements `dcs-sms me zone set-radius --name|--id <X> --radius <m>`.
//
// For circle zones, this sets the trigger radius. For quad zones, this sets
// the icon radius (the circle drawn at center; the quad shape itself is
// defined by --vertices, not --radius). Wraps
// Mission.TriggerZoneData.setTriggerZoneRadius.
func meZoneSetRadiusCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meZoneSetRadiusFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me zone set-radius: exactly one of --name or --id is required")
		return 2
	}
	if opts.Radius <= 0 {
		fmt.Fprintln(stderr, "dcs-sms me zone set-radius: --radius is required (> 0)")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, radius = %g }", idClause, opts.Radius)

	resp, exitCode := runMeVerb("zone_set_radius", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
