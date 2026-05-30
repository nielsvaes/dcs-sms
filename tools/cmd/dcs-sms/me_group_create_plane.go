package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupCreatePlaneOpts struct {
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

func meGroupCreatePlaneFlags() (*flag.FlagSet, *meGroupCreatePlaneOpts) {
	opts := &meGroupCreatePlaneOpts{}
	fs := flag.NewFlagSet("me group create-plane", flag.ContinueOnError)
	fs.StringVar(&opts.Country, "country", "", "country name in current mission (e.g. USA, Russia)")
	fs.StringVar(&opts.Type, "type", "", "airframe id (e.g. F-16C_50, Su-27)")
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin (north positive)")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin (east positive)")
	fs.StringVar(&opts.Name, "name", "", "group name (auto-allocated if empty)")
	fs.Float64Var(&opts.Alt, "alt", 8000, "altitude in meters above sea level")
	fs.StringVar(&opts.AltType, "alt-type", "BARO", "altitude reference: BARO or RADIO")
	fs.Float64Var(&opts.Speed, "speed", 220, "speed in m/s")
	fs.Float64Var(&opts.Heading, "heading", 0, "heading in degrees (0 = north, CW positive)")
	fs.StringVar(&opts.Skill, "skill", "Average", "AI skill: Average, Good, High, Excellent, Random, Player")
	fs.StringVar(&opts.Livery, "livery", "", "livery id ('' = default)")
	fs.Float64Var(&opts.Frequency, "frequency", 251, "radio frequency MHz")
	fs.StringVar(&opts.OnboardNum, "onboard-num", "010", "onboard number (display only)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "create-plane", cmdInfo{
		Run:		meGroupCreatePlaneCmd,
		Flags:		flagsOnly(meGroupCreatePlaneFlags),
		Synopsis:	"spawn a new plane group at the given coordinates",
	})
}

// meGroupCreatePlaneCmd implements
// `dcs-sms me group create-plane --country <c> --type <t> --north <m> --east <m> [...]`.
//
// Synthesizes and injects a single-unit fixed-wing aircraft group at
// the given map position, single waypoint at the spawn point with an empty
// ComboTask. Survives save (runs Mission.fixWaypointForGroup), is fully
// selectable in the ME, and runs in mission. Sequence implemented in
// dcs_sms_me/verbs.lua follows the canonical 11-step injection from
// research/me-bridge-discovery-2026-05-08.md.
//
// Coordinates: --north is meters north of theatre origin (north positive),
// --east is meters east (east positive), --alt is altitude above sea level.
// We use north/east because DCS's internal naming is contradictory — the
// mission table stores the ground as (x = N–S, y = E–W) while the runtime 3D
// engine uses (x = N–S, y = altitude, z = E–W). See the comment block at the
// top of verbs.lua for the full rationale.
//
// Country must already exist in the mission's coalition tree — `me file new
// --map <theatre>` sets DCS defaults that include the usual Red/Blue
// countries for that theatre.
func meGroupCreatePlaneCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupCreatePlaneFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Country == "" {
		fmt.Fprintln(stderr, "dcs-sms me group create-plane: --country is required")
		return 2
	}
	if opts.Type == "" {
		fmt.Fprintln(stderr, "dcs-sms me group create-plane: --type is required")
		return 2
	}
	// north/east default to 0; we don't reject (0,0) because some theatres
	// have meaningful origin near 0,0.

	luaArgs := fmt.Sprintf(
		"{ country = %s, type = %s, north = %g, east = %g, name = %s, "+
			"alt = %g, alt_type = %s, speed = %g, heading_deg = %g, "+
			"skill = %s, livery = %s, frequency = %g, onboard_num = %s }", luaQuote(opts.Country), luaQuote(opts.Type), opts.North, opts.East, luaQuote(opts.Name), opts.Alt, luaQuote(opts.AltType), opts.Speed, opts.Heading, luaQuote(opts.Skill), luaQuote(opts.Livery), opts.Frequency, luaQuote(opts.OnboardNum),
	)

	resp, exitCode := runMeVerb("group_create_plane", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
