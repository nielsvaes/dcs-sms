package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupCreateShipOpts struct {
	Country		string
	Type		string
	North		float64
	East		float64
	Name		string
	Heading		float64
	Skill		string
	Task		string
	Force		bool
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupCreateShipFlags() (*flag.FlagSet, *meGroupCreateShipOpts) {
	opts := &meGroupCreateShipOpts{}
	fs := flag.NewFlagSet("me group create-ship", flag.ContinueOnError)
	fs.StringVar(&opts.Country, "country", "", "country in current mission")
	fs.StringVar(&opts.Type, "type", "", "ship id (e.g. CVN_71_THEODORE_ROOSEVELT, FFG_7CL_OliverHazardPerry)")
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin")
	fs.StringVar(&opts.Name, "name", "", "group name (auto-allocated if empty)")
	fs.Float64Var(&opts.Heading, "heading", 0, "heading in degrees (0 = north, CW positive)")
	fs.StringVar(&opts.Skill, "skill", "Average", "AI skill")
	fs.StringVar(&opts.Task, "task", "", "group task; default \"CAP\"")
	fs.BoolVar(&opts.Force, "force", false, "skip the water-surface check")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "create-ship", cmdInfo{
		Run:		meGroupCreateShipCmd,
		Flags:		flagsOnly(meGroupCreateShipFlags),
		Synopsis:	"spawn a new ship group at the given coordinates",
	})
}

// meGroupCreateShipCmd implements
// `dcs-sms me group create-ship --country <c> --type <t> --north --east [--force]`.
//
// Synthesizes a stationary single-unit naval-vessel group. Same shape as
// create-vehicle, but the spawn point must be over water — the verb
// queries terrain.GetSurfaceType and refuses if the position is land
// (use --force to override, e.g. for spawning at a not-quite-coastal pier).
func meGroupCreateShipCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupCreateShipFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Country == "" {
		fmt.Fprintln(stderr, "dcs-sms me group create-ship: --country is required")
		return 2
	}
	if opts.Type == "" {
		fmt.Fprintln(stderr, "dcs-sms me group create-ship: --type is required")
		return 2
	}

	luaArgs := fmt.Sprintf(
		"{ country = %s, type = %s, north = %g, east = %g, name = %s, "+
			"heading_deg = %g, skill = %s, task = %s, force = %t }", luaQuote(opts.Country), luaQuote(opts.Type), opts.North, opts.East, luaQuote(opts.Name), opts.Heading, luaQuote(opts.Skill), luaQuote(opts.Task), opts.Force,
	)

	resp, exitCode := runMeVerb("group_create_ship", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
