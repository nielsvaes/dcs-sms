package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupCreateVehicleOpts struct {
	Country		string
	Type		string
	North		float64
	East		float64
	Name		string
	Heading		float64
	Skill		string
	Task		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupCreateVehicleFlags() (*flag.FlagSet, *meGroupCreateVehicleOpts) {
	opts := &meGroupCreateVehicleOpts{}
	fs := flag.NewFlagSet("me group create-vehicle", flag.ContinueOnError)
	fs.StringVar(&opts.Country, "country", "", "country in current mission")
	fs.StringVar(&opts.Type, "type", "", "vehicle id (e.g. M-1 Abrams, T-72B)")
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin")
	fs.StringVar(&opts.Name, "name", "", "group name (auto-allocated if empty)")
	fs.Float64Var(&opts.Heading, "heading", 0, "heading in degrees (0 = north, CW positive)")
	fs.StringVar(&opts.Skill, "skill", "Average", "AI skill")
	fs.StringVar(&opts.Task, "task", "", "group task; default \"Ground Nothing\"")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "create-vehicle", cmdInfo{
		Run:		meGroupCreateVehicleCmd,
		Flags:		flagsOnly(meGroupCreateVehicleFlags),
		Synopsis:	"spawn a new ground vehicle group at the given coordinates",
	})
}

// meGroupCreateVehicleCmd implements
// `dcs-sms me group create-vehicle --country <c> --type <t> --north --east [...]`.
//
// Synthesizes a stationary single-unit ground vehicle group: single
// "Off Road" waypoint at the spawn point with speed=0, speed_locked.
// task = "Ground Nothing".
func meGroupCreateVehicleCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupCreateVehicleFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Country == "" {
		fmt.Fprintln(stderr, "dcs-sms me group create-vehicle: --country is required")
		return 2
	}
	if opts.Type == "" {
		fmt.Fprintln(stderr, "dcs-sms me group create-vehicle: --type is required")
		return 2
	}

	luaArgs := fmt.Sprintf(
		"{ country = %s, type = %s, north = %g, east = %g, name = %s, "+
			"heading_deg = %g, skill = %s, task = %s }", luaQuote(opts.Country), luaQuote(opts.Type), opts.North, opts.East, luaQuote(opts.Name), opts.Heading, luaQuote(opts.Skill), luaQuote(opts.Task),
	)

	resp, exitCode := runMeVerb("group_create_vehicle", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
