package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupCreateHelicopterOpts struct {
	Country		string
	Type		string
	North		float64
	East		float64
	Name		string
	Alt		float64
	AltType		string
	Speed		float64
	Heading		float64
	Skill		string
	Livery		string
	Frequency	float64
	OnboardNum	string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupCreateHelicopterFlags() (*flag.FlagSet, *meGroupCreateHelicopterOpts) {
	opts := &meGroupCreateHelicopterOpts{}
	fs := flag.NewFlagSet("me group create-helicopter", flag.ContinueOnError)
	fs.StringVar(&opts.Country, "country", "", "country in current mission (e.g. USA, Russia)")
	fs.StringVar(&opts.Type, "type", "", "airframe id (e.g. UH-60L, Mi-8MT)")
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin")
	fs.StringVar(&opts.Name, "name", "", "group name (auto-allocated if empty)")
	fs.Float64Var(&opts.Alt, "alt", 1000, "altitude in meters above sea level")
	fs.StringVar(&opts.AltType, "alt-type", "BARO", "altitude reference: BARO or RADIO")
	fs.Float64Var(&opts.Speed, "speed", 50, "speed in m/s")
	fs.Float64Var(&opts.Heading, "heading", 0, "heading in degrees (0 = north, CW positive)")
	fs.StringVar(&opts.Skill, "skill", "Average", "AI skill")
	fs.StringVar(&opts.Livery, "livery", "", "livery id")
	fs.Float64Var(&opts.Frequency, "frequency", 127.5, "radio frequency MHz")
	fs.StringVar(&opts.OnboardNum, "onboard-num", "010", "onboard number")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "create-helicopter", cmdInfo{
		Run:		meGroupCreateHelicopterCmd,
		Flags:		flagsOnly(meGroupCreateHelicopterFlags),
		Synopsis:	"spawn a new helicopter group at the given coordinates",
	})
}

// meGroupCreateHelicopterCmd implements
// `dcs-sms me group create-helicopter --country <c> --type <t> --north --east [...]`.
//
// Same structural shape as create-plane (single unit, single waypoint with
// empty ComboTask, save-survives via Mission.fixWaypointForGroup), but with
// helo-typical defaults: lower altitude, slower speed, lower frequency.
func meGroupCreateHelicopterCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupCreateHelicopterFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Country == "" {
		fmt.Fprintln(stderr, "dcs-sms me group create-helicopter: --country is required")
		return 2
	}
	if opts.Type == "" {
		fmt.Fprintln(stderr, "dcs-sms me group create-helicopter: --type is required")
		return 2
	}

	luaArgs := fmt.Sprintf(
		"{ country = %s, type = %s, north = %g, east = %g, name = %s, "+
			"alt = %g, alt_type = %s, speed = %g, heading_deg = %g, "+
			"skill = %s, livery = %s, frequency = %g, onboard_num = %s }", luaQuote(opts.Country), luaQuote(opts.Type), opts.North, opts.East, luaQuote(opts.Name), opts.Alt, luaQuote(opts.AltType), opts.Speed, opts.Heading, luaQuote(opts.Skill), luaQuote(opts.Livery), opts.Frequency, luaQuote(opts.OnboardNum),
	)

	resp, exitCode := runMeVerb("group_create_helicopter", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
